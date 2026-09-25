import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:trezor_flutter/src/link/trezor_link.dart';
import 'package:trezor_flutter/src/messages/message.dart';
import 'package:trezor_flutter/src/protobuf/proto.dart';
import 'package:trezor_flutter/src/protocol/codec_v1.dart';
import 'package:trezor_flutter/src/protocol/thp/noise.dart';
import 'package:trezor_flutter/src/protocol/thp/thp_crypto.dart';
import 'package:trezor_flutter/src/protocol/thp/thp_packet.dart';
import 'package:trezor_flutter/src/util/bytes.dart';

/// In-memory [TrezorLink] whose far end is a [FakeTrezor].
class FakeLink implements TrezorLink {
  FakeLink(this.packetSize);

  @override
  final int packetSize;

  final StreamController<Uint8List> _toHost = StreamController.broadcast();
  void Function(Uint8List packet)? onHostPacket;

  /// Drops the Nth host packet (1-based) to exercise retransmission.
  int? dropHostPacket;
  int _hostPackets = 0;
  bool closed = false;

  @override
  Stream<Uint8List> get packets => _toHost.stream;

  void deliver(Uint8List packet) {
    if (packet.length != packetSize) {
      throw StateError('device sent ${packet.length}-byte packet');
    }
    scheduleMicrotask(() => _toHost.add(packet));
  }

  @override
  Future<void> write(Uint8List packet) async {
    if (packet.length != packetSize) {
      throw StateError('host sent ${packet.length}-byte packet');
    }
    _hostPackets++;
    if (_hostPackets == dropHostPacket) return;
    scheduleMicrotask(() => onHostPacket?.call(packet));
  }

  @override
  Future<void> close() async {
    closed = true;
    await _toHost.close();
  }
}

Uint8List encodeFeatures({String model = 'Safe 7', bool passphrase = false}) =>
    (ProtoWriter()
          ..string(1, 'trezor.io')
          ..uint(2, 2)
          ..uint(3, 9)
          ..uint(4, 3)
          ..string(6, 'DEVICE-ID')
          ..boolean(8, passphrase)
          ..string(10, 'My Trezor')
          ..boolean(12, true)
          ..string(21, model)
          ..repeatedUint(30, [1, 7, 18])
          ..string(44, 'T3W1'))
        .toBytes();

/// Codec v1 device: answers Cancel, Initialize, GetFeatures, Ping.
class FakeCodecV1Trezor {
  FakeCodecV1Trezor(this.link) {
    link.onHostPacket = _onPacket;
  }

  final FakeLink link;
  BytesBuilder? _buffer;
  int _type = 0;
  int _expected = 0;
  final List<int> received = [];

  void _onPacket(Uint8List packet) {
    if (_buffer == null) {
      _type = readUint16BE(packet, 3);
      _expected = readUint32BE(packet, 5);
      _buffer = BytesBuilder()..add(packet.sublist(9));
    } else {
      _buffer!.add(packet.sublist(1));
    }
    if (_buffer!.length >= _expected) {
      final payload = _buffer!.toBytes().sublist(0, _expected);
      _buffer = null;
      _handle(_type, payload);
    }
  }

  void _send(int type, Uint8List payload) {
    for (final p in CodecV1Wire.encodePackets(type, payload, link.packetSize)) {
      link.deliver(p);
    }
  }

