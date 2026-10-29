import Foundation
import Observation

struct WebhookConfiguration: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var url = ""
    var enabled = true
    var hasSecret = false
    var destinationID: String { "webhook.\(id.uuidString)" }

    func validatedURL() throws -> URL {
        guard let parts = URLComponents(string: url), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.fragment == nil, let result = parts.url else { throw WebhookError.invalidURL }
        return result
    }
}

protocol WebhookSecretStore {
    func read(id: UUID) throws -> String?
    func save(_ secret: String, id: UUID) throws
    func delete(id: UUID) throws
}

struct KeychainWebhookSecrets: WebhookSecretStore {
    private func store(_ id: UUID) -> KeychainTokenStore {
        KeychainTokenStore(service: "com.whereabouts.webhook-secret", account: id.uuidString)
    }
    func read(id: UUID) throws -> String? { try store(id).read() }
    func save(_ secret: String, id: UUID) throws { try store(id).save(secret) }
    func delete(id: UUID) throws { try store(id).delete() }
}

@MainActor
@Observable
final class WebhookStore {
    private(set) var configurations: [WebhookConfiguration] = []
    private let fileURL: URL
    let secrets: any WebhookSecretStore

    init(fileURL: URL? = nil, secrets: any WebhookSecretStore = KeychainWebhookSecrets()) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whereabouts/webhooks.json")
        self.secrets = secrets
    }

    func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let saved = try JSONDecoder().decode([WebhookConfiguration].self, from: Data(contentsOf: fileURL))
        for item in saved { _ = try item.validatedURL() }
        guard Set(saved.map(\.id)).count == saved.count else { throw WebhookError.invalidConfiguration }
        configurations = saved
    }

    func save(_ configuration: WebhookConfiguration, secret: String?) throws {
        var configuration = configuration
        _ = try configuration.validatedURL()
        guard !configuration.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebhookError.invalidConfiguration
        }
        let existing = configurations.first { $0.id == configuration.id }
        let oldSecret = try existing?.hasSecret == true ? secrets.read(id: configuration.id) : nil
        configuration.hasSecret = secret.map { !$0.isEmpty } ?? existing?.hasSecret ?? false
        var next = configurations
        if let index = next.firstIndex(where: { $0.id == configuration.id }) { next[index] = configuration }
        else { next.append(configuration) }
        if let secret {
            if secret.isEmpty {
                if existing?.hasSecret == true { try secrets.delete(id: configuration.id) }
            } else { try secrets.save(secret, id: configuration.id) }
        }
        do { try persist(next) }
        catch {
            if let oldSecret { try? secrets.save(oldSecret, id: configuration.id) }
            else { try? secrets.delete(id: configuration.id) }
            throw error
        }
    }

    func delete(_ configuration: WebhookConfiguration) throws {
        let oldSecret = try configuration.hasSecret ? secrets.read(id: configuration.id) : nil
        if configuration.hasSecret { try secrets.delete(id: configuration.id) }
        do { try persist(configurations.filter { $0.id != configuration.id }) }
        catch {
            if let oldSecret { try? secrets.save(oldSecret, id: configuration.id) }
            throw error
        }
    }

    private func persist(_ next: [WebhookConfiguration]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
        configurations = next
    }
}
