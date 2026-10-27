import Foundation
import Security

/// Generic passwords in the login Keychain under service "smartwifi".
///
/// All access goes through /usr/bin/security. Items it creates trust that
/// Apple-signed tool, which never changes, so the ad-hoc-signed app gets no
/// Keychain prompts, even after a rebuild. (Items the app creates itself trust
/// one particular build, and every rebuild brought the "allow access" prompt
/// back, blocking the engine until someone clicked it.)
enum Keychain {
    static let service = "smartwifi"

    static func get(_ account: String) -> String? {
        guard let out = runSecurity(["find-generic-password", "-s", service, "-a", account, "-w"]), !out.isEmpty else { return nil }
        return out
    }

    /// Saves `value`; an empty value deletes the item. The command goes over
    /// stdin with the password hex-encoded, so it never shows up in `ps`.
    static func set(_ account: String, _ value: String) {
        delete(account)
        guard !value.isEmpty else { return }
        let hex = value.utf8.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -s \(service) -a \(account) -l SmartWiFi -X \(hex)\n"
        if runSecurity(["-i"], input: command) == nil || get(account) != value {
            log("keychain: could not save \(account)")
        }
    }

    static func delete(_ account: String) {
        _ = runSecurity(["delete-generic-password", "-s", service, "-a", account])
    }

    /// Moves items written by v1.0 through the Security framework (owned by
    /// that build of the app) over to /usr/bin/security. May show one last
    /// prompt per item.
    static func migrateFromSecItem(_ accounts: [String]) -> Bool {
        var ok = true
        for account in accounts {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: service,
                                       kSecAttrAccount as String: account]
            var q = base
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { continue }
            let value = String(decoding: data, as: UTF8.self)
            SecItemDelete(base as CFDictionary)
            set(account, value)
            ok = ok && get(account) == value
        }
        return ok
    }

    private static func runSecurity(_ args: [String], input: String? = nil) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let output = Pipe()
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        if input != nil { p.standardInput = stdin }
        do { try p.run() } catch { return nil }
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
