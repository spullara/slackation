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

    func publish(_ status: LocationStatus) async throws -> PublishOutcome {
        // Compare only the fields Slack receives; generic metadata remains in the engine.
        let legacyKey = "Slackation.lastSuccessfulStatus"
        let payloadKey = "Slackation.slackSuccessfulPayload"
        let saved = defaults.dictionary(forKey: payloadKey) ?? defaults.dictionary(forKey: legacyKey)
        let isDuplicate = saved?["text"] as? String == status.text && saved?["emoji"] as? String == status.emoji
        if !isDuplicate {
            try await client.setStatus(text: status.text, emoji: status.emoji)
        }
        defaults.set(["text": status.text, "emoji": status.emoji], forKey: payloadKey)
        defaults.removeObject(forKey: legacyKey)
        return isDuplicate ? .skippedDuplicate : .sent
    }
}
