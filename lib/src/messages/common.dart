import 'dart:typed_data';

import '../protobuf/proto.dart';
import 'message.dart';

/// The `Success` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class Success extends TrezorMessage {
  const Success([this.message = '']);

  factory Success.decode(ProtoFields f) => Success(f.string(1) ?? '');

  final String message;

  @override
  int get messageType => MessageType.success;
}

/// The `Failure` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class Failure extends TrezorMessage {
  const Failure({this.code, this.message});

  factory Failure.decode(ProtoFields f) =>
      Failure(code: f.uint(1), message: f.string(2));

  final int? code;
  final String? message;

  @override
  int get messageType => MessageType.failure;

  @override
  String toString() => 'Failure($code, $message)';
}

/// The `Cancel` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class Cancel extends TrezorMessage {
  const Cancel();

  @override
  int get messageType => MessageType.cancel;
}

/// `ButtonRequest.ButtonRequestType`.
abstract final class ButtonRequestType {
  static const other = 1;
  static const feeOverThreshold = 2;
  static const confirmOutput = 3;
  static const resetDevice = 4;
  static const confirmWord = 5;
  static const wipeDevice = 6;
  static const protectCall = 7;
  static const signTx = 8;
  static const firmwareCheck = 9;
  static const address = 10;
  static const publicKey = 11;
  static const mnemonicWordCount = 12;
  static const mnemonicInput = 13;
  static const unknownDerivationPath = 15;
  static const recoveryHomepage = 16;
  static const success = 17;
  static const warning = 18;
  static const passphraseEntry = 19;
  static const pinEntry = 20;
}

/// The device is waiting for the user to act on its screen. The host answers
/// with [ButtonAck] straight away; the user's decision arrives as the next
/// message.
class ButtonRequest extends TrezorMessage {
  const ButtonRequest({this.code, this.pages, this.name});

  factory ButtonRequest.decode(ProtoFields f) =>
      ButtonRequest(code: f.uint(1), pages: f.uint(2), name: f.string(4));

  final int? code;
  final int? pages;
  final String? name;

  @override
  int get messageType => MessageType.buttonRequest;

  @override
  String toString() => 'ButtonRequest($code, $name)';
}

/// The `ButtonAck` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class ButtonAck extends TrezorMessage {
  const ButtonAck();

  @override
  int get messageType => MessageType.buttonAck;
}

/// `PinMatrixRequest.PinMatrixRequestType`.
abstract final class PinMatrixRequestType {
  static const current = 1;
  static const newFirst = 2;
  static const newSecond = 3;
  static const wipeCodeFirst = 4;
  static const wipeCodeSecond = 5;
}

/// Trezor Model One only: the device shows a scrambled 3×3 grid and the host
/// sends back grid positions, never the PIN digits themselves. Touchscreen
/// models take the PIN on the device and never send this.
class PinMatrixRequest extends TrezorMessage {
  const PinMatrixRequest({this.type});

  factory PinMatrixRequest.decode(ProtoFields f) =>
      PinMatrixRequest(type: f.uint(1));

  final int? type;

  @override
  int get messageType => MessageType.pinMatrixRequest;
}

/// The `PinMatrixAck` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class PinMatrixAck extends TrezorMessage {
  const PinMatrixAck(this.pin);

  final String pin;

  @override
  int get messageType => MessageType.pinMatrixAck;

  @override
  Uint8List encode() => (ProtoWriter()..string(1, pin)).toBytes();
}

/// The `PassphraseRequest` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class PassphraseRequest extends TrezorMessage {
  const PassphraseRequest();

  @override
  int get messageType => MessageType.passphraseRequest;
}

/// The `PassphraseAck` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class PassphraseAck extends TrezorMessage {
  const PassphraseAck({this.passphrase, this.onDevice});

  final String? passphrase;
  final bool? onDevice;

  @override
  int get messageType => MessageType.passphraseAck;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..string(1, passphrase)
            ..boolean(3, onDevice))
          .toBytes();
}

class HDNodeType {
  const HDNodeType({
    required this.depth,
    required this.fingerprint,
    required this.childNum,
    required this.chainCode,
    required this.publicKey,
  });

  factory HDNodeType.decode(ProtoFields f) => HDNodeType(
    depth: f.uint(1) ?? 0,
    fingerprint: f.uint(2) ?? 0,
    childNum: f.uint(3) ?? 0,
    chainCode: f.bytes(4) ?? Uint8List(0),
    publicKey: f.bytes(6) ?? Uint8List(0),
  );

  final int depth;
  final int fingerprint;
  final int childNum;
  final Uint8List chainCode;

  /// Compressed secp256k1 public key (33 bytes) for Bitcoin/Ethereum nodes.
  final Uint8List publicKey;
}
