from __future__ import annotations

from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw, ImageFont, ImageOps


def _font(size: int) -> ImageFont.ImageFont:
    for name in ("arial.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            pass
    return ImageFont.load_default()


def create_contact_sheet(
    frame_paths: list[Path],
    timestamps: list[dict[str, int]],
    destination: Path,
    *,
    source_id: str,
    original_filename: str,
    duration_ms: int,
    width: int,
    height: int,
) -> None:
    if len(frame_paths) != 6 or len(timestamps) != 6:
        raise ValueError("contact sheet requires exactly six frames")
    cell_width, cell_height = 360, 360
    header_height, label_height = 82, 34
    sheet = Image.new("RGB", (cell_width * 3, header_height + (cell_height + label_height) * 2), "#151515")
    draw = ImageDraw.Draw(sheet)
    header_font = _font(22)
    label_font = _font(18)
    title = f"{source_id} | {original_filename}"
    detail = f"duration {duration_ms / 1000:.3f}s | {width}x{height}"
    draw.text((16, 12), title, fill="white", font=header_font)
    draw.text((16, 46), detail, fill="#d0d0d0", font=label_font)
    for index, (path, frame) in enumerate(zip(frame_paths, timestamps, strict=True)):
        row, column = divmod(index, 3)
        left = column * cell_width
        top = header_height + row * (cell_height + label_height)
        with Image.open(path) as opened:
            image = ImageOps.exif_transpose(opened).convert("RGB")
            image.thumbnail((cell_width, cell_height), Image.Resampling.LANCZOS)
            x = left + (cell_width - image.width) // 2
            y = top + (cell_height - image.height) // 2
            sheet.paste(image, (x, y))
        label = f"{frame['percentage']:03d}% | {frame['timestamp_ms'] / 1000:.3f}s"
        draw.text((left + 12, top + cell_height + 6), label, fill="white", font=label_font)
    destination.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(destination, format="JPEG", quality=88, optimize=False, progressive=False, subsampling=2)
