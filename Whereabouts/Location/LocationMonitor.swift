import CoreLocation
import Observation

@MainActor
@Observable
final class LocationMonitor: NSObject, @preconcurrency CLLocationManagerDelegate {
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var lastError: String?
    private(set) var insideIDs: Set<UUID> = []
    var onStatusChange: ((LocationStatus) -> Void)?
    private let manager: CLLocationManager
    private var geofences: [Geofence] = []
    private var other = OtherStatus()
    private var pendingIDs: Set<UUID> = []
    private let prefix = "whereabouts."

    override init() {
        manager = CLLocationManager()
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    func requestAlwaysAuthorization() {
        if authorizationStatus == .notDetermined || authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }

    /// Call at launch and after saved geofences or Other status change.
    func configure(geofences: [Geofence], other: OtherStatus) {
        self.geofences = geofences
        self.other = other
        registerRegions()
    }

    private func registerRegions() {
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else { return }
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            lastError = "Region monitoring is not available on this device."
            return
        }
        guard geofences.count <= 20, Set(geofences.map(\.id)).count == geofences.count,
              geofences.allSatisfy({ CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) && $0.radius.isFinite && $0.radius > 0 }) else {
            lastError = "Use up to 20 unique geofences with valid coordinates and a positive radius."
            return
        }
        lastError = nil
        insideIDs = []
        pendingIDs = Set(geofences.map(\.id))
        let regions = geofences.map { place in
            CLCircularRegion(center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                             radius: min(place.radius, manager.maximumRegionMonitoringDistance),
                             identifier: prefix + place.id.uuidString)
        }
        let wanted = Set(regions.map(\.identifier))
        for existing in manager.monitoredRegions where existing.identifier.hasPrefix(prefix) {
            let replacement = regions.first { $0.identifier == existing.identifier }
            let circle = existing as? CLCircularRegion
            if !wanted.contains(existing.identifier) || circle?.center.latitude != replacement?.center.latitude || circle?.center.longitude != replacement?.center.longitude || circle?.radius != replacement?.radius {
                manager.stopMonitoring(for: existing)
            }
        }
        for region in regions {
            manager.startMonitoring(for: region)
            manager.requestState(for: region)
        }
        publishIfReady()
    }

    private func update(_ region: CLRegion, inside: Bool) {
        guard region.identifier.hasPrefix(prefix),
              let id = UUID(uuidString: String(region.identifier.dropFirst(prefix.count))),
              geofences.contains(where: { $0.id == id }) else { return }
        if inside { insideIDs.insert(id) } else { insideIDs.remove(id) }
        pendingIDs.remove(id)
        publishIfReady()
    }

    private func publishIfReady() {
        // Do not send Other while initial region states are still unknown.
        guard pendingIDs.isEmpty else { return }
        onStatusChange?(StatusResolver.resolve(geofences: geofences, insideIDs: insideIDs, other: other))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .denied || authorizationStatus == .restricted {
            lastError = "Location access is disabled. Enable Always access in Settings for background updates."
        }
        registerRegions()
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) { update(region, inside: true) }
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) { update(region, inside: false) }
    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard state != .unknown else { return }
        update(region, inside: state == .inside)
    }
    func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) { manager.requestState(for: region) }
    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) { lastError = error.localizedDescription }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { lastError = error.localizedDescription }
}
