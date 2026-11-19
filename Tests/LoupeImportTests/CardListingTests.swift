import AppKit
import Foundation
import Testing
import LoupeCore
@testable import LoupeImport

/// A temp dir standing in for /Volumes. Tests never read the real /Volumes.
final class FakeVolumes: @unchecked Sendable {
    let url: URL

    init() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-volumes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        // The real path (/private/var/...), as the directory enumerator reports it.
        let real = try #require(realpath(made.path, nil))
        defer { free(real) }
        url = URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }

    /// Creates `name/DCIM` and returns the card.
    func addCard(_ name: String = "EOS_DIGITAL") throws -> Card {
        let volume = url.appendingPathComponent(name)
        let dcim = volume.appendingPathComponent("DCIM")
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        return Card(volumeURL: volume, name: name, dcimURL: dcim)
    }

    @discardableResult
    func addFile(_ relativePath: String, bytes: Data) throws -> URL {
        let u = relativePath.split(separator: "/").reduce(url) { $0.appendingPathComponent(String($1)) }
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: u)
        return u
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

func randomBytes(_ count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, count) }
    return data
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

@Suite struct CardListingTests {
    @Test func detectsCardsWithDCIM() throws {
        let volumes = try FakeVolumes()
        _ = try volumes.addCard("A")
        try FileManager.default.createDirectory(
            at: volumes.url.appendingPathComponent("B"), withIntermediateDirectories: true)
        let center = NotificationCenter()
        let seen = Box<[[Card]]>([])
        let detector = CardDetector(volumesURL: volumes.url, notificationCenter: center) { seen.value.append($0) }
        #expect(detector.currentCards().map(\.name) == ["A"])
        let card = try #require(detector.currentCards().first)
        #expect(card.dcimURL.lastPathComponent == "DCIM")
        #expect(card.volumeURL.lastPathComponent == "A")

        detector.start()
        _ = try volumes.addCard("C")
        center.post(name: NSWorkspace.didMountNotification, object: nil)
        #expect(seen.value.last?.map(\.name) == ["A", "C"])
        try FileManager.default.removeItem(at: volumes.url.appendingPathComponent("A"))
        center.post(name: NSWorkspace.didUnmountNotification, object: nil)
        #expect(seen.value.last?.map(\.name) == ["C"])

        detector.stop()
        let count = seen.value.count
        center.post(name: NSWorkspace.didMountNotification, object: nil)
        #expect(seen.value.count == count)
    }

    @Test func listsAndGroupsCardContents() throws {
        let volumes = try FakeVolumes()
        let card = try volumes.addCard()
        try volumes.addFile("EOS_DIGITAL/DCIM/100CANON/IMG_1.CR2", bytes: randomBytes(100))
        try volumes.addFile("EOS_DIGITAL/DCIM/100CANON/IMG_1.JPG", bytes: randomBytes(50))
        try volumes.addFile("EOS_DIGITAL/DCIM/101CANON/IMG_2.CR2", bytes: randomBytes(70))
        try volumes.addFile("EOS_DIGITAL/DCIM/100CANON/._IMG_1.CR2", bytes: randomBytes(10))  // hidden: skipped
        try volumes.addFile("EOS_DIGITAL/DCIM/.Trashes/IMG_3.CR2", bytes: randomBytes(10))
        try volumes.addFile("EOS_DIGITAL/MISC/IMG_4.CR2", bytes: randomBytes(10))  // outside DCIM

        let groups = try CardListing.groups(on: card, editMarkers: ["-", "_edited", " (edited"])
        try #require(groups.map(\.stem) == ["IMG_1", "IMG_2"])
        #expect(groups[0].versions.map(\.file.url.lastPathComponent) == ["IMG_1.CR2", "IMG_1.JPG"])
        #expect(groups[0].versions[0].file.size == 100)
        #expect(groups[1].folder.lastPathComponent == "101CANON")
    }
}
