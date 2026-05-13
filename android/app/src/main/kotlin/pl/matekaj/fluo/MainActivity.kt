package pl.matekaj.fluo

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

class MainActivity : FlutterActivity() {

    private val METHOD_CHANNEL = "pl.matekaj.fluo/apator_bt"
    private val DATA_CHANNEL = "pl.matekaj.fluo/apator_bt/data"
    private val STATUS_CHANNEL = "pl.matekaj.fluo/apator_bt/status"

    private var socket: BluetoothSocket? = null
    private var inputStream: InputStream? = null
    private var outputStream: OutputStream? = null
    private var readThread: Thread? = null

    private var dataSink: EventChannel.EventSink? = null
    private var statusSink: EventChannel.EventSink? = null

    @SuppressLint("MissingPermission")
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Data stream (incoming bytes from device)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, DATA_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    dataSink = events
                }
                override fun onCancel(arguments: Any?) {
                    dataSink = null
                }
            })

        // Status stream (0=disconnected, 1=connecting, 2=connected)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, STATUS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    statusSink = events
                }
                override fun onCancel(arguments: Any?) {
                    statusSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPairedDevices" -> getPairedDevices(result)
                    "connect" -> {
                        val address = call.argument<String>("address")!!
                        connectRfcomm(address, result)
                    }
                    "disconnect" -> disconnect(result)
                    "write" -> {
                        val data = call.argument<ByteArray>("data")!!
                        writeData(data, result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @SuppressLint("MissingPermission")
    private fun getPairedDevices(result: MethodChannel.Result) {
        try {
            val btManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
            val adapter = btManager.adapter
            if (adapter == null) {
                result.error("NO_BT", "Bluetooth not available", null)
                return
            }
            val devices = adapter.bondedDevices.map { d ->
                mapOf("name" to (d.name ?: d.address), "address" to d.address)
            }
            result.success(devices)
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    @SuppressLint("MissingPermission")
    private fun connectRfcomm(address: String, result: MethodChannel.Result) {
        Thread {
            try {
                postStatus(1) // connecting
                val btManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
                val adapter = btManager.adapter
                val device: BluetoothDevice = adapter.getRemoteDevice(address)

                // Use createRfcommSocket via reflection (channel 1) - same as Inkasoid
                val method = device.javaClass.getMethod("createRfcommSocket", Int::class.javaPrimitiveType)
                socket = method.invoke(device, 1) as BluetoothSocket

                adapter.cancelDiscovery()
                socket!!.connect()

                inputStream = socket!!.inputStream
                outputStream = socket!!.outputStream

                // Start read thread
                startReadThread()

                postStatus(2) // connected
                Handler(Looper.getMainLooper()).post { result.success(true) }

            } catch (e: Exception) {
                android.util.Log.e("ApatorBT", "connect failed", e)
                postStatus(0) // disconnected
                Handler(Looper.getMainLooper()).post {
                    result.error("CONNECT_FAILED", e.message, null)
                }
            }
        }.start()
    }

    private fun startReadThread() {
        readThread = Thread {
            val buffer = ByteArray(2048)
            while (!Thread.currentThread().isInterrupted) {
                try {
                    val len = inputStream?.read(buffer) ?: -1
                    if (len > 0) {
                        val data = buffer.copyOf(len)
                        Handler(Looper.getMainLooper()).post {
                            dataSink?.success(data)
                        }
                    } else if (len < 0) {
                        break
                    }
                } catch (e: IOException) {
                    break
                }
            }
            postStatus(0)
        }
        readThread!!.start()
    }

    private fun disconnect(result: MethodChannel.Result) {
        try {
            readThread?.interrupt()
            readThread = null
            inputStream?.close()
            outputStream?.close()
            socket?.close()
            socket = null
            postStatus(0)
            result.success(true)
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    private fun writeData(data: ByteArray, result: MethodChannel.Result) {
        try {
            outputStream?.write(data)
            outputStream?.flush()
            result.success(true)
        } catch (e: IOException) {
            result.error("WRITE_ERROR", e.message, null)
            postStatus(0)
        }
    }

    private fun postStatus(status: Int) {
        Handler(Looper.getMainLooper()).post {
            statusSink?.success(status)
        }
    }
}
