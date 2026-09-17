from __future__ import annotations

import hashlib
import os
from pathlib import Path, PurePosixPath
from typing import Iterable


VIDEO_EXTENSIONS = frozenset({".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm"})


class UnsafePathError(ValueError):
    pass


def validate_relative_portable(value: str) -> str:
    if not value or "\\" in value or "\x00" in value or ":" in value:
        raise UnsafePathError(f"not a portable relative path: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise UnsafePathError(f"not a portable relative path: {value!r}")
    return path.as_posix()


def relative_portable(path: Path, root: Path) -> str:
    resolved_root = root.resolve(strict=True)
    resolved_path = path.resolve(strict=True)
    try:
        relative = resolved_path.relative_to(resolved_root)
    except ValueError as exc:
        raise UnsafePathError(f"path escapes source root: {path}") from exc
    return validate_relative_portable(relative.as_posix())


def safe_source_path(root: Path, relative: str) -> Path:
    validate_relative_portable(relative)
    candidate = root.joinpath(*PurePosixPath(relative).parts)
    if candidate.is_symlink():
        raise UnsafePathError(f"source symlink is not allowed: {relative}")
    relative_portable(candidate, root)
    return candidate


def ensure_output_outside_source(source_root: Path, output_root: Path) -> None:
    source = source_root.resolve(strict=True)
    output = output_root.resolve(strict=False)
    try:
        output.relative_to(source)
    except ValueError:
        return
    raise UnsafePathError("analysis output must be outside assets_source")


def discover_files(source_root: Path) -> list[Path]:
    root = source_root.resolve(strict=True)
    discovered: list[Path] = []

    def walk(directory: Path) -> None:
        with os.scandir(directory) as iterator:
            entries = sorted(iterator, key=lambda entry: (entry.name.casefold(), entry.name))
        for entry in entries:
            path = Path(entry.path)
            if entry.is_symlink():
                raise UnsafePathError(f"source symlink/reparse point is not allowed: {path}")
            if entry.is_dir(follow_symlinks=False):
                walk(path)
            elif entry.is_file(follow_symlinks=False):
                relative_portable(path, root)
                discovered.append(path)
    walk(root)
    return sorted(discovered, key=lambda path: relative_portable(path, root).casefold())


def discover_videos(source_root: Path) -> list[Path]:
    return [path for path in discover_files(source_root) if path.suffix.casefold() in VIDEO_EXTENSIONS]


def assign_source_ids(items: Iterable[tuple[str, str]]) -> dict[str, str]:
    """Map portable relative path to an ID based on content, with a path-only tie breaker.

    The SHA prefix is the content identity. The relative-path digest only keeps exact
    duplicate copies distinct so each record has a unique output directory.
    """
    ordered = sorted(items, key=lambda item: (item[0].casefold(), item[0]))
    result: dict[str, str] = {}
    used: set[str] = set()
    for relative, sha256 in ordered:
        path_digest = hashlib.sha256(relative.encode("utf-8")).hexdigest()
        content_length = 16
        path_length = 8
        while True:
            candidate = f"src_{sha256[:content_length]}_{path_digest[:path_length]}"
            if candidate not in used:
                break
            if content_length < len(sha256):
                content_length += 4
            elif path_length < len(path_digest):
                path_length += 4
            else:
                raise RuntimeError("unable to create collision-free source_id")
        used.add(candidate)
        result[relative] = candidate
    return result
