package io.github.mtpublic.trezor_flutter

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * USB packet pipe for Trezor devices.
 *
 * Trezors expose the wire protocol on a vendor-class (WebUSB) interface with
 * one interrupt IN and one interrupt OUT endpoint and 64-byte packets. Model
 * One firmware older than 1.7 only has a HID interface instead; its reports are
 * the same 64 bytes, so it is used as a fallback.
 *
 * Threads:
 * - one **reader** thread per open device loops on the IN endpoint and emits
 *   each packet. A Trezor can stay silent for minutes while the user confirms
 *   on its screen, so this must never be the platform thread.
 * - one shared **writer** executor serializes OUT transfers and open/close, so
 *   the packets of a message go out in order and never interleave.
 *
 * Hotplug (attach/detach) broadcasts are forwarded as events for as long as the
 * plugin is attached, filtered to Trezor vendor/product ids.
 */
internal class TrezorUsbTransport(
    private val context: Context,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    private companion object {
        const val PACKET_SIZE = 64
        const val READ_TIMEOUT_MS = 250
        const val WRITE_TIMEOUT_MS = 5_000
        const val VENDOR_CLASS = UsbConstants.USB_CLASS_VENDOR_SPEC
        const val HID_CLASS = UsbConstants.USB_CLASS_HID
        const val ACTION_USB_PERMISSION = "io.github.mtpublic.trezor_flutter.USB_PERMISSION"

        /** (vendorId, productId): Model One, Trezor Core models, Core bootloader. */
        val TREZOR_IDS = setOf(0x534C to 0x0001, 0x1209 to 0x53C1, 0x1209 to 0x53C0)

        fun isTrezor(device: UsbDevice) = (device.vendorId to device.productId) in TREZOR_IDS
    }

    private inner class Connection(
        val deviceName: String,
        val connection: UsbDeviceConnection,
        val usbInterface: UsbInterface,
        val input: UsbEndpoint,
        val output: UsbEndpoint,
    ) {
        @Volatile var closed = false

        private val reader = Thread({ readLoop() }, "trezor_flutter.usb.read").apply {
            isDaemon = true
        }

        fun start() = reader.start()

        private fun readLoop() {
            val buffer = ByteArray(PACKET_SIZE)
            while (!closed) {
                // Negative means timeout (or an error we cannot tell from one);
                // an unplug is reported by the detach broadcast instead.
                val n = connection.bulkTransfer(input, buffer, buffer.size, READ_TIMEOUT_MS)
                if (n > 0 && !closed) {
                    emit(mapOf("event" to "packet", "deviceId" to deviceName,
                        "data" to buffer.copyOf(n)))
                }
            }
        }

        fun close() {
            if (closed) return
            closed = true
            // Closing the connection makes a blocked bulkTransfer return.
            connection.releaseInterface(usbInterface)
            connection.close()
            reader.join(READ_TIMEOUT_MS * 2L)
        }
    }

    private val usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private val io: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "trezor_flutter.usb.io")
    }

    /** Open devices by `UsbDevice.deviceName`. Only mutated on [io]. */
    private val connections = java.util.concurrent.ConcurrentHashMap<String, Connection>()

    private val hotplugReceiver = object : BroadcastReceiver() {
        override fun onReceive(receiverContext: Context?, intent: Intent?) {
            val device = intent?.usbDevice() ?: return
            if (!isTrezor(device)) return
            when (intent.action) {
                UsbManager.ACTION_USB_DEVICE_ATTACHED ->
                    emit(mapOf("event" to "usbAttached", "device" to describe(device)))
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    val name = device.deviceName
                    if (connections.containsKey(name)) {
                        execute { closeNow(name) }
                        emit(mapOf("event" to "disconnected", "deviceId" to name,
                            "reason" to "USB device detached"))
                    }
                    emit(mapOf("event" to "usbDetached", "deviceId" to name))
                }
            }
        }
    }

    init {
        val filter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        // Protected system broadcasts: the receiver need not be exported.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(hotplugReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(hotplugReceiver, filter)
        }
    }

    fun listDevices(): List<Map<String, Any?>> =
        usbManager.deviceList.values.filter(::isTrezor).map(::describe)

    private fun describe(device: UsbDevice): Map<String, Any?> = mapOf(
        "deviceId" to device.deviceName,
        "transport" to "usb",
        "name" to (device.productName ?: "Trezor"),
        "vendorId" to device.vendorId,
        "productId" to device.productId,
        "hasPermission" to usbManager.hasPermission(device),
    )

    fun isOpen(deviceId: String) = connections.containsKey(deviceId)

    fun requestPermission(deviceId: String, result: MethodChannel.Result) {
        val device = usbManager.deviceList[deviceId]
        if (device == null) {
            result.error("deviceNotFound", "USB device $deviceId not found", null)
            return
        }
        if (usbManager.hasPermission(device)) {
            result.success(true)
            return
        }

        val receiver = object : BroadcastReceiver() {
            private var answered = false

            override fun onReceive(receiverContext: Context?, intent: Intent?) {
                if (answered) return
                answered = true
                try {
                    context.unregisterReceiver(this)
                } catch (_: IllegalArgumentException) {
                    // Already unregistered.
                }
                // The manager is the source of truth: the extra is missing on
                // some OEM builds even when the user tapped "Allow".
                result.success(usbManager.hasPermission(device))
            }
        }
        val filter = IntentFilter(ACTION_USB_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Sent by the system on our behalf, so it arrives as external.
            context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }

        // Mutable so the system can attach EXTRA_DEVICE/EXTRA_PERMISSION_GRANTED;
        // package-restricted, which API 34 requires for mutable PendingIntents.
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val intent = Intent(ACTION_USB_PERMISSION).setPackage(context.packageName)
        usbManager.requestPermission(
            device,
            PendingIntent.getBroadcast(context, 0, intent, flags),
        )
    }

    fun open(deviceId: String, result: MethodChannel.Result) = execute(result) {
        closeNow(deviceId)
        val device = usbManager.deviceList[deviceId]
            ?: throw TransportException("deviceNotFound", "USB device $deviceId not found")
        if (!usbManager.hasPermission(device)) {
            throw TransportException("permissionDenied", "No permission for USB device")
        }
        val usbInterface = findInterface(device)
            ?: throw TransportException("openFailed", "Trezor USB interface not found")
        val (input, output) = findEndpoints(usbInterface)
        if (input == null || output == null) {
            throw TransportException("openFailed", "Trezor USB endpoints not found")
        }
        val connection = usbManager.openDevice(device)
            ?: throw TransportException("openFailed", "Unable to open USB device")
        if (!connection.claimInterface(usbInterface, true)) {
            connection.close()
            throw TransportException(
                "openFailed",
                "USB interface is in use (is another app connected to the Trezor?)",
            )
        }
        val open = Connection(deviceId, connection, usbInterface, input, output)
        connections[deviceId] = open
        open.start()
        mapOf("packetSize" to PACKET_SIZE)
    }

    fun write(deviceId: String, data: ByteArray, result: MethodChannel.Result) =
        execute(result) {
            val open = connections[deviceId]
                ?: throw TransportException("notConnected", "USB device $deviceId is not open")
            val n = open.connection.bulkTransfer(open.output, data, data.size, WRITE_TIMEOUT_MS)
            if (n != data.size) {
                throw TransportException("writeFailed", "USB write failed ($n of ${data.size})")
            }
            null
        }

    fun close(deviceId: String) = execute { closeNow(deviceId) }

    private fun closeNow(deviceId: String) {
        connections.remove(deviceId)?.close()
    }

    /**
     * The wire interface: the lowest-numbered vendor-class interface (a debug
     * firmware adds a second one for DebugLink), else HID for old Model Ones.
     */
    private fun findInterface(device: UsbDevice): UsbInterface? {
        val interfaces = (0 until device.interfaceCount).map(device::getInterface)
        return interfaces.filter { it.interfaceClass == VENDOR_CLASS }.minByOrNull { it.id }
            ?: interfaces.filter { it.interfaceClass == HID_CLASS }.minByOrNull { it.id }
    }

    private fun findEndpoints(usbInterface: UsbInterface): Pair<UsbEndpoint?, UsbEndpoint?> {
        val endpoints = (0 until usbInterface.endpointCount).map(usbInterface::getEndpoint)
        return endpoints.firstOrNull { it.direction == UsbConstants.USB_DIR_IN } to
            endpoints.firstOrNull { it.direction == UsbConstants.USB_DIR_OUT }
    }

    private fun execute(work: () -> Unit) {
        try {
            io.execute(work)
        } catch (_: RejectedExecutionException) {
            // Disposed.
        }
    }

    /** Runs [work] on [io] and answers [result] on the main thread. */
    private fun execute(result: MethodChannel.Result, work: () -> Any?) {
        try {
            io.execute {
                try {
                    val value = work()
                    mainHandler.post { result.success(value) }
                } catch (ex: TransportException) {
                    mainHandler.post { result.error(ex.code, ex.message, null) }
                } catch (ex: Exception) {
                    mainHandler.post { result.error("openFailed", ex.message ?: "USB error", null) }
                }
            }
        } catch (_: RejectedExecutionException) {
            result.error("notConnected", "Plugin is detached", null)
        }
    }

    fun dispose() {
        try {
            context.unregisterReceiver(hotplugReceiver)
        } catch (_: IllegalArgumentException) {
            // Not registered.
        }
        execute { connections.keys.toList().forEach(::closeNow) }
        io.shutdown()
    }

    private fun Intent.usbDevice(): UsbDevice? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            getParcelableExtra(UsbManager.EXTRA_DEVICE)
        }
}

/** A failure with one of the channel's error codes (see `TrezorPlatformErrorCode`). */
internal class TransportException(val code: String, message: String) : Exception(message)
