import SwiftUI
import AppKit
import IOKit.pwr_mgt

/// Keeps the Mac awake while the app runs.
///
/// Two tiers:
/// - **Lid open** — an IOKit power assertion (no permissions). Same technique as
///   `caffeinate` / KeepingYouAwake; cannot stop lid-close sleep on its own.
/// - **Lid closed** — sets the kernel `SleepDisabled` flag via
///   `pmset -a disablesleep`. The first time, it installs a narrowly-scoped
///   passwordless `sudo` rule (one admin prompt) limited to exactly
///   `pmset -a disablesleep 0|1`; after that every toggle is instant — forever,
///   across reboots — with no further prompts.
///
/// NOTE: the sudo-rule approach is great for local/personal use. For a *shipped*
/// app, replace `installRule`/`runSudo` with an SMAppService privileged helper +
/// XPC (see README "Shipping"). The `setLidClosed` seam stays the same.
@MainActor
final class WakeGuard: ObservableObject {
    /// Lid-open keep-awake (free, in-process power assertion).
    @Published var keepAwake = false {
        didSet { keepAwake ? createAssertion() : releaseAssertion() }
    }
    /// Lid-closed keep-awake (`pmset disablesleep`, passwordless after first setup).
    @Published private(set) var lidClosed = false
    @Published private(set) var lidClosedBusy = false
    @Published private(set) var lidClosedError: String?

    private var assertionID = IOPMAssertionID(0)
    private var hasAssertion = false
    nonisolated private static let sudoersPath = "/etc/sudoers.d/sdrgb-disablesleep"

    init() {
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

    // MARK: - Lid-closed (passwordless pmset disablesleep)

    func setLidClosed(_ enabled: Bool) {
        guard enabled != lidClosed, !lidClosedBusy else { return }
        lidClosedBusy = true
        lidClosedError = nil
        let value = enabled ? "1" : "0"
        DispatchQueue.global(qos: .userInitiated).async {
            var message: String?
            var ok = (WakeGuard.runSudo(value) == .ok)
            if !ok {
                // First run: install the one-time passwordless rule, then retry.
                switch WakeGuard.installRule() {
                case .ok:
                    ok = (WakeGuard.runSudo(value) == .ok)
                    if !ok { message = "Couldn't change the system sleep setting." }
                case .cancelled:
                    message = "Cancelled — admin permission is needed once to set this up."
                case .failed:
                    message = "Couldn't set up passwordless control."
                }
            }
            let actual = WakeGuard.readSleepDisabled()
            Task { @MainActor in
                self.lidClosedBusy = false
                self.lidClosed = actual
                self.lidClosedError = message
            }
        }
    }

    private enum SudoResult { case ok, needsSetup, failed }
    private enum InstallResult { case ok, cancelled, failed }

    /// `sudo -n pmset -a disablesleep <value>` — no prompt once the rule exists.
    nonisolated private static func runSudo(_ value: String) -> SudoResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", value]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return .failed }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? .ok : .needsSetup
    }

    /// One-time: install a passwordless sudoers rule scoped to exactly
    /// `pmset -a disablesleep 0|1` for the current user. One admin prompt.
    nonisolated private static func installRule() -> InstallResult {
        let user = NSUserName()
        guard !user.isEmpty,
              user.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else {
            return .failed
        }
        let setup = """
        #!/bin/sh
        set -e
        f=\(sudoersPath)
        printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\\n' "$1" > "$f"
        chown root:wheel "$f"
        chmod 0440 "$f"
        /usr/sbin/visudo -cf "$f" >/dev/null 2>&1 || { rm -f "$f"; exit 1; }
        """
        let tmp = NSTemporaryDirectory() + "sdrgb-setup-\(UUID().uuidString).sh"
        guard (try? setup.write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else {
            return .failed
        }
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // The standard macOS admin auth dialog (one time).
        let osa = "do shell script \"/bin/sh '\(tmp)' '\(user)'\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", osa]
        p.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        p.standardError = errPipe
        do { try p.run() } catch { return .failed }
        p.waitUntilExit()
        if p.terminationStatus == 0 { return .ok }
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (err.contains("-128") || err.localizedCaseInsensitiveContains("cancel"))
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
        // Restore normal sleep so quitting can't leave a laptop unable to sleep in
        // a bag. Passwordless once the rule is installed.
        if lidClosed { _ = WakeGuard.runSudo("0") }
    }
}
