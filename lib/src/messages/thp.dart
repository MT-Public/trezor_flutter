import 'dart:typed_data';

import '../protobuf/proto.dart';
import 'message.dart';

/// `ThpPairingMethod`.
abstract final class ThpPairingMethod {
  static const skipPairing = 1;
  static const codeEntry = 2;
  static const qrCode = 3;
  static const nfc = 4;
}

/// Sent by the device in `ChannelAllocationResponse`. Not a wire message: it
/// has no type id and is carried raw after the nonce and channel id. The raw
/// bytes are also the Noise prologue, so they are kept alongside.
class ThpDeviceProperties {
  const ThpDeviceProperties({
    required this.raw,
    required this.internalModel,
    required this.modelVariant,
    required this.protocolVersionMajor,
    required this.protocolVersionMinor,
    required this.pairingMethods,
  });

  factory ThpDeviceProperties.decode(Uint8List raw) {
    final f = ProtoFields.decode(raw);
    return ThpDeviceProperties(
      raw: raw,
      internalModel: f.string(1) ?? '',
      modelVariant: f.uint(2) ?? 0,
      protocolVersionMajor: f.uint(3) ?? 0,
      protocolVersionMinor: f.uint(4) ?? 0,
      pairingMethods: f.uints(5),
    );
  }

  final Uint8List raw;
  final String internalModel;
  final int modelVariant;
  final int protocolVersionMajor;
  final int protocolVersionMinor;
  final List<int> pairingMethods;
}

/// The encrypted payload of `HandshakeCompletionRequest`. Also not a wire
/// message.
class ThpHandshakeCompletionReqNoisePayload implements ProtoEncodable {
  const ThpHandshakeCompletionReqNoisePayload({this.hostPairingCredential});

  final Uint8List? hostPairingCredential;

  @override
  Uint8List encode() =>
      (ProtoWriter()..bytes(1, hostPairingCredential)).toBytes();
}

/// Opens a seeded session on the session id it is sent on. Answered with
/// `Success` once the seed (and passphrase wallet) has been derived.
class ThpCreateNewSession extends TrezorMessage {
  const ThpCreateNewSession({this.passphrase, this.onDevice});

  final String? passphrase;
  final bool? onDevice;

  @override
  int get messageType => MessageType.thpCreateNewSession;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..string(1, passphrase)
            ..boolean(2, onDevice))
          .toBytes();
}

/// The `ThpPairingRequest` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class ThpPairingRequest extends TrezorMessage {
  const ThpPairingRequest({required this.hostName, required this.appName});

  final String hostName;
  final String appName;

  @override
  int get messageType => MessageType.thpPairingRequest;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..string(1, hostName)
            ..string(2, appName))
          .toBytes();
}

/// The `ThpPairingRequestApproved` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class ThpPairingRequestApproved extends TrezorMessage {
  const ThpPairingRequestApproved();

  @override
  int get messageType => MessageType.thpPairingRequestApproved;
}

/// The `ThpSelectMethod` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class ThpSelectMethod extends TrezorMessage {
  const ThpSelectMethod(this.method);

  final int method;

  @override
  int get messageType => MessageType.thpSelectMethod;

  @override
  Uint8List encode() => (ProtoWriter()..uint(1, method)).toBytes();
}

/// The `ThpPairingPreparationsFinished` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class ThpPairingPreparationsFinished extends TrezorMessage {
  const ThpPairingPreparationsFinished();

  @override
  int get messageType => MessageType.thpPairingPreparationsFinished;
}

/// The `ThpCodeEntryCommitment` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class ThpCodeEntryCommitment extends TrezorMessage {
  const ThpCodeEntryCommitment(this.commitment);

  factory ThpCodeEntryCommitment.decode(ProtoFields f) =>
      ThpCodeEntryCommitment(f.bytes(1) ?? Uint8List(0));

  final Uint8List commitment;

  @override
  int get messageType => MessageType.thpCodeEntryCommitment;

  @override
  Uint8List encode() => (ProtoWriter()..bytes(1, commitment)).toBytes();
}

