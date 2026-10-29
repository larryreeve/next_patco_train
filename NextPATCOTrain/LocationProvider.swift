import Observation
import CoreLocation
import Foundation
import WidgetKit

#if os(iOS)
@MainActor
final class DestinationRegionMonitor: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = DestinationRegionMonitor()
    private let manager = CLLocationManager()
    private let prefix = "patco.station."
    private var mayRequestAuthorization = false
    var onArrival: (() -> Void)?

    private override init() {
        super.init()
        manager.delegate = self
    }

    func start(requestAuthorization: Bool = false) {
        mayRequestAuthorization = mayRequestAuthorization || requestAuthorization
        if manager.authorizationStatus == .authorizedWhenInUse, mayRequestAuthorization,
           !UserDefaults.standard.bool(forKey: "destinationGeofenceAlwaysRequested") {
            UserDefaults.standard.set(true, forKey: "destinationGeofenceAlwaysRequested")
            manager.requestAlwaysAuthorization()
        }
        guard manager.authorizationStatus == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
                for region in manager.monitoredRegions where region.identifier.hasPrefix(prefix) {
                    manager.stopMonitoring(for: region)
                }
            }
            return
        }
        // Register the small station set so widget-only route changes work without launching the app.
        // Events still affect only the destination in the currently committed shared route.
        let stations = PATCOScheduleStore().stations
        let identifiers = Set(stations.map { prefix + $0.id })
        for region in manager.monitoredRegions where region.identifier.hasPrefix(prefix) && !identifiers.contains(region.identifier) {
            manager.stopMonitoring(for: region)
        }
        let existing = Set(manager.monitoredRegions.map(\.identifier))
        for station in stations.prefix(20) where !existing.contains(prefix + station.id) {
            let region = CLCircularRegion(center: station.coordinate,
                radius: LocationGuidancePolicy.stationRadiusMeters, identifier: prefix + station.id)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { start() }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard manager.authorizationStatus == .authorizedAlways,
              region.identifier.hasPrefix(prefix), let previous = SharedRouteCoordinator.current() else { return }
        let stationId = String(region.identifier.dropFirst(prefix.count))
        guard stationId == previous.destinationId else { return }
        let store = PATCOScheduleStore()
        guard let route = SharedRouteCoordinator.destinationRegionEntered(stationId: stationId,
            expectedRevision: previous.revision, stations: store.stations), route.revision != previous.revision else { return }
        SharedJourneyTracking.end()
        onArrival?()
        let calendar = PATCOClock.calendar
        let dates = (-1...1).compactMap { calendar.date(byAdding: .day, value: $0, to: Date()) }
        _ = SharedTripState.update(store: store, routeRevision: route.revision, location: nil,
            locationAllowed: true, specialSchedules: SharedSpecialScheduleCache.schedules(matching: dates, calendar: calendar))
        ArrivalDiagnostics.record("Destination geofence entered", detail: "\(stationId); return route revision \(route.revision); no stop or GPS fix required")
        SharedWidgetDiagnostics.recordReloadRequest(action: "Destination geofence arrival")
        WidgetCenter.shared.reloadTimelines(ofKind: "NextPATCOLockScreenWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "NextPATCOTrainWidget")
        if let station = store.stations.first(where: { $0.id == stationId }) {
            Task { @MainActor in await PATCOLiveActivityStarter.endActivities(arrivingAt: station.name) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard manager.authorizationStatus == .authorizedAlways,
              region.identifier.hasPrefix(prefix), let route = SharedRouteCoordinator.current() else { return }
        SharedRouteCoordinator.destinationRegionExited(stationId: String(region.identifier.dropFirst(prefix.count)),
            expectedRevision: route.revision)
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        ArrivalDiagnostics.record("Geofence monitoring failed", detail: "\(region?.identifier ?? "unknown"): \(error.localizedDescription)")
    }
}
#endif

protocol LocationManaging: AnyObject {
    var delegate: CLLocationManagerDelegate? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var distanceFilter: CLLocationDistance { get set }
    var pausesLocationUpdatesAutomatically: Bool { get set }
    var allowsBackgroundLocationUpdates: Bool { get set }
    var showsBackgroundLocationIndicator: Bool { get set }
    func requestWhenInUseAuthorization()
    func requestLocation()
    func startUpdatingLocation()
    func stopUpdatingLocation()
}

#if os(iOS)
extension CLLocationManager: LocationManaging {}
#endif

private final class LocationTimeoutTarget: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

@Observable
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var currentLocation: CLLocation?
    private(set) var errorMessage: String?
    private(set) var lastUpdatedAt: Date?

    private let manager: any LocationManaging
    private let now: () -> Date
    private let scheduleTimeout: (TimeInterval, @escaping () -> Void) -> () -> Void
    private let trackingChanged: (Date?, Bool) -> Void
    private let clearCachedLocation: () -> Void
    private let expireActivities: () -> Void
    private let recordError: (Error) -> Void
    private let journeySession: () -> JourneyProgressSession?
    var isInBackground = false {
        didSet { configureSampling() }
    }
    var onLocationUpdate: ((CLLocation) -> Void)?
    private var cancelJourneyTimeout: (() -> Void)?
    private(set) var journeyTrackingDeadline: Date?
    private var journeyStations: [CLLocation] = []
    private var trackedJourneyKey: String?
    private var lastActivityExpirationCheck: Date?

    /// Shared startup/foreground entry point; location never waits on schedule networking.
    func refreshForForeground() {
        isInBackground = false
        guard LocationInteractionPolicy.isAuthorized(authorizationStatus) else { return }
        startUpdatingLocation()
        requestLocation()
    }

    func beginJourneyTracking(stations: [Station] = []) {
        let startedAt = now()
        var deadline = startedAt.addingTimeInterval(2 * 60 * 60)
        if let session = journeySession(), session.isActive(at: startedAt) {
            trackedJourneyKey = session.key
            deadline = min(deadline, ScheduledTripExpiration.deadline(arrivalDate: session.arrival))
        }
        if !stations.isEmpty { journeyStations = stations.map(\.location) }
        guard !isInBackground,
              LocationInteractionPolicy.isAuthorized(manager.authorizationStatus) else { return }
        if let existing = journeyTrackingDeadline, existing <= deadline { return }
        cancelJourneyTimeout?()
        journeyTrackingDeadline = deadline
        trackingChanged(journeyTrackingDeadline, true)
        configureSampling()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        cancelJourneyTimeout = scheduleTimeout(deadline.timeIntervalSince(startedAt)) { [weak self] in self?.endJourneyTracking() }
    }

    @objc func endJourneyTracking() {
        endJourneyTracking(reloadWidgets: true)
    }

    func endJourneyTracking(reloadWidgets: Bool) {
        let wasTracking = journeyTrackingDeadline != nil
        cancelJourneyTimeout?()
        cancelJourneyTimeout = nil
        journeyTrackingDeadline = nil
        trackedJourneyKey = nil
        // Arrival callers publish the return route and reload both widgets afterward.
        trackingChanged(nil, wasTracking && reloadWidgets)
        configureSampling()
        manager.allowsBackgroundLocationUpdates = false
        if isInBackground { manager.stopUpdatingLocation() }
    }

    func reconcileSharedRoute(_ route: SharedRouteCoordinator.Route, previousRevision: Int?) {
        if let trackedJourneyKey, route.journey?.key == trackedJourneyKey,
           route.journey?.termination != nil || route.journey?.completed == true {
            endJourneyTracking()
            return
        }
        guard journeyTrackingDeadline != nil, let previousRevision, route.revision > previousRevision else { return }
        if route.endsJourneyTracking || route.journey?.termination != nil {
            endJourneyTracking()
        }
    }

    override convenience init() {
        #if os(iOS)
        self.init(manager: CLLocationManager())
        #else
        fatalError("Inject a location manager in command-line tests")
        #endif
    }

    init(manager: any LocationManaging, now: @escaping () -> Date = Date.init,
         journeySession: @escaping () -> JourneyProgressSession? = { SharedRouteCoordinator.current()?.journey },
         scheduleTimeout: @escaping (TimeInterval, @escaping () -> Void) -> () -> Void = { interval, action in
             let target = LocationTimeoutTarget(action: action)
             let timer = Timer.scheduledTimer(timeInterval: interval, target: target,
                 selector: #selector(LocationTimeoutTarget.fire), userInfo: nil, repeats: false)
             return { timer.invalidate() }
         },
         trackingChanged: @escaping (Date?, Bool) -> Void = { deadline, reloadWidgets in
             if let deadline { SharedJourneyTracking.begin(until: deadline) } else { SharedJourneyTracking.end() }
             if reloadWidgets { WidgetCenter.shared.reloadTimelines(ofKind: "NextPATCOLockScreenWidget") }
         },
         clearCachedLocation: @escaping () -> Void = { SharedCurrentLocationCache.clear() },
         expireActivities: @escaping () -> Void = {
             #if os(iOS)
             Task { @MainActor in await PATCOLiveActivityStarter.endExpiredActivities() }
             #endif
         }, recordError: @escaping (Error) -> Void = { error in
             ArrivalDiagnostics.record("Location request failed", detail: "\((error as NSError).domain), code \((error as NSError).code)")
         }) {
        self.manager = manager
        self.journeySession = journeySession
        self.now = now
        self.scheduleTimeout = scheduleTimeout
        self.trackingChanged = trackingChanged
        self.clearCachedLocation = clearCachedLocation
        self.expireActivities = expireActivities
        self.recordError = recordError
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 25
        manager.pausesLocationUpdatesAutomatically = true
    }

    private func configureSampling() {
        // A movement filter or automatic pause can suppress the stopped fixes needed for dwell confirmation.
        let active = LocationInteractionPolicy.shouldRunUpdates(authorization: manager.authorizationStatus,
            isForeground: !isInBackground, trackingDeadline: journeyTrackingDeadline, now: now())
        // Preserve frequent arrival fixes near stations; reduce sampling between stops.
        let nearStation = currentLocation.map { location in
            journeyStations.isEmpty || !LocationGuidancePolicy.isUsable(location, maxAge: 180, now: now())
                || journeyStations.contains { location.distance(from: $0) <= 750 + max(0, location.horizontalAccuracy) }
        } ?? true
        let precise = active && (!isInBackground || nearStation)
        let distanceFilter = precise ? kCLDistanceFilterNone : active ? 100.0 : 25.0
        let accuracy = precise ? kCLLocationAccuracyBest : kCLLocationAccuracyNearestTenMeters
        if manager.distanceFilter != distanceFilter { manager.distanceFilter = distanceFilter }
        if manager.desiredAccuracy != accuracy { manager.desiredAccuracy = accuracy }
        if manager.pausesLocationUpdatesAutomatically != !active {
            manager.pausesLocationUpdatesAutomatically = !active
        }
    }

    func requestLocation() {
        if LocationInteractionPolicy.isAuthorized(manager.authorizationStatus) {
            manager.requestLocation()
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            errorMessage = "Location is off. Pick a station manually."
        default:
            errorMessage = "Location status is unavailable."
        }
    }

    func startUpdatingLocation() {
        configureSampling()
        if LocationInteractionPolicy.isAuthorized(manager.authorizationStatus) {
            if LocationInteractionPolicy.shouldRunUpdates(authorization: manager.authorizationStatus,
                isForeground: !isInBackground, trackingDeadline: journeyTrackingDeadline, now: now()) {
                manager.startUpdatingLocation()
            }
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            errorMessage = "Location is off. Pick a station manually."
        default:
            errorMessage = "Location status is unavailable."
        }
    }

    func stopUpdatingLocation() {
        guard !LocationInteractionPolicy.shouldRunUpdates(authorization: manager.authorizationStatus,
            isForeground: false, trackingDeadline: journeyTrackingDeadline, now: now()) else { return }
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationDidChange()
    }

    func authorizationDidChange() {
        authorizationStatus = manager.authorizationStatus
        configureSampling()
        if LocationInteractionPolicy.isAuthorized(authorizationStatus) {
            if LocationInteractionPolicy.shouldRunUpdates(authorization: authorizationStatus,
                isForeground: !isInBackground, trackingDeadline: journeyTrackingDeadline, now: now()) {
                manager.startUpdatingLocation()
            } else {
                manager.stopUpdatingLocation()
            }
        } else {
            endJourneyTracking()
            manager.stopUpdatingLocation()
            currentLocation = nil
            lastUpdatedAt = nil
            clearCachedLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        receivedLocations(locations)
    }

    func receivedLocations(_ locations: [CLLocation]) {
        guard LocationInteractionPolicy.isAuthorized(manager.authorizationStatus) else { return }
        let orderedLocations = locations.sorted { $0.timestamp < $1.timestamp }
        guard let latest = orderedLocations.last else { return }
        let receivedAt = now()
        if lastActivityExpirationCheck.map({ receivedAt.timeIntervalSince($0) < 0
            || receivedAt.timeIntervalSince($0) >= 30 }) ?? true {
            lastActivityExpirationCheck = receivedAt
            expireActivities()
        }
        currentLocation = latest
        configureSampling()
        lastUpdatedAt = now()
        errorMessage = nil
        // SwiftUI can coalesce published changes; deliver each distinct fix directly for stop evidence.
        var deliveredAt: Date?
        for location in orderedLocations where location.timestamp != deliveredAt {
            deliveredAt = location.timestamp
            onLocationUpdate?(location)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        receivedError(error)
    }

    func receivedError(_ error: Error) {
        recordError(error)
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
