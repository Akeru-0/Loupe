import Foundation

/// Groups faces of one person (or one pet) by their vectors. Named people (`PeopleNames`) come first: a face alike
/// enough to a name's vector joins that name's group. The rest go biggest face first, each joining the group whose
/// average vector is most alike if it is alike enough, else starting a new one. A group's id is its lowest face id,
/// so a person keeps their id as photos are added.
enum FaceGrouping {
    struct Face {
        var id: Int64
        var kind: String
        var vector: [Float]
        /// Area of the face in the photo (0…1): bigger faces are clearer, so they seed the groups.
        var size: Double
    }

    /// How alike a face must be to a group's average: SFace's own same-person threshold is 0.363 for two faces;
    /// against an average it runs a little higher. Vision's feature prints are less specific, so pets need more.
    static func threshold(for kind: String) -> Float { kind == "person" ? 0.40 : 0.86 }

    /// How alike a face must be to a named person to take their name: stricter than joining a group, or a stranger
    /// who was once a near miss (and was moved out by hand) would pull the person's real faces after them.
    static func nameThreshold(for kind: String) -> Float { kind == "person" ? 0.55 : 0.90 }

    /// Face id → group id.
    static func group(_ faces: [Face]) -> [Int64: Int64] { group(faces, names: PeopleNames()).groups }

    /// Face id → group id, and group id → name for the groups of named people.
    static func group(_ faces: [Face], names: PeopleNames) -> (groups: [Int64: Int64], names: [Int64: String]) {
        var result: [Int64: Int64] = [:]
        var named: [Int64: String] = [:]
        for kind in Set(faces.map(\.kind)) {
            var sums: [[Float]] = []
            var members: [[Int64]] = []
            var rest: [Face] = []
            // Named people first: their groups are seeded by the name's vector.
            let people = names.people.filter { $0.kind == kind }
            var byName = [[Int64]](repeating: [], count: people.count)
            for face in faces where face.kind == kind {
                // A face corrected by hand goes where it was put, or nowhere.
                if let pin = names.pin(for: face.vector, kind: kind) {
                    if let name = pin.name, let i = people.firstIndex(where: { $0.name == name }) { byName[i].append(face.id) }
                    continue
                }
                let scores = people.map { Vectors.dot($0.vector, face.vector) }
                if let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] >= nameThreshold(for: kind) {
                    byName[best].append(face.id)
                } else {
                    rest.append(face)
                }
            }
            for (i, group) in byName.enumerated() where !group.isEmpty {
                let id = group.min()!
                for face in group { result[face] = id }
                named[id] = people[i].name
            }
            for face in rest.sorted(by: { ($0.size, -$0.id) > ($1.size, -$1.id) }) {
                var best = -1, bestScore: Float = -2
                for (i, sum) in sums.enumerated() {
                    let score = Vectors.dot(Vectors.normalized(sum), face.vector)
                    if score > bestScore { (best, bestScore) = (i, score) }
                }
                if best >= 0, bestScore >= threshold(for: kind) {
                    for j in sums[best].indices { sums[best][j] += face.vector[j] }
                    members[best].append(face.id)
                } else {
                    sums.append(face.vector)
                    members.append([face.id])
                }
            }
            for group in members {
                let id = group.min()!
                for face in group { result[face] = id }
            }
        }
        return (result, named)
    }
}
