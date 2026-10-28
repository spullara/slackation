import Observation
import UIKit

/// Created by the app delegate, including launches caused by a region event.
@MainActor
@Observable
final class LocationRuntime {
    static let shared = LocationRuntime()
    let store = GeofenceStore()
    let monitor = LocationMonitor()
    let destinations: DestinationRegistry
    let engine: StatusEngine
    private(set) var storageError: String?

    private init() {
        destinations = DestinationRegistry(destinations: [SlackDestination()])
        engine = StatusEngine(registry: destinations)
        monitor.onStatusChange = { [weak self] status in
            guard let self else { return }
            Task { await self.engine.update(status) }
        }
    }

    func start() {
        do {
            try store.load()
            storageError = nil
            refreshMonitoring()
        } catch {
            storageError = error.localizedDescription
        }
    }

    /// UI calls this after a successful store save.
    func refreshMonitoring() {
        monitor.configure(geofences: store.geofences, other: store.otherStatus)
    }
}

final class LocationAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        LocationRuntime.shared.start()
        return true
    }
}
