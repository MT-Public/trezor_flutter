#include "trezor_usb_transport.h"

// windows.h first: the USB, configuration manager and property headers below
// depend on its types. initguid.h makes devpkey.h define its property keys in
// this translation unit instead of only declaring them.
#include <windows.h>
#include <objbase.h>
#include <initguid.h>
#include <cfgmgr32.h>
#include <devpkey.h>
#include <usb.h>
#include <winusb.h>

#include <algorithm>
#include <atomic>
#include <cwchar>
#include <cwctype>
#include <utility>

namespace trezor_flutter {

namespace {

constexpr ULONG kPacketSize = 64;


// (vendor id, product id): Model One, Trezor Core models, Core bootloader.
bool IsTrezor(int vendor_id, int product_id) {
  return (vendor_id == 0x534C && product_id == 0x0001) ||
         (vendor_id == 0x1209 && product_id == 0x53C1) ||
         (vendor_id == 0x1209 && product_id == 0x53C0);
}

std::string Utf8FromWide(const std::wstring& wide) {
  if (wide.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                       static_cast<int>(wide.size()), nullptr,
                                       0, nullptr, nullptr);
  std::string out(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                      out.data(), size, nullptr, nullptr);
  return out;
}

std::wstring Lower(std::wstring text) {
  std::transform(text.begin(), text.end(), text.begin(), [](wchar_t c) {
    return static_cast<wchar_t>(std::towlower(static_cast<wint_t>(c)));
  });
  return text;
}

// Reads the 4 hex digits after `tag` ("vid_" / "pid_") in a hardware id.
bool ParseId(const std::wstring& hardware_id, const wchar_t* tag, int* out) {
  const size_t at = hardware_id.find(tag);
  const size_t start = at + std::wcslen(tag);
  if (at == std::wstring::npos || start + 4 > hardware_id.size()) return false;
  const std::wstring digits = hardware_id.substr(start, 4);
  wchar_t* end = nullptr;
  const long value = std::wcstol(digits.c_str(), &end, 16);
  if (end != digits.c_str() + 4) return false;
  *out = static_cast<int>(value);
  return true;
}

// The device interface classes the function's driver registered. A WinUSB
// function bound through Microsoft OS descriptors lists its GUIDs here; the
// composite parent and HID functions have none, which is what filters them out.
std::vector<GUID> InterfaceGuids(DEVINST devinst) {
  std::vector<GUID> guids;
  HKEY key = nullptr;
  if (CM_Open_DevNode_Key(devinst, KEY_READ, 0, RegDisposition_OpenExisting,
                          &key, CM_REGISTRY_HARDWARE) != CR_SUCCESS) {
    return guids;
  }
  for (const wchar_t* name : {L"DeviceInterfaceGUIDs", L"DeviceInterfaceGUID"}) {
    DWORD type = 0;
    DWORD bytes = 0;
    if (RegQueryValueExW(key, name, nullptr, &type, nullptr, &bytes) !=
            ERROR_SUCCESS ||
        bytes == 0) {
      continue;
    }
    // Room for the double terminator of a REG_MULTI_SZ even if it is missing.
    std::vector<wchar_t> value(bytes / sizeof(wchar_t) + 2, L'\0');
    if (RegQueryValueExW(key, name, nullptr, &type,
                         reinterpret_cast<LPBYTE>(value.data()),
                         &bytes) != ERROR_SUCCESS) {
      continue;
    }
    for (const wchar_t* text = value.data(); *text != L'\0';
         text += std::wcslen(text) + 1) {
      GUID guid;
      if (CLSIDFromString(text, &guid) == NOERROR) guids.push_back(guid);
    }
    if (!guids.empty()) break;
  }
  RegCloseKey(key);
  return guids;
}

// The first present interface path of `instance_id` in any of `guids`.
std::wstring InterfacePath(const std::wstring& instance_id,
                           const std::vector<GUID>& guids) {
  std::wstring id = instance_id;
  for (GUID guid : guids) {
    ULONG length = 0;
    if (CM_Get_Device_Interface_List_SizeW(
            &length, &guid, id.data(), CM_GET_DEVICE_INTERFACE_LIST_PRESENT) !=
            CR_SUCCESS ||
        length <= 1) {
      continue;
    }
    std::vector<wchar_t> paths(length, L'\0');
    if (CM_Get_Device_Interface_ListW(&guid, id.data(), paths.data(), length,
                                      CM_GET_DEVICE_INTERFACE_LIST_PRESENT) !=
        CR_SUCCESS) {
      continue;
    }
    if (paths[0] != L'\0') return std::wstring(paths.data());
  }
  return {};
}

// The product string the device reported, e.g. "Trezor Safe 3".
std::string ProductName(DEVINST devinst) {
  wchar_t buffer[256] = {};
  ULONG size = sizeof(buffer);
  DEVPROPTYPE type = 0;
  if (CM_Get_DevNode_PropertyW(devinst, &DEVPKEY_Device_BusReportedDeviceDesc,
                               &type, reinterpret_cast<PBYTE>(buffer), &size,
                               0) == CR_SUCCESS &&
      type == DEVPROP_TYPE_STRING && buffer[0] != L'\0') {
    return Utf8FromWide(buffer);
  }
  return {};
}

std::vector<TrezorUsbTransport::Device> Enumerate() {
  std::vector<TrezorUsbTransport::Device> devices;
  constexpr ULONG kFlags =
      CM_GETIDLIST_FILTER_ENUMERATOR | CM_GETIDLIST_FILTER_PRESENT;
  ULONG size = 0;
  if (CM_Get_Device_ID_List_SizeW(&size, L"USB", kFlags) != CR_SUCCESS ||
      size <= 1) {
    return devices;
  }
  std::vector<wchar_t> ids(size, L'\0');
  if (CM_Get_Device_ID_ListW(L"USB", ids.data(), size, kFlags) != CR_SUCCESS) {
    return devices;
  }

  for (const wchar_t* id = ids.data(); *id != L'\0'; id += std::wcslen(id) + 1) {
    const std::wstring instance_id(id);
    // "USB\VID_1209&PID_53C1&MI_00\7&2a6..." — the hardware part is the second
    // segment; the instance part after it is opaque.
    const std::wstring lower = Lower(instance_id);
    const size_t first = lower.find(L'\\');
    const size_t second = lower.find(L'\\', first + 1);
    if (first == std::wstring::npos || second == std::wstring::npos) continue;
    const std::wstring hardware = lower.substr(first + 1, second - first - 1);

    int vendor_id = 0;
    int product_id = 0;
    if (!ParseId(hardware, L"vid_", &vendor_id) ||
        !ParseId(hardware, L"pid_", &product_id) ||
        !IsTrezor(vendor_id, product_id)) {
      continue;
    }
    // On a composite device only interface 0 carries the wire protocol (a
    // debug firmware adds DebugLink as interface 1, others add FIDO/HID).
    const size_t function = hardware.find(L"&mi_");
    if (function != std::wstring::npos &&
        hardware.compare(function, 6, L"&mi_00") != 0) {
      continue;
    }

    DEVINST devinst = 0;
    std::wstring locate = instance_id;
    if (CM_Locate_DevNodeW(&devinst, locate.data(), CM_LOCATE_DEVNODE_NORMAL) !=
        CR_SUCCESS) {
      continue;
    }
    const std::vector<GUID> guids = InterfaceGuids(devinst);
    if (guids.empty()) continue;  // not bound to WinUSB
    const std::wstring path = InterfacePath(instance_id, guids);
    if (path.empty()) continue;

    // The product string belongs to the whole device; a composite function
    // reports its interface string ("TREZOR Interface") instead.
    std::string name;
    DEVINST parent = 0;
    if (function != std::wstring::npos &&
        CM_Get_Parent(&parent, devinst, 0) == CR_SUCCESS) {
      name = ProductName(parent);
    }
    if (name.empty()) name = ProductName(devinst);

    TrezorUsbTransport::Device device;
    device.id = Utf8FromWide(instance_id);
    device.path = path;
    device.vendor_id = vendor_id;
    device.product_id = product_id;
    device.name = name.empty() ? "Trezor" : name;
    devices.push_back(std::move(device));
  }
  return devices;
}

flutter::EncodableMap Describe(const TrezorUsbTransport::Device& device) {
  return flutter::EncodableMap{
      {flutter::EncodableValue("deviceId"), flutter::EncodableValue(device.id)},
      {flutter::EncodableValue("transport"), flutter::EncodableValue("usb")},
      {flutter::EncodableValue("name"), flutter::EncodableValue(device.name)},
      {flutter::EncodableValue("vendorId"),
       flutter::EncodableValue(static_cast<int32_t>(device.vendor_id))},
      {flutter::EncodableValue("productId"),
       flutter::EncodableValue(static_cast<int32_t>(device.product_id))},
      // Windows has no per-device USB permission.
      {flutter::EncodableValue("hasPermission"), flutter::EncodableValue(true)},
  };
}

// A failure with one of the channel's error codes (see
// `TrezorPlatformErrorCode`).
struct Failure {
  std::string code;
  std::string message;
};

void Reply(const TrezorUsbTransport::Post& post, MethodResultPtr result,
           flutter::EncodableValue value) {
  post([result, value = std::move(value)]() { result->Success(value); });
}

void Reply(const TrezorUsbTransport::Post& post, MethodResultPtr result,
           Failure failure) {
  post([result, failure = std::move(failure)]() {
    result->Error(failure.code, failure.message);
  });
}

}  // namespace

// MARK: - SerialWorker

SerialWorker::SerialWorker() : thread_([this]() { Loop(); }) {}

SerialWorker::~SerialWorker() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
  }
  wake_.notify_one();
  if (thread_.joinable()) thread_.join();
}

