import XCTest
import CoreLocation
@testable import Whereabouts

final class EventLogTests: XCTestCase {
    private func file() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("events.jsonl")
    }

    @MainActor
    func testAppendTrimsCountAndKeepsNewestFirst() throws {
        let url = file()
        let log = EventLog(url: url)
        for index in 0...1000 { log.append(.app, "event \(index)") }
        XCTAssertEqual(log.events.count, 1000)
        XCTAssertEqual(log.events.first?.text, "event 1000")
        XCTAssertEqual(log.events.last?.text, "event 1")
        XCTAssertEqual(try String(contentsOf: url).split(separator: "\n").count, 1000)
    }

    @MainActor
    func testTrimAge() {
        var now = Date(timeIntervalSince1970: 2_000_000)
        let url = file()
        let log = EventLog(url: url, now: { now })
        log.append(.app, "old")
        now += 7 * 86400
        log.append(.app, "new")
        XCTAssertEqual(log.events.count, 2)
        now += 1
        log.prune()
        XCTAssertEqual(log.events.map(\.text), ["new"])
        XCTAssertEqual(EventLog(url: url, now: { now }).events.map(\.text), ["new"])
    }

    @MainActor
    func testPersistenceAcrossReload() {
        let url = file()
        let log = EventLog(url: url)
        log.append(.app, "first")
        log.append(.driving, "second")
        let reloaded = EventLog(url: url)
        XCTAssertEqual(reloaded.events.map(\.id), log.events.map(\.id))
        reloaded.clear()
        XCTAssertTrue(EventLog(url: url).events.isEmpty)
    }

    @MainActor
    func testExportTextFormat() {
        let log = EventLog(url: file(), now: { Date(timeIntervalSince1970: 0) })
        log.append(.app, "app launch: foreground\nnext line")
        XCTAssertEqual(log.exportText(), "1970-01-01T00:00:00Z [app] app launch: foreground next line")
    }

    @MainActor
    func testSendErrorDoesNotPersistSecrets() async throws {
        let url = file()
        let log = EventLog(url: url)
        let destination = LogDestination()
        destination.error = NSError(domain: "secret-domain", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Bearer xoxp-private-token https://example.com?secret=private-secret 37.123,-122.456"])
        let defaults = makeDefaults()
        let engine = StatusEngine(registry: DestinationRegistry(destinations: [destination], defaults: defaults), defaults: defaults, eventLog: log)
        await engine.update(LocationStatus(locationName: "Other", text: "Other", emoji: "", isOther: true))
        XCTAssertEqual(log.events.first?.text, "send Test: error — Destination request failed.")
        let persisted = try String(contentsOf: url)
        for secret in ["xoxp", "private-secret", "secret-domain", "37.123", "example.com"] {
            XCTAssertFalse(persisted.contains(secret))
            XCTAssertFalse(log.exportText().contains(secret))
        }
    }

    @MainActor
    func testDrivingStartResolvesAndSendsInOrder() async throws {
        let log = EventLog(url: file())
        let source = LogMotionSource()
        let defaults = makeDefaults()
        let motion = DrivingMonitor(source: source, defaults: defaults, locationSource: LogLocationSource(), eventLog: log)
        let destination = LogDestination()
        let store = GeofenceStore(fileURL: file())
        let runtime = LocationRuntime(store: store, driving: motion,
            destinations: DestinationRegistry(destinations: [destination], defaults: defaults), defaults: defaults, eventLog: log)
        runtime.refreshMonitoring()
        let deadline = Date().addingTimeInterval(3)
        while !log.events.contains(where: { $0.kind == .send }) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let relevant = log.events.reversed().filter { [.driving, .status, .send].contains($0.kind) }
        XCTAssertEqual(relevant.prefix(3).map(\.kind), [.driving, .status, .send])
        XCTAssertEqual(relevant.first?.text, "driving start: high confidence")
        XCTAssertTrue(relevant.dropFirst().first?.text.contains("status resolved: Driving") == true)
        XCTAssertEqual(relevant.dropFirst(2).first?.text, "send Test: sent")
        motion.setEnabled(false)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "EventLogTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}

@MainActor
private final class LogDestination: StatusDestination {
    let id = "test"
    let displayName = "Test"
    let isConfigured = true
    var error: Error?
    func publish(_ status: LocationStatus) async throws -> PublishOutcome {
        if let error { throw error }
        return .sent
    }
}

@MainActor
private final class LogMotionSource: MotionActivitySource {
    let available = true
    let denied = false
    func start(_ receive: @escaping ([MotionSample]) -> Void) {}
    func stop() {}
    func history(from: Date, to: Date) async throws -> [MotionSample] {
        [MotionSample(date: to, activity: .automotive, confidence: .high)]
    }
}

@MainActor
private final class LogLocationSource: DrivingLocationSource {
    var onActiveChange: ((Bool) -> Void)?
    func start(_ receive: @escaping ([CLLocation]) -> Void) { onActiveChange?(true) }
    func stop() { onActiveChange?(false) }
}
