import Foundation

// Everything the app saves, in one Codable value (one local JSON file), plus setup checks.

struct GupDoData: Codable, Hashable {
    static let currentVersion = 1

    var version = GupDoData.currentVersion
    var places: [Place] = []
    var reminders: [Reminder] = []
    var habits: [Habit] = []
    var events: [Event] = []
    var history = HabitHistory()
    var settings = Settings()

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> GupDoData {
        try JSONDecoder().decode(GupDoData.self, from: data)
    }

    var home: Place? { places.first { $0.isHome } }
}

enum SetupProblem: String, Codable, Hashable {
    case emptyName
    case noDaysPicked
    case locationProofNeedsPlace
    case nfcProofNeedsTag
    case photoProofNeedsReference
    case endBeforeStart
    case unknownPlace
}

enum Setup {
    static func problems(_ h: Habit, places: [Place]) -> [SetupProblem] {
        var out: [SetupProblem] = []
        if h.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.emptyName) }
        if case .weekdays(let set) = h.days, set.isEmpty { out.append(.noDaysPicked) }
        if let place = h.placeID, !places.contains(where: { $0.id == place }) { out.append(.unknownPlace) }
        switch h.proof {
        case .location where h.placeID == nil: out.append(.locationProofNeedsPlace)
        case .nfc where (h.nfcTagID ?? "").isEmpty: out.append(.nfcProofNeedsTag)
        case .photo where (h.referencePhoto ?? "").isEmpty: out.append(.photoProofNeedsReference)
        default: break
        }
        return out
    }

    static func problems(_ r: Reminder, places: [Place]) -> [SetupProblem] {
        var out: [SetupProblem] = []
        if r.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.emptyName) }
        if case .days(let set) = r.repeatRule, set.isEmpty { out.append(.noDaysPicked) }
        if let place = r.placeID, !places.contains(where: { $0.id == place }) { out.append(.unknownPlace) }
        return out
    }

    static func problems(_ e: Event, places: [Place]) -> [SetupProblem] {
        var out: [SetupProblem] = []
        if e.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.emptyName) }
        if let end = e.end, end < e.start { out.append(.endBeforeStart) }
        if let place = e.placeID, !places.contains(where: { $0.id == place }) { out.append(.unknownPlace) }
        return out
    }
}
