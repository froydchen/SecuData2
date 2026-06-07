from __future__ import annotations

from dataclasses import dataclass, asdict, field
from datetime import datetime
from typing import Any, Optional


@dataclass
class MeasurementRaw:
    rpe: Optional[float]
    rins: Optional[float]
    ipe: Optional[float]
    u: Optional[float]
    timestamp: str
    is_ok: bool = True
    values: list[dict[str, str]] = field(default_factory=list)

    @classmethod
    def now(
        cls,
        rpe: Optional[float] = None,
        rins: Optional[float] = None,
        ipe: Optional[float] = None,
        u: Optional[float] = None,
        is_ok: bool = True,
        values: Optional[list[dict[str, str]]] = None,
    ) -> "MeasurementRaw":
        return cls(
            rpe=rpe,
            rins=rins,
            ipe=ipe,
            u=u,
            timestamp=datetime.now().isoformat(timespec="seconds"),
            is_ok=is_ok,
            values=values or [],
        )

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class MeasurementMetadata:
    id: str = ""
    geraeteart: str = ""
    hersteller: str = ""
    raum_etage: str = ""
    kunde: str = ""
    typ_modell: str = ""
    seriennummer: str = ""
    pruefer: str = ""
    zusatztext: str = ""

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class DraftInputState(MeasurementMetadata):
    pass


@dataclass
class FinalRecord:
    id: int
    created_at: str
    measurement: MeasurementRaw
    metadata: MeasurementMetadata

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "created_at": self.created_at,
            "measurement": self.measurement.to_dict(),
            "metadata": self.metadata.to_dict(),
        }


@dataclass
class RawProtocolRecord:
    source: str
    raw_record: str
    protocol_number: Optional[str]
    protocol_date: Optional[str]
    protocol_time: Optional[str]
    parsed_measurement: Optional[MeasurementRaw]
    parsed_metadata: Optional[MeasurementMetadata]
    raw_fields: list[str]

    def to_dict(self) -> dict[str, Any]:
        return {
            "source": self.source,
            "raw_record": self.raw_record,
            "protocol_number": self.protocol_number,
            "protocol_date": self.protocol_date,
            "protocol_time": self.protocol_time,
            "parsed_measurement": self.parsed_measurement.to_dict() if self.parsed_measurement else None,
            "parsed_metadata": self.parsed_metadata.to_dict() if self.parsed_metadata else None,
            "raw_fields": self.raw_fields,
        }


@dataclass
class MesStatus:
    raw_response: str
    connection_flags_raw: Optional[str]
    running_measurement_numbers: list[int]
    is_stopped: bool
    contains_measurement_21_stop: bool

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class SequenceStepResult:
    step_name: str
    success: bool
    detail: str
    raw_data: Optional[str] = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class SequenceResult:
    success: bool
    sequence_name: str
    message: str
    steps: list[SequenceStepResult]
    final_status_raw: Optional[str]
    measurement_imported: bool
    imported_measurement_summary: Optional[str]

    def to_dict(self) -> dict[str, Any]:
        return {
            "success": self.success,
            "sequence_name": self.sequence_name,
            "message": self.message,
            "steps": [step.to_dict() for step in self.steps],
            "final_status_raw": self.final_status_raw,
            "measurement_imported": self.measurement_imported,
            "imported_measurement_summary": self.imported_measurement_summary,
        }
