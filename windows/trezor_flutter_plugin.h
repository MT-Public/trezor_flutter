#ifndef FLUTTER_PLUGIN_TREZOR_FLUTTER_PLUGIN_H_
#define FLUTTER_PLUGIN_TREZOR_FLUTTER_PLUGIN_H_

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <windows.h>

#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>

#include "trezor_usb_transport.h"

namespace trezor_flutter {

// Windows side of `trezor_flutter`: a USB packet pipe.
//
// Nothing here knows the Trezor protocol. [TrezorUsbTransport] finds devices
// and moves 64-byte packets; framing, encryption and protobuf all happen in
// Dart. The channel contract is the one documented in `trezor_platform.dart`.
// Bluetooth is not supported on Windows: `getCapabilities` reports
// `ble: false` and the Bluetooth methods answer `unsupported`.
class TrezorFlutterPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit TrezorFlutterPlugin(flutter::PluginRegistrarWindows* registrar);
  ~TrezorFlutterPlugin() override;

  TrezorFlutterPlugin(const TrezorFlutterPlugin&) = delete;
  TrezorFlutterPlugin& operator=(const TrezorFlutterPlugin&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Runs [task] on the platform thread. Callable from any thread: the task is
  // queued and the top-level window is poked with a private message, whose
  // handler drains the queue.
  void Post(std::function<void()> task);
  void Drain();

  void Emit(flutter::EncodableMap event);

  std::optional<LRESULT> HandleWindowProc(HWND hwnd, UINT message,
                                          WPARAM wparam, LPARAM lparam);
  void Attach(HWND hwnd);

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> methods_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;

  int window_proc_id_ = -1;
  const UINT dispatch_message_;
  HDEVNOTIFY device_notification_ = nullptr;

  std::mutex queue_mutex_;
  HWND window_ = nullptr;  // guarded by queue_mutex_
  std::deque<std::function<void()>> queue_;

  std::unique_ptr<TrezorUsbTransport> usb_;
};

}  // namespace trezor_flutter

#endif  // FLUTTER_PLUGIN_TREZOR_FLUTTER_PLUGIN_H_
