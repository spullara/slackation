import Observation
import UIKit

@MainActor
@Observable
final class StatusEngine {
    private(set) var lastSentStatus: ResolvedStatus?
    private(set) var lastError: String?
    private(set) var isSending = false
    private let client: any SlackStatusSetting
    private var pending: ResolvedStatus?
    private let defaults: UserDefaults
    private static let lastStatusKey = "Slackation.lastSuccessfulStatus"

    init(client: any SlackStatusSetting, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        if let saved = defaults.dictionary(forKey: Self.lastStatusKey),
           let text = saved["text"] as? String, let emoji = saved["emoji"] as? String {
            lastSentStatus = ResolvedStatus(text: text, emoji: emoji)
        }
    }

    /// Serializes requests. While a request runs, only the latest desired status is retained.
    func update(_ status: ResolvedStatus) async {
        pending = status
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }
        let lease = BackgroundLease()
        defer { lease.end() }
        while let next = pending {
            pending = nil
            guard next != lastSentStatus else { continue }
            do {
                try await client.setStatus(text: next.text, emoji: next.emoji)
                defaults.set(["text": next.text, "emoji": next.emoji], forKey: Self.lastStatusKey)
                lastSentStatus = next
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                // A later event can retry a failed status; failures do not enter the dedupe cache.
            }
        }
    }
}

@MainActor
private final class BackgroundLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Update Slack status") { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
