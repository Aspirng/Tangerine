import AppKit

// Entry point. We build an NSApplication by hand (rather than an `App` /
// `@main` SwiftUI lifecycle) because Tangerine is a background utility: no
// windows at launch, no Dock icon, and full control over NSStatusItem /
// NSPanel which the SwiftUI App lifecycle makes awkward to own directly.
// Top-level code in main.swift isn't implicitly @MainActor, but it does run
// on the main thread before anything else starts, so this is safe.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.run()
}
