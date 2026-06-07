from __future__ import annotations

import asyncio
import io
from pathlib import Path
from typing import Any, Awaitable, Callable, Optional

import uvicorn
from starlette.applications import Starlette
from starlette.exceptions import HTTPException
from starlette.requests import Request
from starlette.responses import FileResponse, JSONResponse, StreamingResponse
from starlette.staticfiles import StaticFiles
from starlette.routing import WebSocketRoute
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.websockets import WebSocket, WebSocketDisconnect

from .acquisition import SecutestAcquisitionService
from .client import SecutestClientError, SecutestLiveConnection
from .database import Database
from .dictionaries import (
    build_device_suggestions,
    build_id_suggestions,
    build_manufacturer_suggestions,
    expand_device_abbreviations,
)
from .excel_io import export_records_to_bytes, export_records_to_path, import_records_from_bytes
from .models import DraftInputState, MeasurementMetadata
from .sequences import MeasurementSequenceService
from .state import AppState, EventHub


PACKAGE_ROOT = Path(__file__).resolve().parent.parent
STATIC_DIR = PACKAGE_ROOT / "static"
DATA_DIR = PACKAGE_ROOT / "data"
DATA_DIR.mkdir(parents=True, exist_ok=True)
DB_PATH = DATA_DIR / "secudata_web.db"

app = Starlette(debug=False)
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

# Starlette has changed/de-emphasized decorator helpers across versions.
# Keep the route definitions below readable by providing tiny compatibility
# decorators that use Starlette's stable add_* methods internally.
def _route(path: str, methods: list[str] | None = None):
    def decorator(func):
        app.add_route(path, func, methods=methods)
        return func
    return decorator


def _websocket_route(path: str):
    def decorator(func):
        # Termux/Android can ship Starlette versions where the decorator helper
        # exists, but add_websocket_route() does not. Appending a WebSocketRoute
        # is stable across those versions. Ja, Versionstabellen-Bingo.
        app.routes.append(WebSocketRoute(path, func))
        return func
    return decorator


def _exception_handler(exc_class_or_status_code):
    def decorator(func):
        app.add_exception_handler(exc_class_or_status_code, func)
        return func
    return decorator


app.route = _route  # type: ignore[attr-defined]
app.websocket_route = _websocket_route  # type: ignore[attr-defined]
app.exception_handler = _exception_handler  # type: ignore[attr-defined]

class NoCacheMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        response = await call_next(request)
        # Local field tool: stale JS/CSS is worse than an extra few milliseconds.
        response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
        return response


app.add_middleware(NoCacheMiddleware)

database = Database(DB_PATH)
events = EventHub()
state = AppState(database, events)
client = SecutestLiveConnection(database, state)
acquisition = SecutestAcquisitionService(client)
sequences = MeasurementSequenceService(acquisition, database, state)


# =========================================================
# JSON / validation helpers
# =========================================================

async def _read_json(request: Request) -> dict[str, Any]:
    try:
        payload = await request.json()
    except Exception as exc:
        raise HTTPException(status_code=400, detail="Ungültiger JSON-Body.") from exc
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="JSON-Body muss ein Objekt sein.")
    return payload


def _as_text(payload: dict[str, Any], key: str, default: str = "") -> str:
    value = payload.get(key, default)
    if value is None:
        return default
    return str(value)


def _as_optional_text(payload: dict[str, Any], key: str) -> Optional[str]:
    if key not in payload or payload[key] is None:
        return None
    return str(payload[key])


def _as_optional_bool(payload: dict[str, Any], key: str) -> Optional[bool]:
    if key not in payload or payload[key] is None:
        return None
    value = payload[key]
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "yes", "ja", "on"}:
            return True
        if normalized in {"0", "false", "no", "nein", "off"}:
            return False
    raise HTTPException(status_code=400, detail=f"'{key}' muss boolesch sein.")


