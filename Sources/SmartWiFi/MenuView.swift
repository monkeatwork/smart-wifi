import SwiftUI

struct MenuLabel: View {
    @ObservedObject var engine: Engine
    var body: some View { Image(systemName: engine.status.icon) }
}

struct MenuView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var store: ConfigStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = engine.status
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: s.icon).font(.title2).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.ssid ?? "Not connected").font(.headline)
                    Text(subtitle(s)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !s.message.isEmpty {
                Text(s.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }

            Divider()

            Toggle("SmartWiFi controls Tailscale", isOn: $store.config.manageTailscale)
                .toggleStyle(.switch)
            if store.config.manageTailscale, let running = s.tailscaleRunning {
                Toggle("Tailscale", isOn: Binding(get: { running }, set: { engine.setTailscale(on: $0) }))
                    .toggleStyle(.switch)
                if s.tailscalePausedByApp {
                    Text("Off for the hotspot; turns back on when the Mac leaves it.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Hotspot data today")
                Spacer()
                Text(dataText(s)).monospacedDigit().foregroundStyle(s.dataCapReached ? .red : .primary)
            }
            if s.dataCapReached {
                Button("Allow the hotspot anyway today") { engine.allowDataToday() }
            }

            if !s.nearby.isEmpty || s.hasPortal {
                Divider()
                ForEach(s.nearby, id: \.self) { ssid in
                    Button { engine.connect(to: ssid) } label: { Label("Switch to \(ssid)", systemImage: "arrow.right.circle") }
                }
                if s.hasPortal {
                    Button { engine.loginNow() } label: { Label("Log in to portal now", systemImage: "person.badge.key") }
                }
            }
            if s.pausedUntil != nil {
                Button { engine.resume() } label: { Label("Resume auto-switching", systemImage: "play.circle") }
            } else {
                Menu {
                    Button("For 1 hour") { engine.pause(for: 3600) }
                    Button("Until I resume") { engine.pause(for: nil) }
                } label: { Label("Pause auto-switching", systemImage: "pause.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Divider()

            HStack {
                Button("Settings…") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Log") { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
                Button("Quit") { LaunchAgent.quitUntilNextLogin() }
                    .help("Quit until next login")
            }
        }
        .buttonStyle(.borderless)
        .padding(14)
        .frame(width: 300)
    }

    private func subtitle(_ s: Status) -> String {
        guard s.ssid != nil else { return "Looking for a network" }
        let since = s.since.formatted(date: .omitted, time: .shortened)
        switch s.connectivity {
        case .online: return "Online · since \(since) · \(s.rssi) dBm"
        case .captive: return "Waiting for portal login"
        case .offline: return "No internet"
        }
    }

    private func dataText(_ s: Status) -> String {
        let used = ByteCountFormatter.string(fromByteCount: Int64(s.dataToday), countStyle: .decimal)
        guard s.dataCapBytes > 0 else { return used }
        return "\(used) / \(ByteCountFormatter.string(fromByteCount: Int64(s.dataCapBytes), countStyle: .decimal))"
    }
}
