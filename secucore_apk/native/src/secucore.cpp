#include "secucore.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/variant.hpp>

using namespace godot;

void SecuCore::_bind_methods() {
    ClassDB::bind_method(D_METHOD("get_version"), &SecuCore::get_version);
    ClassDB::bind_method(D_METHOD("calculate_checksum_hex", "payload_including_dollar"), &SecuCore::calculate_checksum_hex);
    ClassDB::bind_method(D_METHOD("build_frame", "command_core"), &SecuCore::build_frame);
    ClassDB::bind_method(D_METHOD("parse_frame", "raw"), &SecuCore::parse_frame);
    ClassDB::bind_method(D_METHOD("self_test"), &SecuCore::self_test);
    ClassDB::bind_method(D_METHOD("parse_direct_prx_blocks", "x_payload", "y_payload", "z_payload"), &SecuCore::parse_direct_prx_blocks);
    ClassDB::bind_method(D_METHOD("simulate_fix117_measurement"), &SecuCore::simulate_fix117_measurement);

    ClassDB::bind_method(D_METHOD("begin_identity_probe"), &SecuCore::begin_identity_probe);
    ClassDB::bind_method(D_METHOD("consume_identity_probe_line", "raw"), &SecuCore::consume_identity_probe_line);
    ClassDB::bind_method(D_METHOD("get_identity_probe_state"), &SecuCore::get_identity_probe_state);
    ClassDB::bind_method(D_METHOD("reset_identity_probe"), &SecuCore::reset_identity_probe);

    ClassDB::bind_method(D_METHOD("begin_live_init"), &SecuCore::begin_live_init);
    ClassDB::bind_method(D_METHOD("consume_live_line", "raw"), &SecuCore::consume_live_line);
    ClassDB::bind_method(D_METHOD("begin_mes_status_query"), &SecuCore::begin_mes_status_query);
    ClassDB::bind_method(D_METHOD("get_live_state"), &SecuCore::get_live_state);
    ClassDB::bind_method(D_METHOD("reset_live_init"), &SecuCore::reset_live_init);

    ClassDB::bind_method(D_METHOD("arm_measurement_monitor"), &SecuCore::arm_measurement_monitor);
    ClassDB::bind_method(D_METHOD("begin_measurement_fetch"), &SecuCore::begin_measurement_fetch);
    ClassDB::bind_method(D_METHOD("consume_measurement_line", "raw"), &SecuCore::consume_measurement_line);
    ClassDB::bind_method(D_METHOD("get_measurement_state"), &SecuCore::get_measurement_state);
    ClassDB::bind_method(D_METHOD("reset_measurement_flow"), &SecuCore::reset_measurement_flow);
}

String SecuCore::get_version() const {
    return "SecuCore C++ v0.7 - Raw PRX";
}

String SecuCore::calculate_checksum_hex(const String &payload_including_dollar) const {
    CharString bytes = payload_including_dollar.utf8();
    unsigned int total = 0;
    for (int i = 0; i < bytes.length(); ++i) {
        total = (total + static_cast<unsigned char>(bytes[i])) & 0xFF;
    }
    return String::num_int64(total, 16).pad_zeros(2).to_upper();
}

String SecuCore::build_frame(const String &command_core) const {
    const String payload = command_core + String("$");
    return payload + calculate_checksum_hex(payload) + "\r";
}

bool SecuCore::is_hex_char(char32_t c) {
    return (c >= '0' && c <= '9') ||
           (c >= 'A' && c <= 'F') ||
           (c >= 'a' && c <= 'f');
}

String SecuCore::strip_frame_controls(const String &value) {
    int start = 0;
    int end = value.length();

    auto is_control = [](char32_t c) {
        return c == 0x02 || c == 0x03 || c == 0x11 || c == 0x13 || c == 0x00 || c == '\r' || c == '\n';
    };

    while (start < end && is_control(value.unicode_at(start))) {
        ++start;
    }
    while (end > start && is_control(value.unicode_at(end - 1))) {
        --end;
    }
    return value.substr(start, end - start);
}

