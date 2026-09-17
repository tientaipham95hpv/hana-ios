from __future__ import annotations

from collections import defaultdict
from typing import Any


def build_duplicates(inventory: dict[str, Any]) -> dict[str, Any]:
    by_sha: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for item in inventory.get("videos", []):
        by_sha[item["sha256"]].append(item)
    exact = []
    for sha256, items in sorted(by_sha.items()):
        if len(items) < 2:
            continue
        ordered = sorted(items, key=lambda item: item["source_id"])
        exact.append(
            {
                "group_id": f"exact_{sha256[:16]}",
                "sha256": sha256,
                "source_ids": [item["source_id"] for item in ordered],
                "relative_source_paths": [item["relative_source_path"] for item in ordered],
            }
        )
    return {
        "schema_version": 1,
        "exact_duplicates": exact,
        "near_duplicate_candidates": [],
        "near_duplicate_detection": {
            "status": "not_implemented",
            "reason": (
                "Phase 2 does not emit speculative matches. A calibrated sampled-frame "
                "perceptual-hash threshold and review corpus are not yet available."
            ),
        },
    }


def exact_group_map(duplicates: dict[str, Any]) -> dict[str, str]:
    result: dict[str, str] = {}
    for group in duplicates.get("exact_duplicates", []):
        for source_id in group.get("source_ids", []):
            result[source_id] = group["group_id"]
    return result
