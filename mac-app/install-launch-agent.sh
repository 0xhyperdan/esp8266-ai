#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
LABEL="local.AIClockBridge"
DOMAIN="gui/$(id -u)"
INSTALL_DIR="$HOME/Library/Application Support/AIClockBridge"
INSTALLED_BINARY="$INSTALL_DIR/AIClockBridge"
INSTALLED_BUNDLE="$INSTALL_DIR/AIClockBridge_AIClockBridge.bundle"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$LABEL.plist"
TEMP_PLIST="$PLIST_PATH.tmp"
LOG_DIR="$HOME/Library/Logs/AIClockBridge"
STDOUT_PATH="$LOG_DIR/bridge.log"
STDERR_PATH="$LOG_DIR/bridge-error.log"

cd "$SCRIPT_DIR"
swift build -c release

SOURCE_BINARY="$SCRIPT_DIR/.build/release/AIClockBridge"
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

mkdir -p "$INSTALL_DIR" "$LAUNCH_AGENTS_DIR" "$LOG_DIR"

launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true

for pid in ${(f)"$(pgrep -x AIClockBridge 2>/dev/null || true)"}; do
  command_path=$(ps -p "$pid" -o command= 2>/dev/null || true)
  if [[ "$command_path" == "$SCRIPT_DIR/.build/"* || \
        "$command_path" == "$INSTALLED_BINARY"* ]]; then
    kill "$pid" >/dev/null 2>&1 || true
  fi
done

/usr/bin/install -m 755 "$SOURCE_BINARY" "$INSTALLED_BINARY"
rm -rf "$INSTALLED_BUNDLE"
/usr/bin/ditto "$SOURCE_BUNDLE" "$INSTALLED_BUNDLE"

rm -f "$TEMP_PLIST"
/usr/bin/plutil -create xml1 "$TEMP_PLIST"
/usr/libexec/PlistBuddy -c "Add :Label string $LABEL" "$TEMP_PLIST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$TEMP_PLIST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $INSTALLED_BINARY" "$TEMP_PLIST"
/usr/libexec/PlistBuddy -c "Add :WorkingDirectory string $INSTALL_DIR" "$TEMP_PLIST"
/usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$TEMP_PLIST"
/usr/libexec/PlistBuddy -c "Add :KeepAlive dict" "$TEMP_PLIST"
/usr/libexec/PlistBuddy -c "Add :KeepAlive:SuccessfulExit bool false" "$TEMP_PLIST"
/usr/libexec/PlistBuddy -c "Add :ThrottleInterval integer 10" "$TEMP_PLIST"
/usr/libexec/PlistBuddy -c "Add :ProcessType string Interactive" "$TEMP_PLIST"
/usr/libexec/PlistBuddy -c "Add :LimitLoadToSessionType string Aqua" "$TEMP_PLIST"
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$TEMP_PLIST"
/usr/libexec/PlistBuddy -c \
  "Add :EnvironmentVariables:PATH string /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$TEMP_PLIST"
/usr/libexec/PlistBuddy -c "Add :StandardOutPath string $STDOUT_PATH" "$TEMP_PLIST"
/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $STDERR_PATH" "$TEMP_PLIST"

/usr/bin/plutil -lint "$TEMP_PLIST" >/dev/null
/bin/mv "$TEMP_PLIST" "$PLIST_PATH"
/bin/chmod 644 "$PLIST_PATH"

launchctl bootstrap "$DOMAIN" "$PLIST_PATH"
launchctl kickstart -k "$DOMAIN/$LABEL"

print "Installed and started $LABEL"
print "LaunchAgent: $PLIST_PATH"
print "Application: $INSTALL_DIR"
print "Logs: $LOG_DIR"