String SecuCore::classify_payload(const String &payload) {
    const String upper = payload.strip_edges().to_upper();
    if (upper.begins_with(".Y") || upper.begins_with("Y")) {
        return "ACK";
    }
    if (upper.begins_with(".N") || upper.begins_with("N")) {
        return "NACK";
    }
    return "RESPONSE";
}

Dictionary SecuCore::parse_frame(const String &raw) const {
    Dictionary out;
    const String normalized = strip_frame_controls(raw);
    const int dollar = normalized.rfind("$");

    String payload = normalized;
    String checksum_received;
    String checksum_calculated;
    bool checksum_present = false;
    bool checksum_valid = false;

    // Only treat "$xx" at the very end as an outer checksum.
    // A checksumless direct SECUTEST response is valid input and must not be
    // rejected merely because '$xx' is absent.
    if (
        dollar >= 0 &&
        dollar == normalized.length() - 3 &&
        is_hex_char(normalized.unicode_at(dollar + 1)) &&
        is_hex_char(normalized.unicode_at(dollar + 2))
    ) {
        checksum_present = true;
        const String payload_including_dollar = normalized.substr(0, dollar + 1);
        payload = normalized.substr(0, dollar);
        checksum_received = normalized.substr(dollar + 1, 2).to_upper();
        checksum_calculated = calculate_checksum_hex(payload_including_dollar);
        checksum_valid = checksum_received == checksum_calculated;
    }

    out["raw"] = raw;
    out["normalized"] = normalized;
    out["payload"] = payload;
    out["checksum_present"] = checksum_present;
    out["checksum_received"] = checksum_received;
    out["checksum_calculated"] = checksum_calculated;
    out["checksum_valid"] = checksum_valid;
    out["checksum_acceptable"] = !checksum_present || checksum_valid;
    out["checksum_state"] = checksum_present ? (checksum_valid ? "OK" : "FEHLER") : "KEINE";
    out["kind"] = classify_payload(payload);
    return out;
}

bool SecuCore::checksum_acceptable(const Dictionary &parsed) {
    return bool(parsed.get("checksum_acceptable", false));
}

bool SecuCore::response_begins_with(const Dictionary &parsed, const String &prefix) {
    if (String(parsed.get("kind", "")) != "RESPONSE") {
        return false;
    }
    const String payload = String(parsed.get("payload", "")).strip_edges().to_upper();
    return payload.begins_with(prefix.to_upper());
}

Dictionary SecuCore::begin_identity_probe() {
    identity_probe_state = IdentityProbeState::WAITING_IDN;
    identity_probe_error = "";

    Dictionary out;
    out["command"] = "IDN?";
    out["frame"] = build_frame("IDN?");
    out["state"] = get_identity_probe_state();
    return out;
}

Dictionary SecuCore::consume_identity_probe_line(const String &raw) {
    Dictionary out;
    const Dictionary parsed = parse_frame(raw);
    out["frame"] = parsed;
    out["accepted"] = false;
    out["complete"] = false;
    out["success"] = false;

    if (identity_probe_state != IdentityProbeState::WAITING_IDN) {
        out["state"] = get_identity_probe_state();
        out["message"] = "Kein IDN?-Probe aktiv";
        return out;
    }

    const String kind = String(parsed.get("kind", ""));
    const String payload = String(parsed.get("payload", ""));
    const String upper = payload.strip_edges().to_upper();

    if (!checksum_acceptable(parsed)) {
        identity_probe_state = IdentityProbeState::ERROR;
        identity_probe_error = "IDN?-Antwort mit falscher vorhandener Checksumme";
        out["accepted"] = true;
        out["complete"] = true;
        out["state"] = get_identity_probe_state();
        out["message"] = identity_probe_error;
        return out;
    }

    if (kind == "NACK") {
        identity_probe_state = IdentityProbeState::ERROR;
        identity_probe_error = "NACK auf IDN?";
        out["accepted"] = true;
        out["complete"] = true;
        out["state"] = get_identity_probe_state();
        out["message"] = identity_probe_error;
        return out;
    }

    if (kind != "RESPONSE" || !upper.begins_with("IDN")) {
        out["state"] = get_identity_probe_state();
        out["message"] = "Unsolicited/unerwarteter Frame während IDN?-Probe";
        return out;
    }

    identity_probe_state = IdentityProbeState::IDENTIFIED;
    out["accepted"] = true;
    out["complete"] = true;
    out["success"] = true;
    out["state"] = get_identity_probe_state();
    out["identity"] = payload;
    out["is_secutest"] = upper.contains("SECUTEST");
    out["message"] = upper.contains("SECUTEST") ? "SECUTEST-Identität empfangen" : "IDN-Antwort empfangen";
    return out;
}

