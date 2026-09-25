import CoreBluetooth
import Flutter
import Foundation

/// CoreBluetooth packet pipe for Trezor Safe 7 (and later BLE models).
///
/// GATT layout (trezorlib `transport/ble.py`): service `8c000001-…`, RX
/// `8c000002-…` (host writes), TX `8c000003-…` (device notifies). Packets are
/// 244 bytes.
///
/// The central manager is created lazily, on the first call that needs it:
/// creating one is what makes iOS show the Bluetooth permission prompt, and it
/// should appear when the user chooses to connect a Trezor, not at launch.
///
/// Link encryption (the OS pairing dialog with Numeric Comparison) is handled
/// by iOS itself: subscribing to the encrypted TX characteristic triggers it,
/// and the subscription completes once the user has confirmed.
///
/// Everything runs on the main queue, so no state here needs locking and
/// events can go straight to the FlutterEventSink.
final class TrezorBleCentral: NSObject, CBCentralManagerDelegate {
  private static let serviceUUID = CBUUID(string: "8C000001-A59B-4D58-A9AD-073DF69FA1B1")
  private static let rxUUID = CBUUID(string: "8C000002-A59B-4D58-A9AD-073DF69FA1B1")
  private static let txUUID = CBUUID(string: "8C000003-A59B-4D58-A9AD-073DF69FA1B1")
  private static let packetSize = 244

  /// Covers the system pairing dialog, which the user has to read and confirm.
  private static let openTimeout: TimeInterval = 90

  private let emit: ([String: Any?]) -> Void
  private var central: CBCentralManager?
  private var peripherals: [String: CBPeripheral] = [:]
  private var wantsScan = false
  /// Work waiting for the adapter to leave `.unknown`/`.resetting`.
  private var whenReady: [(CBManagerState) -> Void] = []

  private var session: Session?

  init(emit: @escaping ([String: Any?]) -> Void) {
    self.emit = emit
  }

  // MARK: - Manager

  private func manager() -> CBCentralManager {
    if let central { return central }
    let created = CBCentralManager(
      delegate: self, queue: nil,
      options: [CBCentralManagerOptionShowPowerAlertKey: false])
    central = created
    return created
  }

  /// Runs [action] once the manager knows whether Bluetooth is usable.
  private func withState(_ action: @escaping (CBManagerState) -> Void) {
    let manager = manager()
    switch manager.state {
    case .unknown, .resetting: whenReady.append(action)
    default: action(manager.state)
    }
  }

  private static func describe(_ state: CBManagerState) -> String {
    switch state {
    case .poweredOn: return "on"
    case .poweredOff: return "off"
    case .unauthorized: return "unauthorized"
    case .unsupported: return "unavailable"
    default: return "unknown"
    }
  }

  private static func error(for state: CBManagerState) -> FlutterError? {
    switch state {
    case .poweredOn: return nil
    case .poweredOff: return FlutterError(code: "bluetoothOff", message: "Bluetooth is off", details: nil)
    case .unauthorized:
      return FlutterError(code: "permissionDenied", message: "Bluetooth permission denied", details: nil)
    case .unsupported:
      return FlutterError(code: "bluetoothUnavailable", message: "Bluetooth LE unsupported", details: nil)
    default:
      return FlutterError(code: "bluetoothUnavailable", message: "Bluetooth not ready", details: nil)
    }
  }

  /// Answers without prompting: before the user has decided, report
  /// "unknown" rather than creating the manager.
  func stateString() -> String {
    switch CBCentralManager.authorization {
    case .notDetermined: return "unknown"
    case .denied, .restricted: return "unauthorized"
    default: return TrezorBleCentral.describe(manager().state)
    }
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    emit(["event": "bluetoothState", "state": TrezorBleCentral.describe(central.state)])
    if central.state != .unknown && central.state != .resetting {
      let actions = whenReady
      whenReady.removeAll()
      actions.forEach { $0(central.state) }
    }
    if central.state == .poweredOn {
      if wantsScan { beginScan() }
    } else {
      session?.fail(code: "bluetoothOff", message: "Bluetooth became unavailable")
    }
  }

  // MARK: - Scan

  func startScan(result: @escaping FlutterResult) {
    withState { [weak self] state in
      guard let self else { return }
      if let error = TrezorBleCentral.error(for: state) {
        result(error)
        return
      }
      self.wantsScan = true
      self.beginScan()
      result(nil)
    }
  }

