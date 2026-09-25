import 'dart:async';
import 'dart:typed_data';

import '../../exceptions.dart';
import '../../link/trezor_link.dart';
import '../../messages/thp.dart';
import '../../util/async_queue.dart';
import '../../util/bytes.dart';
import 'credentials.dart';
import 'noise.dart';
import 'thp_packet.dart';

/// `trezor_state` from `HandshakeCompletionResponse`.
enum ThpPairingState {
  unpaired,

  /// Credential accepted; the user may still be asked to confirm the
  /// connection on the device.
  paired,

  /// Credential accepted and no confirmation will be asked (channel
  /// replacement, e.g. after the app restarted).
  pairedAutoconnect,
}

class ThpHandshakeResult {
  const ThpHandshakeResult({required this.state, this.usedCredential});

  final ThpPairingState state;

  /// The stored credential that was offered, if one matched this device.
  final ThpCredential? usedCredential;

  bool get isPaired => state != ThpPairingState.unpaired;
}

/// One THP channel over a [TrezorLink]: the transport layer (allocation,
/// segmenting, CRC, the Alternating Bit Protocol) plus the Noise secure
/// channel on top.
///
/// A single packet listener feeds everything: ACKs complete the pending
/// send, data messages are ACKed and queued for [receive], and transport
/// errors fail whichever side is waiting. That keeps sending (e.g. a `Cancel`)
/// possible while a read is outstanding, which a read-then-write design
/// cannot do.
///
/// ACK piggybacking (protocol ≥ 2.1) is not used: the host sends the ACK bit
/// as 0 on `HandshakeInitiationRequest`, which is how the spec lets a host opt
/// out, so the device keeps sending explicit ACKs.
class ThpChannel {
  ThpChannel._(this._link) {
    _subscription = _link.packets.listen(
      _onPacket,
      onError: (Object e, StackTrace s) => _failAll(e, s),
      onDone: () => _failAll(const TrezorDisconnectedException()),
    );
  }

  /// How long to wait for an ACK before retransmitting. BLE writes with
  /// response already pace the sender, so this covers device processing only.
  static const Duration ackTimeout = Duration(milliseconds: 1000);
  static const int maxRetransmissions = 20;
  static const Duration _busyBackoff = Duration(milliseconds: 100);

  final TrezorLink _link;
  late final StreamSubscription<Uint8List> _subscription;
  final ThpAssembler _assembler = ThpAssembler();
  final AsyncLock _packetLock = AsyncLock();
  final AsyncLock _sendLock = AsyncLock();
  final AsyncLock _encryptLock = AsyncLock();
  final AsyncQueue<ThpMessage> _inbox = AsyncQueue();

  int _channelId = broadcastChannelId;
  late ThpDeviceProperties deviceProperties;

  int _sendBit = 0;
  int _receiveBit = 0;
  Completer<void>? _ackWaiter;
  int _ackExpected = 0;

  Uint8List? _allocationNonce;
  Completer<ThpMessage>? _allocationWaiter;

  ThpCipherState? _outbound;
  ThpCipherState? _inbound;
  Uint8List? _handshakeHash;
  Uint8List? _hostStaticPrivateKey;
  bool _disposed = false;

  int get channelId => _channelId;

  /// Binds pairing proofs to this channel. Available after [handshake].
  Uint8List get handshakeHash => _handshakeHash!;

  /// The host static key used in this channel's handshake; a new credential
  /// is issued for it.
  Uint8List get hostStaticPrivateKey => _hostStaticPrivateKey!;

