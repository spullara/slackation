import XCTest
import CoreLocation
@testable import Whereabouts

final class DrivingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000)
    private func sample(_ seconds: Double, _ activity: MotionSample.Activity, _ confidence: MotionSample.Confidence = .high) -> MotionSample {
        MotionSample(date: start.addingTimeInterval(seconds), activity: activity, confidence: confidence)
    }
    func testHighStartsImmediatelyAndStopNeedsTwoMinutes() {
        var detector = DrivingDetector()
        XCTAssertTrue(detector.update(samples: [sample(0, .automotive)], now: start))
        XCTAssertTrue(detector.update(samples: [sample(10, .stopped)], now: start.addingTimeInterval(129)))
        XCTAssertFalse(detector.update(samples: [], now: start.addingTimeInterval(130)))
    }
    func testMediumNeedsTwoMinutesAndAutomotiveCancelsStop() {
        var detector = DrivingDetector()
        XCTAssertFalse(detector.update(samples: [sample(0, .automotive, .medium)], now: start.addingTimeInterval(119)))
        XCTAssertTrue(detector.update(samples: [], now: start.addingTimeInterval(120)))
        XCTAssertTrue(detector.update(samples: [sample(130, .stopped), sample(249, .automotive, .medium)], now: start.addingTimeInterval(250)))
        XCTAssertTrue(detector.update(samples: [], now: start.addingTimeInterval(500)))
    }
    func testUnknownAndLowCannotStartOrStop() {
        var detector = DrivingDetector()
        XCTAssertFalse(detector.update(samples: [sample(0, .automotive, .low), sample(10, .unknown)], now: start.addingTimeInterval(600)))
        XCTAssertTrue(detector.update(samples: [sample(601, .automotive), sample(602, .stopped, .low), sample(603, .unknown)], now: start.addingTimeInterval(1200)))
    }
    func testUnknownBreaksMediumEvidenceAndHistoryIsOrdered() {
        var detector = DrivingDetector()
        XCTAssertFalse(detector.update(samples: [sample(90, .unknown), sample(0, .automotive, .medium)], now: start.addingTimeInterval(300)))
        XCTAssertTrue(detector.update(samples: [sample(400, .automotive), sample(410, .stopped)], now: start.addingTimeInterval(529)))
        XCTAssertFalse(detector.update(samples: [sample(400, .automotive)], now: start.addingTimeInterval(530)))
    }
    func testResolverPriorityAndReturnToPlace() {
        let place = Geofence(name: "Office", latitude: 0, longitude: 0, radius: 100, statusText: "At work", statusEmoji: ":office:")
        let inside = StatusResolver.resolve(geofences: [place], insideIDs: [place.id], other: OtherStatus(), isDriving: true)
        XCTAssertEqual(inside.locationName, "Office")
        XCTAssertEqual(inside.geofenceID, place.id)
        let driving = StatusResolver.resolve(geofences: [place], insideIDs: [], other: OtherStatus(), isDriving: true)
        XCTAssertEqual(driving.locationName, "Driving")
        XCTAssertEqual(driving.emoji, ":car:")
        XCTAssertFalse(driving.isOther)
        XCTAssertEqual(StatusResolver.resolve(geofences: [place], insideIDs: [place.id], other: OtherStatus()).locationName, "Office")
        XCTAssertEqual(StatusResolver.resolve(geofences: [place], insideIDs: [], other: OtherStatus()).locationName, "Other")
    }
    @MainActor
    func testOffStopsMonitoringAndIgnoresLateSamples() async {
        let source = FakeMotionSource()
        let defaults = defaults()
        let monitor = DrivingMonitor(source: source, defaults: defaults)
        var locationMonitoring: [Bool] = []
        monitor.onMonitoringChange = { locationMonitoring.append($0) }
        XCTAssertTrue(monitor.enabled)
        await monitor.refresh()
        source.receive?([MotionSample(date: Date(), activity: .automotive, confidence: .high)])
        XCTAssertTrue(monitor.isDriving)
        monitor.setEnabled(false)
        source.receive?([MotionSample(date: Date().addingTimeInterval(1), activity: .automotive, confidence: .high)])
        await monitor.refresh()
        XCTAssertFalse(monitor.isDriving)
        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertEqual(source.queries, 1)
        XCTAssertGreaterThan(source.stops, 0)
        XCTAssertEqual(locationMonitoring, [true, false, false])
        XCTAssertFalse(DrivingMonitor(source: source, defaults: defaults).enabled)
    }
    @MainActor
    func testDeniedAndUnavailableFallBackAndSettingsPersist() async {
        let source = FakeMotionSource()
        let defaults = defaults()
        let monitor = DrivingMonitor(source: source, defaults: defaults)
        source.denied = true
        await monitor.refresh()
        XCTAssertNotNil(monitor.issue)
        XCTAssertFalse(monitor.isDriving)
        XCTAssertEqual(source.queries, 0)
        source.denied = false
        source.available = false
        await monitor.refresh()
        XCTAssertTrue(monitor.issue!.contains("not available"))
        let status = OtherStatus(text: "On the road", emoji: ":taxi:")
        monitor.saveStatus(status)
        XCTAssertEqual(DrivingMonitor(source: source, defaults: defaults).status, status)
    }
    @MainActor
    func testDisableDuringHistoryRejectsPendingResult() async {
        let source = FakeMotionSource()
        source.pauseHistory = true
        let monitor = DrivingMonitor(source: source, defaults: defaults())
        let refresh = Task { await monitor.refresh() }
        while source.resume == nil { await Task.yield() }
        monitor.setEnabled(false)
        source.resume?.resume(returning: [MotionSample(date: Date(), activity: .automotive, confidence: .high)])
        await refresh.value
        XCTAssertFalse(monitor.isDriving)
        XCTAssertFalse(monitor.isMonitoring)
    }

    @MainActor
    func testHistoryReplaysBeforeBufferedLiveSample() async {
        let source = FakeMotionSource()
        source.pauseHistory = true
        let monitor = DrivingMonitor(source: source, defaults: defaults())
        let refresh = Task { await monitor.refresh() }
        while source.resume == nil { await Task.yield() }
        let now = Date()
        source.receive?([MotionSample(date: now, activity: .stopped, confidence: .high)])
        source.resume?.resume(returning: [MotionSample(date: now.addingTimeInterval(-60), activity: .automotive, confidence: .high)])
        await refresh.value
        XCTAssertTrue(monitor.isDriving, "A fresh stop must retain Driving for two minutes.")
        monitor.setEnabled(false)
    }

    @MainActor
    func testRegionEntryPublishesBeforeHistoryAndDrivingEndIsDeduplicated() async throws {
        let source = FakeMotionSource()
        let motion = DrivingMonitor(source: source, defaults: defaults())
        await motion.refresh()
        source.receive?([MotionSample(date: Date().addingTimeInterval(-180), activity: .automotive, confidence: .high)])
        XCTAssertTrue(motion.isDriving)
        let (runtime, destination, region) = try runtime(motion: motion)
        await runtime.engine.update(runtime.currentStatus)
        source.pauseHistory = true
        runtime.monitor.locationManager(CLLocationManager(), didEnterRegion: region)
        await waitUntil { source.resume != nil && destination.calls.count == 2 }
        XCTAssertEqual(destination.calls.map(\.locationName), ["Driving", "Office"])
        source.resume?.resume(returning: [
            MotionSample(date: Date().addingTimeInterval(-121), activity: .stopped, confidence: .high)
        ])
        source.pauseHistory = false
        await waitUntil { !motion.isDriving }
        // Let the queued region evaluation and destination updates finish.
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(destination.calls.map(\.locationName), ["Driving", "Office"])
        motion.setEnabled(false)
    }

    @MainActor
    func testRegionExitRefreshesHistoryBeforePublishingDriving() async throws {
        let source = FakeMotionSource()
        let motion = DrivingMonitor(source: source, defaults: defaults())
        let (runtime, destination, region) = try runtime(motion: motion)
        runtime.monitor.locationManager(CLLocationManager(), didEnterRegion: region)
        await waitUntil { destination.calls.count == 1 && source.queries > 0 }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(motion.isDriving)
        source.pauseHistory = true
        runtime.monitor.locationManager(CLLocationManager(), didExitRegion: region)
        await waitUntil { source.resume != nil }
        XCTAssertEqual(destination.calls.map(\.locationName), ["Office"])
        source.resume?.resume(returning: [
            MotionSample(date: Date(), activity: .automotive, confidence: .high)
        ])
        source.pauseHistory = false
        await waitUntil { destination.calls.count == 2 }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(destination.calls.map(\.locationName), ["Office", "Driving"])
        motion.setEnabled(false)
    }

    @MainActor
    private func runtime(motion: DrivingMonitor) throws -> (LocationRuntime, RecordingDestination, CLCircularRegion) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = GeofenceStore(fileURL: directory.appendingPathComponent("places.json"))
        let place = Geofence(name: "Office", latitude: 0, longitude: 0, radius: 100,
                             statusText: "At work", statusEmoji: ":office:")
        try store.save(geofences: [place], otherStatus: OtherStatus())
        let destination = RecordingDestination()
        let registry = DestinationRegistry(destinations: [destination], defaults: defaults())
        let runtime = LocationRuntime(store: store, driving: motion, destinations: registry, defaults: defaults())
        runtime.monitor.configure(geofences: [place], other: OtherStatus())
        let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                      radius: 100, identifier: "whereabouts." + place.id.uuidString)
        return (runtime, destination, region)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "Expected asynchronous status update.")
    }

    private func defaults() -> UserDefaults {
        let name = "DrivingTests." + UUID().uuidString
        let result = UserDefaults(suiteName: name)!
        addTeardownBlock { result.removePersistentDomain(forName: name) }
        return result
    }
}

@MainActor
private final class FakeMotionSource: MotionActivitySource {
    var available = true
    var denied = false
    var receive: (([MotionSample]) -> Void)?
    var stops = 0
    var queries = 0
    var pauseHistory = false
    var resume: CheckedContinuation<[MotionSample], Never>?
    func start(_ receive: @escaping ([MotionSample]) -> Void) { self.receive = receive }
    func stop() { stops += 1 }
    func history(from: Date, to: Date) async throws -> [MotionSample] {
        queries += 1
        if pauseHistory { return await withCheckedContinuation { resume = $0 } }
        return []
    }
}


@MainActor
private final class RecordingDestination: StatusDestination {
    let id = "region-test"
    let displayName = "Test"
    var isConfigured = true
    var calls: [LocationStatus] = []
    func publish(_ status: LocationStatus) async throws -> PublishOutcome {
        calls.append(status)
        return .sent
    }
}
