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
import java.text.Normalizer
import java.util.Locale
import java.util.UUID
import kotlin.math.min

class SecuDataBlePlugin(godot: Godot) : GodotPlugin(godot) {
    companion object {
        private val STATE_CHANGED = SignalInfo("state_changed", String::class.java, String::class.java)
        private val RX_TEXT = SignalInfo("rx_text", String::class.java)
        private val BLE_ERROR = SignalInfo("ble_error", String::class.java)
        private const val REQUEST_CODE = 4207
        private const val SCAN_TIMEOUT_MS = 12_000L
        private val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        private val BASE_LINE_TYPES = listOf(
            "Verlängerung", "Mehrfachverteiler", "Kaltgerätekabel",
            "Anschlußleitung", "Kabeltrommel", "1-fach Verteiler"
        )

        private val BASE_DEVICE_TYPES = listOf(
            "Abzugshaube", "Aktenvernichter", "Anrufbeantworter", "Aufschnittmaschine",
            "Bettlampe", "Bildbetrachter", "Blu-Ray-Player", "Bohrmaschine", "Boiler",
            "Bügeleisen", "CD-Player", "Computer", "Diaprojektor", "Dockingstation",
            "Drucker", "DVD-Player", "Eierkocher", "Faxgerät", "Fernseher",
            "Flachbildschirm", "Gefrierschrank", "Gefriertruhe", "Geschirrspüler",
            "Heißklebepistole", "Heizkörper", "Heizlüfter", "Industriesauger",
            "Kaltgerätekabel", "Kopierer", "Kühlschrank", "Ladegerät", "Lichterkette",
            "Laptop", "Lüfter/Ventilator", "Mikrowelle", "Monitor", "Multifunktionsprinter",
            "Musikanlage", "Nähmaschine", "Netzteil", "Notlampe", "Overheadprojektor",
            "PC-Lautsprecher", "Pflegebett", "Personal-Terminal", "Radio", "Radiowecker",
            "Rasierer", "Receiver", "Router", "Standbohrmaschine", "Scanner",
            "Schreibmaschine", "Speedport", "Staubsauger", "Stehlampe", "Switch",
            "Kabeltrommel", "Kaffeeautomat", "Kaffeemaschine", "Toaster", "Unterbaulampe",
            "Verlängerung", "Videorekorder", "Waage", "Waffeltoaster", "Wandlampe",
            "Wärmeschrank", "Wärmewagen", "Wäschetrockner", "Waschmaschine",
            "Wasserkocher", "Zahnbürste", "Zimmerantenne", "1-fach Verteiler", "Telefon",
            "Tellerwagen", "Tischlampe", "Tischrechner", "Ultraschallreinigungsgerät",
            "Oberfräse", "Lockenwickler", "Mehrfachverteiler", "Anschlußleitung"
        ).distinct()

        private val DEVICE_ABBREVIATIONS = mapOf(
            "AV" to "Aktenvernichter", "BM" to "Bohrmaschine", "PC" to "Computer",
            "D" to "Drucker", "TV" to "Fernseher", "TFT" to "Flachbildschirm",
            "KGK" to "Kaltgerätekabel", "KO" to "Kopierer", "KS" to "Kühlschrank",
            "LG" to "Ladegerät", "LT" to "Laptop", "MW" to "Mikrowelle",
            "M" to "Monitor", "MEP" to "Multifunktionsprinter", "NT" to "Netzteil",
            "PB" to "Pflegebett", "R" to "Radio", "RT" to "Router", "SC" to "Scanner",
            "SS" to "Staubsauger", "SW" to "Switch", "KT" to "Kabeltrommel",
            "KM" to "Kaffeemaschine", "TO" to "Toaster", "V" to "Verlängerung",
            "WM" to "Waschmaschine", "WK" to "Wasserkocher", "T" to "Telefon"
        )

        private val DEVICE_ALIAS_TO_KEY = linkedMapOf(
            "Netzteil" to "NT/LG", "NT" to "NT/LG", "Ladegerät" to "NT/LG", "LG" to "NT/LG",
            "Drucker" to "D/MEP/KO/SC", "Multifunktionsprinter" to "D/MEP/KO/SC",
            "Kopierer" to "D/MEP/KO/SC", "Scanner" to "D/MEP/KO/SC",
            "Computer" to "PC/LT/M", "PC" to "PC/LT/M", "Laptop" to "PC/LT/M", "Monitor" to "PC/LT/M",
            "Fernseher" to "TV/TFT", "Flachbildschirm" to "TV/TFT", "TV" to "TV/TFT", "TFT" to "TV/TFT",
            "Router" to "RT/SW/SP", "Switch" to "RT/SW/SP", "Speedport" to "RT/SW/SP",
            "Staubsauger" to "SS/IS", "Industriesauger" to "SS/IS",
            "Waschmaschine" to "WM/WT", "Wäschetrockner" to "WM/WT",
            "Kühlschrank" to "KS/GFS", "Gefrierschrank" to "KS/GFS",
            "Geschirrspüler" to "GS", "Mikrowelle" to "MW", "Kaffeemaschine" to "KM",
            "Kaffeeautomat" to "KM", "Toaster" to "TO/WK", "Wasserkocher" to "TO/WK",
            "Bohrmaschine" to "BM/SB/OF", "Standbohrmaschine" to "BM/SB/OF", "Oberfräse" to "BM/SB/OF",
            "Rasierer" to "RA/ZB", "Zahnbürste" to "RA/ZB", "Telefon" to "T/AB",
            "Musikanlage" to "MA/PCL", "PC-Lautsprecher" to "MA/PCL", "Aktenvernichter" to "AV",
            "Pflegebett" to "PB", "Ultraschallreinigungsgerät" to "URG"
        )

        private val BASE_MANUFACTURERS = mapOf(
            "D/MEP/KO/SC" to listOf("HP", "Canon", "Epson", "Brother", "Kyocera", "Ricoh", "Xerox"),
            "PC/LT/M" to listOf("Dell", "HP", "Lenovo", "Apple", "ASUS", "Acer", "Samsung"),
            "TV/TFT" to listOf("Samsung", "LG", "Sony", "Philips", "Panasonic", "Hisense", "TCL"),
            "RT/SW/SP" to listOf("AVM", "TP-Link", "Netgear", "Cisco", "Ubiquiti", "Telekom", "D-Link"),
            "SS/IS" to listOf("Kärcher", "Miele", "Bosch", "Siemens", "Nilfisk", "Makita", "Einhell"),
            "WM/WT" to listOf("Miele", "Bosch", "Siemens", "AEG", "Bauknecht", "Beko", "Samsung"),
            "KS/GFS" to listOf("Liebherr", "Bosch", "Siemens", "Miele", "AEG", "Samsung", "Beko"),
            "GS" to listOf("Bosch", "Siemens", "Miele", "AEG", "Bauknecht", "Neff", "Beko"),
            "MW" to listOf("Panasonic", "Samsung", "LG", "Bosch", "Sharp", "Whirlpool"),
            "KM" to listOf("Jura", "De’Longhi", "Siemens", "Melitta", "Saeco", "Philips", "Nivona"),
            "TO/WK" to listOf("WMF", "Bosch", "Siemens", "Philips", "Russell Hobbs", "Tefal", "Severin"),
            "BM/SB/OF" to listOf("Bosch", "Makita", "Metabo", "DeWalt", "Einhell", "Festool", "Milwaukee"),
            "RA/ZB" to listOf("Philips", "Braun", "Oral-B", "Panasonic", "Remington"),
            "T/AB" to listOf("Gigaset", "Panasonic", "AVM", "Telekom", "Yealink"),
            "MA/PCL" to listOf("Sony", "JBL", "Bose", "Teufel", "Panasonic", "Yamaha", "Philips"),
            "AV" to listOf("Fellowes", "HSM", "Leitz", "Dahle", "Rexel"),
            "NT/LG" to listOf("Anker", "Belkin", "Hama", "Samsung", "Apple", "Aukey"),
            "PB" to listOf("Burmeier", "Stiegelmeyer", "Wissner-Bosserhoff", "Invacare", "Hermann Bock"),
            "URG" to listOf("Bandelin", "Elma", "Vevor", "EMAG", "Branson")
        )
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
    fun expandDeviceAbbreviations(input: String): String {
        if (input.isEmpty()) return input
        val trailingSpace = input.lastOrNull()?.isWhitespace() == true
        val tokens = input.trim().split(Regex("\\s+")).filter { it.isNotBlank() }
        if (tokens.isEmpty()) return if (trailingSpace) " " else ""

        val expanded = tokens.joinToString(" ") { token ->
            DEVICE_ABBREVIATIONS[token.uppercase(Locale.ROOT)] ?: token
        }
        return expanded + if (trailingSpace) " " else ""
    }

    @UsedByGodot
    fun databaseSuggestions(
        field: String,
        deviceType: String,
        input: String,
        switchPosition: Int,
        limit: Int,
    ): String {
        val db = ensureDatabase() ?: return "[]"
        val safeLimit = limit.coerceIn(1, 8)
        val fieldKey = when (field.trim().lowercase(Locale.ROOT)) {
            "id", "external_id" -> "ID"
            "geraeteart", "device", "device_type" -> "DEVICE"
            "hersteller", "manufacturer" -> "MANUFACTURER"
            else -> return "[]"
        }

        // Expand abbreviations for matching as well, even before the UI commits
        // the expanded form. "NT" therefore already matches "Netzteil".
        val expandedInput = if (fieldKey == "DEVICE") expandDeviceAbbreviations(input) else input
        val query = expandedInput.trim()
        val queryNorm = normalizeVocabulary(query)
        val result = JSONArray()
        val seen = LinkedHashSet<String>()

        // Load dismissed entries ONCE. v0.13 queried SQLite for every candidate,
        // which made the device field block the Godot main thread for seconds.
        val dismissKey = if (fieldKey == "MANUFACTURER") resolveDeviceKey(deviceType) else ""
        val dismissed = LinkedHashSet<String>()
        if (fieldKey != "ID") {
            val selection: String
            val args: Array<String>
            if (fieldKey == "MANUFACTURER") {
                selection = "kind = ? AND status = 'dismissed' AND (device_key = ? OR device_key = '')"
                args = arrayOf(fieldKey, dismissKey)
            } else {
                selection = "kind = ? AND status = 'dismissed'"
                args = arrayOf(fieldKey)
            }
            db.query(
                "dictionary_entries",
                arrayOf("normalized"),
                selection,
                args,
                null,
                null,
                null,
            ).use { cursor ->
                while (cursor.moveToNext()) dismissed += cursor.getString(0).orEmpty()
            }
        }

        fun add(
            value: String,
            action: String = "fill",
            source: String = "dictionary",
            label: String = value,
            respectQuery: Boolean = true,
            dictionaryValue: String = "",
        ) {
            val clean = value.trim()
            if (clean.isBlank()) return
            val normalized = normalizeVocabulary(clean)
            if (normalized.isBlank() || normalized in seen) return

            // Cheap text filter FIRST; no database work per candidate.
            if (respectQuery && queryNorm.isNotBlank() && !matchesVocabulary(clean, queryNorm)) return

            val dismissNorm = normalizeVocabulary(if (dictionaryValue.isNotBlank()) dictionaryValue else clean)
            if (fieldKey != "ID" && dismissNorm in dismissed) return

            seen += normalized
            result.put(
                JSONObject()
                    .put("value", clean)
                    .put("label", label)
                    .put("action", action)
                    .put("source", source)
                    .put("dictionary_value", if (dictionaryValue.isNotBlank()) dictionaryValue else clean)
            )
        }

        try {
            when (fieldKey) {
                "ID" -> {
                    db.rawQuery(
                        """
                        SELECT external_id, COUNT(*) AS n, MAX(id) AS last_id
                        FROM records
                        WHERE TRIM(external_id) <> ''
                        GROUP BY LOWER(TRIM(external_id))
                        ORDER BY n DESC, last_id DESC
                        LIMIT 80
                        """.trimIndent(),
                        null,
                    ).use { cursor ->
                        while (cursor.moveToNext() && result.length() < safeLimit) {
                            add(cursor.getString(0).orEmpty(), source = "history")
                        }
                    }
                }

                "DEVICE" -> {
                    val compound = splitNetzteilCompound(expandedInput)

                    if (compound != null) {
                        val prefix = compound.first
                        val remainder = compound.second
                        val remainderNorm = normalizeVocabulary(remainder)

                        // Past combinations first: "Netzteil TFT", "Netzteil Monitor", …
                        db.rawQuery(
                            """
                            SELECT geraeteart, COUNT(*) AS n, MAX(id) AS last_id
                            FROM records
                            WHERE LOWER(TRIM(geraeteart)) LIKE LOWER(?)
                            GROUP BY LOWER(TRIM(geraeteart))
                            ORDER BY n DESC, last_id DESC
                            LIMIT 80
                            """.trimIndent(),
                            arrayOf("$prefix %"),
                        ).use { cursor ->
                            while (cursor.moveToNext() && result.length() < safeLimit) {
                                val value = cursor.getString(0).orEmpty()
                                val suffix = value.substringAfter(" ", "")
                                if (remainderNorm.isBlank() || matchesVocabulary(suffix, remainderNorm)) {
                                    add(value, source = "history-compound", respectQuery = false)
                                }
                            }
                        }

                        // Known device types can be appended without losing the prefix.
                        if (result.length() < safeLimit) {
                            for (candidate in baseDeviceSuggestionsForSwitch(3)) {
                                if (result.length() >= safeLimit) break
                                if (normalizeVocabulary(candidate) == normalizeVocabulary(prefix)) continue
                                if (remainderNorm.isNotBlank() && !matchesVocabulary(candidate, remainderNorm)) continue
                                add("$prefix $candidate", source = "compound-base", respectQuery = false)
                            }
                        }

                        // User-accepted device vocabulary is also valid as a suffix.
                        if (result.length() < safeLimit) {
                            db.query(
                                "dictionary_entries",
                                arrayOf("value"),
                                "kind = 'DEVICE' AND status = 'active'",
                                null,
                                null,
                                null,
                                "use_count DESC, updated_at DESC",
                                "100",
                            ).use { cursor ->
                                while (cursor.moveToNext() && result.length() < safeLimit) {
                                    val candidate = cursor.getString(0).orEmpty()
                                    if (remainderNorm.isNotBlank() && !matchesVocabulary(candidate, remainderNorm)) continue
                                    add("$prefix $candidate", source = "compound-dictionary", respectQuery = false)
                                }
                            }
                        }

                        if (remainder.isNotBlank() && result.length() < safeLimit) {
                            if (!isKnownDevice(remainder, db)) {
                                val similar = findSimilarDevice(remainder, db)
                                if (similar.isNotBlank()) {
                                    add(
                                        "$prefix $similar",
                                        action = "fill",
                                        source = "similar",
                                        label = "≈ $similar",
                                        respectQuery = false,
                                    )
                                } else if (normalizeVocabulary(remainder) !in dismissed) {
                                    add(
                                        "$prefix $remainder",
                                        action = "add",
                                        source = "unknown",
                                        label = "＋ $remainder",
                                        respectQuery = false,
                                        dictionaryValue = remainder,
                                    )
                                }
                            }
                        }
                    } else {
                        val base = baseDeviceSuggestionsForSwitch(switchPosition)
                        for (value in base) {
                            if (result.length() >= safeLimit) break
                            add(value, source = "base")
                        }

                        db.rawQuery(
                            """
                            SELECT geraeteart, COUNT(*) AS n, MAX(id) AS last_id
                            FROM records
                            WHERE TRIM(geraeteart) <> ''
                            GROUP BY LOWER(TRIM(geraeteart))
                            ORDER BY n DESC, last_id DESC
                            LIMIT 120
                            """.trimIndent(),
                            null,
                        ).use { cursor ->
                            while (cursor.moveToNext() && result.length() < safeLimit) {
                                val value = cursor.getString(0).orEmpty()
                                if (deviceAllowedForSwitch(value, switchPosition)) {
                                    add(value, source = "history")
                                }
                            }
                        }

                        addStoredVocabulary(db, "DEVICE", "", queryNorm, safeLimit, result, seen, deviceType)

                        if (query.isNotBlank() && result.length() < safeLimit) {
                            val candidate = extractUnknownDeviceCandidate(query)
                            if (candidate.isNotBlank() && !isKnownDevice(candidate, db)) {
                                val similar = findSimilarDevice(candidate, db)
                                if (similar.isNotBlank()) {
                                    add(similar, action = "fill", source = "similar", label = "≈ $similar", respectQuery = false)
                                } else if (normalizeVocabulary(candidate) !in dismissed) {
                                    add(
                                        candidate,
                                        action = "add",
                                        source = "unknown",
                                        label = "＋ $candidate",
                                        respectQuery = false,
                                        dictionaryValue = candidate,
                                    )
                                }
                            }
                        }
                    }
                }

                "MANUFACTURER" -> {
                    val deviceKey = resolveDeviceKey(deviceType)
                    for (value in BASE_MANUFACTURERS[deviceKey].orEmpty()) {
                        if (result.length() >= safeLimit) break
                        add(value, source = "base")
                    }

                    if (deviceType.isNotBlank()) {
                        db.rawQuery(
                            """
                            SELECT hersteller, COUNT(*) AS n, MAX(id) AS last_id
                            FROM records
                            WHERE TRIM(hersteller) <> ''
                              AND LOWER(TRIM(geraeteart)) = LOWER(TRIM(?))
                            GROUP BY LOWER(TRIM(hersteller))
                            ORDER BY n DESC, last_id DESC
                            LIMIT 80
                            """.trimIndent(),
                            arrayOf(deviceType.trim()),
                        ).use { cursor ->
                            while (cursor.moveToNext() && result.length() < safeLimit) {
                                add(cursor.getString(0).orEmpty(), source = "history-device")
                            }
                        }
                    }

                    addStoredVocabulary(db, "MANUFACTURER", deviceKey, queryNorm, safeLimit, result, seen, deviceType)

                    db.rawQuery(
                        """
                        SELECT hersteller, COUNT(*) AS n, MAX(id) AS last_id
                        FROM records
                        WHERE TRIM(hersteller) <> ''
                        GROUP BY LOWER(TRIM(hersteller))
                        ORDER BY n DESC, last_id DESC
                        LIMIT 80
                        """.trimIndent(),
                        null,
                    ).use { cursor ->
                        while (cursor.moveToNext() && result.length() < safeLimit) {
                            add(cursor.getString(0).orEmpty(), source = "history")
                        }
                    }

                    if (query.isNotBlank() && result.length() < safeLimit && query != "-") {
                        val known = knownManufacturerValues(deviceKey, db)
                        val exact = known.any { normalizeVocabulary(it) == queryNorm }
                        if (!exact) {
                            val similar = findSimilarValue(query, known)
                            if (similar.isNotBlank()) {
                                add(similar, action = "fill", source = "similar", label = "≈ $similar", respectQuery = false)
                            } else if (queryNorm !in dismissed) {
                                add(
                                    query,
                                    action = "add",
                                    source = "unknown",
                                    label = "＋ $query",
                                    respectQuery = false,
                                    dictionaryValue = query,
                                )
                            }
                        }
                    }
                }
            }

            if (queryNorm.isBlank() && result.length() < safeLimit) {
                add("-", source = "special")
            }
        } catch (exc: Exception) {
            emitError("Wortvorschläge fehlgeschlagen: ${exc.message}")
        }

        return result.toString()
    }

    @UsedByGodot
    fun databaseAcceptVocabulary(field: String, value: String, deviceType: String): Boolean {
        val db = ensureDatabase() ?: return false
        val kind = when (field.trim().lowercase(Locale.ROOT)) {
            "geraeteart", "device", "device_type" -> "DEVICE"
            "hersteller", "manufacturer" -> "MANUFACTURER"
            else -> return false
        }
        val clean = value.trim()
        val normalized = normalizeVocabulary(clean)
        if (clean.isBlank() || normalized.isBlank() || clean == "-") return false
        val deviceKey = if (kind == "MANUFACTURER") resolveDeviceKey(deviceType) else ""

        return try {
            val values = ContentValues().apply {
                put("kind", kind)
                put("normalized", normalized)
                put("value", clean)
                put("device_key", deviceKey)
                put("status", "active")
                put("source", "user")
                put("use_count", 1)
                put("updated_at", System.currentTimeMillis())
            }
            db.insertWithOnConflict("dictionary_entries", null, values, SQLiteDatabase.CONFLICT_REPLACE) != -1L
        } catch (exc: Exception) {
            emitError("Wörterbuch-Eintrag fehlgeschlagen: ${exc.message}")
            false
        }
    }

    @UsedByGodot
    fun databaseDismissSuggestion(field: String, value: String, deviceType: String): Boolean {
        val db = ensureDatabase() ?: return false
        val kind = when (field.trim().lowercase(Locale.ROOT)) {
            "geraeteart", "device", "device_type" -> "DEVICE"
            "hersteller", "manufacturer" -> "MANUFACTURER"
            else -> return false
        }
        val clean = value.trim()
        val normalized = normalizeVocabulary(clean)
        if (normalized.isBlank()) return false
        val deviceKey = if (kind == "MANUFACTURER") resolveDeviceKey(deviceType) else ""

        return try {
            val values = ContentValues().apply {
                put("kind", kind)
                put("normalized", normalized)
                put("value", clean)
                put("device_key", deviceKey)
                put("status", "dismissed")
                put("source", "user")
                put("use_count", 0)
                put("updated_at", System.currentTimeMillis())
            }
            db.insertWithOnConflict("dictionary_entries", null, values, SQLiteDatabase.CONFLICT_REPLACE) != -1L
        } catch (exc: Exception) {
            emitError("Vorschlag konnte nicht verworfen werden: ${exc.message}")
            false
        }
    }

    @UsedByGodot
    fun databaseObserveVocabulary(deviceType: String, manufacturer: String): Boolean {
        val db = ensureDatabase() ?: return false
        return try {
            val deviceCandidate = extractUnknownDeviceCandidate(deviceType)
            if (deviceCandidate.isNotBlank() && !isKnownDevice(deviceCandidate, db) && findSimilarDevice(deviceCandidate, db).isBlank()) {
                storePendingVocabulary(db, "DEVICE", deviceCandidate, "")
            }

            val manufacturerClean = manufacturer.trim()
            if (manufacturerClean.isNotBlank() && manufacturerClean != "-") {
                val deviceKey = resolveDeviceKey(deviceType)
                val known = knownManufacturerValues(deviceKey, db)
                if (known.none { normalizeVocabulary(it) == normalizeVocabulary(manufacturerClean) } &&
                    findSimilarValue(manufacturerClean, known).isBlank()
                ) {
                    storePendingVocabulary(db, "MANUFACTURER", manufacturerClean, deviceKey)
                }
            }
            true
        } catch (exc: Exception) {
            emitError("Wörterbuch-Beobachtung fehlgeschlagen: ${exc.message}")
            false
        }
    }

    private fun addStoredVocabulary(
        db: SQLiteDatabase,
        kind: String,
        deviceKey: String,
        queryNorm: String,
        limit: Int,
        result: JSONArray,
        seen: LinkedHashSet<String>,
        deviceType: String,
    ) {
        val selection: String
        val args: Array<String>
        if (kind == "MANUFACTURER") {
            selection = "kind = ? AND status IN ('active','pending') AND (device_key = ? OR device_key = '')"
            args = arrayOf(kind, deviceKey)
        } else {
            selection = "kind = ? AND status IN ('active','pending')"
            args = arrayOf(kind)
        }

        db.query(
            "dictionary_entries",
            arrayOf("value", "status"),
            selection,
            args,
            null,
            null,
            "CASE status WHEN 'active' THEN 0 ELSE 1 END, use_count DESC, updated_at DESC",
            "80",
        ).use { cursor ->
            while (cursor.moveToNext() && result.length() < limit) {
                val value = cursor.getString(0).orEmpty()
                val status = cursor.getString(1).orEmpty()
                val normalized = normalizeVocabulary(value)
                if (normalized.isBlank() || normalized in seen) continue
                if (queryNorm.isNotBlank() && !matchesVocabulary(value, queryNorm)) continue
                if (isVocabularyDismissed(db, kind, normalized, if (kind == "MANUFACTURER") deviceKey else "")) continue

                seen += normalized
                result.put(
                    JSONObject()
                        .put("value", value)
                        .put("label", if (status == "pending") "＋ $value" else value)
                        .put("action", if (status == "pending") "add" else "fill")
                        .put("source", status)
                )
            }
        }
    }

    private fun storePendingVocabulary(db: SQLiteDatabase, kind: String, value: String, deviceKey: String) {
        val clean = value.trim()
        val normalized = normalizeVocabulary(clean)
        if (clean.isBlank() || normalized.isBlank() || isVocabularyDismissed(db, kind, normalized, deviceKey)) return

        val current = db.query(
            "dictionary_entries",
            arrayOf("status"),
            "kind = ? AND normalized = ? AND device_key = ?",
            arrayOf(kind, normalized, deviceKey),
            null,
            null,
            null,
            "1",
        ).use { cursor -> if (cursor.moveToFirst()) cursor.getString(0).orEmpty() else "" }

        if (current == "active" || current == "dismissed") return

        val values = ContentValues().apply {
            put("kind", kind)
            put("normalized", normalized)
            put("value", clean)
            put("device_key", deviceKey)
            put("status", "pending")
            put("source", "observed")
            put("use_count", 0)
            put("updated_at", System.currentTimeMillis())
        }
        db.insertWithOnConflict("dictionary_entries", null, values, SQLiteDatabase.CONFLICT_IGNORE)
    }

    private fun isVocabularyDismissed(
        db: SQLiteDatabase,
        kind: String,
        normalized: String,
        deviceTypeOrKey: String,
    ): Boolean {
        val deviceKey = if (kind == "MANUFACTURER") {
            if (deviceTypeOrKey.contains("/")) deviceTypeOrKey else resolveDeviceKey(deviceTypeOrKey)
        } else {
            ""
        }
        return db.query(
            "dictionary_entries",
            arrayOf("status"),
            "kind = ? AND normalized = ? AND device_key = ?",
            arrayOf(kind, normalized, deviceKey),
            null,
            null,
            null,
            "1",
        ).use { cursor ->
            cursor.moveToFirst() && cursor.getString(0).orEmpty() == "dismissed"
        }
    }

    private fun knownManufacturerValues(deviceKey: String, db: SQLiteDatabase): List<String> {
        val values = LinkedHashSet<String>()
        values.addAll(BASE_MANUFACTURERS[deviceKey].orEmpty())
        db.query(
            "dictionary_entries",
            arrayOf("value"),
            "kind = 'MANUFACTURER' AND status = 'active' AND (device_key = ? OR device_key = '')",
            arrayOf(deviceKey),
            null,
            null,
            "use_count DESC, updated_at DESC",
            "100",
        ).use { cursor ->
            while (cursor.moveToNext()) values += cursor.getString(0).orEmpty()
        }
        return values.filter { it.isNotBlank() }
    }

    private fun isKnownDevice(value: String, db: SQLiteDatabase): Boolean {
        val normalized = normalizeVocabulary(value)
        if (BASE_DEVICE_TYPES.any { normalizeVocabulary(it) == normalized }) return true
        if (DEVICE_ALIAS_TO_KEY.keys.any { normalizeVocabulary(it) == normalized }) return true

        return db.query(
            "dictionary_entries",
            arrayOf("status"),
            "kind = 'DEVICE' AND normalized = ?",
            arrayOf(normalized),
            null,
            null,
            null,
            "1",
        ).use { cursor -> cursor.moveToFirst() && cursor.getString(0).orEmpty() == "active" }
    }

    private fun baseDeviceSuggestionsForSwitch(switchPosition: Int): List<String> {
        return when (switchPosition) {
            4 -> BASE_LINE_TYPES
            3 -> BASE_DEVICE_TYPES.filterNot { value -> BASE_LINE_TYPES.any { normalizeVocabulary(it) == normalizeVocabulary(value) } }
            else -> BASE_DEVICE_TYPES
        }
    }

    private fun deviceAllowedForSwitch(value: String, switchPosition: Int): Boolean {
        if (switchPosition !in listOf(3, 4)) return true
        val isLine = BASE_LINE_TYPES.any { normalizeVocabulary(it) == normalizeVocabulary(value) } ||
            listOf("leitung", "kabel", "verteiler", "kabeltrommel", "verlängerung").any {
                normalizeVocabulary(value).contains(normalizeVocabulary(it))
            }
        return if (switchPosition == 4) isLine else !isLine
    }

    private fun resolveDeviceKey(deviceType: String): String {
        val normalized = normalizeVocabulary(deviceType)
        if (normalized.isBlank()) return ""

        // Special SecuData rule:
        // "Netzteil" on its own uses the Netzteil/Ladegerät manufacturer group.
        // If something follows it, the manufacturer belongs to the appended
        // device instead: "Netzteil TFT" -> TFT, "Netzteil Abheftgerät" ->
        // Abheftgerät. This also works before the appended device is formally
        // accepted into the dictionary.
        val netzteilPrefixes = listOf("netzteil", "nt")
        for (prefix in netzteilPrefixes) {
            if (normalized.startsWith("$prefix ")) {
                val remainder = normalized.removePrefix("$prefix ").trim()
                if (remainder.isNotBlank()) {
                    return resolveDeviceKey(remainder)
                }
            }
        }

        val orderedAliases = DEVICE_ALIAS_TO_KEY.keys.sortedByDescending { it.length }
        for (alias in orderedAliases) {
            val aliasNorm = normalizeVocabulary(alias)
            if (normalized == aliasNorm || normalized.startsWith("$aliasNorm ")) {
                return DEVICE_ALIAS_TO_KEY[alias].orEmpty()
            }
        }

        for (token in normalized.split(" ")) {
            val hit = DEVICE_ALIAS_TO_KEY.entries.firstOrNull { normalizeVocabulary(it.key) == token }
            if (hit != null) return hit.value
        }
        return normalized
    }

    private fun splitNetzteilCompound(input: String): Pair<String, String>? {
        val expanded = expandDeviceAbbreviations(input)
        val match = Regex("^\\s*(Netzteil)\\s+(.*)$", RegexOption.IGNORE_CASE).find(expanded)
            ?: return null
        return Pair("Netzteil", match.groupValues[2].trim())
    }

    private fun extractUnknownDeviceCandidate(input: String): String {
        val clean = input.trim().replace(Regex("\\s+"), " ")
        if (clean.isBlank() || clean == "-") return ""

        val normalized = normalizeVocabulary(clean)
        val orderedKnown = (BASE_DEVICE_TYPES + DEVICE_ALIAS_TO_KEY.keys)
            .distinct()
            .sortedByDescending { it.length }

        for (known in orderedKnown) {
            val knownNorm = normalizeVocabulary(known)
            if (normalized == knownNorm) return ""
            if (normalized.startsWith("$knownNorm ")) {
                val remainder = clean.substring(known.length.coerceAtMost(clean.length)).trim(' ', '-', '/', ',')
                if (remainder.isBlank() || remainder.matches(Regex("^[0-9 .,+/_-]+$"))) return ""
                if (isBaseKnownDevice(remainder)) return ""
                return remainder
            }
        }
        return clean
    }

    private fun isBaseKnownDevice(value: String): Boolean {
        val normalized = normalizeVocabulary(value)
        return BASE_DEVICE_TYPES.any { normalizeVocabulary(it) == normalized } ||
            DEVICE_ALIAS_TO_KEY.keys.any { normalizeVocabulary(it) == normalized }
    }

    private fun findSimilarDevice(value: String, db: SQLiteDatabase): String {
        val candidates = LinkedHashSet<String>()
        candidates.addAll(BASE_DEVICE_TYPES)
        db.query(
            "dictionary_entries",
            arrayOf("value"),
            "kind = 'DEVICE' AND status = 'active'",
            null,
            null,
            null,
            "use_count DESC, updated_at DESC",
            "120",
        ).use { cursor ->
            while (cursor.moveToNext()) candidates += cursor.getString(0).orEmpty()
        }
        return findSimilarValue(value, candidates.toList())
    }

    private fun findSimilarValue(value: String, candidates: List<String>): String {
        val needle = normalizeVocabulary(value)
        if (needle.length < 3) return ""
        var best = ""
        var bestDistance = Int.MAX_VALUE
        for (candidate in candidates) {
            val target = normalizeVocabulary(candidate)
            if (target.isBlank() || target == needle) continue
            val distance = levenshtein(needle, target)
            val threshold = when {
                needle.length <= 5 -> 1
                needle.length <= 10 -> 2
                else -> 3
            }
            if (distance <= threshold && distance < bestDistance) {
                best = candidate
                bestDistance = distance
            }
        }
        return best
    }

    private fun matchesVocabulary(value: String, queryNorm: String): Boolean {
        if (queryNorm.isBlank()) return true
        val valueNorm = normalizeVocabulary(value)
        if (valueNorm.contains(queryNorm) || valueNorm.startsWith(queryNorm)) return true
        val expanded = DEVICE_ABBREVIATIONS.entries.firstOrNull {
            normalizeVocabulary(it.key) == queryNorm
        }?.value.orEmpty()
        return expanded.isNotBlank() && normalizeVocabulary(value).contains(normalizeVocabulary(expanded))
    }

    private fun normalizeVocabulary(value: String): String {
        val lower = value.trim().lowercase(Locale.ROOT).replace("ß", "ss")
        val decomposed = Normalizer.normalize(lower, Normalizer.Form.NFD)
        return decomposed
            .replace(Regex("\\p{M}+"), "")
            .replace(Regex("[^a-z0-9]+"), " ")
            .trim()
            .replace(Regex("\\s+"), " ")
    }

    private fun levenshtein(left: String, right: String): Int {
        if (left == right) return 0
        if (left.isEmpty()) return right.length
        if (right.isEmpty()) return left.length

        var previous = IntArray(right.length + 1) { it }
        for (i in left.indices) {
            val current = IntArray(right.length + 1)
            current[0] = i + 1
            for (j in right.indices) {
                val cost = if (left[i] == right[j]) 0 else 1
                current[j + 1] = min(
                    min(current[j] + 1, previous[j + 1] + 1),
                    previous[j] + cost,
                )
            }
            previous = current
        }
        return previous[right.length]
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

            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS dictionary_entries (
                    kind TEXT NOT NULL,
                    normalized TEXT NOT NULL,
                    value TEXT NOT NULL,
                    device_key TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'active',
                    source TEXT NOT NULL DEFAULT 'user',
                    use_count INTEGER NOT NULL DEFAULT 0,
                    updated_at INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(kind, normalized, device_key)
                )
                """.trimIndent()
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS idx_dictionary_status ON dictionary_entries(kind, status, device_key)")
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