  private func beginScan() {
    guard let central, central.state == .poweredOn else { return }
    // A Trezor already connected to this phone (by us, or restored by the
    // system) does not advertise; list those first.
    for peripheral in central.retrieveConnectedPeripherals(withServices: [TrezorBleCentral.serviceUUID]) {
      report(peripheral, name: peripheral.name, rssi: nil)
    }
    central.scanForPeripherals(
      withServices: [TrezorBleCentral.serviceUUID],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
  }

  func stopScan() {
    wantsScan = false
    if let central, central.state == .poweredOn { central.stopScan() }
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi RSSI: NSNumber
  ) {
    let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
    report(peripheral, name: name, rssi: RSSI.intValue)
  }

  private func report(_ peripheral: CBPeripheral, name: String?, rssi: Int?) {
    let id = peripheral.identifier.uuidString
    peripherals[id] = peripheral
    emit([
      "event": "bleScanResult",
      "device": [
        "deviceId": id,
        "transport": "ble",
        "name": name ?? "Trezor",
        "rssi": rssi,
      ] as [String: Any?],
    ])
  }

  // MARK: - Open / write / close

  func open(deviceId: String, result: @escaping FlutterResult) {
    withState { [weak self] state in
      guard let self else { return }
      if let error = TrezorBleCentral.error(for: state) {
        result(error)
        return
      }
      if let current = self.session {
        if current.deviceId == deviceId && current.ready {
          result(["packetSize": TrezorBleCentral.packetSize])
          return
        }
        current.close()
      }
      guard let peripheral = self.lookup(deviceId) else {
        result(FlutterError(code: "deviceNotFound", message: "Unknown Trezor \(deviceId); scan first", details: nil))
        return
      }
      self.stopScan()
      let session = Session(owner: self, peripheral: peripheral, result: result)
      self.session = session
      session.start()
    }
  }

  private func lookup(_ deviceId: String) -> CBPeripheral? {
    if let known = peripherals[deviceId] { return known }
    guard let uuid = UUID(uuidString: deviceId), let central else { return nil }
    let found = central.retrievePeripherals(withIdentifiers: [uuid]).first
    if let found { peripherals[deviceId] = found }
    return found
  }

  func write(deviceId: String, data: Data, result: @escaping FlutterResult) {
    guard let session, session.deviceId == deviceId, session.ready else {
      result(FlutterError(code: "notConnected", message: "Trezor \(deviceId) is not open", details: nil))
      return
    }
    session.enqueue(data, result)
  }

  func close(deviceId: String) {
    if let session, session.deviceId == deviceId { session.close() }
  }

  fileprivate func ended(_ session: Session) {
    if self.session === session { self.session = nil }
  }

  fileprivate func connect(_ peripheral: CBPeripheral) { central?.connect(peripheral) }

  fileprivate func cancel(_ peripheral: CBPeripheral) { central?.cancelPeripheralConnection(peripheral) }

  fileprivate func send(_ event: [String: Any?]) { emit(event) }

  // Connection callbacks are delivered to the manager's delegate; route them.

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    session(for: peripheral)?.didConnect()
  }

