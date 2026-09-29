import FlutterMacOS
import Foundation
import IOKit
import IOKit.usb

/// USB packet pipe for Trezor devices on macOS, over IOUSBLib.
///
/// Trezors expose the wire protocol on a vendor-class (WebUSB) interface with
/// one interrupt IN and one interrupt OUT endpoint and 64-byte packets. No
/// kernel driver claims that interface, so the app can open it directly: macOS
/// has no per-device permission prompt (a sandboxed app needs the
/// `com.apple.security.device.usb` entitlement). Model One firmware older than
/// 1.7, which only has a HID interface, is not supported here.
///
/// IOUSBLib rather than the newer IOUSBHost framework: the App Sandbox lets
/// IOUSBLib's user client through with the USB entitlement, but refuses
/// IOUSBHost's (`kIOReturnNotPermitted`), and Flutter apps are sandboxed.
///
/// Threads:
/// - one **reader** thread per open device blocks on the IN pipe. A Trezor
///   can stay silent for minutes while the user confirms on its screen;
///   closing aborts the pipe, which releases the read.
/// - a serial **control** queue opens and closes devices, and a serial
///   **write** queue per device sends OUT packets in order (a write does not
///   wait for the blocked read).
/// - device discovery and hotplug run on the main queue, where every event is
///   also delivered, as FlutterEventSink requires.
final class TrezorUsbTransport {
  private static let packetSize = 64
  private static let vendorClass = 0xFF

  /// (vendorId, productId): Model One, Trezor Core models, Core bootloader.
  private static let trezorIds: Set<[Int]> = [[0x534C, 0x0001], [0x1209, 0x53C1], [0x1209, 0x53C0]]

  /// A Trezor's wire interface, as found in the I/O Registry.
  private struct Entry {
    let deviceId: String
    let interfaceEntryId: UInt64
    let vendorId: Int
    let productId: Int
    let name: String
  }

  private let emit: ([String: Any?]) -> Void
  private let control = DispatchQueue(label: "trezor_flutter.usb.control")

  private var notifyPort: IONotificationPortRef?
  private var iterators: [io_iterator_t] = []
  /// Plugged-in Trezors by device id. Main queue only.
  private var known: [String: Entry] = [:]

  private let lock = NSLock()
  private var connections: [String: Connection] = [:]

  /// [emit] is always called on the main queue.
  init(emit: @escaping ([String: Any?]) -> Void) {
    self.emit = emit
  }

  private func send(_ event: [String: Any?]) {
    DispatchQueue.main.async { self.emit(event) }
  }

  // MARK: - Discovery and hotplug

