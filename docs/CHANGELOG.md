# Changelog

## 2026-10-22: Initial version

**What changed**
- Swift LaunchAgent app (SmartWiFi.app) that joins the phone hotspot
  when it's in range and otherwise joins the hostel Wi-Fi.
- Automatic Pronto Networks captive-portal login with exponential backoff
  (30 s → 10 min), re-login whenever the probe to captive.apple.com fails.
- Falls back to hostel Wi-Fi for 10 min if the hotspot has no internet for ~1 min.
- Scripts: install, set-credentials (Keychain), status, uninstall.

**Why**
- Remote control and Tailscale access were lost whenever the hotspot left with
  the phone, because the Mac then sat on an un-logged-in captive portal.
- SSIDs are redacted without Location Services, so CoreWLAN in an app bundle
  is needed instead of a shell script.

**Files**: `Sources/main.swift`, `Info.plist`, `scripts/*.sh`, `README.md`

**Known issues**
- Portal form fields are the well-known Pronto ones; confirmed working
  only once the first automatic login after leaving the room succeeds.
- Ad-hoc signing means a rebuild may re-trigger the Location prompt.

**Next step**
- Test a real leave/return cycle and check `~/Library/Logs/smartwifi.log`.

## 2026-10-22: Fix redacted SSIDs, launch via LaunchServices

**What changed**
- LaunchAgent now runs `open -W -g --env ... -a SmartWiFi.app` instead of the
  binary directly; the app writes its own log file.
- Request "Always" Location access; sign with a bundle-ID designated
  requirement so the permission survives rebuilds.
- A join attempt (successful or not) now pauses probing for 10 s, and a failed
  hotspot join no longer falls through to a false portal login.
- install/uninstall also kill a running app instance; status.sh shows agent + app.

**Why**
- Even with Location authorized (status 3), CoreWLAN returned nil SSIDs for
  the launchd-spawned binary; launched through LaunchServices it works.
- First live run: joining the hotspot with no stored password dropped the hostel Wi-Fi, and the
  probe in that gap triggered a needless portal login.

**Files**: `Sources/main.swift`, `scripts/install.sh`, `scripts/status.sh`,
`scripts/uninstall.sh`, `README.md`

**Verified**: SSIDs visible, env vars reach the app, launchd restarts the app
when killed, switches to the hotspot when in range.

**Known issues**
- Pronto auto-login not yet exercised for real (needs credentials + leaving).

**Next step**
- Store credentials, switch the hotspot off, confirm fallback to the hostel Wi-Fi + login.

## 2026-10-22: Hotfix - fall back to the hostel Wi-Fi when the hotspot disappears

**What changed**
- Removed the `ssid == nil && wlanChannel != nil` guard in `tick()`; nil SSID now
  means "not connected". The redaction warning moved into `find()` (fires only
  when a scan returns networks with no names).

**Why**
- When the hotspot went away the interface still reported a channel, so the guard
  mistook "disconnected" for "redacted" and skipped the fallback every tick.

**Files**: `Sources/main.swift`

**Known issues**: fallback + Pronto login still to be confirmed live.

**Next step**: live hotspot-off test, then v1 menu bar app.

## 2026-10-22: Fix Pronto auto-login (App Transport Security)

**What changed**
- `Info.plist`: `NSAppTransportSecurity` → `NSAllowsArbitraryLoads`.
- `fetch()` records the underlying error; portal failures now log it.

**Why**
- Live test: after falling back to the hostel Wi-Fi, every login attempt failed instantly
  with "no response". Inside an app bundle, ATS blocks plain-HTTP requests
  (NSURLErrorDomain -1022); the Pronto portal is HTTP-only. `captive.apple.com`
  is exempt, which is why the connectivity probe still worked.

**Files**: `Info.plist`, `Sources/main.swift`

**Verified**: logged out via `/cgi-bin/authlogout`; the agent detected it and
logged back in within ~9 s (`portal: logged in, online`). Hotspot-off → the hostel Wi-Fi
fallback also confirmed live.

**Known issues**: one the hotspot join attempt failed with apple80211 error -3912 while
the hotspot was being switched off; watch for it on a normal join.

**Next step**: v1 menu bar app.

## 2026-10-22: v1 - menu bar app

**What changed**
- Rewrote the agent as a SwiftUI menu bar app (`Sources/SmartWiFi/`): the engine
  is split from the old `main.swift` into Engine, Portal, Config, Keychain,
  Tailscale, Notifier, PromptServer, TailscalePrompt, DataMeter, Awake,
  LaunchAgent, MenuView, SettingsView.
- Any number of networks in priority order (preferred / fallback, optional
  Pronto portal), edited in Settings; JSON config replaces env vars.
