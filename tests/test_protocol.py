import unittest

from secudata_web.protocol import build_frame, calculate_checksum_hex, parse_incoming_frame


class ProtocolTests(unittest.TestCase):
    def test_build_frame_builds_checksum_for_mes(self):
        self.assertEqual(build_frame("MES?"), "MES?$48\r")

    def test_parse_incoming_frame_validates_checksum(self):
        parsed = parse_incoming_frame("MES?;STOP;$04")
        self.assertTrue(parsed.is_checksum_valid)
        self.assertEqual(parsed.checksum_calculated, "04")
        self.assertEqual(parsed.kind, "RESPONSE")

    def test_parse_incoming_frame_detects_invalid_checksum(self):
        parsed = parse_incoming_frame("MES?;STOP;$00")
        self.assertFalse(parsed.is_checksum_valid)

    def test_ack_can_have_bridge_dot_prefix(self):
        payload = ".Y1$"
        raw = payload + calculate_checksum_hex(payload)
        parsed = parse_incoming_frame(raw)
        self.assertTrue(parsed.is_checksum_valid)
        self.assertEqual(parsed.kind, "ACK")

    def test_nack_can_be_classified(self):
        payload = "N1$"
        raw = payload + calculate_checksum_hex(payload)
        parsed = parse_incoming_frame(raw)
        self.assertTrue(parsed.is_checksum_valid)
        self.assertEqual(parsed.kind, "NACK")


if __name__ == "__main__":
    unittest.main()


def test_psi_ack_with_x_address_is_ack():
    frame = parse_incoming_frame("\x13.Yx$23")
    assert frame.kind == "ACK"
    assert frame.is_checksum_valid


def test_psi_nack_with_x_address_is_nack():
    frame = parse_incoming_frame("\x13.Nx$18")
    assert frame.kind == "NACK"
    assert frame.is_checksum_valid


def test_command_expected_kind_keeps_tas_as_ack_even_if_response_requested():
    from secudata_web.client import SecutestLiveConnection
    client = SecutestLiveConnection.__new__(SecutestLiveConnection)
    assert client._determine_expected_kind("TAS!4", "RESPONSE") == "ACK_OR_NACK"


def test_command_expected_kind_keeps_idn_assignment_as_response():
    from secudata_web.client import SecutestLiveConnection
    client = SecutestLiveConnection.__new__(SecutestLiveConnection)
    assert client._determine_expected_kind("IDN!0", "auto") == "RESPONSE"
    assert client._determine_expected_kind("IDN1!1", "auto") == "RESPONSE"


def test_wer_checksum_uses_raw_cp437_bytes_for_ohm_symbol():
    from secudata_web.protocol import calculate_checksum_hex_bytes
    payload_bytes = b'XXXXXXXX;>+310.0M' + bytes([0xEA]) + b';>2.000M' + bytes([0xEA]) + b';0001$'
    raw = payload_bytes + calculate_checksum_hex_bytes(payload_bytes).encode('ascii')
    frame = parse_incoming_frame(raw)
    assert frame.is_checksum_valid
    assert 'Ω' in frame.payload_without_checksum
    assert frame.kind == 'RESPONSE'


def test_command_expected_kind_accepts_wer_response_or_nack():
    from secudata_web.client import SecutestLiveConnection
    client = SecutestLiveConnection.__new__(SecutestLiveConnection)
    assert client._determine_expected_kind('WER?', 'auto') == 'RESPONSE_OR_NACK'
    assert client._matches_expected(parse_incoming_frame('\x13.Nx$18'), 'RESPONSE_OR_NACK')


def test_command_expected_kind_accepts_addressed_rst_as_ack():
    from secudata_web.client import SecutestLiveConnection
    client = SecutestLiveConnection.__new__(SecutestLiveConnection)
    assert client._determine_expected_kind('RST1!3', 'auto') == 'ACK_OR_NACK'
    assert client._determine_expected_kind('RST0!4', 'auto') == 'ACK_OR_NACK'
