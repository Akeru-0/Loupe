import Testing
@testable import LoupeCore

@Suite struct AlbumTreeTests {
    private func info(_ path: String, _ count: Int, subs: Bool = false) -> FolderInfo {
        FolderInfo(path: path, directMediaCount: count, hasSubfolders: subs)
    }

    @Test func folderWithMediaIsAlbum() {
        #expect(AlbumTree.build([info("a", 3)]) == [AlbumNode(path: "a", name: "a", kind: .album, children: [])])
    }

    @Test func emptyFolderIsAlbum() {
        #expect(AlbumTree.build([info("e", 0)]) == [AlbumNode(path: "e", name: "e", kind: .album, children: [])])
    }

    @Test func folderWithOnlySubfoldersIsGroup() {
        let tree = AlbumTree.build([info("2026", 0, subs: true), info("2026/Iceland", 5)])
        #expect(tree == [
            AlbumNode(path: "2026", name: "2026", kind: .group, children: [
                AlbumNode(path: "2026/Iceland", name: "Iceland", kind: .album, children: []),
            ]),
        ])
    }

    @Test func albumWithSubfolderKeepsChildren() {
        let tree = AlbumTree.build([info("a", 2, subs: true), info("a/b", 1)])
        #expect(tree == [
            AlbumNode(path: "a", name: "a", kind: .album, children: [
                AlbumNode(path: "a/b", name: "b", kind: .album, children: []),
            ]),
        ])
    }

    @Test func rootIsNeverAnAlbum() {
        #expect(AlbumTree.build([info("", 4)]).isEmpty)
    }

    @Test func siblingsSortNaturally() {
        let tree = AlbumTree.build([info("Trip 10", 1), info("Trip 2", 1), info("x", 0, subs: true),
                                    info("x/Trip 10", 1), info("x/Trip 2", 1)])
        #expect(tree.map(\.name) == ["Trip 2", "Trip 10", "x"])
        #expect(tree.last?.children.map(\.name) == ["Trip 2", "Trip 10"])
    }

    @Test func pathsAreNFC() {
        let nfd = "Z\u{30C}lut\u{30C}"
        let tree = AlbumTree.build([info(nfd, 0, subs: true), info(nfd + "/x", 1)])
        #expect(tree.first?.path.unicodeScalars.elementsEqual("Žluť".unicodeScalars) == true)
        #expect(tree.first?.children.first?.path.unicodeScalars.elementsEqual("Žluť/x".unicodeScalars) == true)
    }
}
