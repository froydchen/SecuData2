package com.secudata.ble

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import java.util.UUID

class SecuDataBlePlugin(godot: Godot) : GodotPlugin(godot) {
    companion object {
        private val STATE_CHANGED = SignalInfo("state_changed", String::class.java, String::class.java)
        private val RX_TEXT = SignalInfo("rx_text", String::class.java)
        private val BLE_ERROR = SignalInfo("ble_error", String::class.java)
        private const val REQUEST_CODE = 4207
        private const val SCAN_TIMEOUT_MS = 12_000L
        private val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private var scanner: BluetoothLeScanner? = null
    private var gatt: BluetoothGatt? = null
    private var writeCharacteristic: BluetoothGattCharacteristic? = null
    private var notifyCharacteristic: BluetoothGattCharacteristic? = null
    private var scanning = false
    private var targetName = "BLE RS232"
    private var connectionState = "IDLE"
    private val handler = Handler(Looper.getMainLooper())

    override fun getPluginName() = BuildConfig.GODOT_PLUGIN_NAME

    override fun getPluginSignals(): MutableSet<SignalInfo> = mutableSetOf(
        STATE_CHANGED,
        RX_TEXT,
        BLE_ERROR,
    )

    @UsedByGodot
    fun isBluetoothSupported(): Boolean {
        val manager = activity?.getSystemService(BluetoothManager::class.java)
        return manager?.adapter != null
    }

    @UsedByGodot
    fun getPermissionState(): String {
        return if (hasRequiredPermissions()) "GRANTED" else "REQUIRED"
    }

    @UsedByGodot
    fun requestPermissions() {
        val host = activity ?: run {
            emitError("Android Activity nicht verfügbar")
            return
        }
        val missing = requiredPermissions().filter {
            host.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            emitState("PERMISSION_GRANTED", "Bluetooth-Berechtigungen vorhanden")
            return
        }
        host.runOnUiThread {
            host.requestPermissions(missing.toTypedArray(), REQUEST_CODE)
        }
        emitState("PERMISSION_REQUESTED", "Bluetooth-Berechtigung angefordert")
    }

    @UsedByGodot
    fun startScan(requestedTargetName: String): Boolean {
        if (!hasRequiredPermissions()) {
            emitError("Bluetooth-Berechtigung fehlt")
            return false
        }

        val host = activity ?: run {
            emitError("Android Activity nicht verfügbar")
            return false
        }
        val manager = host.getSystemService(BluetoothManager::class.java)
        val adapter = manager?.adapter ?: run {
            emitError("Bluetooth wird von diesem Gerät nicht unterstützt")
            return false
        }

        if (!adapter.isEnabled) {
            emitError("Bluetooth ist ausgeschaltet")
            return false
        }

        disconnectGattOnly()
        targetName = requestedTargetName.trim().ifEmpty { "BLE RS232" }
        scanner = adapter.bluetoothLeScanner ?: run {
            emitError("BLE-Scanner nicht verfügbar")
            return false
        }

        return try {
            scanning = true
            connectionState = "SCANNING"
            scanner?.startScan(scanCallback)
            emitState("SCANNING", "Suche nach $targetName")
            handler.removeCallbacks(scanTimeout)
            handler.postDelayed(scanTimeout, SCAN_TIMEOUT_MS)
            true
        } catch (exc: SecurityException) {
            scanning = false
            emitError("BLE-Scan nicht erlaubt: ${exc.message}")
            false
        } catch (exc: Exception) {
            scanning = false
            emitError("BLE-Scan fehlgeschlagen: ${exc.message}")
            false
        }
    }

    @UsedByGodot
    fun disconnect() {
        stopScan()
        disconnectGattOnly()
        connectionState = "DISCONNECTED"
        emitState("DISCONNECTED", "BLE-Verbindung getrennt")
    }

    @UsedByGodot
    fun getConnectionState(): String = connectionState

    @UsedByGodot
    fun sendText(text: String): Boolean {
        if (!hasConnectPermission()) {
            emitError("Bluetooth-Verbindungsberechtigung fehlt")
            return false
        }
        val activeGatt = gatt ?: run {
            emitError("Keine BLE-Verbindung")
            return false
        }
        val characteristic = writeCharacteristic ?: run {
            emitError("Keine schreibbare UART-Charakteristik")
            return false
        }

        val data = text.toByteArray(Charsets.ISO_8859_1)
        val props = characteristic.properties
        val writeType = if (props and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0) {
            BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        } else {
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        }

        return try {
            val queued = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                activeGatt.writeCharacteristic(characteristic, data, writeType) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                characteristic.writeType = writeType
                @Suppress("DEPRECATION")
                characteristic.value = data
                @Suppress("DEPRECATION")
                activeGatt.writeCharacteristic(characteristic)
            }
            if (!queued) {
                emitError("BLE-Schreibvorgang konnte nicht eingereiht werden")
            }
            queued
        } catch (exc: SecurityException) {
            emitError("BLE-Schreiben nicht erlaubt: ${exc.message}")
            false
        } catch (exc: Exception) {
            emitError("BLE-Schreiben fehlgeschlagen: ${exc.message}")
            false
        }
    }

