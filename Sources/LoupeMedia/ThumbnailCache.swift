import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import LoupeCore
import UniformTypeIdentifiers

public actor ThumbnailCache {
    private let directory: URL
    private let maxPixelSize: Int

    public init(directory: URL, maxPixelSize: Int = 512) {
        self.directory = directory
        self.maxPixelSize = maxPixelSize
    }

    /// `rotation` is the photo's extra turn: a rotated photo gets its own thumbnail.
    public nonisolated static func key(for file: MediaFile, rotation: Int?) -> String {
        var text = "\(file.url.path)|\(file.size)|\(file.modified.timeIntervalSince1970)"
        if let turn = Orientation.turn(rotation) { text += "|r\(turn.exif)" }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The actor only holds configuration; all I/O and decoding runs in nonisolated async
    /// statics so concurrent requests are not serialised on the actor.
    /// `rotation` is the photo's extra turn on top of the file's own orientation (`ImageLoader`); nil for none.
    /// Videos always show their own orientation.
    public func thumbnail(for file: MediaFile, kind: VersionKind, rotation: Int?) async -> CGImage? {
        let isMotion = kind == .video || kind == .live
        return await Self.load(
            file, kind: kind, rotation: isMotion ? nil : rotation, directory: directory, maxPixelSize: maxPixelSize)
    }

    private nonisolated static func load(
        _ file: MediaFile, kind: VersionKind, rotation: Int?, directory: URL, maxPixelSize: Int
    ) async -> CGImage? {
        // A grid cell scrolled away before its request ran: skip the work.
        guard !Task.isCancelled else { return nil }
        let key = key(for: file, rotation: rotation)
        let cached = directory.appendingPathComponent(String(key.prefix(2)))
            .appendingPathComponent("\(key).jpg")
        // Decode now, here: a lazily decoded image would read and decode the file when first drawn, on the main thread.
        if let source = CGImageSourceCreateWithURL(cached as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        {
            return image
        }
        guard !Task.isCancelled else { return nil }

        let image: CGImage?
        switch kind {
        case .video, .live: image = await videoThumbnail(file.url, maxPixelSize: maxPixelSize)
        default: image = imageThumbnail(file.url, maxPixelSize: maxPixelSize, rotation: rotation)
        }
        guard let image else { return nil }
        write(image, to: cached)
        return image
    }

    private nonisolated static func imageThumbnail(_ url: URL, maxPixelSize: Int, rotation: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        func make(always: Bool) -> CGImage? {
            let options: [CFString: Any] = [
                (always ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent): true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        let made: CGImage?
        if let image = make(always: false), max(image.width, image.height) >= maxPixelSize / 2 {
            made = image
        } else {
            made = make(always: true)
        }
        return made.flatMap { ImageLoader.turned($0, by: rotation) }
    }

    private nonisolated static func videoThumbnail(_ url: URL, maxPixelSize: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { return nil }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            let time = CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)
            return try await generator.image(at: time).image
        } catch {
            return nil
        }
    }

    private nonisolated static func write(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(
            dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        if !CGImageDestinationFinalize(dest) { try? FileManager.default.removeItem(at: url) }
    }
}
