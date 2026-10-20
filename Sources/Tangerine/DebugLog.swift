import Foundation

/// Writes to both fd 2 directly (so running the raw binary from a
/// terminal always shows it immediately, even redirected into a file —
/// NSLog alone doesn't reliably do that off a real tty) and through
/// NSLog/the unified log (so `log show`/Console.app can see it when
/// Tangerine is launched via `open`, where nothing is attached to its
/// stderr at all). Fine to leave in — a couple of syscalls, not a
/// meaningful cost for a menu-bar app that isn't in a hot loop.
func debugLog(_ message: String) {
    FileHandle.standardError.write(Data("Tangerine: \(message)\n".utf8))
    NSLog("Tangerine: %{public}@", message)
}
