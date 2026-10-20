import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, DragMonitorDelegate, OverlayDropDelegate {
    private var statusItem: NSStatusItem!
    private var onboarding: OnboardingWindowController?
    private var isEnabled = true
    private let dragMonitor = DragMonitor()
    private let overlay = OverlayWindowController()
    private let converter = ConverterService()
    private let toast = ToastWindowController()
    private var permissionPollTimer: Timer?
    private var lastDragLocation = NSPoint.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no app switcher entry — this also works when run as
        // a bare SPM binary (not just inside a bundle with LSUIElement set).
        NSApp.setActivationPolicy(.accessory)

        buildStatusItem()
        dragMonitor.delegate = self
        overlay.dropDelegate = self
        overlay.prewarm()
        NotificationManager.shared.configure()

        if PermissionManager.shared.isAccessibilityGranted {
            debugLog("Accessibility granted — starting drag monitor")
            dragMonitor.start()
        } else {
            debugLog("Accessibility NOT granted — showing onboarding")
            showOnboarding()
        }

        // Accessibility can be granted while we're already running (user
        // flips it in System Settings without quitting Tangerine), so poll
        // rather than requiring a relaunch.
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPermission() }
        }
    }

    private func pollPermission() {
        guard isEnabled, !dragMonitor.isActive, PermissionManager.shared.isAccessibilityGranted else { return }
        debugLog("Accessibility granted while running — starting drag monitor")
        dragMonitor.start()
        onboarding?.refresh()
    }

    // MARK: - DragMonitorDelegate

    func dragSessionDidBegin(fileURLs: [URL], screenLocation: NSPoint) {
        lastDragLocation = screenLocation
        let formats = FileTypeClassifier.targetFormats(for: fileURLs)
        let category = fileURLs.first.flatMap(FileTypeClassifier.category(for:))
        debugLog("overlay showing for \(fileURLs.map(\.lastPathComponent)) (category: \(String(describing: category))) -> wedges: \(formats.map(\.label))")
        overlay.show(formats: formats, fileCount: fileURLs.count, centeredAt: screenLocation)
    }

    func dragSessionDidForceEnd() {
        overlay.hide()
    }

    // MARK: - OverlayDropDelegate

    func overlayDidReceiveDrop(format: ConversionFormat, fileURLs: [URL]) {
        debugLog("dropped on wedge \(format.label): \(fileURLs.map(\.lastPathComponent))")
        let dropLocation = lastDragLocation
        toast.showProgress(near: dropLocation)
        Task { @MainActor [converter, toast] in
            let results = await converter.convert(fileURLs: fileURLs, to: format)

            var allOutputs: [URL] = []
            var firstError: (source: URL, error: Error)?
            for result in results {
                switch result.outputs {
                case .success(let outputs):
                    debugLog("converted \(result.source.lastPathComponent) -> \(outputs.map(\.lastPathComponent))")
                    allOutputs += outputs
                    NotificationManager.shared.notifySuccess(outputs: outputs)
                case .failure(let error):
                    debugLog("FAILED converting \(result.source.lastPathComponent): \(error.localizedDescription)")
                    if firstError == nil { firstError = (result.source, error) }
                    NotificationManager.shared.notifyFailure(source: result.source, error: error)
                }
            }

            // One file: show exactly what happened to it. Multiple files:
            // prioritize surfacing a failure (silent partial failure would
            // be worse than a success toast that doesn't mention it) over
            // reporting the successes.
            if let firstError, fileURLs.count == 1 {
                toast.showFailure(near: dropLocation, message: firstError.error.localizedDescription)
            } else if let firstError {
                let message = "\(firstError.source.lastPathComponent): \(firstError.error.localizedDescription)"
                toast.showFailure(near: dropLocation, message: message)
            } else if !allOutputs.isEmpty {
                toast.showSuccess(near: dropLocation, outputs: allOutputs)
            } else {
                toast.hide()
            }
        }
    }

    func overlaySessionDidEnd() {
        overlay.hide()
        dragMonitor.sessionEnded()
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "Tangerine")
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = isEnabled ? .on : .off
        menu.addItem(enabledItem)

        menu.addItem(.separator())

        let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        let onboardingItem = NSMenuItem(title: "Setup & Permissions…", action: #selector(openOnboarding), keyEquivalent: "")
        onboardingItem.target = self
        menu.addItem(onboardingItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Tangerine", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        isEnabled.toggle()
        sender.state = isEnabled ? .on : .off
        if isEnabled {
            if PermissionManager.shared.isAccessibilityGranted {
                dragMonitor.start()
            }
        } else {
            dragMonitor.stop()
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        LaunchAtLogin.isEnabled.toggle()
        sender.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    @objc private func openOnboarding() {
        showOnboarding()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindowController()
        }
        onboarding?.show()
    }
}

/// Thin wrapper around SMAppService so AppDelegate doesn't need to know
/// about the registration dance (and the fact it throws).
enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                debugLog("failed to update Launch at Login: \(error)")
            }
        }
    }
}
