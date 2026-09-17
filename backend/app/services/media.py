from __future__ import annotations

import hashlib
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

from app.core.config import Settings


@dataclass(frozen=True)
class StoredMedia:
    key: str
    path: Path
    bytes: int
    sha256: bytes
    expires_at: datetime


class MediaStore:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    def write(
        self, *, media_id: uuid.UUID, kind: str, data: bytes, suffix: str, ttl_s: int
    ) -> StoredMedia:
        safe_suffix = suffix if suffix in {".mp3", ".wav", ".m4a", ".aac", ".ogg"} else ".bin"
        relative = Path(kind) / str(media_id)[:2] / f"{media_id}{safe_suffix}"
        path = (self.settings.media_root / relative).resolve()
        root = self.settings.media_root.resolve()
        if root not in path.parents:
            raise ValueError("unsafe media path")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return StoredMedia(
            key=relative.as_posix(),
            path=path,
            bytes=len(data),
            sha256=hashlib.sha256(data).digest(),
            expires_at=datetime.now(UTC) + timedelta(seconds=ttl_s),
        )

    def resolve(self, storage_key: str) -> Path:
        root = self.settings.media_root.resolve()
        path = (root / storage_key).resolve()
        if root not in path.parents:
            raise ValueError("unsafe media path")
        return path

    def delete(self, storage_key: str) -> None:
        path = self.resolve(storage_key)
        try:
            path.unlink()
        except FileNotFoundError:
            pass

    def prune(self, kind: str, max_bytes: int) -> None:
        """Bound a disposable media cache by removing its oldest files."""
        root = (self.settings.media_root / kind).resolve()
        media_root = self.settings.media_root.resolve()
        if media_root not in root.parents or not root.exists():
            return
        files = [path for path in root.rglob("*") if path.is_file()]
        total = sum(path.stat().st_size for path in files)
        for path in sorted(files, key=lambda item: item.stat().st_mtime):
            if total <= max_bytes:
                break
            size = path.stat().st_size
            path.unlink(missing_ok=True)
            total -= size
