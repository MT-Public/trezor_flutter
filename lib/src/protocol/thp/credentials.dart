import 'dart:typed_data';

import '../../util/bytes.dart';
import 'thp_crypto.dart';

/// A THP pairing credential: what lets this phone reconnect to a Trezor it
/// has paired with before without another code entry.
///
/// [hostStaticPrivateKey] is a secret. Persist credentials in secure storage
/// (Keychain / Keystore), never in plain preferences.
class ThpCredential {
  const ThpCredential({
    required this.trezorStaticPublicKey,
    required this.hostStaticPrivateKey,
    required this.credential,
  });

  factory ThpCredential.fromJson(Map<String, Object?> json) => ThpCredential(
    trezorStaticPublicKey: hexToBytes(json['trezorStaticPublicKey']! as String),
    hostStaticPrivateKey: hexToBytes(json['hostStaticPrivateKey']! as String),
    credential: hexToBytes(json['credential']! as String),
  );

  /// The device's *unmasked* static key, as returned in
  /// `ThpCredentialResponse`. Identifies the device across connections.
  final Uint8List trezorStaticPublicKey;
  final Uint8List hostStaticPrivateKey;

  /// Opaque blob issued by the device; sent back during the handshake.
  final Uint8List credential;

  Map<String, Object?> toJson() => {
    'trezorStaticPublicKey': bytesToHex(trezorStaticPublicKey),
    'hostStaticPrivateKey': bytesToHex(hostStaticPrivateKey),
    'credential': bytesToHex(credential),
  };

  /// Whether this credential belongs to the device that just sent
  /// [maskedStatic] alongside [ephemeral] in its handshake response:
  /// `X25519(SHA-256(S ‖ e), S) == masked`.
  Future<bool> matches({
    required Uint8List ephemeral,
    required Uint8List maskedStatic,
  }) async {
    final mask = ThpCrypto.sha256([...trezorStaticPublicKey, ...ephemeral]);
    final expected = await ThpCrypto.x25519(mask, trezorStaticPublicKey);
    return bytesEqual(expected, maskedStatic);
  }
}

/// Where the app keeps THP credentials.
abstract interface class ThpCredentialStore {
  Future<List<ThpCredential>> load();

  /// Adds [credential], replacing any earlier one for the same device.
  Future<void> save(ThpCredential credential);

  /// Forgets [credential], e.g. after the device rejected it.
  Future<void> remove(ThpCredential credential);
}

/// Keeps credentials for the lifetime of the process only; every app restart
/// means pairing again. Fine for tests, not for shipping.
class InMemoryThpCredentialStore implements ThpCredentialStore {
  final List<ThpCredential> _items = [];

  @override
  Future<List<ThpCredential>> load() async => List.unmodifiable(_items);

  @override
  Future<void> save(ThpCredential credential) async {
    _items.removeWhere(
      (c) =>
          bytesEqual(c.trezorStaticPublicKey, credential.trezorStaticPublicKey),
    );
    _items.add(credential);
  }

  @override
  Future<void> remove(ThpCredential credential) async {
    _items.removeWhere((c) => bytesEqual(c.credential, credential.credential));
  }
}
