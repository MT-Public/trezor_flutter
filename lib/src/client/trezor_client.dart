import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../exceptions.dart';
import '../link/trezor_device.dart';
import '../link/trezor_link.dart';
import '../messages/common.dart';
import '../messages/management.dart';
import '../messages/message.dart';
import '../messages/thp.dart';
import '../protocol/codec_v1.dart';
import '../protocol/thp/credentials.dart';
import '../protocol/thp/thp_channel.dart';
import '../protocol/thp/thp_crypto.dart';
import '../protocol/thp/thp_wire.dart';
import '../protocol/wire.dart';
import '../util/async_queue.dart';
import '../util/bytes.dart';
import 'trezor_interaction.dart';

enum TrezorProtocol { codecV1, thp }

/// How the app introduces itself when pairing over THP. The device shows
/// "Allow [appName] on [hostName] to pair with this Trezor?".
class TrezorAppIdentity {
  const TrezorAppIdentity({required this.appName, required this.hostName});

  final String appName;
  final String hostName;
}

/// A connected, ready-to-use Trezor.
///
/// Obtained from [TrezorClient.connect], which picks the protocol, runs the
/// THP handshake/pairing when needed, and fetches [features]. All requests go
/// through [call], which answers the device's interactive requests (button
/// confirmations, PIN matrix, passphrase) via [TrezorInteraction].
class TrezorClient {
  TrezorClient._({
    required this.link,
    required this.protocol,
    required TrezorWire wire,
    required this.interaction,
  }) : _wire = wire;

  final TrezorLink link;
  final TrezorProtocol protocol;

  /// Replaceable: a long-lived client (e.g. one kept after connecting) should
  /// route prompts to whichever screen is using it now.
  TrezorInteraction interaction;
  final TrezorWire _wire;
  final AsyncLock _callLock = AsyncLock();

  late Features _features;
  Features get features => _features;

  /// THP session carrying the derived seed, once created. Session 0 is the
  /// seedless one used for management calls and pairing.
  int? _walletSession;
  int _currentSession = 0;
  bool _closed = false;

  static const int _seedlessSession = 0;
  static const int _firstWalletSession = 1;

  /// Connects to the device behind [link].
  ///
  /// BLE is always THP (only THP models have Bluetooth). Over USB the
  /// protocol is detected: a Codec v1 `Cancel` is answered with
  /// `Failure(InvalidProtocol)` by THP firmware and anything else by Codec v1
  /// firmware — the same probe trezorlib uses.
  static Future<TrezorClient> connect({
    required TrezorLink link,
    required TrezorTransportType transport,
    required TrezorAppIdentity app,
    TrezorInteraction interaction = const TrezorInteraction(),
    ThpCredentialStore? credentialStore,
  }) async {
    final useThp =
        transport == TrezorTransportType.ble || !await _speaksCodecV1(link);

    if (!useThp) {
      final client = TrezorClient._(
        link: link,
        protocol: TrezorProtocol.codecV1,
        wire: CodecV1Wire(link),
        interaction: interaction,
      );
      try {
        client._features = await client.callExpect<Features>(
          const Initialize(),
        );
        return client;
      } catch (_) {
        await client._wire.dispose();
        rethrow;
      }
    }

    final store = credentialStore ?? InMemoryThpCredentialStore();
    final channel = await ThpChannel.allocate(link);
    final client = TrezorClient._(
      link: link,
      protocol: TrezorProtocol.thp,
      wire: ThpWire(channel),
      interaction: interaction,
    );
    try {
      final handshake = await channel.handshake(
        credentials: await store.load(),
      );
      if (!handshake.isPaired) {
        // A credential that was offered and refused is dead (device wiped or
        // credentials invalidated); drop it so it is not offered again.
        final stale = handshake.usedCredential;
        if (stale != null) await store.remove(stale);
        await client._pairWithCodeEntry(channel, app);
        final issued = await client.callExpect<ThpCredentialResponse>(
          ThpCredentialRequest(
            hostStaticPublicKey: await ThpCrypto.x25519PublicKey(
              channel.hostStaticPrivateKey,
            ),
          ),
        );
        await store.save(
          ThpCredential(
            trezorStaticPublicKey: issued.trezorStaticPublicKey,
            hostStaticPrivateKey: channel.hostStaticPrivateKey,
            credential: issued.credential,
          ),
        );
      }
      // Leaves the credential phase. With a non-autoconnect credential the
      // device asks the user to confirm the connection here (ButtonRequest).
      await client.callExpect<ThpEndResponse>(const ThpEndRequest());
      client._features = await client.callExpect<Features>(const GetFeatures());
      return client;
    } catch (_) {
      await client._wire.dispose();
      rethrow;
    }
  }

