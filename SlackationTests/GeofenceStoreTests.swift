import XCTest
@testable import Slackation

final class GeofenceStoreTests: XCTestCase {
    @MainActor
    func testRoundTrip() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = GeofenceStore(fileURL: url)
        try store.load()
        XCTAssertEqual(store.geofences, [])
        XCTAssertEqual(store.otherStatus, OtherStatus())
        let places = [geofence()]
        let other = OtherStatus(text: "Away", emoji: ":walking:")
        try store.save(geofences: places, otherStatus: other)
        let reloaded = GeofenceStore(fileURL: url)
        try reloaded.load()
        XCTAssertEqual(reloaded.geofences, places)
        XCTAssertEqual(reloaded.otherStatus, other)
    }

    @MainActor
    func testLimitPreservesSavedState() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = GeofenceStore(fileURL: url)
        let places = (0..<20).map { _ in geofence() }
        try store.save(geofences: places, otherStatus: OtherStatus())
        XCTAssertThrowsError(try store.save(geofences: places + [geofence()], otherStatus: OtherStatus())) {
            XCTAssertEqual($0 as? GeofenceStore.StoreError, .tooManyGeofences)
        }
        XCTAssertEqual(store.geofences, places)
        try store.load()
        XCTAssertEqual(store.geofences, places)
    }

    @MainActor
    func testInvalidFileIsPreserved() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = Data("invalid json".utf8)
        try invalid.write(to: url)
        let store = GeofenceStore(fileURL: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: url), invalid)
    }

    @MainActor
    func testDuplicateIDsAreRejected() throws {
        let store = GeofenceStore(fileURL: temporaryURL())
        let place = geofence()
        XCTAssertThrowsError(try store.save(geofences: [place, place], otherStatus: OtherStatus())) {
            XCTAssertEqual($0 as? GeofenceStore.StoreError, .duplicateIDs)
        }
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    }

    private func geofence() -> Geofence {
        Geofence(name: "Office", latitude: 37.78, longitude: -122.4, radius: 150,
                 statusText: "At work", statusEmoji: ":office:")
    }
}
