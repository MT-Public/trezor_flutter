import 'dart:async';

import 'package:flutter/services.dart';

import '../exceptions.dart';
import 'trezor_device.dart';

/// Bluetooth adapter state as reported by the platform.
enum TrezorBluetoothState { unknown, unavailable, unauthorized, off, on }

/// Something the native layer pushed that is not a data packet.
sealed class TrezorPlatformEvent {
  const TrezorPlatformEvent();
}

class TrezorBleScanResult extends TrezorPlatformEvent {
  const TrezorBleScanResult(this.device);
  final TrezorDevice device;
}

class TrezorBleScanFailed extends TrezorPlatformEvent {
  const TrezorBleScanFailed(this.code, this.message);
  final String code;
  final String message;
}

class TrezorUsbAttached extends TrezorPlatformEvent {
  const TrezorUsbAttached(this.device);
  final TrezorDevice device;
}

class TrezorUsbDetached extends TrezorPlatformEvent {
  const TrezorUsbDetached(this.deviceId);
  final String deviceId;
}

class TrezorBluetoothStateChanged extends TrezorPlatformEvent {
  const TrezorBluetoothStateChanged(this.state);
  final TrezorBluetoothState state;
}

class TrezorLinkDisconnected extends TrezorPlatformEvent {
  const TrezorLinkDisconnected(this.deviceId, this.reason);
  final String deviceId;
  final String? reason;
}

/// Raw bridge to the native plugin.
///
/// The native side is deliberately protocol-agnostic: it discovers devices,
/// opens a pipe, and moves fixed-size packets (64 bytes over USB, 244 over
/// BLE). Framing, encryption and messages all live in Dart, so both platforms
/// share one implementation that can be unit-tested without hardware, and the
/// native code stays small enough to audit.
///
/// ## MethodChannel `trezor_flutter/methods`
///
/// | method                 | arguments                     | result              |
/// |------------------------|-------------------------------|---------------------|
/// | `getCapabilities`      | —                             | `{usb, ble}` bools  |
/// | `bluetoothState`       | —                             | state string        |
/// | `usbListDevices`       | —                             | `List<device map>`  |
/// | `usbRequestPermission` | `{deviceId}`                  | `bool`              |
/// | `bleStartScan`         | —                             | —                   |
/// | `bleStopScan`          | —                             | —                   |
/// | `open`                 | `{deviceId, transport}`       | `{packetSize}`      |
/// | `write`                | `{deviceId, data: Uint8List}` | — (once sent)       |
/// | `close`                | `{deviceId}`                  | —                   |
///
/// ## EventChannel `trezor_flutter/events`
///
/// Maps with an `event` key: `packet {deviceId, data}`,
/// `disconnected {deviceId, reason}`, `bleScanResult {device}`,
/// `bleScanFailed {code, message}`, `usbAttached {device}`,
/// `usbDetached {deviceId}`, `bluetoothState {state}`.
///
/// A device map is `{deviceId, transport, name, vendorId?, productId?, rssi?,
/// hasPermission?}`.
class TrezorPlatform {
  TrezorPlatform._();

  static final TrezorPlatform instance = TrezorPlatform._();

  static const MethodChannel _methods = MethodChannel('trezor_flutter/methods');
  static const EventChannel _eventChannel = EventChannel(
    'trezor_flutter/events',
  );

  final StreamController<({String deviceId, Uint8List data})> _packets =
      StreamController.broadcast(sync: true);
  final StreamController<TrezorPlatformEvent> _events =
      StreamController.broadcast(sync: true);
  StreamSubscription<dynamic>? _subscription;

  /// Incoming packets for every open device.
  Stream<({String deviceId, Uint8List data})> get packets {
    _ensureListening();
    return _packets.stream;
  }

  Stream<TrezorPlatformEvent> get events {
    _ensureListening();
    return _events.stream;
  }

  // One native subscription for the lifetime of the app. The native side
  // buffers nothing, so it must be live before any device is opened; keeping
  // it open also means packets are never dropped between one consumer
  // cancelling and the next one listening.
  void _ensureListening() {
    _subscription ??= _eventChannel.receiveBroadcastStream().listen(
      _dispatch,
      onError: (Object error) {
        // No plugin on this platform: let a later call retry.
        _subscription?.cancel();
        _subscription = null;
      },
    );
  }

