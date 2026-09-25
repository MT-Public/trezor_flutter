import 'dart:typed_data';

import '../protobuf/proto.dart';
import 'message.dart';

/// The `SolanaGetAddress` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class SolanaGetAddress extends TrezorMessage {
  const SolanaGetAddress({
    required this.addressN,
    this.showDisplay,
    this.chunkify,
  });

  final List<int> addressN;
  final bool? showDisplay;
  final bool? chunkify;

  @override
  int get messageType => MessageType.solanaGetAddress;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..repeatedUint(1, addressN)
            ..boolean(2, showDisplay)
            ..boolean(3, chunkify))
          .toBytes();
}

/// The `SolanaAddress` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class SolanaAddress extends TrezorMessage {
  const SolanaAddress(this.address);

  factory SolanaAddress.decode(ProtoFields f) =>
      SolanaAddress(f.string(1) ?? '');

  /// Base58 public key.
  final String address;

  @override
  int get messageType => MessageType.solanaAddress;
}

/// The `SolanaGetPublicKey` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class SolanaGetPublicKey extends TrezorMessage {
  const SolanaGetPublicKey({required this.addressN, this.showDisplay});

  final List<int> addressN;
  final bool? showDisplay;

  @override
  int get messageType => MessageType.solanaGetPublicKey;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..repeatedUint(1, addressN)
            ..boolean(2, showDisplay))
          .toBytes();
}

/// The `SolanaPublicKey` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class SolanaPublicKey extends TrezorMessage {
  const SolanaPublicKey(this.publicKey);

  factory SolanaPublicKey.decode(ProtoFields f) =>
      SolanaPublicKey(f.bytes(1) ?? Uint8List(0));

  /// Raw 32-byte ed25519 public key.
  final Uint8List publicKey;

  @override
  int get messageType => MessageType.solanaPublicKey;
}

/// The `SolanaSignTx` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class SolanaSignTx extends TrezorMessage {
  const SolanaSignTx({
    required this.addressN,
    required this.serializedTx,
    this.chunkify,
  });

  final List<int> addressN;

  /// The serialized transaction *message* (what gets signed), not a full
  /// signed transaction.
  final Uint8List serializedTx;
  final bool? chunkify;

  @override
  int get messageType => MessageType.solanaSignTx;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..repeatedUint(1, addressN)
            ..bytes(2, serializedTx)
            ..boolean(5, chunkify))
          .toBytes();
}

/// The `SolanaTxSignature` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class SolanaTxSignature extends TrezorMessage {
  const SolanaTxSignature(this.signature);

  factory SolanaTxSignature.decode(ProtoFields f) =>
      SolanaTxSignature(f.bytes(1) ?? Uint8List(0));

  /// 64-byte ed25519 signature.
  final Uint8List signature;

  @override
  int get messageType => MessageType.solanaTxSignature;
}
