import 'dart:typed_data';

import '../protobuf/proto.dart';
import 'bitcoin.dart';
import 'common.dart';
import 'ethereum.dart';
import 'management.dart';
import 'solana.dart';
import 'thp.dart';
import 'tron.dart';

/// A protobuf message that travels on the wire, tagged with its numeric type
/// from `messages.proto` / `messages-thp.proto`.
abstract class TrezorMessage implements ProtoEncodable {
  const TrezorMessage();

  int get messageType;

  /// Serialized body. Messages without fields keep this default.
  @override
  Uint8List encode() => Uint8List(0);

  @override
  String toString() => runtimeType.toString();
}

/// A response whose type this package does not model. Callers that need it can
/// decode [payload] themselves with [ProtoFields.decode].
class UnknownMessage extends TrezorMessage {
  const UnknownMessage(this.messageType, this.payload);

  @override
  final int messageType;
  final Uint8List payload;

  @override
  Uint8List encode() => payload;

  @override
  String toString() => 'UnknownMessage(type: $messageType)';
}

/// Wire type identifiers (`MessageType_*`).
abstract final class MessageType {
  static const initialize = 0;
  static const ping = 1;
  static const success = 2;
  static const failure = 3;
  static const getPublicKey = 11;
  static const publicKey = 12;
  static const features = 17;
  static const pinMatrixRequest = 18;
  static const pinMatrixAck = 19;
  static const cancel = 20;
  static const lockDevice = 24;
  static const buttonRequest = 26;
  static const buttonAck = 27;
  static const getAddress = 29;
  static const address = 30;
  static const passphraseRequest = 41;
  static const passphraseAck = 42;
  static const getFeatures = 55;
  static const endSession = 83;

  static const ethereumGetAddress = 56;
  static const ethereumAddress = 57;
  static const ethereumSignTx = 58;
  static const ethereumTxRequest = 59;
  static const ethereumTxAck = 60;
  static const ethereumSignMessage = 64;
  static const ethereumMessageSignature = 66;
  static const ethereumGetPublicKey = 450;
  static const ethereumPublicKey = 451;
  static const ethereumSignTxEip1559 = 452;
  static const ethereumTypedDataSignature = 469;
  static const ethereumSignTypedHash = 470;

  static const solanaGetPublicKey = 900;
  static const solanaPublicKey = 901;
  static const solanaGetAddress = 902;
  static const solanaAddress = 903;
  static const solanaSignTx = 904;
  static const solanaTxSignature = 905;

  static const thpCreateNewSession = 1000;
  static const thpPairingRequest = 1008;
  static const thpPairingRequestApproved = 1009;
  static const thpSelectMethod = 1010;
  static const thpPairingPreparationsFinished = 1011;
  static const thpCredentialRequest = 1016;
  static const thpCredentialResponse = 1017;
  static const thpEndRequest = 1018;
  static const thpEndResponse = 1019;
  static const thpCodeEntryCommitment = 1024;
  static const thpCodeEntryChallenge = 1025;
  static const thpCodeEntryCpaceTrezor = 1026;
  static const thpCodeEntryCpaceHostTag = 1027;
  static const thpCodeEntrySecret = 1028;

  static const tronGetAddress = 2200;
  static const tronAddress = 2201;
}

/// Decoders for every device → host message this package understands.
final Map<int, TrezorMessage Function(ProtoFields)> _decoders = {
  MessageType.success: Success.decode,
  MessageType.failure: Failure.decode,
  MessageType.features: Features.decode,
  MessageType.buttonRequest: ButtonRequest.decode,
  MessageType.pinMatrixRequest: PinMatrixRequest.decode,
  MessageType.passphraseRequest: (_) => const PassphraseRequest(),
  MessageType.publicKey: PublicKey.decode,
  MessageType.address: Address.decode,
  MessageType.ethereumAddress: EthereumAddress.decode,
  MessageType.ethereumPublicKey: EthereumPublicKey.decode,
  MessageType.ethereumTxRequest: EthereumTxRequest.decode,
  MessageType.ethereumMessageSignature: EthereumMessageSignature.decode,
  MessageType.ethereumTypedDataSignature: EthereumTypedDataSignature.decode,
  MessageType.solanaAddress: SolanaAddress.decode,
  MessageType.solanaPublicKey: SolanaPublicKey.decode,
  MessageType.solanaTxSignature: SolanaTxSignature.decode,
  MessageType.tronAddress: TronAddress.decode,
  MessageType.thpPairingRequestApproved: (_) =>
      const ThpPairingRequestApproved(),
  MessageType.thpPairingPreparationsFinished: (_) =>
      const ThpPairingPreparationsFinished(),
  MessageType.thpCredentialResponse: ThpCredentialResponse.decode,
  MessageType.thpEndResponse: (_) => const ThpEndResponse(),
  MessageType.thpCodeEntryCommitment: ThpCodeEntryCommitment.decode,
  MessageType.thpCodeEntryCpaceTrezor: ThpCodeEntryCpaceTrezor.decode,
  MessageType.thpCodeEntrySecret: ThpCodeEntrySecret.decode,
};

TrezorMessage decodeTrezorMessage(int type, Uint8List payload) {
  final decoder = _decoders[type];
  if (decoder == null) return UnknownMessage(type, payload);
  return decoder(ProtoFields.decode(payload));
}
