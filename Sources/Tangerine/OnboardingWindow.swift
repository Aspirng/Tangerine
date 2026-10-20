import AppKit
import SwiftUI

/// Explains why Tangerine needs Accessibility access and lets the user jump
/// straight to the System Settings pane. Shown automatically on first
/// launch (and from the menu bar item any time after) until permission is
/// granted.
struct OnboardingView: View {
    var isGranted: Bool
    var onOpenSettings: () -> Void
    var onRequestPrompt: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text("Welcome to Tangerine")
                    .font(.title2)
                    .bold()
            }

            Text("Tangerine shows a radial conversion menu when you drag a file while holding Shift. To detect that drag anywhere on the system, macOS requires Accessibility access.")
                .fixedSize(horizontal: false, vertical: true)

            Text("Tangerine never uploads your files anywhere — all conversions run locally using command-line tools already on your Mac.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Circle()
                    .fill(isGranted ? .green : .red)
                    .frame(width: 10, height: 10)
                Text(isGranted ? "Accessibility access granted" : "Accessibility access not granted")
                    .font(.callout)
            }

            HStack {
                Button("Quit Tangerine", role: .destructive, action: onQuit)
                Spacer()
                if !isGranted {
                    Button("Open System Settings", action: onOpenSettings)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { onRequestPrompt() }
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tangerine Setup"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        refresh()
    }

    /// Rebuilds the hosted SwiftUI view so the granted/not-granted dot
    /// reflects the latest permission state whenever the window is shown.
    func refresh() {
        let granted = PermissionManager.shared.isAccessibilityGranted
        let view = OnboardingView(
            isGranted: granted,
            onOpenSettings: { PermissionManager.shared.openAccessibilitySettings() },
            onRequestPrompt: { PermissionManager.shared.requestAccessibilityPermission() },
            onQuit: { NSApp.terminate(nil) }
        )
        window?.contentView = NSHostingView(rootView: view)
    }

    func show() {
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
