from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.asset_pipeline.hashing import sha256_file
from tools.asset_pipeline.integrity import capture_snapshot, compare_snapshots
from tools.asset_pipeline.phase4 import (
    Phase4Failure,
    _probe_media,
    _scan_runtime_leaks,
    build_manifests,
    dry_run_plan,
    source_asset_map_document,
    transcode_asset,
    validate_manifest_document,
    verify_media_file,
)
from tools.asset_pipeline.phase4_policy import EXPECTED_REVIEW_IDS, POOR_IDS, SEED_POLICY
from tools.asset_pipeline.probe import parse_ffprobe, run_ffprobe


def synthetic_records_and_states() -> tuple[list[dict], dict[str, dict], dict]:
    records: list[dict] = []
    states: dict[str, dict] = {}
    review = set(EXPECTED_REVIEW_IDS)
    suggestive_ids = {
        "chr_001", "chr_002", "chr_006", "chr_009", "chr_010", "chr_011",
        "chr_018", "chr_019", "chr_020", "chr_022", "chr_029", "chr_030",
        "chr_033", "chr_035", "chr_040", "chr_042", "chr_043",
    }
    for number in range(1, 44):
        asset_id = f"chr_{number:03d}"
        suggestive = asset_id in suggestive_ids
        excluded = asset_id in POOR_IDS
        modes = ["daily", "assistant", "relationship", "private"] if suggestive else ["relationship", "private"]
        records.append(
            {
                "asset_id": asset_id,
                "source_sha256": f"{number:064x}",
                "content_sensitivity": "suggestive" if suggestive else "private",
                "allowed_modes": modes,
                "delivery": "vault",
                "technical_quality": "poor" if excluded else "good",
                "review_flag": asset_id in review,
                "needs_visual_confirmation": suggestive,
                "excluded_by_default": excluded,
                "states": {"idle": "shared"},
                "state_mapping_status": "provisional",
                "cues": [],
                "kind": "oneshot" if excluded else "loop",
                "loop_quality": "crossfade",
                "loop_grade": "D" if excluded else "B",
                "start_end_match": 0.5,
                "motion_intensity": 0.2,
                "intensity_tags": [],
                "weight": 0.2 if excluded else 1.0,
                "interruptible": True,
                "cooldown_seconds": 0,
                "render_mode": "contain_blur" if suggestive else "cover",
                "focal_x": 0.5,
                "focal_y": 0.5,
            }
        )
        states[asset_id] = {
            "outputs": {
                "video": {"path": f"vault/{asset_id}.mp4", "sha256": f"{number + 100:064x}", "bytes": 100},
                "poster": {"path": f"vault/{asset_id}.poster.jpg", "sha256": "a" * 64, "bytes": 10},
                "poster_blur": {"path": f"vault/{asset_id}.blur.jpg", "sha256": "b" * 64, "bytes": 5},
            },
            "media": {
                "duration_ms": 1000,
                "width": 64,
                "height": 64,
                "fps": 24.0,
                "audio_streams": 0,
                "attached_picture_streams": 0,
                "subtitle_streams": 0,
                "data_streams": 0,
            },
        }
    snapshot = {"files": [{"mtime_ns": 1_700_000_000_000_000_000}]}
    return records, states, snapshot


def generated_source_video(directory: Path) -> tuple[Path, int, int]:
    cover = directory / "cover.jpg"
    source = directory / "fixture.mp4"
    commands = [
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=red:s=64x64", "-frames:v", "1", str(cover),
        ],
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=24:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=1000:duration=1",
            "-i", str(cover), "-t", "1",
            "-map", "0:v", "-map", "1:a", "-map", "2:v",
            "-c:v:0", "libx264", "-pix_fmt:v:0", "yuv420p", "-c:a", "aac",
            "-c:v:1", "mjpeg", "-disposition:v:1", "attached_pic", str(source),
        ],
    ]
    for command in commands:
        completed = subprocess.run(command, capture_output=True, text=True, check=False)
        if completed.returncode != 0:
            raise RuntimeError(completed.stderr)
    payload = run_ffprobe(source)
    parsed = parse_ffprobe(payload)
    return source, parsed["video"]["stream_index"], parsed["duration_ms"]


