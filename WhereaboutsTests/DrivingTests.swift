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
    func testUnknownPreservesMediumEvidenceAndHistoryIsOrdered() {
        var detector = DrivingDetector()
        XCTAssertTrue(detector.update(samples: [sample(90, .unknown), sample(0, .automotive, .medium)], now: start.addingTimeInterval(300)))
        XCTAssertTrue(detector.update(samples: [sample(400, .automotive), sample(410, .stopped)], now: start.addingTimeInterval(529)))
        XCTAssertFalse(detector.update(samples: [sample(400, .automotive)], now: start.addingTimeInterval(530)))
    }
    func testMediumStartsAfterTwoMinutesAcrossUnknownAndLowSamples() {
        var detector = DrivingDetector()
        XCTAssertFalse(detector.update(samples: [sample(0, .automotive, .medium),
                                                 sample(30, .unknown), sample(60, .stopped, .low),
                                                 sample(90, .automotive, .medium)],
                                       now: start.addingTimeInterval(119)))
        XCTAssertTrue(detector.update(samples: [], now: start.addingTimeInterval(120)))
    }

    @MainActor
    func testRelaunchPublishesSavedDrivingAfterHistoryFailureOrTimeout() async throws {
        for timesOut in [false, true] {
            let saved = defaults()
            var detector = DrivingDetector()
            let now = Date()
            _ = detector.update(samples: [MotionSample(date: now, activity: .automotive, confidence: .high)], now: now)
            saved.set(try JSONEncoder().encode(detector), forKey: "Whereabouts.drivingDetector")
            let source = FakeMotionSource()
            source.shouldThrow = !timesOut
            source.pauseHistory = timesOut
            let motion = DrivingMonitor(source: source, defaults: saved, historyTimeout: 0.05)
            XCTAssertTrue(motion.isDriving)
            let (runtime, destination, _) = try runtime(motion: motion)
            runtime.monitor.configure(geofences: [], other: OtherStatus())
            runtime.monitor.onMotionWake?()
            await waitUntil { motion.issue != nil && destination.calls.count == 1 }
            XCTAssertTrue(motion.isDriving)
            XCTAssertEqual(destination.calls.map(\.locationName), ["Driving"])
            source.pauseHistory = false
            source.resume?.resume(returning: [])
            motion.setEnabled(false)
        }
    }

    @MainActor
    func testRelaunchWithExpiredStopAndStoppedHistoryPublishesOther() async throws {
        let saved = defaults()
        let now = Date()
        let stopped = MotionSample(date: now.addingTimeInterval(-121), activity: .stopped, confidence: .high)
        var detector = DrivingDetector()
        _ = detector.update(samples: [MotionSample(date: now.addingTimeInterval(-180), activity: .automotive, confidence: .high), stopped], now: stopped.date)
        XCTAssertTrue(detector.isDriving)
        saved.set(try JSONEncoder().encode(detector), forKey: "Whereabouts.drivingDetector")
        let source = FakeMotionSource()
        source.pauseHistory = true
        let motion = DrivingMonitor(source: source, defaults: saved)
        XCTAssertFalse(motion.isDriving)
        let (runtime, destination, _) = try runtime(motion: motion)
        runtime.monitor.configure(geofences: [], other: OtherStatus())
        runtime.monitor.onMotionWake?()
        await waitUntil { source.resume != nil }
        source.pauseHistory = false
        source.resume?.resume(returning: [stopped])
        await waitUntil { destination.calls.count == 1 }
        XCTAssertFalse(motion.isDriving)
        XCTAssertEqual(destination.calls.map(\.locationName), ["Other"])
        motion.setEnabled(false)
    }

    @MainActor
    func testLaunchChecksRecentHistoryBeforeFirstSend() async throws {
        let saved = defaults()
        let now = Date()
        var detector = DrivingDetector()
        _ = detector.update(samples: [MotionSample(date: now.addingTimeInterval(-60), activity: .unknown, confidence: .low)], now: now)
        saved.set(try JSONEncoder().encode(detector), forKey: "Whereabouts.drivingDetector")
        let source = FakeMotionSource()
        source.pauseHistory = true
        let motion = DrivingMonitor(source: source, defaults: saved)
        let (runtime, destination, _) = try runtime(motion: motion)
        runtime.refreshMonitoring()
        await waitUntil { source.resume != nil }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(source.historyInterval), 900)
        XCTAssertTrue(destination.calls.isEmpty)
        source.pauseHistory = false
        source.resume?.resume(returning: [
            MotionSample(date: now.addingTimeInterval(-300), activity: .automotive, confidence: .medium)
        ])
        await waitUntil { destination.calls.count == 1 }
        XCTAssertEqual(destination.calls.map(\.locationName), ["Driving"])
        XCTAssertTrue(motion.isDriving)
        motion.setEnabled(false)
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
    func testRegionExitWaitsForHistoryStartedByEnablingDriving() async throws {
        let source = FakeMotionSource()
        let motion = DrivingMonitor(source: source, defaults: defaults())
        motion.setEnabled(false)
        let (runtime, destination, region) = try runtime(motion: motion)
        runtime.monitor.locationManager(CLLocationManager(), didEnterRegion: region)
        await waitUntil { runtime.engine.lastSentStatuses[destination.id]?.locationName == "Office" }
        for _ in 0..<100 { await Task.yield() }

        source.pauseHistory = true
        motion.setEnabled(true)
        await waitUntil { source.resume != nil }
        let queries = source.queries
        runtime.monitor.locationManager(CLLocationManager(), didExitRegion: region)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(source.queries, queries, "Exit must share the active query.")
        XCTAssertEqual(destination.calls.map(\.locationName), ["Office"])
        source.pauseHistory = false
        source.resume?.resume(returning: [
            MotionSample(date: Date(), activity: .automotive, confidence: .high)
        ])
        await waitUntil { runtime.engine.lastSentStatuses[destination.id]?.locationName == "Driving" }
        XCTAssertEqual(destination.calls.map(\.locationName), ["Office", "Driving"])
        motion.setEnabled(false)
    }

    @MainActor
    func testFailedSharedHistoryKeepsKnownDrivingAndReleasesCallers() async {
        let source = FakeMotionSource()
        let motion = DrivingMonitor(source: source, defaults: defaults())
        await motion.refresh()
        source.receive?([MotionSample(date: Date(), activity: .automotive, confidence: .high)])
        XCTAssertTrue(motion.isDriving)
        source.pauseHistory = true
        source.shouldThrow = true
        let first = Task { await motion.refresh() }
        await waitUntil { source.resume != nil }
        var secondFinished = false
        let second = Task { await motion.refresh(); secondFinished = true }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(secondFinished)
        XCTAssertEqual(source.queries, 2)
        source.pauseHistory = false
        source.resume?.resume(returning: [])
        await first.value
        await second.value
        XCTAssertTrue(motion.isDriving)
        XCTAssertNotNil(motion.issue)
        source.shouldThrow = false
        await motion.refresh()
        XCTAssertEqual(source.queries, 3, "A failed query must not block future refreshes.")
        motion.setEnabled(false)
    }

    @MainActor
    func testDisableReleasesSharedHistoryWaiterAndRejectsLateResult() async {
        let source = FakeMotionSource()
        source.pauseHistory = true
        let motion = DrivingMonitor(source: source, defaults: defaults())
        let first = Task { await motion.refresh() }
        await waitUntil { source.resume != nil }
        var secondFinished = false
        let second = Task { await motion.refresh(); secondFinished = true }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(secondFinished)
        motion.setEnabled(false)
        await waitUntil { secondFinished }
        source.resume?.resume(returning: [
            MotionSample(date: Date(), activity: .automotive, confidence: .high)
        ])
        await first.value
        await second.value
        XCTAssertFalse(motion.isDriving)
        XCTAssertFalse(motion.isMonitoring)
    }

    @MainActor
    func testMotionChangeDuringSlowSendPublishesFinalStateInOrder() async throws {
        let source = FakeMotionSource()
        let motion = DrivingMonitor(source: source, defaults: defaults())
        let (runtime, destination, _) = try runtime(motion: motion)
        runtime.monitor.configure(geofences: [], other: OtherStatus())
        runtime.monitor.onMotionWake?()
        await waitUntil { runtime.engine.lastSentStatuses[destination.id]?.locationName == "Other" }
        for _ in 0..<100 { await Task.yield() }

        source.pauseHistory = true
        runtime.monitor.onMotionWake?()
        await waitUntil { source.resume != nil }
        destination.pauseNext = true
        source.pauseHistory = false
        source.resume?.resume(returning: [
            MotionSample(date: Date().addingTimeInterval(-180), activity: .automotive, confidence: .high)
        ])
        await waitUntil { destination.resume != nil }
        XCTAssertEqual(destination.calls.map(\.locationName), ["Other", "Driving"])
        source.receive?([MotionSample(date: Date().addingTimeInterval(-121), activity: .stopped, confidence: .high)])
        XCTAssertFalse(motion.isDriving)
        destination.resume?.resume()
        await waitUntil { !runtime.engine.isSending && destination.calls.count == 3 }
        XCTAssertEqual(destination.calls.map(\.locationName), ["Other", "Driving", "Other"])
        XCTAssertEqual(runtime.engine.lastSentStatuses[destination.id]?.locationName, "Other")
        XCTAssertEqual(runtime.currentStatus.locationName, "Other")
        motion.setEnabled(false)
    }

    @MainActor
    func testTimeoutReleasesOwnerAndWaitersAndRejectsLateResultDuringNewQuery() async {
        let source = FakeMotionSource()
        source.pauseHistory = true
        let motion = DrivingMonitor(source: source, defaults: defaults(), historyTimeout: 0.05)
        var ownerFinished = false
        var waiterFinished = false
        let owner = Task { await motion.refresh(); ownerFinished = true }
        await waitUntil { source.resume != nil }
        let oldResult = source.resume
        let waiter = Task { await motion.refresh(); waiterFinished = true }
        await waitUntil { ownerFinished && waiterFinished }
        await owner.value
        await waiter.value
        XCTAssertFalse(motion.isDriving)
        XCTAssertNotNil(motion.issue)
        XCTAssertEqual(source.queries, 1)

        source.resume = nil
        var nextFinished = false
        let next = Task { await motion.refresh(); nextFinished = true }
        await waitUntil { source.resume != nil }
        oldResult?.resume(returning: [MotionSample(date: Date(), activity: .automotive, confidence: .high)])
        try? await Task.sleep(for: .milliseconds(5))
        XCTAssertFalse(motion.isDriving)
        XCTAssertFalse(nextFinished, "An old result must not release the new query.")
        source.resume?.resume(returning: [MotionSample(date: Date(), activity: .automotive, confidence: .high)])
        await next.value
        XCTAssertTrue(motion.isDriving)
        XCTAssertEqual(source.queries, 2)
        motion.setEnabled(false)
    }

    @MainActor
    func testCancellingOwnerOrWaiterReleasesEveryCaller() async {
        for cancelOwner in [true, false] {
            let source = FakeMotionSource()
            source.pauseHistory = true
            let motion = DrivingMonitor(source: source, defaults: defaults(), historyTimeout: 60)
            var ownerFinished = false
            var waiterFinished = false
            let owner = Task { await motion.refresh(); ownerFinished = true }
            await waitUntil { source.resume != nil }
            let waiter = Task { await motion.refresh(); waiterFinished = true }
            try? await Task.sleep(for: .milliseconds(5))
            if cancelOwner { owner.cancel() } else { waiter.cancel() }
            await waitUntil { ownerFinished && waiterFinished }
            XCTAssertFalse(motion.isDriving)
            // Release the fake source only after proving callers did not need its callback.
            source.resume?.resume(returning: [
                MotionSample(date: Date(), activity: .automotive, confidence: .high)
            ])
            await owner.value
            await waiter.value
            try? await Task.sleep(for: .milliseconds(5))
            XCTAssertFalse(motion.isDriving)
            source.pauseHistory = false
            await motion.refresh()
            XCTAssertEqual(source.queries, 2)
            motion.setEnabled(false)
        }
    }

    @MainActor
    func testRegionExitTimeoutPublishesLastKnownDrivingOrOther() async throws {
        for wasDriving in [true, false] {
            let source = FakeMotionSource()
            let motion = DrivingMonitor(source: source, defaults: defaults(), historyTimeout: 0.05)
            await motion.refresh()
            if wasDriving {
                source.receive?([MotionSample(date: Date(), activity: .automotive, confidence: .high)])
            }
            let (runtime, destination, region) = try runtime(motion: motion)
            // Allow initial authorization callbacks before simulating region state.
            try? await Task.sleep(for: .milliseconds(10))
            runtime.monitor.locationManager(CLLocationManager(), didEnterRegion: region)
            await waitUntil { runtime.engine.lastSentStatuses[destination.id]?.locationName == "Office" }
            try? await Task.sleep(for: .milliseconds(5))
            let beforeExit = destination.calls.map(\.locationName)
            XCTAssertEqual(beforeExit.last, "Office")
            source.pauseHistory = true
            source.resume = nil
            runtime.monitor.locationManager(CLLocationManager(), didExitRegion: region)
            await waitUntil { source.resume != nil }
            var waiterFinished = false
            let waiter = Task { await motion.refresh(); waiterFinished = true }
            let expected = wasDriving ? "Driving" : "Other"
            await waitUntil { waiterFinished && runtime.engine.lastSentStatuses[destination.id]?.locationName == expected }
            XCTAssertEqual(destination.calls.map(\.locationName), beforeExit + [expected])
            XCTAssertEqual(motion.isDriving, wasDriving)
            source.pauseHistory = false
            source.resume?.resume(returning: [])
            await waiter.value
            motion.setEnabled(false)
        }
    }

    @MainActor
    func testDisableReleasesRuntimeOwnedQueryWithoutSourceCallback() async throws {
        let source = FakeMotionSource()
        let motion = DrivingMonitor(source: source, defaults: defaults(), historyTimeout: 60)
        await motion.refresh()
        source.receive?([MotionSample(date: Date(), activity: .automotive, confidence: .high)])
        let (runtime, destination, _) = try runtime(motion: motion)
        runtime.monitor.configure(geofences: [], other: OtherStatus())
        runtime.monitor.onMotionWake?()
        await waitUntil { runtime.engine.lastSentStatuses[destination.id]?.locationName == "Driving" }
        try? await Task.sleep(for: .milliseconds(5))
        source.pauseHistory = true
        runtime.monitor.onMotionWake?()
        await waitUntil { source.resume != nil }
        motion.setEnabled(false)
        await waitUntil { runtime.engine.lastSentStatuses[destination.id]?.locationName == "Other" }
        XCTAssertEqual(destination.calls.map(\.locationName), ["Driving", "Other"])
        source.resume?.resume(returning: [
            MotionSample(date: Date(), activity: .automotive, confidence: .high)
        ])
        try? await Task.sleep(for: .milliseconds(5))
        XCTAssertFalse(motion.isDriving)
        XCTAssertEqual(runtime.currentStatus.locationName, "Other")
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
    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition(), "Expected asynchronous status update.", file: file, line: line)
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
    var historyInterval: TimeInterval?
    var pauseHistory = false
    var shouldThrow = false
    var resume: CheckedContinuation<[MotionSample], Never>?
    func start(_ receive: @escaping ([MotionSample]) -> Void) { self.receive = receive }
    func stop() { stops += 1 }
    func history(from: Date, to: Date) async throws -> [MotionSample] {
        queries += 1
        historyInterval = to.timeIntervalSince(from)
        let samples: [MotionSample]
        if pauseHistory { samples = await withCheckedContinuation { resume = $0 } }
        else { samples = [] }
        if shouldThrow { throw NSError(domain: "MotionTest", code: 1) }
        return samples
    }
}


@MainActor
private final class RecordingDestination: StatusDestination {
    let id = "region-test"
    let displayName = "Test"
    var isConfigured = true
    var calls: [LocationStatus] = []
    var pauseNext = false
    var resume: CheckedContinuation<Void, Never>?
    func publish(_ status: LocationStatus) async throws -> PublishOutcome {
        calls.append(status)
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation { self.resume = $0 }
        }
        return .sent
    }
}