- Tailscale: prompt on the Mac + ntfy action buttons when joining a preferred
  network; restored on leaving only if SmartWiFi turned it off; Ask / Always
  off / Never policy with "remember my choice".
- ntfy notifications (queued while offline), keep-awake assertion on AC,
  hotspot data meter with daily cap, Wi-Fi watchdog.
- Credentials moved from the `/usr/bin/security` items into app-owned Keychain
  items keyed by network id; `scripts/set-credentials.sh` removed.
- `scripts/build.sh` (macOS 26.5 SDK, see Known issues); install.sh uses it.

**Why**
- Requested: a minimal UI for networks and passwords, more fallbacks, a
  Tailscale prompt, and the v1 feature set (notifications, keep awake, data
  meter, watchdog).

**Files**: `Sources/SmartWiFi/*.swift` (new), `Sources/main.swift` (removed),
`Info.plist`, `scripts/build.sh` (new), `scripts/install.sh`,
`scripts/set-credentials.sh` (removed), `README.md`

**Verified**: builds without warnings; installs; Location permission kept
across the rebuild; credentials migrated and old items deleted; on the hostel Wi-Fi online;
keep-awake assertion taken.

**Known issues**
- The macOS 27 SDK's SwiftUI `@State` needs Xcode's macro plugin, so the build
  is pinned to the 26.5 SDK.
- Not yet verified live: menu bar UI, Tailscale prompt (Mac + phone), data cap,
  watchdog.

**Next step**
- Turn the hotspot on: check the switch, the prompt, and Tailscale on/off;
  set up ntfy on the phone.

## 2026-10-22: Fix v1 switching (manual hold, hotspot detection)

**What changed**
- A manual "Switch to …" now holds only while that network works: the hold is
  ignored when disconnected or offline, and cleared on disconnect.
- Preferred networks missing from the broad scan get a directed scan by name;
  while one is waiting for its second sighting, the next scan comes after 15 s
  instead of 30 s.
- Log "in range: …" whenever the set of configured networks in range changes.

**Why**
- Live test: after "Switch to the hotspot", turning the hotspot off left the Mac
  disconnected for over 2 min because the 10-min manual hold blocked the
  fallback to the hostel Wi-Fi.
- the hotspot was never joined automatically from the hostel Wi-Fi. The old agent's directed scan
  always found it; the broad scan probably misses it now and then, resetting
  the two-sightings counter.

**Files**: `Sources/SmartWiFi/Engine.swift`

**Known issues**: auto-join of the hotspot from the hostel Wi-Fi still to be confirmed live.

**Next step**: hotspot off → the hostel Wi-Fi, hotspot on → the hotspot + Tailscale prompt.

## 2026-10-22: Fix Keychain prompts and portal login after switching

**What changed**
- Keychain: all reads/writes go through `/usr/bin/security` again (writes over
  stdin with the password hex-encoded, so it never appears in `ps`). One-time
  migration moves the v1.0 Security-framework items over.
- Portal probe + Pronto login use `/usr/bin/curl` (request config on stdin)
  instead of URLSession; after the POST, the probe is retried for up to 10 s.
- Joins always rescan by name first; a network that was just lost, or that a
  rescan can't find, is skipped for 30 s.
- Tailscale counts as on while "Starting" (its state right after a network
  change); the status check retries; log when the prompt is skipped.
- `uninstall.sh --forget` deletes every `smartwifi` Keychain item.

**Why**
- Items the app created through the Security framework trust one build of the
  ad-hoc-signed app, so each rebuild brought back an "allow access" prompt per
  password, and the engine blocked on it before joining or logging in.
- After a fresh join to the hostel Wi-Fi, URLSession failed with -1009 ("offline") while
  macOS still rated the captive network as having no internet. The third
  attempt only worked ~2 min later. curl's plain sockets aren't affected.
- Hotspot just turned off: a stale scan result made the engine try the hotspot first
  (-3912 after 10 s). The join to the hotspot from the hostel Wi-Fi took 57 s on a 30 s-old scan.
- The Tailscale prompt never showed: the status check right after joining the hotspot
  saw "Starting", not "Running".

**Files**: `Sources/SmartWiFi/Keychain.swift`, `Portal.swift`, `Engine.swift`,
`Tailscale.swift`, `Config.swift`, `scripts/uninstall.sh`

**Verified**: migrated items read instantly with no prompt; curl config format
checked for the probe and for a form POST (encoding round-trips).

**Next step**: the hotspot off → the hostel Wi-Fi + automatic Pronto login; the hotspot on → the hotspot +
Tailscale prompt.

## 2026-10-22: Live test passed