void SerialWorker::Run(std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    tasks_.push_back(std::move(task));
  }
  wake_.notify_one();
}

void SerialWorker::Loop() {
  for (;;) {
    std::function<void()> task;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      wake_.wait(lock, [this]() { return stopping_ || !tasks_.empty(); });
      if (tasks_.empty()) return;  // stopping, and nothing left to run
      task = std::move(tasks_.front());
      tasks_.pop_front();
    }
    task();
  }
}

// MARK: - Connection

class TrezorUsbTransport::Connection {
 public:
  Connection(std::string device_id, HANDLE file, WINUSB_INTERFACE_HANDLE winusb,
             UCHAR in_pipe, UCHAR out_pipe)
      : device_id_(std::move(device_id)),
        file_(file),
        winusb_(winusb),
        in_pipe_(in_pipe),
        out_pipe_(out_pipe),
        writes_(std::make_unique<SerialWorker>()) {}

  ~Connection() { Close(); }

  Connection(const Connection&) = delete;
  Connection& operator=(const Connection&) = delete;

  const std::string& device_id() const { return device_id_; }

  void Start(std::function<void(std::vector<uint8_t>)> on_packet,
             std::function<void(std::string)> on_failure) {
    reader_ = std::thread(
        [this, on_packet = std::move(on_packet),
         on_failure = std::move(on_failure)]() { ReadLoop(on_packet, on_failure); });
  }

