import Foundation

@MainActor
struct SlackDestination: StatusDestination {
    let id = "slack"
    let displayName = "Slack"
    private let defaults: UserDefaults
    private let client: SlackClient
    private let tokenProvider: () throws -> String?

    init(defaults: UserDefaults = .standard, session: URLSession = URLSession(configuration: .ephemeral),
         tokenProvider: @escaping () throws -> String? = { try KeychainTokenStore().read() }) {
        self.defaults = defaults
        self.tokenProvider = tokenProvider
        client = SlackClient(session: session, tokenProvider: tokenProvider)
    }

    var isConfigured: Bool {
        guard let token = try? tokenProvider() else { return false }
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func publish(_ status: LocationStatus) async throws {
        // Consume the success record from the original single-destination engine.
        let legacyKey = "Slackation.lastSuccessfulStatus"
        let legacy = defaults.dictionary(forKey: legacyKey)
        if legacy?["text"] as? String != status.text || legacy?["emoji"] as? String != status.emoji {
            try await client.setStatus(text: status.text, emoji: status.emoji)
        }
        defaults.removeObject(forKey: legacyKey)
    }
}
