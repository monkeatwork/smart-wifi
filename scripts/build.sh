#!/bin/bash
# Compile SmartWiFi.app into build/.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/SmartWiFi.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
# The macOS 27 SDK makes SwiftUI's @State a macro whose plugin ships only with
# Xcode, so with just the Command Line Tools build against the 26.x SDK.
SDK="${SMARTWIFI_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos15 -sdk "$SDK" \
  -o "$APP/Contents/MacOS/smartwifi" Sources/SmartWiFi/*.swift
# Pin the designated requirement to the bundle ID so Location permission and
# Keychain access survive rebuilds (plain ad-hoc signing pins the binary's hash).
codesign --force --sign - -r='designated => identifier "io.github.monkeatwork.smartwifi"' "$APP"
