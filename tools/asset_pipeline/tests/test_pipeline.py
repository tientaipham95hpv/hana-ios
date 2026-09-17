from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from PIL import Image

from tools.asset_pipeline.duplicates import build_duplicates
from tools.asset_pipeline.hashing import sha256_file
from tools.asset_pipeline.integrity import capture_snapshot, compare_snapshots
from tools.asset_pipeline.inventory import build_inventory, inventory_csv
from tools.asset_pipeline.keyframes import calculate_timestamps, extract_visuals
from tools.asset_pipeline.paths import (
    UnsafePathError,
    assign_source_ids,
    safe_source_path,
    validate_relative_portable,
)
from tools.asset_pipeline.probe import ProbeError, parse_ffprobe, select_main_video_stream
from tools.asset_pipeline.runner import dry_run_plan
from tools.asset_pipeline.visual_index import build_visual_index


def probe_payload(*, width: int = 544, height: int = 544, attached_first: bool = False) -> dict:
    main = {
        "index": 0 if not attached_first else 1,
        "codec_type": "video",
        "codec_name": "h264",
        "profile": "High",
        "level": 40,
        "width": width,
        "height": height,
        "sample_aspect_ratio": "1:1",
        "display_aspect_ratio": "1:1",
        "pix_fmt": "yuv420p",
        "avg_frame_rate": "24/1",
        "r_frame_rate": "24/1",
        "nb_read_frames": "145",
        "bit_rate": "1000000",
        "duration": "6.040000",
        "disposition": {"default": 1, "attached_pic": 0},
        "color_space": "bt709",
    }
    attached = {
        "index": 0 if attached_first else 2,
        "codec_type": "video",
        "codec_name": "mjpeg",
        "width": 544,
        "height": 544,
        "disposition": {"default": 0, "attached_pic": 1},
    }
    audio = {
        "index": 2 if attached_first else 1,
        "codec_type": "audio",
        "codec_name": "aac",
        "sample_rate": "44100",
        "channels": 2,
        "channel_layout": "stereo",
        "disposition": {"default": 1, "attached_pic": 0},
    }
    return {
        "streams": [attached, main, audio] if attached_first else [main, audio, attached],
        "format": {
            "format_name": "mov,mp4,m4a,3gp,3g2,mj2",
            "start_time": "0.000000",
            "duration": "6.040000",
            "bit_rate": "1200000",
            "tags": {"major_brand": "isom", "comment": "must not be retained"},
        },
    }


