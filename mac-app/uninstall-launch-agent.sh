#!/bin/zsh
set -euo pipefail

LABEL="local.AIClockBridge"
DOMAIN="gui/$(id -u)"
INSTALL_DIR="$HOME/Library/Application Support/AIClockBridge"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"
rm -rf "$INSTALL_DIR"

print "Uninstalled $LABEL"
