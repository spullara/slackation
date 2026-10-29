import XCTest
@testable import Whereabouts

@MainActor
final class WebhookTests: XCTestCase {
    private var session: URLSession!
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private var status: LocationStatus {
        LocationStatus(locationName: "Office", text: "At work", emoji: ":office:", isOther: false,
                       emojiUnicode: "🏢", geofenceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    }

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WebhookMockProtocol.self]
        session = URLSession(configuration: config)
    }
    override func tearDown() {
        session.invalidateAndCancel()
        WebhookMockProtocol.handler = nil
        super.tearDown()
    }

    func testBodySignatureAndTimestamp() async throws {
        let secrets = MemoryWebhookSecrets()
        var config = WebhookConfiguration(name: "Example", url: "https://example.com/hook")
        config.hasSecret = true
        try secrets.save("key", id: config.id)
        XCTAssertEqual(WebhookDestination.signature(body: Data("The quick brown fox jumps over the lazy dog".utf8), secret: "key"),
                       "sha256=f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
        let expectedID = status.geofenceID!.uuidString
        WebhookMockProtocol.handler = { request in
            let raw = Self.body(request)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
            XCTAssertEqual(Set(body.keys), ["version", "event", "kind", "location", "geofenceId", "text", "emoji", "emojiShortcode", "timestamp"])
            XCTAssertEqual(body["version"] as? Int, 1)
            XCTAssertEqual(body["event"] as? String, "status.changed")
            XCTAssertEqual(body["kind"] as? String, "geofence")
            XCTAssertEqual(body["geofenceId"] as? String, expectedID)
            XCTAssertEqual(body["location"] as? String, "Office")
            XCTAssertEqual(body["text"] as? String, "At work")
            XCTAssertEqual(body["emoji"] as? String, "🏢")
            XCTAssertEqual(body["emojiShortcode"] as? String, ":office:")
            XCTAssertEqual(body["timestamp"] as? String, "2023-11-14T22:13:20Z")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.timeoutInterval, 15)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Whereabouts-Signature"), WebhookDestination.signature(body: raw, secret: "key"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Whereabouts-Timestamp"), body["timestamp"] as? String)
            return (204, [:])
        }
        _ = try await destination(config, secrets: secrets).publish(status)
    }

    func testUnsignedTestEventAndStatusKinds() async throws {
        let config = WebhookConfiguration(name: "Example", url: "https://example.com/hook")
        for kind in [StatusKind.other, .driving] {
            WebhookMockProtocol.handler = { request in
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any])
                XCTAssertEqual(body["event"] as? String, "test")
                XCTAssertEqual(body["kind"] as? String, kind.rawValue)
                XCTAssertTrue(body["geofenceId"] is NSNull)
                XCTAssertNil(request.value(forHTTPHeaderField: "X-Whereabouts-Signature"))
                XCTAssertNil(request.value(forHTTPHeaderField: "X-Whereabouts-Timestamp"))
                return (202, [:])
            }
            let value = StatusResolver.resolve(geofences: [], insideIDs: [], other: OtherStatus(), isDriving: kind == .driving)
            let code = try await destination(config).sendTest(value)
            XCTAssertEqual(code, 202)
        }
    }

    func testHTTPResultsAndOneRetryOnly() async throws {
        for code in [200, 204, 299, 301, 400, 401, 404, 429, 500, 503, 599] {
            var calls = 0
            var delays: [TimeInterval] = []
            WebhookMockProtocol.handler = { _ in calls += 1; return (code, ["Retry-After": "90"]) }
            let config = WebhookConfiguration(name: "Example", url: "https://example.com/hook")
            let client = destination(config, sleep: { delays.append($0) })
            do {
                _ = try await client.publish(status)
                XCTAssertTrue((200..<300).contains(code))
            } catch {
                XCTAssertEqual(error.localizedDescription, "Webhook returned HTTP \(code).")
                XCTAssertFalse((200..<300).contains(code))
            }
            let retries = code == 429 || (500..<600).contains(code)
            XCTAssertEqual(calls, retries ? 2 : 1)
            XCTAssertEqual(delays, retries ? [30] : [])
        }
    }

    func testRetryRecoveryAndRetryAfterDate() async throws {
        for (header, delay) in [(nil, 1.0), ("invalid", 1.0), ("3", 3.0), ("Tue, 14 Nov 2023 22:13:25 GMT", 5.0)] as [(String?, Double)] {
            var calls = 0
            var delays: [TimeInterval] = []
            WebhookMockProtocol.handler = { _ in
                calls += 1
                return calls == 1 ? (503, header.map { ["Retry-After": $0] } ?? [:]) : (200, [:])
            }
            _ = try await destination(WebhookConfiguration(name: "Example", url: "https://example.com/hook"), sleep: { delays.append($0) }).publish(status)
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(delays, [delay])
        }
    }

    func testStoreUsesSecretStoreAndValidatesURL() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("webhooks.json")
        let secrets = MemoryWebhookSecrets()
        let store = WebhookStore(fileURL: file, secrets: secrets)
        var config = WebhookConfiguration(name: "Example", url: "https://example.com/hook")
        try store.save(config, secret: "synthetic-test-value")
        XCTAssertEqual(try secrets.read(id: config.id), "synthetic-test-value")
        XCTAssertFalse(String(data: try Data(contentsOf: file), encoding: .utf8)!.contains("synthetic-test-value"))
        let restored = WebhookStore(fileURL: file, secrets: secrets)
        try restored.load()
        XCTAssertTrue(restored.configurations[0].hasSecret)
        config.name = "Changed"
        try restored.save(config, secret: nil)
        XCTAssertEqual(try secrets.read(id: config.id), "synthetic-test-value")
        for url in ["http://example.com", "https://", "https://user:pass@example.com", "https://example.com/#fragment"] {
            var invalid = config; invalid.url = url
            XCTAssertThrowsError(try restored.save(invalid, secret: nil))
        }
        try restored.save(config, secret: "")
        XCTAssertNil(try secrets.read(id: config.id))
        try restored.save(config, secret: "replacement-test-value")
        try restored.delete(restored.configurations[0])
        XCTAssertNil(try secrets.read(id: config.id))
        try store.load()
        XCTAssertTrue(store.configurations.isEmpty)
    }

    func testMultipleWebhooksFailAndDedupeIndependently() async throws {
        let suite = "WebhookTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = WebhookConfiguration(name: "First", url: "https://example.com/first")
        let second = WebhookConfiguration(name: "Second", url: "https://example.com/second")
        var calls: [String: Int] = [:]
        var failFirst = true
        WebhookMockProtocol.handler = { request in
            let path = request.url!.path
            calls[path, default: 0] += 1
            return (path == "/first" && failFirst ? 400 : 200, [:])
        }
        let registry = DestinationRegistry(destinations: [destination(first), destination(second)], defaults: defaults)
        let engine = StatusEngine(registry: registry, defaults: defaults)
        await engine.update(status)
        XCTAssertNotNil(engine.lastErrors[first.destinationID])
        XCTAssertNil(engine.lastErrors[second.destinationID])
        XCTAssertNil(engine.lastSentDates[first.destinationID])
        let secondDate = engine.lastSentDates[second.destinationID]
        XCTAssertNotNil(secondDate)
        failFirst = false
        await engine.update(status)
        await StatusEngine(registry: registry, defaults: defaults).update(status)
        XCTAssertEqual(calls, ["/first": 2, "/second": 1])
        XCTAssertNil(engine.lastErrors[first.destinationID])
        XCTAssertEqual(engine.lastSentDates[second.destinationID], secondDate)
        engine.invalidate(destinationID: second.destinationID)
        await engine.update(status)
        XCTAssertEqual(calls, ["/first": 2, "/second": 2])
    }

    func testRegistryRestoresSwitchesAndDeletesWebhooks() {
        let suite = "WebhookRegistryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = DestinationRegistry(destinations: [], defaults: defaults)
        let first = WebhookConfiguration(name: "First", url: "https://example.com/first", enabled: false)
        let second = WebhookConfiguration(name: "Second", url: "https://example.com/second")
        registry.replaceWebhooks([first, second], secrets: MemoryWebhookSecrets())
        XCTAssertEqual(registry.destinations.count, 2)
        XCTAssertEqual(registry.enabledDestinations.map(\.id), [second.destinationID])
        registry.replaceWebhooks([first], secrets: MemoryWebhookSecrets())
        XCTAssertEqual(registry.destinations.map(\.id), [first.destinationID])
        XCTAssertTrue(registry.enabledDestinations.isEmpty)
    }

    func testMissingSecretFailsWithoutSending() async {
        var config = WebhookConfiguration(name: "Example", url: "https://example.com/hook")
        config.hasSecret = true
        WebhookMockProtocol.handler = { _ in XCTFail("Must not send unsigned"); return (200, [:]) }
        do {
            _ = try await destination(config).publish(status)
            XCTFail("Expected missing secret")
        } catch { XCTAssertEqual(error.localizedDescription, "The signing secret is missing. Save the secret again.") }
    }

    func testFailedFileSaveRestoresSecret() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let secrets = MemoryWebhookSecrets()
        let store = WebhookStore(fileURL: file.appendingPathComponent("webhooks.json"), secrets: secrets)
        let config = WebhookConfiguration(name: "Example", url: "https://example.com/hook")
        XCTAssertThrowsError(try store.save(config, secret: "synthetic-test-value"))
        XCTAssertNil(try secrets.read(id: config.id))
        XCTAssertTrue(store.configurations.isEmpty)
    }

    private func destination(_ config: WebhookConfiguration, secrets: MemoryWebhookSecrets = MemoryWebhookSecrets(),
                             sleep: @escaping (TimeInterval) async throws -> Void = { _ in }) -> WebhookDestination {
        WebhookDestination(configuration: config, secrets: secrets, session: session, now: { self.date }, sleep: sleep)
    }

    nonisolated private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class MemoryWebhookSecrets: WebhookSecretStore {
    var values: [UUID: String] = [:]
    func read(id: UUID) throws -> String? { values[id] }
    func save(_ secret: String, id: UUID) throws { values[id] = secret }
    func delete(id: UUID) throws { values[id] = nil }
}

private final class WebhookMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, headers) = try XCTUnwrap(Self.handler)(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
