# Tangerine

A macOS menu-bar utility: hold **Shift** while dragging a file anywhere on
the system and a radial menu appears under your cursor. Drop the file on a
wedge to convert it — entirely locally, no uploads. The result is saved
next to the original file.

Built with Swift (AppKit + SwiftUI), no Xcode project — just a Swift
Package.

## Requirements

- macOS 13+
- Xcode command line tools (for `swift build`)
- Conversion engines, via Homebrew:

  ```bash
  brew install imagemagick poppler pandoc ffmpeg
  ```

- Optional, for converting documents **to PDF** (DOCX/TXT/MD/HTML → PDF):

  ```bash
  brew install --cask basictex
  ```

  Without this, every other conversion still works — PDF output specifically
  shows a clear error telling you to install it.

## Build & run

```bash
# Build and package into Tangerine.app (debug, fast iteration)
./Scripts/build_app.sh

# Release build (optimized)
./Scripts/build_app.sh release

# Run it
open Tangerine.app
```

Launching with `open` (rather than running the binary directly) matters —
it's what gives Tangerine proper LaunchServices registration, which its
Accessibility permission grant depends on.

The first launch shows a setup window explaining why Accessibility access
is needed (to detect drags happening in *other* apps) and lets you jump
straight to System Settings to grant it.

### Why the build script creates a certificate

`Scripts/build_app.sh` signs the app with a stable local certificate
("Tangerine Local Dev") that it generates once and reuses on every build.
This matters because Accessibility permission is tied to the app's code
signature — ad-hoc signing (`codesign -s -`) hashes the binary itself, so
every rebuild would look like a brand new app to macOS and silently lose
the permission grant. If Xcode has a real "Apple Development" identity
installed, the script uses that instead.

## Using it

1. Click the menu bar icon (hexagon grid) to confirm Tangerine is enabled.
2. Hold **Shift** and drag a file from Finder (or anywhere) — a radial
   menu appears, centered on your cursor, with wedges for the formats you
   can convert to (based on the file's type).
3. Drop the file on a wedge. A small toast shows progress, then either a
   success message with a **Reveal in Finder** action, or a clear error if
   something went wrong (e.g. a missing converter binary, with the exact
   `brew install` command to fix it).
4. Multi-file drags convert every file; a multi-page PDF rasterized to
   images produces a numbered set in its own folder instead of one file.

Other menu bar options: toggle Tangerine on/off, enable Launch at Login,
reopen the setup window, or quit.

## Project layout

```
Sources/Tangerine/
  main.swift              Entry point
  AppDelegate.swift        Menu bar item, app lifecycle, wiring
  PermissionManager.swift  Accessibility permission checks
  OnboardingWindow.swift   First-run setup window
  DragMonitor.swift        Global Shift+drag detection
  OverlayPanel.swift       The radial menu's window + drag-destination logic
  RadialMenuView.swift     The radial menu's SwiftUI visuals
  FileTypeClassifier.swift Maps a file's type to its target formats
  ConverterService.swift   Dispatches conversions, process-running helpers
  ImageMagickConverter.swift / PopplerConverter.swift /
  PandocConverter.swift / FFmpegConverter.swift
                            One implementation per command-line tool
  Notifications.swift      Progress/success/error toast UI
  DebugLog.swift            Logging helper
Scripts/build_app.sh       Builds and packages Tangerine.app
Resources/Info.plist        App bundle metadata (LSUIElement, etc.)
```
