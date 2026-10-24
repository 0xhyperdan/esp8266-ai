#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JSON_INCLUDE="$ROOT/firmware/.pio/libdeps/nodemcuv2/ArduinoJson/src"
if [[ ! -f "$JSON_INCLUDE/ArduinoJson.h" ]]; then
  JSON_INCLUDE="$ROOT/firmware/.pio/libdeps/waveshare-s3-touch-lcd-154/ArduinoJson/src"
fi
if [[ ! -f "$JSON_INCLUDE/ArduinoJson.h" ]]; then
  echo "cached ArduinoJson headers not found" >&2
  exit 2
fi

TMPDIR_PATH="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_PATH"' EXIT

CXX="${CXX:-c++}"
"$CXX" -std=c++17 -Wall -Wextra -Wpedantic -Werror \
  -I"$JSON_INCLUDE" -I"$ROOT/firmware/include" -I"$ROOT/firmware/test/support" \
  -c "$ROOT/firmware/test/printer_monitor_parser_test.cpp" \
  -o "$TMPDIR_PATH/printer_monitor_parser_test.o"
"$CXX" -std=c++17 -Wall -Wextra -Wpedantic -Werror \
  -I"$JSON_INCLUDE" -I"$ROOT/firmware/include" -I"$ROOT/firmware/test/support" \
  -c "$ROOT/firmware/src/printer_monitor.cpp" \
  -o "$TMPDIR_PATH/printer_monitor.o"
"$CXX" "$TMPDIR_PATH/printer_monitor_parser_test.o" "$TMPDIR_PATH/printer_monitor.o" \
  -o "$TMPDIR_PATH/printer_monitor_parser_test"
"$TMPDIR_PATH/printer_monitor_parser_test"
"$CXX" -std=c++17 -Wall -Wextra -Wpedantic -Werror \
  -I"$JSON_INCLUDE" -I"$ROOT/firmware/include" -I"$ROOT/firmware/test/support" \
  "$ROOT/firmware/test/printer_bridge_parser_test.cpp" \
  -o "$TMPDIR_PATH/printer_bridge_parser_test"
"$TMPDIR_PATH/printer_bridge_parser_test"
"$CXX" -std=c++17 -Wall -Wextra -Wpedantic -Werror -DARDUINO_ARCH_ESP8266 \
  -I"$JSON_INCLUDE" -I"$ROOT/firmware/include" -I"$ROOT/firmware/test/support" \
  "$ROOT/firmware/test/printer_bridge_parser_test.cpp" \
  "$ROOT/firmware/src/printer_monitor.cpp" \
  -o "$TMPDIR_PATH/printer_bridge_esp8266_test"
"$TMPDIR_PATH/printer_bridge_esp8266_test"
"$CXX" -std=c++17 -Wall -Wextra -Wpedantic -Werror \
  -I"$ROOT/firmware/include" \
  "$ROOT/firmware/test/printer_monitor_recovery_test.cpp" \
  -o "$TMPDIR_PATH/printer_monitor_recovery_test"
"$TMPDIR_PATH/printer_monitor_recovery_test"
