"""Build a deterministic, Git-external Character Media publish directory."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_relative(value: str, expected: str) -> None:
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or "\\" in value or value != expected:
        raise ValueError(f"unsafe or unexpected manifest path: {value}")


def build(source: Path, manifest_path: Path, output: Path, replace: bool) -> dict:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assets = manifest.get("assets")
    if manifest.get("schema_version") != 2 or manifest.get("manifest_kind") != "vault":
        raise ValueError("runtime vault manifest schema/kind is invalid")
    if not isinstance(assets, list) or len(assets) != 43:
        raise ValueError("current Phase 4 publish package must contain 43 assets")
    ids = [asset.get("asset_id") for asset in assets]
    expected_ids = [f"chr_{index:03d}" for index in range(1, 44)]
    if ids != expected_ids:
        raise ValueError("canonical chr_001..chr_043 sequence is missing")
    excluded = [asset["asset_id"] for asset in assets if asset["excluded_by_default"]]
    if excluded != ["chr_011", "chr_022"]:
        raise ValueError("excluded-by-default policy changed")

    output_parent = output.resolve().parent
    output_parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{output.name}-", dir=output_parent))
    integrity_assets: list[dict] = []
    try:
        (staging / "manifest").mkdir()
        (staging / "assets").mkdir()
        (staging / "posters").mkdir()
        shutil.copyfile(manifest_path, staging / "manifest" / "character_manifest.json")
        for asset in assets:
            asset_id = asset["asset_id"]
            validate_relative(asset["path"], f"vault/{asset_id}.mp4")
            video = source / "vault" / f"{asset_id}.mp4"
            if not video.is_file():
                raise FileNotFoundError(video)
            size = video.stat().st_size
            digest = sha256_file(video)
            if size != asset["bytes"] or digest != asset["sha256"]:
                raise ValueError(f"integrity mismatch: {asset_id}")
            shutil.copyfile(video, staging / "assets" / f"{asset_id}.mp4")

            posters: dict[str, str] = {}
            for suffix, key in (("poster.jpg", "poster"), ("blur.jpg", "blur")):
                candidate = source / "vault" / f"{asset_id}.{suffix}"
                if candidate.is_file():
                    target_name = f"{asset_id}.{suffix}"
                    shutil.copyfile(candidate, staging / "posters" / target_name)
                    posters[key] = sha256_file(candidate)
            integrity_assets.append(
                {
                    "asset_id": asset_id,
                    "path": f"assets/{asset_id}.mp4",
                    "bytes": size,
                    "sha256": digest,
                    "posters": posters,
                }
            )

        integrity = {
            "schema_version": 1,
            "manifest_version": manifest["manifest_version"],
            "asset_count": len(integrity_assets),
            "assets": integrity_assets,
        }
        (staging / "integrity.json").write_text(
            json.dumps(integrity, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        if output.exists():
            if not replace:
                raise FileExistsError(f"output exists: {output}; pass --replace")
            backup = output.with_name(f".{output.name}.previous")
            if backup.exists():
                shutil.rmtree(backup)
            output.rename(backup)
            try:
                staging.rename(output)
                shutil.rmtree(backup)
            except BaseException:
                if not output.exists() and backup.exists():
                    backup.rename(output)
                raise
        else:
            staging.rename(output)
        return integrity
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--replace", action="store_true")
    args = parser.parse_args()
    try:
        result = build(args.source.resolve(), args.manifest.resolve(), args.output, args.replace)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"publish failed: {error}", file=sys.stderr)
        return 1
    print(
        f"published {result['asset_count']} verified assets "
        f"for manifest {result['manifest_version']} to {args.output.resolve()}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
