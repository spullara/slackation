import Foundation

enum StatusKind: String, Codable, Sendable { case geofence, driving, other }

struct LocationStatus: Codable, Equatable, Sendable {
    var kind: StatusKind
    var geofenceID: UUID?
    var locationName: String
    var text: String
    var emoji: String
    var isOther: Bool
    var emojiUnicode: String?
    var displayEmoji: String { emojiUnicode ?? EmojiCatalog.unicode(for: emoji) ?? emoji }

    init(locationName: String, text: String, emoji: String, isOther: Bool, emojiUnicode: String? = nil, kind: StatusKind? = nil, geofenceID: UUID? = nil) {
        self.kind = kind ?? (isOther ? .other : .geofence)
        self.geofenceID = geofenceID
        self.locationName = locationName
        self.text = text
        self.emoji = emoji
        self.isOther = isOther
        self.emojiUnicode = emojiUnicode ?? EmojiCatalog.unicode(for: emoji)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        locationName = try values.decode(String.self, forKey: .locationName)
        text = try values.decode(String.self, forKey: .text)
        emoji = try values.decode(String.self, forKey: .emoji)
        isOther = try values.decode(Bool.self, forKey: .isOther)
        kind = try values.decodeIfPresent(StatusKind.self, forKey: .kind) ?? (isOther ? .other : .geofence)
        geofenceID = try values.decodeIfPresent(UUID.self, forKey: .geofenceID)
        emojiUnicode = try values.decodeIfPresent(String.self, forKey: .emojiUnicode) ?? EmojiCatalog.unicode(for: emoji)
    }
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
