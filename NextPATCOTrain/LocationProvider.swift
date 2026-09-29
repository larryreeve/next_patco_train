import Combine
import CoreLocation
import Foundation
import UserNotifications

enum ArrivalNotifications {
    static func requestPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    static func post(stationName: String, returnStationName: String) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        let content = UNMutableNotificationContent()
        content.title = "Near \(stationName)"
        content.body = "Your return route to \(returnStationName) is ready."
        content.sound = .default
        // Replacing the previous arrival keeps outdated return routes out of Notification Center.
        center.removeDeliveredNotifications(withIdentifiers: ["destination-arrival"])
        try? await center.add(UNNotificationRequest(identifier: "destination-arrival", content: content, trigger: nil))
    }
}

final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var currentLocation: CLLocation?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdatedAt: Date?

    private let manager = CLLocationManager()
    var isInBackground = false
    var onBackgroundLocation: ((CLLocation) -> Void)?
    private var journeyTimeout: Timer?
    private(set) var journeyTrackingDeadline: Date?

    func beginJourneyTracking() {
        guard journeyTimeout == nil else { return }
        Task { await ArrivalNotifications.requestPermissionIfNeeded() }
        journeyTrackingDeadline = Date().addingTimeInterval(2 * 60 * 60)
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        journeyTimeout = Timer.scheduledTimer(timeInterval: 2 * 60 * 60, target: self,
                                            selector: #selector(endJourneyTracking), userInfo: nil, repeats: false)
    }

    @objc func endJourneyTracking() {
        journeyTimeout?.invalidate()
        journeyTimeout = nil
        journeyTrackingDeadline = nil
        manager.allowsBackgroundLocationUpdates = false
        if isInBackground { manager.stopUpdatingLocation() }
    }

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 25
    }

    func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            errorMessage = "Location is off. Pick a station manually."
        @unknown default:
            errorMessage = "Location status is unavailable."
        }
    }

    func startUpdatingLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            errorMessage = "Location is off. Pick a station manually."
        @unknown default:
            errorMessage = "Location status is unavailable."
        }
    }

    func stopUpdatingLocation() {
        guard journeyTimeout == nil else { return }
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            manager.startUpdatingLocation()
        } else {
            endJourneyTracking()
            manager.stopUpdatingLocation()
            currentLocation = nil
            lastUpdatedAt = nil
            SharedCurrentLocationCache.clear()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else { return }
        Task { @MainActor in await PATCOLiveActivityStarter.endExpiredActivities() }
        currentLocation = locations.last
        lastUpdatedAt = Date()
        errorMessage = nil
        if isInBackground, let location = locations.last { onBackgroundLocation?(location) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let locationError = error as? CLError {
            switch locationError.code {
            case .denied:
                errorMessage = "Location is off. Pick a station manually."
            case .locationUnknown, .network:
                errorMessage = "Could not find your location. Try again or pick a station."
            default:
                errorMessage = "Location is unavailable. Pick a station manually."
            }
        } else {
            errorMessage = "Location is unavailable. Pick a station manually."
        }
    }
}
