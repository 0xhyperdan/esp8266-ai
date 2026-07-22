#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
APP_NAME="AIClockBridge"
APP_DIR="$SCRIPT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$SCRIPT_DIR"
swift build -c release

BIN_DIR=$(swift build -c release --show-bin-path)
SOURCE_BINARY="$BIN_DIR/$APP_NAME"
SOURCE_BUNDLE=$(/usr/bin/find "$SCRIPT_DIR/.build" \
  -type d -path '*/release/AIClockBridge_AIClockBridge.bundle' \
  -print -quit)

if [[ ! -x "$SOURCE_BINARY" ]]; then
  print -u2 "Release binary was not produced: $SOURCE_BINARY"
  exit 1
fi

if [[ -z "$SOURCE_BUNDLE" || ! -d "$SOURCE_BUNDLE" ]]; then
  print -u2 "Resource bundle was not produced."
  exit 1
fi

if [[ ! -f "$SCRIPT_DIR/Resources/AppIcon.icns" ]]; then
  print -u2 "App icon is missing. Run generate-app-icon.py first."
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
/usr/bin/install -m 755 "$SOURCE_BINARY" "$CONTENTS_DIR/MacOS/$APP_NAME"
/usr/bin/ditto "$SOURCE_BUNDLE" "$CONTENTS_DIR/Resources/AIClockBridge_AIClockBridge.bundle"
/bin/cp "$SCRIPT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
/bin/cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"

/usr/bin/plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
/usr/bin/codesign --force --deep --sign - "$APP_DIR"

print "$APP_DIR"