def _as_optional_int(
    payload: dict[str, Any],
    key: str,
    *,
    minimum: Optional[int] = None,
    maximum: Optional[int] = None,
) -> Optional[int]:
    if key not in payload or payload[key] is None or payload[key] == "":
        return None
    try:
        value = int(payload[key])
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=f"'{key}' muss eine Ganzzahl sein.") from exc
    if minimum is not None and value < minimum:
        raise HTTPException(status_code=400, detail=f"'{key}' muss mindestens {minimum} sein.")
    if maximum is not None and value > maximum:
        raise HTTPException(status_code=400, detail=f"'{key}' darf höchstens {maximum} sein.")
    return value


def _as_optional_rst_code(payload: dict[str, Any], key: str) -> Optional[str]:
    value = _as_optional_text(payload, key)
    if value is None or value.strip() == "":
        return None
    text = value.strip().upper().removeprefix("RST!")
    if not text.isdigit() or not 1 <= int(text) <= 8:
        raise HTTPException(status_code=400, detail=f"'{key}' muss eine RST-Ziffer von 1 bis 8 sein.")
    return str(int(text))


def _as_optional_rst_address(payload: dict[str, Any], key: str) -> Optional[str]:
    value = _as_optional_text(payload, key)
    if value is None or value.strip() == "":
        return None
    text = value.strip().upper()
    if text.startswith("RST") and "!" in text:
        text = text[3:].split("!", 1)[0]
    if not text.isdigit() or not 0 <= int(text) <= 90:
        raise HTTPException(status_code=400, detail=f"'{key}' muss eine RST-Adresse von 0 bis 90 sein.")
    return str(int(text))


def _reset_code_for_button(settings: dict[str, str], button_name: Optional[str]) -> str:
    if button_name == "LEITUNGEN":
        return settings.get("rst_code_leitungen", "4")
    if button_name == "SK_I_II":
        return settings.get("rst_code_sk_i_ii", "3")
    return settings.get("rst_code_sk_i_ii", "3")


def _reset_address_from_settings(settings: dict[str, str]) -> str:
    return settings.get("rst_target_address", "1")


def _draft_from_payload(payload: dict[str, Any]) -> DraftInputState:
    return DraftInputState(
        id=_as_text(payload, "id"),
        geraeteart=_as_text(payload, "geraeteart"),
        hersteller=_as_text(payload, "hersteller"),
        raum_etage=_as_text(payload, "raum_etage"),
        kunde=_as_text(payload, "kunde"),
        typ_modell=_as_text(payload, "typ_modell"),
        seriennummer=_as_text(payload, "seriennummer"),
        pruefer=_as_text(payload, "pruefer"),
        zusatztext=_as_text(payload, "zusatztext"),
    )


def _metadata_from_payload(payload: dict[str, Any]) -> MeasurementMetadata:
    return MeasurementMetadata(
        id=_as_text(payload, "id"),
        geraeteart=expand_device_abbreviations(_as_text(payload, "geraeteart")),
        hersteller=_as_text(payload, "hersteller"),
        raum_etage=_as_text(payload, "raum_etage"),
        kunde=_as_text(payload, "kunde"),
        typ_modell=_as_text(payload, "typ_modell"),
        seriennummer=_as_text(payload, "seriennummer"),
        pruefer=_as_text(payload, "pruefer"),
        zusatztext=_as_text(payload, "zusatztext"),
    )


def _prefer_imported(imported: str, current: str) -> str:
    value = (imported or "").strip()
    return value if value else current


def _merge_imported_metadata_into_draft(imported: Optional[MeasurementMetadata]) -> Optional[DraftInputState]:
    if imported is None:
        return None
    current = database.get_draft()
    merged = DraftInputState(
        id=_prefer_imported(imported.id, current.id),
        geraeteart=_prefer_imported(expand_device_abbreviations(imported.geraeteart), current.geraeteart),
        hersteller=_prefer_imported(imported.hersteller, current.hersteller),
        raum_etage=_prefer_imported(imported.raum_etage, current.raum_etage),
        kunde=current.kunde,
        typ_modell=current.typ_modell,
        seriennummer=current.seriennummer,
        pruefer=current.pruefer,
        zusatztext=current.zusatztext,
    )
    return database.save_draft(merged)