    private val scanTimeout = Runnable {
        if (scanning) {
            stopScan()
            connectionState = "SCAN_TIMEOUT"
            emitError("BLE RS232 beim Scan nicht gefunden")
        }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            super.onScanResult(callbackType, result)
            if (!scanning) return

            val advertisedName = result.scanRecord?.deviceName.orEmpty()
            val deviceName = try {
                result.device.name.orEmpty()
            } catch (_: SecurityException) {
                ""
            }
            val name = if (advertisedName.isNotBlank()) advertisedName else deviceName
            if (!name.contains(targetName, ignoreCase = true)) return

            stopScan()
            val address = try {
                result.device.address
            } catch (_: SecurityException) {
                "?"
            }
            connectionState = "CONNECTING"
            emitState("CONNECTING", "$name · $address")
            connectDevice(result.device)
        }

        override fun onScanFailed(errorCode: Int) {
            scanning = false
            handler.removeCallbacks(scanTimeout)
            connectionState = "SCAN_FAILED"
            emitError("BLE-Scan fehlgeschlagen (Code $errorCode)")
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                connectionState = "CONNECTION_ERROR"
                emitError("BLE-Verbindungsfehler (GATT $status)")
                closeGatt(gatt)
                return
            }

            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    connectionState = "DISCOVERING"
                    emitState("CONNECTED", "GATT verbunden, Dienste werden gesucht")
                    try {
                        if (!gatt.discoverServices()) {
                            emitError("BLE-Dienstsuche konnte nicht gestartet werden")
                        }
                    } catch (exc: SecurityException) {
                        emitError("BLE-Dienstsuche nicht erlaubt: ${exc.message}")
                    }
                }

                BluetoothProfile.STATE_DISCONNECTED -> {
                    connectionState = "DISCONNECTED"
                    emitState("DISCONNECTED", "GATT-Verbindung beendet")
                    closeGatt(gatt)
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                connectionState = "SERVICE_ERROR"
                emitError("BLE-Dienstsuche fehlgeschlagen (GATT $status)")
                return
            }

            val pair = chooseSerialPair(gatt) ?: run {
                connectionState = "NO_UART"
                emitError("Keine passende Write/Notify-UART-Charakteristik gefunden")
                return
            }

            writeCharacteristic = pair.write
            notifyCharacteristic = pair.notify
            connectionState = "ENABLING_NOTIFY"
            emitState(
                "UART_FOUND",
                "Service ${pair.write.service.uuid} · TX ${pair.write.uuid} · RX ${pair.notify.uuid}",
            )
            enableNotifications(gatt, pair.notify)
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            handleRx(characteristic.value ?: byteArrayOf())
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            handleRx(value)
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (descriptor.uuid != CCCD_UUID) return
            if (status != BluetoothGatt.GATT_SUCCESS) {
                connectionState = "NOTIFY_ERROR"
                emitError("BLE-Benachrichtigungen konnten nicht aktiviert werden (GATT $status)")
                return
            }
            connectionState = "READY"
            emitState("READY", uartDescription())
        }
    }

    private data class SerialPair(
        val write: BluetoothGattCharacteristic,
        val notify: BluetoothGattCharacteristic,
        val score: Int,
    )

    private fun chooseSerialPair(gatt: BluetoothGatt): SerialPair? {
        var best: SerialPair? = null
        for (service in gatt.services.orEmpty()) {
            val writable = service.characteristics.filter { characteristic ->
                val p = characteristic.properties
                p and BluetoothGattCharacteristic.PROPERTY_WRITE != 0 ||
                    p and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0
            }
            val notifiable = service.characteristics.filter { characteristic ->
                val p = characteristic.properties
                p and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0 ||
                    p and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0
            }

            for (write in writable) {
                for (notify in notifiable) {
                    var score = uartServiceScore(service.uuid.toString())
                    if (write.uuid == notify.uuid) score += 40
                    if (write.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0) score += 5
                    val candidate = SerialPair(write, notify, score)
                    if (best == null || candidate.score > best.score) best = candidate
                }
            }
        }
        return best
    }

    private fun uartServiceScore(uuid: String): Int {
        val value = uuid.lowercase()
        return when {
            value.contains("6e400001") -> 120 // Nordic UART service
            value.contains("ffe0") -> 110
            value.contains("fff0") -> 100
            else -> 10
        }
    }

    private fun enableNotifications(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
        if (!hasConnectPermission()) {
            emitError("Bluetooth-Verbindungsberechtigung fehlt")
            return
        }
        try {
            if (!gatt.setCharacteristicNotification(characteristic, true)) {
                emitError("Lokale BLE-Benachrichtigung konnte nicht aktiviert werden")
                return
            }

            val descriptor = characteristic.getDescriptor(CCCD_UUID) ?: run {
                emitError("Notify-Charakteristik besitzt keinen CCCD-Descriptor")
                return
            }
            val enableValue = if (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0 &&
                characteristic.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY == 0
            ) {
                BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
            } else {
                BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            }

            val queued = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeDescriptor(descriptor, enableValue) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                descriptor.value = enableValue
                @Suppress("DEPRECATION")
                gatt.writeDescriptor(descriptor)
            }
            if (!queued) {
                emitError("CCCD-Schreibvorgang konnte nicht eingereiht werden")
            }
        } catch (exc: SecurityException) {
            emitError("BLE-Notify nicht erlaubt: ${exc.message}")
        } catch (exc: Exception) {
            emitError("BLE-Notify fehlgeschlagen: ${exc.message}")
        }
    }

    private fun connectDevice(device: android.bluetooth.BluetoothDevice) {
        val host = activity ?: run {
            emitError("Android Activity nicht verfügbar")
            return
        }
        if (!hasConnectPermission()) {
            emitError("Bluetooth-Verbindungsberechtigung fehlt")
            return
        }
        try {
            gatt = device.connectGatt(host, false, gattCallback, android.bluetooth.BluetoothDevice.TRANSPORT_LE)
            if (gatt == null) {
                emitError("GATT-Verbindung konnte nicht erzeugt werden")
            }
        } catch (exc: SecurityException) {
            emitError("BLE-Verbindung nicht erlaubt: ${exc.message}")
        } catch (exc: Exception) {
            emitError("BLE-Verbindung fehlgeschlagen: ${exc.message}")
        }
    }

    private fun handleRx(value: ByteArray) {
        if (value.isEmpty()) return
        val text = String(value, Charsets.ISO_8859_1)
        runOnHostThread {
            emitSignal(RX_TEXT.name, text)
        }
    }

    private fun stopScan() {
        if (!scanning) return
        scanning = false
        handler.removeCallbacks(scanTimeout)
        try {
            scanner?.stopScan(scanCallback)
        } catch (_: SecurityException) {
        } catch (_: Exception) {
        }
    }

    private fun disconnectGattOnly() {
        writeCharacteristic = null
        notifyCharacteristic = null
        val active = gatt
        gatt = null
        if (active != null) {
            try {
                if (hasConnectPermission()) active.disconnect()
            } catch (_: Exception) {
            }
            closeGatt(active)
        }
    }

    private fun closeGatt(target: BluetoothGatt) {
        try {
            target.close()
        } catch (_: Exception) {
        }
        if (gatt === target) gatt = null
        writeCharacteristic = null
        notifyCharacteristic = null
    }

    private fun uartDescription(): String {
        val write = writeCharacteristic
        val notify = notifyCharacteristic
        return if (write != null && notify != null) {
            "Service ${write.service.uuid} · TX ${write.uuid} · RX ${notify.uuid}"
        } else {
            "BLE UART bereit"
        }
    }

    private fun requiredPermissions(): Array<String> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }
    }

    private fun hasRequiredPermissions(): Boolean {
        val host = activity ?: return false
        return requiredPermissions().all { host.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
    }

    private fun hasConnectPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val host = activity ?: return false
        return host.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
    }

    private fun emitState(state: String, detail: String) {
        connectionState = state
        runOnHostThread {
            emitSignal(STATE_CHANGED.name, state, detail)
        }
    }

    private fun emitError(message: String) {
        runOnHostThread {
            emitSignal(BLE_ERROR.name, message)
        }
    }
}
