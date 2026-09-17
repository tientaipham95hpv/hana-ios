from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any


@dataclass(frozen=True)
class PipelineError:
    category: str
    relative_source_path: str | None
    source_id: str | None
    return_code: int | None
    message: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class IntegrityDifference:
    relative_source_path: str
    fields: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "relative_source_path": self.relative_source_path,
            "fields": list(self.fields),
        }
