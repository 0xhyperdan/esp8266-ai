#!/usr/bin/env python3

import argparse
import base64
import json
import re
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path


def read_define(source: str, name: str) -> str:
    match = re.search(
        rf'^\s*#define\s+{re.escape(name)}\s+"([^"]+)"\s*$',
        source,
        re.MULTILINE,
    )
    if not match:
        raise ValueError(f"{name} is missing from the OTA secrets file.")
    return match.group(1)


def fetch_info(host: str, timeout: float = 5) -> dict:
    with urllib.request.urlopen(f"http://{host}/api/info", timeout=timeout) as response:
        return json.load(response)


def validate_firmware(firmware: bytes, board: str) -> None:
    if len(firmware) < 4096 or firmware[0] != 0xE9:
        raise ValueError("The selected file is not an Espressif firmware image.")
    chip_id = int.from_bytes(firmware[12:14], "little")
    is_s3 = "esp32-s3" in board.lower()
    if is_s3 != (chip_id == 9):
        raise ValueError(f"The firmware image does not match board {board}.")


def multipart_body(firmware: bytes, boundary: str) -> bytes:
    prefix = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="firmware"; filename="firmware.bin"\r\n'
        "Content-Type: application/octet-stream\r\n\r\n"
    ).encode()
    return prefix + firmware + f"\r\n--{boundary}--\r\n".encode()


def upload(host: str, firmware: bytes, username: str, password: str) -> None:
    boundary = f"aiclock-ota-{uuid.uuid4()}"
    request = urllib.request.Request(
        f"http://{host}/update",
        data=multipart_body(firmware, boundary),
        method="POST",
    )
    request.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    token = base64.b64encode(f"{username}:{password}".encode()).decode()
    request.add_header("Authorization", f"Basic {token}")
    with urllib.request.urlopen(request, timeout=120) as response:
        if response.status < 200 or response.status >= 300:
            raise RuntimeError(f"The device returned HTTP {response.status}.")


def wait_until_online(host: str, attempts: int = 120) -> dict:
    time.sleep(3)
    for _ in range(attempts):
        try:
            return fetch_info(host, timeout=1)
        except (OSError, urllib.error.URLError, json.JSONDecodeError):
            time.sleep(1)
    raise TimeoutError("The device did not return after the firmware update.")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Upload AIClock firmware over the authenticated local OTA endpoint."
    )
    parser.add_argument("host", help="Device IP address or hostname")
    parser.add_argument("firmware", type=Path, help="Matching firmware.bin")
    parser.add_argument(
        "--secrets",
        type=Path,
        default=Path("firmware/include/ota_secrets.h"),
        help="Header containing OTA_USERNAME and OTA_PASSWORD",
    )
    args = parser.parse_args()

    host = args.host.strip().removeprefix("http://").rstrip("/")
    firmware = args.firmware.expanduser().read_bytes()
    secrets = args.secrets.expanduser().read_text()
    username = read_define(secrets, "OTA_USERNAME")
    password = read_define(secrets, "OTA_PASSWORD")

    before = fetch_info(host)
    board = str(before.get("board", ""))
    validate_firmware(firmware, board)
    print(f"Uploading {len(firmware)} bytes to {host} ({board})...")
    upload(host, firmware, username, password)
    print("Upload accepted. Waiting for the device to restart...")
    after = wait_until_online(host)
    print(f"Device online: firmware {after.get('fw', '?')}, IP {after.get('ip', host)}")


if __name__ == "__main__":
    main()
