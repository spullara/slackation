import XCTest
@testable import Slackation

final class LocationTests: XCTestCase {
    func testResolverNoneOneAndOverlap() {
        let large = place(radius: 300, text: "Office")
        let small = place(radius: 100, text: "Desk")
        let other = OtherStatus()
        XCTAssertEqual(StatusResolver.resolve(geofences: [large, small], insideIDs: [], other: other),
                       ResolvedStatus(text: other.text, emoji: other.emoji))
        XCTAssertEqual(StatusResolver.resolve(geofences: [large, small], insideIDs: [large.id], other: other).text, "Office")
        XCTAssertEqual(StatusResolver.resolve(geofences: [large, small], insideIDs: [large.id, small.id], other: other).text, "Desk")
    }

    func testEqualRadiusHasStableTieBreak() {
        let a = place(radius: 100, text: "A")
        let b = place(radius: 100, text: "B")
        let ids: Set<UUID> = [a.id, b.id]
        XCTAssertEqual(StatusResolver.resolve(geofences: [a, b], insideIDs: ids, other: OtherStatus()),
                       StatusResolver.resolve(geofences: [b, a], insideIDs: ids, other: OtherStatus()))
    }

    @MainActor
    func testEngineDedupeAndChanges() async {
        let client = FakeSlack()
        let engine = StatusEngine(client: client, defaults: isolatedDefaults())
        let first = ResolvedStatus(text: "Office", emoji: ":office:")
        let second = ResolvedStatus(text: "Other", emoji: ":earth_africa:")
        await engine.update(first)
        await engine.update(first)
        await engine.update(second)
        await engine.update(second)
        XCTAssertEqual(client.calls, [first, second])
        XCTAssertEqual(engine.lastSentStatus, second)
        XCTAssertNil(engine.lastError)
    }

    @MainActor
    func testFailureIsKeptAndCanRetry() async {
        let client = FakeSlack()
        let engine = StatusEngine(client: client, defaults: isolatedDefaults())
        let status = ResolvedStatus(text: "Office", emoji: ":office:")
        client.shouldFail = true
        await engine.update(status)
        XCTAssertNotNil(engine.lastError)
        XCTAssertNil(engine.lastSentStatus)
        client.shouldFail = false
        await engine.update(status)
        XCTAssertEqual(client.calls, [status, status])
        XCTAssertEqual(engine.lastSentStatus, status)
        XCTAssertNil(engine.lastError)
    }

    @MainActor
    func testConcurrentEventsSendLatestAfterInFlightRequest() async {
        let client = FakeSlack()
        client.pauseNext = true
        let engine = StatusEngine(client: client, defaults: isolatedDefaults())
        let a = ResolvedStatus(text: "A", emoji: ":a:")
        let b = ResolvedStatus(text: "B", emoji: ":b:")
        let c = ResolvedStatus(text: "C", emoji: ":c:")
        let first = Task { await engine.update(a) }
        while client.resume == nil { await Task.yield() }
        await engine.update(b)
        await engine.update(c)
        client.resume?.resume()
        await first.value
        XCTAssertEqual(client.calls, [a, c])
        XCTAssertEqual(engine.lastSentStatus, c)
    }

    @MainActor
    func testSuccessfulStatusSurvivesEngineRecreation() async {
        let defaults = isolatedDefaults()
        let client = FakeSlack()
        let status = ResolvedStatus(text: "Office", emoji: ":office:")
        await StatusEngine(client: client, defaults: defaults).update(status)
        let recreated = StatusEngine(client: client, defaults: defaults)
        XCTAssertEqual(recreated.lastSentStatus, status)
        await recreated.update(status)
        XCTAssertEqual(client.calls, [status])
        let changed = ResolvedStatus(text: "Other", emoji: ":earth_africa:")
        await recreated.update(changed)
        XCTAssertEqual(client.calls, [status, changed])
    }

    @MainActor
    func testFailedStatusIsNotRestoredAfterEngineRecreation() async {
        let defaults = isolatedDefaults()
        let client = FakeSlack()
        client.shouldFail = true
        let status = ResolvedStatus(text: "Office", emoji: ":office:")
        await StatusEngine(client: client, defaults: defaults).update(status)
        let recreated = StatusEngine(client: client, defaults: defaults)
        XCTAssertNil(recreated.lastSentStatus)
        client.shouldFail = false
        await recreated.update(status)
        XCTAssertEqual(client.calls, [status, status])
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "LocationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func place(radius: Double, text: String) -> Geofence {
        Geofence(name: text, latitude: 0, longitude: 0, radius: radius,
                 statusText: text, statusEmoji: ":office:")
    }
}

private final class FakeSlack: SlackStatusSetting {
    var calls: [ResolvedStatus] = []
    var shouldFail = false
    var pauseNext = false
    var resume: CheckedContinuation<Void, Never>?

    func setStatus(text: String, emoji: String) async throws {
        calls.append(ResolvedStatus(text: text, emoji: emoji))
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation { resume = $0 }
        }
        if shouldFail { throw NSError(domain: "Test", code: 1) }
    }
}
