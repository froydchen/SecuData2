# SecuCore v0.2 BLE IDN test

Build target: Android ARM64. The v0.2 test connects to the LinTech `BLE RS232` adapter, sends a real SECUTEST `IDN?` frame through the native C++ core, validates the received frame/checksum, and displays the identity response. The fix117 simulation remains available as a regression test.
