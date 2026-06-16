import SwiftUI
import AppKit

@main
struct SDRGBApp: App {
    @StateObject private var device = DeviceManager()
    @StateObject private var wake = WakeGuard()

    init() {
        // Safe maintenance flag: remove the login item and quit WITHOUT starting
        // the app or touching any device volume. Runs before the DeviceManager
        // (@StateObject) is ever created.
        if CommandLine.arguments.contains("--unregister-login") {
            LoginItem.setEnabled(false)
            exit(0)
        }
        // Single-instance: never let two copies write to the same device at once
        // (concurrent writers were a big part of what wedged the device before).
        let me = Bundle.main.bundleIdentifier ?? "com.gourneau.SDRGB"
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
            Image(systemName: device.devices.isEmpty ? "lightbulb.slash" : "lightbulb.fill")
        }
        .menuBarExtraStyle(.window)

        Window("LEDS.TXT Format", id: "spec") {
            SpecView()
        }
        .windowResizability(.contentSize)
    }
}