String SecuCore::get_identity_probe_state() const {
    switch (identity_probe_state) {
        case IdentityProbeState::WAITING_IDN:
            return "WAITING_IDN";
        case IdentityProbeState::IDENTIFIED:
            return "IDENTIFIED";
        case IdentityProbeState::ERROR:
            return "ERROR";
        case IdentityProbeState::IDLE:
        default:
            return "IDLE";
    }
}

void SecuCore::reset_identity_probe() {
    identity_probe_state = IdentityProbeState::IDLE;
    identity_probe_error = "";
}

Dictionary SecuCore::make_live_command(const String &command, const String &message) const {
    Dictionary out;
    out["accepted"] = true;
    out["complete"] = false;
    out["success"] = false;
    out["command"] = command;
    out["next_command"] = command;
    out["next_frame"] = build_frame(command);
    out["state"] = get_live_state();
    out["message"] = message;
    return out;
}

Dictionary SecuCore::fail_live(const Dictionary &parsed, const String &message) {
    live_state = LiveInitState::ERROR;
    live_error = message;

    Dictionary out;
    out["frame"] = parsed;
    out["accepted"] = true;
    out["complete"] = true;
    out["success"] = false;
    out["state"] = get_live_state();
    out["message"] = message;
    return out;
}

Dictionary SecuCore::begin_live_init() {
    live_state = LiveInitState::WAIT_IDN_INITIAL;
    live_error = "";
    live_identity = "";
    live_mes_status = "";
    return make_live_command("IDN?", "Gerätekennung lesen");
}

