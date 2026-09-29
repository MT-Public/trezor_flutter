import 'dart:convert';
import 'dart:typed_data';

import '../client/trezor_client.dart';
import '../exceptions.dart';
import '../messages/message.dart';
import '../messages/tron.dart';
import '../protobuf/proto.dart';
import '../util/bip32_path.dart';
import '../util/bytes.dart';

/// Tron calls on a connected Trezor (Model T, Safe 3/5/7 with Tron-capable
/// firmware — check `features.hasCapability(TrezorCapability.tron)`).
///
/// Trezor does not sign opaque bytes for Tron: it is sent the transaction as
/// fields, rebuilds `raw_data` itself, and signs the SHA-256 of that. So a
/// signature is only valid for the transaction the app broadcasts if the
/// device's rebuild is byte-identical to it — which
/// [tronSignRawTransaction] checks before anything is sent to the device.
extension TrezorTron on TrezorClient {
  /// Base58check `T…` address.
  Future<String> tronGetAddress(
    String path, {
    bool showOnDevice = false,
  }) async {
    final response = await callWallet<TronAddress>(
      TronGetAddress(addressN: parseBip32Path(path), showDisplay: showOnDevice),
    );
    return response.address;
  }

  /// Signs a transaction given as its serialized `raw_data` — what TronGrid
  /// returns as `raw_data_hex` from `createtransaction`,
  /// `triggersmartcontract` and the staking endpoints.
  ///
  /// Returns 65 bytes, r ‖ s ‖ v (v = 27/28), for the transaction's
  /// `signature` list. Throws [TrezorProtocolException] if the transaction
  /// uses something Trezor cannot reproduce exactly (multi-contract,
  /// permission ids, TRC-10 call fields, …).
  Future<Uint8List> tronSignRawTransaction(String path, Uint8List rawData) {
    final parsed = TronRawTransactionParser.parse(rawData);
    return tronSignTransaction(
      TronSignTx(
        addressN: parseBip32Path(path),
        refBlockBytes: parsed.refBlockBytes,
        refBlockHash: parsed.refBlockHash,
        expiration: parsed.expiration,
        timestamp: parsed.timestamp,
        data: parsed.data,
        feeLimit: parsed.feeLimit,
      ),
      parsed.contract,
    );
  }

  /// Signs from explicit fields: [tx] then [contract] (e.g. a
  /// [TronTransferContract]). Returns the 65-byte signature.
  Future<Uint8List> tronSignTransaction(
    TronSignTx tx,
    TrezorMessage contract,
  ) async {
    await callWallet<TronContractRequest>(tx);
    final response = await callWallet<TronSignature>(contract);
    if (response.signature.length != 65) {
      throw TrezorProtocolException(
        'Tron signature has ${response.signature.length} bytes, expected 65',
      );
    }
    return response.signature;
  }
}

/// The parts of a Tron `raw_data` that Trezor signs from.
class TronParsedTransaction {
  const TronParsedTransaction({
    required this.refBlockBytes,
    required this.refBlockHash,
    required this.expiration,
    required this.timestamp,
    required this.contract,
    this.data,
    this.feeLimit,
  });

  final Uint8List refBlockBytes;
  final Uint8List refBlockHash;
  final int expiration;
  final int timestamp;
  final Uint8List? data;
  final int? feeLimit;

  /// The single contract, as the Trezor message that carries it.
  final TrezorMessage contract;
}

/// Converts Tron `raw_data` into Trezor's messages and proves the device will
/// rebuild exactly the same bytes.
abstract final class TronRawTransactionParser {
  static const _typeUrlPrefix = 'type.googleapis.com/protocol.';

  /// raw contract type → (Trezor message type, contract name, allowed fields)
  static const _contracts = <int, (int, String, Set<int>)>{
    1: (MessageType.tronTransferContract, 'TransferContract', {1, 2, 3}),
    4: (MessageType.tronVoteWitnessContract, 'VoteWitnessContract', {1, 2}),
    13: (MessageType.tronWithdrawBalance, 'WithdrawBalanceContract', {1}),
    31: (
      MessageType.tronTriggerSmartContract,
      'TriggerSmartContract',
      {1, 2, 3, 4},
    ),
    54: (
      MessageType.tronFreezeBalanceV2Contract,
      'FreezeBalanceV2Contract',
      {1, 2, 3},
    ),
    55: (
      MessageType.tronUnfreezeBalanceV2Contract,
      'UnfreezeBalanceV2Contract',
      {1, 2, 3},
    ),
    56: (
      MessageType.tronWithdrawUnfreeze,
      'WithdrawExpireUnfreezeContract',
      {1},
    ),
    57: (
      MessageType.tronDelegateResourceContract,
      'DelegateResourceContract',
      {1, 2, 3, 4, 5, 6},
    ),
    58: (
      MessageType.tronUnDelegateResourceContract,
      'UnDelegateResourceContract',
      {1, 2, 3, 4},
    ),
  };

