import AppKit
import CoreLocation
import CoreWLAN
import Foundation

/// What the menu bar shows. Built on the engine queue, published on main.
struct Status {
    var ssid: String?
    var role: NetworkRole?
    var rssi = 0
    var connectivity: Connectivity = .offline
    var since = Date()
    var message = "Starting…"
    var pausedUntil: Date?
    var tailscaleRunning: Bool?
    var tailscalePausedByApp = false
    var tailscaleRemembered: String?
    var dataToday: UInt64 = 0
    var dataCapBytes: UInt64 = 0
    var dataCapReached = false
    var nearby: [String] = []
    var hasPortal = false

    var icon: String {
        if pausedUntil != nil { return "pause.circle" }
        if ssid == nil { return "wifi.slash" }
        if connectivity != .online { return "wifi.exclamationmark" }
        return role == .preferred ? "personalhotspot" : "wifi"
    }
}

/// Picks the best configured network, keeps captive portals logged in and runs
/// the extras (Tailscale prompt, notifications, data meter, watchdog, awake).
final class Engine: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var status = Status()

    let store: ConfigStore
    private let state = StateStore()
    private let wifi = CWWiFiClient.shared()
    private let location = CLLocationManager()
    private let queue = DispatchQueue(label: "smartwifi.engine")
    private let notifier = Notifier()
    private let awake = Awake()
    private let promptServer = PromptServer()
    private let prompt = TailscalePrompt()
    private var timer: DispatchSourceTimer?
    private var timerInterval = 0.0

    // Everything below is only touched on `queue`.
    private var authorized = false
    private var firstTick = true
    private var lastNote = ""
    private var current: String?
    private var connectedSince = Date()
    private var lastScan = Date.distantPast
    private var scanned: [String: CWNetwork] = [:]   // strongest BSSID per SSID from the last scan
    private var seenScans: [String: Int] = [:]       // consecutive scans a configured SSID was usable
    private var lastInRange: [String] = []
    private var blockedUntil: [String: Date] = [:]
    private var savedNetworks: [String] = []          // macOS's saved networks, in its order
    private var lastSavedRead = Date.distantPast
    private var offlineSince: Date?                  // no internet at all
    private var currentOfflineSince: Date?           // current network without internet
    private var settleUntil = Date.distantPast
    private var loginFailures = 0
    private var nextLoginAt = Date.distantPast
    private var manualLogin = false           // "Log in now": trust this network's router
    private var portalWarned = false          // warned about an unknown router on this join
    private var manualUntil = Date.distantPast
    private var pausedUntil: Date?
    private var lastPowerCycle = Date.distantPast
    private var capNotifiedDay = ""
    private var lastBytes: UInt64?
    private var lastStateSave = Date.distantPast
    private var pendingPrompt: String?
    private var tailscaleRunning: Bool?
    private var lastTailscaleCheck = Date.distantPast
    private var nextTailscaleRestore = Date.distantPast

    init(store: ConfigStore) {
        self.store = store
        super.init()
    }

    func start() {
        location.delegate = self
        // A background agent is never "in use", so ask for Always.
        if location.authorizationStatus != .authorizedAlways {
            location.requestAlwaysAuthorization()
        }
        updateAuthorization(location.authorizationStatus)
        promptServer.onAnswer = { [weak self] token, off in
            self?.queue.async { self?.answerPrompt(token: token, turnOff: off, remember: false, from: "phone") }
        }
        let cfg = store.snapshot
        queue.async {
            self.migrateCredentials(cfg)
            self.scheduleTimer(cfg.checkInterval)
        }
        log("started: " + cfg.networks.map { "\($0.ssid) (\($0.role.rawValue))" }.joined(separator: ", "))
    }

    private func scheduleTimer(_ interval: Double) {
        timer?.cancel()
        timerInterval = interval
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: interval, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: Location (without it macOS redacts every SSID)

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateAuthorization(manager.authorizationStatus)
    }

    private func updateAuthorization(_ status: CLAuthorizationStatus) {
        let ok = !(status == .notDetermined || status == .denied || status == .restricted)
        queue.async {
            if ok != self.authorized { log("location: \(ok ? "authorized" : "not authorized") (status \(status.rawValue))") }
            self.authorized = ok
        }
    }

    /// Logs a steady-state message once instead of on every tick.
    private func note(_ message: String) {
        guard message != lastNote else { return }
        lastNote = message
        log(message)
    }

    // MARK: Main loop

    private func tick() {
        let cfg = store.snapshot
        if cfg.checkInterval != timerInterval { scheduleTimer(cfg.checkInterval) }
        awake.update(enabled: cfg.keepAwake)

        let iface = wifi.interface()
        var ssid: String?
        var entry: NetworkEntry?
        var conn = Connectivity.offline
        defer { publish(iface, ssid, entry, conn, cfg) }

        guard authorized else {
            note("waiting for permission: System Settings > Privacy & Security > Location Services > SmartWiFi")
            return
        }
        guard let iface, iface.powerOn() else {
            note("Wi-Fi is off")
            return
        }
        let now = Date()
        guard now >= settleUntil else { return }

        ssid = iface.ssid()  // nil means not connected
        entry = cfg.networks.first { $0.ssid == ssid }
        if ssid != current || firstTick { networkChanged(from: current, to: ssid, entry: entry, cfg: cfg) }
        firstTick = false
        sampleMeter(iface, counting: entry?.role == .preferred, cfg: cfg)
        refreshTailscale(now, cfg: cfg)
        let ifname = iface.interfaceName ?? "en0"
        conn = ssid == nil ? .offline : connectivity(via: ifname)

        // Captive portal: keep it logged in, even while auto-switching is paused.
        if let entry, entry.portal != .none {
            if conn != .online, loginToPortal(entry, interface: ifname, cfg: cfg) { conn = .online }
            // macOS keeps Wi-Fi blocked for every other app while its own portal
            // window is open, even once we're logged in; closing it lifts that.
            if conn == .online, Portal.closeSystemLoginWindow() { log("portal: closed the macOS login window") }
        }
        trackOnline(conn, ssid: ssid, cfg: cfg, now: now)
        if conn == .online, let ssid { note("on \(ssid): online") }

        if cfg.manageTailscale, state.value.tailscalePausedByApp, ssid != nil, entry?.role != .preferred, conn == .online,
           now >= nextTailscaleRestore {
            restoreTailscale()
        }
        if watchdog(iface, cfg: cfg, now: now) { return }

        if let until = pausedUntil {
            if until > now { return note("auto-switching paused") }
            pausedUntil = nil
            log("auto-switching resumed")
        }
        // A manual pick holds only while it works.
        guard now >= manualUntil || ssid == nil || conn != .online else { return }
        chooseNetwork(iface, ssid: ssid, entry: entry, conn: conn, cfg: cfg, now: now)
    }

    private func chooseNetwork(_ iface: CWInterface, ssid: String?, entry: NetworkEntry?, conn: Connectivity,
                               cfg: AppConfig, now: Date) {
        scanIfNeeded(iface, entry: entry, conn: conn, cfg: cfg, now: now)
        let capReached = dataCapReached(cfg)

        func usable(_ n: NetworkEntry) -> Bool {
            guard let net = scanned[n.ssid], net.rssiValue >= -80 else { return false }
            if let until = blockedUntil[n.ssid], until > now { return false }
            if n.role == .preferred && capReached { return false }
            // Only leave a working network for a preferred one that has stuck around.
            if n.role == .preferred, n.ssid != ssid, conn == .online, (seenScans[n.ssid] ?? 0) < 2 { return false }
            return true
        }

        // Other networks saved in macOS come last. They have no password or portal
        // settings here; macOS supplies the password when joining.
        var candidates = cfg.networks
        if cfg.useSavedNetworks {
            candidates += saved(iface, now: now)
                .filter { s in !cfg.networks.contains { $0.ssid == s } }
                .map { NetworkEntry(ssid: $0, role: .fallback) }
        }

        // A network that's had no internet for a minute gets a 10-minute break,
        // as long as there's somewhere else to go.
        if let s = ssid, let since = currentOfflineSince, now.timeIntervalSince(since) >= 60,
           candidates.contains(where: { $0.ssid != s && usable($0) }) {
            log("\(s) has had no internet for a minute, avoiding it for 10 min")
            blockedUntil[s] = now.addingTimeInterval(600)
            currentOfflineSince = nil
        }

        guard let target = candidates.first(where: usable) else {
            if cfg.networks.isEmpty { note("No networks set up yet: open Settings > Networks") }
            else if ssid == nil { note("no usable network in range") }
            return
        }
        guard target.ssid != ssid else { return }
        // A saved network SmartWiFi is already on is treated like any network it doesn't
        // manage: left alone while it has internet.
        let targetIndex = candidates.firstIndex(of: target)!
        let currentIndex = cfg.networks.firstIndex { $0.ssid == ssid }

        let reason: String
        if ssid == nil {
            reason = "not connected"
        } else if let until = blockedUntil[ssid!], until > now {
            reason = "\(ssid!) has no internet"
        } else if entry?.role == .preferred && capReached {
            reason = "today's hotspot data cap is reached"
        } else if let ci = currentIndex, targetIndex < ci {
            reason = "\(target.ssid) is in range"
        } else if currentIndex == nil, conn != .online {
            reason = "\(ssid!) has no internet"
        } else if currentIndex == nil, target.role == .preferred {
            reason = "\(target.ssid) is in range"
        } else {
            if currentIndex == nil, let s = ssid { note("on \(s) with internet, leaving it alone") }
            return
        }
        log("\(reason), switching to \(target.ssid)")
        join(target, iface)
    }

    /// Networks saved in macOS's Wi-Fi settings, re-read every 5 minutes.
    private func saved(_ iface: CWInterface, now: Date) -> [String] {
        guard now.timeIntervalSince(lastSavedRead) >= 300 else { return savedNetworks }
        lastSavedRead = now
        let out = run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", iface.interfaceName ?? "en0"])
        savedNetworks = out?.split(separator: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? savedNetworks
        return savedNetworks
    }

    private func scanIfNeeded(_ iface: CWInterface, entry: NetworkEntry?, conn: Connectivity, cfg: AppConfig, now: Date) {
        let onTop = entry != nil && entry == cfg.networks.first && conn == .online
        // Re-check sooner while a preferred network is waiting for its second sighting.
        let confirming = cfg.networks.contains { $0.role == .preferred && $0.ssid != entry?.ssid && seenScans[$0.ssid] == 1 }
        let interval = conn == .online && !confirming ? cfg.scanInterval : cfg.checkInterval
        guard !onTop, now.timeIntervalSince(lastScan) >= interval else { return }
        lastScan = now
        guard let networks = try? iface.scanForNetworks(withName: nil) else { return }
        if !networks.isEmpty, networks.allSatisfy({ $0.ssid == nil }) {
            note("macOS is hiding network names from SmartWiFi - check Location access and that it was started with `open`")
        }
        var best: [String: CWNetwork] = [:]
        func keep(_ n: CWNetwork) {
            guard let s = n.ssid else { return }
            if let b = best[s], b.rssiValue >= n.rssiValue { return }
            best[s] = n
        }
        networks.forEach(keep)
        // A broad scan can miss a phone hotspot; a directed scan finds it reliably.
        for n in cfg.networks where n.role == .preferred && best[n.ssid] == nil {
            ((try? iface.scanForNetworks(withName: n.ssid)) ?? []).forEach(keep)
        }
        scanned = best
        for n in cfg.networks {
            let ok = (best[n.ssid]?.rssiValue ?? -999) >= -80
            seenScans[n.ssid] = ok ? (seenScans[n.ssid] ?? 0) + 1 : 0
        }
        let names = cfg.networks.map(\.ssid).filter { best[$0] != nil }
        if names != lastInRange {
            lastInRange = names
            let detail = names.map { "\($0) \(best[$0]!.rssiValue) dBm" }
            log("in range: \(detail.isEmpty ? "none of your networks" : detail.joined(separator: ", "))")
        }
    }

    @discardableResult
    private func join(_ entry: NetworkEntry, _ iface: CWInterface) -> Bool {
        // Even a failed attempt drops the current link, so let macOS settle
        // (and possibly auto-rejoin) before the next probe.
        settleUntil = Date().addingTimeInterval(10)
        lastNote = ""
        // Always rescan: a cached result can be for a hotspot that was just turned
        // off (apple80211 -3912 after ~10 s) or make the join slow.
        let network = (try? iface.scanForNetworks(withName: entry.ssid))?
            .filter { $0.ssid == entry.ssid }.max { $0.rssiValue < $1.rssiValue }
        guard let network else {
            log("could not join \(entry.ssid): not in range")
            scanned[entry.ssid] = nil
            seenScans[entry.ssid] = 0
            blockedUntil[entry.ssid] = Date().addingTimeInterval(30)
            return false
        }
        let configured = store.snapshot.networks.contains { $0.id == entry.id }
        let password = Keychain.get(entry.passwordAccount)
        do {
            try iface.associate(to: network, password: password)
        } catch {
            // For a network saved in macOS, networksetup joins with the password macOS stored.
            if configured || !joinWithSavedPassword(entry.ssid, iface) {
                log("could not join \(entry.ssid): \(error.localizedDescription)\(password == nil && configured ? " (no password saved)" : "")")
                // A saved network that won't take us likely needs something we can't supply.
                blockedUntil[entry.ssid] = Date().addingTimeInterval(configured ? 120 : 600)
                return false
            }
        }
        log("joined \(entry.ssid)\(configured ? "" : " (saved in macOS)")")
        loginFailures = 0
        nextLoginAt = .distantPast
        return true
    }

    private func joinWithSavedPassword(_ ssid: String, _ iface: CWInterface) -> Bool {
        let ifname = iface.interfaceName ?? "en0"
        guard let out = run("/usr/sbin/networksetup", ["-setairportnetwork", ifname, ssid]) else { return false }
        // networksetup exits 0 even on failure and says why on stdout.
        return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func networkChanged(from old: String?, to new: String?, entry: NetworkEntry?, cfg: AppConfig) {
        current = new
        if new == nil {
            manualUntil = .distantPast
            // Just lost it, so it's probably gone even if the last scan still lists it.
            if let old { blockedUntil[old] = Date().addingTimeInterval(30) }
        }
        connectedSince = Date()
        currentOfflineSince = nil
        loginFailures = 0
        nextLoginAt = .distantPast
        portalWarned = false
        lastNote = ""
        log("network: \(old ?? "none") -> \(new ?? "none")")
        if pendingPrompt != nil, entry?.role != .preferred { closePrompt() }
        // On launch, just take note of where we are.
        guard !firstTick, let new else { return }
        if cfg.notifySwitch {
            notifier.send("Mac switched to \(new)", old.map { "Was on \($0)." } ?? "Was disconnected.",
                          tags: ["signal_strength"], config: cfg)
        }
        if let entry, entry.role == .preferred { tailscaleOnPreferred(entry, cfg: cfg) }
    }

    private func trackOnline(_ conn: Connectivity, ssid: String?, cfg: AppConfig, now: Date) {
        if conn == .online {
            if let since = offlineSince, now.timeIntervalSince(since) >= 60, cfg.notifyBackOnline, let ssid {
                let minutes = Int(now.timeIntervalSince(since) / 60)
                notifier.send("Mac is back online", "Offline for \(minutes) min, now on \(ssid).", tags: ["white_check_mark"], config: cfg)
            }
            offlineSince = nil
            currentOfflineSince = nil
            notifier.flush(cfg)
        } else {
            if offlineSince == nil { offlineSince = now }
            if ssid != nil, currentOfflineSince == nil { currentOfflineSince = now }
        }
    }

    // MARK: Captive portal

    private func loginToPortal(_ entry: NetworkEntry, interface: String, cfg: AppConfig) -> Bool {
        guard Date() >= nextLoginAt else { return false }
        let manual = manualLogin
        manualLogin = false
        guard let user = Keychain.get(entry.portalUserAccount), let pass = Keychain.get(entry.portalPasswordAccount) else {
            note("portal: no login saved for \(entry.ssid) - add it in Settings > Networks")
            return false
        }
        // Anyone can broadcast an open network with the same name and a fake
        // portal. Send the password only through the router seen on the first
        // login, to the portal address seen then. "Log in now" overrides this.
        let key = entry.id.uuidString
        let trusted = state.value.trustedPortals[key]
        guard let router = Portal.router(on: interface) else {
            note("portal: can't identify the router on \(entry.ssid), not sending the login")
            return false
        }
        if let trusted, !trusted.routers.contains(router.mac), !manual {
            note("portal: \(entry.ssid) has an unknown router (\(router.mac)), not sending the login - use Log in now if it's the real network")
            if !portalWarned, cfg.notifyPortalFailure {
                portalWarned = true
                notifier.send("\(entry.ssid) looks different", "SmartWiFi didn't send your portal login: this network's router isn't the one it knows. "
                              + "If it's the real \(entry.ssid), use Log in now in the menu.", tags: ["warning"], priority: 4, config: cfg)
            }
            return false
        }
        log("on \(entry.ssid) without internet, logging in to the portal")
        if let used = Portal.prontoLogin(user: user, password: pass, via: interface, address: manual ? nil : trusted?.address) {
            var record = trusted ?? TrustedPortal(address: used, routers: [])
            if manual, !used.isEmpty { record.address = used }
            if !record.routers.contains(router.mac) {
                record.routers.append(router.mac)
                log("portal: trusting \(entry.ssid) router \(router.mac), portal at \(record.address)")
            }
            state.value.trustedPortals[key] = record
            state.save()
            loginFailures = 0
            lastNote = ""
            log("portal: logged in, online")
            return true
        }
        loginFailures += 1
        // Retry soon (15s, 30s, 60s, then every 2 min): a failed try is cheap.
        let wait = min(120, 15 * pow(2, Double(loginFailures - 1)))
        nextLoginAt = Date().addingTimeInterval(wait)
        log("portal: login failed (\(loginFailures)x), next try in \(Int(wait))s")
        if loginFailures == 3, cfg.notifyPortalFailure {
            notifier.send("Portal login failing on \(entry.ssid)", "3 attempts failed. Check the login in SmartWiFi settings.",
                          tags: ["warning"], priority: 4, config: cfg)
        }
        return false
    }

    // MARK: Tailscale

    private func refreshTailscale(_ now: Date, cfg: AppConfig) {
        guard cfg.manageTailscale else { tailscaleRunning = nil; return }
        guard now.timeIntervalSince(lastTailscaleCheck) >= 30 else { return }
        lastTailscaleCheck = now
        tailscaleRunning = Tailscale.isRunning()
    }

    private func tailscaleOnPreferred(_ entry: NetworkEntry, cfg: AppConfig) {
        guard cfg.manageTailscale, cfg.tailscalePolicy != .never else { return }
        tailscaleRunning = Tailscale.isRunning()
        guard tailscaleRunning == true else {
            log("tailscale: \(tailscaleRunning == nil ? "not answering" : "already off"), not asking")
            return
        }
        switch cfg.tailscalePolicy {
        case .never:
            return
        case .alwaysOff:
            pauseTailscale()
        case .ask:
            if let remembered = state.value.tailscaleRememberedChoice {
                if remembered == "off" { pauseTailscale() }
                return
            }
            askAboutTailscale(on: entry.ssid, cfg: cfg)
        }
    }

    /// Asks on the Mac and, through ntfy, on the phone. The first answer wins.
    private func askAboutTailscale(on ssid: String, cfg: AppConfig) {
        let token = randomToken(24)
        pendingPrompt = token
        log("tailscale prompt: asking whether to turn Tailscale off on \(ssid)")

        if cfg.ntfyEnabled {
            var actions: [[String: Any]] = []
            if let ip = Tailscale.ipv4(), promptServer.start(host: ip, port: UInt16(cfg.promptPort), token: token) {
                let base = "http://\(ip):\(cfg.promptPort)/ts/\(token)"
                actions = [
                    ["action": "http", "label": "Turn off", "url": base + "/off", "method": "POST", "clear": true],
                    ["action": "http", "label": "Keep on", "url": base + "/keep", "method": "POST", "clear": true],
                ]
            }
            notifier.send("On \(ssid): turn off Tailscale?",
                          "You're in the room. It turns back on when the Mac leaves the hotspot.",
                          tags: ["question"], priority: 4, actions: actions, queueIfOffline: false, config: cfg)
        }
        DispatchQueue.main.async {
            self.prompt.show(network: ssid) { off, remember in
                self.queue.async { self.answerPrompt(token: token, turnOff: off, remember: remember, from: "Mac") }
            }
        }
        queue.asyncAfter(deadline: .now() + 120) {
            guard self.pendingPrompt == token else { return }
            log("tailscale prompt: no answer, keeping it on")
            self.closePrompt()
        }
    }

    private func answerPrompt(token: String, turnOff: Bool, remember: Bool, from source: String) {
        guard pendingPrompt == token else { return }
        closePrompt()
        log("tailscale prompt: \(turnOff ? "turn off" : "keep on") (answered on the \(source))")
        if remember {
            state.value.tailscaleRememberedChoice = turnOff ? "off" : "keep"
            state.save()
        }
        guard turnOff else { return }
        // Give the phone's HTTP request time to get its response before the tunnel goes.
        queue.asyncAfter(deadline: .now() + 1) {
            guard self.store.snapshot.networks.first(where: { $0.ssid == self.current })?.role == .preferred else { return }
            self.pauseTailscale()
        }
    }

    private func closePrompt() {
        pendingPrompt = nil
        promptServer.stop()
        DispatchQueue.main.async { self.prompt.close() }
    }

    private func pauseTailscale() {
        guard Tailscale.down() else { return }
        state.value.tailscalePausedByApp = true
        state.save()
        tailscaleRunning = false
        log("tailscale: turned off (back on when the Mac leaves the hotspot)")
    }

    private func restoreTailscale() {
        log("tailscale: turning back on")
        if Tailscale.up() {
            state.value.tailscalePausedByApp = false
            state.save()
            tailscaleRunning = true
            log("tailscale: on")
        } else {
            nextTailscaleRestore = Date().addingTimeInterval(60)
        }
    }

    // MARK: Data meter, watchdog

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var today: String { Self.dayFormat.string(from: Date()) }

    private func sampleMeter(_ iface: CWInterface, counting: Bool, cfg: AppConfig) {
        guard let total = DataMeter.bytes(of: iface.interfaceName ?? "en0") else { return }
        defer { lastBytes = total }
        if state.value.meterDay != today {
            state.value.meterDay = today
            state.value.meterBytes = 0
            state.save()
        }
        guard counting, let last = lastBytes, total >= last else { return }
        state.value.meterBytes += total - last
        if Date().timeIntervalSince(lastStateSave) >= 60 {
            lastStateSave = Date()
            state.save()
        }
        if dataCapReached(cfg), capNotifiedDay != today {
            capNotifiedDay = today
            log("data cap: \(cfg.dataCapMB) MB used on the hotspot today, avoiding it until midnight")
            if cfg.notifyDataCap {
                notifier.send("Hotspot data cap reached", "\(cfg.dataCapMB) MB used today. The Mac will stay off the hotspot until midnight.",
                              tags: ["warning"], config: cfg)
            }
        }
    }

    private func dataCapReached(_ cfg: AppConfig) -> Bool {
        cfg.dataCapMB > 0 && state.value.capOverrideDay != today
            && state.value.meterBytes >= UInt64(cfg.dataCapMB) * 1_000_000
    }

    /// Turns Wi-Fi off and on when nothing has had internet for a while.
    private func watchdog(_ iface: CWInterface, cfg: AppConfig, now: Date) -> Bool {
        guard cfg.watchdogMinutes > 0, let since = offlineSince,
              now.timeIntervalSince(since) >= Double(cfg.watchdogMinutes) * 60,
              now.timeIntervalSince(lastPowerCycle) >= 900 else { return false }
        lastPowerCycle = now
        log("watchdog: no internet for \(cfg.watchdogMinutes) min, turning Wi-Fi off and on")
        do {
            try iface.setPower(false)
            Thread.sleep(forTimeInterval: 3)
            try iface.setPower(true)
        } catch {
            log("watchdog: could not power-cycle Wi-Fi: \(error.localizedDescription)")
        }
        settleUntil = now.addingTimeInterval(15)
        lastNote = ""
        return true
    }

    // MARK: Credentials saved by v1.0

    private func migrateCredentials(_ cfg: AppConfig) {
        guard !state.value.keychainViaSecurityTool else { return }
        let accounts = cfg.networks.flatMap { [$0.passwordAccount, $0.portalUserAccount, $0.portalPasswordAccount] }
        guard Keychain.migrateFromSecItem(accounts) else { return log("keychain: moving saved passwords failed, will retry") }
        state.value.keychainViaSecurityTool = true
        state.save()
        log("keychain: saved passwords moved to the prompt-free store")
    }

    // MARK: Status

    private func publish(_ iface: CWInterface?, _ ssid: String?, _ entry: NetworkEntry?, _ conn: Connectivity, _ cfg: AppConfig) {
        var s = Status()
        s.ssid = ssid
        s.role = entry?.role
        s.rssi = iface?.rssiValue() ?? 0
        s.connectivity = conn
        s.since = connectedSince
        s.message = lastNote
        s.pausedUntil = pausedUntil
        s.tailscaleRunning = tailscaleRunning
        s.tailscalePausedByApp = state.value.tailscalePausedByApp
        s.tailscaleRemembered = state.value.tailscaleRememberedChoice
        s.dataToday = state.value.meterBytes
        s.dataCapBytes = UInt64(cfg.dataCapMB) * 1_000_000
        s.dataCapReached = dataCapReached(cfg)
        s.nearby = cfg.networks.map(\.ssid).filter { scanned[$0] != nil && $0 != ssid }
        s.hasPortal = (entry?.portal ?? .none) != .none
        DispatchQueue.main.async { self.status = s }
    }

    // MARK: Actions from the UI (called on main)

    func connect(to ssid: String) {
        queue.async {
            guard let entry = self.store.snapshot.networks.first(where: { $0.ssid == ssid }),
                  let iface = self.wifi.interface() else { return }
            self.manualUntil = Date().addingTimeInterval(600)
            log("manual: switching to \(ssid) (auto-switching held for 10 min)")
            self.blockedUntil[ssid] = nil
            self.join(entry, iface)
        }
    }

    func loginNow() {
        queue.async {
            self.nextLoginAt = .distantPast
            self.manualLogin = true
            self.tick()
        }
    }

    func pause(for seconds: TimeInterval?) {
        queue.async {
            self.pausedUntil = seconds.map { Date().addingTimeInterval($0) } ?? .distantFuture
            log("auto-switching paused \(seconds.map { "for \(Int($0 / 60)) min" } ?? "until resumed")")
            self.tick()
        }
    }

    func resume() {
        queue.async {
            self.pausedUntil = Date.distantPast
            self.manualUntil = .distantPast
            self.tick()
        }
    }

    func allowDataToday() {
        queue.async {
            self.state.value.capOverrideDay = self.today
            self.state.save()
            log("data cap: overridden for today")
            self.tick()
        }
    }

    func setTailscale(on: Bool) {
        queue.async {
            let ok = on ? Tailscale.up() : Tailscale.down()
            log("manual: tailscale \(on ? "on" : "off")\(ok ? "" : " failed")")
            // A manual choice overrides ours, so don't undo it later.
            self.state.value.tailscalePausedByApp = false
            self.state.save()
            self.tailscaleRunning = Tailscale.isRunning()
            self.tick()
        }
    }

    func forgetTailscaleChoice() {
        queue.async {
            self.state.value.tailscaleRememberedChoice = nil
            self.state.save()
            self.tick()
        }
    }

    func scanNearby(_ completion: @escaping ([String]) -> Void) {
        queue.async {
            let names = ((try? self.wifi.interface()?.scanForNetworks(withName: nil)) ?? [])
                .sorted { $0.rssiValue > $1.rssiValue }
                .compactMap(\.ssid)
            var seen = Set<String>()
            let unique = names.filter { seen.insert($0).inserted }
            DispatchQueue.main.async { completion(unique) }
        }
    }

    func sendTestNotification() {
        let cfg = store.snapshot
        notifier.send("SmartWiFi test", "Notifications are working.", tags: ["tada"], queueIfOffline: false, config: cfg)
    }
}

/// Runs a command and returns its stdout, or nil if it couldn't start or failed.
private func run(_ path: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
}
