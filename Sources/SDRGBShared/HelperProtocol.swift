import Foundation

/// Shared identifiers for the app ⇄ privileged-helper XPC channel.
///
/// The only value defined here is the app's bundle identifier; everything else is
/// derived from it, and the required signing Team is read from the helper's own
/// signature at runtime (see `SDRGBHelper`) — so there's no hardcoded Team ID.
/// (Future: inject `appBundleID` from an xcconfig/Info.plist at build time.)
public enum HelperConstants {
    /// The app's bundle identifier (matches Info.plist CFBundleIdentifier).
    public static let appBundleID = "com.gourneau.SDRGB"
    /// Mach service the daemon vends and the app connects to.
    public static let machServiceName = appBundleID + ".helper"
    /// LaunchDaemon label and plist filename (in Contents/Library/LaunchDaemons).
    public static let label = machServiceName
    public static let plistName = machServiceName + ".plist"
}

/// The privileged operations the root helper exposes over XPC. Deliberately
/// tiny: it only toggles the kernel sleep flag.
@objc public protocol HelperProtocol {
    /// Set `pmset -a disablesleep` to on/off. `reply(true)` on success.
    func setDisableSleep(_ on: Bool, reply: @escaping (Bool) -> Void)
    /// Liveness check that also returns the helper's version.
    func version(reply: @escaping (String) -> Void)
}
