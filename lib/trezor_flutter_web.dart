/// Web side of `trezor_flutter`: a USB packet pipe over WebUSB.
///
/// Registered by the Flutter tool for web builds; apps do not import this.
/// It answers the same `trezor_flutter/methods` and `trezor_flutter/events`
/// channels as the native plugins, so everything above [TrezorPlatform] runs
/// unchanged in the browser.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'src/web/webusb.dart';

/// WebUSB implementation of the `trezor_flutter` channels.
///
/// WebUSB is available in Chromium-based browsers (Chrome, Edge, Opera), in a
/// secure context (https or localhost). A page can only see devices the user
/// has picked in the browser's device chooser ([usbRequestDevice] on the Dart
/// side); the browser remembers the choice, so later visits list the Trezor
/// without asking. Bluetooth is not supported on the web.
class TrezorFlutterWeb {
  TrezorFlutterWeb._(this._usb) {
    _usb?.addEventListener(
      'connect',
      ((UsbConnectionEvent event) => _onConnect(event.device)).toJS,
    );
    _usb?.addEventListener(
      'disconnect',
      ((UsbConnectionEvent event) => _onDisconnect(event.device)).toJS,
    );
  }

  static void registerWith(Registrar registrar) {
    final navigator = globalContext['navigator'] as JSObject?;
    final usb = navigator != null && navigator.has('usb')
        ? navigator['usb'] as Usb?
        : null;
    final plugin = TrezorFlutterWeb._(usb);
    MethodChannel(
      'trezor_flutter/methods',
      const StandardMethodCodec(),
      registrar,
    ).setMethodCallHandler(plugin._handle);
    PluginEventChannel<Object?>(
      'trezor_flutter/events',
      const StandardMethodCodec(),
      registrar,
    ).setController(plugin._events);
  }

  static const _packetSize = 64;
  static const _vendorClass = 0xFF;

  /// (vendor id, product id): Model One, Trezor Core models, Core bootloader.
  static const _trezorIds = [(0x534C, 0x0001), (0x1209, 0x53C1), (0x1209, 0x53C0)];

  final Usb? _usb;
  final StreamController<Object?> _events = StreamController.broadcast();

  /// Devices this page has seen, with the ids handed to Dart. WebUSB devices
  /// have no stable identifier (Trezors share one serial number), so ids are
  /// assigned here and devices matched by object identity.
  final List<(String, UsbDevice)> _known = [];
  int _nextId = 0;
  final Map<String, _Connection> _connections = {};

  static bool _isTrezor(UsbDevice device) => _trezorIds.contains(
    (device.vendorId, device.productId),
  );

  String _register(UsbDevice device) {
    for (final (id, known) in _known) {
      if (known.strictEquals(device).toDart) return id;
    }
    final id = 'webusb-${_nextId++}';
    _known.add((id, device));
    return id;
  }

  UsbDevice? _byId(String id) {
    for (final (knownId, device) in _known) {
      if (knownId == id) return device;
    }
    return null;
  }

  Map<String, Object?> _describe(String id, UsbDevice device) => {
    'deviceId': id,
    'transport': 'usb',
    'name': device.productName ?? 'Trezor',
    'vendorId': device.vendorId,
    'productId': device.productId,
    // Only devices the user picked in the chooser are visible at all.
    'hasPermission': true,
  };

  void _emit(Map<String, Object?> event) => _events.add(event);

  // MARK: - Hotplug

  /// Fires only for devices this site already has access to.
  void _onConnect(UsbDevice device) {
    if (!_isTrezor(device)) return;
    final id = _register(device);
    _emit({'event': 'usbAttached', 'device': _describe(id, device)});
  }

  void _onDisconnect(UsbDevice device) {
    String? id;
    for (final (knownId, known) in _known) {
      if (known.strictEquals(device).toDart) id = knownId;
    }
    if (id == null) return;
    final open = _connections.remove(id);
    if (open != null) {
      unawaited(open.close());
      _emit({
        'event': 'disconnected',
        'deviceId': id,
        'reason': 'USB device detached',
      });
    }
    _known.removeWhere((entry) => entry.$1 == id);
    _emit({'event': 'usbDetached', 'deviceId': id});
  }

  // MARK: - Method channel

