import CoreLocation

@MainActor
protocol DrivingLocationSource: AnyObject {
    var onActiveChange: ((Bool) -> Void)? { get set }
    func start(_ receive: @escaping ([CLLocation]) -> Void)
    func stop()
}

/// A separate manager keeps drive updates independent of one-shot map requests.
@MainActor
final class CoreDrivingLocationSource: NSObject, DrivingLocationSource, @preconcurrency CLLocationManagerDelegate {
    var onActiveChange: ((Bool) -> Void)?
    private let manager = CLLocationManager()
    private var session: CLBackgroundActivitySession?
    private var receive: (([CLLocation]) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    func start(_ receive: @escaping ([CLLocation]) -> Void) {
        self.receive = receive
        updateSession()
    }

    func stop() {
        receive = nil
        endSession()
    }

    private func updateSession() {
        guard receive != nil,
              manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else {
            endSession()
            return
        }
        guard session == nil else { return }
        manager.allowsBackgroundLocationUpdates = true
        session = CLBackgroundActivitySession()
        manager.startUpdatingLocation()
        onActiveChange?(true)
    }

    private func endSession() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        session?.invalidate()
        session = nil
        onActiveChange?(false)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { updateSession() }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) { receive?(locations) }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied { endSession() }
    }
}
