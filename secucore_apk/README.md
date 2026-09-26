# SecuData SecuCore Android test v0.1

First native-core proof of architecture, based on the last known-good SecuData fix117 behavior.

What this APK proves:

- Godot UI starts on Android in portrait mode.
- SecuCore is a real C++ GDExtension compiled for ARM64.
- GDScript calls native C++ directly.
- C++ builds SECUTEST checksummed command frames.
- C++ parses the captured fix117-style direct PRX?X / PRX?Y / PRX?Z sample.
- Parsed measurement is returned to Godot as structured data.

Expected simulated values:

- Result: OK
- RPE: unavailable
- RISO: 310.0 MOhm
- IPE: 0.0 mA
- U: 197.2 V
- SECUTEST timestamp: 15.08.26 12:47:31

Deliberately not in v0.1:

- BLE transport
- TAS? switch-position request
- real PRX event listener
- SQLite
- dictionary
- production UI

Those are added only after this native C++ bridge is proven on the target Android devices.
