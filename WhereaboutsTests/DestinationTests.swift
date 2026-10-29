import XCTest
@testable import Whereabouts

@MainActor
final class DestinationTests: XCTestCase {
    func testIndependentFailureAndRelaunchDedupe() async {
        let defaults = isolatedDefaults()
        let first = TestDestination(id: "first")
        let second = TestDestination(id: "second")
        first.shouldFail = true
        let registry = DestinationRegistry(destinations: [first, second], defaults: defaults)
        let status = LocationStatus(locationName: "Office", text: "At work", emoji: ":office:", isOther: false)
        let engine = StatusEngine(registry: registry, defaults: defaults)
        await engine.update(status)
        XCTAssertEqual(first.calls, [status])
        XCTAssertEqual(second.calls, [status])
        XCTAssertNotNil(engine.lastErrors[first.id])
        XCTAssertNil(engine.lastErrors[second.id])
        XCTAssertNil(engine.lastSentStatuses[first.id])
        XCTAssertNil(engine.lastSentDates[first.id])
        XCTAssertNotNil(engine.lastSentDates[second.id])
        XCTAssertEqual(engine.lastSentStatuses[second.id], status)

        first.shouldFail = false
        let recreated = StatusEngine(registry: registry, defaults: defaults)
        XCTAssertEqual(recreated.lastSentDates[second.id], engine.lastSentDates[second.id])
        await recreated.update(status)
        XCTAssertEqual(first.calls, [status, status])
        XCTAssertEqual(second.calls, [status])
        await StatusEngine(registry: registry, defaults: defaults).update(status)
        XCTAssertEqual(first.calls.count, 2)
        XCTAssertEqual(second.calls.count, 1)
    }

    func testInvalidationDiscardsAnOldInFlightResult() async {
        let defaults = isolatedDefaults()
        let destination = TestDestination(id: "edited")
        destination.pause = true
        let registry = DestinationRegistry(destinations: [destination], defaults: defaults)
        let engine = StatusEngine(registry: registry, defaults: defaults)
        let status = LocationStatus(locationName: "Other", text: "Away", emoji: "", isOther: true)
        let task = Task { await engine.update(status) }
        while destination.resume == nil { await Task.yield() }
        engine.invalidate(destinationID: destination.id)
        destination.resume?.resume()
        await task.value
        XCTAssertNil(engine.lastSentStatuses[destination.id])
        XCTAssertNil(engine.lastSentDates[destination.id])
        destination.pause = false
        await engine.update(status)
        XCTAssertEqual(destination.calls.count, 2)
        XCTAssertEqual(engine.lastSentStatuses[destination.id], status)
    }

    func testSlowDestinationDoesNotBlockAnother() async {
        let defaults = isolatedDefaults()
        let first = TestDestination(id: "slow")
        first.pause = true
        let second = TestDestination(id: "fast")
        let registry = DestinationRegistry(destinations: [first, second], defaults: defaults)
        let engine = StatusEngine(registry: registry, defaults: defaults)
        let status = LocationStatus(locationName: "Other", text: "Away", emoji: "", isOther: true)
        let task = Task { await engine.update(status) }
        while first.resume == nil || engine.lastSentStatuses[second.id] == nil { await Task.yield() }
        XCTAssertEqual(second.calls, [status])
        first.resume?.resume()
        await task.value
        XCTAssertEqual(engine.lastSentStatuses.count, 2)
    }

    func testDisabledAndUnconfiguredDestinationsAndSettingsRestore() async {
        let defaults = isolatedDefaults()
        let first = TestDestination(id: "first")
        let second = TestDestination(id: "second")
        second.isConfigured = false
        let registry = DestinationRegistry(destinations: [first, second], defaults: defaults)
        registry.setEnabled(false, for: first.id)
        let restored = DestinationRegistry(destinations: [first, second], defaults: defaults)
        XCTAssertEqual(restored.enabledIDs, [second.id])
        let engine = StatusEngine(registry: restored, defaults: defaults)
        let status = LocationStatus(locationName: "Other", text: "Other", emoji: "", isOther: true)
        await engine.update(status)
        XCTAssertTrue(first.calls.isEmpty)
        XCTAssertTrue(second.calls.isEmpty)
        restored.setEnabled(true, for: first.id)
        await engine.update(status)
        XCTAssertEqual(first.calls, [status])
    }

    func testSlackConfigurationAndSavedSuccess() async throws {
        let defaults = isolatedDefaults()
        XCTAssertFalse(SlackDestination(defaults: defaults, tokenProvider: { "  " }).isConfigured)
        XCTAssertFalse(SlackDestination(defaults: defaults, tokenProvider: { throw NSError(domain: "test", code: 1) }).isConfigured)
        let destination = SlackDestination(defaults: defaults, tokenProvider: { "token" })
        XCTAssertTrue(destination.isConfigured)
        defaults.set(["text": "Office", "emoji": ":office:"], forKey: "Whereabouts.slackSuccessfulPayload")
        let registry = DestinationRegistry(destinations: [destination], defaults: defaults)
        let status = LocationStatus(locationName: "Office", text: "Office", emoji: ":office:", isOther: false)
        await StatusEngine(registry: registry, defaults: defaults).update(status)
        let recreated = StatusEngine(registry: registry, defaults: defaults)
        XCTAssertEqual(recreated.lastSentStatuses[destination.id], status)
        await recreated.update(status)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "DestinationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}

@MainActor
private final class TestDestination: StatusDestination {
    let id: String
    var displayName: String { id }
    var isConfigured = true
    var shouldFail = false
    var pause = false
    var resume: CheckedContinuation<Void, Never>?
    var calls: [LocationStatus] = []
    init(id: String) { self.id = id }
    func publish(_ status: LocationStatus) async throws -> PublishOutcome {
        calls.append(status)
        if pause { await withCheckedContinuation { resume = $0 } }
        if shouldFail { throw NSError(domain: "test", code: 1) }
        return .sent
    }
}
