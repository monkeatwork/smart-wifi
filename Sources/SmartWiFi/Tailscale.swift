import Foundation

/// Drives the Tailscale app through its bundled CLI.
enum Tailscale {
    static let cli = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

    static var installed: Bool { FileManager.default.isExecutableFile(atPath: cli) }

    @discardableResult
    static func run(_ args: [String], timeout: TimeInterval = 20) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        // The app binary acts as the CLI only when told to or when run from a
        // terminal. Started from a background app it launches a second copy of
        // the Tailscale app instead, which never answers.
        p.environment = ProcessInfo.processInfo.environment.merging(["TAILSCALE_BE_CLI": "1"]) { $1 }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Whether Tailscale is switched on. "Starting" counts: it's what Tailscale
    /// reports while reconnecting right after a network change.
    /// nil when Tailscale isn't installed or doesn't answer.
    static func isRunning() -> Bool? {
        guard installed else { return nil }
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
            let (status, output) = run(["status", "--json"], timeout: 8)
            guard status == 0,
                  let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
                  let state = json["BackendState"] as? String else { continue }
            return state == "Running" || state == "Starting"
        }
        return nil
    }

    static func ipv4() -> String? {
        let (status, output) = run(["ip", "-4"], timeout: 8)
        let ip = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return status == 0 && !ip.isEmpty && !ip.contains(" ") ? ip : nil
    }

    static func down() -> Bool {
        let (status, output) = run(["down"])
        if status != 0 { log("tailscale: down failed: \(output.prefix(200))") }
        return status == 0
    }

    static func up() -> Bool {
        var (_, output) = run(["up"])
        // A bare `up` is refused when non-default prefs (e.g. --accept-routes) are
        // set; Tailscale prints the exact command to use instead.
        if output.contains("requires mentioning all"),
           let line = output.split(separator: "\n").first(where: { $0.contains("tailscale up") }) {
            let args = line.split(separator: " ").map(String.init).drop { $0 != "up" }
            (_, output) = run(Array(args))
        }
        for _ in 0..<5 {
            if isRunning() == true { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        log("tailscale: up failed: \(output.prefix(200))")
        return false
    }
}