**Verified** (log 13:42-13:45): the hotspot off → the hostel Wi-Fi joined and online in ~17 s
(twice); the hotspot on → switched back automatically ~30 s after it came into range,
join itself took 1 s; no Keychain prompts.

**Known issues**
- The Tailscale prompt still didn't show: right after joining the hotspot,
  `tailscale status` failed 3 times in ~2 s ("not answering, not asking").
  The decision should wait until the Mac is online and Tailscale answers.
- The portal session was still valid each time, so the curl-based login after
  a fresh join wasn't exercised in this run.

**Next step**: defer the Tailscale decision until Tailscale answers; v2
features (phone control page, connection history, LAN project links, other
portal types).

## 2026-10-22: Portal login works while macOS shows its login window

**What**: the connectivity probe and the Pronto login request are now bound to
the Wi-Fi interface (`curl --interface en0`). Portal retries back off
15 s → 30 s → 60 s → every 2 min (was 30 s doubling up to 10 min).

**Why**: after leaving the room the Mac rejoined the hostel Wi-Fi, but every automatic
login failed instantly with `curl exit 7 (could not connect)`; "Log in now"
worked only after the macOS captive login window was closed. The system log
showed why: on joining a known captive network macOS sets the Wi-Fi interface
rank to Never and opens its Websheet; until that window is dismissed
(`websheet: cancelled` at 18:30:01), unbound sockets can't use Wi-Fi at all.
Sockets bound to the interface are exempt, which is how Apple's own
captiveagent reaches the portal. Checking more often wouldn't have helped;
every try was being refused.

**Files**: `Sources/SmartWiFi/Portal.swift`, `Sources/SmartWiFi/Engine.swift`

**Verified**: bound probe reports online on the hotspot after reinstall; curl confirms
"socket successfully bound to interface 'en0'".

**Known issues**: not yet confirmed on a fresh the hostel Wi-Fi join with the portal
window open; Tailscale prompt timing (see above) still open.

**Next step**: leave the room / drop the hotspot and confirm `portal: logged in,
online` with no manual step.

## 2026-10-22: Close the macOS portal window after logging in

**What**: on a network with a portal, once SmartWiFi's login has the Mac online
it quits Captive Network Assistant (`com.apple.CaptiveNetworkAssistant`) if
that window is open, and logs "portal: closed the macOS login window".

**Why**: even after a successful background login, macOS keeps Wi-Fi blocked
for every other app (interface rank Never) until its own portal window is
dismissed. Quitting it counts as dismissing it: configd logs
`websheet: died` → `Authenticated` and the block lifts. The window is left
open when the login fails, so a manual login is still possible.

**Files**: `Sources/SmartWiFi/Portal.swift`, `Sources/SmartWiFi/Engine.swift`

**Verified** (23:24): logged out of Pronto, forced a rejoin of the hostel Wi-Fi with
SmartWiFi stopped, and the macOS window opened with no internet for other apps.
Then SmartWiFi started: login 23:24:30 → online 23:24:33 → window closed →
other apps online 23:24:34.

**Known issues**: the window still flashes up for a few seconds on each
rejoin. It can be turned off system-wide (affects every network) with
`sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.captive.control Active -bool false`;
not applied. The Tailscale prompt timing is still open.

**Next step**: the Tailscale prompt fix; then v2.

## 2026-10-24: Only send the portal login to the known hostel network

**What**: SmartWiFi remembers the hostel network's router (hardware address)
and the portal's IP from a known-good login. Later, it sends the portal
password only when the router matches, and it connects to the remembered
portal IP directly (`curl` `resolve`), so the network's DNS can't redirect it.
On a mismatch it holds the login, notes it in the menu and sends one ntfy
warning per join. "Log in now" from the menu overrides this and trusts the
new router. A network with no record yet is trusted on its first login.

**Why**: the hostel Wi-Fi is open and the portal is plain HTTP. Anyone nearby
could broadcast a network with the same name and a fake login page, and
SmartWiFi would hand over the password automatically.

**Router lookup**: the router's hardware address comes from macOS's own
DHCP state (SCDynamicStore `ARPResolvedHardwareAddress`, the same value
macOS uses as the network's signature). Running `arp` from the app returns
an empty table, since macOS hides it from the app.

**Files**: `Sources/SmartWiFi/Config.swift` (TrustedPortal in state),
`Sources/SmartWiFi/Portal.swift`, `Sources/SmartWiFi/Engine.swift`

**Verified**: router lookup returns the hotspot router from a test build that
can't read the ARP table; a pinned address is used (and a bogus one never
connects); trust record seeded from the earlier verified login and survives
restarts. The mismatch path itself (unknown router -> login held) hasn't been
exercised on a live network yet; both hostel runs stopped earlier, at "can't
identify the router", because DHCP wasn't answering.

