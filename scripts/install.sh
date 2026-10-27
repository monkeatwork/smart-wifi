#!/bin/bash
# Build SmartWiFi.app, install it to ~/Applications and (re)load the LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL=io.github.monkeatwork.smartwifi
APP="$HOME/Applications/SmartWiFi.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/smartwifi.log"
DOMAIN="gui/$(id -u)"

xml() { local s=${1//&/&amp;}; s=${s//</&lt;}; printf '%s' "${s//>/&gt;}"; }

echo "Building..."
./scripts/build.sh

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
pkill -f "SmartWiFi.app/Contents/MacOS/smartwifi" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
rm -rf "$APP"
cp -R build/SmartWiFi.app "$APP"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<!-- Launch through LaunchServices: macOS only reveals SSIDs to the app
	     when it's started as an app, not as a bare launchd executable.
	     -W keeps open alive while the app runs so KeepAlive works. -->
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/open</string>
		<string>-W</string>
		<string>-g</string>
		<string>-a</string>
		<string>$(xml "$APP")</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$(xml "$LOG")</string>
	<key>StandardErrorPath</key>
	<string>$(xml "$LOG")</string>
</dict>
</plist>
EOF

launchctl enable "$DOMAIN/$LABEL"
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Installed $APP and loaded $LABEL."
echo "Log: $LOG"
