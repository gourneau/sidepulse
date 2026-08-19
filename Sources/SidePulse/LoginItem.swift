import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` for the "Launch at login" toggle.
/// Only meaningful once the app runs from a real bundle (e.g. /Applications).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the resulting enabled state (unchanged on failure).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Typically fails when run as a loose binary rather than a bundle.
            return isEnabled
        }
        return isEnabled
    }
}
