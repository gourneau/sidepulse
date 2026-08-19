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

        // Maintenance flags quit WITHOUT starting the app or touching any device
        // volume. They are safe here because `device` and `wake` are @StateObject:
        // the property wrapper takes an @autoclosure, so DeviceManager() — whose
        // init scans volumes and starts the heartbeat — is not constructed until
        // the scene body is first evaluated, which never happens on these paths.
        // Changing either to @ObservedObject or a plain `let` would silently make
        // `brew uninstall` start device I/O.
        if CommandLine.arguments.contains("--unregister-login") {
            LoginItem.setEnabled(false)
            exit(0)
        }
        // Hand back everything macOS records about this app, for an uninstaller.
        //
        // A package manager cannot do this for us: the privileged helper is
        // registered through SMAppService and its plist lives *inside* the app
        // bundle, so there is no /Library/LaunchDaemons file to delete and no
        // supported way to clear the Background Task Management record from
        // outside. Only the bundle that made the registration can retract it —
        // which is why deleting an older build by hand once left a root daemon
        // registered with nothing able to remove it.
        if CommandLine.arguments.contains("--deregister-services") {
            // Restore "Launch at login" on next launch if it was on: Homebrew runs
            // uninstall scripts during `brew upgrade` too, so without this every
            // upgrade would quietly switch the setting off.
            if LoginItem.isEnabled {
                UserDefaults.standard.set(true, forKey: "pendingReregisterLoginItem")
            }
            LoginItem.setEnabled(false)
            WakeGuard.deregisterHelper()
            exit(0)   // always 0: "nothing was registered" is a success, not a failure
        }

        // An upgrade can leave the previous version running out of a bundle that
        // has already been replaced. Yielding to it would strand the user on the
        // old build — and because the old bundle is gone, with no way back.
        let me = Bundle.main.bundleIdentifier ?? "com.gourneau.SidePulse"
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: me)
            .filter { $0 != .current }
        if let other = others.first {
            let stale = other.bundleURL.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
                || other.bundleURL?.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL
            if stale {
                // Take over from a copy running out of a moved or deleted bundle.
                other.terminate()
            } else {
                // A genuine second launch of the same install: never let two copies
                // write to one device (concurrent writers wedge it).
                other.activate()
                exit(0)
            }
        }

        // Put the login item back after an upgrade deregistered it.
        if UserDefaults.standard.bool(forKey: "pendingReregisterLoginItem") {
            UserDefaults.standard.removeObject(forKey: "pendingReregisterLoginItem")
            LoginItem.setEnabled(true)
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
