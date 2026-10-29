import Foundation

struct LocationStatus: Codable, Equatable, Sendable {
    var locationName: String
    var text: String
    var emoji: String
    var isOther: Bool
    var emojiUnicode: String?
    var displayEmoji: String { emojiUnicode ?? EmojiCatalog.unicode(for: emoji) ?? emoji }

    init(locationName: String, text: String, emoji: String, isOther: Bool, emojiUnicode: String? = nil) {
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
