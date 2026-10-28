import Foundation

struct LocationStatus: Codable, Equatable, Sendable {
    var locationName: String
    var text: String
    var emoji: String
    var isOther: Bool
}

enum PublishOutcome {
    case sent
    case skippedDuplicate
}

@MainActor
protocol StatusDestination {
    var id: String { get }
    var displayName: String { get }
    var isConfigured: Bool { get }
    func publish(_ status: LocationStatus) async throws -> PublishOutcome
}
