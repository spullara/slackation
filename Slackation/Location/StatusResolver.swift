import Foundation

struct ResolvedStatus: Equatable, Sendable {
    var text: String
    var emoji: String
}

enum StatusResolver {
    static func resolve(geofences: [Geofence], insideIDs: Set<UUID>, other: OtherStatus) -> ResolvedStatus {
        let selected = geofences.filter { insideIDs.contains($0.id) }.min {
            if $0.radius == $1.radius { return $0.id.uuidString < $1.id.uuidString }
            return $0.radius < $1.radius
        }
        return ResolvedStatus(text: selected?.statusText ?? other.text,
                              emoji: selected?.statusEmoji ?? other.emoji)
    }
}
