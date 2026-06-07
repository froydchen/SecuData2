from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Optional, Union

from .models import MesStatus, MeasurementMetadata, MeasurementRaw, RawProtocolRecord


FRAME_REGEX = re.compile(r"^(.*\$)([0-9A-Fa-f]{2})$", re.S)
FRAME_BYTES_REGEX = re.compile(rb"^(.*\$)([0-9A-Fa-f]{2})$", re.S)
ACK_REGEX = re.compile(r"^\.?Y[0-9A-Za-z]*$", re.I)
NACK_REGEX = re.compile(r"^\.?N[0-9A-Za-z]*$", re.I)
RESPONSE_PREFIX_REGEX = re.compile(r"^(?:WERTE?|PROTOKOLL|PRX)\d*\s*=\s*", re.I)
DATE_REGEX = re.compile(r"^\s*\d{2}[./-]\d{2}[./-]\d{2,4}\s*$")
TIME_REGEX = re.compile(r"^\s*\d{2}:\d{2}(?::\d{2})?\s*$")
NUMERIC_REGEX = re.compile(r"[-+]?\d+(?:[.,]\d+)?")
INTERNAL_RECORD_SEPARATOR_REGEX = re.compile(r"\$[0-9A-Fa-f]{2};")

# The PSI / SECUTEST data stream is byte based.  WER? records may contain
# non-ASCII measurement symbols, for example the Ω sign as CP437 byte 0xEA.
# If those bytes are decoded with errors="ignore" before checksum validation,
# the checksum becomes wrong although the device frame is valid.
RX_TEXT_ENCODING = "cp437"


S2N_PSI_MEASUREMENT_LABELS = {
    6: "MW R-SL", 7: "GW R-SL", 8: "MW ΔR-SL", 9: "GW ΔR-SL",
    10: "MW R-ISO", 11: "GW R-ISO", 12: "MW U-ISO", 13: "GW U-ISO",
    14: "MW DI-STR", 15: "GW DI-STR", 16: "MW UAC", 17: "GW UAC",
    18: "MW UDC", 19: "GW UDC", 20: "MW EGA", 21: "GW EGA",
    22: "MW EPA", 23: "GW EPA", 24: "MW EA", 25: "GW EA",
    26: "MW EA SFC", 27: "GW EA SFC", 28: "MW GA", 29: "GW GA",
    30: "MW GA SFC", 31: "GW GA SFC", 32: "MW PA AC", 33: "GW PA AC",
    34: "MW PA AC SFC", 35: "GW PA AC SFC", 36: "MW PA DC", 37: "GW PA DC",
    38: "MW PA DC SFC", 39: "GW PA DC SFC", 40: "MW PH AC", 41: "GW PH AC",
    42: "MW PH AC SFC", 43: "GW PH AC SFC", 44: "MW PH DC", 45: "GW PH DC",
    46: "MW PH DC SFC", 47: "GW PH DC SFC", 48: "MW UHV", 49: "GW UHV",
    50: "MW PSpg", 51: "GW Ubez",
}

OLD_0701_MEASUREMENT_LABELS = {
    2: "MW RSL", 3: "GW RSL", 4: "MW RISO", 5: "GW RISO",
    6: "MW UISO", 7: "GW UISO", 8: "MW IEA", 9: "GW IEA",
    10: "MW ΔI", 11: "GW ΔI",
}

EXPLICIT_MEASUREMENT_LABELS = {
    "RPE": "RPE", "RSL": "RSL", "RSLAC": "RSL AC", "RSLK": "RSL Klemme",
    "RISO": "RISO", "RINS": "RINS", "IPE": "IPE", "IEA": "IEA",
    "ILEAK": "Ableitstrom", "U": "U", "UISO": "UISO",
}


@dataclass
class ParsedFrame:
    raw: str
    normalized: str
    payload_without_checksum: str
    checksum_received: Optional[str]
    checksum_calculated: str
    is_checksum_valid: bool
    kind: str
    raw_bytes: Optional[bytes] = None
    payload_bytes_including_dollar: Optional[bytes] = None

    def to_dict(self) -> dict:
        return {
            "raw": self.raw,
            "normalized": self.normalized,
            "payload_without_checksum": self.payload_without_checksum,
            "checksum_received": self.checksum_received,
            "checksum_calculated": self.checksum_calculated,
            "is_checksum_valid": self.is_checksum_valid,
            "kind": self.kind,
        }


def calculate_checksum_hex(payload_including_dollar: str) -> str:
    total = 0
    for char in payload_including_dollar:
        total = (total + ord(char)) & 0xFF
    return f"{total:02X}"


