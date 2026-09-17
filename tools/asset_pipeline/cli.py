from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .io_utils import write_json
from .report import write_report
from .runner import (
    PipelineFailure,
    dry_run_plan,
    run_all,
    run_extract,
    run_scan,
    run_verify,
    validate_roots,
)


def _defaults() -> tuple[Path, Path, Path]:
    repo_root = Path(__file__).resolve().parents[2]
    project_root = repo_root.parent
    return repo_root, project_root / "assets_source", project_root / "asset_analysis"


def _common_parser() -> argparse.ArgumentParser:
    _, source, output = _defaults()
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--source", type=Path, default=source)
    common.add_argument("--output", type=Path, default=output)
    common.add_argument("--concurrency", type=int, default=4)
    common.add_argument("--ffprobe", default="ffprobe")
    common.add_argument("--ffmpeg", default="ffmpeg")
    common.add_argument("--dry-run", action="store_true")
    return common


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Hana Phase 2 read-only source asset pipeline")
    subparsers = parser.add_subparsers(dest="command", required=True)
    common = _common_parser()
    for command in ("scan", "extract", "verify", "all"):
        subparsers.add_parser(command, parents=[common])
    report = subparsers.add_parser("report", parents=[common])
    report.add_argument("--test-status", choices=("PASS", "FAIL"))
    report.add_argument("--tests-run", type=int, default=0)
    report.add_argument(
        "--test-command",
        default="python -m unittest discover -s tools/asset_pipeline/tests -v",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    repo_root, _, _ = _defaults()
    source_root = args.source.resolve(strict=False)
    output_root = args.output.resolve(strict=False)
    try:
        validate_roots(source_root, output_root)
        if args.dry_run:
            result = dry_run_plan(args.command, source_root, output_root)
        elif args.command == "scan":
            result = run_scan(source_root, output_root, ffprobe_bin=args.ffprobe, concurrency=args.concurrency)
        elif args.command == "extract":
            result = run_extract(source_root, output_root, repo_root, ffmpeg_bin=args.ffmpeg, concurrency=args.concurrency)
        elif args.command == "verify":
            result = run_verify(source_root, output_root, repo_root)
        elif args.command == "all":
            result = run_all(
                source_root,
                output_root,
                repo_root,
                ffprobe_bin=args.ffprobe,
                ffmpeg_bin=args.ffmpeg,
                concurrency=args.concurrency,
            )
        elif args.command == "report":
            if args.test_status:
                write_json(
                    output_root / "test_results.json",
                    {
                        "schema_version": 1,
                        "status": args.test_status,
                        "tests_run": args.tests_run,
                        "command": args.test_command,
                    },
                )
            path = write_report(repo_root, output_root)
            result = {"status": "PASS", "report": str(path)}
        else:
            raise AssertionError(args.command)
    except (PipelineFailure, OSError, ValueError, RuntimeError) as exc:
        print(json.dumps({"status": "FAIL", "error": f"{type(exc).__name__}: {exc}"}, ensure_ascii=False), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if result.get("status") == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
