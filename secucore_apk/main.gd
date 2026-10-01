extends Control

var core
var ble
var rx_buffer := ""
var pending_command := ""
var current_measurement: Dictionary = {}
var post_action_mode := ""

var status_label: Label
var detail_label: Label
var ble_label: Label
var measurement_label: Label
var frame_label: Label
var connect_button: Button
var init_button: Button
var mes_button: Button
var fetch_button: Button
var test_button: Button
var save_button: Button
var discard_button: Button
var command_timer: Timer


func _ready() -> void:
    OS.low_processor_usage_mode = true
    OS.low_processor_usage_mode_sleep_usec = 33000
    Engine.max_fps = 30

    _build_ui()
    _build_timeout_timer()
    print("GODOT_SCENE_READY")

    if not ClassDB.class_exists("SecuCore"):
        status_label.text = "SECUCORE C++ NICHT GELADEN"
        status_label.modulate = Color("ff7885")
        detail_label.text = "Die native GDExtension konnte nicht geladen werden."
        connect_button.disabled = true
        init_button.disabled = true
        mes_button.disabled = true
        fetch_button.disabled = true
        test_button.disabled = true
        save_button.disabled = true
        discard_button.disabled = true
        print("SECUCORE_CLASS_MISSING")
        return

    core = ClassDB.instantiate("SecuCore")
    status_label.text = "SECUCORE C++ GELADEN"
    status_label.modulate = Color("68e39a")
    detail_label.text = core.get_version() + "\nBasis: SecuData fix117"

    var self_test: Dictionary = core.self_test()
    frame_label.text = (
        "Native Selbstprüfung: "
        + ("OK" if bool(self_test.get("ok", false)) else "FEHLER")
        + "\n"
        + str(self_test.get("detail", ""))
    )
    if bool(self_test.get("ok", false)):
        print("SECUCORE_SMOKE_OK")
    else:
        print("SECUCORE_SMOKE_FAILED: " + str(self_test))

    _setup_ble()


func _build_timeout_timer() -> void:
    command_timer = Timer.new()
    command_timer.one_shot = true
    command_timer.wait_time = 4.0
    command_timer.timeout.connect(_on_command_timeout)
    add_child(command_timer)


func _setup_ble() -> void:
    if not Engine.has_singleton("SecuDataBle"):
        ble_label.text = "BLE-Bridge nur im Android-Build verfügbar."
        connect_button.disabled = true
        init_button.disabled = true
        mes_button.disabled = true
        fetch_button.disabled = true
        return

    ble = Engine.get_singleton("SecuDataBle")
    ble.state_changed.connect(_on_ble_state_changed)
    ble.rx_text.connect(_on_ble_rx_text)
    ble.ble_error.connect(_on_ble_error)

    connect_button.disabled = false
    init_button.disabled = true
    mes_button.disabled = true
    fetch_button.disabled = true

    if not bool(ble.isBluetoothSupported()):
        ble_label.text = "Bluetooth LE wird auf diesem Gerät nicht unterstützt."
        connect_button.disabled = true
        return

    ble_label.text = "BLE bereit - Berechtigung: " + str(ble.getPermissionState())


