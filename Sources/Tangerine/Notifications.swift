import AppKit
import SwiftUI

/// Best-effort native notifications via the deprecated
/// `NSUserNotificationCenter` API. On current macOS, *both* the modern
/// `UNUserNotificationCenter` and this legacy API refuse to actually
/// register/deliver banners for an app that isn't signed with a real Apple
/// Developer ID team (ours is a local self-signed certificate — see
/// `Scripts/build_app.sh` — which is enough for a stable TCC identity but
/// not for notification authorization). This is kept around because it
/// becomes a working bonus the moment Tangerine is ever signed with a real
/// Developer ID; it's deliberately NOT the primary feedback mechanism —
/// that's `ToastWindowController` below, which is Tangerine's own UI and
/// doesn't depend on any system permission.
@MainActor
final class NotificationManager: NSObject, NSUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private let pathsKey = "paths"

    func configure() {
        NSUserNotificationCenter.default.delegate = self
    }

    func notifySuccess(outputs: [URL]) {
        let note = NSUserNotification()
        if outputs.count == 1, let first = outputs.first {
            note.title = "Converted"
            note.informativeText = first.lastPathComponent
        } else {
            note.title = "Converted \(outputs.count) files"
            note.informativeText = outputs.map(\.lastPathComponent).joined(separator: ", ")
        }
        note.hasActionButton = true
        note.actionButtonTitle = "Reveal in Finder"
        note.userInfo = [pathsKey: outputs.map(\.path)]
        NSUserNotificationCenter.default.deliver(note)
    }

    func notifyFailure(source: URL, error: Error) {
        let note = NSUserNotification()
        note.title = "Couldn't convert \(source.lastPathComponent)"
        note.informativeText = error.localizedDescription
        NSUserNotificationCenter.default.deliver(note)
    }

    // MARK: - NSUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool {
        true // present even while Tangerine is the frontmost app
    }

    nonisolated func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        guard let paths = notification.userInfo?["paths"] as? [String], !paths.isEmpty else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        Task { @MainActor in
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }
}

private enum ToastState {
    case progress
    case success(outputs: [URL])
    case failure(message: String)
}

/// The actual feedback UI: a small panel near the drop point that shows a
/// spinner while converting, then either a checkmark with a clickable
/// "Reveal in Finder" row, or an error message. This is Tangerine's own
/// window, not a system notification, so it always works regardless of
/// code-signing/notification-authorization status.
private struct ToastContentView: View {
    let state: ToastState
    let onPrimaryAction: () -> Void

    var body: some View {
        switch state {
        case .progress:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Converting…")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())

        case .success(let outputs):
            Button(action: onPrimaryAction) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(outputs.count == 1 ? "Converted" : "Converted \(outputs.count) files")
                            .font(.system(size: 12, weight: .semibold))
                        Text(outputs.map(\.lastPathComponent).joined(separator: ", "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Reveal in Finder")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tint)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .frame(width: 260)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

        case .failure(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 16))
                Text(message)
                    .font(.system(size: 12))
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(width: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

@MainActor
final class ToastWindowController {
    private var panel: NSPanel?
    private var autoDismissTimer: Timer?

    func showProgress(near screenPoint: NSPoint) {
        present(width: 160, interactive: false, autoDismissAfter: nil, near: screenPoint) {
            ToastContentView(state: .progress, onPrimaryAction: {})
        }
    }

    func showSuccess(near screenPoint: NSPoint, outputs: [URL]) {
        present(width: 260, interactive: true, autoDismissAfter: 5, near: screenPoint) { [weak self] in
            ToastContentView(state: .success(outputs: outputs), onPrimaryAction: {
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
                self?.hide()
            })
        }
    }

    func showFailure(near screenPoint: NSPoint, message: String) {
        present(width: 300, interactive: true, autoDismissAfter: 7, near: screenPoint) {
            ToastContentView(state: .failure(message: message), onPrimaryAction: {})
        }
    }

    func hide() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func present(
        width: CGFloat,
        interactive: Bool,
        autoDismissAfter seconds: TimeInterval?,
        near screenPoint: NSPoint,
        @ViewBuilder content: () -> ToastContentView
    ) {
        hide() // only one toast at a time; a new one replaces whatever's showing

        let hostingView = NSHostingView(rootView: content())
        // Give it a starting frame, force one layout pass, then read back
        // SwiftUI's actual fitting size — same trick as the radial menu's
        // prewarm — so the panel is sized to its real content instead of
        // a guessed constant, without ever flashing a wrong-sized frame.
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        hostingView.layoutSubtreeIfNeeded()
        let fitSize = hostingView.fittingSize
        let size = NSSize(width: width, height: max(fitSize.height, 32))
        hostingView.setFrameSize(size)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = !interactive
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hostingView
        panel.setFrameOrigin(NSPoint(x: screenPoint.x - size.width / 2, y: screenPoint.y - size.height - 24))
        panel.orderFrontRegardless()
        self.panel = panel

        if let seconds {
            autoDismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.hide() }
            }
        }
    }
}
