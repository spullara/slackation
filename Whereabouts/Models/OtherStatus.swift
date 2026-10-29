import Foundation

struct OtherStatus: Codable, Equatable, Sendable {
    var text: String
    var emoji: String
    var emojiUnicode: String?

    init(text: String = "Other", emoji: String = ":globe_with_meridians:", emojiUnicode: String? = nil) {
        self.text = text
        self.emoji = emoji
        self.emojiUnicode = emojiUnicode ?? EmojiCatalog.unicode(for: emoji)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decode(String.self, forKey: .text)
        emoji = try values.decode(String.self, forKey: .emoji)
        emojiUnicode = try values.decodeIfPresent(String.self, forKey: .emojiUnicode) ?? EmojiCatalog.unicode(for: emoji)
    }
}
