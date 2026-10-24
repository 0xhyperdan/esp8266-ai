#!/usr/bin/env python3
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
FONT_PATH = "/System/Library/Fonts/STHeiti Medium.ttc"
OUTPUT_PATH = ROOT / "firmware/include/img/ui_labels_zh.h"
PREVIEW_PATH = Path("/private/tmp/aiclock-ui-labels.png")

LABELS = [
    ("STOCK_LABEL", "stock_label_bits", "\u80a1\u7968", 11, 22, 12),
    # salary clock page (poster-style: 每秒进账 / gold coin / progress bar)
    ("SALARY_TITLE", "salary_title_bits", "\u6bcf\u79d2\u8fdb\u8d26", 24, 96, 26),
    ("SALARY_RATE_PREFIX", "salary_rate_prefix_bits", "\u6bcf\u79d2", 16, 32, 18),
    ("SALARY_YUAN", "salary_yuan_bits", "\u5143", 16, 16, 18),
    ("SALARY_EARNED_PREFIX", "salary_earned_prefix_bits", "\u5df2\u6323", 16, 32, 18),
    ("SALARY_FOOTER_PREFIX", "salary_footer_prefix_bits", "\u6708\u85aa", 16, 32, 18),
    ("SALARY_STATUS_EARNING", "salary_status_earning_bits", "\u8ba1\u85aa\u4e2d", 14, 42, 16),
    ("SALARY_STATUS_LUNCH", "salary_status_lunch_bits", "\u5348\u4f11\u6682\u505c", 14, 56, 16),
    ("SALARY_STATUS_WEEKEND", "salary_status_weekend_bits", "\u5468\u672b\u6682\u505c", 14, 56, 16),
    ("SALARY_STATUS_BEFORE", "salary_status_before_bits", "\u4e0a\u73ed\u524d", 14, 42, 16),
    ("SALARY_STATUS_AFTER", "salary_status_after_bits", "\u5df2\u4e0b\u73ed", 14, 42, 16),
    ("SALARY_STATUS_CONFIG", "salary_status_config_bits", "\u8bf7\u5148\u914d\u7f6e\u85aa\u8d44", 14, 84, 16),
    ("SALARY_STATUS_CLOCK", "salary_status_clock_bits", "\u7b49\u5f85\u65f6\u949f", 14, 56, 16),
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
