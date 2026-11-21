import AppKit
import LoupeCore
import LoupeFaces
import LoupeIndex
import LoupeMedia
import SwiftUI

/// Utilities ▸ People: everyone face recognition found (people, then cats and dogs alike), each as a tile with their
/// face cut from their clearest photo. A tile opens their photos like an album; Back returns here.
struct PeopleView: View {
    var model: AppModel

    var body: some View {
        if model.faceGroups.isEmpty {
            ContentUnavailableView {
                Label("No People Yet", systemImage: "person.crop.square")
            } description: {
                Text(emptyReason)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 24)], spacing: 28) {
                    ForEach(model.faceGroups) { group in
                        Button { model.openFaceGroup(group.id) } label: {
                            PersonTile(group: group, title: model.faceGroupTitle(group), library: model.library)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Show Photos") { model.openFaceGroup(group.id) }
                            Divider()
                            Button("Rename…") { Task { await model.renameFaceGroup(group) } }
                            if model.shownName(group) != nil {
                                Button("Remove Name") { Task { await model.setFaceGroupName(group, to: nil) } }
                            }
                        }
                    }
                }
                .padding(28)
            }
        }
    }

    private var emptyReason: String {
        if !model.faceModel.isInstalled || !FaceScanner.runtimeInstalled {
            return "Download the recognition model in Settings ▸ Faces. People and pets seen in at least two photos "
                + "appear here."
        }
        if case .scanning(let done, let total) = model.faceScanStatus {
            return "Looking for faces… \(done.formatted()) of \(total.formatted()) photos."
        }
        return "Nobody has been seen in two photos or more yet."
    }
}

/// One person or pet: their face in a circle, their name and how many photos show them.
private struct PersonTile: View {
    let group: LibraryIndex.FaceGroup
    let title: String
    let library: Library?
    // `@State` is a macro whose plugin ships only with Xcode; see SettingsView.
    private let picture: State<CGImage?>

    init(group: LibraryIndex.FaceGroup, title: String, library: Library?) {
        self.group = group
        self.title = title
        self.library = library
        picture = State(initialValue: FacePictures.cached(group.coverFaceID))
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(.quaternary)
                if let image = picture.wrappedValue {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, height: 140)
            .clipShape(Circle())
            .contentShape(Circle())
            Text(title).font(.headline)
            Text("\(group.photoCount.formatted()) \(group.photoCount == 1 ? "photo" : "photos")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: group.coverFaceID) {
            guard picture.wrappedValue == nil, let library else { return }
            picture.wrappedValue = await FacePictures.picture(for: group, library: library)
        }
    }

    private var symbol: String {
        switch group.kind {
        case "cat": "cat"
        case "dog": "dog"
        default: "person.fill"
        }
    }
}

/// A person's picture: a square around their face in the photo it was found in, a little wider than the face.
/// Cut off the main thread and kept in memory by face.
@MainActor enum FacePictures {
    private static var cache: [Int64: CGImage] = [:]

    static func cached(_ faceID: Int64) -> CGImage? { cache[faceID] }

    static func picture(for group: LibraryIndex.FaceGroup, library: Library) async -> CGImage? {
        if let image = cache[group.coverFaceID] { return image }
        let index = library.index, root = library.location.rootURL
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let photo = try? index.photo(id: group.coverPhotoID),
                let display = try? index.versions(ofPhoto: group.coverPhotoID).first(where: \.isDisplay),
                let full = ImageLoader.image(at: display.url(in: root), maxPixelSize: 1200, rotation: photo.rotation)
            else { return nil }
            let (w, h) = (CGFloat(full.width), CGFloat(full.height))
            let box = group.coverBox
            let side = min(max(box.width * w, box.height * h) * 1.7, min(w, h))
            let center = CGPoint(x: box.midX * w, y: box.midY * h)
            let x = min(max(center.x - side / 2, 0), w - side), y = min(max(center.y - side / 2, 0), h - side)
            return full.cropping(to: CGRect(x: x, y: y, width: side, height: side).integral)
        }.value
        if let image { cache[group.coverFaceID] = image }
        return image
    }
}
