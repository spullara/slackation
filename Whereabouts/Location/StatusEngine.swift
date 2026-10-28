import Observation
import UIKit

@MainActor
@Observable
final class StatusEngine {
    private(set) var lastSentStatuses: [String: LocationStatus] = [:]
    private(set) var lastSentDates: [String: Date] = [:]
    private(set) var lastErrors: [String: String] = [:]
    private(set) var isSending = false
    private let registry: DestinationRegistry
    private var pending: LocationStatus?
    private let defaults: UserDefaults
    private static let lastStatusKey = "Whereabouts.destinationStatuses"

    init(registry: DestinationRegistry, defaults: UserDefaults = .standard) {
        self.registry = registry
        self.defaults = defaults
        lastSentDates = defaults.dictionary(forKey: "Whereabouts.destinationStatusDates") as? [String: Date] ?? [:]
        if let data = defaults.data(forKey: Self.lastStatusKey),
           let saved = try? JSONDecoder().decode([String: LocationStatus].self, from: data) {
            lastSentStatuses = saved
        }
    }

    /// Serializes events and retains only the latest pending status.
    /// Destinations publish concurrently, with independent success and error state.
    func update(_ status: LocationStatus) async {
        pending = status
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }
        let lease = BackgroundLease()
        defer { lease.end() }
        while let next = pending {
            pending = nil
            let tasks = registry.enabledDestinations.map { destination in
                Task { @MainActor in
                    guard destination.isConfigured else { return }
                    guard self.lastSentStatuses[destination.id] != next else { return }
                    do {
                        let outcome = try await destination.publish(next)
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
                        self.lastErrors[destination.id] = error.localizedDescription
                    }
                }
            }
            for task in tasks { await task.value }
        }
    }
}

@MainActor
private final class BackgroundLease {
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
