extends Control

var core
var ble
var rx_buffer := ""
var pending_command := ""

var status_label: Label
var detail_label: Label
var ble_label: Label
var measurement_label: Label
var frame_label: Label
var connect_button: Button
var init_button: Button
var mes_button: Button
var test_button: Button
var command_timer: Timer

func _ready() -> void:
    # Diese App ist UI-/Event-getrieben. Kein Grund, im Leerlauf mit voller
    # Renderfrequenz zu laufen.
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
        test_button.disabled = true
        print("SECUCORE_CLASS_MISSING")
        return

    core = ClassDB.instantiate("SecuCore")
    status_label.text = "SECUCORE C++ GELADEN"
    status_label.modulate = Color("68e39a")
    detail_label.text = core.get_version() + "\nBasis: SecuData fix117"

    var self_test: Dictionary = core.self_test()
    frame_label.text = "Native Selbstprüfung: " + ("OK" if bool(self_test.get("ok", false)) else "FEHLER") + "\n" + str(self_test.get("detail", ""))
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
        return

    ble = Engine.get_singleton("SecuDataBle")
    ble.state_changed.connect(_on_ble_state_changed)
    ble.rx_text.connect(_on_ble_rx_text)
    ble.ble_error.connect(_on_ble_error)

    connect_button.disabled = false
    init_button.disabled = true
    mes_button.disabled = true

    if not bool(ble.isBluetoothSupported()):
        ble_label.text = "Bluetooth LE wird auf diesem Gerät nicht unterstützt."
        connect_button.disabled = true
        return

    ble_label.text = "BLE bereit · Berechtigung: " + str(ble.getPermissionState())

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
    subtitle.text = "SecuCore Android Debug · v0.4"
    subtitle.add_theme_font_size_override("font_size", 21)
    subtitle.modulate = Color("a9b7c6")
    root.add_child(subtitle)

    status_label = Label.new()
    status_label.text = "SECUCORE WIRD GELADEN …"
    status_label.add_theme_font_size_override("font_size", 25)
    root.add_child(status_label)

    detail_label = Label.new()
    detail_label.add_theme_font_size_override("font_size", 17)
    detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    root.add_child(detail_label)

    var divider := HSeparator.new()
    root.add_child(divider)

    ble_label = Label.new()
    ble_label.text = "BLE wird initialisiert …"
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

    test_button = Button.new()
    test_button.text = "SIMULIERTE FIX117-MESSUNG"
    test_button.custom_minimum_size.y = 50
    test_button.add_theme_font_size_override("font_size", 16)
    test_button.pressed.connect(_run_measurement)
    root.add_child(test_button)

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
    core.reset_live_init()
    init_button.disabled = true
    mes_button.disabled = true
    measurement_label.text = "Suche nach BLE RS232 …"
    measurement_label.modulate = Color("c8d2dc")
    ble.startScan("BLE RS232")

func _on_ble_state_changed(state: String, detail: String) -> void:
    ble_label.text = state + (" · " + detail if not detail.is_empty() else "")

    if state == "READY":
        connect_button.text = "BLE NEU VERBINDEN"
        init_button.disabled = false
        mes_button.disabled = true
        # Der echte Nutzungsfall soll nach dem Connect ohne Extra-Tippen bereit sein.
        _start_live_init()
    elif state in ["SCANNING", "CONNECTING", "CONNECTED", "UART_FOUND", "ENABLING_NOTIFY"]:
        init_button.disabled = true
        mes_button.disabled = true
    elif state == "DISCONNECTED":
        command_timer.stop()
        pending_command = ""
        core.reset_live_init()
        init_button.disabled = true
        mes_button.disabled = true

func _on_ble_error(message: String) -> void:
    command_timer.stop()
    pending_command = ""
    ble_label.text = "BLE-FEHLER · " + message
    measurement_label.text = message
    measurement_label.modulate = Color("ff7885")
    init_button.disabled = false if ble != null and str(ble.getConnectionState()) == "READY" else true
    mes_button.disabled = true

