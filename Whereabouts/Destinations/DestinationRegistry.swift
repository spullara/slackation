import Foundation
import Observation

@MainActor
@Observable
final class DestinationRegistry {
    let destinations: [any StatusDestination]
    private(set) var enabledIDs: Set<String>
    private let defaults: UserDefaults
    private static let settingsKey = "Slackation.enabledDestinations"

    init(destinations: [any StatusDestination], defaults: UserDefaults = .standard) {
        precondition(Set(destinations.map(\.id)).count == destinations.count, "Destination IDs must be unique")
        self.destinations = destinations
        self.defaults = defaults
        enabledIDs = Set(defaults.stringArray(forKey: Self.settingsKey) ?? destinations.map(\.id))
    }

    var enabledDestinations: [any StatusDestination] {
        destinations.filter { enabledIDs.contains($0.id) }
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard destinations.contains(where: { $0.id == id }) else { return }
        if enabled { enabledIDs.insert(id) } else { enabledIDs.remove(id) }
        defaults.set(enabledIDs.sorted(), forKey: Self.settingsKey)
    }
}
