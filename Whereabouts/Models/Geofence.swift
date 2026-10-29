import Foundation

struct Geofence: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    /// Radius in meters.
    var radius: Double
    var statusText: String
    var statusEmoji: String
    var statusEmojiUnicode: String?
    var displayEmoji: String { statusEmojiUnicode ?? EmojiCatalog.unicode(for: statusEmoji) ?? statusEmoji }

    init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double, radius: Double,
         statusText: String, statusEmoji: String, statusEmojiUnicode: String? = nil) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.statusText = statusText
        self.statusEmoji = statusEmoji
        self.statusEmojiUnicode = statusEmojiUnicode ?? EmojiCatalog.unicode(for: statusEmoji)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        latitude = try values.decode(Double.self, forKey: .latitude)
        longitude = try values.decode(Double.self, forKey: .longitude)
        radius = try values.decode(Double.self, forKey: .radius)
        statusText = try values.decode(String.self, forKey: .statusText)
        statusEmoji = try values.decode(String.self, forKey: .statusEmoji)
        statusEmojiUnicode = try values.decodeIfPresent(String.self, forKey: .statusEmojiUnicode)
            ?? EmojiCatalog.unicode(for: statusEmoji)
    }
}