/// The `ThpCodeEntryChallenge` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class ThpCodeEntryChallenge extends TrezorMessage {
  const ThpCodeEntryChallenge(this.challenge);

  final Uint8List challenge;

  @override
  int get messageType => MessageType.thpCodeEntryChallenge;

  @override
  Uint8List encode() => (ProtoWriter()..bytes(1, challenge)).toBytes();
}

/// The `ThpCodeEntryCpaceTrezor` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class ThpCodeEntryCpaceTrezor extends TrezorMessage {
  const ThpCodeEntryCpaceTrezor(this.cpaceTrezorPublicKey);

  factory ThpCodeEntryCpaceTrezor.decode(ProtoFields f) =>
      ThpCodeEntryCpaceTrezor(f.bytes(1) ?? Uint8List(0));

  final Uint8List cpaceTrezorPublicKey;

  @override
  int get messageType => MessageType.thpCodeEntryCpaceTrezor;

  @override
  Uint8List encode() =>
      (ProtoWriter()..bytes(1, cpaceTrezorPublicKey)).toBytes();
}

/// The `ThpCodeEntryCpaceHostTag` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class ThpCodeEntryCpaceHostTag extends TrezorMessage {
  const ThpCodeEntryCpaceHostTag({
    required this.cpaceHostPublicKey,
    required this.tag,
  });

  final Uint8List cpaceHostPublicKey;
  final Uint8List tag;

  @override
  int get messageType => MessageType.thpCodeEntryCpaceHostTag;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..bytes(1, cpaceHostPublicKey)
            ..bytes(2, tag))
          .toBytes();
}

/// The `ThpCodeEntrySecret` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class ThpCodeEntrySecret extends TrezorMessage {
  const ThpCodeEntrySecret(this.secret);

  factory ThpCodeEntrySecret.decode(ProtoFields f) =>
      ThpCodeEntrySecret(f.bytes(1) ?? Uint8List(0));

  final Uint8List secret;

  @override
  int get messageType => MessageType.thpCodeEntrySecret;

  @override
  Uint8List encode() => (ProtoWriter()..bytes(1, secret)).toBytes();
}

/// The `ThpCredentialRequest` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class ThpCredentialRequest extends TrezorMessage {
  const ThpCredentialRequest({
    required this.hostStaticPublicKey,
    this.autoconnect,
    this.credential,
  });

  final Uint8List hostStaticPublicKey;
  final bool? autoconnect;
  final Uint8List? credential;

  @override
  int get messageType => MessageType.thpCredentialRequest;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..bytes(1, hostStaticPublicKey)
            ..boolean(2, autoconnect)
            ..bytes(3, credential))
          .toBytes();
}

/// The `ThpCredentialResponse` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class ThpCredentialResponse extends TrezorMessage {
  const ThpCredentialResponse({
    required this.trezorStaticPublicKey,
    required this.credential,
  });

  factory ThpCredentialResponse.decode(ProtoFields f) => ThpCredentialResponse(
    trezorStaticPublicKey: f.bytes(1) ?? Uint8List(0),
    credential: f.bytes(2) ?? Uint8List(0),
  );

  final Uint8List trezorStaticPublicKey;
  final Uint8List credential;

  @override
  int get messageType => MessageType.thpCredentialResponse;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..bytes(1, trezorStaticPublicKey)
            ..bytes(2, credential))
          .toBytes();
}

/// The `ThpEndRequest` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class ThpEndRequest extends TrezorMessage {
  const ThpEndRequest();

  @override
  int get messageType => MessageType.thpEndRequest;
}

/// The `ThpEndResponse` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class ThpEndResponse extends TrezorMessage {
  const ThpEndResponse();

  @override
  int get messageType => MessageType.thpEndResponse;
}
