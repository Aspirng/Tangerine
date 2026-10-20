import AppKit
import ApplicationServices

/// Wraps the Accessibility (AX) trust check we need in order to run a
/// global event monitor that sees drag/modifier events from *other* apps.
/// macOS ties this to the app's bundle identity + code signature, so it
/// behaves most reliably once Tangerine is packaged as a proper .app and
/// codesigned (see Scripts/build_app.sh) — running the raw SPM binary works
/// too, but Terminal/the raw binary will be the thing listed in
/// System Settings > Privacy & Security > Accessibility instead of "Tangerine".
@MainActor
final class PermissionManager {
    static let shared = PermissionManager()

    private init() {}

    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system's own "Tangerine would like to control this
    /// computer" prompt the *first* time it's called for this bundle id.
    /// Subsequent calls are a no-op from the OS's perspective, so it's safe
    /// to call this speculatively on every launch.
    func requestAccessibilityPermission() {
        let options: [String: Any] = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
