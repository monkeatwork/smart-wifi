import Foundation

enum NetworkRole: String, Codable, CaseIterable, Identifiable {
    case preferred, fallback
    var id: String { rawValue }
    var label: String { self == .preferred ? "Preferred (join whenever in range)" : "Fallback" }
}

enum PortalKind: String, Codable, CaseIterable, Identifiable {
    case none, pronto
    var id: String { rawValue }
    var label: String { self == .none ? "None" : "Pronto Networks" }
}

enum TailscalePolicy: String, Codable, CaseIterable, Identifiable {
    case ask, alwaysOff, never
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ask: return "Ask me"
        case .alwaysOff: return "Always turn it off"
        case .never: return "Never touch it"
        }
    }
}

struct NetworkEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var ssid: String
    var role: NetworkRole
    var portal: PortalKind = .none

    // Secrets are keyed by id so renaming a network keeps them.
    var passwordAccount: String { "wifi:\(id)" }
    var portalUserAccount: String { "portal-user:\(id)" }
    var portalPasswordAccount: String { "portal-pass:\(id)" }
}

func randomToken(_ length: Int) -> String {
    let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
    return String((0..<length).map { _ in chars.randomElement()! })
}

extension KeyedDecodingContainer {
    /// Missing or malformed keys fall back to the default, so old files keep loading.
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

struct AppConfig: Codable, Equatable {
    var networks: [NetworkEntry] = []  // added in Settings > Networks
    var checkInterval: Double = 15
    var scanInterval: Double = 30
    var useSavedNetworks = true  // other networks saved in macOS, after the list
    var manageTailscale = true  // false: never run the Tailscale CLI at all
    var tailscalePolicy: TailscalePolicy = .ask
    var ntfyEnabled = false
    var ntfyServer = "https://ntfy.sh"
    var ntfyTopic = "smartwifi-" + randomToken(16)
    var notifySwitch = true
    var notifyPortalFailure = true
    var notifyBackOnline = true
    var notifyDataCap = true
    var keepAwake = true
    var dataCapMB = 0
    var watchdogMinutes = 5
    var promptPort = 8765

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        networks = c.value(.networks, default: d.networks)
        checkInterval = c.value(.checkInterval, default: d.checkInterval)
        scanInterval = c.value(.scanInterval, default: d.scanInterval)
        useSavedNetworks = c.value(.useSavedNetworks, default: d.useSavedNetworks)
        manageTailscale = c.value(.manageTailscale, default: d.manageTailscale)
        tailscalePolicy = c.value(.tailscalePolicy, default: d.tailscalePolicy)
        ntfyEnabled = c.value(.ntfyEnabled, default: d.ntfyEnabled)
        ntfyServer = c.value(.ntfyServer, default: d.ntfyServer)
        ntfyTopic = c.value(.ntfyTopic, default: d.ntfyTopic)
        notifySwitch = c.value(.notifySwitch, default: d.notifySwitch)
        notifyPortalFailure = c.value(.notifyPortalFailure, default: d.notifyPortalFailure)
        notifyBackOnline = c.value(.notifyBackOnline, default: d.notifyBackOnline)
        notifyDataCap = c.value(.notifyDataCap, default: d.notifyDataCap)
        keepAwake = c.value(.keepAwake, default: d.keepAwake)
        dataCapMB = c.value(.dataCapMB, default: d.dataCapMB)
        watchdogMinutes = c.value(.watchdogMinutes, default: d.watchdogMinutes)
        promptPort = c.value(.promptPort, default: d.promptPort)
    }
}

let supportDir = URL(fileURLWithPath: NSString(string: "~/Library/Application Support/SmartWiFi").expandingTildeInPath)

/// Settings edited by the UI on the main thread; the engine reads `snapshot` from its queue.
final class ConfigStore: ObservableObject {
    private let url = supportDir.appendingPathComponent("config.json")
    private let lock = NSLock()
    private var current: AppConfig

    @Published var config: AppConfig {
        didSet {
            guard config != oldValue else { return }
            lock.lock()
            current = config
            lock.unlock()
            save()
        }
    }

    var snapshot: AppConfig {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    init() {
        let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(AppConfig.self, from: $0) }
        current = loaded ?? AppConfig()
        config = current
        if loaded == nil { save() }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            log("config: could not save: \(error.localizedDescription)")
        }
    }
}

/// What a portal network looked like on the first login, so later logins can
/// tell it apart from a look-alike network set up to collect the password.
struct TrustedPortal: Codable {
    var address: String    // IP the portal's host name pointed to
    var routers: [String]  // MAC addresses of the network's router
}

/// Runtime state that must survive restarts. Only touched on the engine's queue.
struct PersistentState: Codable {
    var tailscalePausedByApp = false
    var tailscaleRememberedChoice: String?  // "off" or "keep"
    var meterDay = ""
    var meterBytes: UInt64 = 0
    var capOverrideDay = ""
    var keychainViaSecurityTool = false
    var trustedPortals: [String: TrustedPortal] = [:]  // by NetworkEntry id

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tailscalePausedByApp = c.value(.tailscalePausedByApp, default: false)
        tailscaleRememberedChoice = c.value(.tailscaleRememberedChoice, default: nil)
        meterDay = c.value(.meterDay, default: "")
        meterBytes = c.value(.meterBytes, default: 0)
        capOverrideDay = c.value(.capOverrideDay, default: "")
        keychainViaSecurityTool = c.value(.keychainViaSecurityTool, default: false)
        trustedPortals = c.value(.trustedPortals, default: [:])
    }
}

final class StateStore {
    private let url = supportDir.appendingPathComponent("state.json")
    var value: PersistentState

    init() {
        value = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PersistentState.self, from: $0) } ?? PersistentState()
    }

    func save() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
