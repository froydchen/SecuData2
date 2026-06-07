from __future__ import annotations

import asyncio
import re
from dataclasses import dataclass
from typing import Optional

from .acquisition import SecutestAcquisitionService
from .database import Database
from .models import MeasurementRaw, RawProtocolRecord, SequenceResult, SequenceStepResult
from .state import AppState


@dataclass
class AdaptiveSkState:
    auto_enters: int = 0
    repeat_count: int = 0
    stop_repeat_count: int = 0
    ek_repeat_count: int = 0
    phase: str = "idle"
    last_mes: str = ""
    last_mes_full: str = ""
    rslac_seen: bool = False
    last_rslk_post_counter: Optional[int] = None
    rslk_post_descending_hits: int = 0


class MeasurementSequenceService:
    STABLE_TARGET = 2
    MAX_AUTO_ENTERS = 14
    RSLK_DESC_HITS_NEEDED = 3

    def __init__(self, acquisition: SecutestAcquisitionService, database: Database, state: AppState) -> None:
        self.acquisition = acquisition
        self.database = database
        self.state = state
        self.last_imported_measurement: Optional[MeasurementRaw] = None
        self.last_imported_raw_protocol: Optional[RawProtocolRecord] = None

    def _simulation_enabled(self) -> bool:
        return self.database.get_settings().get("simulation_enabled", "0") == "1"

    def _poll_interval_seconds(self) -> float:
        return max(0.05, int(self.database.get_settings().get("poll_interval_ms", "300")) / 1000)

    def consume_last_imported_measurement(self) -> Optional[MeasurementRaw]:
        value = self.last_imported_measurement
        self.last_imported_measurement = None
        return value

    def consume_last_imported_raw_protocol(self) -> Optional[RawProtocolRecord]:
        value = self.last_imported_raw_protocol
        self.last_imported_raw_protocol = None
        return value

    async def run_leitungen_sequence(self) -> SequenceResult:
        if self._simulation_enabled():
            return await self._run_simulated_sequence("Leitungen messen")
        return await self._run_simple_enter_sequence(
            sequence_name="Leitungen messen",
            enter_presses=2,
            clear_psi_after_read=False,
        )

    async def run_sk_sequence(self) -> SequenceResult:
        if self._simulation_enabled():
            return await self._run_simulated_sequence("SK I/II")
        return await self._run_adaptive_sk_sequence("SK I/II")

    async def _run_simple_enter_sequence(
        self,
        sequence_name: str,
        enter_presses: int,
        clear_psi_after_read: bool,
    ) -> SequenceResult:
        self.last_imported_measurement = None
        self.last_imported_raw_protocol = None
        steps: list[SequenceStepResult] = [
            SequenceStepResult("start", True, f"[SEQ] Sequenz {sequence_name} gestartet")
        ]
        final_status_raw: Optional[str] = None

        try:
            before = await self.acquisition.query_mes_status()
            final_status_raw = before.raw_response
            steps.append(SequenceStepResult("status_initial", True, "[SEQ] Initialstatus gelesen", before.raw_response))
        except Exception as exc:
            steps.append(SequenceStepResult("status_initial", False, f"[SEQ] Initialstatus nicht verfügbar: {exc}"))
            before = None

        changed = False
        for index in range(enter_presses):
            try:
                await self.acquisition.press_enter()
                steps.append(SequenceStepResult(f"enter_{index + 1}", True, f"[SEQ] ENTER {index + 1}/{enter_presses} gesendet"))
                status = await self.acquisition.query_mes_status()
                final_status_raw = status.raw_response
                steps.append(SequenceStepResult(f"status_after_enter_{index + 1}", True, "[SEQ] Status nach ENTER gelesen", status.raw_response))
                if before is not None and status.raw_response != before.raw_response:
                    changed = True
                    break
            except Exception as exc:
                steps.append(SequenceStepResult(f"enter_{index + 1}", False, f"[SEQ] ENTER fehlgeschlagen: {exc}"))
                break

        steps.append(
            SequenceStepResult(
                "enter_sequence",
                True,
                "[SEQ] ENTER bis Wechsel ausgeführt" if changed else f"[SEQ] ENTER-Folge ausgeführt ({enter_presses} Drucke), kein klarer Zustandswechsel",
            )
        )

        try:
            protocol = await self.acquisition.fetch_latest_psi_record(clear_after_read=clear_psi_after_read)
            measurement = protocol.parsed_measurement
            self.last_imported_raw_protocol = protocol
            self.last_imported_measurement = measurement
            if measurement is not None:
                steps.append(SequenceStepResult("psi_fetch", True, "[SEQ] PSI-Datensatz gefunden und Messung übernommen", protocol.raw_record))
            else:
                steps.append(SequenceStepResult("psi_fetch", False, "[SEQ] PSI-Datensatz ohne auswertbare Messwerte", protocol.raw_record))
        except Exception as exc:
            steps.append(SequenceStepResult("psi_fetch", False, f"[SEQ] Kein PSI-Datensatz gefunden: {exc}"))

        try:
            status = await self.acquisition.query_mes_status()
            final_status_raw = status.raw_response
            steps.append(SequenceStepResult("status_final", True, "[SEQ] Abschlussstatus gelesen", status.raw_response))
        except Exception as exc:
            steps.append(SequenceStepResult("status_final", False, f"[SEQ] Abschlussstatus fehlgeschlagen: {exc}"))

        imported = self.last_imported_measurement is not None
        success = imported and not any(step.step_name == "status_final" and not step.success for step in steps)
        message = (
            f"{sequence_name}-Sequenz abgeschlossen: Messdaten importiert"
            if imported
            else f"{sequence_name}-Sequenz abgeschlossen: Kein PSI-Datensatz importiert"
        )
        return SequenceResult(
            success=success,
            sequence_name=sequence_name,
            message=message,
            steps=steps,
            final_status_raw=final_status_raw,
            measurement_imported=imported,
            imported_measurement_summary=self._build_measurement_summary(self.last_imported_measurement),
        )

    async def _run_adaptive_sk_sequence(self, sequence_name: str) -> SequenceResult:
        self.last_imported_measurement = None
        self.last_imported_raw_protocol = None
        steps: list[SequenceStepResult] = [
            SequenceStepResult("start", True, f"[SEQ] Sequenz {sequence_name} gestartet (adaptive SK-Logik, response-gesteuert)")
        ]
        final_status_raw: Optional[str] = None
        stop_reason = "Workflow ohne Import beendet"
        state = AdaptiveSkState()

        await self._poll_mes(state, retries=2)

        while state.auto_enters < self.MAX_AUTO_ENTERS:
            current = await self._poll_mes(state, retries=1)
            upper = current.upper()
            final_status_raw = current

            if "NTZON;NULL;" in upper or "NTZON;NULL" in upper:
                steps.append(SequenceStepResult("finish_detected", True, "[SEQ] Messung erfolgreich beendet erkannt (NTZON;NULL)", current))
                try:
                    protocol = await self.acquisition.fetch_latest_psi_record(clear_after_read=False)
                    self.last_imported_raw_protocol = protocol
                    self.last_imported_measurement = protocol.parsed_measurement
                    steps.append(SequenceStepResult("wer_fetch", True, "[SEQ] WER? nach Abschluss gelesen", protocol.raw_record))
                except Exception as exc:
                    steps.append(SequenceStepResult("wer_fetch", False, f"[SEQ] WER? nach Abschluss fehlgeschlagen: {exc}"))
                stop_reason = "Workflow abgeschlossen"
                break

            auto_enter_reason = self._auto_enter_reason(state, upper)
            if auto_enter_reason is not None:
                steps.append(
                    SequenceStepResult(
                        f"auto_enter_{state.auto_enters + 1}",
                        True,
                        f"[SEQ] AUTO-ENTER [{auto_enter_reason}] bei '{state.last_mes_full or current}'",
                        current,
                    )
                )
                await self._do_auto_enter(state, auto_enter_reason)
                continue

            await asyncio.sleep(self._poll_interval_seconds())

        if state.auto_enters >= self.MAX_AUTO_ENTERS and self.last_imported_measurement is None and self.last_imported_raw_protocol is None:
            stop_reason = "AUTO-HALT: Max Auto-Enter erreicht"
            steps.append(SequenceStepResult("auto_halt", False, f"[SEQ] {stop_reason}", final_status_raw))

        if final_status_raw is None:
            try:
                final_status_raw = (await self.acquisition.query_mes_status()).raw_response
            except Exception:
                final_status_raw = None

        imported = self.last_imported_measurement is not None
        message = (
            f"{sequence_name}-Sequenz abgeschlossen: Messdaten importiert"
            if imported
            else f"{sequence_name}-Sequenz abgeschlossen: {stop_reason}"
        )
        return SequenceResult(
            success=imported,
            sequence_name=sequence_name,
            message=message,
            steps=steps,
            final_status_raw=final_status_raw,
            measurement_imported=imported,
            imported_measurement_summary=self._build_measurement_summary(self.last_imported_measurement),
        )

    async def _do_auto_enter(self, state: AdaptiveSkState, reason: str) -> None:
        await self.acquisition.press_enter()
        state.auto_enters += 1
        state.repeat_count = 0
        state.stop_repeat_count = 0
        state.ek_repeat_count = 0
        if reason.startswith("RSLK after RSLAC"):
            state.rslk_post_descending_hits = 0
            state.last_rslk_post_counter = None

    async def _poll_mes(self, state: AdaptiveSkState, retries: int) -> str:
        latest = state.last_mes_full
        for _ in range(max(1, retries)):
            try:
                status = await self.acquisition.query_mes_status()
                latest = status.raw_response
                self._update_adaptive_state_from_mes(state, latest)
                return latest
            except Exception:
                await asyncio.sleep(self._poll_interval_seconds())
        return latest

    def _auto_enter_reason(self, state: AdaptiveSkState, upper: str) -> Optional[str]:
        if state.phase in {"precheck", "user_confirm_off"} and state.stop_repeat_count >= self.STABLE_TARGET:
            return "STOP precheck"
        if state.phase == "user_confirm_off" and state.ek_repeat_count >= self.STABLE_TARGET:
            return "EK;EK off prompt"
        if state.phase == "probe_release" and state.stop_repeat_count >= self.STABLE_TARGET:
            return "STOP after probe release"
        if state.phase == "probe_release" and "RSLK;RSLK" in upper and state.repeat_count >= self.STABLE_TARGET:
            return "RSLK repeat after RSLAC"
        if state.phase == "probe_release" and "RSLK;RSLK" in upper and state.rslk_post_descending_hits >= self.RSLK_DESC_HITS_NEEDED:
            return "RSLK after RSLAC descending"
        if state.stop_repeat_count >= self.STABLE_TARGET:
            return "STOP"
        if state.ek_repeat_count >= self.STABLE_TARGET:
            return "EK;EK"
        return None

    def _update_adaptive_state_from_mes(self, state: AdaptiveSkState, mes_raw: str) -> None:
        mes_full_matches = re.findall(r"(Messung=[^\r\n]+)", mes_raw, re.I)
        mes_full = mes_full_matches[-1].strip() if mes_full_matches else mes_raw.strip()
        mes_matches = re.findall(r"Messung=([^\r\n$]+)", mes_raw, re.I)
        mes = mes_matches[-1].strip() if mes_matches else mes_full

        if mes_full == state.last_mes_full:
            state.repeat_count += 1
        else:
            state.repeat_count = 1
            state.last_mes_full = mes_full
        state.last_mes = mes

        upper_full = mes_full.upper()
        state.stop_repeat_count = state.repeat_count if "STOP;" in upper_full else 0
        state.ek_repeat_count = state.repeat_count if "EK;EK;" in upper_full or "EK;EK" in upper_full else 0
        self._update_phase(state, mes)

    def _update_phase(self, state: AdaptiveSkState, mes: str) -> None:
        upper = mes.upper()
        if "SOK;SOK" in upper:
            state.phase = "precheck"
        elif "EK;EK" in upper:
            state.phase = "user_confirm_off"
        elif "EA2;EA3;UEA" in upper or "EA2;EA20;UEA" in upper:
            state.phase = "pre_measurement"
        elif "KK;KK" in upper:
            state.phase = "contact_check"
        elif "RSLAC" in upper or "USLRAC" in upper or "ISLRAC" in upper:
            state.rslac_seen = True
            state.phase = "pe_measurement"
        elif "RSLK;RSLK" in upper:
            counter = self._parse_rslk_counter(mes)
            if not state.rslac_seen:
                state.phase = "probe_attach"
                state.last_rslk_post_counter = None
                state.rslk_post_descending_hits = 0
            else:
                state.phase = "probe_release"
                if counter is not None:
                    if state.last_rslk_post_counter is not None and counter < state.last_rslk_post_counter:
                        state.rslk_post_descending_hits += 1
                    elif state.last_rslk_post_counter == counter:
                        pass
                    else:
                        state.rslk_post_descending_hits = 0
                    state.last_rslk_post_counter = counter
        elif "RISO" in upper or "UISO" in upper:
            state.phase = "isolation"
        elif "NTZON;NULL" in upper:
            state.phase = "finish"
        elif "STOP;" in upper:
            if state.phase in {"probe_attach", "pe_measurement", "probe_release"}:
                state.phase = "probe_release"
            elif state.phase in {"isolation", "pre_measurement", "contact_check"}:
                pass
            else:
                state.phase = "precheck"

    def _parse_rslk_counter(self, mes: str) -> Optional[int]:
        match = re.search(r"RSLK;RSLK;(\d+)", mes, re.I)
        return int(match.group(1)) if match else None

    async def _run_simulated_sequence(self, sequence_name: str) -> SequenceResult:
        measurement = MeasurementRaw.now(rpe=0.19, rins=5.7, ipe=0.22, u=230.1, is_ok=True)
        raw_protocol = RawProtocolRecord(
            source="PSI_AUTOSTORE_PULL",
            raw_record="SIM;RPE=0.19;RINS=5.7;IPE=0.22;U=230.1",
            protocol_number="SIM-001",
            protocol_date=None,
            protocol_time=None,
            parsed_measurement=measurement,
            parsed_metadata=None,
            raw_fields=["SIM", "RPE=0.19", "RINS=5.7", "IPE=0.22", "U=230.1"],
        )
        self.last_imported_measurement = measurement
        self.last_imported_raw_protocol = raw_protocol
        steps = [
            SequenceStepResult("start", True, "[SEQ] Simulationsmodus aktiv"),
            SequenceStepResult("simulate", True, "[SEQ] Simulierte Messdaten erzeugt", raw_protocol.raw_record),
            SequenceStepResult("status_final", True, "[SEQ] Simulierter Abschlussstatus", "SIM_OK"),
        ]
        return SequenceResult(
            success=True,
            sequence_name=sequence_name,
            message=f"{sequence_name}-Sequenz abgeschlossen: Simulierte Messdaten importiert",
            steps=steps,
            final_status_raw="SIM_OK",
            measurement_imported=True,
            imported_measurement_summary=self._build_measurement_summary(measurement),
        )

    def _build_measurement_summary(self, measurement: Optional[MeasurementRaw]) -> Optional[str]:
        if measurement is None:
            return None
        return f"RPE={measurement.rpe if measurement.rpe is not None else '-'} Ω, RINS={measurement.rins if measurement.rins is not None else '-'} MΩ, IPE={measurement.ipe if measurement.ipe is not None else '-'} mA"
