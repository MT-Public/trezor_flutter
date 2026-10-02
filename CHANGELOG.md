## 1.3.0

- Web: USB over WebUSB (Chrome, Edge and other Chromium browsers), with
  connect / disconnect events. New `TrezorPlatform.usbRequestDevice()` shows the
  browser's device chooser. Safari and Firefox have no WebUSB:
  `capabilities()` reports `usb: false` there.
- Example app: runs in the browser (USB button opens the device chooser) and
  explains when USB is unavailable (Safari / Firefox, or a page that is not
  served over https or localhost).
- Protobuf varints no longer use bitwise operators, which JavaScript limits to
  32 bits: values of 2^32 and above (Tron timestamps and amounts) now encode and
  decode correctly on the web. The whole test suite also passes in Chrome.

## 1.2.1

- Documentation: Windows in the supported devices table, the architecture
  diagram and the packaging notes.

## 1.2.0

- Windows: USB (WinUSB, WebUSB interface) with USB hotplug events. No
  driver install needed on Windows 10 and later. Bluetooth is not supported
  on Windows.

## 1.1.0

- macOS: USB (IOKit, WebUSB interface) and Bluetooth LE (CoreBluetooth),
  with USB hotplug events. Swift Package Manager and CocoaPods.
- Tron: `tronGetAddress`, `tronSignRawTransaction` (signs TronGrid
  `raw_data` directly: TRX, TRC-20 and staking / voting / delegation
  contracts) and `tronSignTransaction` for explicit fields.
- The raw transaction is checked to be byte-identical to what the device will
  rebuild and sign, so unsupported transactions fail before reaching the
  device instead of producing an unusable signature.
- Tron signing messages in `package:trezor_flutter/messages.dart`.

## 1.0.1

- Documentation: full feature list and API reference in the README, hardware
  and test status.

## 1.0.0

Initial release.

- Native transports: USB (Android, WebUSB interface) and Bluetooth LE
  (Android, iOS), exposed as a packet pipe (`TrezorPlatform`,
  `NativeTrezorLink`), with USB hotplug and Bluetooth state events.
- Codec v1 protocol for Model One, Model T, Safe 3 and Safe 5.
- Trezor-Host Protocol (THP) for Bluetooth-capable devices: channel
  allocation, alternating-bit acknowledgement and retransmission, Noise XX
  handshake, code-entry pairing (CPace), pairing credentials and encrypted
  sessions.
- `TrezorClient`: protocol detection, button / PIN matrix / passphrase /
  pairing-code prompts via `TrezorInteraction`, cancellation.
- Ethereum: address, EIP-1559 and legacy transaction signing with calldata
  streaming, EIP-191 message signing, EIP-712 by-hash signing.
- Solana: address, public key, transaction signing.
- Protobuf message classes for management, Ethereum, Solana, Bitcoin, Tron and
  THP in `package:trezor_flutter/messages.dart`.
