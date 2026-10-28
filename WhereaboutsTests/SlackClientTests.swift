import XCTest
import Security
@testable import Slackation

final class SlackClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlackMockProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        SlackMockProtocol.handler = nil
        super.tearDown()
    }

    func testValidateTokenReturnsIdentity() async throws {
        SlackMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://slack.com/api/auth.test")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer xoxp-test")
            return (200, [:], #"{"ok":true,"user":"sam","team":"Workspace"}"#)
        }
        let identity = try await client().validateToken()
        XCTAssertEqual(identity, SlackIdentity(user: "sam", team: "Workspace"))
    }

    func testSetStatusBodyAndHeaders() async throws {
        SlackMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/users.profile.set")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer xoxp-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let profile = try XCTUnwrap(body["profile"] as? [String: Any])
            XCTAssertEqual(profile["status_text"] as? String, "At \"work\" 🏢")
            XCTAssertEqual(profile["status_emoji"] as? String, ":office:")
            XCTAssertEqual(profile["status_expiration"] as? Int, 0)
            XCTAssertNil(body["token"])
            return (200, [:], #"{"ok":true}"#)
        }
        try await client().setStatus(text: "At \"work\" 🏢", emoji: ":office:")
    }

    func testSlackErrors() async throws {
        for code in ["invalid_auth", "missing_scope"] {
            SlackMockProtocol.handler = { _ in (200, [:], "{\"ok\":false,\"error\":\"\(code)\"}") }
            do {
                try await client().setStatus(text: "Away", emoji: ":walking:")
                XCTFail("Expected Slack error")
            } catch { XCTAssertEqual(error as? SlackClientError, .api(code)) }
        }
    }

    func testRateLimitRetriesOnceAfterSpecifiedDelay() async throws {
        var calls = 0
        var delays: [TimeInterval] = []
        SlackMockProtocol.handler = { _ in
            calls += 1
            return calls == 1 ? (429, ["Retry-After": "3"], "") : (200, [:], #"{"ok":true}"#)
        }
        let client = SlackClient(session: session, tokenProvider: { "xoxp-test" }, sleep: { delays.append($0) })
        try await client.setStatus(text: "Away", emoji: ":walking:")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(delays, [3])
    }

    func testSecondRateLimitStopsRetrying() async throws {
        var calls = 0
        SlackMockProtocol.handler = { _ in
            calls += 1
            return (429, ["Retry-After": "2"], "")
        }
        let client = SlackClient(session: session, tokenProvider: { "xoxp-test" }, sleep: { _ in })
        do {
            try await client.setStatus(text: "Away", emoji: ":walking:")
            XCTFail("Expected rate limit")
        } catch { XCTAssertEqual(error as? SlackClientError, .rateLimited(retryAfter: 2)) }
        XCTAssertEqual(calls, 2)
    }

    func testInvalidRetryHeaderDoesNotRetry() async throws {
        var calls = 0
        SlackMockProtocol.handler = { _ in
            calls += 1
            return (429, ["Retry-After": "invalid"], "")
        }
        do {
            try await client().setStatus(text: "Away", emoji: ":walking:")
            XCTFail("Expected rate limit")
        } catch { XCTAssertEqual(error as? SlackClientError, .rateLimited(retryAfter: nil)) }
        XCTAssertEqual(calls, 1)
    }

    func testHTTPAndMalformedResponseErrors() async throws {
        for (status, body, expected) in [(503, "", SlackClientError.http(503)), (200, "not JSON", .invalidResponse)] {
            SlackMockProtocol.handler = { _ in (status, [:], body) }
            do {
                _ = try await client().validateToken()
                XCTFail("Expected response error")
            } catch { XCTAssertEqual(error as? SlackClientError, expected) }
        }
    }

    func testMissingTokenDoesNotSendRequest() async throws {
        SlackMockProtocol.handler = { _ in
            XCTFail("Unexpected request")
            return (200, [:], "")
        }
        do {
            _ = try await SlackClient(session: session, tokenProvider: { nil }).validateToken()
            XCTFail("Expected missing token")
        } catch { XCTAssertEqual(error as? SlackClientError, .missingToken) }
    }

    func testKeychainRoundTripUpdateAndDelete() throws {
        let store = KeychainTokenStore(service: "com.slackation.tests.\(UUID().uuidString)")
        defer { try? store.delete() }
        do {
            let token = try store.read()
            XCTAssertNil(token)
        } catch let error as KeychainTokenStore.StoreError where error.status == errSecMissingEntitlement {
            throw XCTSkip("Unsigned simulator runner has no Keychain entitlement. Run this test with signing enabled.")
        }
        try store.save("xoxp-first")
        XCTAssertEqual(try store.read(), "xoxp-first")
        try store.save("xoxp-second")
        XCTAssertEqual(try store.read(), "xoxp-second")
        try store.delete()
        XCTAssertNil(try store.read())
        XCTAssertNoThrow(try store.delete())
    }

    @MainActor
    func testDestinationDedupesPayloadAcrossMetadataChangesAndRecreation() async throws {
        let suite = "SlackDestinationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var requests = 0
        var fail = false
        SlackMockProtocol.handler = { _ in
            requests += 1
            return (200, [:], fail ? #"{"ok":false,"error":"invalid_auth"}"# : #"{"ok":true}"#)
        }
        func engine() -> StatusEngine {
            let destination = SlackDestination(defaults: defaults, session: session, tokenProvider: { "xoxp-test" })
            return StatusEngine(registry: DestinationRegistry(destinations: [destination], defaults: defaults), defaults: defaults)
        }
        let a = LocationStatus(locationName: "A", text: "Busy", emoji: ":office:", isOther: false)
        var b = a
        b.locationName = "B"
        let first = engine()
        await first.update(a)
        let firstSentDate = try XCTUnwrap(first.lastSentDates["slack"])
        await first.update(b)
        XCTAssertEqual(first.lastSentDates["slack"], firstSentDate, "Metadata changes do not send a payload")
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(first.lastSentStatuses["slack"], b)
        let recreated = engine()
        var other = b
        other.locationName = "Other"
        other.isOther = true
        await recreated.update(other)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(recreated.lastSentStatuses["slack"], other)
        XCTAssertEqual(recreated.lastSentDates["slack"], firstSentDate, "A duplicate preserves the saved send time")
        var changed = other
        changed.text = "Away"
        fail = true
        await recreated.update(changed)
        XCTAssertEqual(requests, 2)
        XCTAssertNotNil(recreated.lastErrors["slack"])
        XCTAssertEqual(recreated.lastSentDates["slack"], firstSentDate, "Failure does not advance the send time")
        XCTAssertEqual(engine().lastSentDates["slack"], firstSentDate)
        fail = false
        let retry = engine()
        await retry.update(changed)
        let retrySentDate = try XCTUnwrap(retry.lastSentDates["slack"])
        XCTAssertGreaterThan(retrySentDate, firstSentDate, "A real successful send advances the time")
        XCTAssertEqual(engine().lastSentDates["slack"], retrySentDate)
        XCTAssertEqual(requests, 3, "A failed payload must remain eligible after recreation")
        await engine().update(a)
        XCTAssertEqual(requests, 4, "Returning to an older payload must publish again")
    }

    private func client() -> SlackClient { SlackClient(token: "xoxp-test", session: session) }
}

private final class SlackMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, headers, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
