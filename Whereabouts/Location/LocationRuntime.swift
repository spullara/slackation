import Observation
import UIKit

/// Created by the app delegate, including launches caused by a region event.
@MainActor
@Observable
final class LocationRuntime {
    static let shared = LocationRuntime()
    let store = GeofenceStore()
    let webhooks = WebhookStore()
    let monitor = LocationMonitor()
    let driving: DrivingMonitor
    let destinations: DestinationRegistry
    let engine: StatusEngine
    private let isPreview: Bool
    private var evaluating = false
    private var evaluateAgain = false
    private(set) var storageError: String?

    private init() {
        #if DEBUG
        isPreview = ProcessInfo.processInfo.arguments.contains("--preview-driving")
        driving = DrivingMonitor(preview: isPreview)
        #else
        isPreview = false
        driving = DrivingMonitor()
        #endif
        destinations = DestinationRegistry(destinations: [SlackDestination()])
        engine = StatusEngine(registry: destinations)
        monitor.onStatusChange = { [weak self] _ in self?.evaluateStatus() }
        monitor.onMotionWake = { [weak self] in self?.evaluateStatus() }
        driving.onChange = { [weak self] in self?.publishStatus() }
        driving.onMonitoringChange = { [weak self] enabled in self?.monitor.setSignificantChangesEnabled(enabled) }
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
        if evaluating { evaluateAgain = true; return }
        evaluating = true
        Task {
            let lease = BackgroundLease()
            defer { lease.end() }
            repeat {
                evaluateAgain = false
                await driving.refresh()
                if !isPreview && (driving.isDriving || monitor.isReady) { await engine.update(currentStatus) }
            } while evaluateAgain
            evaluating = false
        }
    }

    private func publishStatus() {
        guard !isPreview, driving.isDriving || monitor.isReady else { return }
        let status = currentStatus
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
