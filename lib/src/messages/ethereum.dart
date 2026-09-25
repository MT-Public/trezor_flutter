import 'dart:typed_data';

import '../protobuf/proto.dart';
import 'common.dart';
import 'message.dart';

/// The `EthereumGetAddress` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class EthereumGetAddress extends TrezorMessage {
  const EthereumGetAddress({
    required this.addressN,
    this.showDisplay,
    this.encodedNetwork,
    this.chunkify,
  });

  final List<int> addressN;
  final bool? showDisplay;
  final Uint8List? encodedNetwork;
  final bool? chunkify;

  @override
  int get messageType => MessageType.ethereumGetAddress;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..repeatedUint(1, addressN)
            ..boolean(2, showDisplay)
            ..bytes(3, encodedNetwork)
            ..boolean(4, chunkify))
          .toBytes();
}

/// The `EthereumAddress` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class EthereumAddress extends TrezorMessage {
  const EthereumAddress(this.address);

  factory EthereumAddress.decode(ProtoFields f) =>
      EthereumAddress(f.string(2) ?? '');

  /// EIP-55 checksummed, `0x`-prefixed.
  final String address;

  @override
  int get messageType => MessageType.ethereumAddress;
}

/// The `EthereumGetPublicKey` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class EthereumGetPublicKey extends TrezorMessage {
  const EthereumGetPublicKey({required this.addressN, this.showDisplay});

  final List<int> addressN;
  final bool? showDisplay;

  @override
  int get messageType => MessageType.ethereumGetPublicKey;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..repeatedUint(1, addressN)
            ..boolean(2, showDisplay))
          .toBytes();
}

/// The `EthereumPublicKey` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class EthereumPublicKey extends TrezorMessage {
  const EthereumPublicKey({required this.node, required this.xpub});

  factory EthereumPublicKey.decode(ProtoFields f) => EthereumPublicKey(
    node: f.message(1, HDNodeType.decode)!,
    xpub: f.string(2) ?? '',
  );

  final HDNodeType node;
  final String xpub;

  @override
  int get messageType => MessageType.ethereumPublicKey;
}

/// Signed network/token definitions from `data.trezor.io`, needed for the
/// device to name chains and tokens it does not have built in.
class EthereumDefinitions implements ProtoEncodable {
  const EthereumDefinitions({this.encodedNetwork, this.encodedToken});

  final Uint8List? encodedNetwork;
  final Uint8List? encodedToken;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..bytes(1, encodedNetwork)
            ..bytes(2, encodedToken))
          .toBytes();
}

/// Legacy (type 0) and EIP-2930-less transactions.
///
/// All quantities are big-endian with no leading zeros; see
/// `bigIntToMinimalBytes`.
class EthereumSignTx extends TrezorMessage {
  const EthereumSignTx({
    required this.addressN,
    required this.nonce,
    required this.gasPrice,
    required this.gasLimit,
    required this.to,
    required this.value,
    required this.dataInitialChunk,
    required this.dataLength,
    required this.chainId,
    this.txType,
    this.definitions,
    this.chunkify,
  });

  final List<int> addressN;
  final Uint8List nonce;
  final Uint8List gasPrice;
  final Uint8List gasLimit;
  final String to;
  final Uint8List value;
  final Uint8List dataInitialChunk;
  final int dataLength;
  final int chainId;
  final int? txType;
  final EthereumDefinitions? definitions;
  final bool? chunkify;

  @override
  int get messageType => MessageType.ethereumSignTx;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..repeatedUint(1, addressN)
            ..bytes(2, nonce)
            ..bytes(3, gasPrice)
            ..bytes(4, gasLimit)
            ..bytes(6, value)
            ..bytes(7, dataInitialChunk)
            ..uint(8, dataLength)
            ..uint(9, chainId)
            ..uint(10, txType)
            ..string(11, to)
            ..message(12, definitions)
            ..boolean(13, chunkify))
          .toBytes();
}

class EthereumAccessListEntry implements ProtoEncodable {
  const EthereumAccessListEntry({
    required this.address,
    this.storageKeys = const [],
  });

  final String address;
  final List<Uint8List> storageKeys;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..string(1, address)
            ..repeatedBytes(2, storageKeys))
          .toBytes();
}