  /// Requests a channel on the broadcast channel and returns it with the
  /// device properties it announced.
  static Future<ThpChannel> allocate(
    TrezorLink link, {
    int attempts = 3,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final channel = ThpChannel._(link);
    try {
      for (var attempt = 1; ; attempt++) {
        final nonce = randomBytes(8);
        channel._allocationNonce = nonce;
        final waiter = channel._allocationWaiter = Completer<ThpMessage>();
        await channel._writeMessage(
          ThpMessage(
            ThpControl.channelAllocationRequest,
            broadcastChannelId,
            nonce,
          ),
        );
        try {
          final response = await waiter.future.timeout(timeout);
          channel._channelId = readUint16BE(response.data, 8);
          channel.deviceProperties = ThpDeviceProperties.decode(
            Uint8List.fromList(response.data.sublist(10)),
          );
          return channel;
        } on TimeoutException {
          if (attempt >= attempts) {
            throw const TrezorTimeoutException(
              'Trezor did not answer the THP channel allocation request',
            );
          }
        }
      }
    } catch (_) {
      await channel.dispose();
      rethrow;
    } finally {
      channel._allocationWaiter = null;
      channel._allocationNonce = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Receiving
  // ---------------------------------------------------------------------------

  void _onPacket(Uint8List packet) {
    final ThpMessage? message;
    try {
      message = _assembler.add(packet);
    } catch (_) {
      return; // malformed packet; the sender will retransmit
    }
    if (message != null) _onMessage(message);
  }

  void _onMessage(ThpMessage message) {
    final control = message.control;

    if (message.channelId == broadcastChannelId) {
      final waiter = _allocationWaiter;
      final nonce = _allocationNonce;
      if (control == ThpControl.channelAllocationResponse &&
          waiter != null &&
          !waiter.isCompleted &&
          nonce != null &&
          message.data.length >= 10 &&
          bytesEqual(message.data.sublist(0, 8), nonce)) {
        waiter.complete(message);
      }
      return;
    }
    if (message.channelId != _channelId) return;

    if (control == ThpControl.transportError) {
      final error = ThpTransportException(
        message.data.isEmpty ? 0 : message.data[0],
      );
      final ackWaiter = _ackWaiter;
      if (ackWaiter != null && !ackWaiter.isCompleted) {
        ackWaiter.completeError(error);
      }
      // Busy only means "retransmit later"; everything else kills the channel.
      if (error.code != ThpTransportException.transportBusy) _failAll(error);
      return;
    }

    if (ThpControl.isAck(control)) {
      final ackWaiter = _ackWaiter;
      if (ackWaiter != null &&
          !ackWaiter.isCompleted &&
          ThpControl.ackOf(control) == _ackExpected) {
        ackWaiter.complete();
      }
      return;
    }

    if (ThpControl.isData(control)) {
      final seq = ThpControl.seqOf(control);
      // ACK every data message, duplicates included: a duplicate means our
      // earlier ACK was lost and the device is retransmitting.
      unawaited(_sendAck(seq).catchError((Object _) {}));
      if (seq != _receiveBit) return; // duplicate, already delivered
      _receiveBit ^= 1;
      // The device only sends data after it has taken our last message, so a
      // response also settles a send whose ACK went missing.
      final ackWaiter = _ackWaiter;
      if (ackWaiter != null && !ackWaiter.isCompleted) ackWaiter.complete();
      _inbox.add(message);
    }
  }

  void _failAll(Object error, [StackTrace? stackTrace]) {
    final ackWaiter = _ackWaiter;
    if (ackWaiter != null && !ackWaiter.isCompleted) {
      ackWaiter.completeError(error, stackTrace);
    }
    final allocationWaiter = _allocationWaiter;
    if (allocationWaiter != null && !allocationWaiter.isCompleted) {
      allocationWaiter.completeError(error, stackTrace);
    }
    _inbox.fail(error, stackTrace);
  }

  /// Next data message (handshake response or encrypted transport).
  Future<ThpMessage> receive({Duration? timeout}) =>
      _inbox.next(timeout: timeout);

  // ---------------------------------------------------------------------------
  // Sending
  // ---------------------------------------------------------------------------

  /// Writes all packets of [message] back to back. Packet writes of different
  /// messages must never interleave: a new initiation packet on a channel
  /// makes the receiver drop the payload it was reassembling.
  Future<void> _writeMessage(ThpMessage message) => _packetLock.run(() async {
    for (final packet in message.toPackets(_link.packetSize)) {
      await _link.write(packet);
    }
  });

  Future<void> _sendAck(int seq) => _writeMessage(
    ThpMessage(
      ThpControl.ack | (seq == 1 ? ThpControl.ackBit : 0),
      _channelId,
      Uint8List(0),
    ),
  );

  /// Sends one data message under the Alternating Bit Protocol: stamp the
  /// sequence bit, write, wait for the matching ACK, retransmit on timeout.
  Future<void> send(int dataKind, Uint8List data) => _sendLock.run(() async {
    final control = dataKind | (_sendBit == 1 ? ThpControl.seqBit : 0);
    final message = ThpMessage(control, _channelId, data);
    var backoff = _busyBackoff;
    for (var attempt = 0; attempt <= maxRetransmissions; attempt++) {
      if (_disposed) throw const TrezorDisconnectedException();
      final waiter = _ackWaiter = Completer<void>();
      _ackExpected = _sendBit;
      await _writeMessage(message);
      try {
        await waiter.future.timeout(ackTimeout);
        _sendBit ^= 1;
        return;
      } on TimeoutException {
        continue;
      } on ThpTransportException catch (e) {
        if (e.code != ThpTransportException.transportBusy) rethrow;
        await Future<void>.delayed(backoff);
        backoff *= 2;
      } finally {
        _ackWaiter = null;
      }
    }
    throw const TrezorTimeoutException('Trezor did not acknowledge a message');
  });

  // ---------------------------------------------------------------------------
  // Secure channel
  // ---------------------------------------------------------------------------

  /// Runs the Noise XX handshake. Offers the first stored credential that
  /// matches this device; without one a fresh host key is used and the
  /// device will ask to pair.
  ///
  /// [responseTimeout] is null by default because with [tryToUnlock] a locked
  /// device answers only after the user enters the PIN.
  Future<ThpHandshakeResult> handshake({
    required List<ThpCredential> credentials,
    bool tryToUnlock = true,
    Duration? responseTimeout,
  }) async {
    final noise = NoiseHandshake(prologue: deviceProperties.raw);
    await send(
      ThpControl.handshakeInitRequest,
      await noise.writeInitiation(tryToUnlock: tryToUnlock),
    );

    final init = await receive(timeout: responseTimeout);
    if (ThpControl.dataKind(init.control) != ThpControl.handshakeInitResponse) {
      throw const TrezorProtocolException(
        'Expected HandshakeInitiationResponse',
      );
    }
    await noise.readInitiationResponse(init.data);

    ThpCredential? credential;
    for (final candidate in credentials) {
      if (await candidate.matches(
        ephemeral: noise.remoteEphemeral,
        maskedStatic: noise.remoteMaskedStatic,
      )) {
        credential = candidate;
        break;
      }
    }
    final staticPrivateKey =
        credential?.hostStaticPrivateKey ?? randomBytes(32);
    await send(
      ThpControl.handshakeCompletionRequest,
      await noise.writeCompletion(
        staticPrivateKey: staticPrivateKey,
        payload: ThpHandshakeCompletionReqNoisePayload(
          hostPairingCredential: credential?.credential,
        ).encode(),
      ),
    );

    final completion = await receive(timeout: responseTimeout);
    if (ThpControl.dataKind(completion.control) !=
        ThpControl.handshakeCompletionResponse) {
      throw const TrezorProtocolException(
        'Expected HandshakeCompletionResponse',
      );
    }
    final (keyRequest, keyResponse) = noise.split();
    _outbound = ThpCipherState(keyRequest);
    _inbound = ThpCipherState(keyResponse);
    final state = await _inbound!.decrypt(completion.data);
    if (state.length != 1 || state[0] > 2) {
      throw TrezorProtocolException(
        'Invalid trezor_state ${bytesToHex(state)}',
      );
    }
    _handshakeHash = noise.handshakeHash;
    _hostStaticPrivateKey = staticPrivateKey;
    return ThpHandshakeResult(
      state: ThpPairingState.values[state[0]],
      usedCredential: credential,
    );
  }

  /// Encrypts and sends one application-layer payload. Encryption and send
  /// happen under one lock because nonces must reach the device in order.
  Future<void> sendEncrypted(Uint8List plaintext) => _encryptLock.run(() async {
    final cipher = _outbound;
    if (cipher == null) {
      throw StateError('THP handshake has not completed');
    }
    await send(ThpControl.encryptedTransport, await cipher.encrypt(plaintext));
  });

  Future<Uint8List> receiveEncrypted({Duration? timeout}) async {
    final cipher = _inbound;
    if (cipher == null) {
      throw StateError('THP handshake has not completed');
    }
    final message = await receive(timeout: timeout);
    if (ThpControl.dataKind(message.control) != ThpControl.encryptedTransport) {
      throw const TrezorProtocolException('Expected an encrypted message');
    }
    return cipher.decrypt(message.data);
  }

  /// Stops listening to the link. Does not close the link itself.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    _failAll(const TrezorDisconnectedException('THP channel closed'));
  }
}
