import Foundation
import Security
import SDRGBShared

let helperVersion = "1.0"

/// Root LaunchDaemon: accepts XPC connections only from our signed app and runs
/// `pmset -a disablesleep` on request. Installed/managed via SMAppService.
final class HelperDelegate: NSObject, NSXPCListenerDelegate, HelperProtocol {

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard HelperDelegate.isValidClient(connection) else { return false }
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    // MARK: HelperProtocol

    func setDisableSleep(_ on: Bool, reply: @escaping (Bool) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-a", "disablesleep", on ? "1" : "0"]
        do {
            try p.run()
            p.waitUntilExit()
            reply(p.terminationStatus == 0)
        } catch {
            reply(false)
        }
    }

    func repair(reply: @escaping (String) -> Void) {
        // Root, so no sudo needed. Kill the hung FAT driver first (that's what's
        // wedged), then force-unmount and remount our volumes.
        var log = "pkill fskit.msdos:\n" + run("/usr/bin/pkill", ["-9", "-f", "com.apple.fskit.msdos"])
        Thread.sleep(forTimeInterval: 1)
        for v in ["SDRGB", "USBDOT"] {
            log += "\nunmount \(v):\n" + run("/usr/sbin/diskutil", ["unmount", "force", "/Volumes/\(v)"])
        }
        Thread.sleep(forTimeInterval: 1)
        for v in ["SDRGB", "USBDOT"] {
            log += "\nmount \(v):\n" + run("/usr/sbin/diskutil", ["mount", v])
        }
        reply(log)
    }

    private func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "(failed to launch \(path))" }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    func version(reply: @escaping (String) -> Void) { reply(helperVersion) }

    // MARK: Client validation

    /// Only accept connections from our app, signed by the same Team that signed
    /// this helper (Team read from our own signature — not hardcoded).
    static func isValidClient(_ connection: NSXPCConnection) -> Bool {
        guard let requirementText = clientRequirement() else { return false }
        let pid = connection.processIdentifier
        let attrs = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, SecCSFlags(), &code) == errSecSuccess,
              let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString,
                                             SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }

    /// Require: Apple-issued cert chain, our app's identifier, and the same Team
    /// that signed this helper. Returns nil if we can't read our own Team (e.g.
    /// unsigned dev build) — in which case no client is accepted.
    private static func clientRequirement() -> String? {
        guard let team = ownTeamID() else { return nil }
        return "anchor apple generic and identifier \"\(HelperConstants.appBundleID)\" "
            + "and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// The Team Identifier from this helper's own code signature.
    private static func ownTeamID() -> String? {
        var codeRef: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &codeRef) == errSecSuccess, let codeRef else { return nil }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(codeRef, SecCSFlags(), &staticRef) == errSecSuccess,
              let staticRef else { return nil }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(
                staticRef, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
