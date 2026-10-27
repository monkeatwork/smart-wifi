import SwiftUI

let configStore = ConfigStore()
let engine = Engine(store: configStore)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var activity: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        redirectOutputToLog()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep App Nap from stretching the timer while the Mac sits idle.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep], reason: "Wi-Fi switching")
        engine.start()
    }
}

@main
struct SmartWiFiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(engine: engine, store: engine.store)
        } label: {
            MenuLabel(engine: engine)
        }
        .menuBarExtraStyle(.window)

        Window("SmartWiFi Settings", id: "settings") {
            SettingsView(engine: engine, store: configStore)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
