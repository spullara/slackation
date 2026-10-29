import Foundation
import Observation

@MainActor
@Observable
final class DestinationRegistry {
    private(set) var destinations: [any StatusDestination]
    private(set) var enabledIDs: Set<String>
    private let defaults: UserDefaults
    private static let settingsKey = "Whereabouts.enabledDestinations"

    init(destinations: [any StatusDestination], defaults: UserDefaults = .standard) {
        precondition(Set(destinations.map(\.id)).count == destinations.count, "Destination IDs must be unique")
        self.destinations = destinations
        self.defaults = defaults
        enabledIDs = Set(defaults.stringArray(forKey: Self.settingsKey) ?? destinations.map(\.id))
    }

    var enabledDestinations: [any StatusDestination] {
        destinations.filter { enabledIDs.contains($0.id) }
    }

    func replaceWebhooks(_ webhooks: [WebhookConfiguration], secrets: any WebhookSecretStore) {
        destinations.removeAll { $0 is WebhookDestination }
        enabledIDs = enabledIDs.filter { !$0.hasPrefix("webhook.") }
        for webhook in webhooks {
            destinations.append(WebhookDestination(configuration: webhook, secrets: secrets))
            if webhook.enabled { enabledIDs.insert(webhook.destinationID) }
        }
        defaults.set(enabledIDs.sorted(), forKey: Self.settingsKey)
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard destinations.contains(where: { $0.id == id }) else { return }
        if enabled { enabledIDs.insert(id) } else { enabledIDs.remove(id) }
        defaults.set(enabledIDs.sorted(), forKey: Self.settingsKey)
    }
}
