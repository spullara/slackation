import Foundation
import CryptoKit

enum WebhookError: Error, LocalizedError {
    case invalidURL, invalidConfiguration, invalidResponse, missingSecret, transport, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter an HTTPS URL without a username, password, or fragment."
        case .invalidConfiguration: "Enter a name for each webhook with a unique ID."
        case .invalidResponse: "The webhook returned an invalid response."
        case .missingSecret: "The signing secret is missing. Save the secret again."
        case .transport: "The webhook request failed. Check the connection and URL."
        case .http(let code): "Webhook returned HTTP \(code)."
        }
    }
}

// Do not forward location data or signatures to a redirected endpoint.
private final class WebhookRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
struct WebhookDestination: StatusDestination {
    private static let defaultSession = URLSession(configuration: .ephemeral, delegate: WebhookRedirectPolicy(), delegateQueue: nil)
    let configuration: WebhookConfiguration
    let secrets: any WebhookSecretStore
    private let session: URLSession
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void
    var id: String { configuration.destinationID }
    var displayName: String { configuration.name }
    var isConfigured: Bool { (try? configuration.validatedURL()) != nil }

    init(configuration: WebhookConfiguration, secrets: any WebhookSecretStore,
         session: URLSession? = nil, now: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.configuration = configuration
        self.secrets = secrets
        self.session = session ?? Self.defaultSession
        self.now = now
        self.sleep = sleep
    }

    func publish(_ status: LocationStatus) async throws -> PublishOutcome {
        _ = try await send(status, event: "status.changed")
        return .sent // StatusEngine owns persistent per-destination deduplication.
    }

    func sendTest(_ status: LocationStatus) async throws -> Int { try await send(status, event: "test") }

    static func signature(body: Data, secret: String) -> String {
        let digest = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
        return "sha256=" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func send(_ status: LocationStatus, event: String) async throws -> Int {
        let timestamp = ISO8601DateFormatter().string(from: now())
        let payload: [String: Any] = [
            "version": 1, "event": event, "kind": status.kind.rawValue,
            "location": status.locationName, "geofenceId": status.geofenceID?.uuidString as Any? ?? NSNull(),
            "text": status.text, "emoji": status.displayEmoji, "emojiShortcode": status.emoji, "timestamp": timestamp
        ]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        var request = URLRequest(url: try configuration.validatedURL(), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if configuration.hasSecret {
            guard let secret = try secrets.read(id: configuration.id), !secret.isEmpty else {
                throw WebhookError.missingSecret
            }
            request.setValue(Self.signature(body: body, secret: secret), forHTTPHeaderField: "X-Whereabouts-Signature")
            request.setValue(timestamp, forHTTPHeaderField: "X-Whereabouts-Timestamp")
        }
        for attempt in 0...1 {
            let response: URLResponse
            do { (_, response) = try await session.data(for: request) }
            catch is CancellationError { throw CancellationError() }
            catch { throw WebhookError.transport }
            guard let http = response as? HTTPURLResponse else { throw WebhookError.invalidResponse }
            if (200..<300).contains(http.statusCode) { return http.statusCode }
            if attempt == 0 && (http.statusCode == 429 || (500..<600).contains(http.statusCode)) {
                try await sleep(retryDelay(http.value(forHTTPHeaderField: "Retry-After")))
                continue
            }
            throw WebhookError.http(http.statusCode)
        }
        throw WebhookError.invalidResponse
    }

    private func retryDelay(_ header: String?) -> TimeInterval {
        guard let header else { return 1 }
        if let seconds = Double(header), seconds.isFinite { return min(30, max(0, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        guard let date = formatter.date(from: header) else { return 1 }
        return min(30, max(0, date.timeIntervalSince(now())))
    }
}
