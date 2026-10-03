extends Control

const FIELD_IDS: Array[String] = ["id", "geraeteart", "hersteller"]
const FIELD_NAMES: Array[String] = ["ID", "GERÄTEART", "HERSTELLER"]
const ID_COLOR := Color("28b9e6")
const DEVICE_COLOR := Color("d5aa3f")
const MANUFACTURER_COLOR := Color("9b70cf")
const OK_COLOR := Color("79c94b")
const NOK_COLOR := Color("e05252")
const NEUTRAL_BORDER := Color("314152")

const FIELD_COLORS: Array[Color] = [
    ID_COLOR,
    DEVICE_COLOR,
    MANUFACTURER_COLOR,
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
var syncing_common_input := false

var gesture_pressed := false
var gesture_start_position := Vector2.ZERO
var gesture_last_position := Vector2.ZERO
var gesture_press_ms := 0

var today_count := 0
var week_count := 0
var total_count := 0
var current_room := ""
var database_ready := false
var last_database_error := ""

var main_root: VBoxContainer
var capture_row: HBoxContainer
var connection_button: Button
var room_label: Button
var today_label: Button
var measurement_card: PanelContainer
var measurement_header: PanelContainer
var measurement_fade: PanelContainer
var measurement_body: PanelContainer
var measurement_title: Label
var measurement_values: Label
var workflow_label: Label
var field_buttons: Array[Button] = []
var gesture_button: Button
var common_input: LineEdit
var suggestion_panel: PanelContainer
var suggestion_hint: Label
var suggestion_grid: GridContainer
var suggestion_press_ms: Dictionary = {}
var suggestion_long_press_handled: Dictionary = {}
var command_timer: Timer

var data_overlay: PanelContainer
var data_list: VBoxContainer
var data_counts_label: Label
var room_dialog: AcceptDialog
var room_input: LineEdit
var delete_dialog: ConfirmationDialog
var pending_delete_record_id := -1
var edit_dialog: AcceptDialog
var edit_id_input: LineEdit
var edit_device_input: LineEdit
var edit_manufacturer_input: LineEdit
var edit_room_input: LineEdit
var editing_record_id := -1
var editing_record_snapshot: Dictionary = {}
var edit_previous_room := ""


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

    main_root = VBoxContainer.new()
    main_root.add_theme_constant_override("separation", 10)
    margin.add_child(main_root)

    # --- Compact status bar -------------------------------------------------
    var topbar := HBoxContainer.new()
    topbar.custom_minimum_size.y = 58
    topbar.add_theme_constant_override("separation", 10)
    main_root.add_child(topbar)

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
    today_label.add_theme_stylebox_override("pressed", _box(Color("17212c"), OK_COLOR, 2, 12))
    today_label.pressed.connect(_open_data_view)
    topbar.add_child(today_label)

    connection_button = Button.new()
    connection_button.text = "● BLE"
    connection_button.custom_minimum_size = Vector2(96, 46)
    connection_button.add_theme_font_size_override("font_size", 16)
    connection_button.add_theme_color_override("font_color", Color("8fa0b4"))
    connection_button.add_theme_stylebox_override("normal", _box(Color("0c1724"), Color("26384c"), 1, 13))
    connection_button.add_theme_stylebox_override("hover", _box(Color("111f2e"), Color("3b526a"), 1, 13))
    connection_button.add_theme_stylebox_override("pressed", _box(Color("142437"), OK_COLOR, 2, 13))
    connection_button.pressed.connect(_connect_ble)
    topbar.add_child(connection_button)

    # --- Measurement instrument card ---------------------------------------
    # The outer border itself carries the result colour at the top and fades
    # back to the neutral border just below the header.
    measurement_card = PanelContainer.new()
    measurement_card.add_theme_stylebox_override("panel", _box(Color("0b1724"), Color("0b1724"), 0, 16))
    main_root.add_child(measurement_card)

    var measurement_shell := VBoxContainer.new()
    measurement_shell.add_theme_constant_override("separation", 0)
    measurement_card.add_child(measurement_shell)

    measurement_header = PanelContainer.new()
    measurement_header.add_theme_stylebox_override("panel", _result_header_box(Color("111d29"), NEUTRAL_BORDER, 1))
    measurement_shell.add_child(measurement_header)

    var header_margin := MarginContainer.new()
    header_margin.add_theme_constant_override("margin_left", 14)
    header_margin.add_theme_constant_override("margin_right", 14)
    header_margin.add_theme_constant_override("margin_top", 9)
    header_margin.add_theme_constant_override("margin_bottom", 8)
    measurement_header.add_child(header_margin)

    measurement_title = Label.new()
    measurement_title.text = "BEREIT"
    measurement_title.add_theme_font_size_override("font_size", 21)
    measurement_title.add_theme_color_override("font_color", Color("9fb1c4"))
    header_margin.add_child(measurement_title)

    measurement_fade = PanelContainer.new()
    measurement_fade.custom_minimum_size.y = 7
    measurement_fade.add_theme_stylebox_override("panel", _result_fade_box(NEUTRAL_BORDER))
    measurement_shell.add_child(measurement_fade)

    measurement_body = PanelContainer.new()
    measurement_body.add_theme_stylebox_override("panel", _result_body_box(Color("0b1724")))
    measurement_shell.add_child(measurement_body)

    var measurement_margin := MarginContainer.new()
    measurement_margin.add_theme_constant_override("margin_left", 14)
    measurement_margin.add_theme_constant_override("margin_right", 14)
    measurement_margin.add_theme_constant_override("margin_top", 8)
    measurement_margin.add_theme_constant_override("margin_bottom", 12)
    measurement_body.add_child(measurement_margin)

    var measurement_box := VBoxContainer.new()
    measurement_box.add_theme_constant_override("separation", 5)
    measurement_margin.add_child(measurement_box)

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
    capture_row = HBoxContainer.new()
    capture_row.custom_minimum_size.y = 240
    capture_row.add_theme_constant_override("separation", 9)
    main_root.add_child(capture_row)

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
    gesture_button.add_theme_stylebox_override("pressed", _box(Color("16283a"), OK_COLOR, 2, 16))
    gesture_button.gui_input.connect(_on_gesture_input)
    capture_row.add_child(gesture_button)

    # --- One shared input, exactly below the three fields -------------------
    common_input = LineEdit.new()
    common_input.custom_minimum_size.y = 96
    common_input.add_theme_font_size_override("font_size", 34)
    common_input.add_theme_color_override("font_color", Color("111820"))
    common_input.add_theme_color_override("font_placeholder_color", Color("6f7b87"))
    common_input.clear_button_enabled = true
    common_input.text_changed.connect(_on_common_input_changed)
    common_input.text_submitted.connect(_on_common_input_submitted)
    main_root.add_child(common_input)

    # --- Two-row suggestion area: shared by live capture and record editing ---
    suggestion_panel = PanelContainer.new()
    suggestion_panel.custom_minimum_size.y = 128
    suggestion_panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
    suggestion_panel.add_theme_stylebox_override("panel", _box(Color("09131e"), Color("18283a"), 1, 14))
    main_root.add_child(suggestion_panel)

    var suggestion_margin := MarginContainer.new()
    suggestion_margin.add_theme_constant_override("margin_left", 8)
    suggestion_margin.add_theme_constant_override("margin_right", 8)
    suggestion_margin.add_theme_constant_override("margin_top", 7)
    suggestion_margin.add_theme_constant_override("margin_bottom", 7)
    suggestion_panel.add_child(suggestion_margin)

    var suggestion_box := VBoxContainer.new()
    suggestion_box.add_theme_constant_override("separation", 5)
    suggestion_margin.add_child(suggestion_box)

    suggestion_hint = Label.new()
    suggestion_hint.text = "Tippen: übernehmen  ·  halten: ausblenden"
    suggestion_hint.add_theme_font_size_override("font_size", 12)
    suggestion_hint.add_theme_color_override("font_color", Color("54687d"))
    suggestion_box.add_child(suggestion_hint)

    suggestion_grid = GridContainer.new()
    suggestion_grid.columns = 3
    suggestion_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    suggestion_grid.add_theme_constant_override("h_separation", 6)
    suggestion_grid.add_theme_constant_override("v_separation", 6)
    suggestion_box.add_child(suggestion_grid)

    _refresh_capture_ui()
    _refresh_gesture_visual()
    _build_room_dialog()
    _build_delete_dialog()
    _build_data_overlay()


func _build_room_dialog() -> void:
    room_dialog = AcceptDialog.new()
    room_dialog.title = "Raum"
    room_dialog.min_size = Vector2i(430, 220)
    room_dialog.confirmed.connect(_save_room_from_dialog)
    add_child(room_dialog)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 18)
    margin.add_theme_constant_override("margin_right", 18)
    margin.add_theme_constant_override("margin_top", 14)
    margin.add_theme_constant_override("margin_bottom", 14)
    room_dialog.add_child(margin)

    var box := VBoxContainer.new()
    box.add_theme_constant_override("separation", 12)
    margin.add_child(box)

    var label := Label.new()
    label.text = "Raum / Bereich"
    label.add_theme_font_size_override("font_size", 20)
    box.add_child(label)

    room_input = LineEdit.new()
    room_input.custom_minimum_size.y = 66
    room_input.add_theme_font_size_override("font_size", 24)
    room_input.placeholder_text = "z. B. 204"
    box.add_child(room_input)


