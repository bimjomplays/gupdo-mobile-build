import CoreLocation
import MapKit
import Observation

/// Drive times for time to leave: MapKit's ETA by car from where the phone is to an event's Where. When to ask and
/// what the answer does to the alarm are GupDoKit's (`TravelTime`); this only asks. Tests use a fake.
@MainActor
protocol DriveTimes: AnyObject {
    /// Minutes by car from here to `place`, leaving at `departure` (nil: no location, no network, no route).
    func minutes(to place: EventLocation, departure: Date) async -> Int?
}

@MainActor
final class MapDriveTimes: DriveTimes {
    private let sensors: PhoneSensors?

    init(sensors: PhoneSensors?) { self.sensors = sensors }

    func minutes(to place: EventLocation, departure: Date) async -> Int? {
        let request = MKDirections.Request()
        request.source = await source()
        request.destination = MKMapItem(location: CLLocation(latitude: place.latitude, longitude: place.longitude),
                                        address: nil)
        request.transportType = .automobile
        request.departureDate = departure
        let directions = MKDirections(request: request)
        let answer = Once<Int?>()
        return await withCheckedContinuation { cont in
            answer.continuation = cont
            directions.calculateETA { response, _ in
                let minutes = response.map { TravelTime.minutes(fromSeconds: $0.expectedTravelTime) }
                Task { @MainActor in answer.resolve(minutes) }
            }
            // a background wake has little time: no answer in 15 s counts as unknown
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                directions.cancel()
                answer.resolve(nil)
            }
        }
    }

    /// Where the drive starts: a recent fix (the app's own or the system's last), else a fresh one, else whatever
    /// MapKit knows as the current location.
    private func source() async -> MKMapItem {
        if let fix = sensors?.recentFix(maxAge: 10 * 60) ?? (await sensors?.currentFix(timeout: 8)) {
            return MKMapItem(location: CLLocation(latitude: fix.latitude, longitude: fix.longitude), address: nil)
        }
        return MKMapItem.forCurrentLocation()
    }
}

/// Answers a continuation once (whichever of the result and the deadline comes first).
@MainActor
final class Once<T> {
    var continuation: CheckedContinuation<T, Never>?

    func resolve(_ value: T) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// Address search for an event's Where: suggestions while typing (MKLocalSearchCompleter), then the picked one
/// looked up for its point (MKLocalSearch).
@MainActor
@Observable
final class AddressSearch: NSObject, MKLocalSearchCompleterDelegate {
    struct Suggestion: Identifiable, Hashable {
        let id: Int
        let title: String
        let subtitle: String
    }

    /// The typed text changed.
    func update(_ query: String) {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            completer.cancel()
            completions = []
            suggestions = []
        } else {
            completer.queryFragment = query
        }
    }

    private(set) var suggestions: [Suggestion] = []
    private(set) var failed = false
    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private var completions: [MKLocalSearchCompletion] = []

    override init() {
        super.init()
        completer.resultTypes = [.address, .pointOfInterest]
        completer.delegate = self
    }

    /// Suggestions near here first.
    func near(latitude: Double, longitude: Double) {
        completer.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                                              latitudinalMeters: 50_000, longitudinalMeters: 50_000)
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            completions = Array(completer.results.prefix(8))
            suggestions = completions.enumerated().map { Suggestion(id: $0.offset, title: $0.element.title,
                                                                    subtitle: $0.element.subtitle) }
            failed = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            suggestions = []
            failed = true
        }
    }

    /// The picked suggestion as a Where (nil: it couldn't be found).
    func resolve(_ s: Suggestion) async -> EventLocation? {
        guard completions.indices.contains(s.id) else { return nil }
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completions[s.id]))
        let answer = Once<EventLocation?>()
        return await withCheckedContinuation { cont in
            answer.continuation = cont
            search.start { response, _ in
                let found = response?.mapItems.first.map { item -> EventLocation in
                    let point = item.location.coordinate
                    let address = item.address?.shortAddress ?? item.address?.fullAddress
                    return EventLocation(name: item.name ?? s.title, address: address ?? s.subtitle,
                                         latitude: point.latitude, longitude: point.longitude)
                }
                Task { @MainActor in answer.resolve(found) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                search.cancel()
                answer.resolve(nil)
            }
        }
    }
}