class PathAndHashTests(unittest.TestCase):
    def test_path_traversal_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "source"
            root.mkdir()
            outside = Path(temporary) / "outside.mp4"
            outside.write_bytes(b"x")
            with self.assertRaises(UnsafePathError):
                safe_source_path(root, "../outside.mp4")
            for value in ("/absolute.mp4", "C:/drive.mp4", "dir\\file.mp4"):
                with self.assertRaises(UnsafePathError):
                    validate_relative_portable(value)

    def test_sha256_is_streamed_and_correct(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "sample.bin"
            path.write_bytes(b"abc")
            self.assertEqual(
                sha256_file(path, chunk_size=1),
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            )

    def test_source_ids_are_stable_and_duplicate_safe(self) -> None:
        items = [("B.MP4", "a" * 64), ("A.MP4", "a" * 64), ("C.MP4", "b" * 64)]
        first = assign_source_ids(items)
        second = assign_source_ids(reversed(items))
        self.assertEqual(first, second)
        self.assertEqual(len(set(first.values())), 3)
        self.assertTrue(all(value.startswith("src_") for value in first.values()))


class ProbeTests(unittest.TestCase):
    def test_attached_picture_is_not_selected_as_main_video(self) -> None:
        payload = probe_payload(attached_first=True)
        main = select_main_video_stream(payload["streams"])
        self.assertEqual(main["index"], 1)
        self.assertEqual(main["codec_name"], "h264")

    def test_ffprobe_parser_collects_required_stream_data(self) -> None:
        parsed = parse_ffprobe(probe_payload(attached_first=True))
        self.assertEqual(parsed["duration_ms"], 6040)
        self.assertEqual(parsed["video"]["stream_index"], 1)
        self.assertEqual(parsed["video"]["avg_frame_rate_fps"], 24.0)
        self.assertEqual(parsed["audio"]["stream_count"], 1)
        self.assertEqual(parsed["other_streams"]["attached_pic"][0]["codec_name"], "mjpeg")
        self.assertNotIn("comment", parsed["container"]["tags"])

    def test_no_main_video_is_an_error(self) -> None:
        with self.assertRaises(ProbeError):
            select_main_video_stream([probe_payload()["streams"][2]])


class InventoryAndDuplicateTests(unittest.TestCase):
    def _source_and_snapshot(self, directory: Path, names: tuple[str, ...]) -> tuple[Path, dict]:
        source = directory / "assets_source"
        source.mkdir()
        for index, name in enumerate(names):
            (source / name).write_bytes(f"video-{index}".encode())
        return source, capture_snapshot(source)

    def test_inventory_and_csv_are_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, snapshot = self._source_and_snapshot(Path(temporary), ("B.MP4", "a.MP4"))
            first, errors, _ = build_inventory(source, snapshot, probe_func=lambda _: probe_payload(), concurrency=2)
            second, errors2, reused = build_inventory(
                source, snapshot, previous=first, probe_func=lambda _: probe_payload(), concurrency=2
            )
            self.assertFalse(errors)
            self.assertFalse(errors2)
            self.assertEqual(reused, 2)
            self.assertEqual(first, second)
            self.assertEqual(inventory_csv(first), inventory_csv(second))
            self.assertNotIn(str(source), json.dumps(first))

    def test_one_probe_failure_preserves_other_inventory_records(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, snapshot = self._source_and_snapshot(Path(temporary), ("good.MP4", "bad.MP4"))

            def fake_probe(path: Path) -> dict:
                if path.name == "bad.MP4":
                    raise ProbeError("broken", 1, "invalid input")
                return probe_payload()

            inventory, errors, _ = build_inventory(source, snapshot, probe_func=fake_probe, concurrency=2)
            self.assertEqual(len(inventory["videos"]), 1)
            self.assertEqual(inventory["videos"][0]["original_filename"], "good.MP4")
            self.assertEqual(len(errors), 1)
            self.assertEqual(inventory["summary"]["inventory_failure_count"], 1)

    def test_exact_duplicate_grouping_does_not_choose_a_winner(self) -> None:
        inventory = {
            "videos": [
                {"source_id": "src_a", "sha256": "f" * 64, "relative_source_path": "a.MP4"},
                {"source_id": "src_b", "sha256": "f" * 64, "relative_source_path": "b.MP4"},
                {"source_id": "src_c", "sha256": "e" * 64, "relative_source_path": "c.MP4"},
            ]
        }
        duplicates = build_duplicates(inventory)
        self.assertEqual(len(duplicates["exact_duplicates"]), 1)
        self.assertEqual(duplicates["exact_duplicates"][0]["source_ids"], ["src_a", "src_b"])
        self.assertEqual(duplicates["near_duplicate_candidates"], [])


class TimestampAndVisualTests(unittest.TestCase):
    def test_timestamps_include_eof_safe_100_percent(self) -> None:
        frames = calculate_timestamps(10_000, 25.0)
        self.assertEqual([item["percentage"] for item in frames], [0, 20, 40, 60, 80, 100])
        self.assertEqual([item["timestamp_ms"] for item in frames[:-1]], [0, 2000, 4000, 6000, 8000])
        self.assertEqual(frames[-1]["timestamp_ms"], 9960)
        self.assertLess(frames[-1]["timestamp_ms"], 10_000)

    def test_visual_index_paths_are_relative_and_portable(self) -> None:
        inventory = {
            "videos": [
                {
                    "source_id": "src_abc_123",
                    "original_filename": "A.MP4",
                    "duration_ms": 1000,
                    "video": {"width": 720, "height": 1280, "avg_frame_rate_fps": 24.0},
                }
            ]
        }
        index = build_visual_index(inventory, {"exact_duplicates": []})
        record = index["records"][0]
        validate_relative_portable(record["contact_sheet"])
        for frame in record["keyframes"]:
            validate_relative_portable(frame["path"])
            self.assertNotIn("C:\\", frame["path"])

    def test_resume_skips_valid_visual_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "assets_source"
            output = root / "asset_analysis"
            source.mkdir()
            video_path = source / "A.MP4"
            video_path.write_bytes(b"fake-video")
            item = {
                "source_id": "src_test_00000001",
                "relative_source_path": "A.MP4",
                "original_filename": "A.MP4",
                "sha256": sha256_file(video_path),
                "duration_ms": 1000,
                "video": {"stream_index": 0, "width": 64, "height": 64, "avg_frame_rate_fps": 25.0},
            }
            inventory = {"videos": [item]}
            calls: list[list[str]] = []

            def fake_ffmpeg(command: list[str]) -> subprocess.CompletedProcess[str]:
                calls.append(list(command))
                destination = Path(command[-1])
                Image.new("RGB", (64, 64), (len(calls), 20, 30)).save(destination, "JPEG")
                return subprocess.CompletedProcess(command, 0, "", "")

            state, errors, skipped = extract_visuals(
                source, output, inventory, concurrency=1, runner=fake_ffmpeg
            )
            self.assertFalse(errors)
            self.assertEqual(skipped, 0)
            self.assertEqual(len(calls), 6)
            state2, errors2, skipped2 = extract_visuals(
                source, output, inventory, previous_state=state, concurrency=1, runner=fake_ffmpeg
            )
            self.assertFalse(errors2)
            self.assertEqual(skipped2, 1)
            self.assertEqual(len(calls), 6)
            self.assertEqual(state, state2)

    def test_ffmpeg_failure_is_isolated_and_records_return_code(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "assets_source"
            output = root / "asset_analysis"
            source.mkdir()
            video_path = source / "broken.MP4"
            video_path.write_bytes(b"fake-video")
            inventory = {
                "videos": [
                    {
                        "source_id": "src_broken_0001",
                        "relative_source_path": "broken.MP4",
                        "original_filename": "broken.MP4",
                        "sha256": sha256_file(video_path),
                        "duration_ms": 1000,
                        "video": {"stream_index": 0, "width": 64, "height": 64, "avg_frame_rate_fps": 25.0},
                    }
                ]
            }

            def failed_ffmpeg(command: list[str]) -> subprocess.CompletedProcess[str]:
                return subprocess.CompletedProcess(command, 7, "", "decode failed")

            state, errors, _ = extract_visuals(
                source, output, inventory, concurrency=1, runner=failed_ffmpeg
            )
            self.assertEqual(state["assets"], {})
            self.assertEqual(len(errors), 1)
            self.assertEqual(errors[0]["category"], "ffmpeg_extract")
            self.assertEqual(errors[0]["return_code"], 7)
            self.assertEqual(errors[0]["relative_source_path"], "broken.MP4")


class IntegrityAndDryRunTests(unittest.TestCase):
    def test_integrity_comparison_detects_content_change_even_if_size_matches(self) -> None:
        before = {"files": [{"relative_path": "A.MP4", "bytes": 3, "mtime_ns": 1, "sha256": "a"}]}
        after = {"files": [{"relative_path": "A.MP4", "bytes": 3, "mtime_ns": 1, "sha256": "b"}]}
        result = compare_snapshots(before, after)
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(result["modified"][0]["fields"], ["sha256"])

    def test_integrity_comparison_detects_added_and_missing_files(self) -> None:
        before = {"files": [{"relative_path": "A.MP4", "bytes": 1, "mtime_ns": 1, "sha256": "a"}]}
        after = {"files": [{"relative_path": "B.MP4", "bytes": 1, "mtime_ns": 1, "sha256": "b"}]}
        result = compare_snapshots(before, after)
        self.assertEqual(result["missing"], ["A.MP4"])
        self.assertEqual(result["added"], ["B.MP4"])

    def test_dry_run_creates_no_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "assets_source"
            output = root / "asset_analysis"
            source.mkdir()
            (source / "A.MP4").write_bytes(b"video")
            plan = dry_run_plan("all", source, output)
            self.assertEqual(plan["status"], "PASS")
            self.assertTrue(plan["dry_run"])
            self.assertEqual(plan["source_videos"], 1)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