  // `done` runs on the write worker with an empty string on success.
  void Write(std::vector<uint8_t> data,
             std::function<void(Failure*)> done) {
    std::lock_guard<std::mutex> lock(writes_mutex_);
    if (closed_ || !writes_) {
      Failure failure{"notConnected", "USB device " + device_id_ + " is not open"};
      done(&failure);
      return;
    }
    writes_->Run([this, data = std::move(data), done = std::move(done)]() mutable {
      if (closed_) {
        Failure failure{"notConnected",
                        "USB device " + device_id_ + " is not open"};
        done(&failure);
        return;
      }
      ULONG written = 0;
      DWORD error = 0;
      if (!Transfer(false, out_pipe_, data.data(),
                    static_cast<ULONG>(data.size()), &written, &error)) {
        Failure failure{"writeFailed",
                        "USB write failed (error " + std::to_string(error) + ")"};
        done(&failure);
        return;
      }
      if (written != data.size()) {
        Failure failure{"writeFailed",
                        "USB write failed (" + std::to_string(written) + " of " +
                            std::to_string(data.size()) + ")"};
        done(&failure);
        return;
      }
      done(nullptr);
    });
  }

  // Releases a blocked read or write, then the device. Idempotent.
  void Close() {
    if (closed_.exchange(true)) return;
    WinUsb_AbortPipe(winusb_, in_pipe_);
    WinUsb_AbortPipe(winusb_, out_pipe_);
    if (reader_.joinable()) {
      if (reader_.get_id() == std::this_thread::get_id()) {
        reader_.detach();
      } else {
        reader_.join();
      }
    }
    std::unique_ptr<SerialWorker> writes;
    {
      std::lock_guard<std::mutex> lock(writes_mutex_);
      writes = std::move(writes_);
    }
    writes.reset();  // runs what is queued: each sees closed_ and fails
    WinUsb_Free(winusb_);
    CloseHandle(file_);
  }

 private:
  void ReadLoop(const std::function<void(std::vector<uint8_t>)>& on_packet,
                const std::function<void(std::string)>& on_failure) {
    std::vector<uint8_t> buffer(kPacketSize);
    while (!closed_) {
      ULONG read = 0;
      DWORD error = 0;
      // Waits until a packet arrives (the pipe has no timeout); Close()
      // aborts it.
      if (!Transfer(true, in_pipe_, buffer.data(), kPacketSize, &read, &error)) {
        if (!closed_) {
          on_failure("USB read failed (error " + std::to_string(error) + ")");
        }
        return;
      }
      if (read > 0 && !closed_) {
        on_packet(std::vector<uint8_t>(buffer.begin(), buffer.begin() + read));
      }
    }
  }

