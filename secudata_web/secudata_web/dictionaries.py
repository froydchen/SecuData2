from __future__ import annotations

import re
from collections import Counter


DEVICE_ABBREVIATIONS = {
    "ABR": "Abstellraum",
    "AH": "Abzugshaube",
    "AL": "Anschlußleitung",
    "AV": "Aktenvernichter",
    "AB": "Anrufbeantworter",
    "AZ": "Arztzimmer",
    "AR": "Aufenthaltsraum",
    "ASM": "Aufschnittmaschine",
    "BW": "Badewanne",
    "BR": "Betriebsrat",
    "BL": "Bettlampe",
    "BB": "Bildbetrachter",
    "BRP": "Blu-Ray-Player",
    "BM": "Bohrmaschine",
    "BO": "Boiler",
    "BE": "Bügeleisen",
    "CD": "CD-Player",
    "PC": "Computer",
    "DP": "Diaprojektor",
    "DZ": "Dienstzimmer",
    "DST": "Dockingstation",
    "D": "Drucker",
    "DVD": "DVD-Player",
    "EK": "Eierkocher",
    "F": "Faxgerät",
    "TV": "Fernseher",
    "TFT": "Flachbildschirm",
    "GFS": "Gefrierschrank",
    "GFT": "Gefriertruhe",
    "GS": "Geschirrspüler",
    "GR": "Gruppenraum",
    "HT": "Haustechnik",
    "HLT": "Heimleitung",
    "HKP": "Heißklebepistole",
    "HK": "Heizkörper",
    "HL": "Heizlüfter",
    "IS": "Industriesauger",
    "KGK": "Kaltgerätekabel",
    "KO": "Kopierer",
    "KS": "Kühlschrank",
    "LG": "Ladegerät",
    "LK": "Lichterkette",
    "LT": "Laptop",
    "L": "Lüfter/Ventilator",
    "MW": "Mikrowelle",
    "M": "Monitor",
    "MEP": "Multifunktionsprinter",
    "MA": "Musikanlage",
    "NM": "Nähmaschine",
    "NT": "Netzteil",
    "NL": "Notlampe",
    "OHP": "Overheadprojektor",
    "PCL": "PC-Lautsprecher",
    "PB": "Pflegebett",
    "PDL": "Pflegedienstleitung",
    "PT": "Personal-Terminal",
    "PR": "Pflegeraum",
    "PWH": "Pflegewohnheim",
    "RM": "Rechenmaschine",
    "R": "Radio",
    "RW": "Radiowecker",
    "RA": "Rasierer",
    "REC": "Receiver",
    "RT": "Router",
    "SB": "Standbohrmaschine",
    "SC": "Scanner",
    "SM": "Schreibmaschine",
    "ST": "Schreibtisch",
    "SZ": "Schwesternzimmer",
    "SP": "Speedport",
    "SS": "Staubsauger",
    "SL": "Stehlampe",
    "SW": "Switch",
    "T-SAT": "Technisat",
    "KT": "Kabeltrommel",
    "KA": "Kaffeeautomat",
    "KM": "Kaffeemaschine",
    "TO": "Toaster",
    "UL": "Unterbaulampe",
    "V": "Verlängerung",
    "VCR": "Videorekorder",
    "WA": "Waage",
    "WTO": "Waffeltoaster",
    "WL": "Wandlampe",
    "WS": "Wärmeschrank",
    "WW": "Wärmewagen",
    "WT": "Wäschetrockner",
    "WM": "Waschmaschine",
    "WK": "Wasserkocher",
    "ZB": "Zahnbürste",
    "ZA": "Zimmerantenne",
    "1": "1-fach Verteiler",
    "T": "Telefon",
    "TW": "Tellerwagen",
    "TL": "Tischlampe",
    "TR": "Tischrechner",
    "URG": "Ultraschallreinigungsgerät",
    "OF": "Oberfräse",
    "LW": "Lockenwickler",
}

