#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
BINARY="$SCRIPT_DIR/.build/debug/AIClockBridge"
LABEL="local.AIClockBridge"
DOMAIN="gui/$(id -u)"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart "$DOMAIN/$LABEL"
  exit 0
fi

if [[ ! -x "$BINARY" ]]; then
  cd "$SCRIPT_DIR"
  swift build
fi

exec env AICLOCK_SERIAL_PORT="${AICLOCK_SERIAL_PORT:-}" "$BINARY"