func _build_ui() -> void:
    var bg := ColorRect.new()
    bg.color = Color("07101a")
    bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    add_child(bg)

    var margin := MarginContainer.new()
    margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    margin.add_theme_constant_override("margin_left", 24)
    margin.add_theme_constant_override("margin_right", 24)
    margin.add_theme_constant_override("margin_top", 28)
    margin.add_theme_constant_override("margin_bottom", 28)
    add_child(margin)

    var root := VBoxContainer.new()
    root.add_theme_constant_override("separation", 12)
    margin.add_child(root)

    var title := Label.new()
    title.text = "SECU-DAT"
    title.add_theme_font_size_override("font_size", 40)
    title.modulate = Color("ff4d5d")
    root.add_child(title)

    var subtitle := Label.new()
    subtitle.text = "SecuCore Android Debug - v0.8"
    subtitle.add_theme_font_size_override("font_size", 21)
    subtitle.modulate = Color("a9b7c6")
    root.add_child(subtitle)

    status_label = Label.new()
    status_label.text = "SECUCORE WIRD GELADEN ..."
    status_label.add_theme_font_size_override("font_size", 25)
    root.add_child(status_label)

    detail_label = Label.new()
    detail_label.add_theme_font_size_override("font_size", 17)
    detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    root.add_child(detail_label)

    root.add_child(HSeparator.new())

    ble_label = Label.new()
    ble_label.text = "BLE wird initialisiert ..."
    ble_label.add_theme_font_size_override("font_size", 17)
    ble_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    ble_label.modulate = Color("c8d2dc")
    root.add_child(ble_label)

    connect_button = Button.new()
    connect_button.text = "BLE RS232 VERBINDEN"
    connect_button.custom_minimum_size.y = 58
    connect_button.add_theme_font_size_override("font_size", 18)
    connect_button.disabled = true
    connect_button.pressed.connect(_connect_ble)
    root.add_child(connect_button)

    init_button = Button.new()
    init_button.text = "SECUTEST VERBINDUNG + STATUS"
    init_button.custom_minimum_size.y = 54
    init_button.add_theme_font_size_override("font_size", 17)
    init_button.disabled = true
    init_button.pressed.connect(_start_live_init)
    root.add_child(init_button)

    mes_button = Button.new()
    mes_button.text = "MES? STATUS AKTUALISIEREN"
    mes_button.custom_minimum_size.y = 50
    mes_button.add_theme_font_size_override("font_size", 16)
    mes_button.disabled = true
    mes_button.pressed.connect(_refresh_mes_status)
    root.add_child(mes_button)

    fetch_button = Button.new()
    fetch_button.text = "WARTET AUF PRX - AUTOMATISCH"
    fetch_button.custom_minimum_size.y = 50
    fetch_button.add_theme_font_size_override("font_size", 16)
    fetch_button.disabled = true
    fetch_button.pressed.connect(_start_measurement_fetch)
    root.add_child(fetch_button)

    test_button = Button.new()
    test_button.text = "SIMULIERTE FIX117-MESSUNG"
    test_button.custom_minimum_size.y = 50
    test_button.add_theme_font_size_override("font_size", 16)
    test_button.pressed.connect(_run_measurement)
    root.add_child(test_button)

    var decision_row := HBoxContainer.new()
    decision_row.add_theme_constant_override("separation", 10)
    root.add_child(decision_row)

    discard_button = Button.new()
    discard_button.text = "VERWERFEN"
    discard_button.custom_minimum_size.y = 58
    discard_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    discard_button.add_theme_font_size_override("font_size", 17)
    discard_button.add_theme_color_override("font_color", Color("ff7885"))
    discard_button.disabled = true
    discard_button.pressed.connect(_discard_current_measurement)
    decision_row.add_child(discard_button)

    save_button = Button.new()
    save_button.text = "SPEICHERN"
    save_button.custom_minimum_size.y = 58
    save_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    save_button.add_theme_font_size_override("font_size", 17)
    save_button.add_theme_color_override("font_color", Color("68e39a"))
    save_button.disabled = true
    save_button.pressed.connect(_save_current_measurement)
    decision_row.add_child(save_button)

    measurement_label = Label.new()
    measurement_label.text = "Bereit. Keine aktive Gerätekommunikation."
    measurement_label.add_theme_font_size_override("font_size", 20)
    measurement_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    measurement_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
    root.add_child(measurement_label)

    frame_label = Label.new()
    frame_label.add_theme_font_size_override("font_size", 14)
    frame_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    frame_label.modulate = Color("7f93a7")
    root.add_child(frame_label)


func _connect_ble() -> void:
    if ble == null:
        return

    if str(ble.getPermissionState()) != "GRANTED":
        ble.requestPermissions()
        ble_label.text = "Bluetooth-Berechtigung angefordert. Zulassen und danach noch einmal auf Verbinden tippen."
        return

    command_timer.stop()
    pending_command = ""
    rx_buffer = ""
    current_measurement = {}
    post_action_mode = ""
    core.reset_live_init()
    core.reset_measurement_flow()
    core.reset_post_measurement()
    _set_decision_buttons(false)
    init_button.disabled = true
    mes_button.disabled = true
    fetch_button.disabled = true
    measurement_label.text = "Suche nach BLE RS232 ..."
    measurement_label.modulate = Color("c8d2dc")
    ble.startScan("BLE RS232")


