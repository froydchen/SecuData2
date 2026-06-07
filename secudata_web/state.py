from __future__ import annotations

import asyncio
from collections import deque
from datetime import datetime
from typing import Any, Optional

from starlette.websockets import WebSocket

from .database import Database
from .models import DraftInputState, MeasurementRaw, RawProtocolRecord, SequenceResult


class EventHub:
    def __init__(self) -> None:
        self._clients: set[WebSocket] = set()
        self._lock = asyncio.Lock()

    async def connect(self, websocket: WebSocket) -> None:
        await websocket.accept()
        async with self._lock:
            self._clients.add(websocket)

    async def disconnect(self, websocket: WebSocket) -> None:
        async with self._lock:
            self._clients.discard(websocket)

    async def broadcast(self, payload: dict[str, Any]) -> None:
        async with self._lock:
            clients = list(self._clients)
        if not clients:
            return
        stale: list[WebSocket] = []
        for websocket in clients:
            try:
                await websocket.send_json(payload)
            except Exception:
                stale.append(websocket)
        if stale:
            async with self._lock:
                for websocket in stale:
                    self._clients.discard(websocket)


class AppState:
    def __init__(self, database: Database, event_hub: EventHub) -> None:
        self.database = database
        self.event_hub = event_hub
        self.connection_status = "DISCONNECTED"
        self.connection_detail = ""
        self.app_state = "READY_FOR_MEASUREMENT"
        self.is_loading = False
        self.is_sequence_running = False
        self.active_measurement_button: Optional[str] = None
        self.last_measurement_button: Optional[str] = None
        self.current_measurement: Optional[MeasurementRaw] = None
        self.current_raw_protocol: Optional[RawProtocolRecord] = None
        self.current_device_status: Optional[str] = None
        self.last_sequence_message: Optional[str] = None
        self.last_sequence_result: Optional[SequenceResult] = None
        self.error_message: Optional[str] = None
        self.logs: deque[str] = deque(maxlen=240)
        self.comm_log: deque[dict[str, Any]] = deque(maxlen=240)
        self._state_lock = asyncio.Lock()

    async def append_log(self, message: str) -> None:
        timestamp = datetime.now().strftime("%d.%m.%y %H:%M:%S")
        line = f"[{timestamp}] {message}"
        self.logs.append(line)
        await self.event_hub.broadcast({"type": "log", "line": line})

    async def append_comm_log(self, entry: dict[str, Any]) -> None:
        self.comm_log.append(entry)
        await self.event_hub.broadcast({"type": "comm", "entry": entry})

    async def broadcast_draft(self, draft: DraftInputState, reason: str = "server") -> None:
        await self.event_hub.broadcast({"type": "draft", "draft": draft.to_dict(), "reason": reason})

    async def set_connection_status(self, status: str, detail: str = "") -> None:
        self.connection_status = status
        self.connection_detail = detail
        await self.emit_state()

    async def set_sequence_running(self, running: bool, button: Optional[str] = None) -> None:
        self.is_sequence_running = running
        self.is_loading = running
        if button:
            self.active_measurement_button = button
            self.last_measurement_button = button
        self.app_state = "FETCHING_MEASUREMENT" if running else self.app_state
        await self.emit_state()

    async def set_sequence_result(
        self,
        result: SequenceResult,
        measurement: Optional[MeasurementRaw],
        raw_protocol: Optional[RawProtocolRecord],
    ) -> None:
        self.last_sequence_result = result
        self.last_sequence_message = result.message
        self.current_device_status = result.final_status_raw
        self.is_loading = False
        self.is_sequence_running = False
        self.error_message = None if result.success else result.message
        self.current_measurement = measurement or self.current_measurement
        self.current_raw_protocol = raw_protocol or self.current_raw_protocol
        self.app_state = "MEASUREMENT_RECEIVED_NEEDS_METADATA" if measurement else "READY_FOR_MEASUREMENT"
        await self.emit_state()

    async def set_error(self, message: str) -> None:
        self.error_message = message
        self.is_loading = False
        self.is_sequence_running = False
        self.app_state = "READY_FOR_MEASUREMENT"
        await self.emit_state()

    async def set_measurement_ready(self, measurement: MeasurementRaw, raw_protocol: Optional[RawProtocolRecord]) -> None:
        self.current_measurement = measurement
        self.current_raw_protocol = raw_protocol
        self.app_state = "MEASUREMENT_RECEIVED_NEEDS_METADATA"
        self.is_loading = False
        self.is_sequence_running = False
        await self.emit_state()

    async def mark_saved(self) -> None:
        self.app_state = "SAVED"
        self.is_loading = False
        await self.emit_state()
        await asyncio.sleep(1.0)
        self.current_measurement = None
        self.current_raw_protocol = None
        self.active_measurement_button = None
        self.app_state = "READY_FOR_MEASUREMENT"
        await self.emit_state()

    async def update_device_status(self, status: str) -> None:
        self.current_device_status = status
        await self.emit_state()

    async def emit_state(self) -> None:
        await self.event_hub.broadcast({"type": "state", "state": self.snapshot()})

    def snapshot(self) -> dict[str, Any]:
        draft = self.database.get_draft()
        settings = self.database.get_settings()
        return {
            "connection_status": self.connection_status,
            "connection_detail": self.connection_detail,
            "app_state": self.app_state,
            "is_loading": self.is_loading,
            "is_sequence_running": self.is_sequence_running,
            "active_measurement_button": self.active_measurement_button,
            "last_measurement_button": self.last_measurement_button,
            "current_measurement": self.current_measurement.to_dict() if self.current_measurement else None,
            "current_raw_protocol": self.current_raw_protocol.to_dict() if self.current_raw_protocol else None,
            "current_device_status": self.current_device_status,
            "last_sequence_message": self.last_sequence_message,
            "last_sequence_result": self.last_sequence_result.to_dict() if self.last_sequence_result else None,
            "error_message": self.error_message,
            "logs": list(self.logs),
            "comm_log": list(self.comm_log),
            "draft": draft.to_dict(),
            "settings": settings,
            "records_count": len(self.database.get_records("chronological_desc")),
            "custom_buttons": self.database.get_custom_buttons(),
        }