  void _handle(int type, Uint8List payload) {
    received.add(type);
    switch (type) {
      case MessageType.cancel:
        _send(MessageType.failure, (ProtoWriter()..uint(1, 4)).toBytes());
      case MessageType.initialize || MessageType.getFeatures:
        _send(MessageType.features, encodeFeatures(model: 'Safe 5'));
      case MessageType.ping:
        // Exercise the ButtonRequest loop once.
        if (!_pinged) {
          _pinged = true;
          _pendingPing = payload;
          _send(
            MessageType.buttonRequest,
            (ProtoWriter()..uint(1, 1)).toBytes(),
          );
        }
      case MessageType.ethereumSignTxEip1559 || MessageType.ethereumSignTx:
        final f = ProtoFields.decode(payload);
        final isEip1559 = type == MessageType.ethereumSignTxEip1559;
        signedChainId = f.uint(isEip1559 ? 10 : 9);
        _calldataLength = f.uint(isEip1559 ? 9 : 8) ?? 0;
        receivedCalldata = BytesBuilder()
          ..add(f.bytes(isEip1559 ? 8 : 7) ?? const []);
        _requestMoreOrSign(legacy: !isEip1559);
      case MessageType.solanaGetAddress:
        solanaPath = ProtoFields.decode(payload).uints(1);
        _send(
          MessageType.solanaAddress,
          (ProtoWriter()..string(1, 'So1anaFakeAddress')).toBytes(),
        );
      case MessageType.solanaSignTx:
        final f = ProtoFields.decode(payload);
        solanaPath = f.uints(1);
        solanaSignedMessage = f.bytes(2);
        _send(
          MessageType.solanaTxSignature,
          (ProtoWriter()..bytes(1, List.filled(64, 0x33))).toBytes(),
        );
      case MessageType.ethereumTxAck:
        receivedCalldata!.add(ProtoFields.decode(payload).bytes(1)!);
        _requestMoreOrSign(legacy: _legacy);
      case MessageType.buttonAck:
        final ping = ProtoFields.decode(_pendingPing!);
        _send(
          MessageType.success,
          (ProtoWriter()..string(1, ping.string(1))).toBytes(),
        );
      default:
        _send(MessageType.failure, (ProtoWriter()..uint(1, 1)).toBytes());
    }
  }

  bool _pinged = false;
  Uint8List? _pendingPing;

  List<int>? solanaPath;
  Uint8List? solanaSignedMessage;

  // Ethereum signing: asks for calldata 1024 bytes at a time, like firmware.
  int? signedChainId;
  BytesBuilder? receivedCalldata;
  int _calldataLength = 0;
  bool _legacy = false;

  /// Legacy firmware quirk under test: only the recovery bit comes back.
  int legacyParity = 1;

  void _requestMoreOrSign({required bool legacy}) {
    _legacy = legacy;
    final have = receivedCalldata!.length;
    if (have < _calldataLength) {
      final next = _calldataLength - have < 1024
          ? _calldataLength - have
          : 1024;
      _send(
        MessageType.ethereumTxRequest,
        (ProtoWriter()..uint(1, next)).toBytes(),
      );
      return;
    }
    _send(
      MessageType.ethereumTxRequest,
      (ProtoWriter()
            ..uint(2, legacy ? legacyParity : 1)
            ..bytes(3, List.filled(32, 0x11))
            ..bytes(4, List.filled(32, 0x22)))
          .toBytes(),
    );
  }
}

/// THP device, written from the *Trezor-side* state machines in the spec
/// (TH1/TH2, TP0–TP3a, TC1), independently of the host code under test.
class FakeThpTrezor {
  FakeThpTrezor(this.link, {required this.staticPrivateKey}) {
    link.onHostPacket = (p) => _queue = _queue.then((_) => _onPacket(p));
  }

  final FakeLink link;
  final Uint8List staticPrivateKey;
  final Uint8List credAuthKey = randomBytes(32);
  final Uint8List properties =
      (ProtoWriter()
            ..string(1, 'T3W1')
            ..uint(3, 2)
            ..uint(4, 0)
            ..repeatedUint(5, [2]))
          .toBytes();

  static const int cid = 0x1234;

  /// Latest code "shown on the screen".
  String? displayedCode;
  bool pairingConfirmationShown = false;
  int dataMessagesFromHost = 0;
  int duplicatesFromHost = 0;

  Future<void> _queue = Future.value();
  final ThpAssembler _assembler = ThpAssembler();
  int _sendBit = 0;
  int _receiveBit = 0;

  // Handshake state.
  late Uint8List _h, _ck, _k, _ePriv, _hostStatic;
  ThpCipherStateFake? _in, _out;
  Uint8List? _handshakeHash;
  bool _paired = false;

  // Pairing state.
  Uint8List? _secret, _cpacePriv;
  Uint8List? _pendingAfterButton;