  func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
  ) {
    session(for: peripheral)?.fail(
      code: "openFailed", message: error?.localizedDescription ?? "Could not connect to Trezor")
  }

  func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
  ) {
    session(for: peripheral)?.fail(
      code: "openFailed", message: error?.localizedDescription ?? "Trezor disconnected")
  }

  private func session(for peripheral: CBPeripheral) -> Session? {
    guard let session, session.peripheral === peripheral else { return nil }
    return session
  }

  // MARK: - Session

  fileprivate final class Session: NSObject, CBPeripheralDelegate {
    weak var owner: TrezorBleCentral?
    let peripheral: CBPeripheral
    let deviceId: String
    private var openResult: FlutterResult?
    private(set) var ready = false
    private var closed = false
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var timer: Timer?
    private var writes: [(Data, FlutterResult)] = []
    private var inFlight: FlutterResult?

    init(owner: TrezorBleCentral, peripheral: CBPeripheral, result: @escaping FlutterResult) {
      self.owner = owner
      self.peripheral = peripheral
      self.deviceId = peripheral.identifier.uuidString
      self.openResult = result
    }

    func start() {
      peripheral.delegate = self
      timer = Timer.scheduledTimer(withTimeInterval: TrezorBleCentral.openTimeout, repeats: false) {
        [weak self] _ in
        self?.fail(code: "timeout", message: "Timed out connecting to Trezor")
      }
      if peripheral.state == .connected {
        didConnect()
      } else {
        owner?.connect(peripheral)
      }
    }

    func didConnect() {
      guard !closed else { return }
      peripheral.discoverServices([TrezorBleCentral.serviceUUID])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
      guard !closed else { return }
      guard error == nil,
        let service = peripheral.services?.first(where: { $0.uuid == TrezorBleCentral.serviceUUID })
      else {
        return fail(code: "openFailed", message: "Trezor GATT service not found")
      }
      peripheral.discoverCharacteristics([TrezorBleCentral.rxUUID, TrezorBleCentral.txUUID], for: service)
    }

    func peripheral(
      _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
      guard !closed else { return }
      rx = service.characteristics?.first(where: { $0.uuid == TrezorBleCentral.rxUUID })
      tx = service.characteristics?.first(where: { $0.uuid == TrezorBleCentral.txUUID })
      guard error == nil, rx != nil, let tx else {
        return fail(code: "openFailed", message: "Trezor GATT characteristics not found")
      }
      // Encrypted characteristic: iOS runs BLE pairing here if needed.
      peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(
      _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
      error: Error?
    ) {
      guard !closed, characteristic.uuid == TrezorBleCentral.txUUID else { return }
      if let error {
        return fail(
          code: "bondingFailed",
          message: "Could not subscribe (Bluetooth pairing declined?): \(error.localizedDescription)")
      }
      // iOS negotiates the MTU itself. A write longer than MTU-3 would become
      // a "long write", which the Trezor does not accept, so insist on room
      // for a whole packet.
      let room = peripheral.maximumWriteValueLength(for: .withoutResponse)
      guard room >= TrezorBleCentral.packetSize else {
        return fail(code: "openFailed", message: "BLE MTU too small (\(room + 3)) for Trezor packets")
      }
      timer?.invalidate()
      ready = true
      openResult?(["packetSize": TrezorBleCentral.packetSize])
      openResult = nil
    }

    func peripheral(
      _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
      guard ready, !closed, characteristic.uuid == TrezorBleCentral.txUUID, error == nil,
        let value = characteristic.value
      else { return }
      owner?.send([
        "event": "packet", "deviceId": deviceId, "data": FlutterStandardTypedData(bytes: value),
      ])
    }

    // One write in flight at a time, completed by the write response, which
    // gives the Dart side natural flow control.
    func enqueue(_ data: Data, _ result: @escaping FlutterResult) {
      writes.append((data, result))
      pump()
    }

    private func pump() {
      guard inFlight == nil, !closed, let rx, !writes.isEmpty else { return }
      let (data, result) = writes.removeFirst()
      inFlight = result
      peripheral.writeValue(data, for: rx, type: .withResponse)
    }

    func peripheral(
      _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
    ) {
      guard let result = inFlight else { return }
      inFlight = nil
      if let error {
        result(FlutterError(code: "writeFailed", message: error.localizedDescription, details: nil))
      } else {
        result(nil)
      }
      pump()
    }

    /// Error path: fails a pending open, or reports a disconnect of a ready link.
    func fail(code: String, message: String) {
      guard !closed else { return }
      let wasReady = ready
      let pending = openResult
      teardown()
      if let pending {
        pending(FlutterError(code: code, message: message, details: nil))
      } else if wasReady {
        owner?.send(["event": "disconnected", "deviceId": deviceId, "reason": message])
      }
    }

    /// Closed from Dart: no event.
    func close() {
      guard !closed else { return }
      let pending = openResult
      teardown()
      pending?(FlutterError(code: "openFailed", message: "Closed while opening", details: nil))
    }

    private func teardown() {
      closed = true
      ready = false
      openResult = nil
      timer?.invalidate()
      timer = nil
      let failure = FlutterError(code: "notConnected", message: "Trezor disconnected", details: nil)
      inFlight?(failure)
      inFlight = nil
      writes.forEach { $0.1(failure) }
      writes.removeAll()
      if let tx, peripheral.state == .connected { peripheral.setNotifyValue(false, for: tx) }
      owner?.cancel(peripheral)
      owner?.ended(self)
    }
  }
}
