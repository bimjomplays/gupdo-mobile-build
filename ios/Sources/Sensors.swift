import CoreLocation
import CoreMotion
import Foundation

/// What the phone senses for habits: arrivals at saved places (region monitoring), a location fix for location proof,
/// and driving (Core Motion, backed by GPS speed). The rules for what these mean live in GupDoKit (`Presence`,
/// `Geo`, `Driving`); this only gathers. Tests and screen pictures use a fake (or none).
@MainActor
protocol PhoneSensors: AnyObject {
    /// Watches these places for entering and leaving. Events go to `onRegion` (place id, inside, when), also after
    /// the system relaunches the app in the background for one.
    func watch(_ places: [Place], onRegion: @escaping @MainActor (UUID, Bool, Date) -> Void) async
    /// One location fix, as sharp as it gets within `timeout` seconds (nil: no permission or no fix).
    func currentFix(timeout: TimeInterval) async -> LocationFix?
    /// Core Motion activities between these dates (empty without motion permission or hardware).
    func motionSamples(from: Date, to: Date) async -> [MotionSample]
    /// The most recent location fix the app saw, if any (its speed backs up driving detection).
    var lastFix: LocationFix? { get }
    /// While a habit waits for driving to stop: keep location updates running in the background, and call `onUpdate`
    /// with when the phone became stationary (nil while moving).
    func followDriving(_ on: Bool, onUpdate: @escaping @MainActor (Date?) -> Void)
    /// Asks for location (While Using, then Always for arrivals in the background) and motion permission.
    func requestPermissions()
}

@MainActor
final class Sensors: NSObject, PhoneSensors, CLLocationManagerDelegate {
    static let shared = Sensors()

    private let manager = CLLocationManager()
    private let motion = CMMotionActivityManager()
    private var monitor: CLMonitor?
    private var eventsTask: Task<Void, Never>?
    private var onRegion: (@MainActor (UUID, Bool, Date) -> Void)?
    private var drivingTask: Task<Void, Never>?
    private var background: CLBackgroundActivitySession?
    private(set) var lastFix: LocationFix?

    override init() {
        super.init()
        manager.delegate = self
    }

    // MARK: Permissions

    func requestPermissions() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
        if CMMotionActivityManager.isActivityAvailable(), CMMotionActivityManager.authorizationStatus() == .notDetermined {
            // the first query asks for Motion & Fitness permission
            motion.queryActivityStarting(from: Date().addingTimeInterval(-60), to: Date(), to: .main) { _, _ in }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Arrivals in the background need Always: ask for the upgrade once While Using is granted.
        if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
    }

    // MARK: Places

    static let monitorName = "gupdo-places"

    /// A condition's identifier carries the place and its circle, so a moved place is a new condition.
    static func identifier(_ p: Place) -> String {
        String(format: "%@|%.6f|%.6f|%.0f", p.id.uuidString, p.latitude, p.longitude, p.radius)
    }

    static func placeID(_ identifier: String) -> UUID? {
        identifier.split(separator: "|").first.flatMap { UUID(uuidString: String($0)) }
    }

    func watch(_ places: [Place], onRegion: @escaping @MainActor (UUID, Bool, Date) -> Void) async {
        self.onRegion = onRegion
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        if monitor == nil {
            let m = await CLMonitor(Self.monitorName)
            monitor = m
            eventsTask = Task { @MainActor [weak self] in
                do {
                    for try await event in await m.events {
                        guard let self, let id = Self.placeID(event.identifier) else { continue }
                        switch event.state {
                        case .satisfied: self.onRegion?(id, true, event.date)
                        case .unsatisfied: self.onRegion?(id, false, event.date)
                        default: break
                        }
                    }
                } catch {}
            }
        }
        guard let monitor else { return }
        // At most 20 conditions per app: the first 20 places (Home first).
        let wanted = places.sorted { ($0.isHome ? 0 : 1, $0.name) < ($1.isHome ? 0 : 1, $1.name) }.prefix(20)
        let ids = Set(wanted.map(Self.identifier))
        for old in await monitor.identifiers where !ids.contains(old) { await monitor.remove(old) }
        let existing = Set(await monitor.identifiers)
        for p in wanted where !existing.contains(Self.identifier(p)) {
            let condition = CLMonitor.CircularGeographicCondition(
                center: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude), radius: p.radius)
            await monitor.add(condition, identifier: Self.identifier(p), assuming: .unsatisfied)
        }
    }

    // MARK: Location

    func currentFix(timeout: TimeInterval) async -> LocationFix? {
        let deadline = Date().addingTimeInterval(timeout)
        let updates = Task<LocationFix?, Never> { @MainActor in
            var best: LocationFix?
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if update.authorizationDenied || update.authorizationDeniedGlobally { break }
                    guard let loc = update.location else { continue }
                    let fix = Self.fix(loc)
                    if best == nil || fix.accuracy < best!.accuracy { best = fix }
                    if fix.accuracy <= 20 || Date() >= deadline || Task.isCancelled { break }
                }
            } catch {}
            return best
        }
        let timer = Task { try? await Task.sleep(for: .seconds(timeout)); updates.cancel() }
        let best = await updates.value
        timer.cancel()
        if let best { lastFix = best }
        return best
    }

    static func fix(_ loc: CLLocation) -> LocationFix {
        LocationFix(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude,
                    accuracy: loc.horizontalAccuracy, speed: loc.speedAccuracy >= 0 ? loc.speed : -1,
                    time: loc.timestamp)
    }

    // MARK: Driving

    func motionSamples(from: Date, to: Date) async -> [MotionSample] {
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() != .denied,
              CMMotionActivityManager.authorizationStatus() != .restricted else { return [] }
        return await withCheckedContinuation { cont in
            motion.queryActivityStarting(from: from, to: to, to: .main) { activities, _ in
                cont.resume(returning: (activities ?? []).map {
                    MotionSample(start: $0.startDate, automotive: $0.automotive, stationary: $0.stationary,
                                 confident: $0.confidence != .low)
                })
            }
        }
    }

    func followDriving(_ on: Bool, onUpdate: @escaping @MainActor (Date?) -> Void) {
        guard on else {
            drivingTask?.cancel()
            drivingTask = nil
            background?.invalidate()
            background = nil
            return
        }
        guard drivingTask == nil else { return }
        background = CLBackgroundActivitySession()
        drivingTask = Task { @MainActor [weak self] in
            var stillSince: Date?
            do {
                for try await update in CLLocationUpdate.liveUpdates(.automotiveNavigation) {
                    if Task.isCancelled { break }
                    if let loc = update.location { self?.lastFix = Self.fix(loc) }
                    if update.stationary {
                        stillSince = stillSince ?? (update.location?.timestamp ?? Date())
                    } else if let speed = update.location?.speed, speed >= 0, speed < 1 {
                        stillSince = stillSince ?? (update.location?.timestamp ?? Date())
                    } else {
                        stillSince = nil
                    }
                    onUpdate(stillSince)
                }
            } catch {}
        }
    }
}