func _open_room_dialog() -> void:
    if room_dialog == null:
        return
    room_input.text = current_room
    room_dialog.popup_centered()
    room_input.grab_focus()
    room_input.caret_column = room_input.text.length()


func _save_room_from_dialog() -> void:
    current_room = room_input.text.strip_edges()
    _refresh_room_label()
    if ble != null and database_ready:
        ble.databaseSetSetting("current_room", current_room)


func _build_delete_dialog() -> void:
    delete_dialog = ConfirmationDialog.new()
    delete_dialog.title = "Datensatz löschen"
    delete_dialog.dialog_text = "Diesen Datensatz wirklich löschen?"
    delete_dialog.confirmed.connect(_delete_pending_record)
    add_child(delete_dialog)


func _open_edit_record(record: Dictionary) -> void:
    editing_record_id = int(record.get("database_id", -1))
    if editing_record_id < 0:
        return

    editing_record_snapshot = record.duplicate(true)
    edit_previous_room = current_room
    current_room = str(record.get("raum_etage", ""))
    _refresh_room_label()

    field_values["id"] = str(record.get("external_id", ""))
    field_values["geraeteart"] = str(record.get("geraeteart", ""))
    field_values["hersteller"] = str(record.get("hersteller", ""))

    # Reuse the exact live-capture controls. This means suggestions, field
    # colours and the gesture button automatically behave identically here.
    current_measurement = record.duplicate(true)
    _set_capture_locked(false)
    _set_active_field(0, false)

    var result_color: Color = OK_COLOR if bool(record.get("is_ok", true)) else NOK_COLOR
    measurement_title.text = "DATENSATZ #" + str(editing_record_id) + " BEARBEITEN"
    measurement_title.add_theme_color_override("font_color", result_color)
    measurement_header.add_theme_stylebox_override("panel", _result_header_box(Color("111d29"), result_color, 2))
    measurement_fade.add_theme_stylebox_override("panel", _result_fade_box(result_color))
    measurement_body.add_theme_stylebox_override("panel", _result_body_box(Color("0b1724")))
    measurement_values.text = _measurement_mode_text(record) + "  ·  " + _record_measurement_summary(record)
    measurement_values.add_theme_color_override("font_color", Color("eef2f6"))
    _set_workflow("Änderungen mit ↓ übernehmen · ↑ abbrechen", Color("8fa0b4"))
    _refresh_gesture_visual()

    common_input.release_focus()
    DisplayServer.virtual_keyboard_hide()

    if data_overlay != null:
        var tween := create_tween()
        tween.set_parallel(true)
        tween.tween_property(data_overlay, "modulate:a", 0.0, 0.10).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
        tween.tween_property(main_root, "modulate:a", 1.0, 0.12)
        tween.chain().tween_callback(func():
            data_overlay.visible = false
            data_overlay.modulate.a = 1.0
            _animate_capture_in()
        )


