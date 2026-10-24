#!/usr/bin/env python3

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Optional


PARTITION_OFFSET = 0x100000
PARTITION_SIZE = 0x300000
BLOCK_SIZE = 8192
PAGE_SIZE = 256


def find_mklittlefs(explicit_path: Optional[str]) -> Path:
    candidates = [
        Path(explicit_path).expanduser() if explicit_path else None,
        Path(shutil.which("mklittlefs")) if shutil.which("mklittlefs") else None,
        Path.home() / ".platformio/packages/tool-mklittlefs/mklittlefs",
    ]
    for candidate in candidates:
        if candidate and candidate.is_file():
            return candidate
    raise FileNotFoundError(
        "mklittlefs was not found. Install PlatformIO or pass --mklittlefs."
    )


def copy_assets(unpacked: Path, output: Path) -> int:
    groups = {
        "Weather": [unpacked / f"system/image/{index}.jpeg" for index in range(8)],
        "Astronaut": [unpacked / f"system/GIF/T{index}.jpg" for index in range(1, 21)],
        "Indicators": [
            unpacked / "system/image/W0.jpeg",
            unpacked / "system/image/S0.jpeg",
        ],
    }
    copied = 0
    for group, sources in groups.items():
        destination = output / group
        destination.mkdir(parents=True, exist_ok=True)
        for source in sources:
            if not source.is_file():
                raise FileNotFoundError(f"Factory asset is missing: {source}")
            shutil.copy2(source, destination / source.name)
            copied += 1
    return copied


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Extract FuBoTV weather assets from a full 4 MiB factory backup."
    )
    parser.add_argument("backup", type=Path, help="Full ESP8266 flash backup")
    parser.add_argument("output", type=Path, help="Destination FuBoTV resource directory")
    parser.add_argument("--mklittlefs", help="Path to the mklittlefs executable")
    args = parser.parse_args()

    backup = args.backup.expanduser().resolve()
    if backup.stat().st_size < PARTITION_OFFSET + PARTITION_SIZE:
        raise ValueError("The backup is smaller than the expected 4 MiB flash image.")

    tool = find_mklittlefs(args.mklittlefs)
    with backup.open("rb") as source:
        source.seek(PARTITION_OFFSET)
        partition = source.read(PARTITION_SIZE)

    with tempfile.TemporaryDirectory(prefix="fubotv-assets-") as temporary:
        work = Path(temporary)
        image = work / "littlefs.bin"
        unpacked = work / "unpacked"
        image.write_bytes(partition)
        unpacked.mkdir()
        subprocess.run(
            [
                str(tool),
                "-u",
                str(unpacked),
                "-b",
                str(BLOCK_SIZE),
                "-p",
                str(PAGE_SIZE),
                "-s",
                str(PARTITION_SIZE),
                str(image),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        count = copy_assets(unpacked, args.output.expanduser().resolve())

    print(f"Extracted {count} FuBoTV weather assets.")


if __name__ == "__main__":
    main()
