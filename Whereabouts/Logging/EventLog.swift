import Foundation
import Observation

struct LogEvent: Codable, Identifiable {
    enum Kind: String, Codable {
        case app, motion, driving, liveLocation, status, geofence, send
        var icon: String {
            switch self {
            case .app: "app"
            case .motion: "figure.walk"
            case .driving: "car"
            case .liveLocation: "location.fill"
            case .status: "text.bubble"
            case .geofence: "map"
            case .send: "paperplane"
            }
        }
    }
    var id = UUID()
    let date: Date
    let kind: Kind
    let text: String
}

/// Main-actor serialization also covers background location and motion callbacks.
@MainActor
@Observable
final class EventLog {
    static let shared = EventLog()
    private(set) var events: [LogEvent] = []
    private(set) var storageError: String?
    private let url: URL
    private let now: () -> Date
    private static let maxAge: TimeInterval = 7 * 86400

    init(url: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.url = url ?? URL.applicationSupportDirectory.appendingPathComponent("Whereabouts/events.jsonl")
        self.now = now
        do {
            try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: self.url.path) {
                let data = try Data(contentsOf: self.url)
                events = data.split(separator: 10).compactMap { try? JSONDecoder().decode(LogEvent.self, from: Data($0)) }.reversed()
                prune()
            }
        } catch { storageError = "Cannot read the event log." }
    }

    func append(_ kind: LogEvent.Kind, _ text: String, at date: Date? = nil) {
        let event = LogEvent(date: date ?? now(), kind: kind,
                             text: text.components(separatedBy: .newlines).joined(separator: " "))
        events.insert(event, at: 0)
        do {
            if trim() || !FileManager.default.fileExists(atPath: url.path) { try rewrite() }
            else {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: encoded(event))
            }
            storageError = nil
        } catch { storageError = "Cannot save the event log." }
    }

    func prune() {
        guard trim() else { return }
        do { try rewrite(); storageError = nil }
        catch { storageError = "Cannot trim the event log." }
    }

    func clear() {
        do { try Data().write(to: url, options: .atomic); events = []; storageError = nil }
        catch { storageError = "Cannot clear the event log." }
    }

    func exportText() -> String {
        prune()
        let formatter = ISO8601DateFormatter()
        return events.map { "\(formatter.string(from: $0.date)) [\($0.kind.rawValue)] \($0.text)" }.joined(separator: "\n")
    }

    /// Only application-owned error text is safe. Never persist arbitrary response bodies,
    /// URLs, NSError descriptions, headers, or credentials from a destination.
    func sendError(destination: String, error: Error) {
        let message: String
        if let error = error as? SlackClientError { message = error.localizedDescription }
        else if let error = error as? WebhookError { message = error.localizedDescription }
        else if error is CancellationError { message = "Request cancelled." }
        else if let error = error as? URLError { message = "Network request failed (code \(error.code.rawValue))." }
        else { message = "Destination request failed." }
        append(.send, "send \(destination): error — \(message)")
    }

    private func trim() -> Bool {
        let count = events.count
        events = Array(events.filter { $0.date >= now().addingTimeInterval(-Self.maxAge) }.prefix(1000))
        return count != events.count
    }
    private func encoded(_ event: LogEvent) throws -> Data {
        var data = try JSONEncoder().encode(event)
        data.append(10)
        return data
    }
    private func rewrite() throws {
        var data = Data()
        for event in events.reversed() { data.append(try encoded(event)) }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
