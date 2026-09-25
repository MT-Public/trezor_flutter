/// Trezor hardware wallets for Flutter, over native transports: USB and
/// Bluetooth LE on Android, Bluetooth LE on iOS.
///
/// ```dart
/// final device = (await TrezorPlatform.instance.usbListDevices()).first;
/// final link = await NativeTrezorLink.open(device);
/// final trezor = await TrezorClient.connect(
///   link: link,
///   transport: device.transport,
///   app: const TrezorAppIdentity(appName: 'My Wallet', hostName: 'Phone'),
/// );
/// print(trezor.features.model);
/// final address = await trezor.ethereumGetAddress("m/44'/60'/0'/0/0");
/// ```
///
/// This library exposes the client, the transports and the chain helpers.
/// The raw protobuf message classes, for use with [TrezorClient.call], are in
/// `package:trezor_flutter/messages.dart`.
library;

export 'src/api/ethereum.dart';
export 'src/api/solana.dart';
export 'src/client/trezor_client.dart';
export 'src/client/trezor_interaction.dart';
export 'src/exceptions.dart';
export 'src/link/trezor_device.dart';
export 'src/link/trezor_link.dart';
export 'src/link/trezor_platform.dart';
export 'src/messages/common.dart'
    show ButtonRequest, ButtonRequestType, PinMatrixRequestType;
export 'src/messages/ethereum.dart' show EthereumDefinitions;
export 'src/messages/management.dart' show Features, TrezorCapability;
export 'src/messages/message.dart' show TrezorMessage, UnknownMessage;
export 'src/protocol/thp/credentials.dart';
export 'src/util/bip32_path.dart';
