import AppKit
import Foundation
import SystemConfiguration

enum Connectivity { case online, captive, offline }

/// Error of the most recent failed request, for logging.
private var lastFetchError = ""

/// Synchronous HTTP through /usr/bin/curl; only ever called from the engine's
/// serial queue. URLSession refuses requests (-1009, "offline") while macOS
/// still rates a freshly joined captive network as having no internet, which
/// is exactly when the portal login has to happen; curl's plain sockets aren't
/// affected. The request goes in as a curl config on stdin, keeping the portal
/// password out of the process list.
///
/// Requests are bound to the Wi-Fi interface. While macOS shows its own login
/// window for a captive network it ranks Wi-Fi "Never", so unbound sockets
/// can't reach the portal ("could not connect") until that window is closed;
/// sockets bound to the interface still can.
private func curl(_ config: String, timeout: Int, interface: String) -> (status: Int, body: String, address: String)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p.arguments = ["-s", "-K", "-", "-m", String(timeout), "--interface", interface, "-w", "\n%{remote_ip}\n%{http_code}"]
    let input = Pipe()
    let output = Pipe()
    p.standardInput = input
    p.standardOutput = output
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch {
        lastFetchError = error.localizedDescription
        return nil
    }
    input.fileHandleForWriting.write(Data(config.utf8))
    try? input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        let reasons: [Int32: String] = [6: "could not resolve host", 7: "could not connect", 28: "timed out"]
        lastFetchError = "curl exit \(p.terminationStatus)" + (reasons[p.terminationStatus].map { " (\($0))" } ?? "")
        return nil
    }
    var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
    guard lines.count >= 3 else { return nil }
    let status = Int(lines.removeLast()) ?? 0
    let address = lines.removeLast()
    return (status, lines.joined(separator: "\n"), address)
}

func connectivity(via interface: String) -> Connectivity {
    let config = "url = \"http://captive.apple.com/hotspot-detect.html\"\nheader = \"Cache-Control: no-cache\"\n"
    guard let (status, body, _) = curl(config, timeout: 6, interface: interface) else { return .offline }
    return status == 200 && body.contains("<TITLE>Success</TITLE>") ? .online : .captive
}

private func formEncode(_ s: String) -> String {
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
}

private func plainText(_ html: String) -> String {
    html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

enum Portal {
    static let prontoURL = URL(string: "http://phc.prontonetworks.com/cgi-bin/authlogin")!

    /// Quits the Captive Network Assistant window if it's open. macOS treats
    /// that like the user cancelling it and lets all apps use Wi-Fi again.
    static func closeSystemLoginWindow() -> Bool {
        let windows = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.CaptiveNetworkAssistant")
        for app in windows where !app.terminate() { app.forceTerminate() }
        return !windows.isEmpty
    }

    /// The network's router as (IP, MAC address), as recorded by macOS's own
    /// DHCP client. (Running `arp` doesn't work here: macOS hides the ARP
    /// table from the app.)
    static func router(on interface: String) -> (ip: String, mac: String)? {
        guard let store = SCDynamicStoreCreate(nil, "smartwifi" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String]
        else { return nil }
        for key in keys {
            guard let ipv4 = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  ipv4["InterfaceName"] as? String == interface,
                  let ip = ipv4["Router"] as? String,
                  let mac = ipv4["ARPResolvedHardwareAddress"] as? String,
                  ipv4["ARPResolvedIPAddress"] as? String == ip else { continue }
            return (ip, mac.lowercased())
        }
        return nil
    }

    /// Submits the Pronto Networks login form, then confirms with the probe.
    /// With `address`, connects to that IP instead of trusting the network's DNS.
    /// Returns the IP actually used when the login worked.
    static func prontoLogin(user: String, password: String, via interface: String, address: String?) -> String? {
        let fields = [("userId", user), ("password", password), ("serviceName", "ProntoAuthentication"), ("Submit22", "Login")]
        // Form-encoded values contain only unreserved characters and %XX, so
        // they're safe inside the quoted curl config value.
        let form = fields.map { "\($0.0)=\(formEncode($0.1))" }.joined(separator: "&")
        let host = prontoURL.host ?? "portal"
        var config = "url = \"\(prontoURL.absoluteString)\"\ndata = \"\(form)\"\n"
        if let address { config += "resolve = \"\(host):80:\(address)\"\n" }
        guard let (_, body, used) = curl(config, timeout: 10, interface: interface) else {
            log("portal: request to \(host) failed: \(lastFetchError)")
            return nil
        }
        // Access can take a few seconds to open up after the portal accepts the login.
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 2)
            if connectivity(via: interface) == .online { return used }
        }
        log("portal: still offline after login, portal said: \(plainText(body).prefix(160))")
        return nil
    }
}
