# trezor_flutter example

Lists Trezors on USB (Android) and over Bluetooth (Android, iOS), connects to
one, and shows its model, firmware and first Ethereum and Solana addresses.

```sh
flutter run
```

Tapping **Scan** asks for the Bluetooth runtime permissions (with
`permission_handler`) before scanning. USB needs no permission entry: Android
asks the user when you tap a USB device.
