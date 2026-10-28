import XCTest
@testable import Slackation

final class LocationTests: XCTestCase {
    func testResolverNoneOneAndOverlap() {
        let large = place(radius: 300, text: "Office")
        let small = place(radius: 100, text: "Desk")
        let other = OtherStatus()
        XCTAssertEqual(StatusResolver.resolve(geofences: [large, small], insideIDs: [], other: other),
                       LocationStatus(locationName: "Other", text: other.text, emoji: other.emoji, isOther: true))
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
        let client = FakeDestination()
        let engine = StatusEngine(registry: DestinationRegistry(destinations: [client], defaults: isolatedDefaults()), defaults: isolatedDefaults())
        let first = LocationStatus(locationName: "Other", text: "Office", emoji: ":office:", isOther: true)
        let second = LocationStatus(locationName: "Other", text: "Other", emoji: ":earth_africa:", isOther: true)
        await engine.update(first)
        await engine.update(first)
        await engine.update(second)
        await engine.update(second)
        XCTAssertEqual(client.calls, [first, second])
        XCTAssertEqual(engine.lastSentStatuses[client.id], second)
        XCTAssertNil(engine.lastErrors[client.id])
    }

    @MainActor
    func testFailureIsKeptAndCanRetry() async {
        let client = FakeDestination()
        let engine = StatusEngine(registry: DestinationRegistry(destinations: [client], defaults: isolatedDefaults()), defaults: isolatedDefaults())
        let status = LocationStatus(locationName: "Other", text: "Office", emoji: ":office:", isOther: true)
        client.shouldFail = true
        await engine.update(status)
        XCTAssertNotNil(engine.lastErrors[client.id])
        XCTAssertNil(engine.lastSentStatuses[client.id])
        client.shouldFail = false
        await engine.update(status)
        XCTAssertEqual(client.calls, [status, status])
        XCTAssertEqual(engine.lastSentStatuses[client.id], status)
        XCTAssertNil(engine.lastErrors[client.id])
    }

    @MainActor
    func testConcurrentEventsSendLatestAfterInFlightRequest() async {
        let client = FakeDestination()
        client.pauseNext = true
        let engine = StatusEngine(registry: DestinationRegistry(destinations: [client], defaults: isolatedDefaults()), defaults: isolatedDefaults())
        let a = LocationStatus(locationName: "Other", text: "A", emoji: ":a:", isOther: true)
        let b = LocationStatus(locationName: "Other", text: "B", emoji: ":b:", isOther: true)
        let c = LocationStatus(locationName: "Other", text: "C", emoji: ":c:", isOther: true)
        let first = Task { await engine.update(a) }
        while client.resume == nil { await Task.yield() }
        await engine.update(b)
        await engine.update(c)
        client.resume?.resume()
        await first.value
        XCTAssertEqual(client.calls, [a, c])
        XCTAssertEqual(engine.lastSentStatuses[client.id], c)
    }

    @MainActor
    func testSuccessfulStatusSurvivesEngineRecreation() async {
        let defaults = isolatedDefaults()
        let client = FakeDestination()
        let status = LocationStatus(locationName: "Other", text: "Office", emoji: ":office:", isOther: true)
        await StatusEngine(registry: DestinationRegistry(destinations: [client], defaults: isolatedDefaults()), defaults: defaults).update(status)
        let recreated = StatusEngine(registry: DestinationRegistry(destinations: [client], defaults: isolatedDefaults()), defaults: defaults)
        XCTAssertEqual(recreated.lastSentStatuses[client.id], status)
        await recreated.update(status)
        XCTAssertEqual(client.calls, [status])
        let changed = LocationStatus(locationName: "Other", text: "Other", emoji: ":earth_africa:", isOther: true)
        await recreated.update(changed)
        XCTAssertEqual(client.calls, [status, changed])
    }

    @MainActor
    func testFailedStatusIsNotRestoredAfterEngineRecreation() async {
        let defaults = isolatedDefaults()
        let client = FakeDestination()
        client.shouldFail = true
        let status = LocationStatus(locationName: "Other", text: "Office", emoji: ":office:", isOther: true)
        await StatusEngine(registry: DestinationRegistry(destinations: [client], defaults: isolatedDefaults()), defaults: defaults).update(status)
        let recreated = StatusEngine(registry: DestinationRegistry(destinations: [client], defaults: isolatedDefaults()), defaults: defaults)
        XCTAssertNil(recreated.lastSentStatuses[client.id])
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

@MainActor
private final class FakeDestination: StatusDestination {
    let id = "test"
    let displayName = "Test"
    var isConfigured = true
    var calls: [LocationStatus] = []
    var shouldFail = false
    var pauseNext = false
    var resume: CheckedContinuation<Void, Never>?

    func publish(_ status: LocationStatus) async throws {
        calls.append(status)
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation { resume = $0 }
        }
        if shouldFail { throw NSError(domain: "Test", code: 1) }
    }
}
