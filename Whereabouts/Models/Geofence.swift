import Foundation

struct Geofence: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    /// Radius in meters.
    var radius: Double
    var statusText: String
    var statusEmoji: String
}
