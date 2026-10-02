extends Control

const FIELD_IDS: Array[String] = ["id", "geraeteart", "hersteller"]
const FIELD_NAMES: Array[String] = ["ID", "GERÄTEART", "HERSTELLER"]
const FIELD_COLORS: Array[Color] = [
    Color("55d6a7"),
    Color("f0b84b"),
    Color("a98be8"),
]

var core
var ble
var rx_buffer := ""
var pending_command := ""
var current_measurement: Dictionary = {}
var post_action_mode := ""

var field_values := {
    "id": "",
    "geraeteart": "",
    "hersteller": "",
}
var active_field_index := 0
var capture_locked := true

var gesture_pressed := false
var gesture_start_position := Vector2.ZERO
var gesture_last_position := Vector2.ZERO
var gesture_press_ms := 0

var today_count := 0
var week_count := 0
var total_count := 0
var current_room := ""

var connection_button: Button
var room_label: Button
var today_label: Button
var measurement_card: PanelContainer
var measurement_title: Label
var measurement_values: Label
var workflow_label: Label
var field_buttons: Array[Button] = []
var gesture_button: Button
var common_input: LineEdit
var suggestion_panel: PanelContainer
var suggestion_hint: Label
var command_timer: Timer

var data_overlay: PanelContainer
var data_list: VBoxContainer
var data_counts_label: Label
var room_dialog: AcceptDialog
var room_input: LineEdit
var delete_dialog: ConfirmationDialog
var pending_delete_record_id := -1


func _ready() -> void:
    OS.low_processor_usage_mode = true
    OS.low_processor_usage_mode_sleep_usec = 33000
    Engine.max_fps = 30

    _build_ui()
    _build_timeout_timer()
    if not ClassDB.class_exists("SecuCore"):
        _set_connection_visual("CORE FEHLT", Color("ff7885"))
        _set_workflow("Native C++-Erweiterung konnte nicht geladen werden.", Color("ff7885"))
        connection_button.disabled = true
        return

    core = ClassDB.instantiate("SecuCore")
    var self_test: Dictionary = core.self_test()
    if not bool(self_test.get("ok", false)):
        print("SECUCORE_SMOKE_FAILED: " + str(self_test))
        _set_workflow("Core-Selbsttest fehlgeschlagen: " + str(self_test.get("detail", "")), Color("ff7885"))
        return

    print("SECUCORE_SMOKE_OK")
    _setup_ble()
    _setup_database_state()
    _set_capture_locked(true)
    _show_waiting_state()


func _build_timeout_timer() -> void:
    command_timer = Timer.new()
    command_timer.one_shot = true
    command_timer.wait_time = 4.0
    command_timer.timeout.connect(_on_command_timeout)
    add_child(command_timer)


