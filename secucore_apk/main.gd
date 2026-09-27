extends Control

var core
var status_label: Label
var detail_label: Label
var measurement_label: Label
var test_button: Button
var frame_label: Label

func _ready() -> void:
    _build_ui()
    if not ClassDB.class_exists("SecuCore"):
        status_label.text = "SECUCORE C++ NICHT GELADEN"
        status_label.modulate = Color("ff7885")
        detail_label.text = "Die native GDExtension konnte nicht geladen werden."
        test_button.disabled = true
        return

    core = ClassDB.instantiate("SecuCore")
    status_label.text = "SECUCORE C++ GELADEN"
    status_label.modulate = Color("68e39a")
    detail_label.text = core.get_version() + "\nBasis: SecuData fix117"
    var self_test: Dictionary = core.self_test()
    frame_label.text = "Native Selbstprüfung: " + ("OK" if bool(self_test.get("ok", false)) else "FEHLER") + "\n" + str(self_test.get("detail", ""))

func _build_ui() -> void:
    var bg := ColorRect.new()
    bg.color = Color("07101a")
    bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    add_child(bg)

    var margin := MarginContainer.new()
    margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    margin.add_theme_constant_override("margin_left", 28)
    margin.add_theme_constant_override("margin_right", 28)
    margin.add_theme_constant_override("margin_top", 34)
    margin.add_theme_constant_override("margin_bottom", 34)
    add_child(margin)

    var root := VBoxContainer.new()
    root.add_theme_constant_override("separation", 18)
    margin.add_child(root)

    var title := Label.new()
    title.text = "SECU-DAT"
    title.add_theme_font_size_override("font_size", 42)
    title.modulate = Color("ff4d5d")
    root.add_child(title)

    var subtitle := Label.new()
    subtitle.text = "SecuCore Android Debug · v0.1b"
    subtitle.add_theme_font_size_override("font_size", 22)
    subtitle.modulate = Color("a9b7c6")
    root.add_child(subtitle)

    status_label = Label.new()
    status_label.text = "SECUCORE WIRD GELADEN …"
    status_label.add_theme_font_size_override("font_size", 27)
    root.add_child(status_label)

    detail_label = Label.new()
    detail_label.add_theme_font_size_override("font_size", 18)
    detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    root.add_child(detail_label)

    var divider := HSeparator.new()
    root.add_child(divider)

    var info := Label.new()
    info.text = "Dieser erste Build testet nur die neue Architektur:\nGodot → nativer C++-Core → fix117-PRX-Parser → Godot.\nBluetooth kommt im nächsten Schritt."
    info.add_theme_font_size_override("font_size", 18)
    info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    info.modulate = Color("c8d2dc")
    root.add_child(info)

    test_button = Button.new()
    test_button.text = "SIMULIERTE FIX117-MESSUNG"
    test_button.custom_minimum_size.y = 74
    test_button.add_theme_font_size_override("font_size", 20)
    test_button.pressed.connect(_run_measurement)
    root.add_child(test_button)

    measurement_label = Label.new()
    measurement_label.text = "Noch keine Messung ausgelöst."
    measurement_label.add_theme_font_size_override("font_size", 24)
    measurement_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    measurement_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
    root.add_child(measurement_label)

    frame_label = Label.new()
    frame_label.add_theme_font_size_override("font_size", 16)
    frame_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    frame_label.modulate = Color("7f93a7")
    root.add_child(frame_label)

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
    frame_label.text = "C++ erzeugt außerdem echte Protokollframes:\n" + str(core.build_frame("TAS?")).replace("\r", "\\r") + "  |  " + str(core.build_frame("PRX?X")).replace("\r", "\\r")

func _fmt(value) -> String:
    if value == null:
        return "—"
    return str(value)
