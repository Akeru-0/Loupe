import Foundation

/// The names given in People and the corrections made by hand, kept with the library in `<root>/.loupe/people.json`
/// (a hidden folder, never scanned), so they outlive the index and rescans. Each name keeps the average vector of
/// the faces it was given to: faces like it get that name, wherever and whenever they are found. A correction pins
/// one face (by its vector: a rescan of the photo gives the same) to a name, or to nobody.
public struct PeopleNames: Codable, Equatable, Sendable {
    public struct Person: Codable, Equatable, Sendable {
        public var name: String
        /// `person`, `cat` or `dog`.
        public var kind: String
        /// Average of the named faces' vectors (length 1).
        public var vector: [Float]
        /// How many faces went into `vector`, so later namings weigh in fairly.
        public var faces: Int
    }

    /// A face moved by hand: to the person called `name`, or out of every group (`name` nil).
    public struct Pin: Codable, Equatable, Sendable {
        public var kind: String
        public var vector: [Float]
        public var name: String?
    }

    public var people: [Person] = []
    public var pins: [Pin] = []

    /// A person not named by the user but given an identity so corrections can point at them (moving a face to
    /// "Cat 2"): their name starts with this and is never shown.
    public static let hiddenPrefix = "#"

    public static func isShown(_ name: String) -> Bool { !name.hasPrefix(hiddenPrefix) }

    /// A pin applies to a face this alike: the same face of the same photo, scanned again.
    static let sameFace: Float = 0.98

    public init(people: [Person] = [], pins: [Pin] = []) {
        self.people = people
        self.pins = pins
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        people = try c.decodeIfPresent([Person].self, forKey: .people) ?? []
        pins = try c.decodeIfPresent([Pin].self, forKey: .pins) ?? []  // written before corrections existed
    }

    /// The correction for a face, if one was made: `.some(nil)` is "nobody".
    func pin(for vector: [Float], kind: String) -> Pin? {
        pins.first { $0.kind == kind && Vectors.dot($0.vector, vector) >= Self.sameFace }
    }

    /// Pins these faces to `name` (nil: nobody), replacing earlier corrections of them. Moving them to a name nobody
    /// has yet makes that person.
    mutating func pin(_ vectors: [[Float]], kind: String, to name: String?) {
        for v in vectors {
            pins.removeAll { $0.kind == kind && Vectors.dot($0.vector, v) >= Self.sameFace }
            pins.append(Pin(kind: kind, vector: v, name: name))
        }
        if let name, !people.contains(where: { $0.name == name && $0.kind == kind }) {
            self.name(name, kind: kind, vectors: vectors, previous: nil)
        }
    }

    static func url(root: URL) -> URL {
        root.appendingPathComponent(".loupe", isDirectory: true).appendingPathComponent("people.json")
    }

    public static func load(root: URL) -> PeopleNames {
        guard let data = try? Data(contentsOf: url(root: root)),
            let names = try? JSONDecoder().decode(PeopleNames.self, from: data)
        else { return PeopleNames() }
        return names
    }

    public func save(root: URL) throws {
        let url = Self.url(root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Names the faces whose vectors are `vectors`: they join the person already called `name` (of the same kind)
    /// or start one. `previous`: the name the group had, which is dropped (renaming, not adding a second name).
    mutating func name(_ name: String, kind: String, vectors: [[Float]], previous: String?) {
        if let previous, previous != name { people.removeAll { $0.name == previous && $0.kind == kind } }
        guard !vectors.isEmpty else { return }
        var sum = [Float](repeating: 0, count: vectors[0].count)
        for v in vectors { for i in sum.indices where i < v.count { sum[i] += v[i] } }
        if let i = people.firstIndex(where: { $0.name == name && $0.kind == kind }) {
            let old = people[i]
            for j in sum.indices where j < old.vector.count { sum[j] += old.vector[j] * Float(old.faces) }
            people[i] = Person(name: name, kind: kind, vector: Vectors.normalized(sum), faces: old.faces + vectors.count)
        } else {
            people.append(Person(name: name, kind: kind, vector: Vectors.normalized(sum), faces: vectors.count))
        }
    }

    mutating func forget(_ name: String, kind: String) {
        people.removeAll { $0.name == name && $0.kind == kind }
    }
}
