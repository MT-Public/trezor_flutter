// Minimal WebUSB bindings (https://wicg.github.io/webusb/). package:web does
// not include WebUSB, so the parts the transport uses are declared here.
import 'dart:js_interop';

extension type Usb._(JSObject _) implements JSObject {
  external JSPromise<JSArray<UsbDevice>> getDevices();
  external JSPromise<UsbDevice> requestDevice(UsbDeviceRequestOptions options);
  external void addEventListener(String type, JSFunction listener);
}

extension type UsbDeviceRequestOptions._(JSObject _) implements JSObject {
  external factory UsbDeviceRequestOptions({JSArray<UsbDeviceFilter> filters});
}

extension type UsbDeviceFilter._(JSObject _) implements JSObject {
  external factory UsbDeviceFilter({int vendorId, int productId});
}

extension type UsbDevice._(JSObject _) implements JSObject {
  external int get vendorId;
  external int get productId;
  external String? get productName;
  external bool get opened;
  external UsbConfiguration? get configuration;

  external JSPromise<JSAny?> open();
  external JSPromise<JSAny?> close();
  external JSPromise<JSAny?> selectConfiguration(int configurationValue);
  external JSPromise<JSAny?> claimInterface(int interfaceNumber);
  external JSPromise<JSAny?> releaseInterface(int interfaceNumber);
  external JSPromise<UsbInTransferResult> transferIn(
    int endpointNumber,
    int length,
  );
  external JSPromise<UsbOutTransferResult> transferOut(
    int endpointNumber,
    JSUint8Array data,
  );
}

extension type UsbConfiguration._(JSObject _) implements JSObject {
  external JSArray<UsbInterface> get interfaces;
}

extension type UsbInterface._(JSObject _) implements JSObject {
  external int get interfaceNumber;
  external UsbAlternateInterface get alternate;
}

extension type UsbAlternateInterface._(JSObject _) implements JSObject {
  external int get interfaceClass;
  external JSArray<UsbEndpoint> get endpoints;
}

extension type UsbEndpoint._(JSObject _) implements JSObject {
  external int get endpointNumber;

  /// `"in"` or `"out"`.
  external String get direction;
}

extension type UsbInTransferResult._(JSObject _) implements JSObject {
  external JSDataView? get data;

  /// `"ok"`, `"stall"` or `"babble"`.
  external String get status;
}

extension type UsbOutTransferResult._(JSObject _) implements JSObject {
  external int get bytesWritten;
  external String get status;
}

extension type UsbConnectionEvent._(JSObject _) implements JSObject {
  external UsbDevice get device;
}
