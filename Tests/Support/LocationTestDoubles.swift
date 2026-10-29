#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import Foundation
import CoreLocation

final class LocationTestEnvironment {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let manager = MockLocationManager()
    var timeout: (() -> Void)?
    var timeoutCancelled = false
    var trackingChanges: [Date?] = []
    var widgetReloads = 0
    var cacheClears = 0
    var activityExpirations = 0
    var errors = 0
    var session: JourneyProgressSession?

    func provider() -> LocationProvider {
        LocationProvider(manager: manager, now: { self.now }, journeySession: { self.session }, scheduleTimeout: { interval, action in
            precondition(interval > 0 && interval <= 7200)
            self.timeout = action
            self.timeoutCancelled = false
            return { self.timeoutCancelled = true; self.timeout = nil }
        }, trackingChanged: { deadline, reloadWidgets in
            self.trackingChanges.append(deadline)
            if reloadWidgets { self.widgetReloads += 1 }
        },
           clearCachedLocation: { self.cacheClears += 1 },
           expireActivities: { self.activityExpirations += 1 }, recordError: { _ in self.errors += 1 })
    }

    func fix(latitude: Double = 39.98, secondsAgo: Double = 0, accuracy: Double = 20) -> CLLocation {
        CLLocation(coordinate: .init(latitude: latitude, longitude: -75.16), altitude: 0,
                   horizontalAccuracy: accuracy, verticalAccuracy: 1, course: 0, speed: 0, timestamp: now.addingTimeInterval(-secondsAgo))
    }
}

final class MockLocationManager: LocationManaging {
    weak var delegate: CLLocationManagerDelegate?
    var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
    var desiredAccuracy: CLLocationAccuracy = 0
    var distanceFilter: CLLocationDistance = 0
    var pausesLocationUpdatesAutomatically = true
    var allowsBackgroundLocationUpdates = false
    var showsBackgroundLocationIndicator = false
    var permissionRequests = 0
    var requests = 0
    var starts = 0
    var stops = 0
    var running = false
    func requestWhenInUseAuthorization() { permissionRequests += 1 }
    func requestLocation() { requests += 1 }
    func startUpdatingLocation() { starts += 1; running = true }
    func stopUpdatingLocation() { stops += 1; running = false }
    func authorize(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        (delegate as? LocationProvider)?.authorizationDidChange()
    }
    func send(_ readings: [CLLocation]) { (delegate as? LocationProvider)?.receivedLocations(readings) }
    func fail(_ code: CLError.Code) {
        (delegate as? LocationProvider)?.receivedError(NSError(domain: kCLErrorDomain, code: code.rawValue))
    }
}
