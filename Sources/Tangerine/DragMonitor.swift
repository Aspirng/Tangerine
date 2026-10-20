import AppKit

/// Watches for "drag a file while holding Shift" anywhere on the system,
/// and reports it exactly once per drag so the overlay can be shown at a
/// fixed spot.
///
/// There is no public API that hands us "a drag started" directly for
/// drags owned by *other* applications (Finder, Mail, Safari, …). Instead
/// we infer it from two global signals combined:
///
///   1. `NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged)` —
///      fires repeatedly while any app's left mouse button is held and
///      moved. This alone doesn't tell us a *drag session* (as opposed to
///      a plain mouse drag, e.g. a text selection) is in progress.
///   2. `NSPasteboard(name: .drag)` — the special pasteboard the system
///      populates for the duration of an active drag-and-drop session, no
///      matter which app initiated it. When a drag session is active and
///      its contents are file URLs, reading it for `NSURL` succeeds; when
///      there's no active drag, it returns nothing. Polling this on every
///      dragged-mouse event is how we distinguish "dragging a file" from
///      "just moving the mouse with the button down".
///
/// Important: once a session has begun, we deliberately stop reacting to
/// further `.leftMouseDragged` events (`state` guards against it). Earlier
/// versions re-centered the overlay panel on every mouse-moved sample,
/// which fought with the *actual* OS drag-destination tracking on the
/// panel itself: by the time the WindowServer re-evaluated "which window
/// is under the cursor" for the live drag session, our panel had already
/// moved again, so it registered draggingEntered immediately followed by
/// draggingExited in a tight loop and the drop could never land. The panel
/// is now positioned once, stays put, and `OverlayPanel`'s own
/// `NSDraggingDestination` callbacks (routed through `AppDelegate`) are
/// what ends the session — see `sessionEnded()`.
///
/// Both global monitors require Accessibility permission to receive events
/// from *other* processes (PermissionManager handles requesting that).
@MainActor
protocol DragMonitorDelegate: AnyObject {
    func dragSessionDidBegin(fileURLs: [URL], screenLocation: NSPoint)
    /// Backstop only: fired when a `.leftMouseUp` is observed while a
    /// session is active but the overlay's own `draggingEnded` never told
    /// us the session was over (e.g. the drag never actually reached the
    /// panel). Normally `OverlayPanel`'s drag-destination callbacks beat
    /// this to it.
    func dragSessionDidForceEnd()
}

@MainActor
final class DragMonitor {
    weak var delegate: DragMonitorDelegate?

    private var mouseMonitor: Any?
    private var isSessionActive = false

    var isActive: Bool { mouseMonitor != nil }

    func start() {
        guard mouseMonitor == nil else { return }

        // .leftMouseUp is a backstop: during a live OS drag-and-drop
        // session the system generally does NOT deliver ordinary
        // leftMouseUp events to global monitors (the drag manager consumes
        // them), so this mostly matters for the case where our overlay's
        // own draggingEnded never fires because the drag never actually
        // entered our panel (e.g. the user dropped far away from it).
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event: event)
        }
    }

    func stop() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        isSessionActive = false
    }

    /// Called by `AppDelegate` once the overlay panel's own
    /// `NSDraggingDestination` lifecycle (or the `.leftMouseUp` backstop
    /// above) has concluded, so the next Shift-drag is detected fresh.
    func sessionEnded() {
        isSessionActive = false
    }

    private func handle(event: NSEvent) {
        if event.type == .leftMouseUp {
            if isSessionActive {
                isSessionActive = false
                delegate?.dragSessionDidForceEnd()
            }
            return
        }

        guard !isSessionActive else { return }

        guard event.modifierFlags.contains(.shift) else { return }
        guard let fileURLs = Self.fileURLsFromActiveDragPasteboard(), !fileURLs.isEmpty else { return }

        isSessionActive = true
        delegate?.dragSessionDidBegin(fileURLs: fileURLs, screenLocation: NSEvent.mouseLocation)
    }

    /// Reads the system drag pasteboard. Returns nil/empty when no drag
    /// session with file URLs is currently active.
    private static func fileURLsFromActiveDragPasteboard() -> [URL]? {
        let pasteboard = NSPasteboard(name: .drag)
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return nil
        }
        return urls
    }
}
