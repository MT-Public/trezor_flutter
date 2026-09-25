/// Protobuf message classes, for sending requests the chain helpers in
/// `package:trezor_flutter/trezor_flutter.dart` do not cover:
///
/// ```dart
/// import 'package:trezor_flutter/messages.dart' as msg;
///
/// final pong = await trezor.callExpect<msg.Success>(msg.Ping(message: 'hi'));
/// ```
///
/// Kept out of the main library because several names (`EthereumAddress`,
/// `PublicKey`, `Address`, …) are generic enough to clash with other
/// packages; import this one with a prefix.
library;

export 'src/messages/bitcoin.dart';
export 'src/messages/common.dart';
export 'src/messages/ethereum.dart';
export 'src/messages/management.dart';
export 'src/messages/message.dart';
export 'src/messages/solana.dart';
export 'src/messages/thp.dart';
export 'src/messages/tron.dart';
