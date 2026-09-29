import FlutterMacOS
import Foundation

/// macOS side of `trezor_flutter`: a packet pipe over USB or Bluetooth LE.
///
/// Nothing here knows the Trezor protocol. [TrezorUsbTransport] and
/// [TrezorBleCentral] find devices and move fixed-size packets; framing,
/// encryption and protobuf all happen in Dart. The channel contract is the one
/// documented in `trezor_platform.dart` and implemented identically on Android
/// and iOS.
public class TrezorFlutterPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var sink: FlutterEventSink?

  // Both transports deliver events on the main queue, which FlutterEventSink
  // requires.
  private lazy var ble = TrezorBleCentral { [weak self] event in self?.sink?(event) }
  private lazy var usb = TrezorUsbTransport { [weak self] event in self?.sink?(event) }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = TrezorFlutterPlugin()
    let methods = FlutterMethodChannel(
      name: "trezor_flutter/methods", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(
      name: "trezor_flutter/events", binaryMessenger: registrar.messenger)
    events.setStreamHandler(instance)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    usb.dispose()
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    // Hotplug events, like on Android. Watching USB prompts nothing.
    usb.startMonitoring()
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    let deviceId = args?["deviceId"] as? String

    switch call.method {
    case "getCapabilities":
      // Reporting BLE support must not create the central manager: that is
      // what triggers the Bluetooth permission prompt.
      result(["usb": true, "ble": true])
    case "bluetoothState":
      result(ble.stateString())
    case "usbListDevices":
      result(usb.listDevices())
    case "usbRequestPermission":
      // macOS has no per-device USB permission.
      guard let deviceId else { return missingId(result) }
      if usb.hasDevice(deviceId) {
        result(true)
      } else {
        result(
          FlutterError(code: "deviceNotFound", message: "USB device \(deviceId) not found", details: nil))
      }
    case "bleStartScan":
      ble.startScan(result: result)
    case "bleStopScan":
      ble.stopScan()
      result(nil)
    case "open":
      guard let deviceId else { return missingId(result) }
      switch args?["transport"] as? String {
      case "usb": usb.open(deviceId: deviceId, result: result)
      case "ble": ble.open(deviceId: deviceId, result: result)
      default: result(FlutterError(code: "openFailed", message: "Unknown transport", details: nil))
      }
    case "write":
      guard let deviceId else { return missingId(result) }
      guard let data = args?["data"] as? FlutterStandardTypedData else {
        return result(FlutterError(code: "writeFailed", message: "Missing data", details: nil))
      }
      if usb.isOpen(deviceId) {
        usb.write(deviceId: deviceId, data: data.data, result: result)
      } else {
        ble.write(deviceId: deviceId, data: data.data, result: result)
      }
    case "close":
      guard let deviceId else { return missingId(result) }
      usb.close(deviceId: deviceId)
      ble.close(deviceId: deviceId)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func missingId(_ result: FlutterResult) {
    result(FlutterError(code: "deviceNotFound", message: "Missing deviceId", details: nil))
  }
}
