import SwiftUI
import AppKit

/// Window identity, in one place per window.
///
/// SwiftUI opens a window by `id`, but an accessory (menu-bar) app has to find the
/// resulting `NSWindow` **by title** to bring it in front of the popover. A
/// mismatch between the two produces no compile error — `openWindow(id:)` succeeds
/// and the window silently stays behind — so both halves live together here and
/// change together.
enum SpecWindow {
    static let id = "spec"
    static let title = "LEDS.LED Format"
}

enum ActivityWindow {
    static let id = "activity"
    static let title = "SidePulse Activity"
}

@main
struct SidePulseApp: App {
    @StateObject private var device = DeviceManager()
    @StateObject private var wake = WakeGuard.shared

    init() {
        // Make this app's native tooltips (.help) pop almost instantly instead of
        // the ~1.5s system default. Per-app only (our UserDefaults domain).
        UserDefaults.standard.set(80, forKey: "NSInitialToolTipDelay")

        // Safe maintenance flag: remove the login item and quit WITHOUT starting
        // the app or touching any device volume. Runs before the DeviceManager
        // (@StateObject) is ever created.
        if CommandLine.arguments.contains("--unregister-login") {
            LoginItem.setEnabled(false)
            exit(0)
        }
        // Single-instance: never let two copies write to the same device at once
        // (concurrent writers were a big part of what wedged the device before).
        let me = Bundle.main.bundleIdentifier ?? "com.gourneau.SidePulse"
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: me)
            .filter { $0 != .current }
        if !others.isEmpty {
            others.first?.activate()
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(device)
                .environmentObject(wake)
        } label: {
            Image(systemName: menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        // Title/id pairs come from the enums above — ContentView and SpecView look
        // these windows up by title.
        Window(SpecWindow.title, id: SpecWindow.id) {
            SpecView()
        }
        .windowResizability(.contentSize)

        Window(ActivityWindow.title, id: ActivityWindow.id) {
            ActivityView().environmentObject(device)
        }
        .windowResizability(.contentSize)
    }

    /// Cup when keeping the Mac awake; otherwise the lightbulb (slash if no device).
    private var menuBarIcon: String {
        if wake.keepAwake || wake.lidClosed { return "cup.and.saucer.fill" }
        return device.devices.isEmpty ? "lightbulb.slash" : "lightbulb.fill"
    }
}
