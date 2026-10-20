// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tangerine",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // swift-tools-version 5.9 manifests default targets to Swift
        // language mode 5 (no Swift 6 strict-concurrency checking), which
        // is what we want for @MainActor-based AppKit/SwiftUI code.
        .executableTarget(
            name: "Tangerine",
            path: "Sources/Tangerine"
        )
    ]
)