Dictionary SecuCore::consume_live_line(const String &raw) {
    const Dictionary parsed = parse_frame(raw);

    Dictionary out;
    out["frame"] = parsed;
    out["accepted"] = false;
    out["complete"] = false;
    out["success"] = false;
    out["state"] = get_live_state();

    if (live_state == LiveInitState::IDLE || live_state == LiveInitState::READY || live_state == LiveInitState::ERROR) {
        out["message"] = "Kein passender Live-Befehl wartet auf eine Antwort";
        return out;
    }

    if (!checksum_acceptable(parsed)) {
        return fail_live(parsed, "Antwort mit falscher vorhandener Checksumme");
    }

    const String kind = String(parsed.get("kind", ""));
    const String payload = String(parsed.get("payload", "")).strip_edges();
    const String upper = payload.to_upper();

    if (kind == "NACK") {
        return fail_live(parsed, String("SECUTEST meldet NACK in ") + get_live_state());
    }

    switch (live_state) {
        case LiveInitState::WAIT_IDN_INITIAL: {
            if (!response_begins_with(parsed, "IDN")) {
                out["message"] = "Warte weiter auf IDN?-Antwort";
                return out;
            }
            if (!upper.contains("SECUTEST")) {
                return fail_live(parsed, "IDN? liefert keine SECUTEST-Identität");
            }
            live_identity = payload;
            // Direkter SECUTEST-Betrieb: keine PSI-Adressierung.
            live_state = LiveInitState::WAIT_TASA_ACK;
            out = make_live_command("TAS!a", "Direktverbindung erkannt · TAS!a senden");
            out["frame"] = parsed;
            out["identity"] = live_identity;
            return out;
        }

        case LiveInitState::WAIT_IDN0_ASSIGN: {
            if (!response_begins_with(parsed, "IDN")) {
                out["message"] = "Warte weiter auf Antwort zu IDN!0";
                return out;
            }
            live_state = LiveInitState::WAIT_IDN_AFTER_PSI;
            out = make_live_command("IDN?", "Adressierung nach IDN!0 prüfen");
            out["frame"] = parsed;
            return out;
        }

        case LiveInitState::WAIT_IDN_AFTER_PSI: {
            if (!response_begins_with(parsed, "IDN")) {
                out["message"] = "Warte weiter auf zweite IDN?-Antwort";
                return out;
            }
            live_state = LiveInitState::WAIT_IDN1_ASSIGN;
            out = make_live_command("IDN1!1", "SECUTEST auf Adresse 1 setzen");
            out["frame"] = parsed;
            return out;
        }

        case LiveInitState::WAIT_IDN1_ASSIGN: {
            if (!response_begins_with(parsed, "IDN")) {
                out["message"] = "Warte weiter auf Antwort zu IDN1!1";
                return out;
            }
            live_state = LiveInitState::WAIT_IDN1_VERIFY;
            out = make_live_command("IDN1?", "Adressierten SECUTEST prüfen");
            out["frame"] = parsed;
            return out;
        }

        case LiveInitState::WAIT_IDN1_VERIFY: {
            if (!response_begins_with(parsed, "IDN")) {
                out["message"] = "Warte weiter auf IDN1?-Antwort";
                return out;
            }
            if (!upper.contains("SECUTEST")) {
                return fail_live(parsed, "IDN1? liefert keine SECUTEST-Identität");
            }
            live_identity = payload;
            live_state = LiveInitState::WAIT_TASA_ACK;
            out = make_live_command("TAS!a", "Tastatur/Remote-Modus nach Connect initialisieren");
            out["frame"] = parsed;
            out["identity"] = live_identity;
            return out;
        }

        case LiveInitState::WAIT_TASA_ACK: {
            if (kind != "ACK" && !upper.begins_with("TAS")) {
                out["message"] = "Warte weiter auf Bestätigung zu TAS!a";
                return out;
            }
            live_state = LiveInitState::WAIT_MES_STATUS;
            out = make_live_command("MES?", "Aktuellen Messstatus lesen");
            out["frame"] = parsed;
            out["identity"] = live_identity;
            return out;
        }

        case LiveInitState::WAIT_MES_STATUS: {
            if (kind != "RESPONSE") {
                out["message"] = "Warte weiter auf MES?-Antwort";
                return out;
            }
            live_mes_status = payload;
            live_state = LiveInitState::READY;

            out["frame"] = parsed;
            out["accepted"] = true;
            out["complete"] = true;
            out["success"] = true;
            out["state"] = get_live_state();
            out["message"] = "Direkter SECUTEST verbunden und Live-Status gelesen";
            out["identity"] = live_identity;
            out["mes_status"] = live_mes_status;
            return out;
        }

        default:
            out["message"] = "Unbekannter Live-Zustand";
            return out;
    }
}

Dictionary SecuCore::begin_mes_status_query() {
    if (live_state != LiveInitState::READY) {
        Dictionary out;
        out["accepted"] = false;
        out["complete"] = true;
        out["success"] = false;
        out["state"] = get_live_state();
        out["message"] = "SECUTEST ist noch nicht READY";
        return out;
    }
    live_state = LiveInitState::WAIT_MES_STATUS;
    return make_live_command("MES?", "Live-Messstatus aktualisieren");
}

String SecuCore::get_live_state() const {
    switch (live_state) {
        case LiveInitState::WAIT_IDN_INITIAL:
            return "WAIT_IDN_INITIAL";
        case LiveInitState::WAIT_IDN0_ASSIGN:
            return "WAIT_IDN0_ASSIGN";
        case LiveInitState::WAIT_IDN_AFTER_PSI:
            return "WAIT_IDN_AFTER_PSI";
        case LiveInitState::WAIT_IDN1_ASSIGN:
            return "WAIT_IDN1_ASSIGN";
        case LiveInitState::WAIT_IDN1_VERIFY:
            return "WAIT_IDN1_VERIFY";
        case LiveInitState::WAIT_TASA_ACK:
            return "WAIT_TASA_ACK";
        case LiveInitState::WAIT_MES_STATUS:
            return "WAIT_MES_STATUS";
        case LiveInitState::READY:
            return "READY";
        case LiveInitState::ERROR:
            return "ERROR";
        case LiveInitState::IDLE:
        default:
            return "IDLE";
    }
}

