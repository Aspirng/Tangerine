import Foundation

/// Handles every video and audio wedge target via `ffmpeg`. ffmpeg infers
/// codecs from the output path's extension for all the formats in our
/// wedge lists, except GIF, which needs an explicit filter (`fps`/`scale`)
/// to avoid producing an enormous full-resolution, full-framerate file.
@MainActor
struct FFmpegConverter: FormatConverter {
    func convert(fileAt source: URL, to format: ConversionFormat) async throws -> [URL] {
        guard let ffmpeg = BinaryLocator.path(for: "ffmpeg") else {
            throw ConverterError.missingBinary(name: "ffmpeg", installCommand: "brew install ffmpeg")
        }

        let output = OutputPathResolver.nextAvailableFile(for: source, extension: format.fileExtension)
        var arguments = ["-i", source.path]

        switch format {
        case .gif:
            arguments += ["-vf", "fps=10,scale=480:-1:flags=lanczos"]
        case .mp3 where FileTypeClassifier.category(for: source) == .video:
            // "extract audio": drop the video stream entirely.
            arguments += ["-vn", "-q:a", "2"]
        default:
            break
        }

        // `-y` (always overwrite) plus a null stdin are defensive: our
        // output path is freshly computed to not exist, but if ffmpeg ever
        // did find an existing file at that path, it prompts on stdin for
        // confirmation — which would hang forever since nothing is
        // attached to answer it.
        arguments += ["-y", output.path]

        try await ProcessRunner.run(ffmpeg, arguments: arguments, standardInput: .nullDevice)
        return [output]
    }
}