func _animate_capture_in() -> void:
    capture_row.modulate.a = 0.0
    common_input.modulate.a = 0.0
    suggestion_panel.modulate.a = 0.0
    capture_row.scale = Vector2(0.985, 0.985)
    common_input.scale = Vector2(0.985, 0.985)
    suggestion_panel.scale = Vector2(0.985, 0.985)

    var tween := create_tween()
    tween.set_parallel(true)
    tween.tween_property(capture_row, "modulate:a", 1.0, 0.14)
    tween.tween_property(common_input, "modulate:a", 1.0, 0.14)
    tween.tween_property(suggestion_panel, "modulate:a", 1.0, 0.14)
    tween.tween_property(capture_row, "scale", Vector2.ONE, 0.14).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
    tween.tween_property(common_input, "scale", Vector2.ONE, 0.14).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
    tween.tween_property(suggestion_panel, "scale", Vector2.ONE, 0.14).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
    tween.chain().tween_callback(func():
        _set_active_field(0, true)
    )


func _save_edited_capture_record() -> void:
    if editing_record_id < 0 or ble == null or not database_ready:
        return

    if common_input.has_ime_text():
        common_input.apply_ime()
    field_values[FIELD_IDS[active_field_index]] = common_input.text

    var ok := bool(ble.databaseUpdateRecord(
        editing_record_id,
        str(field_values["id"]).strip_edges(),
        str(field_values["geraeteart"]).strip_edges(),
        str(field_values["hersteller"]).strip_edges(),
        current_room.strip_edges()
    ))

    if not ok:
        _set_workflow("Datensatz konnte nicht geändert werden.", NOK_COLOR)
        return

    ble.databaseObserveVocabulary(
        str(field_values["geraeteart"]).strip_edges(),
        str(field_values["hersteller"]).strip_edges()
    )
    _finish_capture_edit(true)