  Future<Object?> _handle(MethodCall call) async {
    final args = call.arguments is Map ? call.arguments as Map : const {};
    final deviceId = args['deviceId'] as String?;

    switch (call.method) {
      case 'getCapabilities':
        return {'usb': _usb != null, 'ble': false};
      case 'bluetoothState':
        return 'unavailable';
      case 'usbListDevices':
        return _listDevices();
      case 'usbRequestDevice':
        return _requestDevice();
      case 'usbRequestPermission':
        // A device the page can see has already been granted by the user.
        return _byId(_requireId(deviceId)) != null
            ? true
            : throw PlatformException(
                code: 'deviceNotFound',
                message: 'USB device $deviceId not found',
              );
      case 'bleStartScan':
        throw PlatformException(
          code: 'unsupported',
          message: 'Bluetooth is not available on the web',
        );
      case 'bleStopScan':
        return null;
      case 'open':
        if (args['transport'] != 'usb') {
          throw PlatformException(
            code: 'unsupported',
            message: 'Only USB is available on the web',
          );
        }
        return _open(_requireId(deviceId));
      case 'write':
        final data = args['data'];
        if (data is! Uint8List) {
          throw PlatformException(code: 'writeFailed', message: 'Missing data');
        }
        return _write(_requireId(deviceId), data);
      case 'close':
        await _connections.remove(_requireId(deviceId))?.close();
        return null;
      default:
        throw MissingPluginException();
    }
  }

  static String _requireId(String? id) =>
      id ??
      (throw PlatformException(
        code: 'deviceNotFound',
        message: 'Missing deviceId',
      ));

  Usb _requireUsb() =>
      _usb ??
      (throw PlatformException(
        code: 'unsupported',
        message:
            'WebUSB is not available in this browser. Use Chrome or Edge, '
            'over https or localhost.',
      ));

  Future<List<Object?>> _listDevices() async {
    final usb = _usb;
    if (usb == null) return const [];
    final devices = (await usb.getDevices().toDart).toDart;
    return [
      for (final device in devices)
        if (_isTrezor(device)) _describe(_register(device), device),
    ];
  }

  Future<Object?> _requestDevice() async {
    final usb = _requireUsb();
    final UsbDevice device;
    try {
      device = await usb
          .requestDevice(
            UsbDeviceRequestOptions(
              filters: [
                for (final (vendorId, productId) in _trezorIds)
                  UsbDeviceFilter(vendorId: vendorId, productId: productId),
              ].toJS,
            ),
          )
          .toDart;
    } catch (e) {
      final (name, message) = _jsError(e);
      if (name == 'NotFoundError') return null; // the user closed the chooser
      if (name == 'SecurityError') {
        throw PlatformException(
          code: 'permissionDenied',
          message:
              'The browser shows the USB device picker only right after a '
              'click or tap. Call usbRequestDevice() from a button handler.',
        );
      }
      throw PlatformException(code: 'openFailed', message: message);
    }
    return _describe(_register(device), device);
  }

  Future<Object?> _open(String id) async {
    _requireUsb();
    final device = _byId(id);
    if (device == null) {
      throw PlatformException(
        code: 'deviceNotFound',
        message: 'USB device $id not found',
      );
    }
    await _connections.remove(id)?.close();

    try {
      if (!device.opened) await device.open().toDart;
      if (device.configuration == null) {
        await device.selectConfiguration(1).toDart;
      }
    } catch (e) {
      throw PlatformException(
        code: 'openFailed',
        message: 'Unable to open USB device: ${_jsError(e).$2}',
      );
    }

    // The wire interface: the lowest-numbered vendor-class interface (a debug
    // firmware adds a second one for DebugLink).
    UsbInterface? wire;
    for (final candidate in device.configuration!.interfaces.toDart) {
      if (candidate.alternate.interfaceClass != _vendorClass) continue;
      if (wire == null || candidate.interfaceNumber < wire.interfaceNumber) {
        wire = candidate;
      }
    }
    int? inEndpoint;
    int? outEndpoint;
    for (final endpoint in wire?.alternate.endpoints.toDart ?? <UsbEndpoint>[]) {
      if (endpoint.direction == 'in') {
        inEndpoint ??= endpoint.endpointNumber;
      } else {
        outEndpoint ??= endpoint.endpointNumber;
      }
    }
    if (wire == null || inEndpoint == null || outEndpoint == null) {
      throw PlatformException(
        code: 'openFailed',
        message: 'Trezor USB interface not found',
      );
    }

    try {
      await device.claimInterface(wire.interfaceNumber).toDart;
    } catch (e) {
      throw PlatformException(
        code: 'openFailed',
        message:
            'USB interface is in use (is Trezor Suite, trezord or another tab '
            'connected to the Trezor?): ${_jsError(e).$2}',
      );
    }

    final open = _Connection(
      id: id,
      device: device,
      interfaceNumber: wire.interfaceNumber,
      inEndpoint: inEndpoint,
      outEndpoint: outEndpoint,
    );
    _connections[id] = open;
    open.startReading(
      onPacket: (packet) =>
          _emit({'event': 'packet', 'deviceId': id, 'data': packet}),
      onFailure: (reason) {
        if (_connections[id] != open) return; // closed or replaced meanwhile
        _connections.remove(id);
        unawaited(open.close());
        _emit({'event': 'disconnected', 'deviceId': id, 'reason': reason});
      },
    );
    return {'packetSize': _packetSize};
  }

