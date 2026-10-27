# smart-wifi

A small macOS menu bar app that keeps an always-on Mac online without manual
Wi-Fi switching:

- **Preferred network (phone hotspot) in range** → join it.
- **Otherwise** → use the fallback networks in order (for example a hostel or campus Wi-Fi), and
  log in to the Pronto Networks captive portal automatically, again whenever
  the session drops.
- **Current network has no internet for a minute** → avoid it for 10 minutes
  and use the next one.
- On some other network that already has internet → leave it alone.

## Features

- **Menu bar:** current network, signal, internet state, hotspot data used today,
  Tailscale switch, "Switch to …" / "Log in to portal now" / "Pause auto-switching".
- **Settings window:** add, remove and reorder networks; Wi-Fi and portal
  passwords (saved in the Keychain); notifications; general options.
- **Tailscale:** when the Mac joins a preferred network, it asks on the Mac and
  on your phone whether to turn Tailscale off. If SmartWiFi turned it off, it
  turns it back on when the Mac leaves the hotspot. If you turned it off
  yourself, it stays off. With no exit node configured, turning it off gives
  only a small speed gain.
- **Phone notifications** through [ntfy](https://ntfy.sh): network switches,
  portal login failures, back online after an outage, data cap reached.
  Messages that can't be sent while offline go out once the Mac is back online.
- **Keep awake:** prevents idle sleep while on AC power (lid-closed sleep still
  happens unless an external display is attached).
- **Hotspot data meter** with an optional daily cap; at the cap the Mac stays
  off the hotspot until midnight, unless you allow it from the menu.
- **Wi-Fi watchdog:** turns Wi-Fi off and on after N minutes with no internet
  (at most once every 15 min).

## Why an app bundle and Location permission?

Since macOS 14.4, Wi-Fi network names (SSIDs) are `<redacted>` for any process
without Location Services access. SmartWiFi uses CoreWLAN and asks for Location
access once. The LaunchAgent (`io.github.monkeatwork.smartwifi`) starts it through `open`
(LaunchServices): started as a bare launchd executable, macOS keeps the SSIDs
redacted even after access is granted.

## Install

Only the Command Line Tools are needed (no Xcode):

```sh
./scripts/install.sh    # build, install to ~/Applications, start at login
```

On first start, allow Location access for **SmartWiFi** (System Settings →
Privacy & Security → Location Services if the prompt doesn't appear). Then open
**Settings… → Networks** from the menu bar icon to set the networks and passwords.

### Phone notifications

1. Install the ntfy app on the phone.
2. Subscribe to the topic shown in **Settings → Notifications**, and enable it there.
3. The "Turn off" / "Keep on" buttons on the Tailscale question call the Mac
   over Tailscale, so they work only while the phone is on Tailscale.

## Day to day

```sh
./scripts/status.sh            # running? + last 20 log lines
tail -f ~/Library/Logs/smartwifi.log
./scripts/uninstall.sh         # remove (add --forget to delete stored credentials)
```

"Quit" in the menu stops the app until the next login.

## Notes

- Settings: `~/Library/Application Support/SmartWiFi/config.json`. Runtime state
  (Tailscale flag, data meter): `state.json` next to it.
- Secrets live in the login Keychain under service `smartwifi`, keyed by
  network id.
- Pronto login: POST `userId`/`password`/`serviceName=ProntoAuthentication` to
  `http://phc.prontonetworks.com/cgi-bin/authlogin`; success is confirmed
  against `captive.apple.com`. `Info.plist` allows plain HTTP because App
  Transport Security would otherwise block the portal.
- Builds against the macOS 26.x SDK: in the 27 SDK SwiftUI's `@State` is a
  macro whose plugin ships only with Xcode. Override with `SMARTWIFI_SDK=…`.
- The app is ad-hoc signed with a bundle-ID designated requirement, so Location
  and Keychain access survive rebuilds.
- The app only runs while you're logged in. After a power cut the Mac needs to
  reach your desktop (enable automatic login) before switching resumes.