def calculate_checksum_hex_bytes(payload_including_dollar: bytes) -> str:
    return f"{sum(payload_including_dollar) & 0xFF:02X}"


def build_frame(command_core: str) -> str:
    payload = command_core + "$"
    checksum = calculate_checksum_hex(payload)
    return payload + checksum + "\r"


def strip_framing_control_chars(value: str) -> str:
    control = {"\x02", "\x03", "\x11", "\x13", "\x00", "\r", "\n"}
    start = 0
    end = len(value)
    while start < end and value[start] in control:
        start += 1
    while end > start and value[end - 1] in control:
        end -= 1
    return value[start:end]


def strip_framing_control_bytes(value: bytes) -> bytes:
    control = {0x02, 0x03, 0x11, 0x13, 0x00, 0x0D, 0x0A}
    start = 0
    end = len(value)
    while start < end and value[start] in control:
        start += 1
    while end > start and value[end - 1] in control:
        end -= 1
    return value[start:end]


def decode_rx_bytes(value: bytes) -> str:
    return value.decode(RX_TEXT_ENCODING, errors="replace")


def parse_incoming_frame(raw: Union[str, bytes]) -> ParsedFrame:
    if isinstance(raw, (bytes, bytearray)):
        return _parse_incoming_frame_bytes(bytes(raw))
    return _parse_incoming_frame_text(raw)


def _parse_incoming_frame_text(raw: str) -> ParsedFrame:
    normalized = strip_framing_control_chars(raw)
    match = FRAME_REGEX.match(normalized)

    if match:
        payload = match.group(1)
        checksum_received = match.group(2).upper()
    else:
        if "$" in normalized:
            payload = normalized.rsplit("$", 1)[0] + "$"
        else:
            payload = normalized
        checksum_received = None

    checksum_calculated = calculate_checksum_hex(payload)
    payload_without_checksum = payload[:-1] if payload.endswith("$") else payload
    is_valid = checksum_received is not None and checksum_received == checksum_calculated
    kind = classify_payload(payload_without_checksum)

    return ParsedFrame(
        raw=raw,
        normalized=normalized,
        payload_without_checksum=payload_without_checksum,
        checksum_received=checksum_received,
        checksum_calculated=checksum_calculated,
        is_checksum_valid=is_valid,
        kind=kind,
    )


def _parse_incoming_frame_bytes(raw: bytes) -> ParsedFrame:
    normalized_bytes = strip_framing_control_bytes(raw)
    match = FRAME_BYTES_REGEX.match(normalized_bytes)

    if match:
        payload_bytes = match.group(1)
        checksum_received = match.group(2).decode("ascii", errors="replace").upper()
    else:
        if b"$" in normalized_bytes:
            payload_bytes = normalized_bytes.rsplit(b"$", 1)[0] + b"$"
        else:
            payload_bytes = normalized_bytes
        checksum_received = None

    checksum_calculated = calculate_checksum_hex_bytes(payload_bytes)
    payload_without_checksum_bytes = payload_bytes[:-1] if payload_bytes.endswith(b"$") else payload_bytes
    normalized = decode_rx_bytes(normalized_bytes)
    payload_without_checksum = decode_rx_bytes(payload_without_checksum_bytes)
    is_valid = checksum_received is not None and checksum_received == checksum_calculated
    kind = classify_payload(payload_without_checksum)

    return ParsedFrame(
        raw=decode_rx_bytes(raw),
        normalized=normalized,
        payload_without_checksum=payload_without_checksum,
        checksum_received=checksum_received,
        checksum_calculated=checksum_calculated,
        is_checksum_valid=is_valid,
        kind=kind,
        raw_bytes=raw,
        payload_bytes_including_dollar=payload_bytes,
    )


def classify_payload(payload: str) -> str:
    candidate = payload.strip()
    if ACK_REGEX.match(candidate):
        return "ACK"
    if NACK_REGEX.match(candidate):
        return "NACK"
    return "RESPONSE"


