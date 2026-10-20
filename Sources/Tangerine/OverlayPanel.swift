import AppKit
import SwiftUI

/// Borderless, non-activating panel that hosts the radial menu. Key
/// behaviors, each load-bearing for a drag-and-drop overlay that must sit
/// on top of whatever app owns the drag without stealing focus from it:
///
///   - `.nonactivatingPanel` + `canBecomeKey`/`canBecomeMain` = false: never
///     takes keyboard focus or activates Tangerine, so the app the user is
///     dragging *from* (Finder, Mail, …) stays frontmost and the drag
///     session it owns is never interrupted.
///   - `level = .popUpMenu`: renders above (almost) everything while
///     staying in the window-level band the WindowServer still routes live
///     drag-destination hit-testing through. Levels at/above `.screenSaver`
///     looked "on top" visually but never received draggingEntered at all.
///   - `isOpaque = false` / `backgroundColor = .clear`: lets the SwiftUI
///     content's own translucent material show the desktop behind it
///     instead of a square window backdrop.
///   - `collectionBehavior` includes `.canJoinAllSpaces` and
///     `.fullScreenAuxiliary` so the overlay can appear over Spaces/full
///     screen apps the drag might be happening in.
///
/// The panel is positioned once, when the drag session begins, and never
/// moved again — see the note on `DragMonitor` for why continuously
/// re-centering it on the cursor made it impossible to ever complete a
/// drop.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    convenience init(contentView: NSView) {
        self.init(
            contentRect: NSRect(origin: .zero, size: contentView.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        ignoresMouseEvents = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        self.contentView = contentView
    }
}

@MainActor
protocol OverlayDropDelegate: AnyObject {
    func overlayDidReceiveDrop(format: ConversionFormat, fileURLs: [URL])
    /// The live OS drag-and-drop session that was tracking our panel is
    /// over — dropped on a wedge, dropped on the dead center, or cancelled
    /// somewhere else entirely. Always the authoritative signal to hide
    /// the overlay and let `DragMonitor` arm for the next drag.
    func overlaySessionDidEnd()
}

/// The real drag destination *and* the panel's `contentView` — per the
/// fix for the entered/exited thrashing bug, this must be the view AppKit
/// hit-tests to directly, not a subview buried under the SwiftUI content.
/// It owns a `PassthroughHostingView` child purely for rendering
/// `RadialMenuView`; that child always reports "nothing here" to hit
/// testing (see below) so AppKit's drag routing lands on this view, which
/// is the one registered via `registerForDraggedTypes`.
///
/// Hover tracking: SwiftUI's `Path`/`Shape` coordinate system is
/// top-left-origin, y-down — the same convention `RadialMenuView`'s
/// `WedgeShape` angles are computed in. AppKit views default to
/// bottom-left-origin, y-up. `format(at:)` converts an AppKit point into
/// that y-down frame before doing the angle math, so the wedge boundaries
/// computed here line up exactly with what's drawn beneath it. Dropping
/// within `innerRadius` (the center "N files" circle) intentionally
/// resolves to no wedge, so the drop is declined (snaps back) instead of
/// converting to something the user didn't pick.
final class WedgeDispatchView: NSView {
    weak var delegate: WedgeDragDelegate?
    private(set) var formats: [ConversionFormat] = []

    private let hostingView: PassthroughHostingView<RadialMenuView>

    init(size: NSSize) {
        hostingView = PassthroughHostingView(rootView: RadialMenuView(formats: [], fileCount: 0, hoveredFormat: nil))
        super.init(frame: NSRect(origin: .zero, size: size))
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — this view is always created programmatically")
    }