func _build_ui() -> void:
    var bg := ColorRect.new()
    bg.color = Color("07111c")
    bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(bg)

    var margin := MarginContainer.new()
    margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    margin.add_theme_constant_override("margin_left", 16)
    margin.add_theme_constant_override("margin_right", 16)
    margin.add_theme_constant_override("margin_top", 18)
    margin.add_theme_constant_override("margin_bottom", 14)
    add_child(margin)

    var root := VBoxContainer.new()
    root.add_theme_constant_override("separation", 10)
    margin.add_child(root)

    # --- Compact status bar -------------------------------------------------
    var topbar := HBoxContainer.new()
    topbar.custom_minimum_size.y = 58
    topbar.add_theme_constant_override("separation", 10)
    root.add_child(topbar)

    var brand := Label.new()
    brand.text = "SECU-DAT"
    brand.add_theme_font_size_override("font_size", 30)
    brand.add_theme_color_override("font_color", Color("f2f5f8"))
    brand.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    topbar.add_child(brand)

    room_label = Button.new()
    room_label.text = "Raum —"
    room_label.add_theme_font_size_override("font_size", 18)
    room_label.add_theme_color_override("font_color", Color("d2d9e0"))
    room_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    room_label.custom_minimum_size.y = 46
    room_label.add_theme_stylebox_override("normal", _box(Color("0b1520"), Color("1f2d3b"), 1, 12))
    room_label.add_theme_stylebox_override("pressed", _box(Color("17212c"), Color("8252b1"), 2, 12))
    room_label.pressed.connect(_open_room_dialog)
    topbar.add_child(room_label)

    today_label = Button.new()
    today_label.text = "Heute 0"
    today_label.add_theme_font_size_override("font_size", 16)
    today_label.add_theme_color_override("font_color", Color("e0e4e8"))
    today_label.custom_minimum_size = Vector2(92, 46)
    today_label.add_theme_stylebox_override("normal", _box(Color("0b1520"), Color("1f2d3b"), 1, 12))
    today_label.add_theme_stylebox_override("pressed", _box(Color("17212c"), Color("89c96e"), 2, 12))
    today_label.pressed.connect(_open_data_view)
    topbar.add_child(today_label)

    connection_button = Button.new()
    connection_button.text = "● BLE"
    connection_button.custom_minimum_size = Vector2(96, 46)
    connection_button.add_theme_font_size_override("font_size", 16)
    connection_button.add_theme_color_override("font_color", Color("8fa0b4"))
    connection_button.add_theme_stylebox_override("normal", _box(Color("0c1724"), Color("26384c"), 1, 13))
    connection_button.add_theme_stylebox_override("hover", _box(Color("111f2e"), Color("3b526a"), 1, 13))
    connection_button.add_theme_stylebox_override("pressed", _box(Color("142437"), Color("55d6a7"), 2, 13))
    connection_button.pressed.connect(_connect_ble)
    topbar.add_child(connection_button)

    # --- Measurement instrument card ---------------------------------------
    measurement_card = PanelContainer.new()
    measurement_card.add_theme_stylebox_override("panel", _box(Color("0b1724"), Color("203248"), 1, 16))
    root.add_child(measurement_card)

    var measurement_margin := MarginContainer.new()
    measurement_margin.add_theme_constant_override("margin_left", 14)
    measurement_margin.add_theme_constant_override("margin_right", 14)
    measurement_margin.add_theme_constant_override("margin_top", 13)
    measurement_margin.add_theme_constant_override("margin_bottom", 13)
    measurement_card.add_child(measurement_margin)

    var measurement_box := VBoxContainer.new()
    measurement_box.add_theme_constant_override("separation", 4)
    measurement_margin.add_child(measurement_box)

    measurement_title = Label.new()
    measurement_title.text = "BEREIT"
    measurement_title.add_theme_font_size_override("font_size", 21)
    measurement_title.add_theme_color_override("font_color", Color("9fb1c4"))
    measurement_box.add_child(measurement_title)

    measurement_values = Label.new()
    measurement_values.text = "Wartet auf SECUTEST"
    measurement_values.add_theme_font_size_override("font_size", 25)
    measurement_values.add_theme_color_override("font_color", Color("e8eef5"))
    measurement_values.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    measurement_box.add_child(measurement_values)

    workflow_label = Label.new()
    workflow_label.text = "Nicht verbunden"
    workflow_label.add_theme_font_size_override("font_size", 15)
    workflow_label.add_theme_color_override("font_color", Color("64788e"))
    workflow_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    measurement_box.add_child(workflow_label)

    # --- Fixed thumb-capture geometry: 2/3 fields + 1/3 gesture pad --------
    var capture_row := HBoxContainer.new()
    capture_row.custom_minimum_size.y = 240
    capture_row.add_theme_constant_override("separation", 9)
    root.add_child(capture_row)

    var field_stack := VBoxContainer.new()
    field_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    field_stack.size_flags_stretch_ratio = 2.0
    field_stack.add_theme_constant_override("separation", 8)
    capture_row.add_child(field_stack)

    for i in FIELD_IDS.size():
        var button := Button.new()
        button.custom_minimum_size.y = 74
        button.size_flags_vertical = Control.SIZE_EXPAND_FILL
        button.add_theme_font_size_override("font_size", 22)
        button.alignment = HORIZONTAL_ALIGNMENT_LEFT
        button.focus_mode = Control.FOCUS_NONE
        button.pressed.connect(_on_field_pressed.bind(i))
        field_stack.add_child(button)
        field_buttons.append(button)

    gesture_button = Button.new()
    gesture_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    gesture_button.size_flags_stretch_ratio = 1.0
    gesture_button.custom_minimum_size = Vector2(138, 240)
    gesture_button.focus_mode = Control.FOCUS_NONE
    gesture_button.add_theme_font_size_override("font_size", 21)
    gesture_button.add_theme_color_override("font_color", Color("d8e2ec"))
    gesture_button.add_theme_stylebox_override("normal", _box(Color("101d2b"), Color("31475e"), 1, 16))
    gesture_button.add_theme_stylebox_override("hover", _box(Color("132334"), Color("3e5871"), 1, 16))
    gesture_button.add_theme_stylebox_override("pressed", _box(Color("16283a"), Color("55d6a7"), 2, 16))
    gesture_button.gui_input.connect(_on_gesture_input)
    capture_row.add_child(gesture_button)

    # --- One shared input, exactly below the three fields -------------------
    common_input = LineEdit.new()
    common_input.custom_minimum_size.y = 76
    common_input.add_theme_font_size_override("font_size", 26)
    common_input.add_theme_color_override("font_color", Color("111820"))
    common_input.add_theme_color_override("font_placeholder_color", Color("6f7b87"))
    common_input.clear_button_enabled = true
    common_input.text_changed.connect(_on_common_input_changed)
    common_input.text_submitted.connect(_on_common_input_submitted)
    root.add_child(common_input)

    # --- Reserved future suggestion space: always between input and keyboard -
    suggestion_panel = PanelContainer.new()
    suggestion_panel.custom_minimum_size.y = 124
    suggestion_panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
    suggestion_panel.add_theme_stylebox_override("panel", _box(Color("09131e"), Color("18283a"), 1, 14))
    root.add_child(suggestion_panel)

    var suggestion_margin := MarginContainer.new()
    suggestion_margin.add_theme_constant_override("margin_left", 12)
    suggestion_margin.add_theme_constant_override("margin_right", 12)
    suggestion_margin.add_theme_constant_override("margin_top", 10)
    suggestion_margin.add_theme_constant_override("margin_bottom", 10)
    suggestion_panel.add_child(suggestion_margin)

    suggestion_hint = Label.new()
    suggestion_hint.text = "WORTVORSCHLÄGE · 2 REIHEN RESERVIERT"
    suggestion_hint.add_theme_font_size_override("font_size", 14)
    suggestion_hint.add_theme_color_override("font_color", Color("34485e"))
    suggestion_hint.vertical_alignment = VERTICAL_ALIGNMENT_TOP
    suggestion_margin.add_child(suggestion_hint)

    _refresh_capture_ui()
    _refresh_gesture_visual()
    _build_room_dialog()
    _build_delete_dialog()
    _build_data_overlay()


