import Foundation

/// Groups faces of one person (or one pet) by their vectors. Named people come first: a face corrected by hand goes
/// where it was put, a face its photo names (Apple Photos' people, `sourceName`) goes to that person, and a face alike
/// enough to a named person (`PeopleNames`, and the faces Photos named) joins them. The rest go biggest face first, each joining the group whose
/// average vector is most alike if it is alike enough, else starting a new one. A group's id is its lowest face id,
/// so a person keeps their id as photos are added.
enum FaceGrouping {
    struct Face {
        var id: Int64
        var kind: String
        var vector: [Float]
        /// Area of the face in the photo (0…1): bigger faces are clearer, so they seed the groups.
        var size: Double
        /// The name the photo's sidecar gives the face (Apple Photos).
        var sourceName: String? = nil
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
            var rest: [Face] = []
            // Named people first: their groups are seeded by the name's vector, and by the faces Photos named.
            var byName: [String: [Int64]] = [:]
            var seedSums: [String: [Float]] = [:]
            var order: [String] = []
            func add(_ vector: [Float], weight: Float, to name: String) {
                if seedSums[name] == nil { order.append(name) }
                var sum = seedSums[name] ?? [Float](repeating: 0, count: vector.count)
                for j in sum.indices where j < vector.count { sum[j] += vector[j] * weight }
                seedSums[name] = sum
            }
            for person in names.people where person.kind == kind { add(person.vector, weight: Float(person.faces), to: person.name) }
            var unplaced: [Face] = []
            var pinned: [(Face, String)] = []
            for face in faces where face.kind == kind {
                // A face corrected by hand goes where it was put, or nowhere.
                if let pin = names.pin(for: face.vector, kind: kind) {
                    if let name = pin.name { pinned.append((face, name)) }
                    continue
                }
                if let source = face.sourceName, let name = names.resolve(source) {
                    byName[name, default: []].append(face.id)
                    add(face.vector, weight: 1, to: name)
                } else {
                    unplaced.append(face)
                }
            }
            // A pin to a name nobody has any more (its name was removed) leaves the face out.
            for (face, name) in pinned where seedSums[name] != nil { byName[name, default: []].append(face.id) }
            let seeds = order.map { ($0, Vectors.normalized(seedSums[$0]!)) }
            for face in unplaced {
                let scores = seeds.map { Vectors.dot($0.1, face.vector) }
                if let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] >= nameThreshold(for: kind) {
                    byName[seeds[best].0, default: []].append(face.id)
                } else {
                    rest.append(face)
                }
            }
            for name in order {
                guard let group = byName[name], !group.isEmpty else { continue }
                let id = group.min()!
                for face in group { result[face] = id }
                named[id] = name
            }
            var sums: [[Float]] = []
            var members: [[Int64]] = []
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
