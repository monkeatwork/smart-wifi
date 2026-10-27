import AppKit
import SwiftUI

/// Floating "turn off Tailscale?" panel on the Mac. Main thread only.
final class TailscalePrompt {
    private var panel: NSPanel?

    func show(network: String, onAnswer: @escaping (_ turnOff: Bool, _ remember: Bool) -> Void) {
        close()
        let p = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = "SmartWiFi"
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: PromptView(network: network) { [weak self] off, remember in
            self?.close()
            onAnswer(off, remember)
        })
        p.center()
        p.orderFrontRegardless()
        panel = p
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

private struct PromptView: View {
    let network: String
    let answer: (Bool, Bool) -> Void
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("You're on \(network)", systemImage: "personalhotspot").font(.headline)
            Text("Turn off Tailscale while on the hotspot? It turns back on automatically when the Mac leaves the hotspot.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Remember my choice", isOn: $remember)
            HStack {
                Text("Keeps it on if you don't answer in 2 min.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Keep on") { answer(false, remember) }
                Button("Turn off") { answer(true, remember) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
