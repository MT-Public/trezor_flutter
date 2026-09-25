import 'dart:typed_data';

import '../client/trezor_client.dart';
import '../exceptions.dart';
import '../messages/solana.dart';
import '../util/bip32_path.dart';

/// Solana calls on a connected Trezor (Model T, Safe 3/5/7; the Model One
/// has no Solana support — check `features.hasCapability(TrezorCapability
/// .solana)` first). Solana keys are ed25519, so every path component must be
/// hardened, e.g. `m/44'/501'/0'/0'`.
extension TrezorSolana on TrezorClient {
  /// Base58 address (the account's public key).
  Future<String> solanaGetAddress(
    String path, {
    bool showOnDevice = false,
  }) async {
    final response = await callWallet<SolanaAddress>(
      SolanaGetAddress(
        addressN: parseBip32Path(path),
        showDisplay: showOnDevice,
      ),
    );
    return response.address;
  }

  /// Raw 32-byte ed25519 public key.
  Future<Uint8List> solanaGetPublicKey(String path) async {
    final response = await callWallet<SolanaPublicKey>(
      SolanaGetPublicKey(addressN: parseBip32Path(path)),
    );
    return response.publicKey;
  }

  /// Signs a serialized transaction *message* (the bytes the signature
  /// covers, not a full transaction) and returns the 64-byte signature. The
  /// device parses the message and shows its instructions for approval.
  Future<Uint8List> solanaSignTransaction(
    String path,
    Uint8List message,
  ) async {
    final response = await callWallet<SolanaTxSignature>(
      SolanaSignTx(addressN: parseBip32Path(path), serializedTx: message),
    );
    if (response.signature.length != 64) {
      throw TrezorProtocolException(
        'Solana signature has ${response.signature.length} bytes, expected 64',
      );
    }
    return response.signature;
  }
}
