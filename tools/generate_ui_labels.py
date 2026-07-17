#!/usr/bin/env python3
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
FONT_PATH = "/System/Library/Fonts/STHeiti Medium.ttc"
OUTPUT_PATH = ROOT / "firmware/include/img/ui_labels_zh.h"
PREVIEW_PATH = Path("/private/tmp/aiclock-ui-labels.png")

LABELS = [
    ("WEEK_LABEL", "week_label_bits", "\u5468", 14, 14, 16),
    ("STOCK_LABEL", "stock_label_bits", "\u80a1\u7968", 11, 22, 12),
    ("POMODORO_LABEL", "pomodoro_label_bits", "\u756a\u8304\u949f", 14, 42, 16),
    ("FOCUS_LABEL", "focus_label_bits", "\u4e13\u6ce8", 14, 28, 16),
    ("BREAK_LABEL", "break_label_bits", "\u4f11\u606f", 14, 28, 16),
    ("RUNNING_LABEL", "running_label_bits", "\u8fdb\u884c\u4e2d", 14, 42, 16),
    ("PAUSED_LABEL", "paused_label_bits", "\u5df2\u6682\u505c", 14, 42, 16),
    ("COMPLETED_LABEL", "completed_label_bits", "\u5b8c\u6210", 12, 24, 14),
]


def render(text: str, font_size: int, width: int, height: int) -> Image.Image:
    font = ImageFont.truetype(FONT_PATH, font_size)
    bbox = font.getbbox(text)
    glyph_height = bbox[3] - bbox[1]
    y = (height - glyph_height) // 2 - bbox[1]
    image = Image.new("L", (width, height), 0)
    ImageDraw.Draw(image).text((0, y), text, font=font, fill=255)
    return image.point(lambda value: 255 if value >= 96 else 0)


def pack(image: Image.Image) -> list[int]:
    width, height = image.size
    row_bytes = (width + 7) // 8
    result: list[int] = []
    for y in range(height):
        for byte_index in range(row_bytes):
            value = 0
            for bit in range(8):
                x = byte_index * 8 + bit
                if x < width and image.getpixel((x, y)):
                    value |= 0x80 >> bit
            result.append(value)
    return result


def format_bytes(values: list[int]) -> str:
    rows = []
    for offset in range(0, len(values), 12):
        rows.append("  " + ", ".join(f"0x{value:02X}" for value in values[offset:offset + 12]) + ",")
    return "\n".join(rows)


def main() -> None:
    rendered = []
    header = ["#pragma once", "#include <Arduino.h>", ""]
    for macro, variable, text, font_size, width, height in LABELS:
        image = render(text, font_size, width, height)
        rendered.append(image)
        values = pack(image)
        header.extend([
            f"#define {macro}_W {width}",
            f"#define {macro}_H {height}",
            f"const uint8_t {variable}[{len(values)}] PROGMEM = {{",
            format_bytes(values),
            "};",
            "",
        ])
    OUTPUT_PATH.write_text("\n".join(header), encoding="utf-8")

    preview_width = max(image.width for image in rendered)
    preview_height = sum(image.height for image in rendered) + 8 * (len(rendered) - 1)
    preview = Image.new("L", (preview_width, preview_height), 0)
    y = 0
    for image in rendered:
        preview.paste(image, (0, y))
        y += image.height + 8
    preview.resize((preview.width * 6, preview.height * 6), Image.Resampling.NEAREST).save(PREVIEW_PATH)


if __name__ == "__main__":
    main()
