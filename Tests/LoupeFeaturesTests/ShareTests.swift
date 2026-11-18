import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import LoupeCore
import LoupeTestSupport
@testable import LoupeFeatures

private let devRaw = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("dev-library/IMG_2174.CR2").path

@Suite @MainActor struct ShareTests {
    let dir: URL
    let out: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-share-\(UUID().uuidString)")
        out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func props(_ url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }
    func size(_ url: URL) throws -> (Int, Int) {
        let p = try props(url)
        return (p[kCGImagePropertyPixelWidth] as! Int, p[kCGImagePropertyPixelHeight] as! Int)
    }
    func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    func jpeg(_ name: String, _ w: Int, _ h: Int, orientation: Int = 1, gps: Bool = false) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try TestImages.makeJPEG(at: url, width: w, height: h, orientation: orientation,
                                exif: [kCGImagePropertyExifUserComment: "hello"], gps: gps)
        return url
    }

    @Test func smallResizesAndStripsGPS() throws {
        let src = try jpeg("a.jpg", 4000, 3000, gps: true)
        let result = try JPEGExporter.small.export(src, kind: .jpeg, removeLocation: true, into: out)
        let (w, h) = try size(result)
        #expect(w == 2048 && h == 1536)
        #expect(result.lastPathComponent == "a.jpg")
        let source = try #require(CGImageSourceCreateWithURL(result as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        #expect(try props(result)[kCGImagePropertyGPSDictionary] == nil)
        let exif = try props(result)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifUserComment] as? String == "hello")
    }

    @Test func keepsGPSWhenToggleOff() throws {
        let src = try jpeg("a.jpg", 400, 300, gps: true)
        let result = try JPEGExporter.highQuality.export(src, kind: .jpeg, removeLocation: false, into: out)
        #expect(try props(result)[kCGImagePropertyGPSDictionary] != nil)
    }

    @Test func neverUpscales() throws {
        let src = try jpeg("a.jpg", 1000, 800)
        let result = try JPEGExporter.small.export(src, kind: .jpeg, removeLocation: true, into: out)
        let (w, h) = try size(result)
        #expect(w == 1000 && h == 800)
    }

    @Test func bakesOrientation() throws {
        let src = try jpeg("a.jpg", 400, 300, orientation: 6)
        let result = try JPEGExporter.highQuality.export(src, kind: .jpeg, removeLocation: true, into: out)
        let (w, h) = try size(result)
        #expect(w == 300 && h == 400)
        let o = try props(result)[kCGImagePropertyOrientation] as? Int
        #expect(o == nil || o == 1)
    }

    @Test func originalStripsGPSLosslessly() throws {
        let src = try jpeg("a.jpg", 400, 300, gps: true)
        let before = try sha(src)
        let result = try OriginalExporter().export(src, kind: .jpeg, removeLocation: true, into: out)
        #expect(try props(result)[kCGImagePropertyGPSDictionary] == nil)
        let (w, h) = try size(result)
        #expect(w == 400 && h == 300)
        #expect(result.lastPathComponent == "a.jpg")
        #expect(try sha(src) == before)
        // Kept when the toggle is off.
        let kept = try OriginalExporter().export(src, kind: .jpeg, removeLocation: false, into: out)
        #expect(try props(kept)[kCGImagePropertyGPSDictionary] != nil)
    }

    @Test func originalCopiesRawUnchanged() throws {
        let src = dir.appendingPathComponent("IMG_1.cr2")
        let bytes = Data((0..<1000).map { UInt8($0 % 251) })
        try bytes.write(to: src)
        let result = try OriginalExporter().export(src, kind: .raw, removeLocation: true, into: out)
        #expect(try Data(contentsOf: result) == bytes)
        #expect(result.lastPathComponent == "IMG_1.cr2")
    }

    @Test func xmpGPSIsNotCarriedIntoJPEGPresets() throws {
        // A source whose GPS lives only in embedded XMP must not leak it through a preset.
        let src = dir.appendingPathComponent("x.jpg")
        try TestImages.makeJPEG(at: src, width: 100, height: 80, gps: true, embeddedXMP: (rating: 3, subjects: ["a"]))
        let result = try JPEGExporter.highQuality.export(src, kind: .jpeg, removeLocation: true, into: out)
        let text = String(decoding: try Data(contentsOf: result), as: UTF8.self)
        #expect(!text.contains("GPSLatitude"))
        #expect(!text.contains("exif:GPS"))
    }

    /// JPEG whose only GPS is in an embedded XMP APP1 segment (`exif:GPSLatitude`), as other tools write it.
    func xmpGPSJPEG() throws -> URL {
        let plain = try jpeg("plain.jpg", 100, 80)
        let xmp = """
            <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/">\
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description \
            xmlns:exif="http://ns.adobe.com/exif/1.0/" exif:GPSLatitude="64,8.79N" exif:GPSLongitude="21,56.55W"/>\
            </rdf:RDF></x:xmpmeta><?xpacket end="w"?>
            """
        var segment = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
        segment.append(Data(xmp.utf8))
        let length = segment.count + 2
        var data = Data(try Data(contentsOf: plain).prefix(2))  // SOI
        data.append(contentsOf: [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)])
        data.append(segment)
        data.append(try Data(contentsOf: plain).dropFirst(2))
        let url = dir.appendingPathComponent("xmpgps.jpg")
        try data.write(to: url)
        #expect(String(decoding: data, as: UTF8.self).contains("GPSLatitude"))
        return url
    }

    @Test func xmpOnlyGPSIsStrippedEverywhere() throws {
        let src = try xmpGPSJPEG()
        for exporter in [JPEGExporter.highQuality, JPEGExporter.small] as [any ShareExporter] {
            let r = try exporter.export(src, kind: .jpeg, removeLocation: true, into: out)
            #expect(!String(decoding: try Data(contentsOf: r), as: UTF8.self).contains("GPSLatitude"))
        }
        let r = try OriginalExporter().export(src, kind: .jpeg, removeLocation: true, into: out)
        #expect(!String(decoding: try Data(contentsOf: r), as: UTF8.self).contains("GPSLatitude"))
    }

    @Test func menuFlagsKeptLocation() throws {
        let defaults = InMemoryPreferences()
        let action = ShareAction(exporters: [OriginalExporter(), JPEGExporter.highQuality, JPEGExporter.small],
                                 outputDirectory: out, defaults: defaults)
        func selection(_ kind: VersionKind, _ path: String) -> ActionSelection {
            let photo = PhotoRecord(id: 1, locationId: "l", folderPath: "", stem: "p", stemKey: "p", addedDate: Date())
            let v = VersionRecord(photoId: 1, path: path, kind: kind, size: 1, modified: Date(), isDisplay: true)
            return ActionSelection(photos: [photo], versions: [1: [v]], root: dir)
        }
        let raw = try #require(action.entries(for: selection(.raw, "p.cr2")).first)
        #expect(raw.children.first { $0.id == "share.original" }?.title == "Original (location kept)")
        let jpegSel = try #require(action.entries(for: selection(.jpeg, "p.jpg")).first)
        #expect(jpegSel.children.first { $0.id == "share.original" }?.title == "Original")
        let video = try #require(action.entries(for: selection(.video, "p.mov")).first)
        #expect(video.children.first { $0.id == "share.hq" }?.isEnabled == false)
        #expect(video.children.first { $0.id == "share.small" }?.isEnabled == false)
        #expect(video.children.first { $0.id == "share.original" }?.isEnabled == true)
    }

    @Test func removeLocationDefaultsOnAndPersists() {
        let defaults = InMemoryPreferences()
        #expect(SharePreferences.removeLocation(in: defaults))
        SharePreferences.setRemoveLocation(false, in: defaults)
        #expect(!SharePreferences.removeLocation(in: defaults))
    }

    @Test func junkJPEGWithLocationRemovalThrowsAndWritesNothing() throws {
        let src = dir.appendingPathComponent("junk.jpg")
        try Data("not an image".utf8).write(to: src)
        #expect(throws: (any Error).self) {
            try OriginalExporter().export(src, kind: .jpeg, removeLocation: true, into: out)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: devRaw)))
    func realRawThroughJPEGPresets() throws {
        let raw = URL(fileURLWithPath: devRaw)
        let before = try sha(raw)
        for exporter in [JPEGExporter.small, JPEGExporter.highQuality] {
            let result = try exporter.export(raw, kind: .raw, removeLocation: true, into: out)
            #expect(result.lastPathComponent == "IMG_2174.jpg")
            let source = try #require(CGImageSourceCreateWithURL(result as CFURL, nil))
            #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
            let (w, h) = try size(result)
            if exporter.maxLongEdge != nil { #expect(max(w, h) <= 2048 && max(w, h) > 0) } else { #expect(max(w, h) > 0) }
            #expect(try props(result)[kCGImagePropertyGPSDictionary] == nil)
        }
        #expect(try sha(raw) == before)
    }
}
