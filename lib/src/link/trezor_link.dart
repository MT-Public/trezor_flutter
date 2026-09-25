import 'dart:async';
import 'dart:typed_data';

import '../exceptions.dart';
import 'trezor_device.dart';
import 'trezor_platform.dart';

/// A packet pipe to one device: the only thing the wire protocols depend on.
///
/// Abstract so tests (and future transports) can supply their own.
abstract class TrezorLink {
  /// Fixed packet size: 64 for USB, 244 for BLE.
  int get packetSize;

  /// Every packet the device sends. Errors with [TrezorDisconnectedException]
  /// and closes when the link goes away.
  Stream<Uint8List> get packets;

  /// Writes one packet of exactly [packetSize] bytes.
  Future<void> write(Uint8List packet);

  Future<void> close();
}

/// [TrezorLink] backed by the native plugin.
class NativeTrezorLink implements TrezorLink {
  NativeTrezorLink._(this.device, this.packetSize, this._platform) {
    _packetSub = _platform.packets
        .where((p) => p.deviceId == device.id)
        .listen((p) => _packets.add(p.data));
    _eventSub = _platform.events.listen((event) {
      if (event is TrezorLinkDisconnected && event.deviceId == device.id) {
        _onDisconnected(event.reason);
      } else if (event is TrezorUsbDetached && event.deviceId == device.id) {
        _onDisconnected('USB device detached');
      }
    });
  }

  static Future<NativeTrezorLink> open(
    TrezorDevice device, {
    TrezorPlatform? platform,
  }) async {
    final p = platform ?? TrezorPlatform.instance;
    // Subscribe before opening so no early packet is lost.
    p.packets;
    final packetSize = await p.open(device);
    return NativeTrezorLink._(device, packetSize, p);
  }

  final TrezorDevice device;
  @override
  final int packetSize;
  final TrezorPlatform _platform;

  final StreamController<Uint8List> _packets = StreamController.broadcast();
  late final StreamSubscription<dynamic> _packetSub;
  late final StreamSubscription<dynamic> _eventSub;
  bool _closed = false;

  @override
  Stream<Uint8List> get packets => _packets.stream;

  void _onDisconnected(String? reason) {
    if (_closed) return;
    _closed = true;
    _packets.addError(
      TrezorDisconnectedException(reason ?? 'Trezor disconnected'),
    );
    _dispose();
  }

  void _dispose() {
    _packetSub.cancel();
    _eventSub.cancel();
    _packets.close();
  }

  @override
  Future<void> write(Uint8List packet) {
    if (_closed) {
      return Future.error(const TrezorDisconnectedException());
    }
    if (packet.length != packetSize) {
      throw ArgumentError(
        'Packet must be $packetSize bytes, got ${packet.length}',
      );
    }
    return _platform.write(device.id, packet);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _dispose();
    try {
      await _platform.close(device.id);
    } on TrezorException {
      // Already gone on the native side.
    }
  }
}
