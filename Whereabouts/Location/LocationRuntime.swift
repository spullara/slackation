import Observation
import UIKit

/// Created by the app delegate, including launches caused by a region event.
@MainActor
@Observable
final class LocationRuntime {
    static let shared = LocationRuntime()
    let store: GeofenceStore
    let webhooks = WebhookStore()
    let monitor = LocationMonitor()
    let driving: DrivingMonitor
    let destinations: DestinationRegistry
    let engine: StatusEngine
    private let isPreview: Bool
    private var initialMotionCheckFinished = false
    private var evaluating = false
    private var evaluateAgain = false
    private(set) var storageError: String?

    init(store: GeofenceStore? = nil, driving: DrivingMonitor? = nil,
         destinations: DestinationRegistry? = nil, defaults: UserDefaults = .standard) {
        self.store = store ?? GeofenceStore()
        #if DEBUG
        isPreview = ProcessInfo.processInfo.arguments.contains("--preview-driving")
        self.driving = driving ?? DrivingMonitor(preview: isPreview)
        #else
        isPreview = false
        self.driving = driving ?? DrivingMonitor()
        #endif
        self.destinations = destinations ?? DestinationRegistry(destinations: [SlackDestination()])
        engine = StatusEngine(registry: self.destinations, defaults: defaults)
        monitor.onStatusChange = { [weak self] _ in self?.evaluateStatus() }
        monitor.onMotionWake = { [weak self] in self?.evaluateStatus() }
        self.driving.onChange = { [weak self] in
            guard let self else { return }
            if self.evaluating { self.evaluateAgain = true; return }
            self.publishStatus()
        }
        self.driving.onMonitoringChange = { [weak self] enabled in self?.monitor.setSignificantChangesEnabled(enabled) }
    }

    func start() {
        do {
            try store.load()
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            return
        }
        do {
            try webhooks.load()
            destinations.replaceWebhooks(webhooks.configurations, secrets: webhooks.secrets)
        } catch {
            storageError = "Could not load webhooks. " + error.localizedDescription
        }
        refreshMonitoring()
    }

    func saveWebhook(_ configuration: WebhookConfiguration, secret: String?) throws {
        let previous = webhooks.configurations.first { $0.id == configuration.id }
        try webhooks.save(configuration, secret: secret)
        if previous?.url != configuration.url || secret != nil {
            engine.invalidate(destinationID: configuration.destinationID)
        }
        destinations.replaceWebhooks(webhooks.configurations, secrets: webhooks.secrets)
        refreshMonitoring()
    }

    func deleteWebhook(_ configuration: WebhookConfiguration) throws {
        try webhooks.delete(configuration)
        engine.invalidate(destinationID: configuration.destinationID)
        destinations.replaceWebhooks(webhooks.configurations, secrets: webhooks.secrets)
    }

    /// UI calls this after a successful store save.
    func refreshMonitoring() {
        driving.start()
        evaluateStatus()
        monitor.configure(geofences: store.geofences, other: store.otherStatus)
    }
    var currentStatus: LocationStatus {
        StatusResolver.resolve(geofences: store.geofences, insideIDs: monitor.insideIDs,
                               other: store.otherStatus, isDriving: driving.enabled && driving.isDriving,
                               drivingStatus: driving.status)
    }

    private func evaluateStatus() {
        // A known place wins immediately, even while motion history is pending.
        if currentStatus.geofenceID != nil { publishStatus() }
        if evaluating { evaluateAgain = true; return }
        evaluating = true
        Task {
            let lease = BackgroundLease()
            defer { lease.end() }
            repeat {
                evaluateAgain = false
                await driving.refresh()
                initialMotionCheckFinished = true
                if !isPreview && (driving.isDriving || monitor.isReady) { await engine.update(currentStatus) }
            } while evaluateAgain
            evaluating = false
        }
    }

    private func publishStatus() {
        guard !isPreview, driving.isDriving || monitor.isReady else { return }
        let status = currentStatus
        guard initialMotionCheckFinished || status.geofenceID != nil else { return }
        Task { await engine.update(status) }
    }

}

final class LocationAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        LocationRuntime.shared.start()
        return true
    }
}
