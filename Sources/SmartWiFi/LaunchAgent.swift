import AppKit

/// The LaunchAgent written by scripts/install.sh starts the app at login and
/// restarts it if it crashes.
enum LaunchAgent {
    static let label = "io.github.monkeatwork.smartwifi"
    private static var domain: String { "gui/\(getuid())" }
    private static var plist: String { NSString(string: "~/Library/LaunchAgents/\(label).plist").expandingTildeInPath }

    @discardableResult
    private static func launchctl(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static var isEnabled: Bool {
        guard FileManager.default.fileExists(atPath: plist) else { return false }
        let disabled = launchctl(["print-disabled", domain])
        return !disabled.contains("\"\(label)\" => disabled") && !disabled.contains("\"\(label)\" => true")
    }

    static func setEnabled(_ on: Bool) {
        if on {
            launchctl(["enable", "\(domain)/\(label)"])
            launchctl(["bootstrap", domain, plist])
        } else {
            launchctl(["disable", "\(domain)/\(label)"])
            launchctl(["bootout", "\(domain)/\(label)"])
        }
        log("launch at login: \(on ? "on" : "off")")
    }

    /// Unloads the agent so KeepAlive doesn't relaunch us; it loads again at next login.
    static func quitUntilNextLogin() {
        log("quitting until next login")
        launchctl(["bootout", "\(domain)/\(label)"])
        NSApp.terminate(nil)
    }
}