/// The `EthereumSignTxEip1559` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class EthereumSignTxEip1559 extends TrezorMessage {
  const EthereumSignTxEip1559({
    required this.addressN,
    required this.nonce,
    required this.maxGasFee,
    required this.maxPriorityFee,
    required this.gasLimit,
    required this.to,
    required this.value,
    required this.dataInitialChunk,
    required this.dataLength,
    required this.chainId,
    this.accessList = const [],
    this.definitions,
    this.chunkify,
  });

  final List<int> addressN;
  final Uint8List nonce;
  final Uint8List maxGasFee;
  final Uint8List maxPriorityFee;
  final Uint8List gasLimit;
  final String to;
  final Uint8List value;
  final Uint8List dataInitialChunk;
  final int dataLength;
  final int chainId;
  final List<EthereumAccessListEntry> accessList;
  final EthereumDefinitions? definitions;
  final bool? chunkify;

  @override
  int get messageType => MessageType.ethereumSignTxEip1559;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..repeatedUint(1, addressN)
            ..bytes(2, nonce)
            ..bytes(3, maxGasFee)
            ..bytes(4, maxPriorityFee)
            ..bytes(5, gasLimit)
            ..string(6, to)
            ..bytes(7, value)
            ..bytes(8, dataInitialChunk)
            ..uint(9, dataLength)
            ..uint(10, chainId)
            ..repeatedMessage(11, accessList)
            ..message(12, definitions)
            ..boolean(13, chunkify))
          .toBytes();
}

/// Either a request for the next [dataLength] bytes of calldata, or — once
/// [signatureR] is present — the final signature.
class EthereumTxRequest extends TrezorMessage {
  const EthereumTxRequest({
    this.dataLength,
    this.signatureV,
    this.signatureR,
    this.signatureS,
  });

  factory EthereumTxRequest.decode(ProtoFields f) => EthereumTxRequest(
    dataLength: f.uint(1),
    signatureV: f.uint(2),
    signatureR: f.bytes(3),
    signatureS: f.bytes(4),
  );

  final int? dataLength;
  final int? signatureV;
  final Uint8List? signatureR;
  final Uint8List? signatureS;

  @override
  int get messageType => MessageType.ethereumTxRequest;
}

/// The `EthereumTxAck` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class EthereumTxAck extends TrezorMessage {
  const EthereumTxAck(this.dataChunk);

  final Uint8List dataChunk;

  @override
  int get messageType => MessageType.ethereumTxAck;

  @override
  Uint8List encode() => (ProtoWriter()..bytes(1, dataChunk)).toBytes();
}

/// The `EthereumSignMessage` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class EthereumSignMessage extends TrezorMessage {
  const EthereumSignMessage({
    required this.addressN,
    required this.message,
    this.encodedNetwork,
    this.chunkify,
  });

  final List<int> addressN;
  final Uint8List message;
  final Uint8List? encodedNetwork;
  final bool? chunkify;

  @override
  int get messageType => MessageType.ethereumSignMessage;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..repeatedUint(1, addressN)
            ..bytes(2, message)
            ..bytes(3, encodedNetwork)
            ..boolean(4, chunkify))
          .toBytes();
}

/// The `EthereumMessageSignature` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class EthereumMessageSignature extends TrezorMessage {
  const EthereumMessageSignature({
    required this.signature,
    required this.address,
  });

  factory EthereumMessageSignature.decode(ProtoFields f) =>
      EthereumMessageSignature(
        signature: f.bytes(2) ?? Uint8List(0),
        address: f.string(3) ?? '',
      );

  /// 65 bytes: r ‖ s ‖ v, with v = 27 or 28.
  final Uint8List signature;
  final String address;

  @override
  int get messageType => MessageType.ethereumMessageSignature;
}

/// EIP-712 by hash. Models with a screen that can parse typed data also
/// support the structured `EthereumSignTypedData` flow; the hash variant works
/// on all of them (Model One *requires* it).
class EthereumSignTypedHash extends TrezorMessage {
  const EthereumSignTypedHash({
    required this.addressN,
    required this.domainSeparatorHash,
    this.messageHash,
    this.encodedNetwork,
  });

  final List<int> addressN;
  final Uint8List domainSeparatorHash;
  final Uint8List? messageHash;
  final Uint8List? encodedNetwork;

  @override
  int get messageType => MessageType.ethereumSignTypedHash;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..repeatedUint(1, addressN)
            ..bytes(2, domainSeparatorHash)
            ..bytes(3, messageHash)
            ..bytes(4, encodedNetwork))
          .toBytes();
}

/// The `EthereumTypedDataSignature` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class EthereumTypedDataSignature extends TrezorMessage {
  const EthereumTypedDataSignature({
    required this.signature,
    required this.address,
  });

  factory EthereumTypedDataSignature.decode(ProtoFields f) =>
      EthereumTypedDataSignature(
        signature: f.bytes(1) ?? Uint8List(0),
        address: f.string(2) ?? '',
      );

  final Uint8List signature;
  final String address;

  @override
  int get messageType => MessageType.ethereumTypedDataSignature;
}
