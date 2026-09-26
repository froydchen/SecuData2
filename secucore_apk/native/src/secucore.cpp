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
    ClassDB::bind_method(D_METHOD("self_test"), &SecuCore::self_test);
    ClassDB::bind_method(D_METHOD("parse_direct_prx_blocks", "x_payload", "y_payload", "z_payload"), &SecuCore::parse_direct_prx_blocks);
    ClassDB::bind_method(D_METHOD("simulate_fix117_measurement"), &SecuCore::simulate_fix117_measurement);
}

String SecuCore::get_version() const {
    return "SecuCore C++ v0.1 · native ARM64";
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

    out["ok"] = checksum_ok && parser_ok;
    out["detail"] =
        String("Frame TAS?$4B + fix117 PRX X/Y/Z Parser: ") +
        String((checksum_ok && parser_ok) ? "OK" : "FEHLER");

    return out;
}
