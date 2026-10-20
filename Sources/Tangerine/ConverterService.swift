import Foundation

enum ConverterError: LocalizedError {
    case missingBinary(name: String, installCommand: String)
    case processFailed(binary: String, output: String)
    case unsupportedConversion

    var errorDescription: String? {
        switch self {
        case .missingBinary(let name, let installCommand):
            return "\(name) isn't installed. Run `\(installCommand)` in Terminal, then try again."
        case .processFailed(let binary, let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "\(binary) failed." : "\(binary) failed: \(trimmed)"
        case .unsupportedConversion:
            return "Tangerine doesn't support that conversion."
        }
    }
}

/// One implementation per command-line tool. Each converter owns the
/// argument-building for its tool and returns the file(s) it produced.
@MainActor
protocol FormatConverter {
    func convert(fileAt source: URL, to format: ConversionFormat) async throws -> [URL]
}

/// Finds a command-line tool's absolute path. Homebrew installs land in
/// different prefixes depending on the Mac (Apple silicon vs Intel), and a
/// GUI app launched from Finder/the menu bar doesn't inherit the shell's
/// PATH the way a Terminal-launched process does — so we check Homebrew's
/// two conventional prefixes directly rather than relying on `Process`
/// resolving a bare command name against the environment's PATH.
struct BinaryLocator {
    static func path(for binaryName: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(binaryName)",
            "/usr/local/bin/\(binaryName)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Runs a command-line tool and returns its stdout, or throws with its
/// stderr on a non-zero exit. `Process`'s `terminationHandler` fires on a
/// Foundation-managed background thread (not the main thread, satisfying
/// "run conversions async off the main thread"), and none of
/// `FormatConverter`'s methods are `@MainActor`-isolated themselves, so
/// awaiting this never blocks the UI.
struct ProcessRunner {
    @discardableResult
    static func run(_ executablePath: String, arguments: [String], standardInput: FileHandle? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            // A GUI app launched via LaunchServices (as opposed to a shell)
            // inherits a minimal PATH that's missing Homebrew *and* things
            // like TeX's bin directory. That's invisible for tools we
            // locate by absolute path (magick, ffmpeg, …), but pandoc
            // shells out to a PDF engine (pdflatex) by searching ITS OWN
            // inherited PATH, so without this, PDF output silently fails
            // to find an engine that's actually installed.
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/Library/TeX/texbin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment
            if let standardInput {
                process.standardInput = standardInput
            }

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { finished in
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: String(data: outData, encoding: .utf8) ?? "")
                } else {
                    let binaryName = (executablePath as NSString).lastPathComponent
                    let errorText = String(data: errData, encoding: .utf8) ?? ""
                    continuation.resume(throwing: ConverterError.processFailed(binary: binaryName, output: errorText))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Computes non-colliding output paths next to the original file —
/// `photo.png` -> `photo.jpg`, or `photo 2.jpg` if that already exists.
struct OutputPathResolver {
    static func nextAvailableFile(for source: URL, extension newExtension: String) -> URL {
        let directory = source.deletingLastPathComponent()
        let baseName = source.deletingPathExtension().lastPathComponent
        return nextAvailable(directory: directory, baseName: baseName, extension: newExtension)
    }

    /// For outputs that land in their own folder (multi-page PDF -> images),
    /// e.g. `report.pdf` -> `report pages/`, or `report pages 2/` if taken.
    static func nextAvailableDirectory(for source: URL, suffix: String) -> URL {
        let directory = source.deletingLastPathComponent()
        let baseName = source.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent("\(baseName) \(suffix)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(suffix) \(counter)")
            counter += 1
        }
        try? FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    private static func nextAvailable(directory: URL, baseName: String, extension newExtension: String) -> URL {
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(newExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(counter)").appendingPathExtension(newExtension)
            counter += 1
        }
        return candidate
    }
}

/// Routes a conversion request to the right tool based on the source
/// file's category, and runs every requested file concurrently.
@MainActor
final class ConverterService {
    private let imageMagick = ImageMagickConverter()
    private let poppler = PopplerConverter()
    private let pandoc = PandocConverter()
    private let ffmpeg = FFmpegConverter()

    struct FileResult {
        let source: URL
        let outputs: Result<[URL], Error>
    }

    func convert(fileURLs: [URL], to format: ConversionFormat) async -> [FileResult] {
        await withTaskGroup(of: FileResult.self) { group in
            for source in fileURLs {
                group.addTask { @MainActor in
                    do {
                        let outputs = try await self.convertOne(source: source, to: format)
                        return FileResult(source: source, outputs: .success(outputs))
                    } catch {
                        return FileResult(source: source, outputs: .failure(error))
                    }
                }
            }
            var results: [FileResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    private func convertOne(source: URL, to format: ConversionFormat) async throws -> [URL] {
        guard let category = FileTypeClassifier.category(for: source) else {
            throw ConverterError.unsupportedConversion
        }
        let converter: FormatConverter
        switch category {
        case .image:
            converter = imageMagick
        case .pdf:
            converter = poppler
        case .document:
            converter = pandoc
        case .video, .audio:
            converter = ffmpeg
        }
        return try await converter.convert(fileAt: source, to: format)
    }
}
