import Foundation

// Habit proof decisions. The phone gathers the raw facts (Vision's feature-print distance between the live photo and
// the reference photo, a location fix, an NFC tag's UID, Core Motion activities); the rules here decide what they
// prove. The app turns a passing check into `ProofEvidence` for `HabitLogic.answer`.

// MARK: - Photo

/// A live camera photo against the habit's reference photo of the spot. The app computes Vision image feature prints
/// of both (on the phone, offline) and their distance: small = the same scene.
enum PhotoMatch {
    /// Feature-print distance at or below which a proof photo counts as the reference spot. Tuned on the CI's
    /// simulator with the photo set in ios/Tests/Fixtures/PhotoMatch (same spots retaken from another angle, other
    /// light, a step closer; random rooms), see PhotoMatchTests.
    static let threshold: Double = 0.62
    /// Up to this distance a failed photo is "close": the screen suggests lining it up with the reference.
    static let closeMargin: Double = 0.12

    enum Verdict: String, Codable, Hashable {
        case match
        /// Not a match, but near: probably the right spot from a different angle.
        case close
        case noMatch
    }

    static func verdict(distance: Double, threshold: Double = threshold) -> Verdict {
        guard distance.isFinite, distance >= 0 else { return .noMatch }
        if distance <= threshold { return .match }
        if distance <= threshold + closeMargin { return .close }
        return .noMatch
    }

    /// The reference photo's file name for a habit (the app keeps photos in its own folder, never the photo library).
    static func referenceFileName(for habitID: UUID) -> String { "ref-\(habitID.uuidString).jpg" }
}

// MARK: - Location

enum Geo {
    static let earthRadius = 6_371_000.0
    /// A location fix vaguer than this can't prove anything.
    static let maxProofAccuracy = 100.0
    /// How much of a fix's uncertainty may stick out of the place's circle.
    static let accuracySlack = 30.0

    /// Great-circle distance in metres.
    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = Double.pi / 180
        let dLat = (lat2 - lat1) * r, dLon = (lon2 - lon1) * r
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * r) * cos(lat2 * r) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    /// Location proof: a fix (horizontal accuracy in metres, negative = invalid) puts the phone at the place.
    static func isAt(_ place: Place, latitude: Double, longitude: Double, accuracy: Double) -> Bool {
        guard accuracy >= 0, accuracy <= maxProofAccuracy else { return false }
        let d = distance(place.latitude, place.longitude, latitude, longitude)
        return d <= place.radius + min(accuracy, accuracySlack)
    }
}

/// A location fix as the phone reports it.
struct LocationFix: Codable, Hashable {
    var latitude: Double
    var longitude: Double
    /// Horizontal accuracy in metres (negative = invalid).
    var accuracy: Double
    /// Metres per second (negative = unknown).
    var speed: Double = -1
    var time: Date
}

// MARK: - Checking proof for a group

enum ProofCheck {
    /// The location-proof habits among `habits` that this fix proves, with the evidence for each.
    static func byLocation(_ habits: [Habit], places: [Place], fix: LocationFix) -> [(habit: Habit, evidence: ProofEvidence)] {
        habits.compactMap { h in
            guard h.proof == .location, let id = h.placeID, let place = places.first(where: { $0.id == id }),
                  Geo.isAt(place, latitude: fix.latitude, longitude: fix.longitude, accuracy: fix.accuracy)
            else { return nil }
            return (h, .location(placeID: id))
        }
    }

    /// The NFC-proof habits among `habits` registered to this tag.
    static func byTag(_ habits: [Habit], tagID: String) -> [(habit: Habit, evidence: ProofEvidence)] {
        let tag = NFCTagID.normalized(tagID)
        guard !tag.isEmpty else { return [] }
        return habits.compactMap { h in
            guard h.proof == .nfc, let mine = h.nfcTagID, NFCTagID.normalized(mine) == tag else { return nil }
            return (h, .nfc(tagID: mine))
        }
    }
}

enum NFCTagID {
    /// A tag's UID bytes as the stored id: upper-case hex, colon separated ("04:A2:2B:...").
    static func string(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Ids compare without case or separators.
    static func normalized(_ id: String) -> String {
        id.uppercased().filter { $0.isHexDigit }
    }
}

// MARK: - Driving

/// One Core Motion activity (it lasts from `start` until the next one).
struct MotionSample: Codable, Hashable {
    var start: Date
    var automotive: Bool
    var stationary: Bool = false
    /// Core Motion's confidence is medium or high.
    var confident: Bool = true
}

/// "Can't right now" while driving, and when a driving pause ends. Core Motion first; a GPS speed backs it up.
enum Driving {
    /// Faster than this (about 25 km/h) counts as driving.
    static let drivingSpeed = 7.0
    /// A non-driving activity has to last this long before driving counts as stopped (traffic lights, queues).
    static let stopMinutes = 2.0

    static func isDriving(samples: [MotionSample], fix: LocationFix?, now: Date) -> Bool {
        if let fix, fix.speed >= drivingSpeed, fix.accuracy >= 0, fix.accuracy <= 100,
           now.timeIntervalSince(fix.time) < 120 {
            return true
        }
        let current = samples.filter { $0.confident && $0.start <= now }.max { $0.start < $1.start }
        return current?.automotive ?? false
    }

    /// When driving stopped after `pauseStart` (the start of the first confident non-driving activity after the last
    /// driving one, once it has lasted `stopMinutes`), or nil while still driving or not sure yet.
    static func stoppedAt(samples: [MotionSample], since pauseStart: Date, now: Date) -> Date? {
        let sorted = samples.filter { $0.confident && $0.start <= now }.sorted { $0.start < $1.start }
        let lastDriving = sorted.last { $0.automotive }?.start ?? .distantPast
        guard let stop = sorted.first(where: { !$0.automotive && $0.start > lastDriving }) else { return nil }
        guard now.timeIntervalSince(stop.start) >= stopMinutes * 60 else { return nil }
        return max(stop.start, pauseStart)
    }
}
