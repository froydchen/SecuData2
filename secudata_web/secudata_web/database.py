from __future__ import annotations

import json
import sqlite3
import threading
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

from .models import DraftInputState, FinalRecord, MeasurementMetadata, MeasurementRaw


class Database:
    def __init__(self, db_path: Path):
        self.db_path = db_path
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(str(self.db_path), check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._init_schema()

    def _init_schema(self) -> None:
        with self._lock, self._conn:
            self._conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS records (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at TEXT NOT NULL,
                    measurement_timestamp TEXT NOT NULL,
                    rpe REAL,
                    rins REAL,
                    ipe REAL,
                    u REAL,
                    is_ok INTEGER NOT NULL,
                    measurement_values TEXT NOT NULL DEFAULT '[]',
                    external_id TEXT NOT NULL DEFAULT '',
                    geraeteart TEXT NOT NULL DEFAULT '',
                    hersteller TEXT NOT NULL DEFAULT '',
                    raum_etage TEXT NOT NULL DEFAULT '',
                    kunde TEXT NOT NULL DEFAULT '',
                    typ_modell TEXT NOT NULL DEFAULT '',
                    seriennummer TEXT NOT NULL DEFAULT '',
                    pruefer TEXT NOT NULL DEFAULT '',
                    zusatztext TEXT NOT NULL DEFAULT ''
                );

                CREATE TABLE IF NOT EXISTS draft_input (
                    singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1),
                    external_id TEXT NOT NULL DEFAULT '',
                    geraeteart TEXT NOT NULL DEFAULT '',
                    hersteller TEXT NOT NULL DEFAULT '',
                    raum_etage TEXT NOT NULL DEFAULT '',
                    kunde TEXT NOT NULL DEFAULT '',
                    typ_modell TEXT NOT NULL DEFAULT '',
                    seriennummer TEXT NOT NULL DEFAULT '',
                    pruefer TEXT NOT NULL DEFAULT '',
                    zusatztext TEXT NOT NULL DEFAULT ''
                );

                CREATE TABLE IF NOT EXISTS settings (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS custom_buttons (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    commands TEXT NOT NULL DEFAULT ''
                );
                """
            )
            self._conn.execute(
                """
                INSERT OR IGNORE INTO draft_input (
                    singleton_id, external_id, geraeteart, hersteller, raum_etage,
                    kunde, typ_modell, seriennummer, pruefer, zusatztext
                ) VALUES (1, '', '', '', '', '', '', '', '', '')
                """
            )
            columns = {row["name"] for row in self._conn.execute("PRAGMA table_info(records)").fetchall()}
            if "measurement_values" not in columns:
                self._conn.execute("ALTER TABLE records ADD COLUMN measurement_values TEXT NOT NULL DEFAULT '[]'")

            defaults = {
                "host": "10.10.100.254",
                "port": "8899",
                "simulation_enabled": "0",
                "autosave_enabled": "1",
                "autosave_path": "data/records_autosave.xlsx",
                "poll_interval_ms": "300",
                "command_timeout_ms": "2500",
                # RST!0 is a full watchdog reset and is too slow for the field workflow.
                # Live device mapping: RSTx!3 = SK I/II, RSTx!4 = Leitungen.
                # The target address is configurable because some bridge setups answer
                # through PSI address 0, while the SECUTEST behind it is address 1.
                "rst_code_sk_i_ii": "3",
                "rst_code_leitungen": "4",
                "rst_target_address": "1",
                "post_reset_settle_ms": "2200",
            }
            for key, value in defaults.items():
                self._conn.execute("INSERT OR IGNORE INTO settings(key, value) VALUES (?, ?)", (key, value))

            # fix14 migration: fix13 shipped the two mode digits inverted.  If an
            # existing database still has exactly those old defaults, correct them
            # automatically.  User-edited values are left untouched.
            current_sk = self._conn.execute("SELECT value FROM settings WHERE key='rst_code_sk_i_ii'").fetchone()
            current_leitung = self._conn.execute("SELECT value FROM settings WHERE key='rst_code_leitungen'").fetchone()
            if current_sk and current_leitung and current_sk["value"] == "4" and current_leitung["value"] == "3":
                self._conn.execute("UPDATE settings SET value='3' WHERE key='rst_code_sk_i_ii'")
                self._conn.execute("UPDATE settings SET value='4' WHERE key='rst_code_leitungen'")

            for index in range(1, 7):
                self._conn.execute(
                    "INSERT OR IGNORE INTO custom_buttons(id, name, commands) VALUES (?, ?, ?)",
                    (index, f"USER {index}", ""),
                )

    def get_settings(self) -> dict[str, str]:
        with self._lock:
            rows = self._conn.execute("SELECT key, value FROM settings").fetchall()
        return {row["key"]: row["value"] for row in rows}

    def set_settings(self, updates: dict[str, Any]) -> dict[str, str]:
        with self._lock, self._conn:
            for key, value in updates.items():
                self._conn.execute(
                    "INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    (key, str(value)),
                )
        return self.get_settings()

    def get_draft(self) -> DraftInputState:
        with self._lock:
            row = self._conn.execute("SELECT * FROM draft_input WHERE singleton_id = 1").fetchone()
        assert row is not None
        return DraftInputState(
            id=row["external_id"],
            geraeteart=row["geraeteart"],
            hersteller=row["hersteller"],
            raum_etage=row["raum_etage"],
            kunde=row["kunde"],
            typ_modell=row["typ_modell"],
            seriennummer=row["seriennummer"],
            pruefer=row["pruefer"],
            zusatztext=row["zusatztext"],
        )

    def save_draft(self, draft: DraftInputState) -> DraftInputState:
        with self._lock, self._conn:
            self._conn.execute(
                """
                UPDATE draft_input SET
                    external_id=?, geraeteart=?, hersteller=?, raum_etage=?, kunde=?,
                    typ_modell=?, seriennummer=?, pruefer=?, zusatztext=?
                WHERE singleton_id=1
                """,
                (
                    draft.id,
                    draft.geraeteart,
                    draft.hersteller,
                    draft.raum_etage,
                    draft.kunde,
                    draft.typ_modell,
                    draft.seriennummer,
                    draft.pruefer,
                    draft.zusatztext,
                ),
            )
        return self.get_draft()

    def insert_record(self, measurement: MeasurementRaw, metadata: MeasurementMetadata) -> FinalRecord:
        created_at = datetime.now().isoformat(timespec="seconds")
        with self._lock, self._conn:
            cursor = self._conn.execute(
                """
                INSERT INTO records (
                    created_at, measurement_timestamp, rpe, rins, ipe, u, is_ok, measurement_values,
                    external_id, geraeteart, hersteller, raum_etage, kunde,
                    typ_modell, seriennummer, pruefer, zusatztext
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    created_at,
                    measurement.timestamp,
                    measurement.rpe,
                    measurement.rins,
                    measurement.ipe,
                    measurement.u,
                    1 if measurement.is_ok else 0,
                    json.dumps(measurement.values or [], ensure_ascii=False),
                    metadata.id,
                    metadata.geraeteart,
                    metadata.hersteller,
                    metadata.raum_etage,
                    metadata.kunde,
                    metadata.typ_modell,
                    metadata.seriennummer,
                    metadata.pruefer,
                    metadata.zusatztext,
                ),
            )
            record_id = int(cursor.lastrowid)
        return FinalRecord(id=record_id, created_at=created_at, measurement=measurement, metadata=metadata)

    def update_record(self, record_id: int, metadata: MeasurementMetadata) -> Optional[FinalRecord]:
        with self._lock, self._conn:
            exists = self._conn.execute("SELECT id FROM records WHERE id = ?", (record_id,)).fetchone()
            if exists is None:
                return None
            self._conn.execute(
                """
                UPDATE records SET
                    external_id=?, geraeteart=?, hersteller=?, raum_etage=?, kunde=?,
                    typ_modell=?, seriennummer=?, pruefer=?, zusatztext=?
                WHERE id=?
                """,
                (
                    metadata.id,
                    metadata.geraeteart,
                    metadata.hersteller,
                    metadata.raum_etage,
                    metadata.kunde,
                    metadata.typ_modell,
                    metadata.seriennummer,
                    metadata.pruefer,
                    metadata.zusatztext,
                    record_id,
                ),
            )
        return self.get_record(record_id)

    def get_record(self, record_id: int) -> Optional[FinalRecord]:
        with self._lock:
            row = self._conn.execute("SELECT * FROM records WHERE id = ?", (record_id,)).fetchone()
        return self._row_to_record(row) if row else None

    def get_records(self, sort: str = "chronological_desc") -> list[FinalRecord]:
        order_by = {
            "chronological": "created_at ASC, id ASC",
            "chronological_desc": "created_at DESC, id DESC",
            "id_asc": "external_id COLLATE NOCASE ASC, created_at DESC",
            "device_asc": "geraeteart COLLATE NOCASE ASC, created_at DESC",
            "manufacturer_asc": "hersteller COLLATE NOCASE ASC, created_at DESC",
            "room_asc": "raum_etage COLLATE NOCASE ASC, created_at DESC",
            "result_asc": "is_ok DESC, created_at DESC",
        }.get(sort, "created_at DESC, id DESC")
        with self._lock:
            rows = self._conn.execute(f"SELECT * FROM records ORDER BY {order_by}").fetchall()
        return [self._row_to_record(row) for row in rows]

    def metadata_rows(self) -> list[dict[str, str]]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT external_id, geraeteart, hersteller, raum_etage, kunde FROM records ORDER BY created_at DESC, id DESC"
            ).fetchall()
        return [
            {
                "id": row["external_id"],
                "geraeteart": row["geraeteart"],
                "hersteller": row["hersteller"],
                "raum_etage": row["raum_etage"],
                "kunde": row["kunde"],
            }
            for row in rows
        ]

    def get_custom_buttons(self) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._conn.execute("SELECT id, name, commands FROM custom_buttons ORDER BY id ASC").fetchall()
        return [{"id": row["id"], "name": row["name"], "commands": row["commands"]} for row in rows]

    def update_custom_button(self, button_id: int, name: str, commands: str) -> Optional[dict[str, Any]]:
        with self._lock, self._conn:
            exists = self._conn.execute("SELECT id FROM custom_buttons WHERE id = ?", (button_id,)).fetchone()
            if exists is None:
                return None
            self._conn.execute(
                "UPDATE custom_buttons SET name=?, commands=? WHERE id=?",
                (name.strip() or f"USER {button_id}", commands.strip(), button_id),
            )
        return next((button for button in self.get_custom_buttons() if button["id"] == button_id), None)

    def import_records(self, records: list[FinalRecord]) -> int:
        inserted = 0
        with self._lock, self._conn:
            for record in records:
                self._conn.execute(
                    """
                    INSERT INTO records (
                        created_at, measurement_timestamp, rpe, rins, ipe, u, is_ok, measurement_values,
                        external_id, geraeteart, hersteller, raum_etage, kunde,
                        typ_modell, seriennummer, pruefer, zusatztext
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        record.created_at,
                        record.measurement.timestamp,
                        record.measurement.rpe,
                        record.measurement.rins,
                        record.measurement.ipe,
                        record.measurement.u,
                        1 if record.measurement.is_ok else 0,
                        json.dumps(record.measurement.values or [], ensure_ascii=False),
                        record.metadata.id,
                        record.metadata.geraeteart,
                        record.metadata.hersteller,
                        record.metadata.raum_etage,
                        record.metadata.kunde,
                        record.metadata.typ_modell,
                        record.metadata.seriennummer,
                        record.metadata.pruefer,
                        record.metadata.zusatztext,
                    ),
                )
                inserted += 1
        return inserted

    def _row_to_record(self, row: sqlite3.Row) -> FinalRecord:
        try:
            measurement_values = json.loads(row["measurement_values"] or "[]")
            if not isinstance(measurement_values, list):
                measurement_values = []
        except Exception:
            measurement_values = []
        measurement = MeasurementRaw(
            rpe=row["rpe"],
            rins=row["rins"],
            ipe=row["ipe"],
            u=row["u"],
            timestamp=row["measurement_timestamp"],
            is_ok=bool(row["is_ok"]),
            values=measurement_values,
        )
        metadata = MeasurementMetadata(
            id=row["external_id"],
            geraeteart=row["geraeteart"],
            hersteller=row["hersteller"],
            raum_etage=row["raum_etage"],
            kunde=row["kunde"],
            typ_modell=row["typ_modell"],
            seriennummer=row["seriennummer"],
            pruefer=row["pruefer"],
            zusatztext=row["zusatztext"],
        )
        return FinalRecord(id=row["id"], created_at=row["created_at"], measurement=measurement, metadata=metadata)