  Future<Object?> _write(String id, Uint8List data) async {
    final open = _connections[id];
    if (open == null) {
      throw PlatformException(
        code: 'notConnected',
        message: 'USB device $id is not open',
      );
    }
    await open.write(data);
    return null;
  }
}

/// An open Trezor: a read loop on the IN endpoint, and writes sent in order.
class _Connection {
  _Connection({
    required this.id,
    required this.device,
    required this.interfaceNumber,
    required this.inEndpoint,
    required this.outEndpoint,
  });

  final String id;
  final UsbDevice device;
  final int interfaceNumber;
  final int inEndpoint;
  final int outEndpoint;

  bool _closed = false;
  Future<void> _lastWrite = Future.value();

  /// Waits for packets until closed. A Trezor can stay silent for minutes
  /// while the user confirms on its screen; closing the device rejects the
  /// pending transfer, which ends the loop.
  void startReading({
    required void Function(Uint8List packet) onPacket,
    required void Function(String reason) onFailure,
  }) {
    unawaited(() async {
      while (!_closed) {
        final UsbInTransferResult result;
        try {
          result = await device
              .transferIn(inEndpoint, TrezorFlutterWeb._packetSize)
              .toDart;
        } catch (e) {
          if (!_closed) onFailure('USB read failed: ${_jsError(e).$2}');
          return;
        }
        if (_closed) return;
        if (result.status != 'ok') {
          onFailure('USB read failed (${result.status})');
          return;
        }
        final data = result.data?.toDart;
        if (data == null || data.lengthInBytes == 0) continue;
        onPacket(Uint8List.fromList(Uint8List.sublistView(data)));
      }
    }());
  }

  /// Sent after every earlier write; completes once this packet is out.
  Future<void> write(Uint8List data) {
    final done = _lastWrite.then((_) => _send(data));
    _lastWrite = done.then<void>((_) {}, onError: (_) {});
    return done;
  }

  Future<void> _send(Uint8List data) async {
    if (_closed) {
      throw PlatformException(
        code: 'notConnected',
        message: 'USB device $id is not open',
      );
    }
    final UsbOutTransferResult result;
    try {
      result = await device.transferOut(outEndpoint, data.toJS).toDart;
    } catch (e) {
      throw PlatformException(
        code: 'writeFailed',
        message: 'USB write failed: ${_jsError(e).$2}',
      );
    }
    if (result.status != 'ok' || result.bytesWritten != data.length) {
      throw PlatformException(
        code: 'writeFailed',
        message:
            'USB write failed (${result.status}, '
            '${result.bytesWritten} of ${data.length})',
      );
    }
  }

  /// Releases the interface and the device. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await device.releaseInterface(interfaceNumber).toDart;
    } catch (_) {
      // Already gone (unplugged).
    }
    try {
      await device.close().toDart;
    } catch (_) {}
  }
}

/// The DOMException name and message behind a rejected WebUSB promise.
(String, String) _jsError(Object error) {
  try {
    // ignore: invalid_runtime_check_with_js_interop_types
    final js = error as JSObject;
    final name = js['name'];
    final message = js['message'];
    return (
      name.isA<JSString>() ? (name as JSString).toDart : '',
      message.isA<JSString>() ? (message as JSString).toDart : '$error',
    );
  } catch (_) {
    final text = '$error';
    // dart2js may surface the exception with its own wrapper; the name still
    // leads the text ("NotFoundError: No device selected.").
    final name = RegExp(r'^(\w+Error)\b').firstMatch(text)?.group(1) ?? '';
    return (name, text);
  }
}