  Future<void> _onPacket(Uint8List packet) async {
    final message = _assembler.add(packet);
    if (message == null) return;
    final c = message.control;
    if (c == ThpControl.channelAllocationRequest) {
      _deliver(
        ThpMessage(
          ThpControl.channelAllocationResponse,
          broadcastChannelId,
          concatBytes([message.data, uint16BE(cid), properties]),
        ),
      );
      return;
    }
    if (ThpControl.isAck(c)) return;
    if (!ThpControl.isData(c)) return;

    final seq = ThpControl.seqOf(c);
    _deliver(
      ThpMessage(
        ThpControl.ack | (seq == 1 ? ThpControl.ackBit : 0),
        cid,
        Uint8List(0),
      ),
    );
    if (seq != _receiveBit) {
      duplicatesFromHost++;
      return;
    }
    _receiveBit ^= 1;
    dataMessagesFromHost++;

    switch (ThpControl.dataKind(c)) {
      case ThpControl.handshakeInitRequest:
        await _th1(message.data);
      case ThpControl.handshakeCompletionRequest:
        await _th2(message.data);
      case ThpControl.encryptedTransport:
        final plain = await _in!.decrypt(message.data);
        await _application(
          plain[0],
          readUint16BE(plain, 1),
          Uint8List.fromList(plain.sublist(3)),
        );
    }
  }

  void _deliver(ThpMessage m) {
    for (final p in m.toPackets(link.packetSize)) {
      link.deliver(p);
    }
  }

  void _sendData(int kind, Uint8List data) {
    _deliver(
      ThpMessage(kind | (_sendBit == 1 ? ThpControl.seqBit : 0), cid, data),
    );
    _sendBit ^= 1;
  }

  void _mixKey(Uint8List ikm) {
    final (ck, k) = ThpCrypto.hkdf(_ck, ikm);
    _ck = ck;
    _k = k;
  }

  Future<void> _th1(Uint8List req) async {
    final hostE = req.sublist(0, 32);
    final tryToUnlock = req.sublist(32, 33);
    _ePriv = randomBytes(32);
    final ePub = await ThpCrypto.x25519PublicKey(_ePriv);
    final sPub = await ThpCrypto.x25519PublicKey(staticPrivateKey);
    _h = ThpCrypto.sha256([...noiseProtocolName, ...properties]);
    _h = ThpCrypto.sha256([..._h, ...hostE]);
    _h = ThpCrypto.sha256([..._h, ...tryToUnlock]);
    _h = ThpCrypto.sha256([..._h, ...ePub]);
    _ck = noiseProtocolName;
    _mixKey(await ThpCrypto.x25519(_ePriv, hostE));
    final mask = ThpCrypto.sha256([...sPub, ...ePub]);
    final masked = await ThpCrypto.x25519(mask, sPub);
    final encStatic = await ThpCrypto.encrypt(_k, 0, _h, masked);
    _h = ThpCrypto.sha256([..._h, ...encStatic]);
    _mixKey(
      await ThpCrypto.x25519(
        mask,
        await ThpCrypto.x25519(staticPrivateKey, hostE),
      ),
    );
    final tag = await ThpCrypto.encrypt(_k, 0, _h, const []);
    _h = ThpCrypto.sha256([..._h, ...tag]);
    _sendData(
      ThpControl.handshakeInitResponse,
      concatBytes([ePub, encStatic, tag]),
    );
  }

  Future<void> _th2(Uint8List req) async {
    final encHostStatic = req.sublist(0, 48);
    final encPayload = req.sublist(48);
    _hostStatic = await ThpCrypto.decrypt(_k, 1, _h, encHostStatic);
    _h = ThpCrypto.sha256([..._h, ...encHostStatic]);
    _mixKey(await ThpCrypto.x25519(_ePriv, _hostStatic));
    final payload = await ThpCrypto.decrypt(_k, 0, _h, encPayload);
    _h = ThpCrypto.sha256([..._h, ...encPayload]);
    final credential = ProtoFields.decode(payload).bytes(1);
    _paired =
        credential != null &&
        bytesEqual(credential, ThpCrypto.hmacSha256(credAuthKey, _hostStatic));
    final (kReq, kResp) = ThpCrypto.hkdf(_ck, const []);
    _in = ThpCipherStateFake(kReq);
    _out = ThpCipherStateFake(kResp);
    _handshakeHash = _h;
    _sendData(
      ThpControl.handshakeCompletionResponse,
      await _out!.encrypt([_paired ? 1 : 0]),
    );
  }

