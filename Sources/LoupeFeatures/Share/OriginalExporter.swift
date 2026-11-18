import Foundation
import ImageIO
import LoupeCore

/// Shares the original bytes; for JPEG/PNG/TIFF with "remove location" it re-muxes losslessly without GPS.
public struct OriginalExporter: ShareExporter {
    public let id = "original"
    public let title = "Original"
    public init() {}

    public func canExport(_ kind: VersionKind) -> Bool { true }

    /// Formats whose GPS can be dropped without re-encoding.
    static func canStripLocation(_ file: URL) -> Bool {
        ["jpg", "jpeg", "png", "tif", "tiff"].contains(file.pathExtension.lowercased())
    }

    public func export(_ file: URL, kind: VersionKind, removeLocation: Bool, into directory: URL) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent(file.lastPathComponent)
        guard removeLocation, Self.canStripLocation(file),
            let source = CGImageSourceCreateWithURL(file as CFURL, nil),
            let type = CGImageSourceGetType(source),
            let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil)
        else {
            try FileManager.default.copyItem(at: file, to: out)
            return out
        }
        let options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &error) else {
            try? FileManager.default.removeItem(at: out)
            throw error?.takeRetainedValue() ?? ShareExportError.encodeFailed(file)
        }
        return out
    }
}

public enum ShareExportError: Error, LocalizedError {
    case unreadable(URL)
    case encodeFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): "Can't read \(url.lastPathComponent)"
        case .encodeFailed(let url): "Can't export \(url.lastPathComponent)"
        }
    }
}