**Known issues**: the hostel Wi-Fi's DHCP wasn't answering during the test
(02:14, "server not responding"), so a full real login through the new
check hasn't run yet. With no IP and no router SmartWiFi correctly refused.

**Next step**: on the hostel Wi-Fi, confirm a normal login still goes
through; then the Tailscale prompt timing.

## 2026-10-26 — Other saved networks as a last resort

**What**: when none of the listed networks work, SmartWiFi now also tries the
networks saved in macOS's Wi-Fi settings (read with `networksetup
-listpreferredwirelessnetworks`, in macOS's order, refreshed every 5 min).
They rank after every listed network. Joining one first tries CoreWLAN, then
`networksetup -setairportnetwork`, which uses the password macOS saved. One
that won't join is skipped for 10 min; one with no internet for a minute is
skipped for 10 min, as listed networks already were (that rule now applies
to any network). A saved network SmartWiFi is on is left alone while it has
internet, except for a preferred network coming into range. On by default;
Settings > Networks has a toggle.

**Why**: macOS's own auto-join won't leave a saved network that has no
internet and won't rank saved networks against SmartWiFi's list.

**Files**: `Sources/SmartWiFi/Config.swift`, `Sources/SmartWiFi/Engine.swift`,
`Sources/SmartWiFi/SettingsView.swift`

**Verified**: builds, installs, restarts on the hotspot as before; the saved-network
list parses. Joining a saved network hasn't been run live (it means taking
the Mac off the hotspot and the hostel Wi-Fi).

**Live check of the portal trust check**: two real hostel logins went through
it today (16:48 and 17:58), each "portal: logged in, online" with no
unknown-router note.

**Known issues**: whether CoreWLAN or networksetup can join a saved WPA
network without the password in hand is unconfirmed.

**Next step**: release polish (see the list in the README's roadmap, once added).

## 2026-10-27 — Tailscale CLI fixed; switch to stop managing Tailscale

**What**: SmartWiFi now runs the Tailscale CLI with `TAILSCALE_BE_CLI=1`.
New "SmartWiFi controls Tailscale" switch in the menu and Settings > Tailscale
(on by default); when off, SmartWiFi never runs the Tailscale CLI. "Never touch
it" now also skips the status check on joining the hotspot.

**Why**: started from a background app (no terminal, no TERM), the Tailscale
app binary doesn't act as the CLI; it launches another copy of the Tailscale
app, which never answers. SmartWiFi killed it after 8 s, three times every
30 s. That was the constant on/off the user saw, and the cause of every
"tailscale: not answering, not asking" (so the hotspot prompt never ran and
the menu's Tailscale toggle never showed). Reproduced with
`env -i .../Tailscale status --json` (hangs) vs. the same with
`TAILSCALE_BE_CLI=1` (answers at once).

**Files**: `Sources/SmartWiFi/Tailscale.swift`, `Sources/SmartWiFi/Config.swift`,
`Sources/SmartWiFi/Engine.swift`, `Sources/SmartWiFi/MenuView.swift`,
`Sources/SmartWiFi/SettingsView.swift`, `Sources/SmartWiFi/App.swift`

**Verified**: after reinstalling, no stuck `Tailscale status` processes over
several 30 s checks (one leftover from the old build was killed).

**Known issues**: the hotspot prompt itself (Mac pop-up + phone buttons) still
needs a live run now that the CLI answers.

**Next step**: join the hotspot with policy "Ask me" and check the prompt appears.

## 2026-10-28 — Ready to publish: neutral defaults, new bundle ID, licence

**What**:
- New installs start with an empty network list (no built-in networks); the
  menu says "No networks set up yet: open Settings > Networks" until one is added.
- Portal option is just "Pronto Networks"; wording in the prompt, menu and
  Location message no longer assumes a hostel.
- Bundle ID and LaunchAgent label: `io.github.monkeatwork.smartwifi`.
- MIT `LICENSE`.
- Network names scrubbed from this changelog and `docs/CONTEXT.md`.
- Public repo starts from a single commit; the full development history is
  kept in a separate private repo.

**Why**: preparing the repo to go public.

**Files**: `Sources/SmartWiFi/Config.swift`, `Engine.swift`, `MenuView.swift`,
`TailscalePrompt.swift`, `LaunchAgent.swift`, `Info.plist`, `scripts/*.sh`,
`README.md`, `LICENSE`, `docs/CHANGELOG.md`, `docs/CONTEXT.md`

**Known issues**: the new bundle ID means macOS asks for Location access again
on the next install; until it's allowed, network names are hidden and nothing
switches. Existing settings, passwords (Keychain) and state are unaffected.

**Next step**: install on the Mac while someone can click "Allow"; signing and
release packaging.
