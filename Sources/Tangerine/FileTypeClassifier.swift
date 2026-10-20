import Foundation

/// The broad bucket a dragged file falls into. Drives which wedges show up
/// and which `ConverterService` implementation handles the conversion.
enum FileCategory {
    case image
    case pdf
    case document
    case video
    case audio

    /// Lowercased file extensions (no dot) that map to this category.
    static let extensionsByCategory: [FileCategory: Set<String>] = [
        .image: ["png", "jpg", "jpeg", "heic", "webp", "tiff", "tif", "bmp", "gif"],
        .pdf: ["pdf"],
        .document: ["docx", "txt", "md", "html", "htm", "rtf"],
        .video: ["mp4", "mov", "mkv", "webm"],
        .audio: ["mp3", "wav", "m4a", "flac", "ogg"],
    ]
}

/// A target format a wedge can convert *to*. Raw value is the lowercase
/// file extension, also used as the wedge label (uppercased) and to decide
/// which `ConverterService` implementation performs the conversion.
enum ConversionFormat: String, CaseIterable, Identifiable {
    case png, jpg, webp, heic, tiff, bmp, gif
    case pdf
    case txt, docx, md, html
    case mp4, mov, webm
    case mp3, wav, m4a, flac, ogg

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }
}

/// Decides a dragged file's category and which conversion wedges to show
/// for it, per the fixed per-category target lists in the spec. The
/// dragged file's own format is always excluded from its own wedge list.
struct FileTypeClassifier {
    static func category(for url: URL) -> FileCategory? {
        let ext = url.pathExtension.lowercased()
        for (category, extensions) in FileCategory.extensionsByCategory {
            if extensions.contains(ext) { return category }
        }
        return nil
    }

    /// The dragged file's own extension, normalized to the `.jpg` /
    /// `.html` spelling we use for wedge labels (e.g. "jpeg" -> .jpg,
    /// "htm" -> .html), so it can be excluded from its own target list.
    private static func normalizedSourceFormat(for url: URL) -> ConversionFormat? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpg
        case "htm", "html": return .html
        case "tif", "tiff": return .tiff
        default: return ConversionFormat(rawValue: url.pathExtension.lowercased())
        }
    }

    private static let targetsByCategory: [FileCategory: [ConversionFormat]] = [
        .image: [.png, .jpg, .webp, .heic, .tiff, .bmp, .pdf],
        .pdf: [.jpg, .png, .txt, .docx],
        .document: [.pdf, .docx, .txt, .md, .html],
        .video: [.mp4, .mov, .webm, .gif, .mp3],
        .audio: [.mp3, .wav, .m4a, .flac, .ogg],
    ]

    /// Target formats for the single dominant category among the dragged
    /// files. For a multi-file drop we classify by the *first* file —
    /// mixed-type multi-drops convert each file against that shared wedge
    /// list, same as the spec's "multi-file drops convert all files".
    static func targetFormats(for urls: [URL]) -> [ConversionFormat] {
        guard let first = urls.first, let category = category(for: first) else { return [] }
        let targets = targetsByCategory[category] ?? []
        let source = normalizedSourceFormat(for: first)
        return targets.filter { $0 != source }
    }
}
