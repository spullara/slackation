import Foundation

enum StatusResolver {
    static func resolve(geofences: [Geofence], insideIDs: Set<UUID>, other: OtherStatus) -> LocationStatus {
        let selected = geofences.filter { insideIDs.contains($0.id) }.min {
            if $0.radius == $1.radius { return $0.id.uuidString < $1.id.uuidString }
            return $0.radius < $1.radius
        }
        return LocationStatus(locationName: selected?.name ?? "Other", text: selected?.statusText ?? other.text,
                              emoji: selected?.statusEmoji ?? other.emoji, isOther: selected == nil)
    }
}
