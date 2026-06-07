from __future__ import annotations

import asyncio
import time
from typing import Optional

from .client import SecutestLiveConnection
from .models import MesStatus, RawProtocolRecord
from .protocol import parse_esr_count, parse_mes_status, parse_psi_record, split_psi_records


class SecutestAcquisitionService:
    def __init__(self, client: SecutestLiveConnection) -> None:
        self.client = client

    async def send_raw(self, command: str):
        return await self.client.send_command(command)

    async def fetch_latest_psi_record(
        self,
        clear_after_read: bool = False,
        wait_timeout_ms: int = 15000,
        poll_interval_s: float = 1.0,
    ) -> RawProtocolRecord:
        """Wait briefly for PSI AutoStore, then fetch the newest WER? record.

        After NTZON;NULL the SECUTEST can need a few seconds to hand the record to
        the PSI AutoStore memory. During that window MES? may even time out once and
        ESR? can still report 0000 records. Therefore WER? must not be fired once
        and treated as a protocol failure immediately.
        """
        deadline = time.monotonic() + max(0, wait_timeout_ms) / 1000
        last_error: Optional[BaseException] = None

        while True:
            count = None
            try:
                count = await self.query_psi_store_count()
            except Exception as exc:
                last_error = exc

            if count is None or count > 0 or time.monotonic() >= deadline:
                try:
                    frame = await self.client.send_command("WER?", timeout_ms=max(10000, wait_timeout_ms))
                    records = split_psi_records(frame.payload_without_checksum)
                    latest = records[-1] if records else None
                    if latest is None:
                        raise RuntimeError("PSI-Speicher leer")
                    parsed = parse_psi_record(latest)
                    if clear_after_read:
                        await self.client.send_command("MEM!")
                    return parsed
                except Exception as exc:
                    last_error = exc
                    if "NACK" in str(exc).upper():
                        raise RuntimeError("PSI-Speicher leer oder AutoStore noch nicht abgeschlossen") from exc
                    if time.monotonic() >= deadline:
                        raise

            await asyncio.sleep(poll_interval_s)

        # unreachable, keeps type checkers calm
        raise RuntimeError(f"PSI-Datensatz nicht abrufbar: {last_error}")

    async def clear_psi_memory(self) -> None:
        await self.client.send_command("MEM!")

    def _looks_like_addressed_secutest_identity(self, payload: str) -> bool:
        upper = payload.upper()
        return payload.strip().upper().startswith("IDN1=1;") and "SECUTEST" in upper and "SECUTEST-PSI" not in upper

    async def quick_addressing_check(self, timeout_ms: int = 1400) -> dict[str, str]:
        """Verify current addressing with one command: IDN1?."""
        frame = await self.client.send_command("IDN1?", timeout_ms=timeout_ms)
        payload = frame.payload_without_checksum
        if not self._looks_like_addressed_secutest_identity(payload):
            raise RuntimeError(f"IDN1? lieferte keine adressierte SECUTEST-Identität: {payload}")
        return {"mode": "quick_check", "commands": "IDN1?", "secutest_identity": payload}

    async def compact_initialize_addressing(self, retries: int = 3, retry_delay_s: float = 0.35) -> dict[str, str]:
        """Set PSI=0 and SECUTEST=1 with the shortest robust command chain."""
        last_error: Optional[BaseException] = None
        for attempt in range(1, max(1, retries) + 1):
            try:
                psi_addressed = await self.client.send_command("IDN!0", timeout_ms=3000)
                secutest_addressed = await self.client.send_command("IDN1!1", timeout_ms=3000)
                secutest_identity = await self.client.send_command("IDN1?", timeout_ms=3000)
                if not self._looks_like_addressed_secutest_identity(secutest_identity.payload_without_checksum):
                    raise RuntimeError(f"SECUTEST-Identität nach Kurz-Init unplausibel: {secutest_identity.payload_without_checksum}")
                return {
                    "mode": "compact_init",
                    "attempt": str(attempt),
                    "commands": "IDN!0 → IDN1!1 → IDN1?",
                    "psi_addressed": psi_addressed.payload_without_checksum,
                    "secutest_addressed": secutest_addressed.payload_without_checksum,
                    "secutest_identity": secutest_identity.payload_without_checksum,
                }
            except Exception as exc:
                last_error = exc
                if attempt < retries:
                    await asyncio.sleep(retry_delay_s)
        raise RuntimeError(f"Kurze Adressierungs-Init fehlgeschlagen: {last_error}")

    async def ensure_addressing(self, retries: int = 3, retry_delay_s: float = 0.35) -> dict[str, str]:
        """Use one probe command if possible, initialize only if necessary."""
        try:
            return await self.quick_addressing_check()
        except Exception as quick_error:
            try:
                result = await self.compact_initialize_addressing(retries=retries, retry_delay_s=retry_delay_s)
                result["quick_check_error"] = str(quick_error)
                return result
            except Exception:
                result = await self.initialize_addressing(retries=1, retry_delay_s=retry_delay_s)
                result["quick_check_error"] = str(quick_error)
                result["mode"] = "full_init_fallback"
                return result

    async def initialize_addressing(self, retries: int = 5, retry_delay_s: float = 0.7) -> dict[str, str]:
        """Run the full legacy addressing handshake as fallback/diagnostic path."""
        last_error: Optional[BaseException] = None
        for attempt in range(1, max(1, retries) + 1):
            try:
                psi_before = await self.client.send_command("IDN?", timeout_ms=3000)
                psi_addressed = await self.client.send_command("IDN!0", timeout_ms=3000)
                psi_after = await self.client.send_command("IDN?", timeout_ms=3000)
                secutest_addressed = await self.client.send_command("IDN1!1", timeout_ms=3000)
                secutest_identity = await self.client.send_command("IDN1?", timeout_ms=3000)
                return {
                    "mode": "full_init",
                    "attempt": str(attempt),
                    "commands": "IDN? → IDN!0 → IDN? → IDN1!1 → IDN1?",
                    "psi_before": psi_before.payload_without_checksum,
                    "psi_addressed": psi_addressed.payload_without_checksum,
                    "psi_after": psi_after.payload_without_checksum,
                    "secutest_addressed": secutest_addressed.payload_without_checksum,
                    "secutest_identity": secutest_identity.payload_without_checksum,
                }
            except Exception as exc:
                last_error = exc
                if attempt < retries:
                    await asyncio.sleep(retry_delay_s)
        raise RuntimeError(f"Adressierungs-Check/Init fehlgeschlagen: {last_error}")

    async def reset_mode_and_initialize(self, rst_code: str | int, rst_address: str | int = 1) -> dict[str, str]:
        """Check addressing, reset one addressed virtual mode, then re-run addressing.

        ``RST!0`` is a full watchdog reset and behaves like a power cycle. For the
        post-save workflow we only restart the selected test mode. The RST command
        must be addressed explicitly, e.g. ``RST1!3`` for SK I/II or ``RST1!4`` for
        Leitung after the PSI/SECUTEST address handshake. After any RST, the address
        assignment is initialized again because the SECUTEST may have dropped it.
        """
        code_text = str(rst_code).strip().upper().removeprefix("RST!")
        if not code_text.isdigit() or not 1 <= int(code_text) <= 8:
            raise ValueError(f"Ungültige RST-Modusziffer: {rst_code!r}")

        address_text = str(rst_address).strip().upper()
        if address_text.startswith("RST") and "!" in address_text:
            address_text = address_text[3:].split("!", 1)[0]
        if not address_text.isdigit() or not 0 <= int(address_text) <= 90:
            raise ValueError(f"Ungültige RST-Adresse: {rst_address!r}")

        pre_init = await self.ensure_addressing(retries=3, retry_delay_s=0.35)
        reset_command = f"RST{int(address_text)}!{int(code_text)}"
        reset_frame = await self.client.send_command(reset_command, timeout_ms=3000)

        # After an addressed mode reset the SECUTEST/PSI pair may acknowledge the
        # RST immediately but not answer the first IDN? probe for a short moment.
        # Waiting here is still much faster than RST!0 and avoids burning two
        # command timeouts before the post-init handshake.
        settings = self.client.database.get_settings()
        settle_ms = int(settings.get("post_reset_settle_ms", "2200"))
        if settle_ms > 0:
            await asyncio.sleep(settle_ms / 1000)

        post_init = await self.ensure_addressing(retries=5, retry_delay_s=0.4)
        return {
            "pre_check": pre_init,
            "post_check": post_init,
            "pre_init": pre_init,
            "post_init": post_init,
            "reset": reset_frame.payload_without_checksum,
            "reset_command": reset_command,
            "secutest_identity": post_init.get("secutest_identity", ""),
            "psi_after": post_init.get("psi_after", ""),
        }

    async def reset_current_mode_and_initialize(self) -> dict[str, str]:
        """Backward-compatible manual fallback. Avoid full RST!0 by default."""
        return await self.reset_mode_and_initialize(3, 1)

    async def query_psi_store_count(self) -> Optional[int]:
        frame = await self.client.send_command("ESR?")
        return parse_esr_count(frame.payload_without_checksum)

    async def query_mes_status(self) -> MesStatus:
        frame = await self.client.send_command("MES?")
        return parse_mes_status(frame.payload_without_checksum)

    async def press_enter(self) -> None:
        await self.client.send_command("TAS!4")

    async def fetch_protocol_from_device(self) -> Optional[str]:
        frame = await self.client.send_command("PRO?")
        payload = frame.payload_without_checksum.strip()
        return payload or None

    async def fetch_measurement_value(self, measure_number: int) -> Optional[str]:
        frame = await self.client.send_command(f"WER?{measure_number}")
        payload = frame.payload_without_checksum.strip()
        return payload or None

    async def trigger_measurement_by_number(self, measure_number: int) -> None:
        await self.client.send_command(f"MES!{measure_number}")
