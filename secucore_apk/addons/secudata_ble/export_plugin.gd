@tool
extends EditorPlugin

var export_plugin: AndroidExportPlugin

func _enter_tree() -> void:
    export_plugin = AndroidExportPlugin.new()
    add_export_plugin(export_plugin)

func _exit_tree() -> void:
    if export_plugin != null:
        remove_export_plugin(export_plugin)
        export_plugin = null

class AndroidExportPlugin extends EditorExportPlugin:
    var _plugin_name := "SecuDataBle"

    func _supports_platform(platform) -> bool:
        return platform is EditorExportPlatformAndroid

    func _get_android_libraries(_platform, debug: bool) -> PackedStringArray:
        if debug:
            return PackedStringArray(["secudata_ble/bin/debug/SecuDataBle-debug.aar"])
        return PackedStringArray(["secudata_ble/bin/release/SecuDataBle-release.aar"])

    func _get_name() -> String:
        return _plugin_name