func _box(bg: Color, border: Color, width: int = 1, radius: int = 12) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = bg
    style.border_color = border
    style.border_width_left = width
    style.border_width_top = width
    style.border_width_right = width
    style.border_width_bottom = width
    style.corner_radius_top_left = radius
    style.corner_radius_top_right = radius
    style.corner_radius_bottom_left = radius
    style.corner_radius_bottom_right = radius
    style.content_margin_left = 14
    style.content_margin_right = 14
    style.content_margin_top = 8
    style.content_margin_bottom = 8
    return style


func _setup_ble() -> void:
    if not Engine.has_singleton("SecuDataBle"):
        _set_connection_visual("KEIN BLE", Color("ff7885"))
        _set_workflow("BLE-Bridge nur im Android-Build verfügbar.", Color("ff7885"))
        connection_button.disabled = true
        return

    ble = Engine.get_singleton("SecuDataBle")
    ble.state_changed.connect(_on_ble_state_changed)
    ble.rx_text.connect(_on_ble_rx_text)
    ble.ble_error.connect(_on_ble_error)

    if not bool(ble.isBluetoothSupported()):
        _set_connection_visual("KEIN BLE", Color("ff7885"))
        connection_button.disabled = true
        return

    _set_connection_visual("BLE", Color("8fa0b4"))
    _set_workflow("Tippe auf BLE zum Verbinden.", Color("64788e"))


func _connect_ble() -> void:
    if ble == null:
        return

    if str(ble.getPermissionState()) != "GRANTED":
        ble.requestPermissions()
        _set_workflow("Bluetooth-Berechtigung angefordert.", Color("f0b84b"))
        return

    command_timer.stop()
    pending_command = ""
    rx_buffer = ""
    current_measurement = {}
    post_action_mode = ""
    _clear_capture_values()
    _set_capture_locked(true)
    core.reset_live_init()
    core.reset_measurement_flow()
    core.reset_post_measurement()

    _set_connection_visual("SUCHE", Color("f0b84b"))
    _set_workflow("Suche BLE RS232 ...", Color("f0b84b"))
    ble.startScan("BLE RS232")


