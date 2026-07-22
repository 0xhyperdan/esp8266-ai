#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
APP_NAME="AIClockBridge"
SOURCE_APP="$SCRIPT_DIR/dist/$APP_NAME.app"
DESTINATION_DIR="${INSTALL_DIR:-$HOME/Applications}"
DESTINATION_APP="$DESTINATION_DIR/$APP_NAME.app"
LABEL="local.AIClockBridge"
DOMAIN="gui/$(id -u)"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ ! -d "$SOURCE_APP" ]]; then
  "$SCRIPT_DIR/build-app.sh"
fi

launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

mkdir -p "$DESTINATION_DIR"
rm -rf "$DESTINATION_APP"
/usr/bin/ditto "$SOURCE_APP" "$DESTINATION_APP"

print "$DESTINATION_APP"