func _finish_capture_edit(saved: bool) -> void:
    common_input.release_focus()
    DisplayServer.virtual_keyboard_hide()

    current_room = edit_previous_room
    _refresh_room_label()
    editing_record_id = -1
    editing_record_snapshot = {}
    edit_previous_room = ""
    current_measurement = {}
    _clear_capture_values()
    _set_capture_locked(true)
    _show_waiting_state()

    _refresh_data_view()
    if data_overlay != null:
        data_overlay.visible = true
        data_overlay.modulate.a = 0.0
        var tween := create_tween()
        tween.tween_property(data_overlay, "modulate:a", 1.0, 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

    if saved:
        _set_workflow("Datensatz geändert.", OK_COLOR)


func _build_data_overlay() -> void:
    data_overlay = PanelContainer.new()
    data_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    data_overlay.visible = false
    data_overlay.z_index = 100
    data_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
    data_overlay.add_theme_stylebox_override("panel", _box(Color("07111c"), Color("07111c"), 0, 0))
    add_child(data_overlay)

    var outer := MarginContainer.new()
    outer.add_theme_constant_override("margin_left", 14)
    outer.add_theme_constant_override("margin_right", 14)
    outer.add_theme_constant_override("margin_top", 18)
    outer.add_theme_constant_override("margin_bottom", 12)
    data_overlay.add_child(outer)

    var root := VBoxContainer.new()
    root.add_theme_constant_override("separation", 10)
    outer.add_child(root)

    var header := HBoxContainer.new()
    header.custom_minimum_size.y = 58
    header.add_theme_constant_override("separation", 10)
    root.add_child(header)

    var back := Button.new()
    back.text = "‹"
    back.custom_minimum_size = Vector2(58, 52)
    back.add_theme_font_size_override("font_size", 32)
    back.add_theme_stylebox_override("normal", _box(Color("111c28"), Color("26394c"), 1, 14))
    back.pressed.connect(_close_data_view)
    header.add_child(back)

    var title := Label.new()
    title.text = "DATEN"
    title.add_theme_font_size_override("font_size", 30)
    title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    header.add_child(title)

    data_counts_label = Label.new()
    data_counts_label.text = "Heute 0 · Woche 0 · Gesamt 0"
    data_counts_label.add_theme_font_size_override("font_size", 15)
    data_counts_label.add_theme_color_override("font_color", Color("b9c3ce"))
    data_counts_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    data_counts_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    header.add_child(data_counts_label)

    var rule := HSeparator.new()
    root.add_child(rule)

    var scroll := ScrollContainer.new()
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    root.add_child(scroll)

    data_list = VBoxContainer.new()
    data_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    data_list.add_theme_constant_override("separation", 9)
    scroll.add_child(data_list)


func _open_data_view() -> void:
    if data_overlay == null:
        return
    if not current_measurement.is_empty() and editing_record_id < 0:
        _set_workflow("Aktuelle Messung zuerst speichern oder verwerfen.", Color("f0b84b"))
        return

    common_input.release_focus()
    DisplayServer.virtual_keyboard_hide()
    if core != null:
        core.reset_measurement_flow()
    _refresh_data_view()
    data_overlay.visible = true
    data_overlay.modulate.a = 1.0


func _close_data_view() -> void:
    if data_overlay != null:
        data_overlay.visible = false
    if core != null and ble != null and str(ble.getConnectionState()) == "READY":
        core.arm_measurement_monitor()
        _show_waiting_state()
        _set_workflow("Verbunden · wartet auf PRX", OK_COLOR)


func _refresh_data_view() -> void:
    if data_list == null:
        return

    for child in data_list.get_children():
        data_list.remove_child(child)
        child.queue_free()

    _refresh_database_counts()

    if ble == null or not database_ready:
        var unavailable := Label.new()
        unavailable.text = "Datenbank ist auf diesem Build nicht verfügbar."
        unavailable.add_theme_font_size_override("font_size", 20)
        data_list.add_child(unavailable)
        return

    var parsed = JSON.parse_string(str(ble.databaseListRecords(600)))
    if not (parsed is Array):
        return

    var records: Array = parsed
    if records.is_empty():
        var empty := Label.new()
        empty.text = "Noch keine gespeicherten Messungen."
        empty.add_theme_font_size_override("font_size", 21)
        empty.add_theme_color_override("font_color", Color("7f91a3"))
        empty.custom_minimum_size.y = 100
        empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
        empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        data_list.add_child(empty)
        return

    var last_group := ""
    for item in records:
        if not (item is Dictionary):
            continue
        var record: Dictionary = item
        var date_text := _record_date(record)
        var room_text := str(record.get("raum_etage", "")).strip_edges()
        var group_key := date_text + "|" + room_text

        if group_key != last_group:
            _add_data_group_header(date_text, room_text)
            last_group = group_key

        _add_data_record_card(record)


func _add_data_group_header(date_text: String, room_text: String) -> void:
    var header := PanelContainer.new()
    header.add_theme_stylebox_override("panel", _box(Color("101b27"), Color("25384c"), 1, 12))
    data_list.add_child(header)

    var row := HBoxContainer.new()
    row.custom_minimum_size.y = 48
    row.add_theme_constant_override("separation", 10)
    header.add_child(row)

    var date_label := Label.new()
    date_label.text = date_text if not date_text.is_empty() else "Ohne Datum"
    date_label.add_theme_font_size_override("font_size", 19)
    date_label.add_theme_color_override("font_color", Color("e4e9ef"))
    date_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    date_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    row.add_child(date_label)

    var room := Label.new()
    room.text = "Raum " + (room_text if not room_text.is_empty() else "—")
    room.add_theme_font_size_override("font_size", 18)
    room.add_theme_color_override("font_color", Color("a98be8"))
    room.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    row.add_child(room)


func _add_data_record_card(record: Dictionary) -> void:
    var ok := bool(record.get("is_ok", true))
    var result_color: Color = OK_COLOR if ok else NOK_COLOR

    var card := PanelContainer.new()
    card.add_theme_stylebox_override("panel", _box(Color("0d1824"), Color("0d1824"), 0, 14))
    data_list.add_child(card)

    var shell := VBoxContainer.new()
    shell.add_theme_constant_override("separation", 0)
    card.add_child(shell)

    # Topbar: only # + time on the left, OK/N-OK on the right.
    var topbar := PanelContainer.new()
    topbar.add_theme_stylebox_override("panel", _result_header_box(Color("111d29"), result_color, 2))
    shell.add_child(topbar)

    var top_margin := MarginContainer.new()
    top_margin.add_theme_constant_override("margin_left", 12)
    top_margin.add_theme_constant_override("margin_right", 12)
    top_margin.add_theme_constant_override("margin_top", 8)
    top_margin.add_theme_constant_override("margin_bottom", 7)
    topbar.add_child(top_margin)

    var top := HBoxContainer.new()
    top.custom_minimum_size.y = 42
    top_margin.add_child(top)

    var number_time := Label.new()
    number_time.text = "#" + str(int(record.get("database_id", -1))) + "  " + _record_time(record)
    number_time.add_theme_font_size_override("font_size", 21)
    number_time.add_theme_color_override("font_color", Color("c5ced7"))
    number_time.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    number_time.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    top.add_child(number_time)

    var result := Label.new()
    result.text = "OK" if ok else "N-OK"
    result.add_theme_font_size_override("font_size", 21)
    result.add_theme_color_override("font_color", result_color)
    result.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    top.add_child(result)

    var fade := PanelContainer.new()
    fade.custom_minimum_size.y = 7
    fade.add_theme_stylebox_override("panel", _result_fade_box(result_color))
    shell.add_child(fade)

    var body := PanelContainer.new()
    body.add_theme_stylebox_override("panel", _result_body_box(Color("0d1824")))
    shell.add_child(body)

    var body_margin := MarginContainer.new()
    body_margin.add_theme_constant_override("margin_left", 12)
    body_margin.add_theme_constant_override("margin_right", 12)
    body_margin.add_theme_constant_override("margin_top", 8)
    body_margin.add_theme_constant_override("margin_bottom", 9)
    body.add_child(body_margin)

    var box := VBoxContainer.new()
    box.add_theme_constant_override("separation", 7)
    body_margin.add_child(box)

    # Middle row, line 1: mode left, ID right.
    var meta_top := HBoxContainer.new()
    meta_top.custom_minimum_size.y = 34
    meta_top.add_theme_constant_override("separation", 10)
    box.add_child(meta_top)

    var mode := Label.new()
    mode.text = _measurement_mode_text(record)
    mode.add_theme_font_size_override("font_size", 21)
    mode.add_theme_color_override("font_color", Color("eef2f6"))
    mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    mode.text_overrun_behavior = TextServer.OVERRUN_TRIM_WORD_ELLIPSIS
    meta_top.add_child(mode)

    var ident := Label.new()
    ident.text = str(record.get("external_id", "")).strip_edges()
    if ident.text.is_empty():
        ident.text = "ID —"
    ident.custom_minimum_size.x = 150
    ident.add_theme_font_size_override("font_size", 22)
    ident.add_theme_color_override("font_color", ID_COLOR)
    ident.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    ident.text_overrun_behavior = TextServer.OVERRUN_TRIM_WORD_ELLIPSIS
    meta_top.add_child(ident)

    # Middle row, line 2: device type left, manufacturer right.
    var meta_bottom := HBoxContainer.new()
    meta_bottom.custom_minimum_size.y = 34
    meta_bottom.add_theme_constant_override("separation", 10)
    box.add_child(meta_bottom)

    var device := Label.new()
    device.text = str(record.get("geraeteart", "")).strip_edges()
    if device.text.is_empty():
        device.text = "Geräteart —"
    device.add_theme_font_size_override("font_size", 21)
    device.add_theme_color_override("font_color", DEVICE_COLOR)
    device.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    device.text_overrun_behavior = TextServer.OVERRUN_TRIM_WORD_ELLIPSIS
    meta_bottom.add_child(device)

    var manufacturer := Label.new()
    manufacturer.text = str(record.get("hersteller", "")).strip_edges()
    if manufacturer.text.is_empty():
        manufacturer.text = "Hersteller —"
    manufacturer.custom_minimum_size.x = 170
    manufacturer.add_theme_font_size_override("font_size", 21)
    manufacturer.add_theme_color_override("font_color", MANUFACTURER_COLOR)
    manufacturer.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    manufacturer.text_overrun_behavior = TextServer.OVERRUN_TRIM_WORD_ELLIPSIS
    meta_bottom.add_child(manufacturer)

    var action_row := HBoxContainer.new()
    action_row.add_theme_constant_override("separation", 7)
    box.add_child(action_row)

    var details_button := Button.new()
    details_button.text = "Daten ▼"
    details_button.custom_minimum_size.y = 50
    details_button.add_theme_font_size_override("font_size", 19)
    details_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    details_button.add_theme_stylebox_override("normal", _box(Color("101b27"), Color("243546"), 1, 10))
    action_row.add_child(details_button)

    var edit_button := Button.new()
    edit_button.text = "✎"
    edit_button.custom_minimum_size = Vector2(58, 50)
    edit_button.add_theme_font_size_override("font_size", 24)
    edit_button.add_theme_color_override("font_color", Color("e6edf4"))
    edit_button.add_theme_stylebox_override("normal", _box(Color("101b27"), Color("243546"), 1, 10))
    edit_button.pressed.connect(_open_edit_record.bind(record))
    action_row.add_child(edit_button)

    var delete_button := Button.new()
    delete_button.text = "×"
    delete_button.custom_minimum_size = Vector2(58, 50)
    delete_button.add_theme_font_size_override("font_size", 26)
    delete_button.add_theme_color_override("font_color", NOK_COLOR)
    delete_button.add_theme_stylebox_override("normal", _box(Color("101b27"), Color("243546"), 1, 10))
    delete_button.pressed.connect(_ask_delete_record.bind(int(record.get("database_id", -1))))
    action_row.add_child(delete_button)

    var details_box := VBoxContainer.new()
    details_box.visible = false
    details_box.add_theme_constant_override("separation", 8)
    box.add_child(details_box)

    _add_measurement_table(record, details_box)

    var stamp := Label.new()
    stamp.text = "Messzeit: " + str(record.get("measurement_timestamp", "—"))
    stamp.add_theme_font_size_override("font_size", 15)
    stamp.add_theme_color_override("font_color", Color("75879a"))
    details_box.add_child(stamp)

    details_button.pressed.connect(_toggle_record_details.bind(details_box, details_button))


func _toggle_record_details(details_box: VBoxContainer, button: Button) -> void:
    details_box.visible = not details_box.visible
    button.text = "Daten ▲" if details_box.visible else "Daten ▼"


func _ask_delete_record(record_id: int) -> void:
    if record_id < 0 or delete_dialog == null:
        return
    pending_delete_record_id = record_id
    delete_dialog.popup_centered()


func _delete_pending_record() -> void:
    if pending_delete_record_id < 0:
        return
    if ble != null and database_ready:
        ble.databaseDeleteRecord(pending_delete_record_id)
    pending_delete_record_id = -1
    _refresh_data_view()


func _record_date(record: Dictionary) -> String:
    var created := str(record.get("created_at", ""))
    if created.length() < 10:
        return created

    var parsed := Time.get_datetime_dict_from_datetime_string(created, false)
    var day := int(parsed.get("day", 0))
    var month := int(parsed.get("month", 0))
    var year := int(parsed.get("year", 0))
    var weekday := int(parsed.get("weekday", -1))
    var weekday_names := ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"]
    var prefix := ""
    if weekday >= 0 and weekday < weekday_names.size():
        prefix = weekday_names[weekday] + ", "
    return prefix + ("%02d.%02d.%04d" % [day, month, year])


func _record_time(record: Dictionary) -> String:
    var created := str(record.get("created_at", ""))
    if created.length() >= 16:
        return created.substr(11, 5)
    return ""


func _measurement_mode_text(record: Dictionary) -> String:
    var kind := str(record.get("measurement_kind", ""))
    var kind_text := "GERÄT" if kind == "GERAET" else ("LEITUNG" if kind == "LEITUNG" else "MESSUNG")

    if kind in ["GERAET", "LEITUNG"]:
        var protection := "SK I" if record.get("rpe") != null else "SK II"
        return "PASSIV - " + kind_text + " - " + protection

    return "PASSIV - " + kind_text


func _record_middle_text(record: Dictionary) -> String:
    return _measurement_mode_text(record)


func _record_measurement_summary(record: Dictionary) -> String:
    var parts: Array[String] = []
    if record.get("rpe") != null:
        parts.append("RPE " + _fmt(record.get("rpe")) + " Ω")
    if record.get("rins") != null:
        parts.append("RISO " + _fmt(record.get("rins")) + " MΩ")
    if record.get("ipe") != null:
        parts.append("IPE " + _fmt(record.get("ipe")) + " mA")
    if record.get("u") != null:
        parts.append("U " + _fmt(record.get("u")) + " V")
    return " · ".join(parts) if not parts.is_empty() else "Keine Messwerte"


func _record_measurement_text(record: Dictionary) -> String:
    var parts: Array[String] = []
    if record.get("rpe") != null:
        parts.append("RPE  " + _fmt(record.get("rpe")) + " Ω")
    if record.get("rins") != null:
        parts.append("RISO  " + _fmt(record.get("rins")) + " MΩ")
    if record.get("uiso") != null:
        parts.append("UISO  " + _fmt(record.get("uiso")) + " V")
    if record.get("ipe") != null:
        parts.append("IPE  " + _fmt(record.get("ipe")) + " mA")
    if record.get("u") != null:
        parts.append("U  " + _fmt(record.get("u")) + " V")
    return "\n".join(parts) if not parts.is_empty() else "Keine Messwerte"


func _add_measurement_table(record: Dictionary, parent: VBoxContainer) -> void:
    var table_panel := PanelContainer.new()
    table_panel.add_theme_stylebox_override("panel", _box(Color("0a141f"), Color("26384a"), 1, 10))
    parent.add_child(table_panel)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 10)
    margin.add_theme_constant_override("margin_right", 10)
    margin.add_theme_constant_override("margin_top", 8)
    margin.add_theme_constant_override("margin_bottom", 8)
    table_panel.add_child(margin)

    var grid := GridContainer.new()
    grid.columns = 4
    grid.add_theme_constant_override("h_separation", 12)
    grid.add_theme_constant_override("v_separation", 6)
    margin.add_child(grid)

    _add_table_cell(grid, "Messung", HORIZONTAL_ALIGNMENT_LEFT, Color("8fa0b4"), 15)
    _add_table_cell(grid, "Wert", HORIZONTAL_ALIGNMENT_RIGHT, Color("8fa0b4"), 15)
    _add_table_cell(grid, "GW", HORIZONTAL_ALIGNMENT_RIGHT, Color("8fa0b4"), 15)
    _add_table_cell(grid, "", HORIZONTAL_ALIGNMENT_RIGHT, Color("8fa0b4"), 15)

    _append_measurement_row(grid, record, "RPE", "rpe", "rpe_limit", "Ω", true)
    _append_measurement_row(grid, record, "ΔRPE", "drpe", "drpe_limit", "Ω", true)
    _append_measurement_row(grid, record, "RISO", "rins", "rins_limit", "MΩ", false)
    _append_measurement_row(grid, record, "UISO", "uiso", "uiso_limit", "V", false)
    _append_measurement_row(grid, record, "IPE", "ipe", "ipe_limit", "mA", true)
    _append_measurement_row(grid, record, "U", "u", "u_limit", "V", true)