  /// `raw_data` fields Trezor sends back to itself when rebuilding.
  static const _txFields = {1, 4, 8, 10, 11, 14, 18};

  static TronParsedTransaction parse(Uint8List rawData) {
    final tx = ProtoFields.decode(rawData);
    _onlyFields(tx, _txFields, 'transaction');

    final contracts = tx.bytesList(11);
    if (contracts.length != 1) {
      throw const TrezorProtocolException(
        'Trezor signs single-contract Tron transactions only',
      );
    }
    final contract = ProtoFields.decode(contracts.single);
    _onlyFields(contract, {1, 2}, 'contract');
    final type = contract.uint(1) ?? 0;
    final spec = _contracts[type];
    if (spec == null) {
      throw TrezorProtocolException(
        'Tron contract type $type is not supported',
      );
    }
    final (messageType, name, allowed) = spec;

    final parameter = ProtoFields.decode(contract.bytes(2) ?? Uint8List(0));
    _onlyFields(parameter, {1, 2}, 'contract parameter');
    if (parameter.string(1) != '$_typeUrlPrefix$name') {
      throw TrezorProtocolException(
        'Unexpected Tron contract type URL ${parameter.string(1)}',
      );
    }
    final value = ProtoFields.decode(parameter.bytes(2) ?? Uint8List(0));
    _onlyFields(value, allowed, name);

    final body = _reencode(value, allowed);
    final parsed = TronParsedTransaction(
      refBlockBytes: tx.bytes(1) ?? Uint8List(0),
      refBlockHash: tx.bytes(4) ?? Uint8List(0),
      expiration: tx.uint(8) ?? 0,
      timestamp: tx.uint(14) ?? 0,
      data: tx.bytes(10),
      feeLimit: tx.uint(18),
      contract: TronContractMessage(messageType, body),
    );

    // The device rebuilds raw_data from these fields and signs its hash. If
    // that rebuild differs from what will be broadcast by even one byte (a
    // non-canonical encoding, an unexpected default), the signature is for a
    // different transaction — refuse now rather than after the user approved.
    final rebuilt = _rebuild(parsed, type, name, body);
    if (!bytesEqual(rebuilt, rawData)) {
      throw const TrezorProtocolException(
        'This Tron transaction is not in a form Trezor can sign exactly',
      );
    }
    return parsed;
  }

  static void _onlyFields(ProtoFields f, Set<int> allowed, String what) {
    for (final field in f.fieldNumbers) {
      if (!allowed.contains(field)) {
        throw TrezorProtocolException(
          'Tron $what field $field is not supported by Trezor',
        );
      }
    }
  }

  /// Ascending field order, as the firmware's protobuf writer emits.
  static Uint8List _reencode(ProtoFields f, Set<int> fields) {
    final w = ProtoWriter();
    for (final field in fields.toList()..sort()) {
      for (final v in f.rawValues(field)) {
        v is int ? w.uint(field, v) : w.bytes(field, v as Uint8List);
      }
    }
    return w.toBytes();
  }

  static Uint8List _rebuild(
    TronParsedTransaction p,
    int type,
    String name,
    Uint8List body,
  ) {
    final parameter =
        (ProtoWriter()
              ..bytes(1, utf8.encode('$_typeUrlPrefix$name'))
              ..bytes(2, body))
            .toBytes();
    final contract =
        (ProtoWriter()
              ..uint(1, type)
              ..bytes(2, parameter))
            .toBytes();
    return (ProtoWriter()
          ..bytes(1, p.refBlockBytes)
          ..bytes(4, p.refBlockHash)
          ..uint(8, p.expiration)
          ..bytes(10, p.data)
          ..bytes(11, contract)
          ..uint(14, p.timestamp)
          ..uint(18, p.feeLimit))
        .toBytes();
  }
}
