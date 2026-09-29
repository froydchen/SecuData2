#ifndef SECUCORE_H
#define SECUCORE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

class SecuCore : public RefCounted {
    GDCLASS(SecuCore, RefCounted)

protected:
    static void _bind_methods();

public:
    String get_version() const;
    String calculate_checksum_hex(const String &payload_including_dollar) const;
    String build_frame(const String &command_core) const;
    Dictionary parse_frame(const String &raw) const;
    Dictionary self_test() const;
    Dictionary parse_direct_prx_blocks(const String &x_payload, const String &y_payload, const String &z_payload) const;
    Dictionary simulate_fix117_measurement() const;

    Dictionary begin_identity_probe();
    Dictionary consume_identity_probe_line(const String &raw);
    String get_identity_probe_state() const;
    void reset_identity_probe();

private:
    enum class IdentityProbeState {
        IDLE,
        WAITING_IDN,
        IDENTIFIED,
        ERROR,
    };

    IdentityProbeState identity_probe_state = IdentityProbeState::IDLE;
    String identity_probe_error;

    static double parse_numeric(const String &value, bool &ok);
    static bool bitfield_is_ok(const String &marker, bool &known);
    static String strip_frame_controls(const String &value);
    static String classify_payload(const String &payload);
};

}

#endif