def split_psi_records(payload: str) -> list[str]:
    """Split a PSI WER? payload into complete records without destroying empty fields.

    Real PSI records contain many consecutive semicolons as *empty field placeholders*.
    They must never be used as record separators. A multi-record WER? response instead
    separates records after an internal ``$CS;`` checksum marker. The outer frame parser
    strips the checksum of the final record, therefore the last chunk intentionally does
    not need its own ``$CS`` suffix here.
    """

    cleaned = strip_framing_control_chars(payload).strip()
    if not cleaned:
        return []

    cleaned = RESPONSE_PREFIX_REGEX.sub("", cleaned, count=1).strip()
    if not cleaned:
        return []

    records: list[str] = []
    cursor = 0
    for match in INTERNAL_RECORD_SEPARATOR_REGEX.finditer(cleaned):
        record = cleaned[cursor:match.start()].strip(" ;\r\n")
        if record:
            records.append(record)
        cursor = match.end()

    tail = cleaned[cursor:].strip(" ;\r\n")
    if tail:
        records.append(tail)

    if len(records) > 1:
        return records

    # Compatibility fallback for old synthetic tests and ad-hoc debug payloads.
    # This branch is deliberately conservative: real PSI records with many ``;;``
    # must remain untouched unless a new record header is clearly visible.
    fallback = re.split(r";;(?=(?:Prot\s*=|[A-Za-z0-9_\-]{2,};[0-9A-Fa-f]{12,}))", cleaned, flags=re.I)
    return [part.strip(" ;\r\n") for part in fallback if part.strip(" ;\r\n")]


def parse_mes_status(payload: str) -> MesStatus:
    normalized = payload.strip()
    fields = normalized.split(";")
    running_numbers = [int(value) for value in re.findall(r"Messung\s*=\s*(\d+)", normalized, re.I)]
    is_stopped = "STOP" in normalized.upper()
    contains_21_stop = bool(re.search(r"Messung\s*=\s*21\s*;\s*STOP", normalized, re.I))
    return MesStatus(
        raw_response=normalized,
        connection_flags_raw=fields[0] if fields and fields[0].strip() else None,
        running_measurement_numbers=running_numbers,
        is_stopped=is_stopped,
        contains_measurement_21_stop=contains_21_stop,
    )


def parse_esr_count(payload: str) -> Optional[int]:
    """Return the PSI protocol count from an ESR? response.

    Real PSI responses look like ``ESR0=;034%;0070`` where ``034`` is the
    memory usage in percent and ``0070`` is the number of stored protocols.
    A naive first-number parser would accidentally return the address digit in
    ``ESR0`` and would therefore always see ``0`` records.  Very helpful, in
    the same way a locked door is technically also a sorting algorithm.
    """
    normalized = payload.strip()
    match = re.search(r"ESR\w*\s*=\s*;?\s*(\d+)\s*%\s*;\s*(\d+)", normalized, re.I)
    if match:
        return int(match.group(2))

    fields = [part.strip() for part in normalized.split(";") if part.strip()]
    for field in reversed(fields):
        if re.fullmatch(r"\d+", field):
            return int(field)
    return None


def parse_psi_record(raw_record: str) -> RawProtocolRecord:
    cleaned_record = RESPONSE_PREFIX_REGEX.sub("", raw_record.strip(), count=1).strip(" ;\r\n")
    fields = cleaned_record.split(";") if cleaned_record else []
    protocol_number = _find_protocol_number(cleaned_record, fields)
    protocol_date = _find_date(cleaned_record)
    protocol_time = _find_time(cleaned_record)
    measurement = _to_measurement_raw(cleaned_record, fields)
    metadata = _to_metadata(fields)
    return RawProtocolRecord(
        source="PSI_AUTOSTORE_PULL",
        raw_record=cleaned_record,
        protocol_number=protocol_number,
        protocol_date=protocol_date,
        protocol_time=protocol_time,
        parsed_measurement=measurement,
        parsed_metadata=metadata,
        raw_fields=fields,
    )


def _find_protocol_number(raw: str, fields: list[str]) -> Optional[str]:
    explicit = _find_field_value(raw, "Protokoll", "Prot", "Nr")
    if explicit:
        return explicit
    for field in reversed(fields[-8:]):
        value = field.strip()
        match = re.match(r"^(\d{4,})", value)
        if match:
            return match.group(1)
    return None


def _to_metadata(fields: list[str]) -> Optional[MeasurementMetadata]:
    start = _find_tail_metadata_start(fields)
    if start is None:
        return None

    def at(offset: int) -> str:
        index = start + offset
        return fields[index].strip() if index < len(fields) else ""

    geraeteart = at(2)
    hersteller = at(3)
    raum_etage = at(4)  # PSI field "Type" is used as room / location in this workflow.
    external_id = at(5)

    if not any([geraeteart, hersteller, raum_etage, external_id]):
        return None

    return MeasurementMetadata(
        id=external_id,
        geraeteart=geraeteart,
        hersteller=hersteller,
        raum_etage=raum_etage,
    )


