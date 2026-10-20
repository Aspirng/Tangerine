import Foundation

/// Handles every PDF wedge target (JPG, PNG, TXT, DOCX) via poppler's
/// command-line tools: `pdfinfo` (page count), `pdftoppm` (rasterizing to
/// JPG/PNG), and `pdftotext` (TXT, and as the first half of the PDF ->
/// DOCX pipeline — `PandocConverter` does the second half).
@MainActor
struct PopplerConverter: FormatConverter {
    func convert(fileAt source: URL, to format: ConversionFormat) async throws -> [URL] {
        switch format {
        case .jpg, .png:
            return try await rasterize(source: source, format: format)
        case .txt:
            return try await extractText(source: source, destination: OutputPathResolver.nextAvailableFile(for: source, extension: "txt"))
        case .docx:
            return try await extractThenConvertToDocx(source: source)
        default:
            throw ConverterError.unsupportedConversion
        }
    }

    /// Single-page PDFs produce one image file next to the original.
    /// Multi-page PDFs produce a numbered set of images in their own
    /// folder, per spec.
    private func rasterize(source: URL, format: ConversionFormat) async throws -> [URL] {
        guard let pdftoppm = BinaryLocator.path(for: "pdftoppm") else {
            throw ConverterError.missingBinary(name: "pdftoppm", installCommand: "brew install poppler")
        }
        let flag = format == .jpg ? "-jpeg" : "-png"
        let pages = try await pageCount(for: source)

        if pages <= 1 {
            let output = OutputPathResolver.nextAvailableFile(for: source, extension: format.fileExtension)
            let prefix = output.deletingPathExtension().path
            try await ProcessRunner.run(pdftoppm, arguments: [flag, "-singlefile", source.path, prefix])
            return [output]
        }

        let folder = OutputPathResolver.nextAvailableDirectory(for: source, suffix: "pages")
        let prefix = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent).path
        try await ProcessRunner.run(pdftoppm, arguments: [flag, source.path, prefix])

        let produced = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        return produced.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func pageCount(for source: URL) async throws -> Int {
        guard let pdfinfo = BinaryLocator.path(for: "pdfinfo") else {
            throw ConverterError.missingBinary(name: "pdfinfo", installCommand: "brew install poppler")
        }
        let info = try await ProcessRunner.run(pdfinfo, arguments: [source.path])
        for line in info.split(separator: "\n") where line.hasPrefix("Pages:") {
            let digits = line.dropFirst("Pages:".count).trimmingCharacters(in: .whitespaces)
            return Int(digits) ?? 1
        }
        return 1
    }

    @discardableResult
    private func extractText(source: URL, destination: URL) async throws -> [URL] {
        guard let pdftotext = BinaryLocator.path(for: "pdftotext") else {
            throw ConverterError.missingBinary(name: "pdftotext", installCommand: "brew install poppler")
        }
        try await ProcessRunner.run(pdftotext, arguments: [source.path, destination.path])
        return [destination]
    }

    private func extractThenConvertToDocx(source: URL) async throws -> [URL] {
        let tempText = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try await extractText(source: source, destination: tempText)
        defer { try? FileManager.default.removeItem(at: tempText) }

        return try await PandocConverter().convert(inputPath: tempText.path, outputNamedLike: source, to: .docx)
    }
}