  static Future<bool> _speaksCodecV1(TrezorLink link) async {
    final wire = CodecV1Wire(link);
    try {
      await wire.send(
        RawMessage(const Cancel().messageType, const Cancel().encode()),
      );
      // Stale replies to an earlier app's requests may still be queued on
      // the device; skip a few until the answer to our Cancel shows up.
      for (var i = 0; i < 5; i++) {
        final raw = await wire.receive(timeout: const Duration(seconds: 3));
        final reply = decodeTrezorMessage(raw.type, raw.payload);
        if (reply is Failure) {
          return reply.code != TrezorFailureCode.invalidProtocol;
        }
      }
      return true;
    } finally {
      await wire.dispose();
    }
  }

  /// THP code-entry pairing (the only method current firmware offers):
  /// commit–challenge, then CPace keyed with the 6-digit code shown on the
  /// device, then check the device's revealed secret against both.
  Future<void> _pairWithCodeEntry(
    ThpChannel channel,
    TrezorAppIdentity app,
  ) async {
    if (!channel.deviceProperties.pairingMethods.contains(
      ThpPairingMethod.codeEntry,
    )) {
      throw const TrezorPairingException(
        'The Trezor offers no pairing method this app supports',
      );
    }
    await callExpect<ThpPairingRequestApproved>(
      ThpPairingRequest(hostName: app.hostName, appName: app.appName),
    );
    final commitment = await callExpect<ThpCodeEntryCommitment>(
      const ThpSelectMethod(ThpPairingMethod.codeEntry),
    );
    final challenge = randomBytes(16);
    final cpaceTrezor = await callExpect<ThpCodeEntryCpaceTrezor>(
      ThpCodeEntryChallenge(challenge),
    );

    final requestCode = interaction.onPairingCodeRequest;
    if (requestCode == null) {
      throw const TrezorPairingException(
        'Pairing needs TrezorInteraction.onPairingCodeRequest',
      );
    }
    final code = (await requestCode())?.trim();
    if (code == null) {
      throw const TrezorFailureException(
        TrezorFailureCode.actionCancelled,
        'Pairing cancelled',
      );
    }
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      throw const TrezorPairingException('The pairing code has 6 digits');
    }

    final handshakeHash = channel.handshakeHash;
    final generator = cpaceGenerator(
      prs: ascii.encode(code),
      ci: handshakeHash,
    );
    final privateKey = randomBytes(32);
    final publicKey = await ThpCrypto.x25519(privateKey, generator);
    final shared = await ThpCrypto.x25519(
      privateKey,
      cpaceTrezor.cpaceTrezorPublicKey,
    );
    if (shared.every((b) => b == 0)) {
      throw const TrezorPairingException('Invalid CPace key from the device');
    }

    final ThpCodeEntrySecret revealed;
    try {
      revealed = await callExpect<ThpCodeEntrySecret>(
        ThpCodeEntryCpaceHostTag(
          cpaceHostPublicKey: publicKey,
          tag: ThpCrypto.sha256(shared),
        ),
      );
    } on TrezorFailureException catch (e) {
      if (e.isCancelled) rethrow;
      throw const TrezorPairingException(
        'The Trezor rejected the pairing code',
      );
    }