void SecuCore::reset_live_init() {
    live_state = LiveInitState::IDLE;
    live_error = "";
    live_identity = "";
    live_mes_status = "";
}


Dictionary SecuCore::make_measurement_command(const String &command, const String &message) const {
    Dictionary out;
    out["accepted"] = true;
    out["complete"] = false;
    out["success"] = false;
    out["next_command"] = command;

    const String upper = command.to_upper();
    if (upper == "PRX?X" || upper == "PRX?Y" || upper == "PRX?Z") {
        // Direct SECUTEST PRX block requests are raw CR-terminated commands.
        // Adding "$xx" makes the device answer with .Nx=x01.
        out["next_frame"] = command + "\r";
        out["raw_command"] = true;
    } else {
        out["next_frame"] = build_frame(command);
        out["raw_command"] = false;
    }

    out["state"] = get_measurement_state();
    out["message"] = message;
    return out;
}

Dictionary SecuCore::fail_measurement(const Dictionary &parsed, const String &message) {
    measurement_state = MeasurementState::ERROR;
    Dictionary out;
    out["frame"] = parsed;
    out["accepted"] = true;
    out["complete"] = true;
    out["success"] = false;
    out["state"] = get_measurement_state();
    out["message"] = message;
    return out;
}

int SecuCore::parse_switch_position(const String &payload) {
    const String upper = payload.to_upper();
    const int marker = upper.find("TASTEX=");
    if (marker < 0) {
        return -1;
    }

    const int start = marker + 7;
    String digits;
    for (int i = start; i < upper.length(); ++i) {
        const char32_t ch = upper.unicode_at(i);
        if (ch >= '0' && ch <= '9') {
            digits += String::chr(ch);
        } else {
            break;
        }
    }
    return digits.is_empty() ? -1 : digits.to_int();
}

void SecuCore::arm_measurement_monitor() {
    measurement_state = MeasurementState::ARMED;
    measurement_switch_position = -1;
    measurement_kind = "";
    measurement_prx_x = "";
    measurement_prx_y = "";
    measurement_prx_z = "";
}

Dictionary SecuCore::begin_measurement_fetch() {
    if (measurement_state != MeasurementState::ARMED &&
        measurement_state != MeasurementState::RESULT_READY &&
        measurement_state != MeasurementState::ERROR) {
        Dictionary out;
        out["accepted"] = false;
        out["complete"] = true;
        out["success"] = false;
        out["state"] = get_measurement_state();
        out["message"] = "Messdatenabruf ist in diesem Zustand nicht möglich";
        return out;
    }

    measurement_switch_position = -1;
    measurement_kind = "";
    measurement_prx_x = "";
    measurement_prx_y = "";
    measurement_prx_z = "";
    measurement_state = MeasurementState::WAIT_SWITCH;
    return make_measurement_command("TAS?", "PRX erkannt - Drehschalter vor Datenabruf lesen");
}

