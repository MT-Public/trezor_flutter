import 'dart:typed_data';

import '../../util/bytes.dart';

/// Control-byte values and masks from the THP specification.
abstract final class ThpControl {
  static const continuation = 0x80;

  static const channelAllocationRequest = 0x40;
  static const channelAllocationResponse = 0x41;
  static const transportError = 0x42;
  static const ping = 0x43;
  static const pong = 0x44;
  static const codecV1 = 0x3F;

  static const ackMask = 0xF7;
  static const ack = 0x20;
  static const ackBit = 0x08;

  static const dataMask = 0xE7;
  static const handshakeInitRequest = 0x00;
  static const handshakeInitResponse = 0x01;
  static const handshakeCompletionRequest = 0x02;
  static const handshakeCompletionResponse = 0x03;
  static const encryptedTransport = 0x04;
  static const seqBit = 0x10;

  static bool isContinuation(int c) => c & continuation != 0;
  static bool isAck(int c) => c & ackMask == ack;

  /// Data messages take part in the Alternating Bit Protocol.
  static bool isData(int c) => c & 0xE0 == 0x00;
  static int dataKind(int c) => c & dataMask;
  static int seqOf(int c) => (c & seqBit) != 0 ? 1 : 0;
  static int ackOf(int c) => (c & ackBit) != 0 ? 1 : 0;
}

const int broadcastChannelId = 0xFFFF;

/// One reassembled THP transport payload (CRC already verified and removed).
class ThpMessage {
  const ThpMessage(this.control, this.channelId, this.data);

  final int control;
  final int channelId;
  final Uint8List data;

  /// Header ‖ data ‖ CRC-32 — the "transport payload with CRC" plus header.
  Uint8List toBytes() {
    final header = concatBytes([
      [control],
      uint16BE(channelId),
      uint16BE(data.length + 4),
    ]);
    final checked = concatBytes([header, data]);
    return concatBytes([checked, uint32BE(crc32(checked))]);
  }

  /// Splits into packets: the first carries the 5-byte header, continuations
  /// carry `0x80 ‖ cid`; the last one is zero-padded.
  List<Uint8List> toPackets(int packetSize) {
    final bytes = toBytes();
    final packets = <Uint8List>[];
    final first = Uint8List(packetSize);
    final firstLen = bytes.length < packetSize ? bytes.length : packetSize;
    first.setRange(0, firstLen, bytes);
    packets.add(first);
    var offset = firstLen;
    final chunk = packetSize - 3;
    while (offset < bytes.length) {
      final packet = Uint8List(packetSize);
      packet[0] = ThpControl.continuation;
      packet[1] = (channelId >> 8) & 0xFF;
      packet[2] = channelId & 0xFF;
      final n = (bytes.length - offset) < chunk ? bytes.length - offset : chunk;
      packet.setRange(3, 3 + n, bytes, offset);
      packets.add(packet);
      offset += n;
    }
    return packets;
  }
}

/// Reassembles packets into [ThpMessage]s, one payload per channel at a time.
///
/// Packets with a bad CRC are dropped: the sender retransmits when no ACK
/// arrives, which is how THP recovers from corruption.
class ThpAssembler {
  final Map<int, _Partial> _partials = {};

  /// Returns a completed message, or null if more packets are needed or the
  /// packet was discarded.
  ThpMessage? add(Uint8List packet) {
    if (packet.length < 3) return null;
    final control = packet[0];
    final cid = readUint16BE(packet, 1);

    if (ThpControl.isContinuation(control)) {
      final partial = _partials[cid];
      if (partial == null) return null; // unexpected continuation
      partial.buffer.add(packet.sublist(3));
      return _tryComplete(cid, partial);
    }

    if (packet.length < 5) return null;
    final length = readUint16BE(packet, 3);
    if (length < 4) return null;
    // A new initiation packet discards any unfinished payload on its channel.
    final partial = _Partial(control, length)..buffer.add(packet.sublist(5));
    _partials[cid] = partial;
    return _tryComplete(cid, partial);
  }

  ThpMessage? _tryComplete(int cid, _Partial partial) {
    if (partial.buffer.length < partial.length) return null;
    _partials.remove(cid);
    final payload = partial.buffer.toBytes().sublist(0, partial.length);
    final data = Uint8List.fromList(payload.sublist(0, payload.length - 4));
    final received = readUint32BE(payload, payload.length - 4);
    final checked = concatBytes([
      [partial.control],
      uint16BE(cid),
      uint16BE(partial.length),
      data,
    ]);
    if (crc32(checked) != received) return null;
    return ThpMessage(partial.control, cid, data);
  }

  void reset() => _partials.clear();
}

class _Partial {
  _Partial(this.control, this.length);
  final int control;
  final int length;
  final BytesBuilder buffer = BytesBuilder();
}

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

/// CRC-32/IEEE (zlib's `crc32`).
int crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
