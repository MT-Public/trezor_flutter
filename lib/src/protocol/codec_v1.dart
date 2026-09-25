import 'dart:async';
import 'dart:typed_data';

import '../exceptions.dart';
import '../link/trezor_link.dart';
import '../util/async_queue.dart';
import '../util/bytes.dart';
import 'wire.dart';

/// Codec v1: the unencrypted protocol spoken by Trezor Model One, Model T,
/// Safe 3 and Safe 5 over USB.
///
/// A message is `"##" ‖ type:u16be ‖ length:u32be ‖ protobuf`, cut into
/// packets that each start with `'?'` and are zero-padded to the packet size.
class CodecV1Wire implements TrezorWire {
  CodecV1Wire(this._link) {
    _subscription = _link.packets.listen(
      _onPacket,
      onError: (Object e, StackTrace s) => _inbox.fail(e, s),
      onDone: () => _inbox.fail(const TrezorDisconnectedException()),
    );
  }

  static const int _magic = 0x3F; // '?'
  static const int _hash = 0x23; // '#'
  static const int _headerLength = 8; // "##" + type + length

  final TrezorLink _link;
  final AsyncQueue<RawMessage> _inbox = AsyncQueue();
  final AsyncLock _writeLock = AsyncLock();
  late final StreamSubscription<Uint8List> _subscription;

  // Reassembly state.
  int? _type;
  int _expected = 0;
  BytesBuilder? _buffer;

  static List<Uint8List> encodePackets(
    int type,
    Uint8List payload,
    int packetSize,
  ) {
    final body = concatBytes([
      [_hash, _hash],
      uint16BE(type),
      uint32BE(payload.length),
      payload,
    ]);
    final chunk = packetSize - 1;
    final packets = <Uint8List>[];
    for (var offset = 0; offset < body.length; offset += chunk) {
      final packet = Uint8List(packetSize);
      packet[0] = _magic;
      final end = (offset + chunk).clamp(0, body.length);
      packet.setRange(1, 1 + end - offset, body, offset);
      packets.add(packet);
    }
    return packets;
  }

  void _onPacket(Uint8List packet) {
    if (packet.isEmpty || packet[0] != _magic) return;
    final buffer = _buffer;
    if (buffer == null) {
      // Expect a first packet; anything else is a stale continuation.
      if (packet.length < 1 + _headerLength ||
          packet[1] != _hash ||
          packet[2] != _hash) {
        return;
      }
      _type = readUint16BE(packet, 3);
      _expected = readUint32BE(packet, 5);
      _buffer = BytesBuilder()..add(packet.sublist(1 + _headerLength));
    } else {
      buffer.add(packet.sublist(1));
    }
    final current = _buffer!;
    if (current.length >= _expected) {
      final data = current.toBytes().sublist(0, _expected);
      _inbox.add(RawMessage(_type!, Uint8List.fromList(data)));
      _buffer = null;
      _type = null;
    }
  }

  @override
  Future<void> send(RawMessage message) => _writeLock.run(() async {
    for (final packet in encodePackets(
      message.type,
      message.payload,
      _link.packetSize,
    )) {
      await _link.write(packet);
    }
  });

  @override
  Future<RawMessage> receive({int sessionId = 0, Duration? timeout}) =>
      _inbox.next(timeout: timeout);

  /// Drops anything the device sent before we started talking, e.g. the tail
  /// of a response to a previous app's request.
  void discardPending() {
    _inbox.clear();
    _buffer = null;
  }

  @override
  Future<void> dispose() async {
    await _subscription.cancel();
    _inbox.fail(const TrezorDisconnectedException('Wire disposed'));
  }
}