func _append_measurement_row(
    grid: GridContainer,
    record: Dictionary,
    label_text: String,
    value_key: String,
    limit_key: String,
    unit: String,
    lower_is_better: bool
) -> void:
    if record.get(value_key) == null:
        return

    var value := float(record.get(value_key, 0.0))
    var has_limit := record.get(limit_key) != null
    var limit := float(record.get(limit_key, 0.0)) if has_limit else 0.0
    var status_text := "—"
    var status_color := Color("75879a")

    if has_limit:
        var row_ok := value <= limit if lower_is_better else value >= limit
        status_text = "OK" if row_ok else "N-OK"
        status_color = OK_COLOR if row_ok else NOK_COLOR

    _add_table_cell(grid, label_text, HORIZONTAL_ALIGNMENT_LEFT, Color("d7e0e8"), 17)
    _add_table_cell(grid, _fmt(value) + " " + unit, HORIZONTAL_ALIGNMENT_RIGHT, Color("eef2f6"), 17)
    _add_table_cell(grid, (_fmt(limit) + " " + unit) if has_limit else "—", HORIZONTAL_ALIGNMENT_RIGHT, Color("aab7c4"), 17)
    _add_table_cell(grid, status_text, HORIZONTAL_ALIGNMENT_RIGHT, status_color, 16)