Dictionary SecuCore::consume_measurement_line(const String &raw) {
    const Dictionary parsed = parse_frame(raw);

    Dictionary out;
    out["frame"] = parsed;
    out["accepted"] = false;
    out["complete"] = false;
    out["success"] = false;
    out["state"] = get_measurement_state();

    if (!checksum_acceptable(parsed)) {
        return fail_measurement(parsed, "Antwort mit falscher vorhandener Checksumme");
    }

    const String kind = String(parsed.get("kind", ""));
    const String payload = String(parsed.get("payload", "")).strip_edges();
    const String upper = payload.to_upper();

    if (measurement_state == MeasurementState::ARMED) {
        if (kind == "RESPONSE" && upper == "PRX") {
            measurement_state = MeasurementState::WAIT_SWITCH;
            out = make_measurement_command("TAS?", "PRX erkannt - XON bestätigen, dann Drehschalter lesen");
            out["frame"] = parsed;
            out["prx_trigger"] = true;
            return out;
        }
        out["message"] = "Lausche auf PRX";
        return out;
    }

    if (kind == "NACK") {
        return fail_measurement(parsed, String("NACK während Messdatenabruf in ") + get_measurement_state());
    }

    switch (measurement_state) {
        case MeasurementState::WAIT_SWITCH: {
            const int position = parse_switch_position(payload);
            if (position < 0) {
                out["message"] = "Warte auf TASTEx-Antwort";
                return out;
            }

            measurement_switch_position = position;
            if (position == 3) {
                measurement_kind = "GERAET";
            } else if (position == 4) {
                measurement_kind = "LEITUNG";
            } else {
                measurement_kind = "ALLE_VORSCHLAEGE";
            }

            measurement_state = MeasurementState::WAIT_PRX_X;
            out = make_measurement_command("PRX?X", "Drehschalter gelesen - XON + PRX X abrufen");
            out["frame"] = parsed;
            out["switch_position"] = measurement_switch_position;
            out["measurement_kind"] = measurement_kind;
            return out;
        }

        case MeasurementState::WAIT_PRX_X: {
            const int late_position = parse_switch_position(payload);
            if (late_position >= 0) {
                measurement_switch_position = late_position;
                if (late_position == 3) {
                    measurement_kind = "GERAET";
                } else if (late_position == 4) {
                    measurement_kind = "LEITUNG";
                } else {
                    measurement_kind = "ALLE_VORSCHLAEGE";
                }
                out["message"] = "Verspätete Drehschalterantwort übernommen; warte weiter auf PRX?X";
                return out;
            }

            if (!upper.begins_with("PROTOKOLL")) {
                out["message"] = "Warte auf PRX?X-Daten";
                return out;
            }
            measurement_prx_x = payload;
            measurement_state = MeasurementState::WAIT_PRX_Y;
            out = make_measurement_command("PRX?Y", "PRX X empfangen - XON + PRX Y abrufen");
            out["frame"] = parsed;
            return out;
        }

        case MeasurementState::WAIT_PRX_Y: {
            if (!upper.begins_with("PROTOKOLL")) {
                out["message"] = "Warte auf PRX?Y-Daten";
                return out;
            }
            measurement_prx_y = payload;
            measurement_state = MeasurementState::WAIT_PRX_Z;
            out = make_measurement_command("PRX?Z", "PRX Y empfangen - XON + PRX Z abrufen");
            out["frame"] = parsed;
            return out;
        }

        case MeasurementState::WAIT_PRX_Z: {
            if (!upper.begins_with("PROTOKOLL")) {
                out["message"] = "Warte auf PRX?Z-Daten";
                return out;
            }
            measurement_prx_z = payload;

            Dictionary measurement = parse_direct_prx_blocks(
                measurement_prx_x,
                measurement_prx_y,
                measurement_prx_z
            );
            measurement["switch_position"] = measurement_switch_position;
            measurement["measurement_kind"] = measurement_kind;

            const String key =
                String(measurement.get("device_date", "")) + "|" +
                String(measurement.get("device_time", ""));
            const bool duplicate = !key.is_empty() && key == last_measurement_key;
            measurement["duplicate"] = duplicate;
            if (!duplicate && !key.is_empty()) {
                last_measurement_key = key;
            }

            measurement_state = MeasurementState::RESULT_READY;
            out["frame"] = parsed;
            out["accepted"] = true;
            out["complete"] = true;
            out["success"] = bool(measurement.get("valid", false));
            out["state"] = get_measurement_state();
            out["message"] = duplicate ? "Doppelter PRX-Zeitstempel verworfen" : "Echte Messdaten vollständig gelesen";
            out["measurement"] = measurement;
            out["duplicate"] = duplicate;
            return out;
        }

        default:
            out["message"] = "Kein aktiver Messdatenabruf";
            return out;
    }
}

