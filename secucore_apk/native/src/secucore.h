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

    // Kept for the small v0.2 diagnostic screen.
    Dictionary begin_identity_probe();
    Dictionary consume_identity_probe_line(const String &raw);
    String get_identity_probe_state() const;
    void reset_identity_probe();

    // v0.3: complete live link bring-up:
    // IDN? -> IDN!0 -> IDN? -> IDN1!1 -> IDN1? -> TAS!a -> MES?
    Dictionary begin_live_init();
    Dictionary consume_live_line(const String &raw);
    Dictionary begin_mes_status_query();
    String get_live_state() const;
    void reset_live_init();

    // v0.5: direct measurement flow.
    // PRX -> TAS? -> PRX?X -> PRX?Y -> PRX?Z -> parsed measurement.
    void arm_measurement_monitor();
    Dictionary begin_measurement_fetch();
    Dictionary consume_measurement_line(const String &raw);
    String get_measurement_state() const;
    void reset_measurement_flow();

    // v0.8: post-measurement action after Save/Discard.
    // Direct mode: switch 3 -> RST!3, switch 4 -> RST!4, then TAS!a.
    Dictionary begin_post_measurement_reset(int switch_position);
    Dictionary consume_post_measurement_line(const String &raw);
    String get_post_measurement_state() const;
    void reset_post_measurement();

private:
    enum class IdentityProbeState {
        IDLE,
        WAITING_IDN,
        IDENTIFIED,
        ERROR,
    };

    enum class LiveInitState {
        IDLE,
        WAIT_IDN_INITIAL,
        WAIT_IDN0_ASSIGN,
        WAIT_IDN_AFTER_PSI,
        WAIT_IDN1_ASSIGN,
        WAIT_IDN1_VERIFY,
        WAIT_TASA_ACK,
        WAIT_MES_STATUS,
        READY,
        ERROR,
    };

    enum class MeasurementState {
        IDLE,
        ARMED,
        WAIT_SWITCH,
        WAIT_PRX_X,
        WAIT_PRX_Y,
        WAIT_PRX_Z,
        RESULT_READY,
        ERROR,
    };

    enum class PostMeasurementState {
        IDLE,
        WAIT_RESET_ACK,
        WAIT_TASA_ACK,
        COMPLETE,
        ERROR,
    };

    IdentityProbeState identity_probe_state = IdentityProbeState::IDLE;
    String identity_probe_error;

    LiveInitState live_state = LiveInitState::IDLE;
    String live_error;
    String live_identity;
    String live_mes_status;

    MeasurementState measurement_state = MeasurementState::IDLE;
    int measurement_switch_position = -1;
    String measurement_kind;
    String measurement_prx_x;
    String measurement_prx_y;
    String measurement_prx_z;
    String last_measurement_key;

    PostMeasurementState post_measurement_state = PostMeasurementState::IDLE;
    int post_measurement_switch_position = -1;

    Dictionary make_live_command(const String &command, const String &message) const;
    Dictionary fail_live(const Dictionary &parsed, const String &message);
    Dictionary make_measurement_command(const String &command, const String &message) const;
    Dictionary fail_measurement(const Dictionary &parsed, const String &message);
    Dictionary make_post_command(const String &command, const String &message) const;
    Dictionary fail_post_measurement(const Dictionary &parsed, const String &message);
    static int parse_switch_position(const String &payload);
    static bool checksum_acceptable(const Dictionary &parsed);
    static bool response_begins_with(const Dictionary &parsed, const String &prefix);

    static double parse_numeric(const String &value, bool &ok);
    static bool bitfield_is_ok(const String &marker, bool &known);
    static String strip_frame_controls(const String &value);
    static String classify_payload(const String &payload);
    static bool is_hex_char(char32_t c);
};

}

#endif
