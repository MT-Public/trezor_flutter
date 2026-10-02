#include "trezor_flutter_plugin.h"

#include <dbt.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cwctype>
#include <string>
#include <utility>
#include <vector>

namespace trezor_flutter {

namespace {

const flutter::EncodableValue* Argument(const flutter::EncodableMap* arguments,
                                        const char* key) {
  if (arguments == nullptr) return nullptr;
  auto it = arguments->find(flutter::EncodableValue(key));
  return it == arguments->end() ? nullptr : &it->second;
}

// True for interface paths of a Trezor ("\\?\USB#VID_1209&PID_53C1#...").
bool IsTrezorPath(std::wstring path) {
  std::transform(path.begin(), path.end(), path.begin(), [](wchar_t c) {
    return static_cast<wchar_t>(std::towlower(static_cast<wint_t>(c)));
  });
  return path.find(L"vid_1209") != std::wstring::npos ||
         path.find(L"vid_534c") != std::wstring::npos;
}

}  // namespace

void TrezorFlutterPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  registrar->AddPlugin(std::make_unique<TrezorFlutterPlugin>(registrar));
}

TrezorFlutterPlugin::TrezorFlutterPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar),
      dispatch_message_(RegisterWindowMessageW(L"trezor_flutter.dispatch")) {
  methods_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "trezor_flutter/methods",
      &flutter::StandardMethodCodec::GetInstance());
  methods_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });

  events_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      registrar->messenger(), "trezor_flutter/events",
      &flutter::StandardMethodCodec::GetInstance());
  events_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue*,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& sink)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            sink_ = std::move(sink);
            return nullptr;
          },
          [this](const flutter::EncodableValue*)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            sink_.reset();
            return nullptr;
          }));

  window_proc_id_ = registrar->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        return HandleWindowProc(hwnd, message, wparam, lparam);
      });

  usb_ = std::make_unique<TrezorUsbTransport>(
      [this](std::function<void()> task) { Post(std::move(task)); },
      [this](flutter::EncodableMap event) { Emit(std::move(event)); });

  // Attaching waits for the first message the top-level window delivers to
  // HandleWindowProc. The view's root cannot be used here: the standard runner
  // registers plugins before it parents the view into the top-level window,
  // so at this point the view has no ancestor and GA_ROOT returns the view
  // itself, whose messages never reach the delegate.
}

TrezorFlutterPlugin::~TrezorFlutterPlugin() {
  // No more draining from here on, so nothing posted below can run against a
  // half-destroyed plugin.
  if (window_proc_id_ != -1) {
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
  }
  if (device_notification_ != nullptr) {
    UnregisterDeviceNotification(device_notification_);
  }
  usb_.reset();  // closes devices and joins their threads
  std::lock_guard<std::mutex> lock(queue_mutex_);
  queue_.clear();
}

// MARK: - Platform-thread dispatch

void TrezorFlutterPlugin::Attach(HWND hwnd) {
  if (hwnd == nullptr) return;
  bool pending = false;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    if (window_ != nullptr) return;
    window_ = hwnd;
    pending = !queue_.empty();
  }
  // Hotplug: every device interface arriving or leaving, filtered to Trezors
  // in HandleWindowProc. All classes, because a Trezor shows up under several
  // (the USB device, its WinUSB function, its HID function) and the WinUSB one
  // can arrive after the others.
  DEV_BROADCAST_DEVICEINTERFACE_W filter = {};
  filter.dbcc_size = sizeof(filter);
  filter.dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE;
  device_notification_ = RegisterDeviceNotificationW(
      hwnd, &filter,
      DEVICE_NOTIFY_WINDOW_HANDLE | DEVICE_NOTIFY_ALL_INTERFACE_CLASSES);
  if (pending) PostMessageW(hwnd, dispatch_message_, 0, 0);
}

