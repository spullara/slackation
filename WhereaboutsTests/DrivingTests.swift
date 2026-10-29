import XCTest
@testable import Whereabouts

final class DrivingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000)
    private func sample(_ seconds: Double, _ activity: MotionSample.Activity, _ confidence: MotionSample.Confidence = .high) -> MotionSample {
        MotionSample(date: start.addingTimeInterval(seconds), activity: activity, confidence: confidence)
    }
    func testHighStartsImmediatelyAndStopNeedsFiveMinutes() {
        var detector = DrivingDetector()
        XCTAssertTrue(detector.update(samples: [sample(0, .automotive)], now: start))
        XCTAssertTrue(detector.update(samples: [sample(10, .stopped)], now: start.addingTimeInterval(309)))
        XCTAssertFalse(detector.update(samples: [], now: start.addingTimeInterval(310)))
    }
    func testMediumNeedsTwoMinutesAndAutomotiveCancelsStop() {
        var detector = DrivingDetector()
        XCTAssertFalse(detector.update(samples: [sample(0, .automotive, .medium)], now: start.addingTimeInterval(119)))
        XCTAssertTrue(detector.update(samples: [], now: start.addingTimeInterval(120)))
        XCTAssertTrue(detector.update(samples: [sample(130, .stopped), sample(400, .automotive, .medium)], now: start.addingTimeInterval(500)))
    }
    func testUnknownAndLowCannotStartOrStop() {
        var detector = DrivingDetector()
        XCTAssertFalse(detector.update(samples: [sample(0, .automotive, .low), sample(10, .unknown)], now: start.addingTimeInterval(600)))
        XCTAssertTrue(detector.update(samples: [sample(601, .automotive), sample(602, .stopped, .low), sample(603, .unknown)], now: start.addingTimeInterval(1200)))
    }
    func testUnknownBreaksMediumEvidenceAndHistoryIsOrdered() {
        var detector = DrivingDetector()
        XCTAssertFalse(detector.update(samples: [sample(90, .unknown), sample(0, .automotive, .medium)], now: start.addingTimeInterval(300)))
        XCTAssertTrue(detector.update(samples: [sample(400, .automotive), sample(410, .stopped)], now: start.addingTimeInterval(709)))
        XCTAssertFalse(detector.update(samples: [sample(400, .automotive)], now: start.addingTimeInterval(710)))
    }
    func testResolverPriorityAndReturnToPlace() {
        let place = Geofence(name: "Office", latitude: 0, longitude: 0, radius: 100, statusText: "At work", statusEmoji: ":office:")
        let driving = StatusResolver.resolve(geofences: [place], insideIDs: [place.id], other: OtherStatus(), isDriving: true)
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
        XCTAssertTrue(monitor.isDriving, "A fresh stop must retain Driving for five minutes.")
        monitor.setEnabled(false)
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
