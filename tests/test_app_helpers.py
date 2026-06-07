import unittest

from starlette.exceptions import HTTPException

from secudata_web.app import (
    _as_optional_bool,
    _as_optional_int,
    _as_optional_rst_address,
    _parse_custom_commands,
    _reset_code_for_button,
)


class AppHelperTests(unittest.TestCase):
    def test_custom_command_parser_accepts_lines_and_pipe(self):
        raw = "MES? | TAS!4\n# Kommentar\nWER?\n\n"
        self.assertEqual(_parse_custom_commands(raw), ["MES?", "TAS!4", "WER?"])

    def test_optional_bool_accepts_ui_style_values(self):
        self.assertTrue(_as_optional_bool({"enabled": "true"}, "enabled"))
        self.assertFalse(_as_optional_bool({"enabled": "off"}, "enabled"))
        self.assertIsNone(_as_optional_bool({}, "enabled"))

    def test_optional_int_range_validation(self):
        self.assertEqual(_as_optional_int({"timeout": "2500"}, "timeout", minimum=200, maximum=30000), 2500)
        with self.assertRaises(HTTPException):
            _as_optional_int({"timeout": "100"}, "timeout", minimum=200, maximum=30000)
        with self.assertRaises(HTTPException):
            _as_optional_int({"timeout": "abc"}, "timeout", minimum=200, maximum=30000)

    def test_reset_mode_mapping_defaults_are_live_mapping(self):
        self.assertEqual(_reset_code_for_button({}, "SK_I_II"), "3")
        self.assertEqual(_reset_code_for_button({}, "LEITUNGEN"), "4")

    def test_rst_address_parser_accepts_plain_or_command_style_address(self):
        self.assertEqual(_as_optional_rst_address({"addr": "1"}, "addr"), "1")
        self.assertEqual(_as_optional_rst_address({"addr": "RST0!3"}, "addr"), "0")
        with self.assertRaises(HTTPException):
            _as_optional_rst_address({"addr": "-1"}, "addr")


if __name__ == "__main__":
    unittest.main()
