import unittest

from secudata_web.protocol import parse_mes_status, parse_psi_record, split_psi_records


class ParserTests(unittest.TestCase):
    def test_parse_single_wer_record(self):
        payload = "Prot=1001;12.03.2026;10:11:12;RPE;0,21;RISO;2,4;IPE;0,34;U;230;BESTANDEN;"
        records = split_psi_records(payload)
        self.assertEqual(len(records), 1)
        parsed = parse_psi_record(records[0])
        self.assertEqual(parsed.protocol_number, "1001")
        self.assertIsNotNone(parsed.parsed_measurement)
        self.assertAlmostEqual(parsed.parsed_measurement.rpe or 0.0, 0.21, places=4)

    def test_parse_multiple_wer_records(self):
        payload = "Prot=1001;RPE;0,21;BESTANDEN;;Prot=1002;RPE;0,45;FEHLER;"
        records = split_psi_records(payload)
        self.assertEqual(len(records), 2)
        last = parse_psi_record(records[-1])
        self.assertFalse(last.parsed_measurement.is_ok)

    def test_parse_mes_stop_status(self):
        status = parse_mes_status("Messung=21;STOP;")
        self.assertTrue(status.is_stopped)
        self.assertTrue(status.contains_measurement_21_stop)
        self.assertEqual(status.running_measurement_numbers, [21])

    def test_parse_pro_or_psi_header_indicators(self):
        parsed = parse_psi_record("BB;CC;Prot=42;RISO;5,00;IPE;0,12;U;229;BESTANDEN;")
        self.assertEqual(parsed.protocol_number, "42")
        self.assertTrue(parsed.parsed_measurement.is_ok)

    def test_finish_state_payload_remains_available(self):
        status = parse_mes_status("Messung=21;NTZON;NULL;$AA")
        self.assertIn("NTZON;NULL", status.raw_response)

    def test_split_realistic_psi_autostore_payload_without_destroying_empty_fields(self):
        payload = (
            "WERTEx=XXXXXXXX;000022000000500000000C000000060000220000;;;"
            "15.03.26;14:18:31;;;;;>+310.0Mê;>2.000Mê; +0527V ;+0500V ;"
            ";;;;;;; +0.000mA;<0.500mA;;;;;;;;;;;;;; +198.3V ;+253.0V ;;;"
            "15.03.26;14:19;tv;sony;haus3 u21;46753;;;;;;;;;;;;;;;0001$C7;"
            "XXXXXXXX;000022000000500000000C000000060000220000;;;"
            "15.03.26;14:18:31;;;;;>+310.0Mê;>2.000Mê; +0527V ;+0500V ;"
            ";;;;;;; +0.000mA;<0.500mA;;;;;;;;;;;;;; +198.3V ;+253.0V ;;;"
            "15.03.26;14:19;tv;sony;haus3 u21;46754;;;;;;;;;;;;;;;0002"
        )
        records = split_psi_records(payload)
        self.assertEqual(len(records), 2)
        last = parse_psi_record(records[-1])
        self.assertEqual(last.protocol_number, "0002")
        self.assertIsNotNone(last.parsed_metadata)
        self.assertEqual(last.parsed_metadata.id, "46754")
        self.assertEqual(last.parsed_metadata.geraeteart, "tv")
        self.assertEqual(last.parsed_metadata.hersteller, "sony")
        self.assertEqual(last.parsed_metadata.raum_etage, "haus3 u21")
        self.assertAlmostEqual(last.parsed_measurement.rins or 0.0, 310.0, places=3)
        self.assertAlmostEqual(last.parsed_measurement.ipe or 0.0, 0.0, places=3)
        self.assertAlmostEqual(last.parsed_measurement.u or 0.0, 198.3, places=3)


if __name__ == "__main__":
    unittest.main()


def test_parse_esr_count_returns_protocol_count_not_address_or_percent():
    from secudata_web.protocol import parse_esr_count
    assert parse_esr_count('ESR0=;034%;0070') == 70
    assert parse_esr_count('ESRx=;001%;0001') == 1
    assert parse_esr_count('ESR0=;000%;0000') == 0
