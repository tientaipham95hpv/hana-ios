from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .phase4 import (
    Phase4Failure,
    dry_run_plan,
    record_test_result,
    run_build,
    run_validate,
)


def _defaults() -> tuple[Path, Path, Path, Path]:
    repo_root = Path(__file__).resolve().parents[2]
    project_root = repo_root.parent
    return (
        repo_root,
        project_root / "assets_source",
        project_root / "asset_analysis",
        project_root / "assets_processed" / "hana",
    )


def build_parser() -> argparse.ArgumentParser:
    repo_root, source_root, analysis_root, output_root = _defaults()
    parser = argparse.ArgumentParser(description="Hana Phase 4 app-ready video library pipeline")
    parser.add_argument("command", choices=("build", "validate", "record-tests"))
    parser.add_argument("--source", type=Path, default=source_root)
    parser.add_argument("--analysis", type=Path, default=analysis_root)
    parser.add_argument("--output", type=Path, default=output_root)
    parser.add_argument("--repo", type=Path, default=repo_root)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--ffprobe", default="ffprobe")
    parser.add_argument("--concurrency", type=int, default=4)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--test-status", choices=("PASS", "FAIL"))
    parser.add_argument("--tests-run", type=int, default=0)
    parser.add_argument(
        "--test-command",
        default="python -m unittest discover -s tools/asset_pipeline/tests -v",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.dry_run:
            if args.command != "build":
                raise Phase4Failure("--dry-run is only valid with build")
            result = dry_run_plan(args.source, args.analysis, args.output)
        elif args.command == "build":
            result = run_build(
                args.source,
                args.analysis,
                args.output,
                args.repo,
                ffmpeg_bin=args.ffmpeg,
                ffprobe_bin=args.ffprobe,
                concurrency=args.concurrency,
            )
        elif args.command == "validate":
            result = run_validate(
                args.source,
                args.analysis,
                args.output,
                args.repo,
                ffprobe_bin=args.ffprobe,
            )
        elif args.command == "record-tests":
            if args.test_status is None:
                raise Phase4Failure("record-tests requires --test-status")
            result = record_test_result(
                args.repo,
                args.output,
                status=args.test_status,
                tests_run=args.tests_run,
                command=args.test_command,
            )
        else:
            raise AssertionError(args.command)
    except (Phase4Failure, OSError, ValueError, RuntimeError) as exc:
        print(
            json.dumps(
                {"status": "FAIL", "error": f"{type(exc).__name__}: {exc}"},
                ensure_ascii=False,
            ),
            file=sys.stderr,
        )
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if result.get("status") == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