void TrezorFlutterPlugin::Post(std::function<void()> task) {
  HWND hwnd = nullptr;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    queue_.push_back(std::move(task));
    hwnd = window_;
  }
  if (hwnd != nullptr) PostMessageW(hwnd, dispatch_message_, 0, 0);
}

void TrezorFlutterPlugin::Drain() {
  std::deque<std::function<void()>> tasks;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    tasks.swap(queue_);
  }
  for (auto& task : tasks) task();
}

std::optional<LRESULT> TrezorFlutterPlugin::HandleWindowProc(HWND hwnd,
                                                             UINT message,
                                                             WPARAM wparam,
                                                             LPARAM lparam) {
  Attach(hwnd);

  if (message == dispatch_message_) {
    Drain();
    return 0;
  }

  if (message == WM_DEVICECHANGE &&
      (wparam == DBT_DEVICEARRIVAL || wparam == DBT_DEVICEREMOVECOMPLETE)) {
    auto* header = reinterpret_cast<DEV_BROADCAST_HDR*>(lparam);
    if (header != nullptr && header->dbch_devicetype == DBT_DEVTYP_DEVICEINTERFACE) {
      auto* device = reinterpret_cast<DEV_BROADCAST_DEVICEINTERFACE_W*>(lparam);
      if (IsTrezorPath(device->dbcc_name)) usb_->OnDeviceChange();
    }
  }
  // Not consumed: other delegates and the default proc still need it.
  return std::nullopt;
}

void TrezorFlutterPlugin::Emit(flutter::EncodableMap event) {
  if (sink_) sink_->Success(flutter::EncodableValue(std::move(event)));
}

// MARK: - Method channel

void TrezorFlutterPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
  const std::string& method = call.method_name();

  std::string device_id;
  if (const auto* value = Argument(arguments, "deviceId")) {
    if (const auto* id = std::get_if<std::string>(value)) device_id = *id;
  }
  auto missing_id = [&]() {
    result->Error("deviceNotFound", "Missing deviceId");
  };

  if (method == "getCapabilities") {
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("usb"), flutter::EncodableValue(true)},
        {flutter::EncodableValue("ble"), flutter::EncodableValue(false)},
    }));
  } else if (method == "bluetoothState") {
    result->Success(flutter::EncodableValue("unavailable"));
  } else if (method == "usbListDevices") {
    result->Success(flutter::EncodableValue(usb_->ListDevices()));
  } else if (method == "usbRequestPermission") {
    // Windows has no per-device USB permission.
    if (device_id.empty()) return missing_id();
    if (usb_->HasDevice(device_id)) {
      result->Success(flutter::EncodableValue(true));
    } else {
      result->Error("deviceNotFound", "USB device " + device_id + " not found");
    }
  } else if (method == "bleStartScan") {
    result->Error("unsupported", "Bluetooth is not available on Windows");
  } else if (method == "bleStopScan") {
    result->Success();
  } else if (method == "open") {
    if (device_id.empty()) return missing_id();
    std::string transport;
    if (const auto* value = Argument(arguments, "transport")) {
      if (const auto* name = std::get_if<std::string>(value)) transport = *name;
    }
    if (transport != "usb") {
      result->Error("unsupported", "Only USB is available on Windows");
      return;
    }
    usb_->Open(device_id, MethodResultPtr(std::move(result)));
  } else if (method == "write") {
    if (device_id.empty()) return missing_id();
    const auto* value = Argument(arguments, "data");
    const auto* data =
        value == nullptr ? nullptr : std::get_if<std::vector<uint8_t>>(value);
    if (data == nullptr) {
      result->Error("writeFailed", "Missing data");
      return;
    }
    usb_->Write(device_id, *data, MethodResultPtr(std::move(result)));
  } else if (method == "close") {
    if (device_id.empty()) return missing_id();
    usb_->Close(device_id);
    result->Success();
  } else {
    result->NotImplemented();
  }
}

}  // namespace trezor_flutter
