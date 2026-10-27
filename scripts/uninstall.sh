#!/bin/bash
# Stop and remove the agent. Pass --forget to also delete the stored credentials.
LABEL=io.github.monkeatwork.smartwifi
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
pkill -f "SmartWiFi.app/Contents/MacOS/smartwifi" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/SmartWiFi.app"
if [[ ${1:-} == --forget ]]; then
  # Each call deletes one matching item; repeat until none are left.
  while security delete-generic-password -s smartwifi >/dev/null 2>&1; do :; done
  echo "Credentials removed."
fi
echo "SmartWiFi uninstalled."