  // One transfer, waited for on its own event. Overlapped rather than
  // synchronous WinUSB calls: synchronous ones on one handle can queue behind
  // each other, and the read below is pending nearly all the time, which would
  // hold every write back until a packet happened to arrive.
  bool Transfer(bool read, UCHAR pipe, uint8_t* data, ULONG length,
                ULONG* transferred, DWORD* error) {
    *transferred = 0;
    OVERLAPPED overlapped = {};
    overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (overlapped.hEvent == nullptr) {
      *error = GetLastError();
      return false;
    }
    BOOL ok = read ? WinUsb_ReadPipe(winusb_, pipe, data, length, nullptr,
                                     &overlapped)
                   : WinUsb_WritePipe(winusb_, pipe, data, length, nullptr,
                                      &overlapped);
    if (ok || GetLastError() == ERROR_IO_PENDING) {
      // Blocks until the transfer completes or WinUsb_AbortPipe cancels it.
      ok = WinUsb_GetOverlappedResult(winusb_, &overlapped, transferred, TRUE);
    }
    *error = ok ? 0 : GetLastError();
    CloseHandle(overlapped.hEvent);
    return ok != FALSE;
  }

  const std::string device_id_;
  const HANDLE file_;
  const WINUSB_INTERFACE_HANDLE winusb_;
  const UCHAR in_pipe_;
  const UCHAR out_pipe_;

  std::atomic<bool> closed_{false};
  std::thread reader_;
  std::mutex writes_mutex_;
  std::unique_ptr<SerialWorker> writes_;
};

// MARK: - Transport

TrezorUsbTransport::TrezorUsbTransport(Post post, Emit emit)
    : post_(std::move(post)), emit_(std::move(emit)) {
  Refresh();
}

TrezorUsbTransport::~TrezorUsbTransport() {
  std::map<std::string, std::shared_ptr<Connection>> open;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    open.swap(connections_);
  }
  for (auto& entry : open) entry.second->Close();
}

void TrezorUsbTransport::Refresh() {
  known_.clear();
  for (auto& device : Enumerate()) {
    const std::string id = device.id;
    known_.emplace(id, std::move(device));
  }
}

flutter::EncodableList TrezorUsbTransport::ListDevices() {
  Refresh();
  flutter::EncodableList list;
  for (const auto& entry : known_) {
    list.push_back(flutter::EncodableValue(Describe(entry.second)));
  }
  return list;
}

bool TrezorUsbTransport::HasDevice(const std::string& device_id) {
  if (known_.find(device_id) == known_.end()) Refresh();
  return known_.find(device_id) != known_.end();
}

void TrezorUsbTransport::OnDeviceChange() {
  const std::map<std::string, Device> previous = known_;
  Refresh();
  for (const auto& entry : known_) {
    if (previous.find(entry.first) == previous.end()) {
      emit_(flutter::EncodableMap{
          {flutter::EncodableValue("event"), flutter::EncodableValue("usbAttached")},
          {flutter::EncodableValue("device"),
           flutter::EncodableValue(Describe(entry.second))},
      });
    }
  }
  for (const auto& entry : previous) {
    if (known_.find(entry.first) != known_.end()) continue;
    if (auto open = Remove(entry.first)) {
      control_.Run([open]() { open->Close(); });
      emit_(flutter::EncodableMap{
          {flutter::EncodableValue("event"), flutter::EncodableValue("disconnected")},
          {flutter::EncodableValue("deviceId"), flutter::EncodableValue(entry.first)},
          {flutter::EncodableValue("reason"),
           flutter::EncodableValue("USB device detached")},
      });
    }
    emit_(flutter::EncodableMap{
        {flutter::EncodableValue("event"), flutter::EncodableValue("usbDetached")},
        {flutter::EncodableValue("deviceId"), flutter::EncodableValue(entry.first)},
    });
  }
}

bool TrezorUsbTransport::IsOpen(const std::string& device_id) {
  return Find(device_id) != nullptr;
}

std::shared_ptr<TrezorUsbTransport::Connection> TrezorUsbTransport::Find(
    const std::string& device_id) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = connections_.find(device_id);
  return it == connections_.end() ? nullptr : it->second;
}

std::shared_ptr<TrezorUsbTransport::Connection> TrezorUsbTransport::Remove(
    const std::string& device_id) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = connections_.find(device_id);
  if (it == connections_.end()) return nullptr;
  auto open = it->second;
  connections_.erase(it);
  return open;
}

