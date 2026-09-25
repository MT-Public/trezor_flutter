package io.github.mtpublic.trezor_flutter

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import java.util.UUID

/**
 * Bluetooth LE packet pipe for Trezor Safe 7 (and later BLE models).
 *
 * GATT layout, from trezorlib's `transport/ble.py`:
 * - service `8c000001-a59b-4d58-a9ad-073df69fa1b1`
 * - RX `8c000002-…` — host writes packets here
 * - TX `8c000003-…` — device notifies packets here
 *
 * Packets are 244 bytes, which needs an ATT MTU of at least 247.
 *
 * The link must be encrypted: Trezor uses LE Secure Connections with Numeric
 * Comparison, so [open] bonds before touching the characteristics and the OS
 * shows its pairing dialog, with the same number displayed on the Trezor. This
 * BLE bond is separate from, and comes before, the THP pairing done in Dart.
 *
 * Every GATT callback arrives on a binder thread and is posted to the main
 * thread, so all session state below is only touched on the main thread. GATT
 * allows one outstanding operation at a time; opening is a strict sequence and
 * writes go through [WriteQueue].
 *
 * One BLE Trezor at a time: a phone is only ever talking to one.
 */
@SuppressLint("MissingPermission") // Checked at runtime; SecurityException is mapped.
internal class TrezorBleTransport(
    private val context: Context,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    private companion object {
        val SERVICE_UUID: UUID = UUID.fromString("8c000001-a59b-4d58-a9ad-073df69fa1b1")
        val RX_UUID: UUID = UUID.fromString("8c000002-a59b-4d58-a9ad-073df69fa1b1")
        val TX_UUID: UUID = UUID.fromString("8c000003-a59b-4d58-a9ad-073df69fa1b1")
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        const val PACKET_SIZE = 244
        const val REQUIRED_MTU = PACKET_SIZE + 3

        /** Connect + MTU + discovery, excluding time spent in the pairing dialog. */
        const val OPEN_TIMEOUT_MS = 30_000L

        /** The user has to compare numbers on two screens. */
        const val BOND_TIMEOUT_MS = 120_000L

        // GATT statuses that mean "encrypt the link first".
        const val GATT_INSUFFICIENT_AUTHENTICATION = 5
        const val GATT_INSUFFICIENT_ENCRYPTION = 15
        const val GATT_AUTH_FAIL = 137
    }

    private val main = Handler(Looper.getMainLooper())
    private val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? get() = manager?.adapter

    private var scanning = false
    private var session: Session? = null

    // ---------------------------------------------------------------- state

    private val stateReceiver = object : BroadcastReceiver() {
        override fun onReceive(receiverContext: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            emit(mapOf("event" to "bluetoothState", "state" to adapterState()))
            if (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1) == BluetoothAdapter.STATE_OFF) {
                scanning = false
                session?.fail("bluetoothOff", "Bluetooth was turned off")
            }
        }
    }

    init {
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(stateReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(stateReceiver, filter)
        }
    }

    fun adapterState(): String {
        val adapter = this.adapter ?: return "unavailable"
        if (!hasPermission(Manifest.permission.BLUETOOTH_CONNECT)) return "unauthorized"
        return if (adapter.isEnabled) "on" else "off"
    }

    private fun hasPermission(permission: String): Boolean {
        // The API 31 runtime permissions do not exist below 31.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }

    /** Null if usable, else an (errorCode, message) pair. */
    private fun unusable(vararg permissions: String): Pair<String, String>? {
        val adapter = this.adapter ?: return "bluetoothUnavailable" to "No Bluetooth adapter"
        permissions.firstOrNull { !hasPermission(it) }?.let {
            return "permissionDenied" to "$it not granted"
        }
        if (!adapter.isEnabled) return "bluetoothOff" to "Bluetooth is off"
        return null
    }

    // ----------------------------------------------------------------- scan

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            main.post {
                val device = result.device
                val name = result.scanRecord?.deviceName ?: safeName(device) ?: "Trezor"
                emit(
                    mapOf(
                        "event" to "bleScanResult",
                        "device" to mapOf(
                            "deviceId" to device.address,
                            "transport" to "ble",
                            "name" to name,
                            "rssi" to result.rssi,
                        ),
                    )
                )
            }
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            results.forEach { onScanResult(ScanSettings.CALLBACK_TYPE_ALL_MATCHES, it) }
        }

        override fun onScanFailed(errorCode: Int) {
            main.post {
                scanning = false
                emit(mapOf("event" to "bleScanFailed", "code" to "scanFailed",
                    "message" to "BLE scan failed ($errorCode)"))
            }
        }
    }

    private fun safeName(device: BluetoothDevice): String? =
        try { device.name } catch (_: SecurityException) { null }

    fun startScan(result: MethodChannel.Result) {
        unusable(Manifest.permission.BLUETOOTH_SCAN)?.let { (code, message) ->
            result.error(code, message, null)
            return
        }
        val scanner = adapter?.bluetoothLeScanner
        if (scanner == null) {
            result.error("bluetoothOff", "BLE scanner unavailable", null)
            return
        }
        try {
            if (scanning) scanner.stopScan(scanCallback)
            val filters = listOf(
                ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build()
            )
            val settings = ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .build()
            scanner.startScan(filters, settings, scanCallback)
            scanning = true
            result.success(null)
        } catch (ex: SecurityException) {
            result.error("permissionDenied", ex.message ?: "Bluetooth permission denied", null)
        }
    }

    fun stopScan() {
        if (!scanning) return
        scanning = false
        try {
            adapter?.bluetoothLeScanner?.stopScan(scanCallback)
        } catch (_: SecurityException) {
            // Permission revoked mid-scan; nothing to stop.
        } catch (_: IllegalStateException) {
            // Adapter turned off.
        }
    }

    // ------------------------------------------------------------ open/close

    fun isOpen(deviceId: String) = session?.let { it.deviceId == deviceId && it.ready } == true

    fun open(deviceId: String, result: MethodChannel.Result) {
        unusable(Manifest.permission.BLUETOOTH_CONNECT)?.let { (code, message) ->
            result.error(code, message, null)
            return
        }
        session?.let {
            if (it.deviceId == deviceId && it.ready) {
                result.success(mapOf("packetSize" to PACKET_SIZE))
                return
            }
            it.close()
        }
        val device = try {
            adapter!!.getRemoteDevice(deviceId)
        } catch (_: IllegalArgumentException) {
            result.error("deviceNotFound", "Invalid Bluetooth address $deviceId", null)
            return
        }
        // Scanning slows connection setup considerably on many chipsets.
        stopScan()
        session = Session(device, result).also { it.start() }
    }

    fun write(deviceId: String, data: ByteArray, result: MethodChannel.Result) {
        val s = session
        if (s == null || s.deviceId != deviceId || !s.ready) {
            result.error("notConnected", "BLE device $deviceId is not open", null)
            return
        }
        s.writes.enqueue(data, result)
    }

    fun close(deviceId: String) {
        val s = session ?: return
        if (s.deviceId == deviceId) s.close()
    }

    fun dispose() {
        stopScan()
        session?.close()
        try {
            context.unregisterReceiver(stateReceiver)
        } catch (_: IllegalArgumentException) {
            // Not registered.
        }
    }

    // --------------------------------------------------------------- session

    private inner class Session(
        val device: BluetoothDevice,
        private var openResult: MethodChannel.Result?,
    ) {
        val deviceId: String = device.address
        var ready = false
            private set

        private var gatt: BluetoothGatt? = null
        private var rx: BluetoothGattCharacteristic? = null
        private var tx: BluetoothGattCharacteristic? = null
        private var bondReceiver: BroadcastReceiver? = null
        private var retriedAfterBond = false
        private var closed = false
        val writes = WriteQueue()

        private val openTimeout = Runnable {
            fail("timeout", "Timed out connecting to Trezor")
        }

        fun start() {
            main.postDelayed(openTimeout, OPEN_TIMEOUT_MS)
            try {
                gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
            } catch (ex: SecurityException) {
                fail("permissionDenied", ex.message ?: "Bluetooth permission denied")
            }
        }

        private val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                main.post {
                    if (closed) return@post
                    when (newState) {
                        BluetoothProfile.STATE_CONNECTED -> guard { g.requestMtu(REQUIRED_MTU) }
                        BluetoothProfile.STATE_DISCONNECTED ->
                            fail("openFailed", "Disconnected (GATT status $status)")
                    }
                }
            }

            override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
                main.post {
                    if (closed) return@post
                    if (status != BluetoothGatt.GATT_SUCCESS || mtu < REQUIRED_MTU) {
                        fail("openFailed", "BLE MTU $mtu is too small for Trezor packets")
                        return@post
                    }
                    ensureBonded { guard { g.discoverServices() } }
                }
            }

            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                main.post {
                    if (closed) return@post
                    val service = g.getService(SERVICE_UUID)
                    rx = service?.getCharacteristic(RX_UUID)
                    tx = service?.getCharacteristic(TX_UUID)
                    if (status != BluetoothGatt.GATT_SUCCESS || rx == null || tx == null) {
                        fail("openFailed", "Trezor GATT service not found")
                        return@post
                    }
                    subscribe()
                }
            }

            override fun onDescriptorWrite(
                g: BluetoothGatt,
                descriptor: BluetoothGattDescriptor,
                status: Int,
            ) {
                main.post {
                    if (closed) return@post
                    when {
                        status == BluetoothGatt.GATT_SUCCESS -> becomeReady()
                        isAuthError(status) && !retriedAfterBond -> {
                            // The bond we saw was stale (e.g. the Trezor forgot
                            // this phone). Bond again, then retry once.
                            retriedAfterBond = true
                            ensureBonded(force = true) { subscribe() }
                        }
                        else -> fail("bondingFailed", "Could not enable notifications ($status)")
                    }
                }
            }

            override fun onCharacteristicWrite(
                g: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                main.post { writes.onWritten(status) }
            }

            override fun onCharacteristicChanged(
                g: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
            ) {
                if (characteristic.uuid != TX_UUID) return
                val copy = value.copyOf()
                main.post { onPacket(copy) }
            }

            @Deprecated("Called instead of the ByteArray overload below API 33")
            override fun onCharacteristicChanged(
                g: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
            ) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
                if (characteristic.uuid != TX_UUID) return
                @Suppress("DEPRECATION")
                val copy = characteristic.value?.copyOf() ?: return
                main.post { onPacket(copy) }
            }
        }

        private fun onPacket(data: ByteArray) {
            if (closed || !ready) return
            emit(mapOf("event" to "packet", "deviceId" to deviceId, "data" to data))
        }

        private fun isAuthError(status: Int) =
            status == GATT_INSUFFICIENT_AUTHENTICATION ||
                status == GATT_INSUFFICIENT_ENCRYPTION ||
                status == GATT_AUTH_FAIL

        /**
         * Runs [then] once the device is bonded, creating the bond if needed.
         * The open timeout is paused while the system pairing dialog is up.
         */
        private fun ensureBonded(force: Boolean = false, then: () -> Unit) {
            val state = try { device.bondState } catch (_: SecurityException) { BluetoothDevice.BOND_NONE }
            if (state == BluetoothDevice.BOND_BONDED && !force) {
                then()
                return
            }
            main.removeCallbacks(openTimeout)
            main.postDelayed(openTimeout, BOND_TIMEOUT_MS)

            val receiver = object : BroadcastReceiver() {
                override fun onReceive(receiverContext: Context?, intent: Intent?) {
                    if (intent?.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED) return
                    val changed = intent.bluetoothDevice() ?: return
                    if (changed.address != deviceId) return
                    when (intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1)) {
                        BluetoothDevice.BOND_BONDED -> {
                            unregisterBondReceiver()
                            main.removeCallbacks(openTimeout)
                            main.postDelayed(openTimeout, OPEN_TIMEOUT_MS)
                            if (!closed) then()
                        }
                        BluetoothDevice.BOND_NONE -> {
                            unregisterBondReceiver()
                            fail("bondingFailed", "Bluetooth pairing was cancelled or rejected")
                        }
                    }
                }
            }
            unregisterBondReceiver()
            bondReceiver = receiver
            val filter = IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                context.registerReceiver(receiver, filter)
            }
            // Already BONDING (the stack started it on its own): just wait.
            if (state != BluetoothDevice.BOND_BONDING) {
                val started = try { device.createBond() } catch (_: SecurityException) { false }
                // createBond() returns false when a bond is already in place (force
                // case) — the stack then re-encrypts on access, so carry on.
                if (!started && state == BluetoothDevice.BOND_BONDED) {
                    unregisterBondReceiver()
                    then()
                } else if (!started) {
                    unregisterBondReceiver()
                    fail("bondingFailed", "Could not start Bluetooth pairing")
                }
            }
        }

        private fun unregisterBondReceiver() {
            val receiver = bondReceiver ?: return
            bondReceiver = null
            try {
                context.unregisterReceiver(receiver)
            } catch (_: IllegalArgumentException) {
                // Already gone.
            }
        }

        private fun subscribe() {
            val g = gatt ?: return
            val tx = this.tx ?: return
            val descriptor = tx.getDescriptor(CCCD_UUID)
            if (descriptor == null) {
                fail("openFailed", "Trezor TX characteristic has no CCCD")
                return
            }
            val value = if (tx.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) {
                BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            } else {
                BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
            }
            guard {
                g.setCharacteristicNotification(tx, true)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    g.writeDescriptor(descriptor, value) == BluetoothStatusCodes.SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    descriptor.value = value
                    @Suppress("DEPRECATION")
                    g.writeDescriptor(descriptor)
                }
            }
        }

        private fun becomeReady() {
            main.removeCallbacks(openTimeout)
            ready = true
            openResult?.success(mapOf("packetSize" to PACKET_SIZE))
            openResult = null
        }

        /** Runs a GATT call that reports failure by returning false. */
        private fun guard(call: () -> Boolean) {
            try {
                if (!call()) fail("openFailed", "Bluetooth operation was rejected")
            } catch (ex: SecurityException) {
                fail("permissionDenied", ex.message ?: "Bluetooth permission denied")
            }
        }

        fun writeRaw(data: ByteArray): Boolean {
            val g = gatt ?: return false
            val rx = this.rx ?: return false
            val type = if (rx.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0) {
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            } else {
                BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            }
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    g.writeCharacteristic(rx, data, type) == BluetoothStatusCodes.SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    rx.writeType = type
                    @Suppress("DEPRECATION")
                    rx.value = data
                    @Suppress("DEPRECATION")
                    g.writeCharacteristic(rx)
                }
            } catch (_: SecurityException) {
                false
            }
        }

        /** Tears down after an error: fails the open or reports a disconnect. */
        fun fail(code: String, message: String) {
            if (closed) return
            val wasReady = ready
            val pendingOpen = openResult
            teardown()
            if (pendingOpen != null) {
                pendingOpen.error(code, message, null)
            } else if (wasReady) {
                emit(mapOf("event" to "disconnected", "deviceId" to deviceId, "reason" to message))
            }
        }

        /** Closed from Dart: no event, the caller knows. */
        fun close() {
            if (closed) return
            val pendingOpen = openResult
            teardown()
            pendingOpen?.error("openFailed", "Closed while opening", null)
        }

        private fun teardown() {
            closed = true
            ready = false
            openResult = null
            main.removeCallbacks(openTimeout)
            unregisterBondReceiver()
            writes.failAll("notConnected", "Trezor disconnected")
            try {
                gatt?.disconnect()
                gatt?.close()
            } catch (_: SecurityException) {
                // Permission revoked; the stack drops the link anyway.
            }
            gatt = null
            if (session === this) session = null
        }

        /** GATT allows one write in flight; the rest wait here in order. */
        inner class WriteQueue {
            private val pending = ArrayDeque<Pair<ByteArray, MethodChannel.Result>>()
            private var inFlight: MethodChannel.Result? = null

            fun enqueue(data: ByteArray, result: MethodChannel.Result) {
                pending.add(data to result)
                pump()
            }

            private fun pump() {
                if (inFlight != null || closed) return
                val (data, result) = pending.poll() ?: return
                if (writeRaw(data)) {
                    inFlight = result
                } else {
                    result.error("writeFailed", "BLE write was rejected", null)
                    pump()
                }
            }

            fun onWritten(status: Int) {
                val result = inFlight ?: return
                inFlight = null
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    result.success(null)
                } else {
                    result.error("writeFailed", "BLE write failed ($status)", null)
                }
                pump()
            }

            fun failAll(code: String, message: String) {
                inFlight?.error(code, message, null)
                inFlight = null
                while (pending.isNotEmpty()) pending.poll()?.second?.error(code, message, null)
            }
        }
    }

    private fun Intent.bluetoothDevice(): BluetoothDevice? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
        }
}