    func update(formats: [ConversionFormat], fileCount: Int, hoveredFormat: ConversionFormat?) {
        self.formats = formats
        hostingView.rootView = RadialMenuView(formats: formats, fileCount: fileCount, hoveredFormat: hoveredFormat)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = updateHover(for: sender)
        debugLog("draggingEntered -> \(String(describing: op.rawValue))")
        return op
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateHover(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        debugLog("draggingExited")
        delegate?.wedgeDidHover(nil)
    }

    override func draggingEnded(_ sender: NSDraggingInfo?) {
        debugLog("draggingEnded")
        delegate?.wedgeDidHover(nil)
        delegate?.wedgeSessionDidEnd()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let hovered = format(at: sender.draggingLocation)
        debugLog("prepareForDragOperation -> \(hovered?.label ?? "none (declined)")")
        return hovered != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let format = format(at: sender.draggingLocation) else {
            debugLog("performDragOperation: no wedge at drop point — declining")
            return false
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty else {
            debugLog("performDragOperation: pasteboard had no file URLs — declining")
            return false
        }
        debugLog("performDragOperation: dropped on \(format.label) with \(urls.count) file(s)")
        delegate?.wedgeDidReceiveDrop(format: format, fileURLs: urls)
        return true
    }

    @discardableResult
    private func updateHover(for sender: NSDraggingInfo) -> NSDragOperation {
        let hovered = format(at: sender.draggingLocation)
        delegate?.wedgeDidHover(hovered)
        return hovered != nil ? .copy : []
    }

    private func format(at windowPoint: NSPoint) -> ConversionFormat? {
        guard !formats.isEmpty else { return nil }
        let point = convert(windowPoint, from: nil)

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let dx = point.x - center.x
        let dyDown = center.y - point.y // flip AppKit's y-up into SwiftUI's y-down convention
        let distance = (dx * dx + dyDown * dyDown).squareRoot()
        guard distance >= RadialMenuView.innerRadius, distance <= RadialMenuView.outerRadius else { return nil }

        let angleStep = 360.0 / Double(formats.count)
        let rawDegrees = atan2(dyDown, dx) * 180 / .pi
        // Undo the "-90 - angleStep/2" offset RadialMenuView applies to each
        // wedge's start angle, so index 0 starts at 0° again.
        var adjusted = rawDegrees + 90 + angleStep / 2
        adjusted = adjusted.truncatingRemainder(dividingBy: 360)
        if adjusted < 0 { adjusted += 360 }

        let index = Int(adjusted / angleStep) % formats.count
        return formats[index]
    }
}

/// An `NSHostingView` that is purely decorative: it always declines hit
/// testing so clicks/drags pass straight through to its superview
/// (`WedgeDispatchView`), which is the view actually registered for
/// dragged types. Without this, the hosting view — being the frontmost
/// subview geometrically on top of the dispatch view — would intercept
/// AppKit's drag-destination routing before it ever reached the view that
/// implements `NSDraggingDestination`.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
protocol WedgeDragDelegate: AnyObject {
    func wedgeDidHover(_ format: ConversionFormat?)
    func wedgeDidReceiveDrop(format: ConversionFormat, fileURLs: [URL])
    func wedgeSessionDidEnd()
}

/// Owns the overlay panel's lifecycle: creating it once per drag session
/// at a fixed position, tracking wedge hover state, and forwarding drops
/// (and session-end) up to `AppDelegate`.
@MainActor
final class OverlayWindowController: WedgeDragDelegate {
    weak var dropDelegate: OverlayDropDelegate?

    private var panel: OverlayPanel?
    private var dispatchView: WedgeDispatchView?

    private var currentFormats: [ConversionFormat] = []
    private var currentFileCount: Int = 0
    private var hoveredFormat: ConversionFormat?

    private let size = NSSize(width: RadialMenuView.diameter, height: RadialMenuView.diameter)

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Forces the panel's SwiftUI content into existence and through one
    /// layout pass ahead of time, while off-screen. Without this, the
    /// *first* real `show()` after launch (or after cold-starting the
    /// hosting view in general) could order the panel on-screen before
    /// SwiftUI's layout pass for a freshly-built `ForEach` over the wedges
    /// had actually completed, which painted a frame with only some of the
    /// wedges — looking like "fewer wedges than expected" for exactly one
    /// attempt. Call once, e.g. at app launch.
    func prewarm() {
        let panel = currentPanel()
        panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000)) // off-screen, never visible
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.orderOut(nil)
    }

    /// Shows the overlay centered at `screenPoint` and leaves it there.
    /// Intentionally takes no further position updates — see
    /// `DragMonitor`'s header comment for why re-centering mid-drag breaks
    /// the OS's drag-destination tracking.
    func show(formats: [ConversionFormat], fileCount: Int, centeredAt screenPoint: NSPoint) {
        currentFormats = formats
        currentFileCount = fileCount
        hoveredFormat = nil

        let dispatchView = currentDispatchView()
        dispatchView.update(formats: formats, fileCount: fileCount, hoveredFormat: nil)

        let panel = currentPanel()
        panel.setFrameOrigin(origin(centeredAt: screenPoint))
        // Belt-and-suspenders alongside prewarm(): make sure this
        // specific wedge count's layout is actually committed before the
        // panel goes visible, not just scheduled for the next run-loop
        // pass.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        hoveredFormat = nil
    }

    // MARK: - WedgeDragDelegate

    func wedgeDidHover(_ format: ConversionFormat?) {
        guard hoveredFormat != format else { return }
        hoveredFormat = format
        dispatchView?.update(formats: currentFormats, fileCount: currentFileCount, hoveredFormat: format)
    }

    func wedgeDidReceiveDrop(format: ConversionFormat, fileURLs: [URL]) {
        dropDelegate?.overlayDidReceiveDrop(format: format, fileURLs: fileURLs)
    }

    func wedgeSessionDidEnd() {
        dropDelegate?.overlaySessionDidEnd()
    }

    // MARK: - Private

    private func currentDispatchView() -> WedgeDispatchView {
        if let dispatchView { return dispatchView }
        let dispatchView = WedgeDispatchView(size: size)
        dispatchView.delegate = self
        self.dispatchView = dispatchView
        return dispatchView
    }

    private func currentPanel() -> OverlayPanel {
        if let panel { return panel }
        let panel = OverlayPanel(contentView: currentDispatchView())
        self.panel = panel
        return panel
    }

    /// Centers the overlay on `screenPoint`, then clamps it to stay fully
    /// within whichever screen the cursor is on. Dragging near a screen
    /// edge (or into a second monitor's edge) would otherwise push part of
    /// the ring off-screen, hiding some wedges entirely rather than just
    /// rendering them where the user can't see or reach them.
    private func origin(centeredAt screenPoint: NSPoint) -> NSPoint {
        var origin = NSPoint(x: screenPoint.x - size.width / 2, y: screenPoint.y - size.height / 2)

        let screen = NSScreen.screens.first { $0.frame.contains(screenPoint) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            origin.x = min(max(origin.x, frame.minX), max(frame.minX, frame.maxX - size.width))
            origin.y = min(max(origin.y, frame.minY), max(frame.minY, frame.maxY - size.height))
        }

        return origin
    }
}
