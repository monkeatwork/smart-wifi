# SmartWiFi: project context

## What it is
SmartWiFi is a macOS menu bar app, written in Swift with SwiftUI and CoreWLAN, for a Mac that stays on all the time in a hostel room. The Mac is reached remotely over Tailscale for hosted projects and for remote control from a phone. If it loses internet, that remote access stops working. SmartWiFi keeps it online by switching Wi-Fi networks automatically and logging into the hostel's captive portal on its own.

## What it does
- **Auto-switching by priority.** It works through an ordered list of networks.
  - A *preferred* network, such as a phone hotspot, is joined whenever it's in range. It must show up in 2 scans in a row first.
  - *Fallback* networks, such as hostel Wi-Fi, are used when nothing above them works.
  - A network with no internet for 1 minute is skipped for 10 minutes.
- **Last resort.** When no listed network works, it tries the other networks saved in macOS (from `networksetup -listpreferredwirelessnetworks`). There's a toggle for this, on by default.
- **Captive portal auto-login** (Pronto Networks portals).
  - Credentials are kept in the Keychain.
  - Requests are bound to the Wi-Fi interface, so they work while macOS's own login pop-up is open. The pop-up is closed once the Mac is online.
  - If a login fails, it retries after 15 s, 30 s, 60 s, then every 120 s.
- **Portal trust check.** It remembers the portal network's router MAC address and the portal's IP, and sends the password only when both match. This protects against look-alike "evil twin" networks. "Log in now" in the menu overrides the check and trusts the new router.
- **Tailscale handling.**
  - On joining the hotspot, it asks (with a Mac pop-up and a phone notification) whether to turn Tailscale off for speed.
  - It turns Tailscale back on at the hostel only if SmartWiFi was the one that turned it off.
  - The phone answer comes back through a small HTTP listener that is reachable only on the Tailscale IP, port 8765, with a token for each prompt.
- **Phone notifications** via ntfy.sh: network switches, portal failures, back online, data cap reached.
- **Keep awake.** An IOPM assertion stops idle sleep while the Mac is on AC power.
- **Hotspot data meter** with an optional daily cap. When the cap is reached it avoids the hotspot until midnight; "Allow anyway" overrides that.
- **Wi-Fi watchdog.** If nothing has been online for N minutes, it power-cycles Wi-Fi, at most once every 15 minutes.
- **Menu bar UI.** It shows status, Tailscale state and today's data, with buttons for Connect to…, Log in now, Pause and Settings. Settings has tabs for Networks, Tailscale, Notifications and General.

## How it's built
- Source is in `Sources/SmartWiFi/`:
  - `Engine.swift`: the switching state machine; one tick every 15 s.
  - `Portal.swift`: connectivity probe, portal login, router lookup.
  - `Config.swift`: settings in `~/Library/Application Support/SmartWiFi/config.json` and state in `state.json`.
  - `Keychain.swift`, `Tailscale.swift`, `Notifier.swift`, `PromptServer.swift`, `DataMeter.swift`, `Awake.swift` and the UI files.
- `scripts/build.sh` builds it with `swiftc`. Only the Command Line Tools are needed, no Xcode project. It's pinned to the macOS 26.5 SDK and signed ad-hoc against a fixed bundle ID, so the Location permission and Keychain access survive rebuilds.
- `scripts/install.sh` installs it to `~/Applications` and adds a LaunchAgent that starts it through `open`. It has to go through LaunchServices, or macOS hides the network names.
- Log: `~/Library/Logs/smartwifi.log`. History and decisions: `docs/CHANGELOG.md`.

## Key gotchas
- Without Location permission, macOS hides every network name (SSID).
- While macOS's captive-portal window is open, other apps can't use the Wi-Fi. The fix is to bind curl with `--interface en0` and close the window after logging in.
- Running `arp` from the app returns nothing, so the router MAC is read from SCDynamicStore instead.
- All Keychain access goes through `/usr/bin/security`, so rebuilds don't trigger Keychain prompts.

## Current state and known gaps
- It works day to day: hotspot ⇄ hostel switching, portal login and the trust check are all confirmed live.
- **Bug:** the Tailscale prompt usually doesn't appear. The log shows `tailscale: not answering, not asking` because it checks before Tailscale has reconnected.
- **Not tested live:** joining networks that are saved only in macOS.
- **Before a public release:**
  - It's signed ad-hoc only, not notarized.
  - Only Pronto portals are supported.
  - There's no first-run guide for the Location permission.
  - There are no tests.

## Repo conventions
- Commit and push after every working iteration.
- Add a `docs/CHANGELOG.md` entry each time: what changed, why, files touched, known issues, next step.
- Never print or commit credentials.
