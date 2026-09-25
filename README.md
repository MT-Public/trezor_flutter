# trezor_flutter

Connect Flutter apps to [Trezor](https://trezor.io) hardware wallets over
native transports - **USB and Bluetooth LE on Android, Bluetooth LE on iOS** -
with no bridge, no Trezor Suite and no web view.

The native side is a thin packet pipe. Everything else - framing, encryption,
pairing, protobuf and the chain helpers - runs in Dart and is shared by both
platforms.

Built and maintained by
[**Macromodule Technologies**](https://macromodule.com/) - AI, blockchain and
software development.

## Contents

- [Features](#features)
- [Status](#status)
- [Supported devices](#supported-devices)
- [Installation and platform setup](#installation)
- [Usage](#usage)
- [API reference](#api-reference)
- [Architecture](#architecture)
- [Limitations](#limitations)
- [About Macromodule Technologies](#about-macromodule-technologies)
- [Contributors](#contributors)

## Features

**Transports**

- USB on Android, through the Trezor WebUSB interface, with all I/O on a
  background thread (the UI never waits on the device).
- USB hotplug events (attached / detached) and runtime USB permission prompts.
- Bluetooth LE on Android and iOS: scanning filtered to Trezor devices, MTU
  negotiation, OS-level bonding, notifications and an ordered write queue.
- Bluetooth adapter state and scan failures reported as events.
- Disconnects (unplug, out of range, power-off) surface immediately as events
  and fail any pending request.

**Protocols**

- **Codec v1** - Model One, Model T, Safe 3, Safe 5.
- **THP (Trezor-Host Protocol)** - Bluetooth-capable Trezors (Safe 7):
  - channel allocation, packet segmentation and CRC-32;
  - alternating-bit acknowledgements with retransmission and busy back-off;
  - Noise XX handshake (X25519, AES-256-GCM, SHA-256) with unlock-on-connect;
  - code-entry pairing (CPace over Curve25519 / Elligator 2);
  - pairing credentials, so a paired phone reconnects without a code;
  - encrypted, multiplexed sessions (seedless and passphrase wallets).
- Automatic protocol detection over USB; Bluetooth always uses THP.

**Device interaction**

- Device information (`Features`): model, firmware, label, lock and passphrase
  state, capabilities.
- Callbacks for everything that needs the user: on-device confirmation, PIN
  matrix (Model One), passphrase (typed in the app or on the device) and the
  6-digit pairing code.
- Cancel an operation from the app; the device leaves its confirmation screen.

**Chains**

- **Ethereum / EVM** (any chain id): address, EIP-1559 and legacy transaction
  signing with streamed calldata of any length, EIP-191 message signing,
  EIP-712 by-hash signing.
- **Solana**: address, public key, transaction signing.
- Every other Trezor message (Bitcoin addresses and public keys, Tron
  addresses, management calls, …) through typed protobuf classes and a generic
  `call`.

**Packaging**

- Android and iOS, Swift Package Manager and CocoaPods, Apple privacy manifest
  included.
- No required native setup beyond the Bluetooth permissions; pure-Dart
  protocol layer that can be tested without hardware (see `TrezorLink`).

## Status

| Path                      | Status                 |
|---------------------------|------------------------|
| Android · USB · Codec v1  | Tested on real devices |
| Android · Bluetooth · THP | Tested on real devices |
| iOS · Bluetooth · THP     | Tested on real devices |

In addition, the protocol layer has unit tests, including known-answer vectors for CRC-32,
Elligator 2 and CPace, a full THP handshake + pairing + credential reuse against
a simulated device built from the device-side state machines of the THP
specification, retransmission after packet loss, and Ethereum calldata
streaming.

## Supported devices

| Model                   | USB (Android) | Bluetooth | Protocol | Solana |
|-------------------------|---------------|-----------|----------|--------|
| Model One               | ✓             | -         | Codec v1 | -      |
| Model T, Safe 3, Safe 5 | ✓             | -         | Codec v1 | ✓      |
| Safe 7                  | ✓             | ✓         | THP      | ✓      |

iOS apps cannot talk to a Trezor over USB, so iOS supports Bluetooth only.

## Installation

```yaml
dependencies:
  trezor_flutter: ^1.0.0
```

### Android

- `minSdkVersion` 21.
- The plugin's manifest declares `BLUETOOTH_SCAN` (with `neverForLocation`),
  `BLUETOOTH_CONNECT`, the pre-Android-12 `BLUETOOTH` / `BLUETOOTH_ADMIN`, and
  the optional `usb.host` / `bluetooth_le` features. They merge into your app.
- **Your app must request the Bluetooth runtime permissions** before scanning
  or connecting (`BLUETOOTH_SCAN` + `BLUETOOTH_CONNECT` on Android 12+). On
  Android 11 and below a scan also needs `ACCESS_FINE_LOCATION`, which the
  plugin deliberately does not declare - add it to your manifest with
  `android:maxSdkVersion="30"` if you support those versions.
- USB needs no manifest entry: access is asked per device at runtime.

### iOS

- iOS 14 or later.
- Add a Bluetooth usage description to `ios/Runner/Info.plist`:

  ```xml
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Used to connect to your Trezor hardware wallet.</string>
  ```

## Usage

### 1. Find a device

```dart
import 'package:trezor_flutter/trezor_flutter.dart';

final platform = TrezorPlatform.instance;

final caps = await platform.capabilities(); // (usb: true, ble: true) on Android

// USB (Android): list what is plugged in, and follow plug / unplug.
final usbDevices = await platform.usbListDevices();

// Bluetooth: results arrive as events.
platform.events.listen((event) {
  switch (event) {
    case TrezorBleScanResult(:final device):
      print('found ${device.name} (${device.rssi} dBm)');
    case TrezorUsbAttached(:final device):
      print('plugged in: $device');
    case TrezorLinkDisconnected(:final deviceId):
      print('lost $deviceId');
    default:
      break;
  }
});
if (await platform.bluetoothState() == TrezorBluetoothState.on) {
  await platform.bleStartScan();
}
```

### 2. Connect

```dart
if (device.transport == TrezorTransportType.usb && !device.hasPermission) {
  await platform.usbRequestPermission(device.id); // Android's USB dialog
}

final link = await NativeTrezorLink.open(device);
final trezor = await TrezorClient.connect(
  link: link,
  transport: device.transport,
  app: const TrezorAppIdentity(appName: 'My Wallet', hostName: 'My phone'),
  credentialStore: myCredentialStore,
  interaction: TrezorInteraction(
    onButtonRequest: (request) => showConfirmOnDeviceHint(),
    onInteractionEnded: hideConfirmOnDeviceHint,
    onPairingCodeRequest: askUserForSixDigitCode,
    onPassphraseRequest: () async => TrezorPassphrase.onDevice,
  ),
);

final f = trezor.features;
print('${f.model} ${f.firmwareVersion} "${f.label}"');
```

`connect` picks the protocol (Bluetooth is always THP; over USB it probes),
runs the THP handshake - a locked device shows its PIN screen - and, on the
first Bluetooth connection, pairing: the Trezor shows a 6-digit code and
`onPairingCodeRequest` returns what the user typed.

### 3. Pairing credentials

After pairing, THP issues a credential that lets the same phone reconnect
without a code. Implement `ThpCredentialStore` on top of secure storage
(Keychain / Keystore) - each credential contains the host's private key.
`ThpCredential` serializes with `toJson` / `fromJson`.
`InMemoryThpCredentialStore` is for tests: every restart pairs again.

### 4. Ethereum / EVM

```dart
const path = "m/44'/60'/0'/0/0";
final address = await trezor.ethereumGetAddress(path);
// Show it on the Trezor's screen for the user to verify:
await trezor.ethereumGetAddress(path, showOnDevice: true);

final sig = await trezor.ethereumSignEip1559(
  path: path,
  chainId: 137,
  nonce: nonce,
  maxFeePerGas: maxFee,
  maxPriorityFeePerGas: tip,
  gasLimit: gasLimit,
  to: '0x…',
  value: amountWei,
  data: calldata, // any length; streamed to the device as it asks
);
// sig.v is the y-parity; build the type-2 envelope with sig.v / sig.r / sig.s.

final legacy = await trezor.ethereumSignLegacy(/* … gasPrice … */);
// legacy.v is the full EIP-155 value.

final personal = await trezor.ethereumSignMessage(path, utf8.encode('hello'));
final typed = await trezor.ethereumSignTypedHash(
  path,
  domainSeparatorHash: domainHash,
  messageHash: messageHash,
);
```

### 5. Solana

```dart
const path = "m/44'/501'/0'/0'"; // ed25519: every level hardened
if (trezor.features.hasCapability(TrezorCapability.solana)) {
  final address = await trezor.solanaGetAddress(path);
  final pubkey = await trezor.solanaGetPublicKey(path); // 32 bytes
  final signature = await trezor.solanaSignTransaction(path, messageBytes);
}
```

### 6. Any other message

```dart
import 'package:trezor_flutter/messages.dart' as msg;

final pong = await trezor.callExpect<msg.Success>(msg.Ping(message: 'hi'));

final btc = await trezor.callWallet<msg.Address>(
  msg.GetAddress(
    addressN: parseBip32Path("m/84'/0'/0'/0/0"),
    coinName: 'Bitcoin',
    scriptType: msg.BitcoinScriptType.spendWitness,
  ),
);
```

`call` / `callExpect` use the seedless session (management calls);
`callWallet` opens the seeded session first, asking for the passphrase through
`onPassphraseRequest` when passphrase protection is on. Button, PIN and
passphrase prompts in between are answered automatically through
`TrezorInteraction`.

### 7. Cancel, errors and disconnect

```dart
try {
  await trezor.ethereumSignEip1559(/* … */);
} on TrezorFailureException catch (e) {
  if (e.isCancelled) print('rejected on the device or cancelled');
} on TrezorDisconnectedException {
  print('unplugged / out of range');
}

await trezor.cancel(); // backs the device out of its confirmation screen
await trezor.close();  // releases the connection
```

## API reference

### Discovery and transport

| API                                | Purpose                                                                                                                                          |
|------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------|
| `TrezorPlatform.instance`          | Native bridge (singleton).                                                                                                                       |
| `capabilities()`                   | Which transports this platform offers: `(usb, ble)`.                                                                                             |
| `bluetoothState()`                 | `TrezorBluetoothState`: `on`, `off`, `unauthorized`, `unavailable`, `unknown`.                                                                   |
| `usbListDevices()`                 | Trezors on USB (Android), as `TrezorDevice`.                                                                                                     |
| `usbRequestPermission(deviceId)`   | Shows Android's USB access dialog.                                                                                                               |
| `bleStartScan()` / `bleStopScan()` | Bluetooth scan; results arrive on `events`.                                                                                                      |
| `events`                           | `TrezorBleScanResult`, `TrezorBleScanFailed`, `TrezorUsbAttached`, `TrezorUsbDetached`, `TrezorBluetoothStateChanged`, `TrezorLinkDisconnected`. |
| `TrezorDevice`                     | `id`, `transport`, `name`, `vendorId`, `productId`, `rssi`, `hasPermission`, `isBootloader`.                                                     |
| `NativeTrezorLink.open(device)`    | Opens the device (connect, MTU, bonding and notifications for BLE).                                                                              |
| `TrezorLink`                       | The packet-pipe interface; implement it for custom transports or tests.                                                                          |

### Client

| API                              | Purpose                                                  |
|----------------------------------|----------------------------------------------------------|
| `TrezorClient.connect(...)`      | Protocol detection, THP handshake and pairing, features. |
| `features` / `refreshFeatures()` | Device information (`Features`).                         |
| `protocol`                       | `TrezorProtocol.codecV1` or `TrezorProtocol.thp`.        |
| `call` / `callExpect<T>`         | Send any message on the seedless session.                |
| `callWallet<T>`                  | Send any message on the seeded (wallet) session.         |
| `interaction`                    | `TrezorInteraction` callbacks; replaceable at any time.  |
| `cancel()`                       | Abort the current operation on the device.               |
| `close()`                        | Release the protocol and close the link.                 |
| `TrezorAppIdentity`              | App and host name shown on the device when pairing.      |

### User interaction

| API                                 | Purpose                                                                               |
|-------------------------------------|---------------------------------------------------------------------------------------|
| `TrezorInteraction.onButtonRequest` | The device waits for the user to confirm on its screen.                               |
| `onInteractionEnded`                | The device answered after confirmation prompts.                                       |
| `onPinMatrixRequest`                | Model One: return the PIN as scrambled-matrix positions.                              |
| `onPassphraseRequest`               | Return `TrezorPassphrase.standardWallet`, `.onDevice` or `TrezorPassphraseText(...)`. |
| `onPairingCodeRequest`              | Return the 6-digit code shown on the Trezor (THP pairing).                            |

### Pairing credentials (THP)

| API                          | Purpose                                                 |
|------------------------------|---------------------------------------------------------|
| `ThpCredentialStore`         | `load`, `save`, `remove` - implement on secure storage. |
| `ThpCredential`              | Stored credential; `toJson` / `fromJson`.               |
| `InMemoryThpCredentialStore` | Process-lifetime store for tests.                       |

### Chains

| API                                       | Purpose                                             |
|-------------------------------------------|-----------------------------------------------------|
| `ethereumGetAddress(path, showOnDevice:)` | EIP-55 address.                                     |
| `ethereumSignEip1559(...)`                | Type-2 transaction signature (`EthereumSignature`). |
| `ethereumSignLegacy(...)`                 | Legacy / EIP-155 transaction signature.             |
| `ethereumSignMessage(path, message)`      | EIP-191 `personal_sign`.                            |
| `ethereumSignTypedHash(path, ...)`        | EIP-712 by domain and message hash.                 |
| `solanaGetAddress(path, showOnDevice:)`   | Base58 address.                                     |
| `solanaGetPublicKey(path)`                | Raw 32-byte ed25519 public key.                     |
| `solanaSignTransaction(path, message)`    | 64-byte signature over a serialized message.        |

Optional `EthereumDefinitions` (signed network / token definitions from
`data.trezor.io`) can be passed to the Ethereum signing calls.

### Device information

`Features`: `model`, `internalModel`, `firmwareVersion`, `label`, `deviceId`,
`initialized`, `unlocked`, `pinProtection`, `passphraseProtection`,
`passphraseAlwaysOnDevice`, `bootloaderMode`, `capabilities` and
`hasCapability(TrezorCapability.…)`.

### Errors

| Exception                     | When                                                                                                                        |
|-------------------------------|-----------------------------------------------------------------------------------------------------------------------------|
| `TrezorException`             | Base class of everything below.                                                                                             |
| `TrezorPlatformException`     | Native error; `code` is a `TrezorPlatformErrorCode` (`permissionDenied`, `bluetoothOff`, `bondingFailed`, `openFailed`, …). |
| `TrezorFailureException`      | The device returned `Failure`; `code` is a `TrezorFailureCode`, `isCancelled` for rejections.                               |
| `TrezorDisconnectedException` | The device went away.                                                                                                       |
| `TrezorTimeoutException`      | No answer in time.                                                                                                          |
| `TrezorPairingException`      | THP pairing failed (wrong code, declined, check mismatch).                                                                  |
| `ThpTransportException`       | THP transport error (e.g. device locked, channel released).                                                                 |
| `TrezorProtocolException`     | Malformed data on the wire.                                                                                                 |

### Utilities

`parseBip32Path("m/44'/60'/0'/0/0")`, `formatBip32Path(...)`, `hardenedOffset`.

### Raw messages

`package:trezor_flutter/messages.dart` - typed protobuf classes for management
(`Initialize`, `GetFeatures`, `Ping`, `LockDevice`, `EndSession`, …), common
(`Success`, `Failure`, `ButtonRequest`, `PinMatrixAck`, `PassphraseAck`, …),
Ethereum, Solana, Bitcoin (`GetAddress`, `GetPublicKey`), Tron
(`TronGetAddress`) and THP pairing messages. Import it with a prefix.

## Architecture

```
┌──────────────── Dart (shared) ────────────────┐
│ Chain helpers   ethereum*, solana*            │
│ TrezorClient    prompts, sessions, cancel     │
│ Protocols       Codec v1 │ THP (Noise, CPace) │
│ Protobuf        typed messages                │
│ TrezorLink      64-byte (USB) / 244-byte (BLE)│
└───────────────────────┬───────────────────────┘
                        │ method + event channel
┌─────── Android ───────┴────────── iOS ────────┐
│ UsbManager, BluetoothGatt │ CoreBluetooth      │
└───────────────────────────────────────────────┘
```

Native code only discovers devices and moves fixed-size packets, which keeps
it small enough to audit and makes the whole protocol stack testable with an
in-memory `TrezorLink`.

## Limitations

- THP pairing supports code entry, the only method current firmware offers;
  QR code and NFC pairing are not implemented.
- No high-level helpers yet for Bitcoin or Tron **signing** or structured
  EIP-712 (by-hash signing is supported); their messages can be sent through
  `call` / `callWallet`.
- Ethereum definitions from `data.trezor.io` are not fetched automatically;
  unknown chains and tokens are shown by chain id and contract address.
- Model One PIN entry through the host needs your own matrix UI via
  `onPinMatrixRequest`; touchscreen models take the PIN on the device.

## About Macromodule Technologies

<p align="center">
  <a href="https://macromodule.com/">
    <img src="https://macromodule.com/wp-content/uploads/2024/11/MT-new-1.png" width="220" alt="Macromodule Technologies - Empowering Your Passion"/>
  </a>
</p>

**trezor_flutter** is built and maintained by
[Macromodule Technologies](https://macromodule.com/), an AI, blockchain and
software development company that helps startups, mid-market businesses and
enterprises plan, build and scale secure digital products - including the
hardware-wallet support in this package.

Need Trezor or other hardware-wallet integration, a crypto wallet, or a
Flutter app built? [Get in touch at macromodule.com](https://macromodule.com/).

## Contributors

<table>
  <tr>
    <td align="center" width="160">
      <a href="https://github.com/asaddigital2809">
        <img src="https://github.com/asaddigital2809.png?size=200" width="96" height="96" alt="Asad Khan"/><br/>
        <b>Asad Khan</b>
      </a><br/>
      <sub>@asaddigital2809</sub><br/>
      <sub>Core contributor</sub>
    </td>
  </tr>
</table>

### Contributing

Contributions are welcome - bug reports, device test results and pull requests
alike.

- **Found a bug?** [Open an issue](https://github.com/MT-Public/trezor_flutter/issues)
  with your Trezor model, firmware version, platform and transport (USB or
  Bluetooth).
- **Want to help?** Fork
  [MT-Public/trezor_flutter](https://github.com/MT-Public/trezor_flutter),
  run `flutter test`, and open a pull request.

## Disclaimer

This is an independent, community-maintained package. It is not affiliated
with, endorsed by, or supported by SatoshiLabs. "Trezor" is a trademark of
SatoshiLabs s.r.o.; it is used here only to describe the devices this package
works with.

## License

MIT - see [LICENSE](LICENSE).
