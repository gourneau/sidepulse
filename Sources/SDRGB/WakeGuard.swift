import SwiftUI
import AppKit
import IOKit.pwr_mgt

/// Keeps the Mac awake while the app runs.
///
/// Two tiers:
/// - **Lid open** — an IOKit power assertion (no permissions). Same technique as
///   `caffeinate` / KeepingYouAwake; cannot stop lid-close sleep on its own.
/// - **Lid closed** — sets the kernel `SleepDisabled` flag via
///   `pmset -a disablesleep`, which needs admin (one macOS password / Touch ID
///   prompt). Reflected from the real flag on launch; reverted on disable/quit;
///   clears on reboot.
@MainActor
final class WakeGuard: ObservableObject {
    /// Lid-open keep-awake (free, in-process power assertion).
    @Published var keepAwake = false {
        didSet { keepAwake ? createAssertion() : releaseAssertion() }
    }
    /// Lid-closed keep-awake (admin `pmset disablesleep`).
    @Published private(set) var lidClosed = false
    /// An admin op is in flight (password dialog up).
    @Published private(set) var lidClosedBusy = false
    /// Last admin error/cancel, shown in the UI (non-fatal).
    @Published private(set) var lidClosedError: String?

    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var hasAssertion = false

    init() {
        // Reflect the real system flag so the toggle is accurate across restarts.
        refreshLidClosedState()
        NotificationCenter.default.addObserver(
            self, selector: #selector(willTerminate),
            name: NSApplication.willTerminateNotification, object: nil)
    }

    // MARK: - Lid-open power assertion

    private func createAssertion() {
        guard !hasAssertion else { return }
        let ok = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "SDRGB keeping the Mac awake" as CFString,
            &assertionID)
        hasAssertion = (ok == kIOReturnSuccess)
    }

    private func releaseAssertion() {
        guard hasAssertion else { return }
        IOPMAssertionRelease(assertionID)
        hasAssertion = false
    }

    // MARK: - Lid-closed (admin pmset disablesleep)

    /// Toggle target for the lid-closed control. Runs the admin op and only flips
    /// the published state to match the actual outcome.
    func setLidClosed(_ enabled: Bool) {
        guard enabled != lidClosed, !lidClosedBusy else { return }
        lidClosedBusy = true
        lidClosedError = nil
        let value = enabled ? "1" : "0"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = WakeGuard.runAdminDisableSleep(value)
            Task { @MainActor in
                self.lidClosedBusy = false
                switch result {
                case .ok:
                    self.lidClosed = enabled
                case .cancelled:
                    self.lidClosedError = "Cancelled — admin permission is required for lid-closed mode."
                case .failed:
                    self.lidClosedError = "Couldn't change the system sleep setting."
                }
            }
        }
    }

    private enum AdminResult { case ok, cancelled, failed }

    /// Run `pmset -a disablesleep <value>` with administrator privileges via
    /// osascript (the standard macOS auth dialog). Blocking — call off-main.
    nonisolated private static func runAdminDisableSleep(_ value: String) -> AdminResult {
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(value)\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let err = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = err
        do { try proc.run() } catch { return .failed }
        proc.waitUntilExit()
        if proc.terminationStatus == 0 { return .ok }
        // osascript returns a User canceled (-128) message when the auth dialog
        // is dismissed.
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.contains("-128") || text.localizedCaseInsensitiveContains("cancel")
            ? .cancelled : .failed
    }

    /// Read the kernel `SleepDisabled` flag (no admin) and reflect it.
    private func refreshLidClosedState() {
        DispatchQueue.global(qos: .utility).async {
            let on = WakeGuard.readSleepDisabled()
            Task { @MainActor in self.lidClosed = on }
        }
    }

    nonisolated private static func readSleepDisabled() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["-g"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").contains {
            $0.contains("SleepDisabled") && $0.contains("1")
        }
    }

    // MARK: - Cleanup

    @objc private func willTerminate() {
        releaseAssertion()
        // Restore normal sleep so quitting the app can't leave a laptop unable to
        // sleep in a bag. Best-effort & synchronous; auth often cached from the
        // recent enable, otherwise this may prompt once.
        if lidClosed { _ = WakeGuard.runAdminDisableSleep("0") }
    }
}
