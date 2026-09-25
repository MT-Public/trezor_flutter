import 'dart:typed_data';

import '../protobuf/proto.dart';
import 'message.dart';

/// Codec v1 session start/resume. Answered with [Features].
class Initialize extends TrezorMessage {
  const Initialize({this.sessionId, this.deriveCardano});

  final Uint8List? sessionId;
  final bool? deriveCardano;

  @override
  int get messageType => MessageType.initialize;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..bytes(1, sessionId)
            ..boolean(3, deriveCardano))
          .toBytes();
}

/// The `GetFeatures` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class GetFeatures extends TrezorMessage {
  const GetFeatures();

  @override
  int get messageType => MessageType.getFeatures;
}

/// The `Ping` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class Ping extends TrezorMessage {
  const Ping({this.message = '', this.buttonProtection});

  final String message;
  final bool? buttonProtection;

  @override
  int get messageType => MessageType.ping;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..string(1, message)
            ..boolean(2, buttonProtection))
          .toBytes();
}

/// The `LockDevice` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class LockDevice extends TrezorMessage {
  const LockDevice();

  @override
  int get messageType => MessageType.lockDevice;
}

/// The `EndSession` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class EndSession extends TrezorMessage {
  const EndSession();

  @override
  int get messageType => MessageType.endSession;
}

/// `Features.Capability`.
abstract final class TrezorCapability {
  static const bitcoin = 1;
  static const bitcoinLike = 2;
  static const cardano = 4;
  static const crypto = 5;
  static const ethereum = 7;
  static const monero = 9;
  static const ripple = 11;
  static const stellar = 12;
  static const shamir = 15;
  static const passphraseEntry = 17;
  static const solana = 18;
  static const ble = 22;
  static const nfc = 23;
  static const tron = 24;
  static const ethereumEip7702 = 28;
}

/// The subset of `Features` a wallet needs. Field numbers follow
/// `messages-management.proto`.
class Features extends TrezorMessage {
  const Features({
    this.vendor,
    required this.majorVersion,
    required this.minorVersion,
    required this.patchVersion,
    this.bootloaderMode,
    this.deviceId,
    this.pinProtection,
    this.passphraseProtection,
    this.label,
    this.initialized,
    this.unlocked,
    this.model,
    this.capabilities = const [],
    this.sessionId,
    this.passphraseAlwaysOnDevice,
    this.busy,
    this.internalModel,
    this.unitBtcOnly,
  });

  factory Features.decode(ProtoFields f) => Features(
    vendor: f.string(1),
    majorVersion: f.uint(2) ?? 0,
    minorVersion: f.uint(3) ?? 0,
    patchVersion: f.uint(4) ?? 0,
    bootloaderMode: f.boolean(5),
    deviceId: f.string(6),
    pinProtection: f.boolean(7),
    passphraseProtection: f.boolean(8),
    label: f.string(10),
    initialized: f.boolean(12),
    unlocked: f.boolean(16),
    model: f.string(21),
    capabilities: f.uints(30),
    sessionId: f.bytes(35),
    passphraseAlwaysOnDevice: f.boolean(36),
    busy: f.boolean(41),
    internalModel: f.string(44),
    unitBtcOnly: f.boolean(46),
  );

  final String? vendor;
  final int majorVersion;
  final int minorVersion;
  final int patchVersion;
  final bool? bootloaderMode;

  /// Stable per-device identifier (changes only on wipe).
  final String? deviceId;
  final bool? pinProtection;
  final bool? passphraseProtection;
  final String? label;
  final bool? initialized;
  final bool? unlocked;

  /// Marketing model code: "1", "T", "Safe 3", "Safe 5", "Safe 7".
  final String? model;
  final List<int> capabilities;

  /// Codec v1 session id; pass back in [Initialize] to resume.
  final Uint8List? sessionId;
  final bool? passphraseAlwaysOnDevice;
  final bool? busy;

  /// Internal model code: T1B1, T2T1, T2B1, T3B1, T3T1, T3W1.
  final String? internalModel;
  final bool? unitBtcOnly;

  String get firmwareVersion => '$majorVersion.$minorVersion.$patchVersion';

  bool hasCapability(int capability) => capabilities.contains(capability);

  @override
  int get messageType => MessageType.features;
}