func _on_ble_state_changed(state: String, detail: String) -> void:
    ble_label.text = state + (" - " + detail if not detail.is_empty() else "")

    if state == "READY":
        connect_button.text = "BLE NEU VERBINDEN"
        init_button.disabled = false
        mes_button.disabled = true
        fetch_button.disabled = true
        _start_live_init()
    elif state in ["SCANNING", "CONNECTING", "CONNECTED", "UART_FOUND", "ENABLING_NOTIFY"]:
        init_button.disabled = true
        mes_button.disabled = true
        fetch_button.disabled = true
    elif state == "DISCONNECTED":
        command_timer.stop()
        pending_command = ""
        current_measurement = {}
        post_action_mode = ""
        _set_decision_buttons(false)
        if core != null:
            core.reset_live_init()
            core.reset_measurement_flow()
            core.reset_post_measurement()
        init_button.disabled = true
        mes_button.disabled = true
        fetch_button.disabled = true


func _on_ble_error(message: String) -> void:
    command_timer.stop()
    pending_command = ""
    ble_label.text = "BLE-FEHLER - " + message
    measurement_label.text = message
    measurement_label.modulate = Color("ff7885")
    init_button.disabled = false if ble != null and str(ble.getConnectionState()) == "READY" else true
    mes_button.disabled = true
    fetch_button.disabled = true


func _start_live_init() -> void:
    if ble == null or core == null:
        return
    if str(ble.getConnectionState()) != "READY":
        measurement_label.text = "BLE ist noch nicht bereit."
        measurement_label.modulate = Color("ffcc66")
        return

    rx_buffer = ""
    current_measurement = {}
    post_action_mode = ""
    _set_decision_buttons(false)
    core.reset_live_init()
    core.reset_measurement_flow()
    core.reset_post_measurement()
    init_button.disabled = true
    mes_button.disabled = true
    fetch_button.disabled = true
    var action: Dictionary = core.begin_live_init()
    _send_core_action(action)


func _refresh_mes_status() -> void:
    if ble == null or core == null or not current_measurement.is_empty():
        return

    var action: Dictionary = core.begin_mes_status_query()
    if not bool(action.get("accepted", false)):
        measurement_label.text = str(action.get("message", "MES? nicht möglich"))
        measurement_label.modulate = Color("ffcc66")
        return

    mes_button.disabled = true
    _send_core_action(action)


func _start_measurement_fetch() -> void:
    measurement_label.text = "Messdaten werden nur nach einem echten PRX-Fertigsignal automatisch abgerufen."
    measurement_label.modulate = Color("ffcc66")


func _send_core_action(action: Dictionary) -> void:
    var frame := str(action.get("next_frame", ""))
    var command := str(action.get("next_command", ""))
    if frame.is_empty():
        return

    var wire_text := frame
    var tx_prefix := "RAW " if bool(action.get("raw_command", false)) else ""

    pending_command = command
    measurement_label.text = (
        str(action.get("message", "SECUTEST-Kommunikation"))
        + "\n"
        + str(action.get("state", ""))
    )
    measurement_label.modulate = Color("c8d2dc")
    frame_label.text = "TX: " + tx_prefix + command + "\n" + frame.replace("\r", "\\r")

    if not bool(ble.sendText(wire_text)):
        pending_command = ""
        measurement_label.text = command + " konnte nicht über BLE gesendet werden."
        measurement_label.modulate = Color("ff7885")
        init_button.disabled = false
        return

    command_timer.start()


func _on_ble_rx_text(chunk: String) -> void:
    rx_buffer += chunk

    while "\r" in rx_buffer:
        var split_at := rx_buffer.find("\r")
        var line := rx_buffer.substr(0, split_at)
        rx_buffer = rx_buffer.substr(split_at + 1)
        if line.is_empty():
            continue
        _consume_rx_line(line)


func _consume_rx_line(line: String) -> void:
    if core == null:
        return

    var preview: Dictionary = core.parse_frame(line)
    var payload := str(preview.get("payload", "")).strip_edges()
    var upper := payload.to_upper()
    var measurement_state := str(core.get_measurement_state())
    var post_state := str(core.get_post_measurement_state())

    if post_state in ["WAIT_RESET_ACK", "WAIT_TASA_ACK"]:
        _consume_post_measurement_line(line)
        return

    var is_prx_trigger := measurement_state == "ARMED" and upper == "PRX"
    var measurement_command_pending := pending_command in ["TAS?", "PRX?X", "PRX?Y", "PRX?Z"]

    if is_prx_trigger or measurement_command_pending:
        _consume_measurement_line(line)
        return

    if not pending_command.is_empty() or str(core.get_live_state()) != "READY":
        _consume_live_line(line)
        return

    if measurement_state == "ARMED":
        _consume_measurement_line(line)
        return

    frame_label.text = "RX unsolicited: " + str(preview.get("normalized", line))