  void _dispatch(dynamic raw) {
    if (raw is! Map) return;
    final deviceId = raw['deviceId'] as String?;
    switch (raw['event']) {
      case 'packet':
        final data = raw['data'];
        if (deviceId != null && data is Uint8List) {
          _packets.add((deviceId: deviceId, data: data));
        }
      case 'disconnected':
        if (deviceId != null) {
          _events.add(
            TrezorLinkDisconnected(deviceId, raw['reason'] as String?),
          );
        }
      case 'bleScanResult':
        final device = raw['device'];
        if (device is Map) {
          _events.add(TrezorBleScanResult(TrezorDevice.fromMap(device)));
        }
      case 'bleScanFailed':
        _events.add(
          TrezorBleScanFailed(
            raw['code'] as String? ?? 'unknown',
            raw['message'] as String? ?? '',
          ),
        );
      case 'usbAttached':
        final device = raw['device'];
        if (device is Map) {
          _events.add(TrezorUsbAttached(TrezorDevice.fromMap(device)));
        }
      case 'usbDetached':
        if (deviceId != null) _events.add(TrezorUsbDetached(deviceId));
      case 'bluetoothState':
        _events.add(
          TrezorBluetoothStateChanged(parseBluetoothState(raw['state'])),
        );
    }
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _methods.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw TrezorPlatformException(e.code, e.message ?? e.code);
    } on MissingPluginException {
      throw const TrezorPlatformException(
        TrezorPlatformErrorCode.unsupported,
        'trezor_flutter has no implementation on this platform',
      );
    }
  }

  Future<({bool usb, bool ble})> capabilities() async {
    final map = await _invoke<Map<Object?, Object?>>('getCapabilities');
    return (usb: map?['usb'] == true, ble: map?['ble'] == true);
  }

  Future<TrezorBluetoothState> bluetoothState() async =>
      parseBluetoothState(await _invoke<String>('bluetoothState'));

  Future<List<TrezorDevice>> usbListDevices() async {
    final list = await _invoke<List<Object?>>('usbListDevices') ?? const [];
    return list
        .whereType<Map<Object?, Object?>>()
        .map(TrezorDevice.fromMap)
        .toList();
  }

  /// Shows Android's "allow access to USB device" dialog if needed.
  Future<bool> usbRequestPermission(String deviceId) async =>
      await _invoke<bool>('usbRequestPermission', {'deviceId': deviceId}) ??
      false;

  /// Results arrive as [TrezorBleScanResult] events.
  Future<void> bleStartScan() async {
    _ensureListening();
    await _invoke<void>('bleStartScan');
  }

  Future<void> bleStopScan() => _invoke<void>('bleStopScan');

  /// Opens the pipe and returns its packet size. For BLE this connects,
  /// negotiates the MTU, bonds if needed (the OS shows its pairing dialog) and
  /// subscribes to notifications before returning.
  Future<int> open(TrezorDevice device) async {
    _ensureListening();
    final map = await _invoke<Map<Object?, Object?>>('open', {
      'deviceId': device.id,
      'transport': device.transport.name,
    });
    final packetSize = map?['packetSize'];
    if (packetSize is! int || packetSize <= 0) {
      throw const TrezorPlatformException(
        TrezorPlatformErrorCode.openFailed,
        'Native open returned no packet size',
      );
    }
    return packetSize;
  }

  Future<void> write(String deviceId, Uint8List packet) =>
      _invoke<void>('write', {'deviceId': deviceId, 'data': packet});

  Future<void> close(String deviceId) =>
      _invoke<void>('close', {'deviceId': deviceId});
}

TrezorBluetoothState parseBluetoothState(Object? value) => switch (value) {
  'on' => TrezorBluetoothState.on,
  'off' => TrezorBluetoothState.off,
  'unauthorized' => TrezorBluetoothState.unauthorized,
  'unavailable' => TrezorBluetoothState.unavailable,
  _ => TrezorBluetoothState.unknown,
};
