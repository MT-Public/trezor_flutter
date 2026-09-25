import 'dart:collection';
import 'dart:typed_data';

import '../../util/bytes.dart';
import '../wire.dart';
import 'thp_channel.dart';

/// THP application layer: `session_id:u8 ‖ message_type:u16be ‖ protobuf`,
/// encrypted by the channel.
///
/// Messages for a session nobody is currently reading are parked until it
/// is, so a late reply on the seedless session cannot be mistaken for one on
/// the wallet session.
class ThpWire implements TrezorWire {
  ThpWire(this.channel);

  final ThpChannel channel;
  final Map<int, Queue<RawMessage>> _parked = {};

  @override
  Future<void> send(RawMessage message) => channel.sendEncrypted(
    concatBytes([
      [message.sessionId & 0xFF],
      uint16BE(message.type),
      message.payload,
    ]),
  );

  @override
  Future<RawMessage> receive({int sessionId = 0, Duration? timeout}) async {
    final parked = _parked[sessionId];
    if (parked != null && parked.isNotEmpty) return parked.removeFirst();
    while (true) {
      final plaintext = await channel.receiveEncrypted(timeout: timeout);
      if (plaintext.length < 3) continue;
      final message = RawMessage(
        readUint16BE(plaintext, 1),
        Uint8List.fromList(plaintext.sublist(3)),
        sessionId: plaintext[0],
      );
      if (message.sessionId == sessionId) return message;
      (_parked[message.sessionId] ??= Queue()).add(message);
    }
  }

  @override
  Future<void> dispose() => channel.dispose();
}
