import 'dart:typed_data';

import '../protobuf/proto.dart';
import 'common.dart';
import 'message.dart';

/// `InputScriptType`: which address/xpub flavour to derive.
enum BitcoinScriptType {
  /// P2PKH, `1…` addresses, `xpub`.
  spendAddress(0),

  /// P2WPKH native segwit, `bc1q…` addresses, `zpub`.
  spendWitness(3),

  /// P2SH-P2WPKH nested segwit, `3…` addresses, `ypub`.
  spendP2shWitness(4),

  /// P2TR taproot, `bc1p…` addresses.
  spendTaproot(5);

  const BitcoinScriptType(this.value);

  final int value;
}

/// The `GetPublicKey` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class GetPublicKey extends TrezorMessage {
  const GetPublicKey({
    required this.addressN,
    this.coinName,
    this.scriptType,
    this.showDisplay,
    this.ignoreXpubMagic,
  });

  final List<int> addressN;
  final String? coinName;
  final BitcoinScriptType? scriptType;
  final bool? showDisplay;
  final bool? ignoreXpubMagic;

  @override
  int get messageType => MessageType.getPublicKey;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..repeatedUint(1, addressN)
            ..boolean(3, showDisplay)
            ..string(4, coinName)
            ..uint(5, scriptType?.value)
            ..boolean(6, ignoreXpubMagic))
          .toBytes();
}

/// The `PublicKey` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class PublicKey extends TrezorMessage {
  const PublicKey({
    required this.node,
    required this.xpub,
    this.rootFingerprint,
    this.descriptor,
  });

  factory PublicKey.decode(ProtoFields f) => PublicKey(
    node: f.message(1, HDNodeType.decode)!,
    xpub: f.string(2) ?? '',
    rootFingerprint: f.uint(3),
    descriptor: f.string(4),
  );

  final HDNodeType node;
  final String xpub;
  final int? rootFingerprint;
  final String? descriptor;

  @override
  int get messageType => MessageType.publicKey;
}

/// The `GetAddress` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class GetAddress extends TrezorMessage {
  const GetAddress({
    required this.addressN,
    this.coinName,
    this.showDisplay,
    this.scriptType,
    this.chunkify,
  });

  final List<int> addressN;
  final String? coinName;
  final bool? showDisplay;
  final BitcoinScriptType? scriptType;
  final bool? chunkify;

  @override
  int get messageType => MessageType.getAddress;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..repeatedUint(1, addressN)
            ..string(2, coinName)
            ..boolean(3, showDisplay)
            ..uint(5, scriptType?.value)
            ..boolean(7, chunkify))
          .toBytes();
}

/// The `Address` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class Address extends TrezorMessage {
  const Address(this.address);

  factory Address.decode(ProtoFields f) => Address(f.string(1) ?? '');

  final String address;

  @override
  int get messageType => MessageType.address;
}
