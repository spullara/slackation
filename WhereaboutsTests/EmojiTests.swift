import XCTest
@testable import Whereabouts

final class EmojiTests: XCTestCase {
    func testCatalogAndCustomShortcodes() throws {
        XCTAssertGreaterThan(EmojiCatalog.entries.count, 1800)
        XCTAssertEqual(EmojiCatalog.unicode(for: ":office:"), "🏢")
        XCTAssertEqual(EmojiCatalog.unicode(for: ":globe_with_meridians:"), "🌐")
        XCTAssertNil(EmojiCatalog.unicode(for: ":my-team:"))
        XCTAssertEqual(EmojiCatalog.customShortcode(" my-team "), ":my-team:")
        XCTAssertEqual(EmojiCatalog.customShortcode(":my-team:"), ":my-team:")
        XCTAssertNil(EmojiCatalog.customShortcode(" "))
        XCTAssertNil(EmojiCatalog.customShortcode(":two words:"))
        XCTAssertNil(EmojiCatalog.customShortcode("🏢"))
        XCTAssertEqual(Set(EmojiCatalog.entries.map(\.shortcode)).count, EmojiCatalog.entries.count)
        XCTAssertTrue(try XCTUnwrap(EmojiCatalog.entries.first { $0.shortcode == ":office:" }).matches("office"))
    }

    @MainActor
    func testShortcodeOnlyStoreMigrationAndUnicodeRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = #"{"geofences":[{"id":"F523A747-C223-4AE9-958A-C37D7250F4C1","name":"Office","latitude":37.7,"longitude":-122.4,"radius":200,"statusText":"Work","statusEmoji":":office:"},{"id":"AE763816-859E-4713-8FBA-1D443F9B8EAF","name":"Team","latitude":0,"longitude":0,"radius":200,"statusText":"Team","statusEmoji":":my-team:"}],"otherStatus":{"text":"Other","emoji":":globe_with_meridians:"}}"#
        try Data(old.utf8).write(to: url)
        let store = GeofenceStore(fileURL: url)
        try store.load()
        XCTAssertEqual(store.geofences[0].statusEmojiUnicode, "🏢")
        XCTAssertEqual(store.geofences[0].statusEmoji, ":office:")
        XCTAssertNil(store.geofences[1].statusEmojiUnicode)
        XCTAssertEqual(store.geofences[1].displayEmoji, ":my-team:")
        XCTAssertEqual(store.otherStatus.emojiUnicode, "🌐")
        let status = StatusResolver.resolve(geofences: store.geofences, insideIDs: [store.geofences[0].id], other: store.otherStatus)
        XCTAssertEqual(status.emojiUnicode, "🏢")
        XCTAssertEqual(status.emoji, ":office:")
        try store.save(geofences: store.geofences, otherStatus: store.otherStatus)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let places = try XCTUnwrap(saved["geofences"] as? [[String: Any]])
        XCTAssertEqual(places[0]["statusEmojiUnicode"] as? String, "🏢")
        let reloaded = GeofenceStore(fileURL: url)
        try reloaded.load()
        XCTAssertEqual(reloaded.geofences, store.geofences)
        XCTAssertEqual(reloaded.otherStatus, store.otherStatus)
    }

    func testSavedDestinationStatusMigration() throws {
        let old = #"{"locationName":"Office","text":"Work","emoji":":office:","isOther":false}"#
        let status = try JSONDecoder().decode(LocationStatus.self, from: Data(old.utf8))
        XCTAssertEqual(status.emojiUnicode, "🏢")
        XCTAssertEqual(status.displayEmoji, "🏢")
    }
}
