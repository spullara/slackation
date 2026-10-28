import Foundation
import Observation

@MainActor
@Observable
final class GeofenceStore {
    static let maximumGeofences = 20

    private(set) var geofences: [Geofence] = []
    private(set) var otherStatus = OtherStatus()
    let fileURL: URL

    enum StoreError: LocalizedError, Equatable {
        case tooManyGeofences
        case duplicateIDs

        var errorDescription: String? {
            switch self {
            case .tooManyGeofences: "You can save up to 20 geofences."
            case .duplicateIDs: "Each geofence must have a unique ID."
            }
        }
    }

    private struct Contents: Codable {
        var geofences: [Geofence]
        var otherStatus: OtherStatus
    }

    /// Call load() at startup and present any error to the user.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? URL.applicationSupportDirectory
            .appending(path: "Whereabouts", directoryHint: .isDirectory)
            .appending(path: "geofences.json")
    }

    /// Missing files represent a new store. Invalid files are never overwritten here.
    func load() throws {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            geofences = []
            otherStatus = OtherStatus()
            return
        }
        let contents = try JSONDecoder().decode(Contents.self, from: data)
        try validate(contents.geofences)
        geofences = contents.geofences
        otherStatus = contents.otherStatus
    }

    /// Write before publishing changes so a failed save leaves memory unchanged.
    func save(geofences: [Geofence], otherStatus: OtherStatus) throws {
        try validate(geofences)
        let data = try JSONEncoder().encode(Contents(geofences: geofences, otherStatus: otherStatus))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        self.geofences = geofences
        self.otherStatus = otherStatus
    }

    private func validate(_ geofences: [Geofence]) throws {
        guard geofences.count <= Self.maximumGeofences else { throw StoreError.tooManyGeofences }
        guard Set(geofences.map(\.id)).count == geofences.count else { throw StoreError.duplicateIDs }
    }
}
