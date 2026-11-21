import CoreGraphics
import LoupeXMP

/// The names a photo's sidecar gives its faces: the people (and pets) named in Apple Photos, which the import from
/// Photos writes as regions. A found face takes the name of the region that marks it, so those people are named in
/// People from the start.
enum SourceNames {
    /// For each found box (0…1 of the shown photo from the top left), the name of the region marking it, or nil.
    /// Regions given for an image of another shape (a cropped edit, a photo turned in Loupe) aren't trusted.
    static func match(
        boxes: [CGRect], regions: [XMPDocument.FaceRegion], regionImageSize: CGSize?, imageSize: CGSize
    ) -> [String?] {
        var names = [String?](repeating: nil, count: boxes.count)
        guard !regions.isEmpty, imageSize.width > 0, imageSize.height > 0 else { return names }
        if let size = regionImageSize {
            let shape = Double(size.width / size.height), shown = Double(imageSize.width / imageSize.height)
            guard abs(shape - shown) <= 0.02 * shown else { return names }
        }
        // Every region and box that could be the same face: the region's centre inside the box (give or take a
        // quarter of it) and about as big. The closest pairs are taken first, each region and box once.
        var pairs: [(region: Int, box: Int, distance: Double)] = []
        for (r, region) in regions.enumerated() {
            for (b, box) in boxes.enumerated() where box.width > 0 && box.height > 0 {
                let dx = (region.x - box.midX) / box.width, dy = (region.y - box.midY) / box.height
                guard abs(dx) <= 0.75, abs(dy) <= 0.75 else { continue }
                let scale = (region.width * region.height / (box.width * box.height)).squareRoot()
                guard (0.4...2.5).contains(scale) else { continue }
                pairs.append((r, b, (dx * dx + dy * dy).squareRoot()))
            }
        }
        var usedRegions = Set<Int>()
        for pair in pairs.sorted(by: { $0.distance < $1.distance })
        where names[pair.box] == nil && !usedRegions.contains(pair.region) {
            names[pair.box] = regions[pair.region].name
            usedRegions.insert(pair.region)
        }
        return names
    }
}
