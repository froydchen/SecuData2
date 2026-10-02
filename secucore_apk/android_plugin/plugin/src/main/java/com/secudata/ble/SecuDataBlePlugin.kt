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
import android.content.ContentValues
import android.content.pm.PackageManager
import android.database.sqlite.SQLiteDatabase
import android.os.Build
import android.os.Handler
import android.os.Looper
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONArray
import org.json.JSONObject
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
    private var database: SQLiteDatabase? = null

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


    @UsedByGodot
    fun databaseSelfTest(): String {
        val db = ensureDatabase() ?: return jsonError("Datenbank konnte nicht geöffnet werden")
        return try {
            db.rawQuery("SELECT COUNT(*) FROM records", null).use { cursor ->
                val count = if (cursor.moveToFirst()) cursor.getInt(0) else 0
                JSONObject()
                    .put("ok", true)
                    .put("records", count)
                    .put("path", activity?.getDatabasePath("secudata.db")?.absolutePath.orEmpty())
                    .toString()
            }
        } catch (exc: Exception) {
            jsonError("Datenbank-Selbsttest fehlgeschlagen: ${exc.message}")
        }
    }

    @UsedByGodot
    fun databaseSaveRecord(recordJson: String): String {
        val db = ensureDatabase() ?: return jsonError("Datenbank nicht verfügbar")
        return try {
            val record = JSONObject(recordJson)
            val values = ContentValues().apply {
                put("created_at", record.optString("created_at"))
                put("measurement_timestamp", record.optString("measurement_timestamp"))
                put("external_id", record.optString("external_id"))
                put("geraeteart", record.optString("geraeteart"))
                put("hersteller", record.optString("hersteller"))
                put("raum_etage", record.optString("raum_etage"))
                put("is_ok", if (record.optBoolean("is_ok", true)) 1 else 0)
                put("switch_position", record.optInt("switch_position", -1))
                put("measurement_kind", record.optString("measurement_kind"))
                put("payload_json", record.toString())
            }
            val id = db.insertOrThrow("records", null, values)
            JSONObject()
                .put("ok", true)
                .put("id", id)
                .toString()
        } catch (exc: Exception) {
            jsonError("Speichern fehlgeschlagen: ${exc.message}")
        }
    }

    @UsedByGodot
    fun databaseListRecords(limit: Int): String {
        val db = ensureDatabase() ?: return "[]"
        val safeLimit = limit.coerceIn(1, 2000)
        val result = JSONArray()
        return try {
            db.query(
                "records",
                arrayOf(
                    "id", "created_at", "measurement_timestamp", "external_id",
                    "geraeteart", "hersteller", "raum_etage", "is_ok",
                    "switch_position", "measurement_kind", "payload_json"
                ),
                null,
                null,
                null,
                null,
                "created_at DESC, id DESC",
                safeLimit.toString(),
            ).use { cursor ->
                val idCol = cursor.getColumnIndexOrThrow("id")
                val payloadCol = cursor.getColumnIndexOrThrow("payload_json")
                while (cursor.moveToNext()) {
                    val payloadText = cursor.getString(payloadCol).orEmpty()
                    val item = try {
                        JSONObject(payloadText)
                    } catch (_: Exception) {
                        JSONObject()
                    }

                    item.put("database_id", cursor.getLong(idCol))
                    item.put("created_at", cursor.getString(cursor.getColumnIndexOrThrow("created_at")).orEmpty())
                    item.put("measurement_timestamp", cursor.getString(cursor.getColumnIndexOrThrow("measurement_timestamp")).orEmpty())
                    item.put("external_id", cursor.getString(cursor.getColumnIndexOrThrow("external_id")).orEmpty())
                    item.put("geraeteart", cursor.getString(cursor.getColumnIndexOrThrow("geraeteart")).orEmpty())
                    item.put("hersteller", cursor.getString(cursor.getColumnIndexOrThrow("hersteller")).orEmpty())
                    item.put("raum_etage", cursor.getString(cursor.getColumnIndexOrThrow("raum_etage")).orEmpty())
                    item.put("is_ok", cursor.getInt(cursor.getColumnIndexOrThrow("is_ok")) != 0)
                    item.put("switch_position", cursor.getInt(cursor.getColumnIndexOrThrow("switch_position")))
                    item.put("measurement_kind", cursor.getString(cursor.getColumnIndexOrThrow("measurement_kind")).orEmpty())
                    result.put(item)
                }
            }
            result.toString()
        } catch (exc: Exception) {
            emitError("Datenbank lesen fehlgeschlagen: ${exc.message}")
            "[]"
        }
    }

    @UsedByGodot
    fun databaseDeleteRecord(recordId: Int): Boolean {
        val db = ensureDatabase() ?: return false
        return try {
            db.delete("records", "id = ?", arrayOf(recordId.toString())) > 0
        } catch (exc: Exception) {
            emitError("Datensatz löschen fehlgeschlagen: ${exc.message}")
            false
        }
    }

    @UsedByGodot
    fun databaseUpdateRoom(recordId: Int, room: String): Boolean {
        val db = ensureDatabase() ?: return false
        return try {
            var payload = JSONObject()
            db.query(
                "records",
                arrayOf("payload_json"),
                "id = ?",
                arrayOf(recordId.toString()),
                null,
                null,
                null,
                "1",
            ).use { cursor ->
                if (cursor.moveToFirst()) {
                    payload = try {
                        JSONObject(cursor.getString(0).orEmpty())
                    } catch (_: Exception) {
                        JSONObject()
                    }
                } else {
                    return false
                }
            }

            payload.put("raum_etage", room)
            val values = ContentValues().apply {
                put("raum_etage", room)
                put("payload_json", payload.toString())
            }
            db.update("records", values, "id = ?", arrayOf(recordId.toString())) > 0
        } catch (exc: Exception) {
            emitError("Raum ändern fehlgeschlagen: ${exc.message}")
            false
        }
    }


    @UsedByGodot
    fun databaseUpdateRecord(
        recordId: Int,
        externalId: String,
        geraeteart: String,
        hersteller: String,
        room: String,
    ): Boolean {
        val db = ensureDatabase() ?: return false
        return try {
            var payload = JSONObject()
            db.query(
                "records",
                arrayOf("payload_json"),
                "id = ?",
                arrayOf(recordId.toString()),
                null,
                null,
                null,
                "1",
            ).use { cursor ->
                if (cursor.moveToFirst()) {
                    payload = try {
                        JSONObject(cursor.getString(0).orEmpty())
                    } catch (_: Exception) {
                        JSONObject()
                    }
                } else {
                    return false
                }
            }

            payload.put("external_id", externalId)
            payload.put("id", externalId)
            payload.put("geraeteart", geraeteart)
            payload.put("hersteller", hersteller)
            payload.put("raum_etage", room)

            val values = ContentValues().apply {
                put("external_id", externalId)
                put("geraeteart", geraeteart)
                put("hersteller", hersteller)
                put("raum_etage", room)
                put("payload_json", payload.toString())
            }
            db.update("records", values, "id = ?", arrayOf(recordId.toString())) > 0
        } catch (exc: Exception) {
            emitError("Datensatz ändern fehlgeschlagen: ${exc.message}")
            false
        }
    }

    @UsedByGodot
    fun databaseCounts(): String {
        val db = ensureDatabase() ?: return """{"today":0,"week":0,"total":0}"""
        return try {
            fun count(where: String? = null): Int {
                val sql = if (where.isNullOrBlank()) {
                    "SELECT COUNT(*) FROM records"
                } else {
                    "SELECT COUNT(*) FROM records WHERE $where"
                }
                db.rawQuery(sql, null).use { cursor ->
                    return if (cursor.moveToFirst()) cursor.getInt(0) else 0
                }
            }

            val today = count("date(created_at) = date('now','localtime')")
            val week = count("strftime('%Y-%W', created_at) = strftime('%Y-%W', 'now','localtime')")
            val total = count()

            JSONObject()
                .put("today", today)
                .put("week", week)
                .put("total", total)
                .toString()
        } catch (exc: Exception) {
            emitError("Zähler lesen fehlgeschlagen: ${exc.message}")
            """{"today":0,"week":0,"total":0}"""
        }
    }

    @UsedByGodot
    fun databaseGetSetting(key: String, fallback: String): String {
        val db = ensureDatabase() ?: return fallback
        return try {
            db.query(
                "settings",
                arrayOf("value"),
                "key = ?",
                arrayOf(key),
                null,
                null,
                null,
                "1",
            ).use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0).orEmpty() else fallback
            }
        } catch (_: Exception) {
            fallback
        }
    }

    @UsedByGodot
    fun databaseSetSetting(key: String, value: String): Boolean {
        val db = ensureDatabase() ?: return false
        return try {
            val values = ContentValues().apply {
                put("key", key)
                put("value", value)
            }
            db.insertWithOnConflict("settings", null, values, SQLiteDatabase.CONFLICT_REPLACE) != -1L
        } catch (exc: Exception) {
            emitError("Einstellung speichern fehlgeschlagen: ${exc.message}")
            false
        }
    }

    private fun ensureDatabase(): SQLiteDatabase? {
        database?.let { if (it.isOpen) return it }

        val host = activity ?: return null
        return try {
            val path = host.getDatabasePath("secudata.db")
            path.parentFile?.mkdirs()
            val db = SQLiteDatabase.openOrCreateDatabase(path, null)
            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS records (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at TEXT NOT NULL,
                    measurement_timestamp TEXT NOT NULL DEFAULT '',
                    external_id TEXT NOT NULL DEFAULT '',
                    geraeteart TEXT NOT NULL DEFAULT '',
                    hersteller TEXT NOT NULL DEFAULT '',
                    raum_etage TEXT NOT NULL DEFAULT '',
                    is_ok INTEGER NOT NULL DEFAULT 1,
                    switch_position INTEGER NOT NULL DEFAULT -1,
                    measurement_kind TEXT NOT NULL DEFAULT '',
                    payload_json TEXT NOT NULL DEFAULT '{}'
                )
                """.trimIndent()
            )
            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS settings (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                )
                """.trimIndent()
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS idx_records_created_at ON records(created_at DESC)")
            db.execSQL("CREATE INDEX IF NOT EXISTS idx_records_room ON records(raum_etage, created_at DESC)")
            database = db
            db
        } catch (exc: Exception) {
            emitError("Datenbank öffnen fehlgeschlagen: ${exc.message}")
            null
        }
    }

    private fun jsonError(message: String): String {
        return JSONObject()
            .put("ok", false)
            .put("error", message)
            .toString()
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