func _consume_live_line(line: String) -> void:
    var result: Dictionary = core.consume_live_line(line)
    var parsed: Dictionary = result.get("frame", {})
    var checksum_state := str(parsed.get("checksum_state", "?"))

    frame_label.text = (
        "RX: " + str(parsed.get("normalized", line))
        + "\nChecksum: " + checksum_state
        + " - Core: " + str(result.get("state", ""))
    )

    if not bool(result.get("accepted", false)):
        return

    command_timer.stop()
    pending_command = ""

    if result.has("next_frame"):
        _send_core_action(result)
        return

    if bool(result.get("complete", false)) and bool(result.get("success", false)):
        var identity := str(result.get("identity", ""))
        var mes_status := str(result.get("mes_status", ""))
        core.arm_measurement_monitor()
        measurement_label.text = (
            "SECUTEST LIVE BEREIT"
            + "\n" + identity
            + "\nMES: " + mes_status
            + "\nLausche auf PRX ..."
        )
        measurement_label.modulate = Color("68e39a")
        init_button.disabled = false
        mes_button.disabled = false
        print("SECUCORE_LIVE_READY: " + identity + " | " + mes_status)
        return

    if bool(result.get("complete", false)):
        measurement_label.text = (
            "VERBINDUNGSFEHLER"
            + "\n" + str(result.get("message", "unbekannt"))
            + "\nState: " + str(result.get("state", ""))
        )
        measurement_label.modulate = Color("ff7885")
        init_button.disabled = false
        mes_button.disabled = true


func _consume_measurement_line(line: String) -> void:
    var result: Dictionary = core.consume_measurement_line(line)
    var parsed: Dictionary = result.get("frame", {})
    var checksum_state := str(parsed.get("checksum_state", "?"))

    frame_label.text = (
        "RX: " + str(parsed.get("normalized", line))
        + "\nChecksum: " + checksum_state
        + " - Measurement: " + str(result.get("state", ""))
    )

    if not bool(result.get("accepted", false)):
        return

    if bool(result.get("prx_trigger", false)):
        measurement_label.text = "PRX erkannt\nDrehschalter wird vor X/Y/Z abgefragt ..."
        measurement_label.modulate = Color("c8d2dc")

    command_timer.stop()
    pending_command = ""

    if result.has("next_frame"):
        _send_core_action(result)
        return

    if not bool(result.get("complete", false)):
        return

    if bool(result.get("success", false)):
        var measurement: Dictionary = result.get("measurement", {})
        if bool(result.get("duplicate", false)):
            measurement_label.text = (
                "DUPLIKAT VERWORFEN"
                + "\nSECUTEST-Zeit: " + str(measurement.get("device_date", ""))
                + " " + str(measurement.get("device_time", ""))
                + "\nLausche wieder auf PRX."
            )
            measurement_label.modulate = Color("ffcc66")
            core.arm_measurement_monitor()
            mes_button.disabled = false
        else:
            current_measurement = measurement.duplicate(true)
            _show_real_measurement(current_measurement)
            _set_decision_buttons(true)
            init_button.disabled = true
            mes_button.disabled = true
        return

    measurement_label.text = (
        "MESSDATEN-FEHLER"
        + "\n" + str(result.get("message", "unbekannt"))
        + "\nState: " + str(result.get("state", ""))
    )
    measurement_label.modulate = Color("ff7885")
    core.arm_measurement_monitor()
    mes_button.disabled = false