def _find_tail_metadata_start(fields: list[str]) -> Optional[int]:
    matches: list[int] = []
    for index in range(max(0, len(fields) - 40), max(0, len(fields) - 1)):
        if DATE_REGEX.match(fields[index]) and TIME_REGEX.match(fields[index + 1]):
            matches.append(index)
    return matches[-1] if matches else None


def _to_measurement_raw(raw_record: str, fields: list[str]) -> MeasurementRaw:
    explicit = _parse_explicit_labeled_measurements(raw_record)
    positional = _parse_positional_measurements(fields)

    rpe = explicit.get("rpe") if explicit.get("rpe") is not None else positional.get("rpe")
    rins = explicit.get("rins") if explicit.get("rins") is not None else positional.get("rins")
    ipe = explicit.get("ipe") if explicit.get("ipe") is not None else positional.get("ipe")
    u = explicit.get("u") if explicit.get("u") is not None else positional.get("u")

    upper = raw_record.upper()
    has_protocol_header = bool(fields and len(fields) > 1 and re.fullmatch(r"[0-9A-F]{12,}", fields[1].strip(), re.I))
    failed = any(token in upper for token in ["NICHT BEST", "FAILED", "NIO", "FEHLER", "NOT OK"])
    value_failure = all(value is None for value in [rpe, rins, ipe, u])
    is_ok = not failed and not (has_protocol_header and value_failure)
    values = _measurement_items_from_record(raw_record, fields)

    return MeasurementRaw.now(rpe=rpe, rins=rins, ipe=ipe, u=u, is_ok=is_ok, values=values)



def _measurement_items_from_record(raw_record: str, fields: list[str]) -> list[dict[str, str]]:
    positional = _positional_measurement_items(fields)
    if positional:
        return positional
    return _explicit_measurement_items(raw_record)


def _clean_measurement_text(value: str) -> str:
    return re.sub(r"\s+", " ", value.strip())


def _measurement_item(label: str, value: str, index: int | None = None) -> dict[str, str]:
    item = {"label": label, "value": _clean_measurement_text(value)}
    if index is not None:
        item["field"] = str(index)
    return item


def _positional_measurement_items(fields: list[str]) -> list[dict[str, str]]:
    if len(fields) < 3:
        return []
    metadata_start = _find_tail_metadata_start(fields)
    measurement_end = metadata_start if metadata_start is not None else len(fields)
    protocol_marker = fields[1].strip() if len(fields) > 1 else ""

    if re.fullmatch(r"[0-9A-F]{24,}", protocol_marker, re.I):
        label_map = S2N_PSI_MEASUREMENT_LABELS
    elif re.fullmatch(r"[0-9A-F]{16}", protocol_marker, re.I):
        label_map = OLD_0701_MEASUREMENT_LABELS
    else:
        return []

    items: list[dict[str, str]] = []
    for index in range(2, measurement_end):
        raw_value = fields[index] if index < len(fields) else ""
        value = _clean_measurement_text(raw_value)
        if not value:
            continue
        label = label_map.get(index)
        if not label:
            continue
        items.append(_measurement_item(label, value, index))
    return items


def _explicit_measurement_items(raw_record: str) -> list[dict[str, str]]:
    fields = [_clean_measurement_text(field) for field in raw_record.split(";")]
    items: list[dict[str, str]] = []
    used_positions: set[int] = set()
    normalized_label_map = {
        label.replace("_", "").replace("-", "").upper(): display
        for label, display in EXPLICIT_MEASUREMENT_LABELS.items()
    }
    for index, field in enumerate(fields):
        normalized = field.replace("_", "").replace("-", "").upper()
        display = normalized_label_map.get(normalized)
        if not display:
            continue
        for value_index, candidate in enumerate(fields[index + 1:index + 5], start=index + 1):
            if value_index in used_positions:
                continue
            if not candidate or _parse_numeric_token(candidate) is None:
                continue
            items.append(_measurement_item(display, candidate, value_index))
            used_positions.add(value_index)
            break
    return items


def _parse_explicit_labeled_measurements(raw_record: str) -> dict[str, Optional[float]]:
    return {
        "rpe": _find_measurement_value(raw_record, "RPE", "RSLAC", "RSLK", "MWRPE", "RSL"),
        "rins": _find_measurement_value(raw_record, "RISO", "RINS", "MWRISO"),
        "ipe": _find_measurement_value(raw_record, "IPE", "ILEAK", "MWIPE", "IEA"),
        "u": _find_voltage_value(raw_record),
    }


