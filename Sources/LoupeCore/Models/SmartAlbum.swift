import Foundation

/// An album that fills itself: the photos matching its rules (all of them, or any), as Photos' Smart Albums. Kept
/// with the library in `<root>/.loupe/smart-albums.json`; the index turns it into SQL.
public struct SmartAlbum: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Photos must match every rule (true) or any one of them.
    public var matchAll: Bool
    public var rules: [SmartRule]

    public init(id: String = UUID().uuidString, name: String, matchAll: Bool = true, rules: [SmartRule]) {
        self.id = id
        self.name = name
        self.matchAll = matchAll
        self.rules = rules
    }
}

/// One condition: a field, how it's compared, and the value (text; see `SmartRule.Field`).
public struct SmartRule: Codable, Hashable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable {
        /// A folder album (its path, photos in its subfolders too) or an album from the sidecar (`Albums|`).
        case album
        /// The capture date: a day (`yyyy-MM-dd`), or a number of days for "is in the last".
        case date
        case keyword
        /// A person or pet named in People.
        case person
        /// A `SmartRule.Kind`.
        case photo
        /// 0…5 stars.
        case rating
        case camera
        case lens
        case filename
    }

    public enum Operator: String, Codable, CaseIterable, Sendable {
        case `is`, isNot, contains, doesNotContain, isBefore, isAfter, isInTheLast, isAtLeast, isAtMost
    }

    /// What "Photo is …" can be.
    public enum Kind: String, CaseIterable, Sendable {
        case favorite, edited, raw, video, panorama
    }

    public var field: Field
    public var op: Operator
    public var value: String

    public init(field: Field, op: Operator, value: String) {
        self.field = field
        self.op = op
        self.value = value
    }

    /// The comparisons each field offers, the first being its default.
    public static func operators(for field: Field) -> [Operator] {
        switch field {
        case .album, .keyword, .person, .photo: [.is, .isNot]
        case .date: [.isBefore, .isAfter, .isInTheLast]
        case .rating: [.isAtLeast, .is, .isAtMost]
        case .camera, .lens: [.is, .isNot, .contains]
        case .filename: [.contains, .doesNotContain, .is]
        }
    }

    /// A rule of `field` with its first comparison and an empty (or the usual) value.
    public static func starting(_ field: Field) -> SmartRule {
        let value = switch field {
        case .date: ""
        case .photo: Kind.favorite.rawValue
        case .rating: "3"
        default: ""
        }
        return SmartRule(field: field, op: operators(for: field)[0], value: value)
    }

    /// Whether the rule can be evaluated (a value given, of the right form).
    public var isComplete: Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field {
        case .date: return op == .isInTheLast ? (Int(text) ?? 0) > 0 : SmartRule.day(text) != nil
        case .rating: return Int(text).map { (0...5).contains($0) } ?? false
        case .photo: return Kind(rawValue: text) != nil
        default: return !text.isEmpty
        }
    }

    /// `yyyy-MM-dd` as the start of that day here.
    public static func day(_ text: String, calendar: Calendar = .current) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    public static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