func _show_real_measurement(measurement: Dictionary) -> void:
    var position := int(measurement.get("switch_position", -1))
    var kind := str(measurement.get("measurement_kind", "ALLE_VORSCHLAEGE"))
    var kind_text := "Gerät" if kind == "GERAET" else ("Leitung" if kind == "LEITUNG" else "andere Stellung")

    var ok: bool = bool(measurement.get("is_ok", false))
    measurement_label.modulate = Color("68e39a") if ok else Color("ff7885")

    var lines: Array[String] = []
    lines.append("ECHTE MESSUNG - " + ("OK" if ok else "NICHT OK"))
    lines.append("Drehschalter: " + str(position) + " - " + kind_text)
    lines.append("SECUTEST-Zeit: " + str(measurement.get("device_date", "")) + " " + str(measurement.get("device_time", "")))

    # RPE is only present when the selected test actually contains a
    # protective-conductor measurement (e.g. SK I). SK II legitimately has no
    # protective conductor, so an absent RPE field is not an error and is hidden.
    if measurement.get("rpe") != null:
        var rpe_line := "RPE: " + _fmt(measurement.get("rpe")) + " Ω"
        if measurement.get("rpe_limit") != null:
            rpe_line += "   GW " + _fmt(measurement.get("rpe_limit")) + " Ω"
        lines.append(rpe_line)

    if measurement.get("drpe") != null:
        var drpe_line := "ΔRPE: " + _fmt(measurement.get("drpe")) + " Ω"
        if measurement.get("drpe_limit") != null:
            drpe_line += "   GW " + _fmt(measurement.get("drpe_limit")) + " Ω"
        lines.append(drpe_line)

    if measurement.get("rins") != null:
        var rins_line := "RISO: " + _fmt(measurement.get("rins")) + " MΩ"
        if measurement.get("rins_limit") != null:
            rins_line += "   GW " + _fmt(measurement.get("rins_limit")) + " MΩ"
        lines.append(rins_line)

    if measurement.get("uiso") != null:
        var uiso_line := "UISO: " + _fmt(measurement.get("uiso")) + " V"
        if measurement.get("uiso_limit") != null:
            uiso_line += "   GW " + _fmt(measurement.get("uiso_limit")) + " V"
        lines.append(uiso_line)

    if measurement.get("ipe") != null:
        var ipe_line := "IPE: " + _fmt(measurement.get("ipe")) + " mA"
        if measurement.get("ipe_limit") != null:
            ipe_line += "   GW " + _fmt(measurement.get("ipe_limit")) + " mA"
        lines.append(ipe_line)

    if measurement.get("u") != null:
        var u_line := "U: " + _fmt(measurement.get("u")) + " V"
        if measurement.get("u_limit") != null:
            u_line += "   GW " + _fmt(measurement.get("u_limit")) + " V"
        lines.append(u_line)

    lines.append("")
    lines.append("Speichern oder Verwerfen.")

    measurement_label.text = "\n".join(lines)
    print("SECUCORE_REAL_MEASUREMENT: " + str(measurement))


func _set_decision_buttons(enabled: bool) -> void:
    save_button.disabled = not enabled
    discard_button.disabled = not enabled


func _save_current_measurement() -> void:
    if current_measurement.is_empty():
        return

    if not _persist_measurement(current_measurement):
        measurement_label.text += "\n\nSPEICHERN FEHLGESCHLAGEN - lokale Datei konnte nicht geöffnet werden."
        measurement_label.modulate = Color("ff7885")
        return

    _begin_post_measurement_action("GESPEICHERT")


func _discard_current_measurement() -> void:
    if current_measurement.is_empty():
        return
    _begin_post_measurement_action("VERWORFEN")


func _persist_measurement(measurement: Dictionary) -> bool:
    var path := "user://secudata_measurements.jsonl"
    var file: FileAccess

    if FileAccess.file_exists(path):
        file = FileAccess.open(path, FileAccess.READ_WRITE)
        if file != null:
            file.seek_end()
    else:
        file = FileAccess.open(path, FileAccess.WRITE)

    if file == null:
        return false

    var record := measurement.duplicate(true)
    record["saved_at"] = Time.get_datetime_string_from_system()
    record["source"] = "SecuCore Android v0.8"
    file.store_line(JSON.stringify(record))
    file.flush()
    file.close()
    return true


func _begin_post_measurement_action(mode: String) -> void:
    if current_measurement.is_empty():
        return

    post_action_mode = mode
    _set_decision_buttons(false)
    init_button.disabled = true
    mes_button.disabled = true

    var switch_position := int(current_measurement.get("switch_position", -1))
    core.reset_post_measurement()
    var action: Dictionary = core.begin_post_measurement_reset(switch_position)
    _send_core_action(action)