func _add_table_cell(
    grid: GridContainer,
    text_value: String,
    alignment: HorizontalAlignment,
    color: Color,
    font_size: int
) -> void:
    var label := Label.new()
    label.text = text_value
    label.add_theme_font_size_override("font_size", font_size)
    label.add_theme_color_override("font_color", color)
    label.horizontal_alignment = alignment
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    grid.add_child(label)


func _result_header_box(bg: Color, accent: Color, width: int = 2) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = bg.lerp(accent, 0.06)
    style.border_color = accent
    style.border_width_left = width
    style.border_width_top = width
    style.border_width_right = width
    style.border_width_bottom = 0
    style.corner_radius_top_left = 13
    style.corner_radius_top_right = 13
    style.corner_radius_bottom_left = 0
    style.corner_radius_bottom_right = 0
    style.shadow_color = Color(accent.r, accent.g, accent.b, 0.12)
    style.shadow_size = 4
    style.shadow_offset = Vector2(0, 2)
    style.content_margin_left = 0
    style.content_margin_right = 0
    style.content_margin_top = 0
    style.content_margin_bottom = 0
    return style


func _result_fade_box(accent: Color) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = Color("0d1824")
    style.border_color = accent.lerp(NEUTRAL_BORDER, 0.58)
    style.border_width_left = 2
    style.border_width_right = 2
    style.border_width_top = 0
    style.border_width_bottom = 0
    return style


