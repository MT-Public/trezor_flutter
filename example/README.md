# trezor_flutter example

Lists Trezors on USB (Android, macOS) and over Bluetooth (Android, iOS,
macOS), connects to one, and shows its model, firmware and first Ethereum,
Solana and Tron addresses.

```sh
flutter run            # Android or iOS device
flutter run -d macos   # this Mac
```

Tapping **Scan** asks for the Bluetooth runtime permissions (with
`permission_handler`) before scanning; on macOS the system asks by itself. USB
needs no permission entry: Android asks the user when you tap a USB device, and
macOS does not ask. The macOS runner already has the USB and Bluetooth
sandbox entitlements.