func _consume_post_measurement_line(line: String) -> void:
    var result: Dictionary = core.consume_post_measurement_line(line)
    var parsed: Dictionary = result.get("frame", {})
    var checksum_state := str(parsed.get("checksum_state", "?"))

    frame_label.text = (
        "RX: " + str(parsed.get("normalized", line))
        + "\nChecksum: " + checksum_state
        + " - Post: " + str(result.get("state", ""))
    )

    if not bool(result.get("accepted", false)):
        return

    command_timer.stop()
    pending_command = ""

    if result.has("next_frame"):
        _send_core_action(result)
        return

    if bool(result.get("complete", false)) and bool(result.get("success", false)):
        var completed_mode := post_action_mode
        current_measurement = {}
        post_action_mode = ""
        core.reset_post_measurement()
        core.arm_measurement_monitor()
        init_button.disabled = false
        mes_button.disabled = false
        _set_decision_buttons(false)
        measurement_label.text = (
            completed_mode
            + "\nReset/Remote-Modus abgeschlossen."
            + "\nLausche wieder auf PRX ..."
        )
        measurement_label.modulate = Color("68e39a") if completed_mode == "GESPEICHERT" else Color("c8d2dc")
        return

    if bool(result.get("complete", false)):
        measurement_label.text = (
            post_action_mode
            + ", ABER RESET FEHLGESCHLAGEN"
            + "\n" + str(result.get("message", "unbekannt"))
            + "\nBLE bitte neu verbinden."
        )
        measurement_label.modulate = Color("ff7885")
        current_measurement = {}
        post_action_mode = ""
        core.reset_post_measurement()
        _set_decision_buttons(false)


func _on_command_timeout() -> void:
    var timed_out := pending_command
    pending_command = ""

    if core == null:
        return

    var post_state := str(core.get_post_measurement_state())
    if post_state in ["WAIT_RESET_ACK", "WAIT_TASA_ACK"]:
        measurement_label.text = (
            post_action_mode
            + ", ABER TIMEOUT bei " + timed_out
            + "\nBLE bitte neu verbinden."
        )
        measurement_label.modulate = Color("ffcc66")
        current_measurement = {}
        post_action_mode = ""
        core.reset_post_measurement()
        _set_decision_buttons(false)
        return

    if timed_out in ["TAS?", "PRX?X", "PRX?Y", "PRX?Z"]:
        var measurement_state := str(core.get_measurement_state())
        measurement_label.text = (
            "TIMEOUT bei " + timed_out
            + "\nMeasurement: " + measurement_state
            + "\nLauschen wird wieder aktiviert."
        )
        measurement_label.modulate = Color("ffcc66")
        core.arm_measurement_monitor()
        mes_button.disabled = false
        return

    var live_state := str(core.get_live_state())
    measurement_label.text = (
        "TIMEOUT bei " + timed_out
        + "\nCore: " + live_state
        + "\nVerbindungstest kann erneut gestartet werden."
    )
    measurement_label.modulate = Color("ffcc66")
    core.reset_live_init()
    core.reset_measurement_flow()
    init_button.disabled = false if ble != null and str(ble.getConnectionState()) == "READY" else true
    mes_button.disabled = true


func _run_measurement() -> void:
    if core == null:
        return

    var result: Dictionary = core.simulate_fix117_measurement()
    if not bool(result.get("valid", false)):
        measurement_label.text = "PARSER-FEHLER\n" + str(result.get("error", "unbekannt"))
        measurement_label.modulate = Color("ff7885")
        return

    _show_real_measurement(result)


func _fmt(value) -> String:
    if value == null:
        return "—"
    return str(value)


func _notification(what: int) -> void:
    if what == NOTIFICATION_APPLICATION_PAUSED:
        if command_timer != null:
            command_timer.stop()
        pending_command = ""
        rx_buffer = ""
        current_measurement = {}
        post_action_mode = ""
        if core != null:
            core.reset_live_init()
            core.reset_measurement_flow()
            core.reset_post_measurement()
        if ble != null:
            ble.disconnect()
    elif what == NOTIFICATION_APPLICATION_RESUMED:
        if ble_label != null:
            ble_label.text = "App aktiv - BLE bei Bedarf neu verbinden"
        if measurement_label != null:
            measurement_label.text = "Bereit. Keine Hintergrundkommunikation aktiv."