func _on_ble_state_changed(state: String, detail: String) -> void:
    match state:
        "READY":
            _set_connection_visual("BLE", Color("55d6a7"))
            _set_workflow("SECUTEST wird geprüft ...", Color("8fa0b4"))
            _start_live_init()
        "SCANNING":
            _set_connection_visual("SUCHE", Color("f0b84b"))
        "CONNECTING", "CONNECTED", "UART_FOUND", "ENABLING_NOTIFY":
            _set_connection_visual("VERBINDET", Color("f0b84b"))
        "DISCONNECTED":
            command_timer.stop()
            pending_command = ""
            current_measurement = {}
            _set_capture_locked(true)
            if core != null:
                core.reset_live_init()
                core.reset_measurement_flow()
                core.reset_post_measurement()
            _set_connection_visual("BLE", Color("8fa0b4"))
            _show_waiting_state()
            _set_workflow("Verbindung getrennt.", Color("ff7885"))


func _on_ble_error(message: String) -> void:
    command_timer.stop()
    pending_command = ""
    _set_connection_visual("FEHLER", Color("ff7885"))
    _set_workflow(message, Color("ff7885"))


func _start_live_init() -> void:
    if ble == null or core == null:
        return
    if str(ble.getConnectionState()) != "READY":
        return

    rx_buffer = ""
    current_measurement = {}
    _clear_capture_values()
    _set_capture_locked(true)
    core.reset_live_init()
    core.reset_measurement_flow()
    core.reset_post_measurement()
    var action: Dictionary = core.begin_live_init()
    _send_core_action(action)


func _send_core_action(action: Dictionary) -> void:
    var frame := str(action.get("next_frame", ""))
    var command := str(action.get("next_command", ""))
    if frame.is_empty():
        return

    pending_command = command
    _set_workflow(str(action.get("message", command)), Color("8fa0b4"))

    if not bool(ble.sendText(frame)):
        pending_command = ""
        _set_workflow(command + " konnte nicht gesendet werden.", Color("ff7885"))
        return

    command_timer.start()


func _send_enter() -> void:
    if ble == null or core == null:
        return
    if str(ble.getConnectionState()) != "READY":
        _connect_ble()
        return
    if bool(ble.sendText(core.build_frame("TAS!4"))):
        _set_workflow("ENTER an SECUTEST gesendet.", Color("55d6a7"))
    else:
        _set_workflow("ENTER konnte nicht gesendet werden.", Color("ff7885"))


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


func _consume_live_line(line: String) -> void:
    var result: Dictionary = core.consume_live_line(line)
    if not bool(result.get("accepted", false)):
        return

    command_timer.stop()
    pending_command = ""

    if result.has("next_frame"):
        _send_core_action(result)
        return

    if bool(result.get("complete", false)) and bool(result.get("success", false)):
        core.arm_measurement_monitor()
        _set_connection_visual("BLE", Color("55d6a7"))
        _show_waiting_state()
        _set_workflow("Verbunden · wartet auf PRX", Color("55d6a7"))
        return

    if bool(result.get("complete", false)):
        _set_workflow("Verbindungsfehler: " + str(result.get("message", "unbekannt")), Color("ff7885"))


func _consume_measurement_line(line: String) -> void:
    var result: Dictionary = core.consume_measurement_line(line)
    if not bool(result.get("accepted", false)):
        return

    if bool(result.get("prx_trigger", false)):
        measurement_title.text = "MESSUNG EMPFANGEN"
        measurement_title.add_theme_color_override("font_color", Color("f0b84b"))
        measurement_values.text = "Daten werden übernommen ..."
        _set_workflow("Drehschalter + PRX X/Y/Z", Color("8fa0b4"))

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
            _set_workflow("Doppelter Datensatz verworfen.", Color("f0b84b"))
            core.arm_measurement_monitor()
            _show_waiting_state()
        else:
            current_measurement = measurement.duplicate(true)
            _show_real_measurement(current_measurement)
            _set_capture_locked(false)
            _set_active_field(0, true)
        return

    _set_workflow("Messdatenfehler: " + str(result.get("message", "unbekannt")), Color("ff7885"))
    core.arm_measurement_monitor()
    _show_waiting_state()


