#!/bin/bash
# Show whether the agent is running and its recent log.
LABEL=io.github.monkeatwork.smartwifi
launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -qE '^\s+state = running' && echo "agent: loaded" || echo "agent: NOT loaded"
pid=$(pgrep -f "SmartWiFi.app/Contents/MacOS/smartwifi") && echo "app:   running (pid $pid)" || echo "app:   NOT running"
echo "---"
tail -n "${1:-20}" "$HOME/Library/Logs/smartwifi.log" 2>/dev/null