  /// Starts forwarding attach/detach events. Idempotent; main queue.
  func startMonitoring() {
    guard notifyPort == nil, let port = IONotificationPortCreate(mach_port_t(MACH_PORT_NULL)) else {
      return
    }
    notifyPort = port
    IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

    let refcon = Unmanaged.passUnretained(self).toOpaque()
    let callback: IOServiceMatchingCallback = { refcon, iterator in
      TrezorUsbTransport.drain(iterator)
      guard let refcon else { return }
      Unmanaged<TrezorUsbTransport>.fromOpaque(refcon).takeUnretainedValue().rescan()
    }
    for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
      var iterator: io_iterator_t = 0
      let status = IOServiceAddMatchingNotification(
        port, type, IOServiceMatching("IOUSBHostInterface"), callback, refcon, &iterator)
      guard status == KERN_SUCCESS else { continue }
      // Draining arms the notification.
      TrezorUsbTransport.drain(iterator)
      iterators.append(iterator)
    }
    known = TrezorUsbTransport.enumerate()
  }

  private static func drain(_ iterator: io_iterator_t) {
    while case let service = IOIteratorNext(iterator), service != 0 {
      IOObjectRelease(service)
    }
  }

  /// Re-reads the registry and reports what was plugged in or pulled out.
  private func rescan() {
    let current = TrezorUsbTransport.enumerate()
    let previous = known
    known = current
    for (id, entry) in current where previous[id] == nil {
      emit(["event": "usbAttached", "device": describe(entry)])
    }
    for id in previous.keys where current[id] == nil {
      if let open = removeConnection(id) {
        control.async { open.close() }
        emit(["event": "disconnected", "deviceId": id, "reason": "USB device detached"])
      }
      emit(["event": "usbDetached", "deviceId": id])
    }
  }

  func listDevices() -> [[String: Any?]] {
    startMonitoring()
    known = TrezorUsbTransport.enumerate()
    return known.values.sorted { $0.deviceId < $1.deviceId }.map(describe)
  }

  func hasDevice(_ deviceId: String) -> Bool {
    if known[deviceId] == nil { known = TrezorUsbTransport.enumerate() }
    return known[deviceId] != nil
  }

  private func describe(_ entry: Entry) -> [String: Any?] {
    [
      "deviceId": entry.deviceId,
      "transport": "usb",
      "name": entry.name,
      "vendorId": entry.vendorId,
      "productId": entry.productId,
      // macOS has no per-device USB permission.
      "hasPermission": true,
    ]
  }

  /// Every plugged-in Trezor's wire interface: per device, the lowest-numbered
  /// vendor-class interface (a debug firmware adds a second one for DebugLink).
  private static func enumerate() -> [String: Entry] {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        mach_port_t(MACH_PORT_NULL), IOServiceMatching("IOUSBHostInterface"), &iterator)
        == KERN_SUCCESS
    else { return [:] }
    defer { IOObjectRelease(iterator) }

    var best: [String: (number: Int, entry: Entry)] = [:]
    while case let service = IOIteratorNext(iterator), service != 0 {
      defer { IOObjectRelease(service) }
      guard ownInt(service, "bInterfaceClass") == vendorClass,
        let vendorId = searchInt(service, "idVendor"),
        let productId = searchInt(service, "idProduct"),
        trezorIds.contains([vendorId, productId]),
        let deviceEntryId = parentEntryId(service),
        let interfaceEntryId = entryId(service)
      else { continue }

      let number = ownInt(service, "bInterfaceNumber") ?? 0
      let deviceId = "usb-\(deviceEntryId)"
      if let existing = best[deviceId], existing.number <= number { continue }
      let name =
        searchString(service, "USB Product Name") ?? searchString(service, "kUSBProductString")
        ?? "Trezor"
      best[deviceId] = (
        number,
        Entry(
          deviceId: deviceId, interfaceEntryId: interfaceEntryId, vendorId: vendorId,
          productId: productId, name: name)
      )
    }
    return best.mapValues(\.entry)
  }

  private static func ownInt(_ service: io_service_t, _ key: String) -> Int? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? Int
  }

  /// Looks on the interface, then on its parents (the device).
  private static func searchProperty(_ service: io_service_t, _ key: String) -> CFTypeRef? {
    IORegistryEntrySearchCFProperty(
      service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
      IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
  }

  private static func searchInt(_ service: io_service_t, _ key: String) -> Int? {
    searchProperty(service, key) as? Int
  }

  private static func searchString(_ service: io_service_t, _ key: String) -> String? {
    searchProperty(service, key) as? String
  }

  private static func entryId(_ entry: io_registry_entry_t) -> UInt64? {
    var id: UInt64 = 0
    return IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS ? id : nil
  }

  private static func parentEntryId(_ service: io_service_t) -> UInt64? {
    var parent: io_registry_entry_t = 0
    guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else {
      return nil
    }
    defer { IOObjectRelease(parent) }
    return entryId(parent)
  }

  // MARK: - Open / write / close

  func isOpen(_ deviceId: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return connections[deviceId] != nil
  }

  private func connection(_ deviceId: String) -> Connection? {
    lock.lock()
    defer { lock.unlock() }
    return connections[deviceId]
  }

  private func removeConnection(_ deviceId: String) -> Connection? {
    lock.lock()
    defer { lock.unlock() }
    return connections.removeValue(forKey: deviceId)
  }

  /// Main queue.
  func open(deviceId: String, result: @escaping FlutterResult) {
    guard hasDevice(deviceId), let entry = known[deviceId] else {
      return result(
        FlutterError(code: "deviceNotFound", message: "USB device \(deviceId) not found", details: nil))
    }
    startMonitoring()
    control.async { [self] in
      removeConnection(deviceId)?.close()
      do {
        let open = try openInterface(entry)
        lock.lock()
        connections[deviceId] = open
        lock.unlock()
        open.start()
        reply(result, ["packetSize": TrezorUsbTransport.packetSize])
      } catch let error as TransportError {
        reply(result, error.flutterError)
      } catch {
        reply(result, FlutterError(code: "openFailed", message: error.localizedDescription, details: nil))
      }
    }
  }

  // IOUSBLib's plug-in UUIDs are C macros, which Swift does not import.
  /// kIOUSBInterfaceUserClientTypeID
  private static let interfaceUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(
    nil, 0x2D, 0x97, 0x86, 0xC6, 0x9E, 0xF3, 0x11, 0xD4, 0xAD, 0x51, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)
  /// kIOCFPlugInInterfaceID
  private static let plugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(
    nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
  /// kIOUSBInterfaceInterfaceID190
  private static let interfaceInterfaceID = CFUUIDGetConstantUUIDWithBytes(
    nil, 0x8F, 0xDB, 0x84, 0x55, 0x74, 0xA6, 0x11, 0xD6, 0x97, 0xB1, 0x00, 0x30, 0x65, 0xD3, 0x60, 0x8E)

  private func openInterface(_ entry: Entry) throws -> Connection {
    let service = IOServiceGetMatchingService(
      mach_port_t(MACH_PORT_NULL), IORegistryEntryIDMatching(entry.interfaceEntryId))
    guard service != 0 else {
      throw TransportError(
        code: "deviceNotFound", message: "USB device \(entry.deviceId) not found", details: nil)
    }
    defer { IOObjectRelease(service) }

    var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
    var score: Int32 = 0
    let created = IOCreatePlugInInterfaceForService(
      service, TrezorUsbTransport.interfaceUserClientTypeID, TrezorUsbTransport.plugInInterfaceID,
      &plugIn, &score)
    guard created == KERN_SUCCESS, let plugIn, let plugInTable = plugIn.pointee else {
      throw TransportError(
        code: "openFailed", message: "Unable to access the USB device (\(hex(created)))",
        details: nil)
    }
    var raw: LPVOID?
    let queried = plugInTable.pointee.QueryInterface(
      plugIn, CFUUIDGetUUIDBytes(TrezorUsbTransport.interfaceInterfaceID), &raw)
    _ = plugInTable.pointee.Release(plugIn)
    guard queried == 0, let raw else {
      throw TransportError(
        code: "openFailed", message: "Unable to access the USB interface", details: nil)
    }
    let interface = raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBInterfaceInterface190>.self)

    let opened = interface.pointee.pointee.USBInterfaceOpen(interface)
    guard opened == kIOReturnSuccess else {
      _ = interface.pointee.pointee.Release(interface)
      throw TransportError(
        code: "openFailed",
        message: opened == kIOReturnExclusiveAccess
          ? "USB interface is in use (is Trezor Suite or trezord connected to the Trezor?)"
          : "Unable to open USB device (\(hex(opened)))",
        details: nil)
    }

    let (inPipe, outPipe) = TrezorUsbTransport.pipes(of: interface)
    guard let inPipe, let outPipe else {
      _ = interface.pointee.pointee.USBInterfaceClose(interface)
      _ = interface.pointee.pointee.Release(interface)
      throw TransportError(code: "openFailed", message: "Trezor USB endpoints not found", details: nil)
    }
    return Connection(
      deviceId: entry.deviceId, interface: interface, inPipe: inPipe, outPipe: outPipe, owner: self)
  }

  /// The pipe refs (1-based endpoint indexes) of the first IN and first OUT
  /// endpoint.
  private static func pipes(of interface: InterfaceRef) -> (UInt8?, UInt8?) {
    var count: UInt8 = 0
    guard interface.pointee.pointee.GetNumEndpoints(interface, &count) == kIOReturnSuccess,
      count > 0
    else { return (nil, nil) }
    var input: UInt8?
    var output: UInt8?
    for pipe in 1...count {
      var direction: UInt8 = 0
      var number: UInt8 = 0
      var transferType: UInt8 = 0
      var maxPacketSize: UInt16 = 0
      var interval: UInt8 = 0
      guard
        interface.pointee.pointee.GetPipeProperties(
          interface, pipe, &direction, &number, &transferType, &maxPacketSize, &interval)
          == kIOReturnSuccess
      else { continue }
      if direction == UInt8(kUSBIn) {
        if input == nil { input = pipe }
      } else if direction == UInt8(kUSBOut), output == nil {
        output = pipe
      }
    }
    return (input, output)
  }

  func write(deviceId: String, data: Data, result: @escaping FlutterResult) {
    guard let open = connection(deviceId) else {
      return result(
        FlutterError(code: "notConnected", message: "USB device \(deviceId) is not open", details: nil))
    }
    open.write(data) { [self] error in reply(result, error) }
  }

  func close(deviceId: String) {
    guard let open = removeConnection(deviceId) else { return }
    control.async { open.close() }
  }

  /// A read or write failed on a device that was not closed from Dart.
  fileprivate func failed(_ open: Connection, reason: String) {
    DispatchQueue.main.async { [self] in
      // Already gone if it was unplugged (rescan) or closed.
      guard connection(open.deviceId) === open else { return }
      _ = removeConnection(open.deviceId)
      control.async { open.close() }
      emit(["event": "disconnected", "deviceId": open.deviceId, "reason": reason])
    }
  }

  fileprivate func packet(_ data: Data, from deviceId: String) {
    send(["event": "packet", "deviceId": deviceId, "data": FlutterStandardTypedData(bytes: data)])
  }

  private func reply(_ result: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { result(value) }
  }

  func dispose() {
    lock.lock()
    let open = Array(connections.values)
    connections.removeAll()
    lock.unlock()
    control.async { open.forEach { $0.close() } }
    iterators.forEach { IOObjectRelease($0) }
    iterators.removeAll()
    if let notifyPort { IONotificationPortDestroy(notifyPort) }
    notifyPort = nil
  }

  // MARK: - Connection

  fileprivate final class Connection {
    let deviceId: String
    private let interface: InterfaceRef
    private let inPipe: UInt8
    private let outPipe: UInt8
    private weak var owner: TrezorUsbTransport?
    private let writes: DispatchQueue
    private let readerExited = DispatchSemaphore(value: 0)

    private let stateLock = NSLock()
    private var _closed = false
    private var closed: Bool {
      stateLock.lock()
      defer { stateLock.unlock() }
      return _closed
    }

    init(
      deviceId: String, interface: InterfaceRef, inPipe: UInt8, outPipe: UInt8,
      owner: TrezorUsbTransport
    ) {
      self.deviceId = deviceId
      self.interface = interface
      self.inPipe = inPipe
      self.outPipe = outPipe
      self.owner = owner
      self.writes = DispatchQueue(label: "trezor_flutter.usb.write.\(deviceId)")
    }

    func start() {
      let reader = Thread { [self] in
        readLoop()
        readerExited.signal()
      }
      reader.name = "trezor_flutter.usb.read"
      reader.start()
    }

    private func readLoop() {
      var buffer = [UInt8](repeating: 0, count: TrezorUsbTransport.packetSize)
      while !closed {
        var size = UInt32(buffer.count)
        // Blocks until a packet arrives; close() aborts it.
        let status = buffer.withUnsafeMutableBytes {
          interface.pointee.pointee.ReadPipe(interface, inPipe, $0.baseAddress, &size)
        }
        if closed { return }
        guard status == kIOReturnSuccess else {
          owner?.failed(self, reason: "USB read failed (\(hex(status)))")
          return
        }
        if size > 0 { owner?.packet(Data(buffer.prefix(Int(size))), from: deviceId) }
      }
    }

    func write(_ data: Data, completion: @escaping (FlutterError?) -> Void) {
      writes.async { [self] in
        guard !closed else {
          return completion(
            FlutterError(code: "notConnected", message: "USB device \(deviceId) is not open", details: nil))
        }
        var bytes = [UInt8](data)
        let status = bytes.withUnsafeMutableBytes {
          interface.pointee.pointee.WritePipe(interface, outPipe, $0.baseAddress, UInt32($0.count))
        }
        completion(
          status == kIOReturnSuccess
            ? nil
            : FlutterError(code: "writeFailed", message: "USB write failed (\(hex(status)))", details: nil))
      }
    }

    /// Releases a blocked read or write and the interface. Idempotent; runs on
    /// the control queue.
    func close() {
      stateLock.lock()
      if _closed {
        stateLock.unlock()
        return
      }
      _closed = true
      stateLock.unlock()
      _ = interface.pointee.pointee.AbortPipe(interface, inPipe)
      _ = interface.pointee.pointee.AbortPipe(interface, outPipe)
      let readerDone = readerExited.wait(timeout: .now() + 2) == .success
      writes.sync {}
      _ = interface.pointee.pointee.USBInterfaceClose(interface)
      // Freeing the interface under a read that did not return would crash;
      // leak it instead in that (unexpected) case.
      if readerDone { _ = interface.pointee.pointee.Release(interface) }
    }
  }
}

private typealias InterfaceRef = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface190>>

/// An IOReturn as the hex code Apple documents it by.
private func hex(_ status: IOReturn) -> String {
  String(format: "0x%08x", UInt32(bitPattern: status))
}

/// A failure with one of the channel's error codes (see
/// `TrezorPlatformErrorCode`). FlutterError itself cannot be thrown.
private struct TransportError: Error {
  let code: String
  let message: String

  init(code: String, message: String, details: Any?) {
    self.code = code
    self.message = message
  }

  var flutterError: FlutterError { FlutterError(code: code, message: message, details: nil) }
}
