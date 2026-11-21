import CoreGraphics
import Foundation
import Vision

/// What Vision finds in a photo: faces (with the five points SFace aligns on) and cats and dogs (with Vision's image
/// fingerprint of the animal, for grouping pets).
struct Detection {
    /// `person`, `cat` or `dog`.
    var kind: String
    /// In the shown photo, 0…1 from the top left.
    var box: CGRect
    /// Faces: eyes, nose tip and mouth corners in pixels from the top left, in `FaceAlignment.reference` order.
    var landmarks: [CGPoint] = []
    /// Pets: Vision's feature print of the animal, length 1.
    var vector: [Float] = []
    /// The name the photo's sidecar gives this face (`SourceNames`).
    var sourceName: String?
}

enum FaceDetector {
    /// Faces narrower than this (pixels in the scanned image) are too small to recognise.
    static let minimumFaceSide: CGFloat = 40

    static func detect(_ image: CGImage, pets: Bool) throws -> [Detection] {
        let size = CGSize(width: image.width, height: image.height)
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let faces = VNDetectFaceLandmarksRequest()
        let animals = VNRecognizeAnimalsRequest()
        try handler.perform(pets ? [faces, animals] : [faces])

        var found: [Detection] = []
        for face in faces.results ?? [] {
            guard face.boundingBox.width * size.width >= minimumFaceSide, let points = landmarks(face, size: size)
            else { continue }
            found.append(Detection(kind: "person", box: topLeft(face.boundingBox), landmarks: points))
        }
        for animal in pets ? animals.results ?? [] : [] {
            guard let label = animal.labels.first, label.confidence >= 0.6 else { continue }
            let kind: String
            switch label.identifier {
            case VNAnimalIdentifier.cat.rawValue: kind = "cat"
            case VNAnimalIdentifier.dog.rawValue: kind = "dog"
            default: continue
            }
            let print = VNGenerateImageFeaturePrintRequest()
            print.regionOfInterest = animal.boundingBox
            try handler.perform([print])
            guard let observation = print.results?.first, let vector = floats(observation) else { continue }
            found.append(Detection(kind: kind, box: topLeft(animal.boundingBox), vector: Vectors.normalized(vector)))
        }
        return found
    }

    /// Vision's normalized rectangles start at the bottom left.
    private static func topLeft(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    /// Image-left eye, image-right eye, nose tip, image-left and image-right mouth corner, in pixels from the top left.
    private static func landmarks(_ face: VNFaceObservation, size: CGSize) -> [CGPoint]? {
        guard let marks = face.landmarks else { return nil }
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            (region?.pointsInImage(imageSize: size) ?? []).map { CGPoint(x: $0.x, y: size.height - $0.y) }
        }
        func center(_ ps: [CGPoint]) -> CGPoint? {
            ps.isEmpty ? nil : CGPoint(x: ps.map(\.x).reduce(0, +) / CGFloat(ps.count),
                                       y: ps.map(\.y).reduce(0, +) / CGFloat(ps.count))
        }
        guard let eyeA = center(points(marks.leftPupil).isEmpty ? points(marks.leftEye) : points(marks.leftPupil)),
            let eyeB = center(points(marks.rightPupil).isEmpty ? points(marks.rightEye) : points(marks.rightPupil))
        else { return nil }
        let lips = points(marks.outerLips)
        // The nose crest runs from between the eyes to the tip: its lowest point.
        guard let nose = points(marks.noseCrest).max(by: { $0.y < $1.y }) ?? center(points(marks.nose)),
            let mouthLeft = lips.min(by: { $0.x < $1.x }), let mouthRight = lips.max(by: { $0.x < $1.x })
        else { return nil }
        let (left, right) = eyeA.x <= eyeB.x ? (eyeA, eyeB) : (eyeB, eyeA)
        return [left, right, nose, mouthLeft, mouthRight]
    }

    private static func floats(_ observation: VNFeaturePrintObservation) -> [Float]? {
        guard observation.elementType == .float else { return nil }
        return observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(observation.elementCount)) }
    }
}
