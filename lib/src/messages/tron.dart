import 'dart:typed_data';

import '../protobuf/proto.dart';
import 'message.dart';

/// The `TronGetAddress` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class TronGetAddress extends TrezorMessage {
  const TronGetAddress({
    required this.addressN,
    this.showDisplay,
    this.chunkify,
  });

  final List<int> addressN;
  final bool? showDisplay;
  final bool? chunkify;

  @override
  int get messageType => MessageType.tronGetAddress;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..repeatedUint(1, addressN)
            ..boolean(2, showDisplay)
            ..boolean(3, chunkify))
          .toBytes();
}

/// The `TronAddress` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class TronAddress extends TrezorMessage {
  const TronAddress(this.address);

  factory TronAddress.decode(ProtoFields f) => TronAddress(f.string(1) ?? '');

  /// Base58check, `T…`.
  final String address;

  @override
  int get messageType => MessageType.tronAddress;
}

/// Starts Tron signing with the contract-agnostic transaction fields. The
/// device answers with [TronContractRequest], then takes one contract
/// message (e.g. [TronTransferContract]) and returns [TronSignature].
class TronSignTx extends TrezorMessage {
  const TronSignTx({
    required this.addressN,
    required this.refBlockBytes,
    required this.refBlockHash,
    required this.expiration,
    required this.timestamp,
    this.data,
    this.feeLimit,
    this.chunkify,
  });

  final List<int> addressN;
  final Uint8List refBlockBytes;
  final Uint8List refBlockHash;
  final int expiration;
  final int timestamp;

  /// Memo, at most 256 bytes on Trezor.
  final Uint8List? data;

  /// Energy cost ceiling in SUN; smart-contract calls only.
  final int? feeLimit;
  final bool? chunkify;

  @override
  int get messageType => MessageType.tronSignTx;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..repeatedUint(1, addressN)
            ..bytes(2, refBlockBytes)
            ..bytes(3, refBlockHash)
            ..uint(4, expiration)
            ..bytes(5, data)
            ..uint(6, timestamp)
            ..uint(7, feeLimit)
            ..boolean(8, chunkify))
          .toBytes();
}

/// The device is ready for the contract message.
class TronContractRequest extends TrezorMessage {
  const TronContractRequest();

  @override
  int get messageType => MessageType.tronContractRequest;
}

/// Native TRX transfer. Addresses are 21 raw bytes (`0x41` + 20).
class TronTransferContract extends TrezorMessage {
  const TronTransferContract({
    required this.ownerAddress,
    required this.toAddress,
    required this.amount,
  });

  final Uint8List ownerAddress;
  final Uint8List toAddress;

  /// In SUN.
  final int amount;

  @override
  int get messageType => MessageType.tronTransferContract;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..bytes(1, ownerAddress)
            ..bytes(2, toAddress)
            ..uint(3, amount))
          .toBytes();
}

/// Smart-contract call, e.g. a TRC-20 `transfer`. TRC-10 is not supported.
class TronTriggerSmartContract extends TrezorMessage {
  const TronTriggerSmartContract({
    required this.ownerAddress,
    required this.contractAddress,
    required this.data,
    this.callValue,
  });

  final Uint8List ownerAddress;
  final Uint8List contractAddress;

  /// ABI-encoded call.
  final Uint8List data;

  /// TRX sent along, in SUN. Omit (not 0) when none: Tron hashes proto3,
  /// where a zero value is absent.
  final int? callValue;

  @override
  int get messageType => MessageType.tronTriggerSmartContract;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..bytes(1, ownerAddress)
            ..bytes(2, contractAddress)
            ..uint(3, callValue)
            ..bytes(4, data))
          .toBytes();
}

/// Any other supported Tron contract (staking, voting, delegation,
/// withdrawals), carried as its already-encoded protobuf body. Built by
/// `TrezorTron.tronSignRawTransaction` from TronGrid `raw_data`.
class TronContractMessage extends TrezorMessage {
  const TronContractMessage(this.messageType, this.body);

  @override
  final int messageType;
  final Uint8List body;

  @override
  Uint8List encode() => body;
}

/// 65 bytes: r ‖ s ‖ v, with v = 27 or 28.
class TronSignature extends TrezorMessage {
  const TronSignature(this.signature);

  factory TronSignature.decode(ProtoFields f) =>
      TronSignature(f.bytes(1) ?? Uint8List(0));

  final Uint8List signature;

  @override
  int get messageType => MessageType.tronSignature;
}