String SecuCore::get_measurement_state() const {
    switch (measurement_state) {
        case MeasurementState::ARMED:
            return "ARMED";
        case MeasurementState::WAIT_SWITCH:
            return "WAIT_SWITCH";
        case MeasurementState::WAIT_PRX_X:
            return "WAIT_PRX_X";
        case MeasurementState::WAIT_PRX_Y:
            return "WAIT_PRX_Y";
        case MeasurementState::WAIT_PRX_Z:
            return "WAIT_PRX_Z";
        case MeasurementState::RESULT_READY:
            return "RESULT_READY";
        case MeasurementState::ERROR:
            return "ERROR";
        case MeasurementState::IDLE:
        default:
            return "IDLE";
    }
}

void SecuCore::reset_measurement_flow() {
    measurement_state = MeasurementState::IDLE;
    measurement_switch_position = -1;
    measurement_kind = "";
    measurement_prx_x = "";
    measurement_prx_y = "";
    measurement_prx_z = "";
}

double SecuCore::parse_numeric(const String &value, bool &ok) {
    String out;
    bool started = false;
    bool dot_seen = false;

    for (int i = 0; i < value.length(); ++i) {
        const char32_t c = value.unicode_at(i);
        const bool digit = c >= '0' && c <= '9';

        if (!started && (c == '+' || c == '-')) {
            out += String::chr(c);
            started = true;
            continue;
        }
        if (digit) {
            out += String::chr(c);
            started = true;
            continue;
        }
        if (started && (c == '.' || c == ',') && !dot_seen) {
            out += String(".");
            dot_seen = true;
            continue;
        }
        if (started) {
            break;
        }
    }

    ok = !out.is_empty() && out != String("+") && out != String("-");
    return ok ? out.to_float() : 0.0;
}