void TrezorUsbTransport::Open(const std::string& device_id,
                              MethodResultPtr result) {
  if (!HasDevice(device_id)) {
    result->Error("deviceNotFound", "USB device " + device_id + " not found");
    return;
  }
  const Device device = known_.at(device_id);
  auto previous = Remove(device_id);

  control_.Run([this, device, previous, result]() {
    if (previous) previous->Close();

    HANDLE file = CreateFileW(device.path.c_str(), GENERIC_READ | GENERIC_WRITE,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED,
                              nullptr);
    if (file == INVALID_HANDLE_VALUE) {
      const DWORD error = GetLastError();
      Reply(post_, result,
            Failure{"openFailed",
                    error == ERROR_ACCESS_DENIED || error == ERROR_SHARING_VIOLATION
                        ? "USB interface is in use (is Trezor Suite or trezord "
                          "connected to the Trezor?)"
                        : "Unable to open USB device (error " +
                              std::to_string(error) + ")"});
      return;
    }

    WINUSB_INTERFACE_HANDLE winusb = nullptr;
    if (!WinUsb_Initialize(file, &winusb)) {
      const DWORD error = GetLastError();
      CloseHandle(file);
      Reply(post_, result,
            Failure{"openFailed", "Unable to open the Trezor USB interface (error " +
                                      std::to_string(error) + ")"});
      return;
    }

    // The first IN and first OUT endpoint of interface 0.
    UCHAR in_pipe = 0;
    UCHAR out_pipe = 0;
    USB_INTERFACE_DESCRIPTOR descriptor = {};
    if (WinUsb_QueryInterfaceSettings(winusb, 0, &descriptor)) {
      for (UCHAR index = 0; index < descriptor.bNumEndpoints; ++index) {
        WINUSB_PIPE_INFORMATION pipe = {};
        if (!WinUsb_QueryPipe(winusb, 0, index, &pipe)) continue;
        if ((pipe.PipeId & 0x80) != 0) {
          if (in_pipe == 0) in_pipe = pipe.PipeId;
        } else if (out_pipe == 0) {
          out_pipe = pipe.PipeId;
        }
      }
    }
    if (in_pipe == 0 || out_pipe == 0) {
      WinUsb_Free(winusb);
      CloseHandle(file);
      Reply(post_, result,
            Failure{"openFailed", "Trezor USB endpoints not found"});
      return;
    }

    auto open = std::make_shared<Connection>(device.id, file, winusb, in_pipe,
                                             out_pipe);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      connections_[device.id] = open;
    }
    std::weak_ptr<Connection> weak = open;
    open->Start(
        [this, id = device.id](std::vector<uint8_t> packet) {
          post_([this, id, packet = std::move(packet)]() {
            emit_(flutter::EncodableMap{
                {flutter::EncodableValue("event"), flutter::EncodableValue("packet")},
                {flutter::EncodableValue("deviceId"), flutter::EncodableValue(id)},
                {flutter::EncodableValue("data"), flutter::EncodableValue(packet)},
            });
          });
        },
        [this, weak](std::string reason) {
          if (auto failed = weak.lock()) Failed(failed, reason);
        });

    Reply(post_, result,
          flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("packetSize"),
               flutter::EncodableValue(static_cast<int32_t>(kPacketSize))},
          }));
  });
}

void TrezorUsbTransport::Failed(const std::shared_ptr<Connection>& connection,
                                const std::string& reason) {
  post_([this, connection, reason]() {
    // Already gone if it was unplugged (OnDeviceChange) or closed from Dart.
    if (Find(connection->device_id()) != connection) return;
    Remove(connection->device_id());
    control_.Run([connection]() { connection->Close(); });
    emit_(flutter::EncodableMap{
        {flutter::EncodableValue("event"), flutter::EncodableValue("disconnected")},
        {flutter::EncodableValue("deviceId"),
         flutter::EncodableValue(connection->device_id())},
        {flutter::EncodableValue("reason"), flutter::EncodableValue(reason)},
    });
  });
}

void TrezorUsbTransport::Write(const std::string& device_id,
                               std::vector<uint8_t> data,
                               MethodResultPtr result) {
  auto open = Find(device_id);
  if (!open) {
    result->Error("notConnected", "USB device " + device_id + " is not open");
    return;
  }
  open->Write(std::move(data), [this, result](Failure* failure) {
    if (failure != nullptr) {
      Reply(post_, result, *failure);
    } else {
      Reply(post_, result, flutter::EncodableValue());
    }
  });
}

void TrezorUsbTransport::Close(const std::string& device_id) {
  if (auto open = Remove(device_id)) {
    control_.Run([open]() { open->Close(); });
  }
}

}  // namespace trezor_flutter