def _parse_positional_measurements(fields: list[str]) -> dict[str, Optional[float]]:
    metadata_start = _find_tail_metadata_start(fields)
    measurement_end = metadata_start if metadata_start is not None else len(fields)
    protocol_marker = fields[1].strip() if len(fields) > 1 else ""

    # Older 0701/0702 PSI records: values start directly at field 2.
    # PHOENIX;BBCCDDEEFFGGHHII;RSL_MW;RSL_GW;RISO_MW;RISO_GW;UISO_MW;...
    if re.fullmatch(r"[0-9A-F]{16}", protocol_marker, re.I) and measurement_end > 8:
        return {
            "rpe": _parse_numeric_token(fields[2]) if len(fields) > 2 else None,
            "rins": _parse_numeric_token(fields[4]) if len(fields) > 4 else None,
            "ipe": _parse_numeric_token(fields[8]) if len(fields) > 8 else None,
            "u": _pick_mains_voltage(fields[2:measurement_end]),
        }

    # SI/S2N+10-style PSI records: fixed SECUTEST measurement table begins after
    # Name, bitfield, ID_Nr, ID-String2, Datum, Zeit.
    rpe = _parse_numeric_token(fields[6]) if len(fields) > 6 else None
    rins = _parse_numeric_token(fields[10]) if len(fields) > 10 else None
    block = fields[6:measurement_end] if measurement_end > 6 else fields
    ipe = _pick_first_current(block)
    u = _pick_mains_voltage(block)
    return {"rpe": rpe, "rins": rins, "ipe": ipe, "u": u}


def _find_measurement_value(raw: str, *labels: str) -> Optional[float]:
    label_set = {label.upper() for label in labels}
    fields = [field.strip() for field in raw.split(";")]
    found: list[float] = []

    for index, field in enumerate(fields):
        normalized = field.upper().replace("_", "").replace("-", "")
        if normalized not in {label.replace("_", "").replace("-", "") for label in label_set}:
            continue
        for candidate in fields[index + 1:index + 5]:
            parsed = _parse_numeric_token(candidate)
            if parsed is not None:
                found.append(parsed)
                break
    return found[-1] if found else None


def _find_voltage_value(raw: str) -> Optional[float]:
    fields = [field.strip() for field in raw.split(";")]
    return _pick_mains_voltage(fields)


def _pick_first_current(fields: list[str]) -> Optional[float]:
    for field in fields:
        upper = field.upper()
        if "MA" not in upper and "ΜA" not in upper and "µA" not in field and "μA" not in field:
            continue
        parsed = _parse_numeric_token(field)
        if parsed is not None:
            # Prefer real measured values over obvious limit placeholders where possible.
            if not field.lstrip().startswith("<") and not field.lstrip().startswith(">"):
                return parsed
    for field in fields:
        upper = field.upper()
        if "MA" in upper:
            parsed = _parse_numeric_token(field)
            if parsed is not None:
                return parsed
    return None


def _pick_mains_voltage(fields: list[str]) -> Optional[float]:
    # Prefer pairs where the following field is the familiar +253.0 V upper limit.
    for index in range(len(fields) - 1):
        current = fields[index]
        following = fields[index + 1]
        candidate = _parse_numeric_token(current)
        limit = _parse_numeric_token(following)
        if candidate is None or limit is None:
            continue
        if "V" in current.upper() and "V" in following.upper() and 100 <= candidate <= 300 and 240 <= limit <= 260:
            return candidate

    for field in reversed(fields):
        parsed = _parse_numeric_token(field)
        if parsed is None:
            continue
        if "V" in field.upper() and 100 <= parsed <= 300:
            return parsed
    return None


def _find_field_value(raw: str, *labels: str) -> Optional[str]:
    for label in labels:
        match = re.search(rf"{re.escape(label)}\s*=\s*([^;\r\n]+)", raw, re.I)
        if match:
            value = match.group(1).strip()
            if value:
                return value
    return None


def _find_date(raw: str) -> Optional[str]:
    match = re.search(r"\b(\d{2}[./-]\d{2}[./-]\d{2,4})\b", raw)
    return match.group(1) if match else None


def _find_time(raw: str) -> Optional[str]:
    match = re.search(r"\b(\d{2}:\d{2}(?::\d{2})?)\b", raw)
    return match.group(1) if match else None


def _parse_numeric_token(value: str) -> Optional[float]:
    match = NUMERIC_REGEX.search(value.replace(",", "."))
    if not match:
        return None
    try:
        return float(match.group(0).replace(",", "."))
    except ValueError:
        return None
