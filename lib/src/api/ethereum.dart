import 'dart:typed_data';

import '../client/trezor_client.dart';
import '../exceptions.dart';
import '../messages/ethereum.dart';
import '../messages/message.dart';
import '../util/bip32_path.dart';
import '../util/bytes.dart';

/// An Ethereum transaction signature as the device returns it.
class EthereumSignature {
  const EthereumSignature({required this.v, required this.r, required this.s});

  /// EIP-1559: the y-parity bit (0/1). Legacy: the full EIP-155 `v`.
  final BigInt v;
  final Uint8List r;
  final Uint8List s;
}

/// Ethereum / EVM calls on a connected Trezor. Works on any chain id: chains
/// the firmware does not know are signed with their numeric id shown.
extension TrezorEthereum on TrezorClient {
  /// Calldata sent with the signing request; the rest is streamed on request.
  static const int _initialChunk = 1024;

  Future<String> ethereumGetAddress(
    String path, {
    bool showOnDevice = false,
  }) async {
    final response = await callWallet<EthereumAddress>(
      EthereumGetAddress(
        addressN: parseBip32Path(path),
        showDisplay: showOnDevice,
      ),
    );
    return response.address;
  }

  /// Signs an EIP-1559 (type 2) transaction. The device shows recipient,
  /// amount and max fee and waits for the user; a rejection throws a
  /// cancelled [TrezorFailureException].
  ///
  /// [to] is `0x`-prefixed; empty for contract creation.
  Future<EthereumSignature> ethereumSignEip1559({
    required String path,
    required int chainId,
    required BigInt nonce,
    required BigInt maxFeePerGas,
    required BigInt maxPriorityFeePerGas,
    required BigInt gasLimit,
    required String to,
    required BigInt value,
    Uint8List? data,
    EthereumDefinitions? definitions,
  }) {
    final payload = data ?? Uint8List(0);
    return _signWithCalldata(
      EthereumSignTxEip1559(
        addressN: parseBip32Path(path),
        nonce: bigIntToMinimalBytes(nonce),
        maxGasFee: bigIntToMinimalBytes(maxFeePerGas),
        maxPriorityFee: bigIntToMinimalBytes(maxPriorityFeePerGas),
        gasLimit: bigIntToMinimalBytes(gasLimit),
        to: to,
        value: bigIntToMinimalBytes(value),
        dataInitialChunk: _head(payload),
        dataLength: payload.length,
        chainId: chainId,
        definitions: definitions,
      ),
      payload,
      legacyChainId: null,
    );
  }

  /// Signs a legacy (pre-EIP-1559, EIP-155) transaction. The returned `v` is
  /// the full EIP-155 value, even when the firmware only sent the parity.
  Future<EthereumSignature> ethereumSignLegacy({
    required String path,
    required int chainId,
    required BigInt nonce,
    required BigInt gasPrice,
    required BigInt gasLimit,
    required String to,
    required BigInt value,
    Uint8List? data,
    EthereumDefinitions? definitions,
  }) {
    final payload = data ?? Uint8List(0);
    return _signWithCalldata(
      EthereumSignTx(
        addressN: parseBip32Path(path),
        nonce: bigIntToMinimalBytes(nonce),
        gasPrice: bigIntToMinimalBytes(gasPrice),
        gasLimit: bigIntToMinimalBytes(gasLimit),
        to: to,
        value: bigIntToMinimalBytes(value),
        dataInitialChunk: _head(payload),
        dataLength: payload.length,
        chainId: chainId,
        definitions: definitions,
      ),
      payload,
      legacyChainId: chainId,
    );
  }

  /// `personal_sign` (EIP-191). Returns the 65-byte r‖s‖v signature, v = 27/28.
  Future<EthereumMessageSignature> ethereumSignMessage(
    String path,
    Uint8List message,
  ) => callWallet<EthereumMessageSignature>(
    EthereumSignMessage(addressN: parseBip32Path(path), message: message),
  );

  /// EIP-712 by hashes. [messageHash] is null for a `EIP712Domain`-only
  /// primary type.
  Future<EthereumTypedDataSignature> ethereumSignTypedHash(
    String path, {
    required Uint8List domainSeparatorHash,
    Uint8List? messageHash,
  }) => callWallet<EthereumTypedDataSignature>(
    EthereumSignTypedHash(
      addressN: parseBip32Path(path),
      domainSeparatorHash: domainSeparatorHash,
      messageHash: messageHash,
    ),
  );

  static Uint8List _head(Uint8List data) => Uint8List.fromList(
    data.sublist(0, data.length < _initialChunk ? data.length : _initialChunk),
  );

  /// Sends the request, then feeds calldata chunks for as long as the device
  /// asks (`EthereumTxRequest.data_length`), until it returns the signature.
  Future<EthereumSignature> _signWithCalldata(
    TrezorMessage request,
    Uint8List data, {
    required int? legacyChainId,
  }) async {
    var offset = data.length < _initialChunk ? data.length : _initialChunk;
    var response = await callWallet<EthereumTxRequest>(request);
    while (response.signatureR == null) {
      final wanted = response.dataLength ?? 0;
      if (wanted <= 0 || offset + wanted > data.length) {
        throw TrezorProtocolException(
          'Trezor asked for $wanted calldata bytes at $offset of ${data.length}',
        );
      }
      final chunk = Uint8List.fromList(data.sublist(offset, offset + wanted));
      offset += wanted;
      response = await callWallet<EthereumTxRequest>(EthereumTxAck(chunk));
    }

    var v = BigInt.from(response.signatureV ?? 0);
    // Newer firmware returns only the recovery bit for legacy transactions;
    // rebuild the EIP-155 value (trezorlib does the same).
    if (legacyChainId != null && v <= BigInt.one) {
      v += BigInt.from(2) * BigInt.from(legacyChainId) + BigInt.from(35);
    }
    return EthereumSignature(
      v: v,
      r: response.signatureR!,
      s: response.signatureS ?? Uint8List(0),
    );
  }
}