  Future<void> _reply(int session, int type, Uint8List payload) async {
    _sendData(
      ThpControl.encryptedTransport,
      await _out!.encrypt(
        concatBytes([
          [session],
          uint16BE(type),
          payload,
        ]),
      ),
    );
  }

  Future<void> _application(int session, int type, Uint8List payload) async {
    final f = ProtoFields.decode(payload);
    switch (type) {
      case MessageType.thpPairingRequest:
        // TP0: ask the user, then approve once the host acks the button.
        _pendingAfterButton = Uint8List(0);
        await _reply(
          session,
          MessageType.buttonRequest,
          (ProtoWriter()..uint(1, 1)).toBytes(),
        );
      case MessageType.buttonAck:
        pairingConfirmationShown = true;
        final after = _pendingAfterButton;
        _pendingAfterButton = null;
        if (after != null) {
          await _reply(session, MessageType.thpPairingRequestApproved, after);
        }
      case MessageType.thpSelectMethod:
        _secret = randomBytes(16);
        await _reply(
          session,
          MessageType.thpCodeEntryCommitment,
          (ProtoWriter()..bytes(1, ThpCrypto.sha256(_secret!))).toBytes(),
        );
      case MessageType.thpCodeEntryChallenge:
        final challenge = f.bytes(1)!;
        final codeHash = ThpCrypto.sha256([
          2,
          ..._handshakeHash!,
          ..._secret!,
          ...challenge,
        ]);
        displayedCode = (bytesToBigIntBE(codeHash) % BigInt.from(1000000))
            .toString()
            .padLeft(6, '0');
        final generator = cpaceGenerator(
          prs: ascii.encode(displayedCode!),
          ci: _handshakeHash!,
        );
        _cpacePriv = randomBytes(32);
        await _reply(
          session,
          MessageType.thpCodeEntryCpaceTrezor,
          (ProtoWriter()
                ..bytes(1, await ThpCrypto.x25519(_cpacePriv!, generator)))
              .toBytes(),
        );
      case MessageType.thpCodeEntryCpaceHostTag:
        final shared = await ThpCrypto.x25519(_cpacePriv!, f.bytes(1)!);
        if (!bytesEqual(f.bytes(2)!, ThpCrypto.sha256(shared))) {
          await _reply(
            session,
            MessageType.failure,
            (ProtoWriter()
                  ..uint(1, 3)
                  ..string(2, 'bad tag'))
                .toBytes(),
          );
          return;
        }
        _paired = true;
        await _reply(
          session,
          MessageType.thpCodeEntrySecret,
          (ProtoWriter()..bytes(1, _secret!)).toBytes(),
        );
      case MessageType.thpCredentialRequest:
        final hostPub = f.bytes(1)!;
        await _reply(
          session,
          MessageType.thpCredentialResponse,
          (ProtoWriter()
                ..bytes(1, await ThpCrypto.x25519PublicKey(staticPrivateKey))
                ..bytes(2, ThpCrypto.hmacSha256(credAuthKey, hostPub)))
              .toBytes(),
        );
      case MessageType.thpEndRequest:
        await _reply(session, MessageType.thpEndResponse, Uint8List(0));
      case MessageType.getFeatures:
        await _reply(session, MessageType.features, encodeFeatures());
      case MessageType.thpCreateNewSession:
        await _reply(session, MessageType.success, Uint8List(0));
      case MessageType.ethereumGetAddress:
        await _reply(
          session,
          MessageType.ethereumAddress,
          (ProtoWriter()..string(2, 'session$session:${f.uints(1).join('/')}'))
              .toBytes(),
        );
      default:
        await _reply(
          session,
          MessageType.failure,
          (ProtoWriter()..uint(1, 1)).toBytes(),
        );
    }
  }
}

class ThpCipherStateFake {
  ThpCipherStateFake(this.key);
  final Uint8List key;
  int nonce = 0;
  Future<Uint8List> encrypt(List<int> p) =>
      ThpCrypto.encrypt(key, nonce++, const [], p);
  Future<Uint8List> decrypt(List<int> c) =>
      ThpCrypto.decrypt(key, nonce++, const [], c);
}