class Phase4PolicyAndManifestTests(unittest.TestCase):
    def test_asset_id_stability_follows_canonical_sorted_source_names(self) -> None:
        names = sorted(SEED_POLICY, key=lambda value: (value.casefold(), value))
        mapping = dict(zip(names, (f"chr_{number:03d}" for number in range(1, 44))))
        self.assertEqual(mapping["ARRJ9858.MP4"], "chr_001")
        self.assertEqual(mapping["DFRT1741.MP4"], "chr_011")
        self.assertEqual(mapping["KKWB4339.MP4"], "chr_022")
        self.assertEqual(mapping["YITD3424.MP4"], "chr_043")

    def test_source_asset_mapping_is_a_separate_development_document(self) -> None:
        records = [
            {
                "source_id": "src_a",
                "source_file": "ABCD1234.MP4",
                "source_sha256": "a" * 64,
                "asset_id": "chr_001",
            }
        ]
        document = source_asset_map_document(records)
        self.assertTrue(document["development_only"])
        self.assertFalse(document["ship_to_client"])
        self.assertEqual(document["assets"][0]["source_filename"], "ABCD1234.MP4")

    def test_manifest_views_preserve_43_master_and_default_mode_counts(self) -> None:
        records, states, snapshot = synthetic_records_and_states()
        manifests = build_manifests(records, states, snapshot)
        self.assertEqual(len(manifests["character_manifest.json"]["assets"]), 43)
        self.assertEqual(len(manifests["vault_manifest.json"]["assets"]), 43)
        self.assertEqual(len(manifests["daily_assistant_manifest.json"]["assets"]), 15)
        self.assertEqual(len(manifests["relationship_manifest.json"]["assets"]), 41)
        self.assertEqual(len(manifests["private_manifest.json"]["assets"]), 41)
        self.assertEqual(manifests["bundle_manifest.json"]["assets"], [])

    def test_allowed_modes_and_sensitivity_validation(self) -> None:
        records, states, snapshot = synthetic_records_and_states()
        document = build_manifests(records, states, snapshot)["character_manifest.json"]
        validate_manifest_document(document, master=True)
        broken = json.loads(json.dumps(document))
        broken["assets"][0]["allowed_modes"] = []
        with self.assertRaises(Phase4Failure):
            validate_manifest_document(broken, master=True)
        broken = json.loads(json.dumps(document))
        broken["assets"][0]["content_sensitivity"] = "unknown"
        with self.assertRaises(Phase4Failure):
            validate_manifest_document(broken, master=True)

    def test_review_flags_and_poor_asset_policy_are_preserved(self) -> None:
        records, _, _ = synthetic_records_and_states()
        self.assertEqual({item["asset_id"] for item in records if item["review_flag"]}, EXPECTED_REVIEW_IDS)
        poor = [item for item in records if item["asset_id"] in POOR_IDS]
        self.assertEqual(len(poor), 2)
        self.assertTrue(all(item["excluded_by_default"] for item in poor))
        self.assertTrue(all(item["technical_quality"] == "poor" for item in poor))
        self.assertTrue(all(item["kind"] == "oneshot" and item["weight"] == 0.2 for item in poor))

    def test_path_traversal_is_rejected_by_manifest_validation(self) -> None:
        records, states, snapshot = synthetic_records_and_states()
        document = build_manifests(records, states, snapshot)["character_manifest.json"]
        document["assets"][0]["path"] = "../escape.mp4"
        with self.assertRaises((Phase4Failure, ValueError)):
            validate_manifest_document(document, master=True)

    def test_source_filename_leakage_is_rejected(self) -> None:
        records, states, snapshot = synthetic_records_and_states()
        manifests = build_manifests(records, states, snapshot)
        manifests["character_manifest.json"]["assets"][0]["semantic_tags"] = ["ABCD1234.MP4"]
        with self.assertRaises(Phase4Failure):
            _scan_runtime_leaks(manifests, ["ABCD1234.MP4"])


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg tools are required")
class Phase4MediaIntegrationTests(unittest.TestCase):
    def _item(self, source: Path, stream_index: int, duration_ms: int) -> dict:
        return {
            "asset_id": "chr_001",
            "delivery": "vault",
            "source_path": source,
            "main_stream_index": stream_index,
            "source_duration_ms": duration_ms,
        }

    def test_audio_and_attached_picture_are_stripped_and_source_is_immutable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_root = root / "assets_source"
            output = root / "output"
            source_root.mkdir()
            source, stream_index, duration_ms = generated_source_video(source_root)
            before = capture_snapshot(source_root)
            state, reused = transcode_asset(
                self._item(source, stream_index, duration_ms),
                output,
                input_fingerprint="fixture-v1",
                previous_state=None,
            )
            self.assertFalse(reused)
            verified = verify_media_file(output / "vault" / "chr_001.mp4", expected_duration_ms=duration_ms)
            self.assertEqual(verified["audio_streams"], 0)
            self.assertEqual(verified["attached_picture_streams"], 0)
            self.assertEqual(verified["stream_count"], 1)
            self.assertEqual(compare_snapshots(before, capture_snapshot(source_root))["status"], "PASS")
            self.assertTrue((output / state["outputs"]["poster"]["path"]).is_file())

    def test_idempotent_resume_skips_verified_output_and_repairs_partial_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_root = root / "assets_source"
            output = root / "output"
            source_root.mkdir()
            source, stream_index, duration_ms = generated_source_video(source_root)
            item = self._item(source, stream_index, duration_ms)
            first, reused = transcode_asset(
                item, output, input_fingerprint="fixture-v1", previous_state=None
            )
            self.assertFalse(reused)
            video_hash = sha256_file(output / first["outputs"]["video"]["path"])
            second, reused = transcode_asset(
                item, output, input_fingerprint="fixture-v1", previous_state=first
            )
            self.assertTrue(reused)
            self.assertEqual(first, second)
            (output / first["outputs"]["poster"]["path"]).unlink()
            repaired, reused = transcode_asset(
                item, output, input_fingerprint="fixture-v1", previous_state=first
            )
            self.assertFalse(reused)
            self.assertTrue((output / repaired["outputs"]["poster"]["path"]).is_file())
            self.assertEqual(sha256_file(output / repaired["outputs"]["video"]["path"]), video_hash)

    def test_ffmpeg_failure_is_reported_without_production_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "fixture.mp4"
            source.write_bytes(b"fixture")
            output = root / "output"

            def failed(command: list[str]) -> subprocess.CompletedProcess[str]:
                return subprocess.CompletedProcess(command, 7, "", "intentional failure")

            with self.assertRaisesRegex(Phase4Failure, "exit 7"):
                transcode_asset(
                    self._item(source, 0, 1000),
                    output,
                    input_fingerprint="failure",
                    previous_state=None,
                    runner=failed,
                )
            self.assertFalse((output / "vault" / "chr_001.mp4").exists())


class Phase4RobustnessTests(unittest.TestCase):
    def test_malformed_ffprobe_output_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "bad.mp4"
            path.write_bytes(b"x")
            with mock.patch("tools.asset_pipeline.phase4.run_ffprobe", return_value={"streams": "bad"}):
                with self.assertRaisesRegex(Phase4Failure, "malformed"):
                    _probe_media(path)

    def test_dry_run_does_not_create_or_modify_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "assets_source"
            analysis = root / "asset_analysis"
            output = root / "output"
            source.mkdir()
            analysis.mkdir()
            (source / "fixture.mp4").write_bytes(b"video")
            snapshot = capture_snapshot(source)
            fake_records = [
                {"asset_id": "chr_001", "delivery": "vault", "excluded_by_default": False}
            ]
            with mock.patch("tools.asset_pipeline.phase4.capture_snapshot", return_value=snapshot), mock.patch(
                "tools.asset_pipeline.phase4.build_policy_records", return_value=fake_records
            ):
                plan = dry_run_plan(source, analysis, output)
            self.assertTrue(plan["dry_run"])
            self.assertEqual(plan["production_writes"], 0)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
