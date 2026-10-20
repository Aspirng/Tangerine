import Foundation

/// Handles every image wedge target (PNG, JPG, WEBP, HEIC, TIFF, BMP) plus
/// image -> PDF, by shelling out to ImageMagick's `magick` tool. A single
/// `magick input output` invocation is enough — ImageMagick infers both
/// formats from each path's extension, including writing a one-page PDF
/// directly from a raster image with no extra delegate required.
@MainActor
struct ImageMagickConverter: FormatConverter {
    func convert(fileAt source: URL, to format: ConversionFormat) async throws -> [URL] {
        guard let magick = BinaryLocator.path(for: "magick") else {
            throw ConverterError.missingBinary(name: "magick", installCommand: "brew install imagemagick")
        }

        let output = OutputPathResolver.nextAvailableFile(for: source, extension: format.fileExtension)
        try await ProcessRunner.run(magick, arguments: [source.path, output.path])
        return [output]
    }
}
