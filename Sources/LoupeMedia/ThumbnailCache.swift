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

    public nonisolated static func key(for file: MediaFile) -> String {
        let text = "\(file.url.path)|\(file.size)|\(file.modified.timeIntervalSince1970)"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func thumbnail(for file: MediaFile, kind: VersionKind) async -> CGImage? {
        let key = Self.key(for: file)
        let cached = directory.appendingPathComponent(String(key.prefix(2)))
            .appendingPathComponent("\(key).jpg")
        if let source = CGImageSourceCreateWithURL(cached as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        {
            return image
        }

        let image: CGImage?
        switch kind {
        case .video, .live: image = await videoThumbnail(file.url)
        default: image = imageThumbnail(file.url)
        }
        guard let image else { return nil }
        write(image, to: cached)
        return image
    }

    private func imageThumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        func make(always: Bool) -> CGImage? {
            let options: [CFString: Any] = [
                (always ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent): true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        if let image = make(always: false), max(image.width, image.height) >= maxPixelSize / 2 {
            return image
        }
        return make(always: true)
    }

    private func videoThumbnail(_ url: URL) async -> CGImage? {
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

    private func write(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(
            dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        if !CGImageDestinationFinalize(dest) { try? FileManager.default.removeItem(at: url) }
    }
}
