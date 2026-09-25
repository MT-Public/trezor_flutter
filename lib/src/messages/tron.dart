import 'dart:typed_data';

import '../protobuf/proto.dart';
import 'message.dart';

/// The `TronGetAddress` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class TronGetAddress extends TrezorMessage {
  const TronGetAddress({
    required this.addressN,
    this.showDisplay,
    this.chunkify,
  });

  final List<int> addressN;
  final bool? showDisplay;
  final bool? chunkify;

  @override
  int get messageType => MessageType.tronGetAddress;

  @override
  Uint8List encode() =>
      (ProtoWriter()
            ..repeatedUint(1, addressN)
            ..boolean(2, showDisplay)
            ..boolean(3, chunkify))
          .toBytes();
}

/// The `TronAddress` protobuf message; field numbers follow the Trezor
/// firmware `.proto` definitions.
class TronAddress extends TrezorMessage {
  const TronAddress(this.address);

  factory TronAddress.decode(ProtoFields f) => TronAddress(f.string(1) ?? '');

  /// Base58check, `T…`.
  final String address;

  @override
  int get messageType => MessageType.tronAddress;
}
