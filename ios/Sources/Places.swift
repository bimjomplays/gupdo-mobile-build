import MapKit
import SwiftUI

// Saved places (Home and any others): a name, a point and a circle. Place habits ring when he's there, location proof
// checks he's inside the circle, and region monitoring watches every saved place for arriving and leaving.

enum PlaceText {
    static func detail(_ p: Place, inside: Bool, habits: Int, reminders: Int = 0) -> String {
        var parts: [String] = []
        if p.isHome { parts.append("Home") }
        parts.append(inside ? "You're here" : "\(Int(p.radius)) m around the pin")
        if habits > 0 { parts.append(habits == 1 ? "1 habit" : "\(habits) habits") }
        if reminders > 0 { parts.append(reminders == 1 ? "1 reminder" : "\(reminders) reminders") }
        return parts.joined(separator: " · ")
    }
}

struct PlaceEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let original: Place?

    @State private var place = Place(name: "", latitude: 0, longitude: 0, radius: 150)
    @State private var located = false
    @State private var loaded = false
    @State private var locating = false
    @State private var message: String?
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    static let sizes: [(String, Double)] = [("Small", 100), ("Normal", 150), ("Large", 300)]

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $place.name)
                    .font(.title3)
                    .accessibilityIdentifier("place-name")
                Toggle("This is Home", isOn: $place.isHome)
            }
            Section {
                MapReader { proxy in
                    Map(position: $camera) {
                        if located {
                            MapCircle(center: coordinate, radius: place.radius)
                                .foregroundStyle(.blue.opacity(0.18))
                                .stroke(.blue, lineWidth: 2)
                            Marker(place.name.isEmpty ? "Place" : place.name, coordinate: coordinate)
                        }
                        UserAnnotation()
                    }
                    .onTapGesture { point in
                        if let c = proxy.convert(point, from: .local) { set(c, recenter: false) }
                    }
                }
                .frame(height: 260)
                .listRowInsets(EdgeInsets())
                Button(locating ? "Finding you…" : "Use where I am now", systemImage: "location") { locate() }
                    .disabled(locating)
                Picker("Size", selection: $place.radius) {
                    ForEach(Self.sizes, id: \.1) { name, metres in Text("\(name) · \(Int(metres)) m").tag(metres) }
                }
            } header: {
                Text("Where")
            } footer: {
                Text(message ?? "Tap the map to move the pin. The circle is the place: arriving in it starts a place habit or an arrival reminder, and being in it proves a location habit.")
            }
            if let original {
                Section {
                    Button("Delete place", role: .destructive) {
                        Task { if await model.deletePlace(original.id) { dismiss() } }
                    }
                    NoticeText()
                }
            }
        }
        .navigationTitle(original == nil ? "New place" : place.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let p = place
                    Task { await model.save(p); dismiss() }
                }
                .disabled(place.name.trimmingCharacters(in: .whitespaces).isEmpty || !located)
                .accessibilityIdentifier("place-save")
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let original {
            place = original
            located = true
            camera = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 700, longitudinalMeters: 700))
        } else {
            if model.data.home == nil {
                place.name = "Home"
                place.isHome = true
            }
            if model.sensors != nil { locate() }
        }
    }

    private func set(_ c: CLLocationCoordinate2D, recenter: Bool) {
        place.latitude = c.latitude
        place.longitude = c.longitude
        located = true
        message = nil
        if recenter {
            camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: 700, longitudinalMeters: 700))
        }
    }

    private func locate() {
        guard let sensors = model.sensors else { return }
        locating = true
        sensors.requestPermissions()
        Task {
            if let fix = await sensors.currentFix(timeout: 10) {
                set(CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude), recenter: true)
            } else {
                message = "Couldn't find you. Allow location for GupDo in Settings, or tap the map."
            }
            locating = false
        }
    }
}
