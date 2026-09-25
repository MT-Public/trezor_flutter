import 'dart:typed_data';

/// One decoded-enough message: its type id and protobuf body.
class RawMessage {
  const RawMessage(this.type, this.payload, {this.sessionId = 0});

  final int type;
  final Uint8List payload;

  /// THP session byte; always 0 for Codec v1.
  final int sessionId;
}

/// A message-level protocol running over a packet link.
///
/// Implementations own the link's packet stream for as long as they live and
/// release it on [dispose], so a probe with one wire can hand over to another.
abstract class TrezorWire {
  Future<void> send(RawMessage message);

  /// Next message for [sessionId]. `timeout: null` waits indefinitely — the
  /// device may be sitting on a confirmation screen — but still fails
  /// promptly if the link drops.
  Future<RawMessage> receive({int sessionId = 0, Duration? timeout});

  Future<void> dispose();
}