func _result_body_box(bg: Color) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = bg
    style.border_color = NEUTRAL_BORDER
    style.border_width_left = 1
    style.border_width_right = 1
    style.border_width_bottom = 1
    style.border_width_top = 0
    style.corner_radius_bottom_left = 13
    style.corner_radius_bottom_right = 13
    return style


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
            _set_connection_visual("BLE", OK_COLOR)
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
        _set_workflow("ENTER an SECUTEST gesendet.", OK_COLOR)
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
        _set_connection_visual("BLE", OK_COLOR)
        _show_waiting_state()
        _set_workflow("Verbunden · wartet auf PRX", OK_COLOR)
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
    measurement_title.add_theme_color_override("font_color", Color("9aaabd"))
    measurement_values.text = "Wartet auf Messung"
    measurement_values.add_theme_color_override("font_color", Color("e8eef5"))
    measurement_header.add_theme_stylebox_override("panel", _result_header_box(Color("111d29"), NEUTRAL_BORDER, 1))
    measurement_fade.add_theme_stylebox_override("panel", _result_fade_box(NEUTRAL_BORDER))
    measurement_body.add_theme_stylebox_override("panel", _result_body_box(Color("0b1724")))
    _refresh_gesture_visual()


func _show_real_measurement(measurement: Dictionary) -> void:
    var ok := bool(measurement.get("is_ok", false))
    var position := int(measurement.get("switch_position", -1))
    var result_color: Color = OK_COLOR if ok else NOK_COLOR

    measurement_title.text = _measurement_mode_text(measurement) + "    " + ("OK" if ok else "NICHT OK")
    measurement_title.add_theme_color_override("font_color", result_color)
    measurement_header.add_theme_stylebox_override("panel", _result_header_box(Color("111d29"), result_color, 2))
    measurement_fade.add_theme_stylebox_override("panel", _result_fade_box(result_color))
    measurement_body.add_theme_stylebox_override("panel", _result_body_box(Color("0b1724")))

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
    measurement_values.add_theme_color_override("font_color", Color("eef2f6"))
    _set_workflow("Drehschalter " + str(position) + " · Angaben ergänzen", Color("8fa0b4"))
    _refresh_gesture_visual()


func _on_field_pressed(index: int) -> void:
    if capture_locked:
        return
    _set_active_field(index, true)


func _set_active_field(index: int, focus_input: bool = false) -> void:
    if common_input != null and not capture_locked:
        # SwiftKey/Android can keep an IME composition tied to the previous field.
        # Commit it before switching, then rebuild the shared input from the new
        # field so the first typed character cannot drag the old value across.
        if common_input.has_ime_text():
            common_input.apply_ime()
        field_values[FIELD_IDS[active_field_index]] = common_input.text

    active_field_index = clampi(index, 0, FIELD_IDS.size() - 1)
    _sync_common_input_from_active()
    _refresh_suggestions()

    if focus_input and not capture_locked:
        common_input.grab_focus()
        common_input.edit()
        common_input.caret_column = common_input.text.length()


func _sync_common_input_from_active() -> void:
    if common_input == null:
        return

    if common_input.has_ime_text():
        common_input.cancel_ime()

    syncing_common_input = true
    common_input.text = "" if capture_locked else str(field_values.get(FIELD_IDS[active_field_index], ""))
    common_input.caret_column = common_input.text.length()
    common_input.deselect()
    syncing_common_input = false


func _cycle_field() -> void:
    if capture_locked:
        return
    _set_active_field((active_field_index + 1) % FIELD_IDS.size(), true)


func _on_common_input_changed(value: String) -> void:
    if capture_locked or syncing_common_input:
        return
    field_values[FIELD_IDS[active_field_index]] = value
    _refresh_capture_rows_only()
    _refresh_suggestions()


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
        common_input.add_theme_stylebox_override("normal", _box(Color("c2c9d0"), Color("5d6874"), 2, 14))
        common_input.add_theme_stylebox_override("focus", _box(Color("c2c9d0"), Color("5d6874"), 2, 14))
        common_input.add_theme_stylebox_override("read_only", _box(Color("89939e"), Color("4c5967"), 2, 14))
    else:
        common_input.add_theme_stylebox_override("normal", _box(Color("eef2f5"), active_color, 3, 14))
        common_input.add_theme_stylebox_override("focus", _box(Color("ffffff"), active_color, 4, 14))
        common_input.add_theme_stylebox_override("read_only", _box(Color("eef2f5"), active_color, 3, 14))

    _sync_common_input_from_active()


func _set_capture_locked(locked: bool) -> void:
    capture_locked = locked
    if locked:
        common_input.release_focus()
    _refresh_capture_ui()
    _refresh_gesture_visual()
    _refresh_suggestions()


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

    var editing := editing_record_id >= 0

    if direction < 0:
        gesture_button.text = "↑\n" + ("ABBRECHEN" if editing else "VERWERFEN") + "\n" + str(int(progress * 100.0)) + "%"
        gesture_button.add_theme_color_override("font_color", NOK_COLOR)
        gesture_button.add_theme_stylebox_override("normal", _box(Color("27151c"), NOK_COLOR, 3, 16))
    elif direction > 0:
        gesture_button.text = "↓\n" + ("ÜBERNEHMEN" if editing else "SPEICHERN") + "\n" + str(int(progress * 100.0)) + "%"
        gesture_button.add_theme_color_override("font_color", OK_COLOR)
        gesture_button.add_theme_stylebox_override("normal", _box(Color("10231f"), OK_COLOR, 3, 16))
    else:
        if editing:
            gesture_button.text = "→\nWEITER\n\n↑ Abbrechen\n↓ Übernehmen"
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

    if editing_record_id >= 0:
        _save_edited_capture_record()
        return

    if not _persist_measurement(current_measurement):
        var message := last_database_error if not last_database_error.is_empty() else "Speichern fehlgeschlagen."
        _set_workflow(message, Color("ff7885"))
        return

    if ble != null and database_ready:
        ble.databaseObserveVocabulary(
            str(field_values["geraeteart"]).strip_edges(),
            str(field_values["hersteller"]).strip_edges()
        )
    _refresh_database_counts()
    _begin_post_measurement_action("GESPEICHERT")