func _show_waiting_state() -> void:
    measurement_title.text = "BEREIT"
    measurement_title.add_theme_color_override("font_color", Color("8fa0b4"))
    measurement_values.text = "Wartet auf Messung"
    measurement_values.add_theme_color_override("font_color", Color("e8eef5"))
    measurement_card.add_theme_stylebox_override("panel", _box(Color("0b1724"), Color("203248"), 1, 16))
    _refresh_gesture_visual()


func _show_real_measurement(measurement: Dictionary) -> void:
    var ok := bool(measurement.get("is_ok", false))
    var position := int(measurement.get("switch_position", -1))
    var kind := str(measurement.get("measurement_kind", ""))
    var kind_text := "GERÄT" if kind == "GERAET" else ("LEITUNG" if kind == "LEITUNG" else "MESSUNG")

    measurement_title.text = kind_text + " · " + ("OK" if ok else "NICHT OK")
    measurement_title.add_theme_color_override("font_color", Color("55d6a7") if ok else Color("ff7885"))
    measurement_card.add_theme_stylebox_override(
        "panel",
        _box(Color("0b1724"), Color("55d6a7") if ok else Color("ff7885"), 2, 16)
    )

    var parts: Array[String] = []
    if measurement.get("rpe") != null:
        parts.append("RPE " + _fmt(measurement.get("rpe")) + " Ω")
    if measurement.get("rins") != null:
        parts.append("RISO " + _fmt(measurement.get("rins")) + " MΩ")
    if measurement.get("ipe") != null:
        parts.append("IPE " + _fmt(measurement.get("ipe")) + " mA")
    if measurement.get("u") != null:
        parts.append("U " + _fmt(measurement.get("u")) + " V")

    measurement_values.text = "  ·  ".join(parts)
    measurement_values.add_theme_color_override("font_color", Color("e8eef5"))
    _set_workflow("Drehschalter " + str(position) + " · Angaben ergänzen", Color("8fa0b4"))
    _refresh_gesture_visual()


func _on_field_pressed(index: int) -> void:
    if capture_locked:
        return
    _set_active_field(index, true)


func _set_active_field(index: int, focus_input: bool = false) -> void:
    active_field_index = clampi(index, 0, FIELD_IDS.size() - 1)
    _refresh_capture_ui()
    if focus_input and not capture_locked:
        common_input.grab_focus()
        common_input.caret_column = common_input.text.length()


func _cycle_field() -> void:
    if capture_locked:
        return
    _set_active_field((active_field_index + 1) % FIELD_IDS.size(), true)


func _on_common_input_changed(value: String) -> void:
    if capture_locked:
        return
    field_values[FIELD_IDS[active_field_index]] = value
    _refresh_capture_rows_only()


func _on_common_input_submitted(_value: String) -> void:
    _cycle_field()


func _refresh_capture_rows_only() -> void:
    for i in FIELD_IDS.size():
        var id: String = FIELD_IDS[i]
        var value := str(field_values.get(id, "")).strip_edges()
        field_buttons[i].text = FIELD_NAMES[i] + "\n" + (value if not value.is_empty() else "—")


func _refresh_capture_ui() -> void:
    _refresh_capture_rows_only()

    for i in FIELD_IDS.size():
        var color: Color = FIELD_COLORS[i]
        var active: bool = i == active_field_index and not capture_locked
        var bg: Color = Color("101b28") if not active else color.darkened(0.72)
        var border: Color = color.darkened(0.42) if not active else color
        var width: int = 1 if not active else 3

        field_buttons[i].disabled = capture_locked
        field_buttons[i].add_theme_color_override("font_color", color if not capture_locked else Color("526274"))
        field_buttons[i].add_theme_color_override("font_disabled_color", Color("526274"))
        field_buttons[i].add_theme_stylebox_override("normal", _box(bg, border, width, 13))
        field_buttons[i].add_theme_stylebox_override("hover", _box(color.darkened(0.76), color, 2, 13))
        field_buttons[i].add_theme_stylebox_override("pressed", _box(color.darkened(0.68), color, 3, 13))
        field_buttons[i].add_theme_stylebox_override("disabled", _box(Color("0c1621"), Color("1d2b3a"), 1, 13))

    common_input.editable = not capture_locked
    common_input.mouse_filter = Control.MOUSE_FILTER_STOP if not capture_locked else Control.MOUSE_FILTER_IGNORE

    var active_color: Color = FIELD_COLORS[active_field_index]
    common_input.placeholder_text = "Warte auf Messdaten" if capture_locked else FIELD_NAMES[active_field_index]
    if capture_locked:
        common_input.text = ""
        common_input.add_theme_stylebox_override("normal", _box(Color("c2c9d0"), Color("5d6874"), 2, 14))
        common_input.add_theme_stylebox_override("focus", _box(Color("c2c9d0"), Color("5d6874"), 2, 14))
        common_input.add_theme_stylebox_override("read_only", _box(Color("89939e"), Color("4c5967"), 2, 14))
    else:
        common_input.text = str(field_values.get(FIELD_IDS[active_field_index], ""))
        common_input.add_theme_stylebox_override("normal", _box(Color("eef2f5"), active_color, 3, 14))
        common_input.add_theme_stylebox_override("focus", _box(Color("ffffff"), active_color, 4, 14))
        common_input.add_theme_stylebox_override("read_only", _box(Color("eef2f5"), active_color, 3, 14))


