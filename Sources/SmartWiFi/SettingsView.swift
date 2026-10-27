import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var store: ConfigStore

    var body: some View {
        TabView {
            NetworksTab(engine: engine, store: store)
                .tabItem { Label("Networks", systemImage: "wifi") }
            TailscaleTab(engine: engine, store: store)
                .tabItem { Label("Tailscale", systemImage: "network") }
            NotificationsTab(engine: engine, store: store)
                .tabItem { Label("Notifications", systemImage: "bell") }
            GeneralTab(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(20)
        .frame(width: 540, height: 440)
    }
}

// MARK: Networks

private struct NetworksTab: View {
    @ObservedObject var engine: Engine
    @ObservedObject var store: ConfigStore
    @State private var selection: NetworkEntry.ID?
    @State private var editing: NetworkEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tried top to bottom. Preferred networks are joined whenever they're in range; fallbacks are used when nothing above them works. Drag to reorder.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(selection: $selection) {
                ForEach(store.config.networks) { n in
                    HStack {
                        Image(systemName: n.role == .preferred ? "personalhotspot" : "wifi").frame(width: 20)
                        Text(n.ssid)
                        Spacer()
                        if n.portal != .none { Text("portal login").font(.caption).foregroundStyle(.secondary) }
                        Text(n.role.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(n.id)
                    .contextMenu { Button("Edit…") { editing = n } }
                }
                .onMove { store.config.networks.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack {
                Button { editing = NetworkEntry(ssid: "", role: .fallback) } label: { Image(systemName: "plus") }
                Button { remove() } label: { Image(systemName: "minus") }.disabled(selection == nil)
                Button("Edit…") { editing = store.config.networks.first { $0.id == selection } }.disabled(selection == nil)
                Spacer()
            }
            Toggle("When none of these work, try other networks saved on this Mac", isOn: $store.config.useSavedNetworks)
        }
        .sheet(item: $editing) { entry in
            NetworkEditor(engine: engine, entry: entry) { saved in
                if let i = store.config.networks.firstIndex(where: { $0.id == saved.id }) {
                    store.config.networks[i] = saved
                } else {
                    store.config.networks.append(saved)
                }
            }
        }
    }

    private func remove() {
        guard let i = store.config.networks.firstIndex(where: { $0.id == selection }) else { return }
        let n = store.config.networks.remove(at: i)
        for account in [n.passwordAccount, n.portalUserAccount, n.portalPasswordAccount] { Keychain.delete(account) }
        selection = nil
    }
}

private struct NetworkEditor: View {
    let engine: Engine
    @State var entry: NetworkEntry
    let onSave: (NetworkEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var hasPassword = false
    @State private var portalUser = ""
    @State private var portalPassword = ""
    @State private var hasPortalPassword = false
    @State private var nearby: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                HStack {
                    TextField("Network name", text: $entry.ssid)
                    Menu("Nearby") {
                        if nearby.isEmpty { Text("Scanning…") }
                        ForEach(nearby, id: \.self) { s in Button(s) { entry.ssid = s } }
                    }
                    .fixedSize()
                }
                Picker("Role", selection: $entry.role) {
                    ForEach(NetworkRole.allCases) { Text($0.label).tag($0) }
                }
                HStack {
                    SecureField("Wi-Fi password", text: $password,
                                prompt: Text(hasPassword ? "Saved (leave blank to keep)" : "None (open network)"))
                    if hasPassword {
                        Button("Forget") { Keychain.delete(entry.passwordAccount); hasPassword = false }
                    }
                }
                Picker("Login portal", selection: $entry.portal) {
                    ForEach(PortalKind.allCases) { Text($0.label).tag($0) }
                }
                if entry.portal == .pronto {
                    TextField("Portal username", text: $portalUser)
                    SecureField("Portal password", text: $portalPassword,
                                prompt: Text(hasPortalPassword ? "Saved (leave blank to keep)" : ""))
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(entry.ssid.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .onAppear {
            hasPassword = Keychain.get(entry.passwordAccount) != nil
            portalUser = Keychain.get(entry.portalUserAccount) ?? ""
            hasPortalPassword = Keychain.get(entry.portalPasswordAccount) != nil
            engine.scanNearby { nearby = $0 }
        }
    }

    private func save() {
        entry.ssid = entry.ssid.trimmingCharacters(in: .whitespaces)
        if !password.isEmpty { Keychain.set(entry.passwordAccount, password) }
        if entry.portal == .pronto {
            Keychain.set(entry.portalUserAccount, portalUser)
            if !portalPassword.isEmpty { Keychain.set(entry.portalPasswordAccount, portalPassword) }
        }
        onSave(entry)
        dismiss()
    }
}

// MARK: Tailscale

private struct TailscaleTab: View {
    @ObservedObject var engine: Engine
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Toggle("Let SmartWiFi control Tailscale", isOn: $store.config.manageTailscale)
            Text("When off, SmartWiFi never checks, asks about, or switches Tailscale.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("When the Mac joins a preferred network", selection: $store.config.tailscalePolicy) {
                ForEach(TailscalePolicy.allCases) { Text($0.label).tag($0) }
            }
            .disabled(!store.config.manageTailscale)
            if let remembered = engine.status.tailscaleRemembered {
                HStack {
                    Text("Remembered answer: \(remembered == "off" ? "turn it off" : "keep it on")")
                    Spacer()
                    Button("Forget") { engine.forgetTailscaleChoice() }
                }
            }
            Text("Tailscale is turned back on when the Mac leaves the hotspot, but only if SmartWiFi turned it off. If you turn it off yourself, it stays off.")
                .font(.caption).foregroundStyle(.secondary)
            Text("With no exit node, normal internet traffic doesn't go through Tailscale, so turning it off gives only a small speed gain.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

// MARK: Notifications

private struct NotificationsTab: View {
    @ObservedObject var engine: Engine
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Toggle("Send notifications to my phone (ntfy)", isOn: $store.config.ntfyEnabled)
            TextField("Server", text: $store.config.ntfyServer)
            HStack {
                TextField("Topic", text: $store.config.ntfyTopic)
                Button("New") { store.config.ntfyTopic = "smartwifi-" + randomToken(16) }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.config.ntfyTopic, forType: .string)
                }
            }
            Text("Install the ntfy app on your phone and subscribe to this topic. Anyone who knows the topic name can read it, so keep it random. The Tailscale question's buttons only work while your phone is on Tailscale.")
                .font(.caption).foregroundStyle(.secondary)
            Section("Notify me when") {
                Toggle("The Mac switches networks", isOn: $store.config.notifySwitch)
                Toggle("Portal login keeps failing", isOn: $store.config.notifyPortalFailure)
                Toggle("The Mac is back online after an outage", isOn: $store.config.notifyBackOnline)
                Toggle("The hotspot data cap is reached", isOn: $store.config.notifyDataCap)
            }
            Button("Send test notification") { engine.sendTestNotification() }
                .disabled(!store.config.ntfyEnabled)
        }
        .formStyle(.grouped)
    }
}

// MARK: General

private struct GeneralTab: View {
    @ObservedObject var store: ConfigStore
    @State private var launchAtLogin = LaunchAgent.isEnabled

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in LaunchAgent.setEnabled(on) }
            Toggle("Keep the Mac awake while plugged in", isOn: $store.config.keepAwake)
            Text("Closing the lid still sleeps the Mac unless an external display is attached.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Hotspot data cap per day") {
                HStack {
                    TextField("", value: $store.config.dataCapMB, format: .number).frame(width: 80)
                    Text("MB (0 = off)")
                }
            }
            Stepper(value: $store.config.watchdogMinutes, in: 0...60) {
                Text(store.config.watchdogMinutes == 0 ? "Wi-Fi watchdog: off"
                     : "Restart Wi-Fi after \(store.config.watchdogMinutes) min with no internet")
            }
            Stepper(value: $store.config.checkInterval, in: 5...120, step: 5) {
                Text("Check every \(Int(store.config.checkInterval)) s")
            }
        }
        .formStyle(.grouped)
    }
}