    // The device committed to its secret before seeing our challenge, so a
    // man in the middle could not have picked the code shown to the user.
    if (!bytesEqual(ThpCrypto.sha256(revealed.secret), commitment.commitment)) {
      throw const TrezorPairingException('Pairing commitment mismatch');
    }
    final expected =
        bytesToBigIntBE(
          ThpCrypto.sha256([
            ThpPairingMethod.codeEntry,
            ...handshakeHash,
            ...revealed.secret,
            ...challenge,
          ]),
        ) %
        BigInt.from(1000000);
    if (expected.toString().padLeft(6, '0') != code) {
      throw const TrezorPairingException('Pairing code mismatch');
    }
  }

  // ---------------------------------------------------------------------------
  // Requests
  // ---------------------------------------------------------------------------

  /// Sends [request] on the seedless session and returns the final answer,
  /// handling interactive requests along the way. A `Failure` becomes a
  /// [TrezorFailureException].
  Future<TrezorMessage> call(TrezorMessage request) =>
      _callLock.run(() => _run(request, _seedlessSession));

  /// Like [call], cast to [T]; anything else is a protocol error.
  Future<T> callExpect<T extends TrezorMessage>(TrezorMessage request) async =>
      _expect<T>(await call(request));

  /// Sends [request] where the seed is available. Over THP this first opens
  /// a wallet session (asking for the passphrase if protection is on); over
  /// Codec v1 the device asks for the passphrase itself when needed.
  Future<T> callWallet<T extends TrezorMessage>(TrezorMessage request) =>
      _callLock.run(() async {
        final session = await _ensureWalletSession();
        return _expect<T>(await _run(request, session));
      });

  T _expect<T extends TrezorMessage>(TrezorMessage response) {
    if (response is T) return response;
    throw TrezorProtocolException(
      'Expected $T, got ${response.runtimeType} (type ${response.messageType})',
    );
  }

  Future<int> _ensureWalletSession() async {
    if (protocol == TrezorProtocol.codecV1) return _seedlessSession;
    final existing = _walletSession;
    if (existing != null) return existing;

    var passphrase = TrezorPassphrase.standardWallet;
    if (_features.passphraseProtection == true) {
      final ask = interaction.onPassphraseRequest;
      if (ask != null) {
        final answer = await ask();
        if (answer == null) {
          throw const TrezorFailureException(
            TrezorFailureCode.actionCancelled,
            'Passphrase entry cancelled',
          );
        }
        passphrase = answer;
      }
    }
    final response = await _run(switch (passphrase) {
      TrezorPassphraseText(:final passphrase) => ThpCreateNewSession(
        passphrase: passphrase,
      ),
      TrezorPassphraseOnDevice() => const ThpCreateNewSession(onDevice: true),
    }, _firstWalletSession);
    _expect<Success>(response);
    return _walletSession = _firstWalletSession;
  }

  Future<TrezorMessage> _run(TrezorMessage request, int session) async {
    if (_closed) throw const TrezorDisconnectedException('Client closed');
    _currentSession = session;
    var outgoing = request;
    var waitingOnUser = false;
    try {
      while (true) {
        await _wire.send(
          RawMessage(
            outgoing.messageType,
            outgoing.encode(),
            sessionId: session,
          ),
        );
        final raw = await _wire.receive(sessionId: session);
        final response = decodeTrezorMessage(raw.type, raw.payload);

        switch (response) {
          case ButtonRequest():
            waitingOnUser = true;
            interaction.onButtonRequest?.call(response);
            outgoing = const ButtonAck();
          case PinMatrixRequest():
            final pin = await interaction.onPinMatrixRequest?.call(
              response.type ?? PinMatrixRequestType.current,
            );
            outgoing = pin == null ? const Cancel() : PinMatrixAck(pin);
          case PassphraseRequest():
            outgoing = await _passphraseAck();
          case Failure():
            throw TrezorFailureException(
              response.code,
              response.message ?? 'Trezor returned a failure',
            );
          default:
            return response;
        }
      }
    } finally {
      if (waitingOnUser) interaction.onInteractionEnded?.call();
    }
  }

  /// Codec v1 passphrase prompt.
  Future<TrezorMessage> _passphraseAck() async {
    final ask = interaction.onPassphraseRequest;
    if (ask == null) return const PassphraseAck(passphrase: '');
    final answer = await ask();
    return switch (answer) {
      null => const Cancel(),
      TrezorPassphraseText(:final passphrase) => PassphraseAck(
        passphrase: passphrase,
      ),
      TrezorPassphraseOnDevice() => const PassphraseAck(onDevice: true),
    };
  }

  /// Aborts whatever the device is doing (e.g. a confirmation screen). The
  /// pending [call] then fails with an `ActionCancelled` failure.
  Future<void> cancel() => _wire.send(
    RawMessage(
      const Cancel().messageType,
      Uint8List(0),
      sessionId: _currentSession,
    ),
  );

  /// Re-reads features (e.g. to see whether the device got unlocked).
  Future<Features> refreshFeatures() async =>
      _features = await callExpect<Features>(const GetFeatures());

  /// Releases the protocol and closes the link.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _wire.dispose();
    await link.close();
  }
}
