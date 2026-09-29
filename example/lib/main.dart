import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:trezor_flutter/trezor_flutter.dart';

void main() => runApp(const MaterialApp(home: TrezorExample()));

class TrezorExample extends StatefulWidget {
  const TrezorExample({super.key});

  @override
  State<TrezorExample> createState() => _TrezorExampleState();
}

class _TrezorExampleState extends State<TrezorExample> {
  final _platform = TrezorPlatform.instance;
  // Keep pairings for the life of the process only. A real app should persist
  // them in secure storage — they contain a private key.
  final _credentials = InMemoryThpCredentialStore();

  final _devices = <TrezorDevice>{};
  StreamSubscription<TrezorPlatformEvent>? _events;
  bool _usbSupported = false;
  bool _scanning = false;

  TrezorClient? _client;
  String _status = 'Idle';
  String? _ethAddress;
  String? _solAddress;
  String? _tronAddress;
  bool _fetchingAddresses = false;

  @override
  void initState() {
    super.initState();
    _events = _platform.events.listen(_onEvent);
    _init();
  }

  Future<void> _init() async {
    final caps = await _platform.capabilities();
    _usbSupported = caps.usb;
    await _refreshUsb();
  }

  void _onEvent(TrezorPlatformEvent event) {
    switch (event) {
      case TrezorBleScanResult(:final device):
        setState(() => _devices.add(device));
      case TrezorUsbAttached() || TrezorUsbDetached():
        _refreshUsb();
      case TrezorLinkDisconnected():
        setState(() {
          _client = null;
          _status = 'Disconnected';
        });
      default:
        break;
    }
  }

  Future<void> _refreshUsb() async {
    if (!_usbSupported) return;
    final usb = await _platform.usbListDevices();
    setState(() {
      _devices.removeWhere((d) => d.transport == TrezorTransportType.usb);
      _devices.addAll(usb);
    });
  }

  Future<void> _scan() async {
    // macOS asks for Bluetooth access itself when scanning starts, and
    // permission_handler has no macOS implementation.
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetooth,
        // Android 11 and below only; ignored where not declared.
        Permission.locationWhenInUse,
      ].request();
      if (statuses.values.any((s) => s.isPermanentlyDenied)) {
        setState(() => _status = 'Bluetooth permission denied');
        return;
      }
    }
    await _platform.bleStartScan();
    setState(() => _scanning = true);
    await Future<void>.delayed(const Duration(seconds: 15));
    await _platform.bleStopScan();
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _connect(TrezorDevice device) async {
    await _client?.close();
    setState(() {
      _client = null;
      _ethAddress = _solAddress = _tronAddress = null;
      _status = 'Connecting to ${device.name ?? device.id}…';
    });
    try {
      if (device.transport == TrezorTransportType.usb &&
          !device.hasPermission &&
          !await _platform.usbRequestPermission(device.id)) {
        setState(() => _status = 'USB access denied');
        return;
      }
      final link = await NativeTrezorLink.open(device);
      final client = await TrezorClient.connect(
        link: link,
        transport: device.transport,
        app: const TrezorAppIdentity(
          appName: 'trezor_flutter example',
          hostName: 'Example phone',
        ),
        credentialStore: _credentials,
        interaction: TrezorInteraction(
          onButtonRequest: (_) =>
              setState(() => _status = 'Confirm on your Trezor'),
          onPairingCodeRequest: _askPairingCode,
        ),
      );
      setState(() {
        _client = client;
        _status = 'Connected';
        _fetchingAddresses = true;
      });

      // One request at a time: the device handles a single call at once.
      final features = client.features;
      final eth = await client.ethereumGetAddress("m/44'/60'/0'/0/0");
      setState(() => _ethAddress = eth);
      if (features.hasCapability(TrezorCapability.solana)) {
        final sol = await client.solanaGetAddress("m/44'/501'/0'/0'");
        setState(() => _solAddress = sol);
      }
      if (features.hasCapability(TrezorCapability.tron)) {
        final tron = await client.tronGetAddress("m/44'/195'/0'/0/0");
        setState(() => _tronAddress = tron);
      }
    } on TrezorException catch (e) {
      setState(() => _status = 'Failed: ${e.message}');
    } finally {
      if (mounted) setState(() => _fetchingAddresses = false);
    }
  }

  Future<String?> _askPairingCode() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Enter the code shown on your Trezor'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Pair'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _events?.cancel();
    _client?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final features = _client?.features;
    return Scaffold(
      appBar: AppBar(
        title: const Text('trezor_flutter'),
        actions: [
          if (_usbSupported)
            IconButton(icon: const Icon(Icons.usb), onPressed: _refreshUsb),
          IconButton(
            icon: const Icon(Icons.bluetooth_searching),
            onPressed: _scanning ? null : _scan,
          ),
        ],
      ),
      body: ListView(
        children: [
          ListTile(title: Text(_status)),
          if (features != null) ...[
            ListTile(
              title: Text('Trezor ${features.model ?? ''}'),
              subtitle: Text(
                'Firmware ${features.firmwareVersion}'
                '${features.label == null ? '' : ' · ${features.label}'}',
              ),
            ),
            if (_ethAddress != null)
              ListTile(
                title: const Text('Ethereum'),
                subtitle: SelectableText(_ethAddress!),
              ),
            if (_solAddress != null)
              ListTile(
                title: const Text('Solana'),
                subtitle: SelectableText(_solAddress!),
              ),
            if (_tronAddress != null)
              ListTile(
                title: const Text('Tron'),
                subtitle: SelectableText(_tronAddress!),
              ),
            if (_fetchingAddresses)
              const ListTile(
                leading: SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                title: Text('Fetching addresses…'),
              ),
          ],
          const Divider(),
          if (_devices.isEmpty)
            const ListTile(
              title: Text('No Trezor found. Plug one in, or tap scan.'),
            ),
          for (final device in _devices)
            ListTile(
              leading: Icon(
                device.transport == TrezorTransportType.usb
                    ? Icons.usb
                    : Icons.bluetooth,
              ),
              title: Text(device.name ?? 'Trezor'),
              subtitle: Text(device.id),
              onTap: () => _connect(device),
            ),
        ],
      ),
    );
  }
}
