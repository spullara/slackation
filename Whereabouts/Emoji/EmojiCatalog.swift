import Foundation

struct EmojiEntry: Codable, Identifiable {
    let unicode: String
    let shortcode: String
    let aliases: [String]
    let name: String
    let category: String
    var id: String { shortcode }

    func matches(_ query: String) -> Bool {
        query.isEmpty || unicode.contains(query) || name.localizedCaseInsensitiveContains(query)
            || aliases.contains { $0.localizedCaseInsensitiveContains(query.replacingOccurrences(of: ":", with: "")) }
    }
}

enum EmojiCatalog {
    static let entries: [EmojiEntry] = {
        guard let url = Bundle.main.url(forResource: "EmojiCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([EmojiEntry].self, from: data) else { return [] }
        return entries
    }()
    static let categories: [String] = entries.reduce(into: []) { result, entry in
        if !result.contains(entry.category) { result.append(entry.category) }
    }
    private static let byShortcode: [String: EmojiEntry] = entries.reduce(into: [:]) { result, entry in
        for alias in entry.aliases { result[":" + alias + ":"] = entry }
    }

    static func unicode(for shortcode: String) -> String? { byShortcode[shortcode]?.unicode }

    static func customShortcode(_ input: String) -> String? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard !name.isEmpty, name.range(of: "^[A-Za-z0-9_+\\-]+$", options: .regularExpression) != nil else { return nil }
        return ":" + name + ":"
    }
}