BASE_MANUFACTURER_DICTIONARY = {
    "D/MEP/KO/SC": ["HP", "Canon", "Epson", "Brother", "Kyocera", "Ricoh", "Xerox"],
    "PC/LT/M": ["Dell", "HP", "Lenovo", "Apple", "ASUS", "Acer", "Samsung"],
    "TV/TFT": ["Samsung", "LG", "Sony", "Philips", "Panasonic", "Hisense", "TCL"],
    "BRP/DVD/CD/REC": ["Sony", "Panasonic", "Pioneer", "Denon", "Yamaha", "Onkyo", "LG"],
    "RT/SW/SP": ["AVM", "TP-Link", "Netgear", "Cisco", "Ubiquiti", "Telekom", "D-Link"],
    "SS/IS": ["Kärcher", "Miele", "Bosch", "Siemens", "Nilfisk", "Makita", "Einhell"],
    "WM/WT": ["Miele", "Bosch", "Siemens", "AEG", "Bauknecht", "Beko", "Samsung"],
    "KS/GFS": ["Liebherr", "Bosch", "Siemens", "Miele", "AEG", "Samsung", "Beko"],
    "GS": ["Bosch", "Siemens", "Miele", "AEG", "Bauknecht", "Neff", "Beko"],
    "MW": ["Panasonic", "Samsung", "LG", "Bosch", "Sharp", "Whirlpool"],
    "KM": ["Jura", "De’Longhi", "Siemens", "Melitta", "Saeco", "Philips", "Nivona"],
    "TO/WK": ["WMF", "Bosch", "Siemens", "Philips", "Russell Hobbs", "Tefal", "Severin"],
    "BL/SL/TL/WL/UL/LK/NL": ["Philips", "Osram", "Paulmann", "Ikea", "EGLO", "Briloner"],
    "BM/SB/OF": ["Bosch", "Makita", "Metabo", "DeWalt", "Einhell", "Festool", "Milwaukee"],
    "RA/ZB": ["Philips", "Braun", "Oral-B", "Panasonic", "Remington"],
    "T/AB": ["Gigaset", "Panasonic", "AVM", "Telekom", "Yealink"],
    "MA/PCL": ["Sony", "JBL", "Bose", "Teufel", "Panasonic", "Yamaha", "Philips"],
    "AV": ["Fellowes", "HSM", "Leitz", "Dahle", "Rexel"],
    "NT/LG": ["Anker", "Belkin", "Hama", "Samsung", "Apple", "Aukey"],
    "PB": ["Burmeier", "Stiegelmeyer", "Wissner-Bosserhoff", "Invacare", "Hermann Bock"],
    "URG": ["Bandelin", "Elma", "Vevor", "EMAG", "Branson"],
}

BASE_DEVICE_TYPE_SUGGESTIONS = list(dict.fromkeys(value.strip() for value in DEVICE_ABBREVIATIONS.values() if value.strip()))

DEVICE_TYPE_ALIAS_MAP = {
    "D": "D/MEP/KO/SC", "DRUCKER": "D/MEP/KO/SC", "MEP": "D/MEP/KO/SC", "MFP": "D/MEP/KO/SC",
    "KO": "D/MEP/KO/SC", "KOPIERER": "D/MEP/KO/SC", "SC": "D/MEP/KO/SC", "SCANNER": "D/MEP/KO/SC",
    "PC": "PC/LT/M", "COMPUTER": "PC/LT/M", "LT": "PC/LT/M", "LAPTOP": "PC/LT/M", "M": "PC/LT/M", "MONITOR": "PC/LT/M",
    "TV": "TV/TFT", "FERNSEHER": "TV/TFT", "TFT": "TV/TFT", "FLACHBILDSCHIRM": "TV/TFT",
    "BRP": "BRP/DVD/CD/REC", "DVD": "BRP/DVD/CD/REC", "CD": "BRP/DVD/CD/REC", "REC": "BRP/DVD/CD/REC", "RECEIVER": "BRP/DVD/CD/REC",
    "RT": "RT/SW/SP", "ROUTER": "RT/SW/SP", "SW": "RT/SW/SP", "SWITCH": "RT/SW/SP", "SP": "RT/SW/SP", "SPEEDPORT": "RT/SW/SP",
    "SS": "SS/IS", "STAUBSAUGER": "SS/IS", "IS": "SS/IS", "INDUSTRIESAUGER": "SS/IS",
    "WM": "WM/WT", "WASCHMASCHINE": "WM/WT", "WT": "WM/WT", "TROCKNER": "WM/WT",
    "KS": "KS/GFS", "KÜHLSCHRANK": "KS/GFS", "GEFRIERSCHRANK": "KS/GFS", "GFS": "KS/GFS",
    "GS": "GS", "GESCHIRRSPÜLER": "GS", "MW": "MW", "MIKROWELLE": "MW", "KM": "KM", "KAFFEEMASCHINE": "KM",
    "TO": "TO/WK", "TOASTER": "TO/WK", "WK": "TO/WK", "WASSERKOCHER": "TO/WK",
    "BL": "BL/SL/TL/WL/UL/LK/NL", "SL": "BL/SL/TL/WL/UL/LK/NL", "TL": "BL/SL/TL/WL/UL/LK/NL", "WL": "BL/SL/TL/WL/UL/LK/NL",
    "UL": "BL/SL/TL/WL/UL/LK/NL", "LK": "BL/SL/TL/WL/UL/LK/NL", "NL": "BL/SL/TL/WL/UL/LK/NL", "LAMPEN": "BL/SL/TL/WL/UL/LK/NL",
    "BM": "BM/SB/OF", "SB": "BM/SB/OF", "OF": "BM/SB/OF", "ELEKTROWERKZEUG": "BM/SB/OF",
    "RA": "RA/ZB", "ZB": "RA/ZB", "RASIERER": "RA/ZB", "ZAHNBÜRSTE": "RA/ZB",
    "T": "T/AB", "AB": "T/AB", "TELEFON": "T/AB", "ANRUFBEANTWORTER": "T/AB",
    "MA": "MA/PCL", "PCL": "MA/PCL", "MUSIKANLAGE": "MA/PCL", "LAUTSPRECHER": "MA/PCL",
    "AV": "AV", "AKTENVERNICHTER": "AV", "NT": "NT/LG", "LG": "NT/LG", "NETZTEIL": "NT/LG", "LADEGERÄT": "NT/LG",
    "PB": "PB", "PFLEGEBETT": "PB", "URG": "URG", "ULTRASCHALLREINIGUNGSGERÄT": "URG",
}


