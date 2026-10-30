import Observation
import UIKit

@MainActor
@Observable
final class StatusEngine {
    private(set) var lastSentStatuses: [String: LocationStatus] = [:]
    private(set) var lastSentDates: [String: Date] = [:]
    private(set) var lastErrors: [String: String] = [:]
    private(set) var isSending = false
    private let eventLog: EventLog
    private var lastResolved: LocationStatus?
    private let registry: DestinationRegistry
    private var revisions: [String: UUID] = [:]
    private var pending: LocationStatus?
    private let defaults: UserDefaults
    private static let lastStatusKey = "Whereabouts.destinationStatuses"

    init(registry: DestinationRegistry, defaults: UserDefaults = .standard, eventLog: EventLog? = nil) {
        self.eventLog = eventLog ?? .shared
        self.registry = registry
        self.defaults = defaults
        lastSentDates = defaults.dictionary(forKey: "Whereabouts.destinationStatusDates") as? [String: Date] ?? [:]
        if let data = defaults.data(forKey: Self.lastStatusKey),
           let saved = try? JSONDecoder().decode([String: LocationStatus].self, from: data) {
            lastSentStatuses = saved
        }
    }

    func invalidate(destinationID: String) {
        revisions[destinationID] = UUID()
        lastSentStatuses[destinationID] = nil
        lastSentDates[destinationID] = nil
        lastErrors[destinationID] = nil
        defaults.set(lastSentDates, forKey: "Whereabouts.destinationStatusDates")
        if let data = try? JSONEncoder().encode(lastSentStatuses) {
            defaults.set(data, forKey: Self.lastStatusKey)
        }
    }

    /// Serializes events and retains only the latest pending status.
    /// Destinations publish concurrently, with independent success and error state.
    func update(_ status: LocationStatus) async {
        if lastResolved != status {
            let reason: String
            switch status.kind {
            case .geofence: reason = "inside \(status.locationName)"
            case .driving: reason = "driving"
            case .other: reason = "outside all geofences"
            }
            eventLog.append(.status, "status resolved: \(status.text) — \(reason)")
            lastResolved = status
        }
        pending = status
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }
        let lease = BackgroundLease()
        defer { lease.end() }
        while let next = pending {
            pending = nil
            let tasks = registry.enabledDestinations.map { destination in
                let revision = revisions[destination.id]
                return Task { @MainActor in
                    guard self.revisions[destination.id] == revision,
                          self.registry.enabledIDs.contains(destination.id), destination.isConfigured else { return }
                    guard self.lastSentStatuses[destination.id] != next else {
                        self.eventLog.append(.send, "send \(destination.displayName): skipped as duplicate")
                        return
                    }
                    do {
                        let outcome = try await destination.publish(next)
                        guard self.revisions[destination.id] == revision else { return }
                        self.eventLog.append(.send, "send \(destination.displayName): \(outcome == .sent ? "sent" : "skipped as duplicate")")
                        self.lastSentStatuses[destination.id] = next
                        if case .sent = outcome {
                            self.lastSentDates[destination.id] = Date()
                            self.defaults.set(self.lastSentDates, forKey: "Whereabouts.destinationStatusDates")
                        }
                        self.lastErrors[destination.id] = nil
                        if let data = try? JSONEncoder().encode(self.lastSentStatuses) {
                            self.defaults.set(data, forKey: Self.lastStatusKey)
                        }
                    } catch {
                        guard self.revisions[destination.id] == revision else { return }
                        self.eventLog.sendError(destination: destination.displayName, error: error)
                        self.lastErrors[destination.id] = error.localizedDescription
                    }
                }
            }
            for task in tasks { await task.value }
        }
    }
}

@MainActor
final class BackgroundLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Update location status") { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
