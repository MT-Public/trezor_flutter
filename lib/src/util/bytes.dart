import 'dart:math';
import 'dart:typed_data';

/// Cryptographically secure source for nonces, challenges and keys.
final Random secureRandom = Random.secure();

Uint8List randomBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = secureRandom.nextInt(256);
  }
  return out;
}

Uint8List concatBytes(List<List<int>> parts) {
  final builder = BytesBuilder(copy: false);
  for (final part in parts) {
    builder.add(part);
  }
  return builder.toBytes();
}

/// Constant-time equality, for comparing MACs, tags and commitments.
bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

String bytesToHex(List<int> bytes) {
  final buffer = StringBuffer();
  for (final b in bytes) {
    buffer.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

Uint8List hexToBytes(String hex) {
  var clean = hex.startsWith('0x') || hex.startsWith('0X')
      ? hex.substring(2)
      : hex;
  if (clean.length.isOdd) clean = '0$clean';
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Uint8List uint16BE(int value) =>
    Uint8List.fromList([(value >> 8) & 0xFF, value & 0xFF]);

Uint8List uint32BE(int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);

int readUint16BE(List<int> bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];

int readUint32BE(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

/// Big-endian, minimal-length encoding of a non-negative integer, which is how
/// Trezor expects Ethereum quantities (nonce, gas, value): zero is the empty
/// byte string, never `00`.
Uint8List bigIntToMinimalBytes(BigInt value) {
  if (value.isNegative) {
    throw ArgumentError.value(value, 'value', 'must be non-negative');
  }
  if (value == BigInt.zero) return Uint8List(0);
  var hex = value.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  return hexToBytes(hex);
}

BigInt bytesToBigIntBE(List<int> bytes) {
  var result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) | BigInt.from(b);
  }
  return result;
}

BigInt bytesToBigIntLE(List<int> bytes) {
  var result = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    result = (result << 8) | BigInt.from(bytes[i]);
  }
  return result;
}

Uint8List bigIntToBytesLE(BigInt value, int length) {
  final out = Uint8List(length);
  var v = value;
  final mask = BigInt.from(0xFF);
  for (var i = 0; i < length; i++) {
    out[i] = (v & mask).toInt();
    v = v >> 8;
  }
  return out;
}