func _start_live_init() -> void:
    if ble == null or core == null:
        return
    if str(ble.getConnectionState()) != "READY":
        measurement_label.text = "BLE ist noch nicht bereit."
        measurement_label.modulate = Color("ffcc66")
        return

    rx_buffer = ""
    core.reset_live_init()
    init_button.disabled = true
    mes_button.disabled = true
    var action: Dictionary = core.begin_live_init()
    _send_core_action(action)

func _refresh_mes_status() -> void:
    if ble == null or core == null:
        return
    var action: Dictionary = core.begin_mes_status_query()
    if not bool(action.get("accepted", false)):
        measurement_label.text = str(action.get("message", "MES? nicht möglich"))
        measurement_label.modulate = Color("ffcc66")
        return
    mes_button.disabled = true
    _send_core_action(action)

func _send_core_action(action: Dictionary) -> void:
    var frame := str(action.get("next_frame", ""))
    var command := str(action.get("next_command", ""))

    if frame.is_empty():
        return

    pending_command = command
    measurement_label.text = (
        str(action.get("message", "SECUTEST-Kommunikation"))
        + "\n"
        + str(action.get("state", ""))
    )
    measurement_label.modulate = Color("c8d2dc")
    frame_label.text = "TX: " + command + "\n" + frame.replace("\r", "\\r")

    if not bool(ble.sendText(frame)):
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

    var result: Dictionary = core.consume_live_line(line)
    var parsed: Dictionary = result.get("frame", {})
    var checksum_state := str(parsed.get("checksum_state", "?"))

    frame_label.text = (
        "RX: " + str(parsed.get("normalized", line))
        + "\nChecksum: " + checksum_state
        + " · Core: " + str(result.get("state", ""))
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
        measurement_label.text = (
            "SECUTEST LIVE BEREIT"
            + "\n" + identity
            + "\nMES: " + mes_status
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

func _on_command_timeout() -> void:
    var timed_out := pending_command
    pending_command = ""
    var state := str(core.get_live_state()) if core != null else "?"
    measurement_label.text = "TIMEOUT bei " + timed_out + "\nCore: " + state + "\nVerbindungstest kann erneut gestartet werden."
    measurement_label.modulate = Color("ffcc66")
    if core != null:
        core.reset_live_init()
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

    var ok: bool = bool(result.get("is_ok", false))
    measurement_label.modulate = Color("68e39a") if ok else Color("ff7885")
    measurement_label.text = (
        ("OK" if ok else "NICHT OK")
        + "\nQuelle: " + str(result.get("source", ""))
        + "\nSECUTEST-Zeit: " + str(result.get("device_date", "")) + " " + str(result.get("device_time", ""))
        + "\nRPE: " + _fmt(result.get("rpe"))
        + "\nRISO: " + _fmt(result.get("rins")) + " MΩ"
        + "\nIPE: " + _fmt(result.get("ipe")) + " mA"
        + "\nU: " + _fmt(result.get("u")) + " V"
    )

func _fmt(value) -> String:
    if value == null:
        return "—"
    return str(value)


func _notification(what: int) -> void:
    if what == NOTIFICATION_APPLICATION_PAUSED:
        # Bildschirm aus / App im Hintergrund: keine Scans, keine GATT-Verbindung,
        # kein laufender Kommando-Timeout. Das verhindert unnötige Hintergrundlast.
        if command_timer != null:
            command_timer.stop()
        pending_command = ""
        rx_buffer = ""
        if core != null:
            core.reset_live_init()
        if ble != null:
            ble.disconnect()
    elif what == NOTIFICATION_APPLICATION_RESUMED:
        if ble_label != null:
            ble_label.text = "App aktiv · BLE bei Bedarf neu verbinden"
        if measurement_label != null:
            measurement_label.text = "Bereit. Keine Hintergrundkommunikation aktiv."
