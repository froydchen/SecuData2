from __future__ import annotations

import asyncio
from datetime import datetime
from typing import Optional

from .database import Database
from .protocol import ParsedFrame, build_frame, parse_incoming_frame
from .state import AppState


class SecutestClientError(RuntimeError):
    pass


class SecutestLiveConnection:
    """Persistent TCP bridge connection with exactly one command in flight."""

    def __init__(self, database: Database, state: AppState) -> None:
        self.database = database
        self.state = state
        self.reader: Optional[asyncio.StreamReader] = None
        self.writer: Optional[asyncio.StreamWriter] = None
        self.rx_task: Optional[asyncio.Task] = None
        self.connected = False
        self.command_lock = asyncio.Lock()
        self.incoming: asyncio.Queue[ParsedFrame] = asyncio.Queue()
        # Raw CR-delimited RX lines are kept as well. WER? is special on the PSI:
        # large records may contain legacy symbols and internal record checksums.
        # The command layer therefore needs access to the exact bytes for checksum
        # diagnostics and to avoid re-parsing a damaged text representation.
        self.raw_lines: asyncio.Queue[bytes] = asyncio.Queue()
        self.rx_buffer = b""

    def _settings(self) -> dict[str, str]:
        return self.database.get_settings()

    async def connect(self) -> None:
        if self.connected:
            return
        settings = self._settings()
        host = settings.get("host", "10.10.100.254")
        port = int(settings.get("port", "8899"))
        timeout_ms = int(settings.get("command_timeout_ms", "2500"))
        try:
            self.reader, self.writer = await asyncio.wait_for(asyncio.open_connection(host, port), timeout=timeout_ms / 1000)
        except Exception as exc:
            await self.state.set_connection_status("DISCONNECTED", f"{host}:{port} – {exc}")
            await self.state.append_log(f"[TCP] Verbindung fehlgeschlagen: {host}:{port} – {exc}")
            raise SecutestClientError(f"TCP-Verbindung fehlgeschlagen: {host}:{port} – {exc}") from exc

        self.connected = True
        self.rx_buffer = b""
        self._drain_queues()
        self.rx_task = asyncio.create_task(self._rx_loop(), name="secutest-rx-loop")
        await self.state.set_connection_status("CONNECTED", f"{host}:{port}")
        await self.state.append_log(f"[TCP] CONNECTED {host}:{port}")

    async def disconnect(self) -> None:
        self.connected = False
        if self.rx_task:
            self.rx_task.cancel()
            try:
                await self.rx_task
            except asyncio.CancelledError:
                pass
            except Exception:
                pass
            self.rx_task = None
        if self.writer:
            try:
                self.writer.close()
                await self.writer.wait_closed()
            except Exception:
                pass
        self.reader = None
        self.writer = None
        self._drain_queues()
        await self.state.set_connection_status("DISCONNECTED", "")
        await self.state.append_log("[TCP] DISCONNECTED")

    async def reconnect(self) -> None:
        await self.disconnect()
        await self.connect()

    async def ensure_connected(self) -> None:
        if not self.connected or self.writer is None or self.reader is None:
            await self.connect()

    async def send_command(
        self,
        command_core: str,
        expected: str = "auto",
        timeout_ms: Optional[int] = None,
        allow_invalid_checksum: bool = False,
    ) -> ParsedFrame:
        command_core = command_core.strip()
        if not command_core:
            raise SecutestClientError("Leerer Befehl wurde verworfen.")

        async with self.command_lock:
            await self.ensure_connected()
            assert self.writer is not None
            timeout_ms = timeout_ms or int(self._settings().get("command_timeout_ms", "2500"))
            expected_kind = self._determine_expected_kind(command_core, expected)
            self._drain_queues()

            if command_core.upper() == "WER?":
                return await self._send_wer_raw_locked(command_core, timeout_ms, allow_invalid_checksum)

            framed = build_frame(command_core)
            try:
                self.writer.write(framed.encode("ascii", errors="ignore"))
                await self.writer.drain()
            except Exception as exc:
                await self.state.append_log(f"[TX-ERR] {command_core}: {exc}")
                await self.disconnect()
                raise SecutestClientError(f"Senden fehlgeschlagen: {exc}") from exc

            await self.state.append_log(f"TX >> {command_core}")
            await self.state.append_comm_log(
                {
                    "timestamp": datetime.now().isoformat(timespec="seconds"),
                    "direction": "TX",
                    "plain_text": command_core,
                    "framed_text": framed.rstrip("\r"),
                    "checksum_ok": True,
                    "note": "gesendet",
                }
            )

            deadline = asyncio.get_event_loop().time() + timeout_ms / 1000
            unexpected: list[str] = []
            while True:
                remaining = deadline - asyncio.get_event_loop().time()
                if remaining <= 0:
                    detail = ", ".join(unexpected[-3:]) if unexpected else "keine passenden Frames"
                    raise SecutestClientError(f"Timeout nach {timeout_ms} ms bei '{command_core}' ({detail}).")
                try:
                    frame = await asyncio.wait_for(self.incoming.get(), timeout=remaining)
                except asyncio.TimeoutError as exc:
                    detail = ", ".join(unexpected[-3:]) if unexpected else "keine passenden Frames"
                    raise SecutestClientError(f"Timeout nach {timeout_ms} ms bei '{command_core}' ({detail}).") from exc

                if not frame.is_checksum_valid and not allow_invalid_checksum:
                    unexpected.append(f"Checksum ungültig: {frame.normalized}")
                    await self.state.append_log(
                        f"[RX-WARN] Ungültige Checksumme verworfen: {frame.normalized} "
                        f"(empfangen={frame.checksum_received}, berechnet={frame.checksum_calculated})"
                    )
                    continue

                if self._matches_expected(frame, expected_kind):
                    if frame.kind == "NACK":
                        raise SecutestClientError(f"NACK auf '{command_core}': {frame.payload_without_checksum}")
                    return frame

                unexpected.append(f"{frame.kind}:{frame.payload_without_checksum}")
                await self.state.append_log(
                    f"[RX-UNSOLICITED] Für '{command_core}' nicht erwartet: {frame.payload_without_checksum}"
                )

    async def _rx_loop(self) -> None:
        assert self.reader is not None
        try:
            while self.connected:
                chunk = await self.reader.read(4096)
                if not chunk:
                    raise SecutestClientError("TCP-Verbindung wurde von der Gegenstelle geschlossen.")
                self.rx_buffer += chunk
                while b"\r" in self.rx_buffer:
                    raw, self.rx_buffer = self.rx_buffer.split(b"\r", 1)
                    raw = raw.strip(b"\n")
                    if not raw.strip():
                        continue
                    await self.raw_lines.put(raw)
                    frame = parse_incoming_frame(raw)
                    await self.state.append_log(f"RX << {frame.normalized}")
                    await self.state.append_comm_log(
                        {
                            "timestamp": datetime.now().isoformat(timespec="seconds"),
                            "direction": "RX",
                            "plain_text": frame.payload_without_checksum,
                            "framed_text": frame.normalized,
                            "checksum_ok": frame.is_checksum_valid,
                            "note": f"{frame.kind}; Checksum {'ok' if frame.is_checksum_valid else 'ungültig'}",
                        }
                    )
                    await self.incoming.put(frame)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            if self.connected:
                self.connected = False
                await self.state.set_connection_status("DISCONNECTED", str(exc))
                await self.state.append_log(f"[TCP] Verbindung beendet: {exc}")
        finally:
            self.reader = None
            self.writer = None

    def _determine_expected_kind(self, command_core: str, expected: str) -> str:
        """Return the expected frame class for a command.

        A few SECUTEST/PSI commands do not follow the naive rule "? = response,
        ! = ACK".  In particular IDN! address assignment returns an IDN*=...
        response, while TAS!/RST!/MEM!/MES! return ACK/NACK telegrams.  This
        command-aware mapping prevents old UI/user-sequence metadata from
        accidentally making TAS!4 wait for a RESPONSE and timing out on .Yx.
        """
        normalized = command_core.strip().upper()

        if self._is_response_assignment_command(normalized):
            return "RESPONSE"
        if self._is_ack_command(normalized):
            return "ACK_OR_NACK"
        if expected != "auto":
            return expected.upper()
        if normalized.startswith("WER") and "?" in normalized:
            return "RESPONSE_OR_NACK"
        if "?" in normalized:
            return "RESPONSE"
        if "!" in normalized:
            return "ACK_OR_NACK"
        return "RESPONSE"

    def _is_response_assignment_command(self, normalized_command: str) -> bool:
        return normalized_command.startswith("IDN") and "!" in normalized_command

    def _is_ack_command(self, normalized_command: str) -> bool:
        if normalized_command.startswith("RST") and "!" in normalized_command:
            return True
        return any(
            normalized_command.startswith(prefix)
            for prefix in ("TAS!", "MEM!", "MES!", "DAT!", "KOP!", "FUS!", "FOO!", "STA!", "CLA!")
        )

    def _matches_expected(self, frame: ParsedFrame, expected_kind: str) -> bool:
        if expected_kind == "ANY":
            return True
        if expected_kind == "RESPONSE":
            return frame.kind == "RESPONSE"
        if expected_kind == "ACK":
            return frame.kind == "ACK"
        if expected_kind == "NACK":
            return frame.kind == "NACK"
        if expected_kind == "ACK_OR_NACK":
            return frame.kind in {"ACK", "NACK"}
        if expected_kind == "RESPONSE_OR_NACK":
            return frame.kind in {"RESPONSE", "NACK"}
        return frame.kind == expected_kind

    async def _send_wer_raw_locked(
        self,
        command_core: str,
        timeout_ms: int,
        allow_invalid_checksum: bool = False,
    ) -> ParsedFrame:
        """Send PSI WER? and collect the raw CR-delimited response bytes.

        WER? is the one command where treating every incoming frame just like a
        small ACK/response is too fragile. Records can be long, include CP437
        symbols (Ω/µ), and contain internal ``$CS;`` separators when several PSI
        records are chained. This path waits on the raw line queue and validates
        the exact bytes that came from TCP before any pretty text conversion.
        """
        assert self.writer is not None
        framed = build_frame(command_core)
        try:
            self.writer.write(framed.encode("ascii", errors="ignore"))
            await self.writer.drain()
        except Exception as exc:
            await self.state.append_log(f"[TX-ERR] {command_core}: {exc}")
            await self.disconnect()
            raise SecutestClientError(f"Senden fehlgeschlagen: {exc}") from exc

        await self.state.append_log(f"TX >> {command_core}")
        await self.state.append_comm_log(
            {
                "timestamp": datetime.now().isoformat(timespec="seconds"),
                "direction": "TX",
                "plain_text": command_core,
                "framed_text": framed.rstrip("\r"),
                "checksum_ok": True,
                "note": "gesendet",
            }
        )

        deadline = asyncio.get_event_loop().time() + timeout_ms / 1000
        unexpected: list[str] = []
        while True:
            remaining = deadline - asyncio.get_event_loop().time()
            if remaining <= 0:
                detail = ", ".join(unexpected[-3:]) if unexpected else "keine WER-Rohantwort"
                self._drain_queue()  # remove mirrored parsed frames for consumed raw lines
                raise SecutestClientError(f"Timeout nach {timeout_ms} ms bei '{command_core}' ({detail}).")

            try:
                raw = await asyncio.wait_for(self.raw_lines.get(), timeout=remaining)
            except asyncio.TimeoutError as exc:
                detail = ", ".join(unexpected[-3:]) if unexpected else "keine WER-Rohantwort"
                self._drain_queue()
                raise SecutestClientError(f"Timeout nach {timeout_ms} ms bei '{command_core}' ({detail}).") from exc

            frame = parse_incoming_frame(raw)
            if frame.kind == "NACK":
                self._drain_queue()
                raise SecutestClientError(f"NACK auf '{command_core}': {frame.payload_without_checksum}")
            if frame.kind != "RESPONSE":
                unexpected.append(f"{frame.kind}:{frame.payload_without_checksum}")
                continue

            if frame.is_checksum_valid or allow_invalid_checksum:
                self._drain_queue()
                return frame

            hexdump = self._hex_preview(raw)
            unexpected.append(
                f"Checksum ungültig: empfangen={frame.checksum_received}, berechnet={frame.checksum_calculated}, hex={hexdump}"
            )
            await self.state.append_log(
                f"[RX-WARN] WER?-Checksumme ungültig: empfangen={frame.checksum_received}, "
                f"berechnet={frame.checksum_calculated}, bytes={len(raw)}, hex={hexdump}"
            )
            # Do not immediately return a damaged WER? frame. If the device sends a
            # follow-up line or a repeated full response within timeout, consume that
            # one instead. This avoids importing a visibly truncated record.

    def _hex_preview(self, raw: bytes, limit: int = 96) -> str:
        shown = raw[:limit].hex(" ").upper()
        if len(raw) > limit:
            shown += f" ... (+{len(raw) - limit} bytes)"
        return shown

    def _drain_queues(self) -> None:
        self._drain_queue()
        while True:
            try:
                self.raw_lines.get_nowait()
            except asyncio.QueueEmpty:
                break

    def _drain_queue(self) -> None:
        while True:
            try:
                self.incoming.get_nowait()
            except asyncio.QueueEmpty:
                break