@app.exception_handler(HTTPException)
async def _http_exception_handler(request: Request, exc: HTTPException) -> JSONResponse:
    return JSONResponse({"detail": exc.detail}, status_code=exc.status_code)


@app.exception_handler(Exception)
async def _generic_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    return JSONResponse({"detail": str(exc)}, status_code=500)


# =========================================================
# Basic routes
# =========================================================

@app.route("/", methods=["GET"])
async def index(request: Request) -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html", headers={"Cache-Control": "no-store, no-cache, must-revalidate, max-age=0"})


@app.route("/manifest.webmanifest", methods=["GET"])
async def manifest(request: Request) -> FileResponse:
    return FileResponse(STATIC_DIR / "manifest.webmanifest", media_type="application/manifest+json", headers={"Cache-Control": "no-store, no-cache, must-revalidate, max-age=0"})


@app.route("/sw.js", methods=["GET"])
async def service_worker(request: Request) -> FileResponse:
    return FileResponse(STATIC_DIR / "sw.js", media_type="application/javascript", headers={"Cache-Control": "no-store, no-cache, must-revalidate, max-age=0"})


@app.route("/api/state", methods=["GET"])
async def get_state(request: Request) -> JSONResponse:
    return JSONResponse(state.snapshot())


@app.websocket_route("/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    await events.connect(websocket)
    try:
        await websocket.send_json({"type": "state", "state": state.snapshot()})
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        await events.disconnect(websocket)
    except Exception:
        await events.disconnect(websocket)


# =========================================================
# Settings + connection
# =========================================================

@app.route("/api/settings", methods=["POST"])
async def update_settings(request: Request) -> JSONResponse:
    payload = await _read_json(request)
    updates: dict[str, Any] = {}

    host = _as_optional_text(payload, "host")
    port = _as_optional_int(payload, "port", minimum=1, maximum=65535)
    simulation_enabled = _as_optional_bool(payload, "simulation_enabled")
    autosave_enabled = _as_optional_bool(payload, "autosave_enabled")
    autosave_path = _as_optional_text(payload, "autosave_path")
    poll_interval_ms = _as_optional_int(payload, "poll_interval_ms", minimum=50, maximum=10000)
    command_timeout_ms = _as_optional_int(payload, "command_timeout_ms", minimum=200, maximum=30000)
    rst_code_sk_i_ii = _as_optional_rst_code(payload, "rst_code_sk_i_ii")
    rst_code_leitungen = _as_optional_rst_code(payload, "rst_code_leitungen")
    rst_target_address = _as_optional_rst_address(payload, "rst_target_address")
    post_reset_settle_ms = _as_optional_int(payload, "post_reset_settle_ms", minimum=0, maximum=10000)

    if host is not None:
        updates["host"] = host.strip()
    if port is not None:
        updates["port"] = str(port)
    if simulation_enabled is not None:
        updates["simulation_enabled"] = "1" if simulation_enabled else "0"
    if autosave_enabled is not None:
        updates["autosave_enabled"] = "1" if autosave_enabled else "0"
    if autosave_path is not None:
        updates["autosave_path"] = autosave_path.strip()
    if poll_interval_ms is not None:
        updates["poll_interval_ms"] = str(poll_interval_ms)
    if command_timeout_ms is not None:
        updates["command_timeout_ms"] = str(command_timeout_ms)
    if rst_code_sk_i_ii is not None:
        updates["rst_code_sk_i_ii"] = rst_code_sk_i_ii
    if rst_code_leitungen is not None:
        updates["rst_code_leitungen"] = rst_code_leitungen
    if rst_target_address is not None:
        updates["rst_target_address"] = rst_target_address
    if post_reset_settle_ms is not None:
        updates["post_reset_settle_ms"] = str(post_reset_settle_ms)

    previous = database.get_settings()
    current = database.set_settings(updates)
    if client.connected and any(key in updates for key in ("host", "port")):
        await client.disconnect()
        await state.append_log("[SETTINGS] Host/Port geändert – Verbindung getrennt.")
    await state.emit_state()
    return JSONResponse({"settings": current, "changed": updates, "previous": previous})


@app.route("/api/connect", methods=["POST"])
async def connect(request: Request) -> JSONResponse:
    try:
        await client.connect()
    except SecutestClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return JSONResponse({"ok": True, "status": state.connection_status, "detail": state.connection_detail})


@app.route("/api/disconnect", methods=["POST"])
async def disconnect(request: Request) -> JSONResponse:
    await client.disconnect()
    return JSONResponse({"ok": True, "status": state.connection_status})


# =========================================================
# Draft + suggestions
# =========================================================

@app.route("/api/draft", methods=["POST"])
async def save_draft(request: Request) -> JSONResponse:
    payload = await _read_json(request)
    draft = database.save_draft(_draft_from_payload(payload))
    # Do not echo every keystroke back through a full state broadcast.
    # Mobile browsers otherwise race their own input and occasionally lose the last character.
    return JSONResponse({"draft": draft.to_dict()})


@app.route("/api/draft/expand-device", methods=["POST"])
async def expand_draft_device(request: Request) -> JSONResponse:
    payload = await _read_json(request)
    value = expand_device_abbreviations(_as_text(payload, "value"))
    return JSONResponse({"value": value})


@app.route("/api/suggestions", methods=["GET"])
async def suggestions(request: Request) -> JSONResponse:
    field = request.query_params.get("field", "")
    q = request.query_params.get("q", "")
    geraeteart = request.query_params.get("geraeteart", "")
    metadata_rows = database.metadata_rows()
    if field == "id":
        values = build_id_suggestions([row["id"] for row in metadata_rows], q)
    elif field == "geraeteart":
        values = build_device_suggestions([row["geraeteart"] for row in metadata_rows], q)
    elif field == "hersteller":
        values = build_manufacturer_suggestions(metadata_rows, geraeteart, q)
    else:
        raise HTTPException(status_code=400, detail="Unbekanntes Vorschlagsfeld")
    return JSONResponse({"field": field, "values": values})


# =========================================================
# Commands / debug console
# =========================================================

@app.route("/api/command", methods=["POST"])
async def send_command(request: Request) -> JSONResponse:
    payload = await _read_json(request)
    command = _as_text(payload, "command").strip()
    if not command:
        raise HTTPException(status_code=400, detail="Leerer Befehl wurde verworfen.")
    expected = _as_text(payload, "expected", "auto").strip() or "auto"
    timeout_ms = _as_optional_int(payload, "timeout_ms", minimum=200, maximum=30000)
    try:
        frame = await client.send_command(command, expected=expected, timeout_ms=timeout_ms)
    except Exception as exc:
        await state.append_log(f"[CMD-ERR] {command}: {exc}")
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return JSONResponse({"ok": True, "frame": frame.to_dict()})


@app.route("/api/manual/enter", methods=["POST"])
async def manual_enter(request: Request) -> JSONResponse:
    try:
        await acquisition.press_enter()
        await state.append_log("ENTER (TAS!4) gesendet.")
        return JSONResponse({"ok": True})
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@app.route("/api/manual/mes", methods=["POST"])
async def manual_mes(request: Request) -> JSONResponse:
    try:
        mes = await acquisition.query_mes_status()
        await state.update_device_status(mes.raw_response)
        await state.append_log(f"MES?: {mes.raw_response}")
        return JSONResponse({"ok": True, "status": mes.to_dict()})
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@app.route("/api/manual/clear-psi", methods=["POST"])
async def manual_clear_psi(request: Request) -> JSONResponse:
    try:
        await acquisition.clear_psi_memory()
        await state.append_log("PSI-Speicher wurde geleert (MEM!).")
        return JSONResponse({"ok": True})
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@app.route("/api/manual/reset-init", methods=["POST"])
async def manual_reset_init(request: Request) -> JSONResponse:
    try:
        payload = await _read_json(request) if request.headers.get("content-length") not in (None, "0") else {}
        settings = database.get_settings()
        reset_code = _as_optional_rst_code(payload, "rst_code") or _reset_code_for_button(
            settings, state.active_measurement_button or state.last_measurement_button
        )
        reset_address = _as_optional_rst_address(payload, "rst_address") or _reset_address_from_settings(settings)
        await state.append_log(f"[INIT] Adressierung kurz prüfen/ggf. setzen → RST{reset_address}!{reset_code} → danach wieder kurz prüfen/ggf. setzen.")
        info = await acquisition.reset_mode_and_initialize(reset_code, reset_address)
        await state.append_log(f"[INIT] {info.get('reset_command', f'RST{reset_address}!{reset_code}')} + Adressierung abgeschlossen.")
        return JSONResponse({"ok": True, "init": info})
    except Exception as exc:
        await state.append_log(f"[INIT-ERR] Reset/Adressierung fehlgeschlagen: {exc}")
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@app.route("/api/manual/fetch-latest", methods=["POST"])
async def manual_fetch_latest(request: Request) -> JSONResponse:
    try:
        protocol = await acquisition.fetch_latest_psi_record(clear_after_read=False)
        measurement = protocol.parsed_measurement
        if measurement is None:
            raise RuntimeError("Datensatz vorhanden, aber keine Messwerte erkannt.")
        merged_draft = _merge_imported_metadata_into_draft(protocol.parsed_metadata)
        if merged_draft is not None:
            await state.broadcast_draft(merged_draft, reason="psi_import")
        await state.set_measurement_ready(measurement, protocol)
        await state.append_log("[WER] Letzter PSI-Datensatz übernommen.")
        return JSONResponse({"ok": True, "protocol": protocol.to_dict(), "draft": merged_draft.to_dict() if merged_draft else None})
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


# =========================================================
# Sequences
# =========================================================

async def _run_sequence(button_name: str, runner: Callable[[], Awaitable[Any]]) -> dict[str, Any]:
    if state.is_sequence_running:
        raise HTTPException(status_code=409, detail="Es läuft bereits eine Sequenz.")
    if state.app_state == "MEASUREMENT_RECEIVED_NEEDS_METADATA" and state.active_measurement_button == button_name:
        raise HTTPException(status_code=409, detail="Bitte zuerst die aktuelle Messung speichern.")

    await state.append_log(f"[SEQ] {button_name} gestartet")
    await state.set_sequence_running(True, button_name)
    try:
        result = await runner()

        # TX/RX already logs every MES?/TAS!/WER? frame live.  Do not replay the
        # full step list afterwards, otherwise the mobile log looks as if old
        # MES? events were processed again.  Only keep the compact milestones and
        # failures for readability.
        await state.append_log(f"[SEQ] {result.message}")
        for step in result.steps:
            important = step.step_name in {"finish_detected", "wer_fetch", "psi_fetch", "auto_halt"}
            if important or not step.success:
                await state.append_log(step.detail)
                if step.raw_data and step.step_name in {"wer_fetch", "psi_fetch"}:
                    await state.append_log(f"[RAW] {step.raw_data[:220]}")
        measurement = sequences.consume_last_imported_measurement()
        raw_protocol = sequences.consume_last_imported_raw_protocol()
        merged_draft = _merge_imported_metadata_into_draft(raw_protocol.parsed_metadata) if raw_protocol else None
        if merged_draft is not None:
            await state.broadcast_draft(merged_draft, reason="psi_import")
        await state.set_sequence_result(result, measurement, raw_protocol)
        return {"ok": result.success, "result": result.to_dict()}
    except Exception as exc:
        message = f"Sequenz abgebrochen: {exc}"
        await state.append_log(f"[SEQ] {message}")
        await state.set_error(message)
        raise HTTPException(status_code=502, detail=message) from exc


@app.route("/api/sequence/leitungen", methods=["POST"])
async def run_leitungen_sequence(request: Request) -> JSONResponse:
    return JSONResponse(await _run_sequence("LEITUNGEN", sequences.run_leitungen_sequence))


@app.route("/api/sequence/sk", methods=["POST"])
async def run_sk_sequence(request: Request) -> JSONResponse:
    return JSONResponse(await _run_sequence("SK_I_II", sequences.run_sk_sequence))


# =========================================================
# Save / history / Excel
# =========================================================

async def _run_post_save_device_cleanup(record_id: int) -> dict[str, Any]:
    """After the local save, prepare PSI/SECUTEST for the next measurement.

    The database save must stay successful even when the field device refuses a
    cleanup command. Otherwise one retry on the UI would create duplicate local
    records.  Cleanup errors are therefore returned and logged, but not converted
    into a failed save response.
    """
    settings = database.get_settings()
    if settings.get("simulation_enabled", "0") == "1":
        await state.append_log(f"[POST-SAVE] Simulation aktiv – PSI-Löschen/Reset für Datensatz #{record_id} übersprungen.")
        return {"ok": True, "skipped": "simulation"}

    if not client.connected:
        message = "Keine TCP-Verbindung – PSI-Löschen/Reset/Init nach dem Speichern nicht ausgeführt."
        await state.append_log(f"[POST-SAVE-WARN] {message}")
        return {"ok": False, "error": message}

    result: dict[str, Any] = {"ok": True, "steps": []}

    try:
        await state.append_log("[POST-SAVE] PSI-Speicher löschen (MEM!).")
        await acquisition.clear_psi_memory()
        result["steps"].append({"name": "clear_psi", "ok": True})
        await state.append_log("[POST-SAVE] PSI-Speicher gelöscht.")
    except Exception as exc:
        result["ok"] = False
        result["steps"].append({"name": "clear_psi", "ok": False, "error": str(exc)})
        await state.append_log(f"[POST-SAVE-WARN] PSI-Speicher konnte nicht gelöscht werden: {exc}")

    try:
        button_name = state.active_measurement_button or state.last_measurement_button
        reset_code = _reset_code_for_button(settings, button_name)
        reset_address = _reset_address_from_settings(settings)
        await state.append_log(
            f"[POST-SAVE] Modus-Reset nach {button_name or 'unbekannter Messung'}: "
            f"Adressierung kurz prüfen/ggf. setzen → RST{reset_address}!{reset_code} → danach wieder kurz prüfen/ggf. setzen."
        )
        init_info = await acquisition.reset_mode_and_initialize(reset_code, reset_address)
        result["steps"].append({"name": "reset_init", "ok": True, "detail": init_info})
        identity = init_info.get("secutest_identity") or init_info.get("psi_after") or "OK"
        await state.append_log(f"[POST-SAVE] {init_info.get('reset_command', 'RST!'+reset_code)} + Adressierung OK: {identity}")
    except Exception as exc:
        result["ok"] = False
        result["steps"].append({"name": "reset_init", "ok": False, "error": str(exc)})
        await state.append_log(f"[POST-SAVE-WARN] Reset/Adressierung fehlgeschlagen: {exc}")

    return result

@app.route("/api/records/save", methods=["POST"])
async def save_record(request: Request) -> JSONResponse:
    payload = await _read_json(request)
    measurement = state.current_measurement
    if measurement is None:
        raise HTTPException(status_code=409, detail="Keine Messung zum Speichern vorhanden.")

    metadata = _metadata_from_payload(payload)
    record = database.insert_record(measurement, metadata)

    # keep persistent fields, clear only device ID like the Android app
    draft_payload = dict(payload)
    draft_payload["id"] = ""
    database.save_draft(_draft_from_payload(draft_payload))

    settings = database.get_settings()
    if settings.get("autosave_enabled", "1") == "1":
        autosave_path = PACKAGE_ROOT / settings.get("autosave_path", "data/records_autosave.xlsx")
        export_records_to_path(database.get_records("chronological"), autosave_path)
        await state.append_log(f"[XLSX] Autosave aktualisiert: {autosave_path}")

    await state.append_log(f"[SAVE] Datensatz #{record.id} gespeichert.")
    state.app_state = "POST_SAVE_CLEANUP"
    state.is_loading = True
    await state.emit_state()
    cleanup_result = await _run_post_save_device_cleanup(record.id)
    asyncio.create_task(state.mark_saved())
    return JSONResponse({"ok": True, "record": record.to_dict(), "post_save_cleanup": cleanup_result})


@app.route("/api/records", methods=["GET"])
async def list_records(request: Request) -> JSONResponse:
    sort = request.query_params.get("sort", "chronological_desc")
    records = database.get_records(sort)
    return JSONResponse({"records": [record.to_dict() for record in records]})


@app.route("/api/records/{record_id:int}", methods=["PUT"])
async def update_record(request: Request) -> JSONResponse:
    record_id = int(request.path_params["record_id"])
    payload = await _read_json(request)
    metadata = _metadata_from_payload(payload)
    updated = database.update_record(record_id, metadata)
    if updated is None:
        raise HTTPException(status_code=404, detail="Datensatz nicht gefunden.")
    await state.append_log(f"[SAVE] Datensatz #{record_id} aktualisiert.")
    await state.emit_state()
    return JSONResponse({"ok": True, "record": updated.to_dict()})


@app.route("/api/records/export.xlsx", methods=["GET"])
async def export_records(request: Request) -> StreamingResponse:
    payload = export_records_to_bytes(database.get_records("chronological"))
    headers = {"Content-Disposition": 'attachment; filename="messdaten_export.xlsx"'}
    return StreamingResponse(
        io.BytesIO(payload),
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers=headers,
    )


@app.route("/api/records/import.xlsx", methods=["POST"])
async def import_records(request: Request) -> JSONResponse:
    try:
        form = await request.form()
        upload = form.get("file")
        if upload is None or not hasattr(upload, "read"):
            raise HTTPException(status_code=400, detail="Keine XLSX-Datei im Feld 'file' übergeben.")
        payload = await upload.read()
        records = import_records_from_bytes(payload)
        count = database.import_records(records)
        await state.append_log(f"[XLSX] {count} Datensätze importiert.")
        await state.emit_state()
        return JSONResponse({"ok": True, "imported": count})
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


# =========================================================
# Custom buttons / sequence playground
# =========================================================

@app.route("/api/custom-buttons", methods=["GET"])
async def list_custom_buttons(request: Request) -> JSONResponse:
    return JSONResponse({"buttons": database.get_custom_buttons()})


@app.route("/api/custom-buttons/{button_id:int}", methods=["PUT"])
async def update_custom_button(request: Request) -> JSONResponse:
    button_id = int(request.path_params["button_id"])
    payload = await _read_json(request)
    name = _as_text(payload, "name").strip()
    commands = _as_text(payload, "commands")
    if not name:
        raise HTTPException(status_code=400, detail="Button-Name darf nicht leer sein.")
    updated = database.update_custom_button(button_id, name, commands)
    if updated is None:
        raise HTTPException(status_code=404, detail="Button nicht gefunden.")
    await state.emit_state()
    return JSONResponse({"ok": True, "button": updated})


@app.route("/api/custom-buttons/{button_id:int}/run", methods=["POST"])
async def run_custom_button(request: Request) -> JSONResponse:
    button_id = int(request.path_params["button_id"])
    button = next((item for item in database.get_custom_buttons() if item["id"] == button_id), None)
    if button is None:
        raise HTTPException(status_code=404, detail="Button nicht gefunden.")

    commands = _parse_custom_commands(button["commands"])
    results: list[dict[str, Any]] = []
    if not commands:
        return JSONResponse({"ok": True, "button": button, "results": results})

    await state.append_log(f"[CUSTOM] {button['name']} gestartet ({len(commands)} Befehle)")
    for command in commands:
        try:
            frame = await client.send_command(command)
            results.append({"command": command, "ok": True, "frame": frame.to_dict()})
        except Exception as exc:
            results.append({"command": command, "ok": False, "error": str(exc)})
            await state.append_log(f"[CUSTOM-ERR] {command}: {exc}")
            break
    return JSONResponse({"ok": all(item["ok"] for item in results), "button": button, "results": results})


def _parse_custom_commands(raw: str) -> list[str]:
    normalized = raw.replace("|", "\n")
    commands: list[str] = []
    for line in normalized.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        commands.append(stripped)
    return commands


# =========================================================
# Entrypoint
# =========================================================

def main() -> None:
    uvicorn.run("secudata_web.app:app", host="0.0.0.0", port=8787, reload=False)


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8787, reload=False)
