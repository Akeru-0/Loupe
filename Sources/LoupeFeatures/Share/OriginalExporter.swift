import Foundation
import ImageIO
import LoupeCore

/// Shares the original bytes. For JPEG/PNG/TIFF it re-muxes losslessly when needed: without GPS for "remove location",
/// and with the photo's orientation override in the orientation tag. Other formats keep the file's own orientation.
public struct OriginalExporter: ShareExporter {
    public let id = "original"
    public let title = "Original"
    public init() {}

    public func canExport(_ kind: VersionKind) -> Bool { true }

    /// Formats whose GPS can be dropped, and orientation tag set, without re-encoding.
    static func canStripLocation(_ file: URL) -> Bool {
        ["jpg", "jpeg", "png", "tif", "tiff"].contains(file.pathExtension.lowercased())
    }

    static func canSetOrientation(_ file: URL) -> Bool { canStripLocation(file) }

    public func export(_ file: URL, kind: VersionKind, orientation: Int?, removeLocation: Bool, into directory: URL) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent(file.lastPathComponent)
        let stripLocation = removeLocation && Self.canStripLocation(file)
        let setOrientation = orientation.flatMap(Orientation.init(exif:)).flatMap { Self.canSetOrientation(file) ? $0 : nil }
        guard stripLocation || setOrientation != nil else {
            try FileManager.default.copyItem(at: file, to: out)
            return out
        }
        // Fail closed: if the location can't be removed, share nothing rather than the original with GPS.
        let failure = stripLocation ? ShareExportError.cannotRemoveLocation(file) : ShareExportError.encodeFailed(file)
        do {
            guard var source = CGImageSourceCreateWithURL(file as CFURL, nil), let type = CGImageSourceGetType(source)
            else { throw failure }
            // ImageIO refuses GPS exclusion and a new orientation in one copy, so those are two lossless passes.
            if stripLocation, setOrientation != nil {
                let stripped = NSMutableData()
                try Self.copy(source, into: CGImageDestinationCreateWithData(stripped, type, 1, nil),
                              [kCGImageMetadataShouldExcludeGPS: true], failure: failure)
                guard let next = CGImageSourceCreateWithData(stripped, nil) else { throw failure }
                source = next
            }
            var options: [CFString: Any] = [:]
            if let setOrientation {
                options[kCGImageDestinationOrientation] = setOrientation.exif
            } else {
                options[kCGImageMetadataShouldExcludeGPS] = true
            }
            try Self.copy(source, into: CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil), options, failure: failure)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return out
    }

    /// `CGImageDestinationCopyImageSource`: the image data is copied as is, only the metadata changes.
    private static func copy(
        _ source: CGImageSource, into dest: CGImageDestination?, _ options: [CFString: Any], failure: ShareExportError
    ) throws {
        guard let dest else { throw failure }
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? failure
        }
    }
}

public enum ShareExportError: Error, LocalizedError {
    case unreadable(URL)
    case encodeFailed(URL)
    case cannotRemoveLocation(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): "Can't read \(url.lastPathComponent)"
        case .encodeFailed(let url): "Can't export \(url.lastPathComponent)"
        case .cannotRemoveLocation(let url): "Can't remove the location from \(url.lastPathComponent)"
        }
    }
}
