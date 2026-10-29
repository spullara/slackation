import SwiftUI
import MapKit

struct GeofencesView: View {
    let runtime: LocationRuntime
    @State private var editing: Geofence?
    @State private var error: String?
    var body: some View {
        List {
            if runtime.store.geofences.isEmpty {
                VStack(spacing: 12) {
                    Image("LaunchLogo").resizable().scaledToFit().frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    Text("Add your first place").font(.headline)
                    Text("Set a location and choose the status to send when you arrive.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 24)
            }
            Section {
                ForEach(runtime.store.geofences) { place in
                    Button { editing = place } label: {
                        HStack {
                            Image(systemName: "mappin.circle.fill").font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(place.name).foregroundStyle(.primary).font(.headline)
                                Text("\(place.statusEmoji)  \(place.statusText)").foregroundStyle(.secondary)
                                Text("\(Int(place.radius)) m radius").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }.onDelete(perform: delete)
            } footer: { Text("\(runtime.store.geofences.count) of 20 geofences. If places overlap, the smallest radius wins.") }
            if let error { ErrorText(message: error) }
        }.navigationTitle("Geofences")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add geofence", systemImage: "plus") {
                        editing = Geofence(name: "", latitude: 37.3349, longitude: -122.0090,
                                           radius: 200, statusText: "", statusEmoji: ":office:")
                    }.disabled(runtime.store.geofences.count >= GeofenceStore.maximumGeofences)
                }
            }
            .sheet(item: $editing) { place in
                NavigationStack { GeofenceEditor(runtime: runtime, place: place) }
            }
    }
    private func delete(at offsets: IndexSet) {
        var places = runtime.store.geofences
        places.remove(atOffsets: offsets)
        do {
            try runtime.store.save(geofences: places, otherStatus: runtime.store.otherStatus)
            runtime.refreshMonitoring()
        } catch { self.error = error.localizedDescription }
    }
}

struct GeofenceEditor: View {
    let runtime: LocationRuntime
    @State var place: Geofence
    @State private var camera: MapCameraPosition = .automatic
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
    }
    var body: some View {
        Form {
            Section("Place") {
                TextField("Name", text: $place.name).accessibilityIdentifier("placeName")
                if place.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Enter a name to save this geofence.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Search for an address", text: $query).submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    Button { Task { await search() } } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("Search address").disabled(searching || query.isEmpty)
                }
                if searching { ProgressView("Search places") }
                ForEach(results.indices, id: \.self) { index in
                    Button {
                        let item = results[index]
                        setCenter(item.placemark.coordinate)
                        if place.name.isEmpty { place.name = item.name ?? "" }
                        results = []
                    } label: {
                        VStack(alignment: .leading) {
                            Text(results[index].name ?? "Place")
                            Text(results[index].placemark.title ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                MapReader { proxy in
                    Map(position: $camera) {
                        MapCircle(center: center, radius: place.radius)
                            .foregroundStyle(Color.accentColor.opacity(0.18))
                            .stroke(Color.accentColor, lineWidth: 2)
                        Marker(place.name.isEmpty ? "Center" : place.name, coordinate: center)
                    }
                    .onTapGesture { point in
                        if let coordinate = proxy.convert(point, from: .local) { setCenter(coordinate) }
                    }
                    .frame(height: 260)
                    .accessibilityLabel("Geofence map. Tap to set the center.")
                }
                Text("Tap the map or search to set the center.").font(.caption).foregroundStyle(.secondary)
                Text("\(place.latitude, specifier: "%.5f"), \(place.longitude, specifier: "%.5f")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                LabeledContent("Radius", value: "\(Int(place.radius)) m")
                Slider(value: $place.radius, in: 100...2000, step: 50).accessibilityLabel("Radius")
            }
            Section("Status on arrival") {
                TextField("Status text", text: $place.statusText).accessibilityIdentifier("statusText")
                TextField("Emoji, for example :office:", text: $place.statusEmoji)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Use an emoji name between colons, for example :office:.").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle(runtime.store.geofences.contains(where: { $0.id == place.id }) ? "Edit geofence" : "New geofence")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { frameCenter() }
            .alert("Geofence", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
    }
    private func frameCenter() {
        camera = .region(MKCoordinateRegion(center: center, latitudinalMeters: max(1200, place.radius * 3),
                                            longitudinalMeters: max(1200, place.radius * 3)))
    }
    private func setCenter(_ coordinate: CLLocationCoordinate2D) {
        place.latitude = coordinate.latitude; place.longitude = coordinate.longitude
        frameCenter()
    }
    @MainActor private func search() async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searching = true; error = nil
        defer { searching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        do {
            results = try await MKLocalSearch(request: request).start().mapItems
            if results.isEmpty { error = "No places found. Try another address." }
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        place.name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !place.name.isEmpty else {
            error = "Enter a name to save this geofence."
            return
        }
        var places = runtime.store.geofences
        if let index = places.firstIndex(where: { $0.id == place.id }) { places[index] = place }
        else { places.append(place) }
        do {
            try runtime.store.save(geofences: places, otherStatus: runtime.store.otherStatus)
            runtime.refreshMonitoring()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
