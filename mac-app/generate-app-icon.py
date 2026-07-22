#!/usr/bin/env python3

from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parent
OUTPUT_DIR = ROOT / "Resources"
CANVAS_SIZE = 1024
SCALE = CANVAS_SIZE / 100


def scaled_box(values: tuple[float, float, float, float]) -> tuple[int, int, int, int]:
    return tuple(round(value * SCALE) for value in values)


def quadratic_curve(
    start: tuple[float, float],
    control: tuple[float, float],
    end: tuple[float, float],
    steps: int = 80,
) -> list[tuple[int, int]]:
    points = []
    for index in range(steps + 1):
        time = index / steps
        inverse = 1 - time
        x = inverse * inverse * start[0] + 2 * inverse * time * control[0] + time * time * end[0]
        y = inverse * inverse * start[1] + 2 * inverse * time * control[1] + time * time * end[1]
        points.append((round(x * SCALE), round(y * SCALE)))
    return points


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    image = Image.new("RGBA", (CANVAS_SIZE, CANVAS_SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    draw.rounded_rectangle(
        scaled_box((0, 0, 100, 100)),
        radius=round(23 * SCALE),
        fill="#1d1d1f",
    )
    draw.rounded_rectangle(
        scaled_box((8, 8, 22, 22)),
        radius=round(4 * SCALE),
        fill="#37d24a",
    )
    draw.rounded_rectangle(
        scaled_box((32.75, 31, 40.25, 52)),
        radius=round(3.75 * SCALE),
        fill="#ffffff",
    )
    draw.rounded_rectangle(
        scaled_box((59.75, 31, 67.25, 52)),
        radius=round(3.75 * SCALE),
        fill="#ffffff",
    )

    smile = quadratic_curve((30, 57), (50, 74.5), (70, 57))
    stroke_width = round(6.5 * SCALE)
    draw.line(smile, fill="#ffffff", width=stroke_width, joint="curve")
    radius = stroke_width // 2
    for x, y in (smile[0], smile[-1]):
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill="#ffffff")

    png_path = OUTPUT_DIR / "AppIcon.png"
    icns_path = OUTPUT_DIR / "AppIcon.icns"
    image.save(png_path, optimize=True)
    image.save(
        icns_path,
        sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)],
    )
    print(png_path)
    print(icns_path)


if __name__ == "__main__":
    main()
