import Foundation

enum StatusResolver {
    static func resolve(geofences: [Geofence], insideIDs: Set<UUID>, other: OtherStatus, isDriving: Bool = false,
                        drivingStatus: OtherStatus = OtherStatus(text: "Driving", emoji: ":car:")) -> LocationStatus {
        if isDriving {
            return LocationStatus(locationName: "Driving", text: drivingStatus.text, emoji: drivingStatus.emoji,
                                  isOther: false, emojiUnicode: drivingStatus.emojiUnicode, kind: .driving)
        }
        let selected = geofences.filter { insideIDs.contains($0.id) }.min {
            if $0.radius == $1.radius { return $0.id.uuidString < $1.id.uuidString }
            return $0.radius < $1.radius
        }
        return LocationStatus(locationName: selected?.name ?? "Other", text: selected?.statusText ?? other.text,
                              emoji: selected?.statusEmoji ?? other.emoji, isOther: selected == nil,
                              emojiUnicode: selected == nil ? other.emojiUnicode : selected?.statusEmojiUnicode,
                              geofenceID: selected?.id)
    }
}