bool SecuCore::bitfield_is_ok(const String &marker, bool &known) {
    String hex;
    const String upper = marker.to_upper();

    for (int i = 0; i < upper.length(); ++i) {
        const char32_t c = upper.unicode_at(i);
        if ((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F')) {
            hex += String::chr(c);
        }
    }

    if (hex.length() < 8) {
        known = false;
        return true;
    }

    const int ee = hex.substr(6, 2).hex_to_int();
    known = true;
    return (ee & 0x80) == 0;
}

Dictionary SecuCore::parse_direct_prx_blocks(
    const String &x_payload,
    const String &y_payload,
    const String &z_payload
) const {
    Dictionary out;
    const PackedStringArray x = x_payload.split(String(";"), true);
    const PackedStringArray y = y_payload.split(String(";"), true);
    const PackedStringArray z = z_payload.split(String(";"), true);

    if (x.size() < 6 || y.size() < 2 || z.size() < 2) {
        out["valid"] = false;
        out["error"] = "PRX?X/Y/Z unvollständig";
        return out;
    }

    String protocol_id = x[0];
    const int eq = protocol_id.find(String("="));
    if (eq >= 0) {
        protocol_id = protocol_id.substr(eq + 1);
    }

    bool result_known = false;
    const bool is_ok = bitfield_is_ok(x[1], result_known);

    bool rpe_ok = false;
    const double rpe = parse_numeric(y[1], rpe_ok);

    bool rins_ok = false;
    const double rins = y.size() > 5 ? parse_numeric(y[5], rins_ok) : 0.0;

    bool ipe_ok = false;
    double ipe = 0.0;
    for (int i = 1; i < y.size(); ++i) {
        if (!y[i].to_upper().contains(String("MA"))) {
            continue;
        }
        bool n_ok = false;
        const double n = parse_numeric(y[i], n_ok);
        if (n_ok) {
            ipe = n;
            ipe_ok = true;
            if (!y[i].strip_edges().begins_with(String("<")) && !y[i].strip_edges().begins_with(String(">"))) {
                break;
            }
        }
    }

    bool u_ok = false;
    double mains_u = 0.0;
    for (int i = 1; i + 1 < z.size(); ++i) {
        if (!z[i].to_upper().contains(String("V")) || !z[i + 1].to_upper().contains("V")) {
            continue;
        }
        bool actual_ok = false;
        bool limit_ok = false;
        const double actual = parse_numeric(z[i], actual_ok);
        const double limit = parse_numeric(z[i + 1], limit_ok);
        if (actual_ok && limit_ok && actual >= 100.0 && actual <= 300.0 && limit >= 240.0 && limit <= 260.0) {
            mains_u = actual;
            u_ok = true;
            break;
        }
    }

    if (!u_ok) {
        for (int i = 1; i + 1 < y.size(); ++i) {
            if (!y[i].to_upper().contains("V") || !y[i + 1].to_upper().contains("V")) {
                continue;
            }
            bool actual_ok = false;
            bool limit_ok = false;
            const double actual = parse_numeric(y[i], actual_ok);
            const double limit = parse_numeric(y[i + 1], limit_ok);
            if (actual_ok && limit_ok && actual >= 100.0 && actual <= 300.0 && limit >= 240.0 && limit <= 260.0) {
                mains_u = actual;
                u_ok = true;
                break;
            }
        }
    }

    out["valid"] = true;
    out["source"] = "SECUTEST_DIRECT_PRX";
    out["protocol_id"] = protocol_id;
    out["device_date"] = x[x.size() - 2].strip_edges();
    out["device_time"] = x[x.size() - 1].strip_edges();
    out["is_ok"] = result_known ? is_ok : true;

    if (rpe_ok) {
        out["rpe"] = rpe;
    } else {
        out["rpe"] = Variant();
    }
    if (rins_ok) {
        out["rins"] = rins;
    } else {
        out["rins"] = Variant();
    }
    if (ipe_ok) {
        out["ipe"] = ipe;
    } else {
        out["ipe"] = Variant();
    }
    if (u_ok) {
        out["u"] = mains_u;
    } else {
        out["u"] = Variant();
    }

    return out;
}

Dictionary SecuCore::simulate_fix117_measurement() const {
    const String x = "Protokollx=XXXXXXXX;000021000000510000000C000000060000220000;;;15.08.26;12:47:31";
    const String y = "Protokollx=XXXXXXXX;;;;;>+310.0MΩ;>2.000MΩ; +0527V ;+0500V ;;;;;;; +0.000mA;<0.500mA;;;;;;;;";
    const String z = "Protokollx=XXXXXXXX;;;;;;;;;;;;;;;;;;;; +197.2V ;+253.0V ;;";
    return parse_direct_prx_blocks(x, y, z);
}

Dictionary SecuCore::self_test() const {
    Dictionary out;

    const bool checksum_ok = build_frame("TAS?") == String("TAS?$4B\r");
    const Dictionary measurement = simulate_fix117_measurement();

    const bool valid = bool(measurement.get("valid", false));
    const double rins = double(measurement.get("rins", 0.0));
    const double ipe = double(measurement.get("ipe", 999.0));
    const double u = double(measurement.get("u", 0.0));
    const bool result_ok = bool(measurement.get("is_ok", false));

    const bool parser_ok =
        valid &&
        Math::is_equal_approx(rins, 310.0) &&
        Math::is_equal_approx(ipe, 0.0) &&
        Math::is_equal_approx(u, 197.2) &&
        result_ok;

    const String idn_frame = build_frame("IDN=SECUTEST S2-N10");
    const Dictionary checksummed = parse_frame(idn_frame);
    const Dictionary checksumless = parse_frame("IDNx=x;GMN;Secutest S2N+10;GMC V 8.23");
    const Dictionary damaged = parse_frame("IDN=SECUTEST$00");

    const bool frame_parser_ok =
        bool(checksummed.get("checksum_present", false)) &&
        bool(checksummed.get("checksum_valid", false)) &&
        !bool(checksumless.get("checksum_present", true)) &&
        bool(checksumless.get("checksum_acceptable", false)) &&
        bool(damaged.get("checksum_present", false)) &&
        !bool(damaged.get("checksum_valid", true)) &&
        !bool(damaged.get("checksum_acceptable", true));

    out["ok"] = checksum_ok && parser_ok && frame_parser_ok;
    out["detail"] =
        String("TX checksum + fix117 PRX + optional RX checksum parser: ") +
        String((checksum_ok && parser_ok && frame_parser_ok) ? "OK" : "FEHLER");

    return out;
}