def expand_device_abbreviations(value: str) -> str:
    tokens = [token for token in re.split(r"[^A-Za-z0-9ÄÖÜäöüß]+", value.strip()) if token]
    return " ".join(DEVICE_ABBREVIATIONS.get(token.upper(), token) for token in tokens)


def normalize_device_type_for_dictionary(value: str) -> str:
    normalized = value.strip()
    if not normalized:
        return ""
    direct = DEVICE_TYPE_ALIAS_MAP.get(normalized.upper())
    if direct:
        return direct
    expanded = expand_device_abbreviations(normalized)
    for token in [item for item in re.split(r"[^A-Za-zÄÖÜäöüß0-9]+", expanded) if item]:
        alias = DEVICE_TYPE_ALIAS_MAP.get(token.upper())
        if alias:
            return alias
    return normalized


def device_suggestion_matches(suggestion: str, user_input: str) -> bool:
    if not user_input.strip():
        return True
    if user_input.lower() in suggestion.lower():
        return True
    normalized = user_input.upper()
    abbreviations = [abbr for abbr, full_name in DEVICE_ABBREVIATIONS.items() if full_name.lower() == suggestion.lower()]
    if any(normalized in abbreviation.upper() for abbreviation in abbreviations):
        return True
    expanded = expand_device_abbreviations(user_input)
    return expanded.lower() in suggestion.lower()


def build_id_suggestions(ids: list[str], user_input: str, limit: int = 6) -> list[str]:
    normalized = user_input.strip().lower()
    unique: list[str] = ["-"]
    for value in ids:
        stripped = value.strip()
        if not stripped or stripped in unique:
            continue
        if normalized and normalized not in stripped.lower():
            continue
        unique.append(stripped)
        if len(unique) >= limit:
            break
    return unique


def build_device_suggestions(device_types: list[str], user_input: str, limit: int = 6) -> list[str]:
    normalized = user_input.strip()
    base = [value for value in BASE_DEVICE_TYPE_SUGGESTIONS if not normalized or device_suggestion_matches(value, normalized)]
    existing: list[str] = ["-"]
    for device_type in device_types:
        expanded = expand_device_abbreviations(device_type.strip())
        if not expanded:
            continue
        if normalized and not device_suggestion_matches(expanded, normalized):
            continue
        if expanded not in existing:
            existing.append(expanded)
    combined: list[str] = []
    for value in existing + base:
        if value not in combined:
            combined.append(value)
        if len(combined) >= limit:
            break
    return combined


def build_manufacturer_suggestions(
    metadata_rows: list[dict],
    geraeteart: str,
    user_input: str,
    limit: int = 6,
) -> list[str]:
    normalized_input = user_input.strip().lower()
    normalized_device = geraeteart.strip()
    lookup_key = normalize_device_type_for_dictionary(normalized_device)

    filtered = metadata_rows
    if normalized_device:
        filtered = [row for row in metadata_rows if row.get("geraeteart", "").strip().lower() == normalized_device.lower()]

    counter = Counter(
        row.get("hersteller", "").strip()
        for row in filtered
        if row.get("hersteller", "").strip() and row.get("hersteller", "").strip() != "-"
    )
    from_records = [name for name, _count in sorted(counter.items(), key=lambda item: (-item[1], item[0].lower()))]
    from_records = [name for name in from_records if not normalized_input or normalized_input in name.lower()]

    base = [name for name in BASE_MANUFACTURER_DICTIONARY.get(lookup_key, []) if not normalized_input or normalized_input in name.lower()]

    merged: list[str] = ["-"]
    for value in base + from_records:
        if value not in merged:
            merged.append(value)
        if len(merged) >= limit + 1:
            break
    return merged
