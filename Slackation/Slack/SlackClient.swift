import Foundation

struct SlackIdentity: Equatable, Sendable {
    let user: String
    let team: String
}

enum SlackClientError: Error, Equatable, LocalizedError {
    case missingToken
    case invalidResponse
    case http(Int)
    case api(String)
    case rateLimited(retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .missingToken: return "Add a Slack user token in Settings."
        case .invalidResponse: return "Slack returned an invalid response."
        case .http(let code): return "Slack request failed (HTTP \(code))."
        case .api(let code):
            switch code {
            case "invalid_auth", "token_revoked", "account_inactive":
                return "Slack rejected the token. Add a valid user token."
            case "missing_scope": return "The token needs the users.profile:write scope."
            default: return "Slack could not complete the request."
            }
        case .rateLimited: return "Slack received too many requests. Try again later."
        }
    }
}

struct SlackClient {
    private let session: URLSession
    private let tokenProvider: () throws -> String?
    private let sleep: (TimeInterval) async throws -> Void

    init(session: URLSession = URLSession(configuration: .ephemeral),
         tokenProvider: @escaping () throws -> String? = { try KeychainTokenStore().read() },
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.session = session
        self.tokenProvider = tokenProvider
        self.sleep = sleep
    }

    init(token: String, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.init(session: session, tokenProvider: { token })
    }

    func validateToken() async throws -> SlackIdentity {
        let response = try await request(method: "auth.test", body: [:])
        guard let user = response.user, let team = response.team else {
            throw SlackClientError.invalidResponse
        }
        return SlackIdentity(user: user, team: team)
    }

    func setStatus(text: String, emoji: String) async throws {
        _ = try await request(method: "users.profile.set", body: [
            "profile": ["status_text": text, "status_emoji": emoji, "status_expiration": 0]
        ])
    }

    private func request(method: String, body: [String: Any]) async throws -> Response {
        guard let token = try tokenProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw SlackClientError.missingToken
        }
        var request = URLRequest(url: URL(string: "https://slack.com/api/\(method)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        for attempt in 0...1 {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SlackClientError.invalidResponse }
            if http.statusCode == 429 {
                let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                let delay = seconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                guard attempt == 0, let delay else { throw SlackClientError.rateLimited(retryAfter: delay) }
                try await sleep(delay)
                continue
            }
            guard (200..<300).contains(http.statusCode) else { throw SlackClientError.http(http.statusCode) }
            guard let result = try? JSONDecoder().decode(Response.self, from: data) else {
                throw SlackClientError.invalidResponse
            }
            guard result.ok else { throw SlackClientError.api(result.error ?? "unknown_error") }
            return result
        }
        throw SlackClientError.rateLimited(retryAfter: nil)
    }

    private struct Response: Decodable {
        let ok: Bool
        let error: String?
        let user: String?
        let team: String?
    }
}
