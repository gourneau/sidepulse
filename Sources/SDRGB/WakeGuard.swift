import SwiftUI
import AppKit
import IOKit.pwr_mgt
import ServiceManagement
import SDRGBShared

/// Keeps the Mac awake while the app runs.
///
/// - **Lid open** — an IOKit power assertion (no permissions). Same technique as
///   `caffeinate`; cannot stop lid-close sleep on its own.
/// - **Lid closed** — sets the kernel `SleepDisabled` flag via `pmset -a
///   disablesleep`. A signed/installed build runs this through a **privileged
///   SMAppService helper over XPC** (approve once in System Settings, then
///   passwordless forever). Unsigned dev builds fall back to a one-time
///   passwordless `sudo` rule.
@MainActor
final class WakeGuard: ObservableObject {
    @Published var keepAwake = false {
        didSet { keepAwake ? createAssertion() : releaseAssertion() }
    }
    @Published private(set) var lidClosed = false
    @Published private(set) var lidClosedBusy = false
    @Published private(set) var lidClosedError: String?

    private var assertionID = IOPMAssertionID(0)
    private var hasAssertion = false
    nonisolated private static let sudoersPath = "/etc/sudoers.d/sdrgb-disablesleep"

    private let helperService = SMAppService.daemon(plistName: HelperConstants.plistName)
    private var connection: NSXPCConnection?

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

    // MARK: - Lid-closed

    func setLidClosed(_ enabled: Bool) {
        guard enabled != lidClosed, !lidClosedBusy else { return }
        lidClosedBusy = true
        lidClosedError = nil

        switch ensureHelperRegistered() {
        case .enabled:
            callHelper(enabled)                 // passwordless via XPC
        case .requiresApproval:
            lidClosedBusy = false
            lidClosedError = "Approve “SDRGB” in System Settings → Login Items, then toggle again."
            SMAppService.openSystemSettingsLoginItems()
        default:
            sudoFallback(enabled)               // unsigned/dev build
        }
    }

    /// Register the privileged helper if needed; returns its status.
    private func ensureHelperRegistered() -> SMAppService.Status {
        if helperService.status == .enabled { return .enabled }
        try? helperService.register()
        return helperService.status
    }

    private func helperProxy(_ onError: @escaping () -> Void) -> HelperProtocol? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            c.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { _ in onError() } as? HelperProtocol
    }

    private func callHelper(_ enabled: Bool) {
        let proxy = helperProxy { [weak self] in
            Task { @MainActor in
                self?.lidClosedBusy = false
                self?.lidClosedError = "Couldn't reach the privileged helper."
            }
        }
        guard let proxy else {
            lidClosedBusy = false
            lidClosedError = "Couldn't reach the privileged helper."
            return
        }
        proxy.setDisableSleep(enabled) { ok in
            let actual = WakeGuard.readSleepDisabled()   // off the main thread (XPC reply queue)
            Task { @MainActor in
                self.lidClosedBusy = false
                self.lidClosed = actual
                if !ok { self.lidClosedError = "Couldn't change the system sleep setting." }
            }
        }
    }

    // MARK: - Sudo fallback (unsigned dev builds only)

    private func sudoFallback(_ enabled: Bool) {
        let value = enabled ? "1" : "0"
        DispatchQueue.global(qos: .userInitiated).async {
            var message: String?
            var ok = (WakeGuard.runSudo(value) == .ok)
            if !ok {
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

    // MARK: - State

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
        // Lid-closed (SleepDisabled) is a deliberate system-level choice: it
        // persists until toggled off or reboot, and is reflected on next launch.
    }
}
