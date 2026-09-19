"""Small Range-capable media fixture server with deterministic fault injection."""

from __future__ import annotations

import argparse
import http.server
import mimetypes
import re
from pathlib import Path
from urllib.parse import unquote, urlsplit


class MediaHandler(http.server.SimpleHTTPRequestHandler):
    root: Path
    fail_first: int
    corrupt_asset: str | None
    offline: bool
    requests_seen = 0

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        type(self).requests_seen += 1
        if self.offline:
            self.send_error(503, "offline simulation")
            return
        if type(self).requests_seen <= self.fail_first:
            self.send_error(503, "retry simulation")
            return
        route = unquote(urlsplit(self.path).path)
        if route == "/manifest/character_manifest.json":
            self._send_file(self.root / "manifest" / "character_manifest.json")
            return
        match = re.fullmatch(r"/assets/(chr_\d{3})\.mp4", route)
        if match:
            self._send_file(
                self.root / "assets" / f"{match.group(1)}.mp4",
                corrupt=match.group(1) == self.corrupt_asset,
            )
            return
        poster = re.fullmatch(r"/posters/(chr_\d{3})\.(poster|blur)\.jpg", route)
        if poster:
            self._send_file(self.root / "posters" / route.rsplit("/", 1)[-1])
            return
        self.send_error(404)

    def _send_file(self, path: Path, corrupt: bool = False) -> None:
        try:
            resolved = path.resolve(strict=True)
            resolved.relative_to(self.root.resolve(strict=True))
        except (OSError, ValueError):
            self.send_error(404)
            return
        data = resolved.read_bytes()
        if corrupt and data:
            data = data[:-1] + bytes([data[-1] ^ 0xFF])
        start = 0
        range_header = self.headers.get("Range")
        if range_header:
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", range_header)
            if not match:
                self.send_error(416)
                return
            start = int(match.group(1))
            if start >= len(data):
                self.send_error(416)
                return
            requested_end = int(match.group(2)) if match.group(2) else len(data) - 1
            end = min(requested_end, len(data) - 1)
            if end < start:
                self.send_error(416)
                return
        else:
            end = len(data) - 1
        body = data[start : end + 1]
        self.send_response(206 if start else 200)
        self.send_header(
            "Content-Type", mimetypes.guess_type(resolved.name)[0] or "application/octet-stream"
        )
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(len(body)))
        if start:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
        self.end_headers()
        self.wfile.write(body)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--fail-first", type=int, default=0)
    parser.add_argument("--corrupt-asset")
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    MediaHandler.root = args.root.resolve(strict=True)
    MediaHandler.fail_first = max(0, args.fail_first)
    MediaHandler.corrupt_asset = args.corrupt_asset
    MediaHandler.offline = args.offline
    server = http.server.ThreadingHTTPServer((args.host, args.port), MediaHandler)
    print(f"serving {MediaHandler.root} at http://{args.host}:{args.port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
