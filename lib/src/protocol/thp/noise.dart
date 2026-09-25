import 'dart:typed_data';

import '../../exceptions.dart';
import '../../util/bytes.dart';
import 'thp_crypto.dart';

/// `Noise_XX_25519_AESGCM_SHA256`, zero-padded to the hash length. Because it
/// is exactly 32 bytes it is used as the initial `h` and `ck` directly, not
/// hashed (Noise §5.2 InitializeSymmetric).
final Uint8List noiseProtocolName = Uint8List.fromList([
  ...'Noise_XX_25519_AESGCM_SHA256'.codeUnits,
  0,
  0,
  0,
  0,
]);

/// Host (initiator) side of the THP handshake: Noise XX with the device
/// properties as prologue.
///
/// From the host's point of view this is textbook Noise XX. Trezor's twist —
/// sending a *masked* static key, `X25519(SHA-256(S ‖ e), S)`, so its identity
/// is unlinkable across connections — is invisible here: the masked key is
/// simply the responder static key `rs`. It only matters when looking up a
/// stored credential; see [ThpCredential.matches].
class NoiseHandshake {
  NoiseHandshake({required Uint8List prologue})
    : _h = Uint8List.fromList(noiseProtocolName),
      _ck = Uint8List.fromList(noiseProtocolName) {
    _mixHash(prologue);
  }

  Uint8List _h;
  Uint8List _ck;
  Uint8List? _k;
  int _n = 0;

  late Uint8List _ePriv;
  Uint8List? _re;
  Uint8List? _rs;

  /// Device ephemeral key, from `HandshakeInitiationResponse`.
  Uint8List get remoteEphemeral => _re!;

  /// Device static key *as masked for this connection*.
  Uint8List get remoteMaskedStatic => _rs!;

  /// The final handshake hash, which binds pairing to this channel.
  Uint8List get handshakeHash => _h;

  void _mixHash(List<int> data) => _h = ThpCrypto.sha256([..._h, ...data]);

  void _mixKey(List<int> ikm) {
    final (ck, k) = ThpCrypto.hkdf(_ck, ikm);
    _ck = ck;
    _k = k;
    _n = 0;
  }

  Future<Uint8List> _encryptAndHash(List<int> plaintext) async {
    final k = _k;
    if (k == null) {
      _mixHash(plaintext);
      return Uint8List.fromList(plaintext);
    }
    final ct = await ThpCrypto.encrypt(k, _n++, _h, plaintext);
    _mixHash(ct);
    return ct;
  }

  Future<Uint8List> _decryptAndHash(List<int> ciphertext) async {
    final k = _k;
    if (k == null) {
      _mixHash(ciphertext);
      return Uint8List.fromList(ciphertext);
    }
    final pt = await ThpCrypto.decrypt(k, _n++, _h, ciphertext);
    _mixHash(ciphertext);
    return pt;
  }

  /// `HandshakeInitiationRequest`: `-> e`, with the one-byte `try_to_unlock`
  /// as (unencrypted) payload. With it set, a locked Trezor shows its PIN
  /// screen instead of answering `DEVICE_LOCKED`.
  Future<Uint8List> writeInitiation({
    required bool tryToUnlock,
    Uint8List? ephemeralPrivateKey,
  }) async {
    _ePriv = ephemeralPrivateKey ?? randomBytes(32);
    final ePub = await ThpCrypto.x25519PublicKey(_ePriv);
    _mixHash(ePub);
    final payload = await _encryptAndHash([tryToUnlock ? 1 : 0]);
    return concatBytes([ePub, payload]);
  }

  /// `HandshakeInitiationResponse`: `<- e, ee, s, es` with an empty payload.
  Future<void> readInitiationResponse(Uint8List message) async {
    if (message.length != 32 + 48 + 16) {
      throw TrezorProtocolException(
        'HandshakeInitiationResponse has ${message.length} bytes, expected 96',
      );
    }
    _re = message.sublist(0, 32);
    _mixHash(_re!);
    _mixKey(await ThpCrypto.x25519(_ePriv, _re!));
    _rs = await _decryptAndHash(message.sublist(32, 80));
    _mixKey(await ThpCrypto.x25519(_ePriv, _rs!));
    final empty = await _decryptAndHash(message.sublist(80, 96));
    if (empty.isNotEmpty) {
      throw const TrezorProtocolException('Non-empty handshake tag payload');
    }
  }

  /// `HandshakeCompletionRequest`: `-> s, se`, carrying the (optional)
  /// pairing credential as encrypted payload.
  Future<Uint8List> writeCompletion({
    required Uint8List staticPrivateKey,
    required Uint8List payload,
  }) async {
    final sPub = await ThpCrypto.x25519PublicKey(staticPrivateKey);
    final encryptedStatic = await _encryptAndHash(sPub);
    _mixKey(await ThpCrypto.x25519(staticPrivateKey, _re!));
    final encryptedPayload = await _encryptAndHash(payload);
    return concatBytes([encryptedStatic, encryptedPayload]);
  }

  /// Transport keys: (host → device, device → host).
  (Uint8List, Uint8List) split() => ThpCrypto.hkdf(_ck, const []);
}

/// One direction of the encrypted transport: key plus nonce counter.
class ThpCipherState {
  ThpCipherState(this._key);

  final Uint8List _key;
  int _nonce = 0;

  Future<Uint8List> encrypt(List<int> plaintext) =>
      ThpCrypto.encrypt(_key, _nonce++, const [], plaintext);

  Future<Uint8List> decrypt(List<int> ciphertext) =>
      ThpCrypto.decrypt(_key, _nonce++, const [], ciphertext);
}
