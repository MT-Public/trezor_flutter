/// How a Trezor is attached to this phone.
enum TrezorTransportType { usb, ble }

/// A Trezor seen by the platform layer, before any protocol has run.
class TrezorDevice {
  const TrezorDevice({
    required this.id,
    required this.transport,
    this.name,
    this.vendorId,
    this.productId,
    this.rssi,
    this.hasPermission = true,
  });

  factory TrezorDevice.fromMap(Map<Object?, Object?> map) => TrezorDevice(
    id: map['deviceId']! as String,
    transport: map['transport'] == 'usb'
        ? TrezorTransportType.usb
        : TrezorTransportType.ble,
    name: map['name'] as String?,
    vendorId: map['vendorId'] as int?,
    productId: map['productId'] as int?,
    rssi: map['rssi'] as int?,
    hasPermission: map['hasPermission'] as bool? ?? true,
  );

  /// USB: the Android device path. BLE: the MAC address on Android, the
  /// CoreBluetooth peripheral UUID on iOS. Only meaningful to this phone.
  final String id;
  final TrezorTransportType transport;
  final String? name;
  final int? vendorId;
  final int? productId;
  final int? rssi;

  /// USB only: whether Android has already granted access to this device.
  final bool hasPermission;

  /// USB product id of the bootloader. A device in this mode can be listed but
  /// not used as a wallet.
  bool get isBootloader => vendorId == 0x1209 && productId == 0x53C0;

  @override
  bool operator ==(Object other) =>
      other is TrezorDevice && other.id == id && other.transport == transport;

  @override
  int get hashCode => Object.hash(id, transport);

  @override
  String toString() => 'TrezorDevice(${transport.name}:$id, $name)';
}
