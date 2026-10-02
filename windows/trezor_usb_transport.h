#ifndef FLUTTER_PLUGIN_TREZOR_USB_TRANSPORT_H_
#define FLUTTER_PLUGIN_TREZOR_USB_TRANSPORT_H_

#include <flutter/encodable_value.h>
#include <flutter/method_result.h>
#include <windows.h>

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace trezor_flutter {

using MethodResultPtr =
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>;

// Runs tasks one at a time, in order, on its own thread. Tasks still queued
// when it is destroyed are run before the thread exits, so a pending write
// always gets an answer.
class SerialWorker {
 public:
  SerialWorker();
  ~SerialWorker();

  SerialWorker(const SerialWorker&) = delete;
  SerialWorker& operator=(const SerialWorker&) = delete;

  void Run(std::function<void()> task);

 private:
  void Loop();

  std::mutex mutex_;
  std::condition_variable wake_;
  std::deque<std::function<void()>> tasks_;
  bool stopping_ = false;
  std::thread thread_;
};

// USB packet pipe for Trezor devices on Windows, over WinUSB.
//
// Trezors expose the wire protocol on a vendor-class (WebUSB) interface with
// one interrupt IN and one interrupt OUT endpoint and 64-byte packets. Their
// firmware carries Microsoft OS descriptors, so Windows 10 and later bind that
// interface to the inbox WinUSB driver by itself: no driver install and no
// permission prompt. Model One firmware older than 1.7, which only has a HID
// interface, is not supported here.
//
// Threads:
// - one reader thread per open device blocks on the IN pipe. A Trezor can stay
//   silent for minutes while the user confirms on its screen; closing aborts
//   the pipe, which releases the read.
// - a control worker opens and closes devices, and a write worker per device
//   sends OUT packets in order.
// - everything the plugin sees (results, events) is handed back through
//   `post`, which runs it on the platform thread as Flutter requires.
class TrezorUsbTransport {
 public:
  // Runs a task on the platform thread. Callable from any thread.
  using Post = std::function<void(std::function<void()>)>;
  // Sends an event to Dart. Platform thread only.
  using Emit = std::function<void(flutter::EncodableMap)>;

  TrezorUsbTransport(Post post, Emit emit);
  ~TrezorUsbTransport();

  TrezorUsbTransport(const TrezorUsbTransport&) = delete;
  TrezorUsbTransport& operator=(const TrezorUsbTransport&) = delete;

  // Everything below runs on the platform thread.

  flutter::EncodableList ListDevices();
  bool HasDevice(const std::string& device_id);
  // Something USB came or went: re-enumerate and report the differences.
  void OnDeviceChange();

  bool IsOpen(const std::string& device_id);
  void Open(const std::string& device_id, MethodResultPtr result);
  void Write(const std::string& device_id, std::vector<uint8_t> data,
             MethodResultPtr result);
  void Close(const std::string& device_id);

  // A Trezor's wire interface, as found by enumeration.
  struct Device {
    std::string id;     // device instance id, UTF-8
    std::wstring path;  // device interface path, for CreateFile
    int vendor_id = 0;
    int product_id = 0;
    std::string name;
  };

  class Connection;

 private:
  void Refresh();
  std::shared_ptr<Connection> Find(const std::string& device_id);
  std::shared_ptr<Connection> Remove(const std::string& device_id);
  void Failed(const std::shared_ptr<Connection>& connection,
              const std::string& reason);

  Post post_;
  Emit emit_;

  // Platform thread only.
  std::map<std::string, Device> known_;

  std::mutex mutex_;
  std::map<std::string, std::shared_ptr<Connection>> connections_;

  // Declared last: destroyed first, while the members above still exist.
  SerialWorker control_;
};

}  // namespace trezor_flutter

#endif  // FLUTTER_PLUGIN_TREZOR_USB_TRANSPORT_H_
