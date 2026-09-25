import Flutter
import UIKit

/// iOS side of `trezor_flutter`: a Bluetooth LE packet pipe.
///
/// iOS has no USB path to a Trezor (no MFi accessory support), so the USB
/// methods report `unsupported`. The channel contract is the one documented in
/// `trezor_platform.dart` and implemented identically on Android.
public class TrezorFlutterPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private lazy var ble = TrezorBleCentral { [weak self] event in
    // CoreBluetooth runs on the main queue (see TrezorBleCentral), so this is
    // already the thread FlutterEventSink requires.
    self?.sink?(event)
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = TrezorFlutterPlugin()
    let methods = FlutterMethodChannel(
      name: "trezor_flutter/methods", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(
      name: "trezor_flutter/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
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
      result(["usb": false, "ble": true])
    case "bluetoothState":
      result(ble.stateString())
    case "usbListDevices":
      result([])
    case "usbRequestPermission":
      result(FlutterError(code: "unsupported", message: "USB is not available on iOS", details: nil))
    case "bleStartScan":
      ble.startScan(result: result)
    case "bleStopScan":
      ble.stopScan()
      result(nil)
    case "open":
      guard let deviceId else { return missingId(result) }
      guard (args?["transport"] as? String) == "ble" else {
        return result(
          FlutterError(code: "unsupported", message: "Only Bluetooth is available on iOS", details: nil))
      }
      ble.open(deviceId: deviceId, result: result)
    case "write":
      guard let deviceId else { return missingId(result) }
      guard let data = args?["data"] as? FlutterStandardTypedData else {
        return result(FlutterError(code: "writeFailed", message: "Missing data", details: nil))
      }
      ble.write(deviceId: deviceId, data: data.data, result: result)
    case "close":
      guard let deviceId else { return missingId(result) }
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
