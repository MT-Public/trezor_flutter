package io.github.mtpublic.trezor_flutter

import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Android side of `trezor_flutter`: a packet pipe over USB or BLE.
 *
 * Nothing here knows the Trezor protocol. [TrezorUsbTransport] and
 * [TrezorBleTransport] find devices and move fixed-size packets; framing,
 * encryption and protobuf all happen in Dart. See `trezor_platform.dart` for
 * the channel contract, which the iOS plugin implements identically.
 *
 * Every event is posted to the main thread before it reaches the EventSink,
 * which Flutter requires; both transports call [emit] from their own threads.
 */
class TrezorFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private companion object {
        const val METHOD_CHANNEL = "trezor_flutter/methods"
        const val EVENT_CHANNEL = "trezor_flutter/events"
    }

    private lateinit var context: Context
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var usb: TrezorUsbTransport? = null
    private var ble: TrezorBleTransport? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).also {
            it.setStreamHandler(this)
        }
        usb = TrezorUsbTransport(context, ::emit)
        ble = TrezorBleTransport(context, ::emit)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        usb?.dispose()
        ble?.dispose()
        usb = null
        ble = null
        sink = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(event: Map<String, Any?>) {
        mainHandler.post { sink?.success(event) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val usb = this.usb
        val ble = this.ble
        if (usb == null || ble == null) {
            result.error("notAttached", "Plugin is detached", null)
            return
        }
        when (call.method) {
            "getCapabilities" -> {
                val pm = context.packageManager
                val bluetoothManager =
                    context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
                result.success(
                    mapOf(
                        "usb" to pm.hasSystemFeature(PackageManager.FEATURE_USB_HOST),
                        "ble" to (pm.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) &&
                            bluetoothManager?.adapter != null),
                    )
                )
            }
            "bluetoothState" -> result.success(ble.adapterState())
            "usbListDevices" -> result.success(usb.listDevices())
            "usbRequestPermission" -> usb.requestPermission(requireId(call, result) ?: return, result)
            "bleStartScan" -> ble.startScan(result)
            "bleStopScan" -> {
                ble.stopScan()
                result.success(null)
            }
            "open" -> {
                val id = requireId(call, result) ?: return
                when (call.argument<String>("transport")) {
                    "usb" -> usb.open(id, result)
                    "ble" -> ble.open(id, result)
                    else -> result.error("openFailed", "Unknown transport", null)
                }
            }
            "write" -> {
                val id = requireId(call, result) ?: return
                val data = call.argument<ByteArray>("data")
                if (data == null) {
                    result.error("writeFailed", "Missing data", null)
                    return
                }
                when {
                    usb.isOpen(id) -> usb.write(id, data, result)
                    ble.isOpen(id) -> ble.write(id, data, result)
                    else -> result.error("notConnected", "Device $id is not open", null)
                }
            }
            "close" -> {
                val id = requireId(call, result) ?: return
                usb.close(id)
                ble.close(id)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun requireId(call: MethodCall, result: MethodChannel.Result): String? {
        val id = call.argument<String>("deviceId")
        if (id == null) result.error("deviceNotFound", "Missing deviceId", null)
        return id
    }
}
