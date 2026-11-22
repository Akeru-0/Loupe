import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import LoupeCore
import UniformTypeIdentifiers

public actor ThumbnailCache {
    private let directory: URL
    private let maxPixelSize: Int

    /// The small version of every thumbnail (`micro…`): shown at once while the thumbnail loads, as Photos does
    /// when scrolling fast, and all the grid shows when zoomed far out (its tiles are no bigger). About 100 KB in
    /// memory, 15 KB on disk.
    public static let microPixelSize = 192

    /// The colour space previews are drawn in: the screen's (set by the app), so Core Animation shows them as they
    /// are instead of converting each one on the main thread while drawing a frame. sRGB until it's set.
    public static var displayColorSpace: CGColorSpace? {
        get { displaySpace.withLock { $0 } }
        set { displaySpace.withLock { $0 = newValue } }
    }
    private static let displaySpace = SpaceLock()

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
    public nonisolated func thumbnail(for file: MediaFile, kind: VersionKind, rotation: Int?) async -> CGImage? {
        let isMotion = kind == .video || kind == .live
        return await Self.load(
            file, kind: kind, rotation: isMotion ? nil : rotation, directory: directory, maxPixelSize: maxPixelSize)
    }

    /// The small thumbnail. It's made with the thumbnail, the first time that is loaded; without `make`, nil until
    /// then (fast). With `make`, a missing one is made now: from the thumbnail on disk, or with it. `maxPixelSize`
    /// below `microPixelSize` reads it smaller still (the mosaic's tiles), which also decodes faster.
    public nonisolated func microThumbnail(
        for file: MediaFile, kind: VersionKind, rotation: Int?, make: Bool = false, maxPixelSize size: Int? = nil
    ) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let isMotion = kind == .video || kind == .live
        let turn = isMotion ? nil : rotation
        let url = Self.cacheURL(Self.key(for: file, rotation: turn), micro: true, in: directory)
        if let image = Self.decode(url, maxPixelSize: size) { return image }
        guard make,
            let full = await Self.load(file, kind: kind, rotation: turn, directory: directory, maxPixelSize: maxPixelSize)
        else { return nil }
        return Self.decode(url, maxPixelSize: size)
            ?? Self.scaled(full, maxPixelSize: min(size ?? Self.microPixelSize, Self.microPixelSize))
    }

    private nonisolated static func cacheURL(_ key: String, micro: Bool, in directory: URL) -> URL {
        directory.appendingPathComponent(String(key.prefix(2))).appendingPathComponent(key + (micro ? ".s192.jpg" : ".jpg"))
    }

    /// Decodes now, here, into pixels the screen takes as they are (`displayReady`).
    private nonisolated static func decode(_ url: URL, maxPixelSize: Int? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let image: CGImage?
        if let maxPixelSize {
            // A JPEG decodes straight to a half or quarter size: cheaper than decoding and then scaling.
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        return image.flatMap { displayReady($0) }
    }

    /// The image drawn into a plain bitmap in the layout the GPU uses (32-bit BGRA, premultiplied). An image read
    /// from a JPEG stays a JPEG underneath, even "cached immediately": Core Animation then decodes it again, on the
    /// main thread, while committing the frame that shows it, which costs frames when many tiles appear at once
    /// (a zoomed-out grid scrolling).
    nonisolated static func displayReady(_ image: CGImage, width: Int? = nil, height: Int? = nil) -> CGImage? {
        let width = width ?? image.width, height = height ?? image.height
        let space = displayColorSpace ?? image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Writes the tiny thumbnail made from `image` unless it's there.
    private nonisolated static func writeMicroIfMissing(_ image: CGImage, key: String, directory: URL) {
        let url = cacheURL(key, micro: true, in: directory)
        guard !FileManager.default.fileExists(atPath: url.path), let micro = scaled(image, maxPixelSize: microPixelSize)
        else { return }
        write(micro, to: url, quality: 0.7)
    }

    nonisolated static func scaled(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let scale = min(1, Double(maxPixelSize) / Double(max(image.width, image.height, 1)))
        return displayReady(
            image, width: max(1, Int((Double(image.width) * scale).rounded())),
            height: max(1, Int((Double(image.height) * scale).rounded())))
    }

    private nonisolated static func load(
        _ file: MediaFile, kind: VersionKind, rotation: Int?, directory: URL, maxPixelSize: Int
    ) async -> CGImage? {
        // A grid cell scrolled away before its request ran: skip the work.
        guard !Task.isCancelled else { return nil }
        let key = key(for: file, rotation: rotation)
        let cached = cacheURL(key, micro: false, in: directory)
        if let image = decode(cached) {
            writeMicroIfMissing(image, key: key, directory: directory)  // thumbnails made before there were tiny ones
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
        writeMicroIfMissing(image, key: key, directory: directory)
        return displayReady(image)
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

    private nonisolated static func write(_ image: CGImage, to url: URL, quality: Double = 0.8) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(
            dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        if !CGImageDestinationFinalize(dest) { try? FileManager.default.removeItem(at: url) }
    }
}

/// `ThumbnailCache.displayColorSpace`'s storage, read from every decoding thread.
final class SpaceLock: @unchecked Sendable {
    private let lock = NSLock()
    private var space: CGColorSpace?

    func withLock<T>(_ body: (inout CGColorSpace?) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&space)
    }
}
