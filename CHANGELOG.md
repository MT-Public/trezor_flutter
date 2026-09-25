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