func _discard_current_measurement() -> void:
    if current_measurement.is_empty():
        return
    if editing_record_id >= 0:
        _finish_capture_edit(false)
        return
    _begin_post_measurement_action("VERWORFEN")


func _persist_measurement(measurement: Dictionary) -> bool:
    last_database_error = ""

    if ble == null:
        last_database_error = "Speichern fehlgeschlagen: Android-Bridge fehlt."
        return false

    if not database_ready:
        _setup_database_state()
        if not database_ready:
            if last_database_error.is_empty():
                last_database_error = "Speichern fehlgeschlagen: Datenbank nicht bereit."
            return false

    var record := measurement.duplicate(true)
    var created_at := Time.get_datetime_string_from_system()
    var measurement_timestamp := str(measurement.get("device_date", ""))
    if not str(measurement.get("device_time", "")).is_empty():
        measurement_timestamp += " " + str(measurement.get("device_time", ""))

    record["created_at"] = created_at
    record["measurement_timestamp"] = measurement_timestamp
    record["external_id"] = str(field_values["id"])
    record["geraeteart"] = str(field_values["geraeteart"])
    record["hersteller"] = str(field_values["hersteller"])
    record["raum_etage"] = current_room
    record["source"] = "SecuCore Android v0.10"

    # Direct call on purpose: @UsedByGodot plugin methods are bridged methods and
    # must not be rejected merely because Object.has_method() does not list them.
    var response_text := str(ble.databaseSaveRecord(JSON.stringify(record)))
    var response = JSON.parse_string(response_text)
    if response is Dictionary and bool(response.get("ok", false)):
        current_measurement["database_id"] = int(response.get("id", -1))
        return true

    if response is Dictionary:
        last_database_error = str(response.get("error", "Datenbankfehler"))
    else:
        last_database_error = "Speichern fehlgeschlagen: ungültige Datenbankantwort."
    return false


func _begin_post_measurement_action(mode: String) -> void:
    if current_measurement.is_empty():
        return

    post_action_mode = mode
    _set_capture_locked(true)
    _set_workflow(mode + " · SECUTEST wird vorbereitet ...", OK_COLOR if mode == "GESPEICHERT" else Color("f0b84b"))

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
        _set_workflow(completed_mode + " · bereit für nächste Messung", OK_COLOR)
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


func _setup_database_state() -> void:
    database_ready = false
    last_database_error = ""

    if ble == null:
        last_database_error = "Datenbank nicht verfügbar: Android-Bridge fehlt."
        _refresh_today_label()
        return

    var self_test_text := str(ble.databaseSelfTest())
    var self_test = JSON.parse_string(self_test_text)
    if not (self_test is Dictionary) or not bool(self_test.get("ok", false)):
        if self_test is Dictionary:
            last_database_error = str(self_test.get("error", "Datenbank-Selbsttest fehlgeschlagen."))
        else:
            last_database_error = "Datenbank-Selbsttest lieferte keine gültige Antwort."
        _refresh_today_label()
        return

    database_ready = true
    current_room = str(ble.databaseGetSetting("current_room", ""))
    _refresh_room_label()
    _migrate_legacy_jsonl_once()
    _refresh_database_counts()


func _migrate_legacy_jsonl_once() -> void:
    if ble == null:
        return
    if str(ble.databaseGetSetting("legacy_jsonl_migrated", "0")) == "1":
        return

    var path := "user://secudata_measurements.jsonl"
    if FileAccess.file_exists(path):
        var file := FileAccess.open(path, FileAccess.READ)
        if file != null:
            while not file.eof_reached():
                var line := file.get_line().strip_edges()
                if line.is_empty():
                    continue
                var parsed = JSON.parse_string(line)
                if not (parsed is Dictionary):
                    continue
                var record: Dictionary = parsed.duplicate(true)
                record["created_at"] = str(record.get("saved_at", Time.get_datetime_string_from_system()))
                record["measurement_timestamp"] = str(record.get("device_date", "")) + " " + str(record.get("device_time", ""))
                record["external_id"] = str(record.get("id", ""))
                record["raum_etage"] = str(record.get("raum_etage", ""))
                ble.databaseSaveRecord(JSON.stringify(record))
            file.close()

    ble.databaseSetSetting("legacy_jsonl_migrated", "1")


func _refresh_database_counts() -> void:
    today_count = 0
    week_count = 0
    total_count = 0

    if ble != null and database_ready:
        var parsed = JSON.parse_string(str(ble.databaseCounts()))
        if parsed is Dictionary:
            today_count = int(parsed.get("today", 0))
            week_count = int(parsed.get("week", 0))
            total_count = int(parsed.get("total", 0))

    _refresh_today_label()
    if data_counts_label != null:
        data_counts_label.text = "Heute %d  ·  Woche %d  ·  Gesamt %d" % [today_count, week_count, total_count]


func _refresh_today_label() -> void:
    if today_label != null:
        today_label.text = "Heute " + str(today_count)


func _refresh_room_label() -> void:
    if room_label != null:
        room_label.text = "Raum " + (current_room if not current_room.is_empty() else "—")


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
