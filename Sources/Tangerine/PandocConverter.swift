import Foundation

/// Handles document conversions (PDF, DOCX, TXT, MD, HTML) via `pandoc`.
/// Also used by `PopplerConverter` as the second half of its PDF -> DOCX
/// pipeline (pdftotext extracts the text, this turns it into a .docx).
@MainActor
struct PandocConverter: FormatConverter {
    func convert(fileAt source: URL, to format: ConversionFormat) async throws -> [URL] {
        try await convert(inputPath: source.path, outputNamedLike: source, to: format)
    }

    /// Runs pandoc on `inputPath` but names the output after `source`
    /// (rather than after `inputPath`, which may be a throwaway
    /// intermediate file in PopplerConverter's PDF -> DOCX pipeline).
    func convert(inputPath: String, outputNamedLike source: URL, to format: ConversionFormat) async throws -> [URL] {
        guard let pandoc = BinaryLocator.path(for: "pandoc") else {
            throw ConverterError.missingBinary(name: "pandoc", installCommand: "brew install pandoc")
        }

        let output = OutputPathResolver.nextAvailableFile(for: source, extension: format.fileExtension)
        do {
            try await ProcessRunner.run(pandoc, arguments: [inputPath, "-o", output.path])
        } catch ConverterError.processFailed(let binary, let output) where format == .pdf && output.contains("--pdf-engine") {
            // pandoc has no built-in PDF writer — it shells out to a LaTeX
            // engine or wkhtmltopdf, neither of which Homebrew installs by
            // default. Surface that as a missing-binary error so the user
            // gets an actionable install command instead of a raw pandoc
            // error about a flag they never passed.
            _ = binary
            throw ConverterError.missingBinary(name: "a PDF engine", installCommand: "brew install basictex")
        }
        return [output]
    }
}