func _set_capture_locked(locked: bool) -> void:
    capture_locked = locked
    if locked:
        common_input.release_focus()
    _refresh_capture_ui()
    _refresh_gesture_visual()


func _clear_capture_values() -> void:
    for id in FIELD_IDS:
        field_values[id] = ""
    active_field_index = 0
    _refresh_capture_ui()


func _refresh_gesture_visual(direction: int = 0, progress: float = 0.0) -> void:
    if gesture_button == null:
        return

    if capture_locked:
        gesture_button.text = "↵\nENTER\n\nWartet"
        gesture_button.add_theme_color_override("font_color", Color("8fa0b4"))
        gesture_button.add_theme_stylebox_override("normal", _box(Color("0d1925"), Color("2a3c50"), 1, 16))
        return

    if direction < 0:
        gesture_button.text = "↑\nVERWERFEN\n" + str(int(progress * 100.0)) + "%"
        gesture_button.add_theme_color_override("font_color", Color("ff7885"))
        gesture_button.add_theme_stylebox_override("normal", _box(Color("27151c"), Color("ff7885"), 3, 16))
    elif direction > 0:
        gesture_button.text = "↓\nSPEICHERN\n" + str(int(progress * 100.0)) + "%"
        gesture_button.add_theme_color_override("font_color", Color("55d6a7"))
        gesture_button.add_theme_stylebox_override("normal", _box(Color("10231f"), Color("55d6a7"), 3, 16))
    else:
        gesture_button.text = "→\nWEITER\n\n↑ Verwerfen\n↓ Speichern"
        gesture_button.add_theme_color_override("font_color", Color("dce6ef"))
        gesture_button.add_theme_stylebox_override("normal", _box(Color("101d2b"), Color("31475e"), 1, 16))


func _on_gesture_input(event: InputEvent) -> void:
    var position := Vector2.ZERO
    var pressed_event := false
    var released_event := false
    var moved_event := false

    if event is InputEventScreenTouch:
        position = event.position
        pressed_event = event.pressed
        released_event = not event.pressed
    elif event is InputEventScreenDrag:
        position = event.position
        moved_event = true
    elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
        position = event.position
        pressed_event = event.pressed
        released_event = not event.pressed
    elif event is InputEventMouseMotion and gesture_pressed and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
        position = event.position
        moved_event = true
    else:
        return

    if pressed_event:
        gesture_pressed = true
        gesture_start_position = position
        gesture_last_position = position
        gesture_press_ms = Time.get_ticks_msec()
        gesture_button.accept_event()
        return

    if moved_event and gesture_pressed:
        gesture_last_position = position
        if capture_locked:
            return

        var elapsed := Time.get_ticks_msec() - gesture_press_ms
        var dy := position.y - gesture_start_position.y
        if elapsed >= 300:
            var threshold := maxf(48.0, gesture_button.size.y * 0.34)
            var progress := clampf(absf(dy) / threshold, 0.0, 1.0)
            if dy < -12.0:
                _refresh_gesture_visual(-1, progress)
            elif dy > 12.0:
                _refresh_gesture_visual(1, progress)
        gesture_button.accept_event()
        return

    if released_event and gesture_pressed:
        gesture_pressed = false
        gesture_last_position = position
        var elapsed := Time.get_ticks_msec() - gesture_press_ms
        var dy := position.y - gesture_start_position.y
        var threshold := maxf(48.0, gesture_button.size.y * 0.34)

        if not capture_locked and elapsed >= 300 and absf(dy) >= threshold:
            if dy < 0.0:
                _discard_current_measurement()
            else:
                _save_current_measurement()
        else:
            if capture_locked:
                _send_enter()
            else:
                _cycle_field()

        _refresh_gesture_visual()
        gesture_button.accept_event()


