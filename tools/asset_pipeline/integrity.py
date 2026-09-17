from __future__ import annotations

from pathlib import Path
from typing import Any

from .hashing import sha256_file
from .models import IntegrityDifference
from .paths import discover_files, relative_portable


def capture_snapshot(source_root: Path) -> dict[str, Any]:
    root = source_root.resolve(strict=True)
    files: list[dict[str, Any]] = []
    for path in discover_files(root):
        before = path.stat()
        digest = sha256_file(path)
        after = path.stat()
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise RuntimeError(f"source changed during snapshot: {path.name}")
        files.append(
            {
                "relative_path": relative_portable(path, root),
                "bytes": after.st_size,
                "mtime_ns": after.st_mtime_ns,
                "sha256": digest,
            }
        )
    files.sort(key=lambda item: (item["relative_path"].casefold(), item["relative_path"]))
    return {"schema_version": 1, "source_root": "assets_source", "files": files}


def compare_snapshots(before: dict[str, Any], after: dict[str, Any]) -> dict[str, Any]:
    before_map = {item["relative_path"]: item for item in before.get("files", [])}
    after_map = {item["relative_path"]: item for item in after.get("files", [])}
    missing = sorted(set(before_map) - set(after_map), key=str.casefold)
    added = sorted(set(after_map) - set(before_map), key=str.casefold)
    modified: list[IntegrityDifference] = []
    for relative in sorted(set(before_map) & set(after_map), key=str.casefold):
        fields = tuple(
            field
            for field in ("bytes", "sha256", "mtime_ns")
            if before_map[relative].get(field) != after_map[relative].get(field)
        )
        if fields:
            modified.append(IntegrityDifference(relative, fields))
    status = "PASS" if not missing and not added and not modified else "FAIL"
    return {
        "schema_version": 1,
        "status": status,
        "files_before": len(before_map),
        "files_after": len(after_map),
        "matching_files": len(before_map) - len(missing) - len(modified),
        "missing": missing,
        "added": added,
        "modified": [item.to_dict() for item in modified],
    }
