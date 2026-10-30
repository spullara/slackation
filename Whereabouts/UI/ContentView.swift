import SwiftUI
import CoreLocation

struct ContentView: View {
    @State private var runtime = LocationRuntime.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            NavigationStack { HomeView(runtime: runtime) }
                .tabItem { Label("Home", systemImage: "house") }
            NavigationStack { GeofencesView(runtime: runtime) }
                .tabItem { Label("Geofences", systemImage: "map") }
            NavigationStack { DestinationsView(runtime: runtime) }
                .tabItem { Label("Destinations", systemImage: "paperplane") }
        }
        .tint(Color("AccentColor"))
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { runtime.refreshMonitoring() }
        }
    }
}

struct HomeView: View {
    let runtime: LocationRuntime
    @State private var configuredIDs: Set<String> = []
    @Environment(\.openURL) private var openURL
    private var current: LocationStatus {
        runtime.currentStatus
    }
    private var permission: String {
        switch runtime.monitor.authorizationStatus {
        case .authorizedAlways: "Always allowed"
        case .authorizedWhenInUse: "While using the app"
        case .denied: "Access denied"
        case .restricted: "Access restricted"
        default: "Access not requested"
        }
    }
    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image("LaunchLogo").resizable().scaledToFit().frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("CURRENT LOCATION").font(.caption).foregroundStyle(.secondary)
                        Text(current.locationName).font(.title2.bold()).accessibilityIdentifier("currentLocation")
                        Text("\(current.displayEmoji)  \(current.text)").foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
            }
            Section {
                NavigationLink("Driving") { DrivingSettingsView(runtime: runtime) }
                if runtime.driving.isLiveLocationActive {
                    Label("Live location on while driving", systemImage: "location.fill")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let issue = runtime.driving.issue, runtime.driving.enabled {
                    ErrorText(message: issue)
                    Button("Open motion settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                }
            }
            Section("Location access") {
                Label(permission, systemImage: "location")
                if runtime.monitor.authorizationStatus != .authorizedAlways {
                    Text("Allow Always access for status updates when the app is closed.").font(.footnote).foregroundStyle(.secondary)
                    Button("Set location access") {
                        if runtime.monitor.authorizationStatus == .notDetermined {
                            runtime.monitor.requestAlwaysAuthorization()
                        } else {
                            openURL(URL(string: UIApplication.openSettingsURLString)!)
                        }
                    }
                }
                if let error = runtime.monitor.lastError { ErrorText(message: error) }
            }
            Section("Destination status") {
                ForEach(runtime.destinations.destinations, id: \.id) { destination in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(destination.displayName).font(.headline)
                        Text(!runtime.destinations.enabledIDs.contains(destination.id) ? "Off" : configuredIDs.contains(destination.id) ? "Ready" : "Setup required")
                            .font(.caption).foregroundStyle(.secondary)
                        if let status = runtime.engine.lastSentStatuses[destination.id] {
                            Text("\(status.displayEmoji)  \(status.text)")
                            if let date = runtime.engine.lastSentDates[destination.id] {
                                Text(date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            }
                        } else { Text("No status sent yet").foregroundStyle(.secondary) }
                        if let error = runtime.engine.lastErrors[destination.id] { ErrorText(message: error) }
                    }.padding(.vertical, 4)
                }
                if runtime.engine.isSending { ProgressView("Send status") }
            }
            Section {
                NavigationLink("Other status") { OtherStatusView(runtime: runtime) }
            } footer: { Text("Use this status outside all saved geofences.") }
            Section { NavigationLink("Event log") { EventLogView(log: runtime.eventLog) } }
            if let error = runtime.storageError { Section("Storage error") { ErrorText(message: error) } }
        }.navigationTitle("Home")
            .onAppear { configuredIDs = Set(runtime.destinations.destinations.filter { $0.isConfigured }.map(\.id)) }
    }
}

struct ErrorText: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
    }
}

struct OtherStatusView: View {
    let runtime: LocationRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var status = OtherStatus()
    @State private var initialized = false
    @State private var error: String?
    var body: some View {
        Form {
            Section("Outside all geofences") {
                TextField("Status text", text: $status.text)
                EmojiPickerButton(shortcode: $status.emoji, unicode: $status.emojiUnicode)
            }
            if let error { ErrorText(message: error) }
        }.navigationTitle("Other status")
            .onAppear {
                if !initialized { status = runtime.store.otherStatus; initialized = true }
            }
            .toolbar { Button("Save") {
                do {
                    try runtime.store.save(geofences: runtime.store.geofences, otherStatus: status)
                    runtime.refreshMonitoring()
                    dismiss()
                } catch { self.error = error.localizedDescription }
            } }
    }
}