func _save_current_measurement() -> void:
    if current_measurement.is_empty():
        return

    if not _persist_measurement(current_measurement):
        _set_workflow("Speichern fehlgeschlagen.", Color("ff7885"))
        return

    today_count += 1
    _refresh_today_label()
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
    record["id"] = str(field_values["id"])
    record["geraeteart"] = str(field_values["geraeteart"])
    record["hersteller"] = str(field_values["hersteller"])
    record["saved_at"] = Time.get_datetime_string_from_system()
    record["source"] = "SecuCore Android v0.9"
    file.store_line(JSON.stringify(record))
    file.flush()
    file.close()
    return true


func _begin_post_measurement_action(mode: String) -> void:
    if current_measurement.is_empty():
        return

    post_action_mode = mode
    _set_capture_locked(true)
    _set_workflow(mode + " · SECUTEST wird vorbereitet ...", Color("55d6a7") if mode == "GESPEICHERT" else Color("f0b84b"))

    var switch_position := int(current_measurement.get("switch_position", -1))
    core.reset_post_measurement()
    var action: Dictionary = core.begin_post_measurement_reset(switch_position)
    _send_core_action(action)


func _consume_post_measurement_line(line: String) -> void:
    var result: Dictionary = core.consume_post_measurement_line(line)
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
        _clear_capture_values()
        _set_capture_locked(true)
        core.reset_post_measurement()
        core.arm_measurement_monitor()
        _show_waiting_state()
        _set_workflow(completed_mode + " · bereit für nächste Messung", Color("55d6a7"))
        return

    if bool(result.get("complete", false)):
        _set_workflow(
            post_action_mode + " · Reset fehlgeschlagen: " + str(result.get("message", "unbekannt")),
            Color("ff7885")
        )


func _on_command_timeout() -> void:
    var timed_out := pending_command
    pending_command = ""

    if core == null:
        return

    var post_state := str(core.get_post_measurement_state())
    if post_state in ["WAIT_RESET_ACK", "WAIT_TASA_ACK"]:
        _set_workflow(post_action_mode + " · Timeout bei " + timed_out, Color("ff7885"))
        return

    if timed_out in ["TAS?", "PRX?X", "PRX?Y", "PRX?Z"]:
        _set_workflow("Timeout bei " + timed_out + " · lauscht wieder", Color("f0b84b"))
        core.arm_measurement_monitor()
        _show_waiting_state()
        return

    _set_workflow("Timeout bei " + timed_out + " · neu verbinden", Color("ff7885"))
    core.reset_live_init()
    core.reset_measurement_flow()


func _set_connection_visual(text_value: String, color: Color) -> void:
    if connection_button == null:
        return
    connection_button.text = "● " + text_value
    connection_button.add_theme_color_override("font_color", color)


func _set_workflow(text_value: String, color: Color) -> void:
    if workflow_label == null:
        return
    workflow_label.text = text_value
    workflow_label.add_theme_color_override("font_color", color)


func _fmt(value) -> String:
    if value == null:
        return "—"
    return str(value)


func _load_today_count() -> void:
    today_count = 0
    var path := "user://secudata_measurements.jsonl"
    if not FileAccess.file_exists(path):
        _refresh_today_label()
        return

    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        _refresh_today_label()
        return

    var today := Time.get_date_string_from_system()
    while not file.eof_reached():
        var line := file.get_line().strip_edges()
        if line.is_empty():
            continue
        var parsed = JSON.parse_string(line)
        if parsed is Dictionary and str(parsed.get("saved_at", "")).begins_with(today):
            today_count += 1
    file.close()
    _refresh_today_label()


func _refresh_today_label() -> void:
    if today_label != null:
        today_label.text = "Heute " + str(today_count)


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
        _set_capture_locked(true)
        _show_waiting_state()
        _set_connection_visual("BLE", Color("8fa0b4"))
        _set_workflow("App aktiv · BLE bei Bedarf neu verbinden.", Color("64788e"))
