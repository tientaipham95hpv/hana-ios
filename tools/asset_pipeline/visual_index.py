from __future__ import annotations

from typing import Any

from .duplicates import exact_group_map
from .keyframes import FRAME_PERCENTAGES, calculate_timestamps


def build_visual_index(inventory: dict[str, Any], duplicates: dict[str, Any]) -> dict[str, Any]:
    group_map = exact_group_map(duplicates)
    records = []
    for item in inventory.get("videos", []):
        source_id = item["source_id"]
        video = item["video"]
        timestamps = calculate_timestamps(item["duration_ms"], video.get("avg_frame_rate_fps"))
        records.append(
            {
                "source_id": source_id,
                "source_filename": item["original_filename"],
                "duration_ms": item["duration_ms"],
                "width": video["width"],
                "height": video["height"],
                "aspect_ratio": round(video["width"] / video["height"], 6),
                "fps": video.get("avg_frame_rate_fps"),
                "contact_sheet": f"contact_sheets/{source_id}.jpg",
                "keyframes": [
                    {
                        "percentage": frame["percentage"],
                        "timestamp_ms": frame["timestamp_ms"],
                        "path": f"keyframes/{source_id}/{frame['percentage']:03d}.jpg",
                    }
                    for frame in timestamps
                ],
                "exact_duplicate_group": group_map.get(source_id),
                "near_duplicate_candidates": [],
            }
        )
    records.sort(key=lambda item: item["source_id"])
    return {
        "schema_version": 1,
        "path_base": "asset_analysis",
        "records": records,
    }
