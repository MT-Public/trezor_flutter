import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

import '../../exceptions.dart';
import '../../util/bytes.dart';

/// Primitives THP needs: SHA-256/512, HMAC-SHA-256, X25519, AES-256-GCM,
/// Elligator 2 and CPace.
abstract final class ThpCrypto {
  static final X25519 _x25519 = X25519();
  static final AesGcm _aes = AesGcm.with256bits();

  static Uint8List sha256(List<int> data) =>
      Uint8List.fromList(crypto.sha256.convert(data).bytes);

  static Uint8List sha512(List<int> data) =>
      Uint8List.fromList(crypto.sha512.convert(data).bytes);

  static Uint8List hmacSha256(List<int> key, List<int> data) =>
      Uint8List.fromList(crypto.Hmac(crypto.sha256, key).convert(data).bytes);

  /// Noise HKDF with two outputs, exactly as in the THP spec.
  static (Uint8List, Uint8List) hkdf(List<int> chainingKey, List<int> input) {
    final temp = hmacSha256(chainingKey, input);
    final out1 = hmacSha256(temp, [0x01]);
    final out2 = hmacSha256(temp, [...out1, 0x02]);
    return (out1, out2);
  }

  static Future<Uint8List> x25519PublicKey(List<int> privateKey) async {
    final pair = await _x25519.newKeyPairFromSeed(privateKey);
    return Uint8List.fromList((await pair.extractPublicKey()).bytes);
  }

  /// X25519(scalar, point). The scalar is clamped per RFC 7748, which is also
  /// what Trezor does with `mask` values that are raw SHA-256 digests.
  static Future<Uint8List> x25519(List<int> scalar, List<int> point) async {
    final pair = await _x25519.newKeyPairFromSeed(scalar);
    final secret = await _x25519.sharedSecretKey(
      keyPair: pair,
      remotePublicKey: SimplePublicKey(point, type: KeyPairType.x25519),
    );
    return Uint8List.fromList(await secret.extractBytes());
  }

  /// Noise AESGCM nonce: 32 zero bits ‖ counter as u64 big-endian.
  static Uint8List nonce(int counter) {
    final n = Uint8List(12);
    var c = counter;
    for (var i = 11; i >= 4; i--) {
      n[i] = c & 0xFF;
      c >>= 8;
    }
    return n;
  }

  /// Returns ciphertext ‖ 16-byte tag.
  static Future<Uint8List> encrypt(
    List<int> key,
    int counter,
    List<int> ad,
    List<int> plaintext,
  ) async {
    final box = await _aes.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce(counter),
      aad: ad,
    );
    return concatBytes([box.cipherText, box.mac.bytes]);
  }

  static Future<Uint8List> decrypt(
    List<int> key,
    int counter,
    List<int> ad,
    List<int> ciphertextAndTag,
  ) async {
    if (ciphertextAndTag.length < 16) {
      throw const TrezorProtocolException('Ciphertext shorter than GCM tag');
    }
    final split = ciphertextAndTag.length - 16;
    try {
      final clear = await _aes.decrypt(
        SecretBox(
          ciphertextAndTag.sublist(0, split),
          nonce: nonce(counter),
          mac: Mac(ciphertextAndTag.sublist(split)),
        ),
        secretKey: SecretKey(key),
        aad: ad,
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw const TrezorProtocolException('THP message failed authentication');
    }
  }
}

// ---------------------------------------------------------------------------
// Elligator 2 for Curve25519, implemented from RFC 9380 §6.8.2
// (map_to_curve_elligator2 for a Montgomery curve By² = x³ + Ax² + x with
// A = 486662, B = 1, Z = 2).
//
// Uses BigInt, so it is not constant-time. Its input is derived from the
// 6-digit pairing code the user has just read off the device, which is single
// use; a timing side channel on the phone is not a practical way to learn it.
// ---------------------------------------------------------------------------

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _a = BigInt.from(486662);
final BigInt _z = BigInt.two;

BigInt _mod(BigInt v) => v % _p;
BigInt _inv(BigInt v) => v.modPow(_p - BigInt.two, _p);

/// Euler's criterion: `v` is zero or a quadratic residue mod p.
bool _isSquare(BigInt v) {
  final e = v.modPow((_p - BigInt.one) >> 1, _p);
  return e == BigInt.zero || e == BigInt.one;
}

/// Maps 32 bytes to a Curve25519 u-coordinate.
///
/// The input is read as a little-endian field element with the top bit
/// cleared (RFC 7748 decodeUCoordinate), which is how Trezor feeds the
/// SHA-512-derived CPace pre-generator to it.
Uint8List elligator2(List<int> input) {
  final bytes = Uint8List.fromList(input);
  bytes[31] &= 0x7F;
  final u = _mod(bytesToBigIntLE(bytes));

  // 1. tv1 = Z · u²
  var tv1 = _mod(_z * u * u);
  // 2. If tv1 == −1, set tv1 = 0 (the exceptional case).
  if (tv1 == _p - BigInt.one) tv1 = BigInt.zero;
  // 3. x1 = −A / (1 + tv1)
  final x1 = _mod(-_a * _inv(_mod(BigInt.one + tv1)));
  // 4. gx1 = x1³ + A·x1² + x1   (B = 1)
  final gx1 = _mod(x1 * x1 * x1 + _a * x1 * x1 + x1);
  // 5. x2 = −x1 − A
  final x2 = _mod(-x1 - _a);
  // 6. x = x1 if gx1 is square, else x2
  final x = _isSquare(gx1) ? x1 : x2;

  return bigIntToBytesLE(x, 32);
}

/// CPace (draft-irtf-cfrg-cpace, X25519/SHA-512) generator, as used by THP
/// code-entry pairing: `ELLIGATOR2(SHA-512(lv(DSI) ‖ lv(PRS) ‖ lv(zpad) ‖
/// lv(CI) ‖ lv(sid))[:32])`.
Uint8List cpaceGenerator({
  required List<int> prs,
  required List<int> ci,
  List<int> sid = const [],
}) => elligator2(
  ThpCrypto.sha512(
    cpaceGeneratorString(prs: prs, ci: ci, sid: sid),
  ).sublist(0, 32),
);

Uint8List cpaceGeneratorString({
  required List<int> prs,
  required List<int> ci,
  List<int> sid = const [],
}) {
  const dsi = [0x43, 0x50, 0x61, 0x63, 0x65, 0x32, 0x35, 0x35]; // "CPace255"
  const hashBlockSize = 128; // SHA-512
  List<int> lv(List<int> data) {
    if (data.length > 0x7F) {
      throw ArgumentError('CPace field longer than 127 bytes');
    }
    return [data.length, ...data];
  }

  final zpadLength = hashBlockSize - (1 + dsi.length) - (1 + prs.length) - 1;
  final zpad = List<int>.filled(zpadLength < 0 ? 0 : zpadLength, 0);
  return concatBytes([lv(dsi), lv(prs), lv(zpad), lv(ci), lv(sid)]);
}
