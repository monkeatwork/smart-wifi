import Foundation

let logPath = NSString(string: "~/Library/Logs/smartwifi.log").expandingTildeInPath

private let timestamp: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    return f
}()

func log(_ message: String) {
    print("\(timestamp.string(from: Date())) \(message)")
    fflush(stdout)
}

/// Launched through LaunchServices there's no stdout to capture, so log to a file.
func redirectOutputToLog() {
    freopen(logPath, "a", stdout)
    freopen(logPath, "a", stderr)
}
