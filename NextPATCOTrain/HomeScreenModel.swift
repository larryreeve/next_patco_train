import ActivityKit
import CoreLocation
import MapKit
import Observation
import SwiftUI
import UIKit
import WidgetKit

/// Coordinates the home screen; presentation is kept in the Home* views.
@MainActor @Observable
final class HomeScreenModel {
    var liveTripRevision = 0
    let tripProgress: TripProgressStore
    let savedRouteStore: SavedRouteStore

    let locationProvider: LocationProvider
    let alertProvider: PATCOAlertProvider

    var isShowingScheduleDatePicker = false
    var departures: [Departure] = []
    var sharedTrip: SharedTripState.Snapshot?
    var isFindingNearestStation = false
    let routePreferences: RoutePreferences
    var selectedDeparture: Departure?
    var inAppBrowserURL: BrowserURL?
    var showsEarlierDepartures = false
    let refreshCoordinator: AppRefreshCoordinator
    var isRefreshing: Bool { refreshCoordinator.isRefreshing }
    #if DEBUG
    var isShowingAbout = ProcessInfo.processInfo.arguments.contains("-showInformation")
    #else
    var isShowingAbout = false
    #endif
    var isShowingLocationPermissionExplanation = false
    let travelEstimates: TravelEstimateController
    var reachabilityLocation: CLLocation?
    var lastReachabilityLocationUpdate: Date?
    var lastWidgetReachabilityReloadAt: Date?
    let widgetReloads: WidgetReloadCoordinator
    var pendingDepartureDeepLink: DepartureDeepLink?

    let reachabilityLocationMinInterval: TimeInterval = 30
    let reachabilityLocationMinDistance: CLLocationDistance = 250
    let widgetReachabilityReloadInterval: TimeInterval = 2 * 60
    let hidesPromotionalDates = ProcessInfo.processInfo.arguments.contains("-promotionalScreenshots")

    @ObservationIgnored private let defaults: UserDefaults
    var scenePhase: ScenePhase = .inactive
    var hasSeenLocationPermissionExplanation: Bool {
        get { defaults.bool(forKey: "hasSeenLocationPermissionExplanation") }
        set { defaults.set(newValue, forKey: "hasSeenLocationPermissionExplanation") }
    }

    init(schedule: HomeScheduleController = HomeScheduleController(),
         routePreferences: RoutePreferences = .live, defaults: UserDefaults = .standard,
         savedRouteStore: SavedRouteStore = SavedRouteStore(),
         tripProgress: TripProgressStore = .shared,
         locationProvider: LocationProvider = LocationProvider(),
         alertProvider: PATCOAlertProvider = PATCOAlertProvider(),
         refreshCoordinator: AppRefreshCoordinator = AppRefreshCoordinator(),
         travelEstimates: TravelEstimateController = TravelEstimateController(),
         widgetReloads: WidgetReloadCoordinator = WidgetReloadCoordinator()) {
        self.tripProgress = tripProgress
        self.savedRouteStore = savedRouteStore
        self.locationProvider = locationProvider
        self.alertProvider = alertProvider
        self.refreshCoordinator = refreshCoordinator
        self.travelEstimates = travelEstimates
        self.widgetReloads = widgetReloads
        self.schedule = schedule
        self.routePreferences = routePreferences
        self.defaults = defaults

    }

    let schedule: HomeScheduleController
    func applyCachedSpecialSchedules() { schedule.applyCachedSpecialSchedules() }
    func scheduleUpdated(_ defaultsChanged: Bool) {
        if defaultsChanged { route.applyDefaultsIfNeeded() } else { refreshDepartures() }
    }
    func forceGTFSUpdate(progress: @escaping @MainActor (PATCOGTFSUpdateService.UpdateStage) -> Void) async -> String {
        await schedule.forceGTFSUpdate(progress: progress, onUpdated: scheduleUpdated,
            onReload: { [weak self] in self?.requestWidgetReload(reason: $0, force: true) })
    }
    func refreshScheduleFeed() async {
        await schedule.refreshScheduleFeed(onUpdated: scheduleUpdated,
            onReload: { [weak self] in self?.requestWidgetReload(reason: $0, force: true) })
    }
    func checkFutureSpecialSchedule(for date: Date) async {
        await schedule.checkFutureSpecialSchedule(for: date, onUpdated: refreshDepartures)
    }

    @ObservationIgnored lazy var route = HomeRouteController(
        schedule: schedule, locationProvider: locationProvider,
        savedRouteStore: savedRouteStore, routePreferences: routePreferences, tripProgress: tripProgress,
        refreshDepartures: { [weak self] in self?.refreshDepartures() },
        reloadWidgets: { [weak self] in self?.requestWidgetReload(reason: $0, force: $1) },
        displayedDepartures: { [weak self] in self?.departures ?? [] },
        isActive: { [weak self] in self?.scenePhase == .active })

    @ObservationIgnored private lazy var journeyLocations = JourneyLocationWorkflow(
        progress: tripProgress, locationProvider: locationProvider, store: schedule.store,
        endActivities: { [tripProgress] name in Task { await PATCOLiveActivityStarter.endActivities(arrivingAt: name, tripProgress: tripProgress) } },
        reloadWidgets: { [weak self] in self?.requestWidgetReload(reason: $0, force: true) })

    var reachability: HomeReachabilityPresentation {
        .init(isViewingToday: schedule.isViewingToday, departures: departures, sharedTrip: sharedTrip,
              authorizationStatus: locationProvider.authorizationStatus, reachabilityLocation: reachabilityLocation,
              isUsingTemporaryStationRoute: route.isUsingTemporaryStationRoute,
              drivingEstimateInFlight: travelEstimates.drivingEstimateInFlight,
              driveTimeEstimate: travelEstimates.driveTimeEstimate, walkingTimeEstimate: travelEstimates.walkingTimeEstimate)
    }
    var visibleAlerts: [VisibleAlert] {
        alertProvider.alerts.compactMap(VisibleAlert.init)
    }

    var isRefreshInProgress: Bool {
        isRefreshing || alertProvider.isLoading || schedule.specialSchedules.isLoading
    }

    func prepareLocationAccess() {
        DestinationRegionMonitor.shared.start(requestAuthorization: true)
        switch locationProvider.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            hasSeenLocationPermissionExplanation = true
            startLocationUpdatesIfAuthorized()
        case .notDetermined:
            isShowingLocationPermissionExplanation = !hasSeenLocationPermissionExplanation
        case .denied, .restricted:
            hasSeenLocationPermissionExplanation = true
        @unknown default:
            break
        }
    }

    func startLocationUpdatesIfAuthorized() {
        locationProvider.refreshForForeground()
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        scenePhase = phase
        locationProvider.isInBackground = phase != .active
        if phase == .active {
            // Reopening the app at the return origin is a new opportunity to track a trip.
            route.resetArrivalSuppression()
            startLocationUpdatesIfAuthorized()
            refreshForForeground()
            route.publishAppRoute()
            requestWidgetReload(reason: "App route takes priority", force: true)
        } else {
            locationProvider.stopUpdatingLocation()
            route.publishAppRoute()
        }
    }

    func requestLocationAccess() {
        locationProvider.startUpdatingLocation()
    }

    func requestWidgetReload(reason: String, force: Bool = false) {
        guard scenePhase == .active || force else { return }
        widgetReloads.request(reason: reason, force: force, isActive: { [weak self] in self?.scenePhase == .active }) { [weak self] now in
            guard let self else { return }
            // Publish a matching snapshot before asking another process to render this revision.
            if let committedRoute = SharedRouteCoordinator.current() {
                let dates = (-1...1).compactMap { schedule.patcoCalendar.date(byAdding: .day, value: $0, to: now) }
                _ = SharedTripState.update(store: schedule.store, routeRevision: committedRoute.revision,
                    location: locationProvider.currentLocation,
                    locationAllowed: LocationInteractionPolicy.isAuthorized(locationProvider.authorizationStatus),
                    specialSchedules: SharedSpecialScheduleCache.schedules(matching: dates, calendar: schedule.patcoCalendar))
            }
        }
    }

    func refreshForForeground() {
        SharedWidgetDiagnostics.record("App foregrounded", detail: "Refreshing app data")
        Task {
            await PATCOLiveActivityStarter.endExpiredActivities(tripProgress: tripProgress)
            await refreshAll()
        }
    }

    @MainActor
    func findNearestStation() async {
        guard !isFindingNearestStation, schedule.isViewingToday else { return }
        route.publishAppRoute()
        guard let previous = SharedRouteCoordinator.current() else { return }
        isFindingNearestStation = true
        route.nearestStationMessage = nil
        defer { isFindingNearestStation = false }
        let requestedAt = Date()
        locationProvider.requestLocation()
        var request = NearestStationSelectionRequest(expectedRevision: previous.revision, requestedAt: requestedAt)
        while true {
            let outcome = request.poll(location: locationProvider.currentLocation,
                authorization: locationProvider.authorizationStatus, isForeground: scenePhase == .active,
                isViewingToday: schedule.isViewingToday, cancelled: Task.isCancelled, stations: schedule.store.stations)
            switch outcome {
            case .waiting:
                break
            case .cancelled:
                return
            case .denied, .timedOut, .routeChanged, .staleLocation, .inaccurateLocation,
                 .ambiguousStation, .invalidLocation, .stationsUnavailable:
                route.nearestStationMessage = outcome.failureMessage
                SharedWidgetDiagnostics.record("Nearest station selection failed", detail: outcome.failureMessage ?? "Unknown reason")
                return
            case .selected(let selected):
                if let location = locationProvider.currentLocation {
                    SharedWidgetDiagnostics.record("Nearest station selected", detail:
                        "\(request.usedRecentLocationFallback ? "Recent reading fallback" : "Fresh reading"); "
                        + "age \(Int(Date().timeIntervalSince(location.timestamp))) sec; accuracy \(Int(location.horizontalAccuracy)) m")
                }
                routePreferences.clearJourneyDirection()
                routePreferences.clearManualStationSelection()
                route.publishAppRoute()
                route.resetArrivalSuppression()
                route.nearestRouteStationName = route.selectedStation(selected.originId)?.name
                updateReachabilityLocationIfNeeded(locationProvider.currentLocation, force: true)
                refreshDepartures()
                requestWidgetReload(reason: "Nearest station selected", force: true)
                return
            }
            do { try await Task.sleep(nanoseconds: 200_000_000) }
            catch { return }
        }
    }

    func performReachabilityLocationAction() {
        switch locationProvider.authorizationStatus {
        case .denied, .restricted:
            guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(settingsURL)
        case .notDetermined:
            requestLocationAccess()
        default:
            locationProvider.requestLocation()
        }
    }

    func locationFreshnessText(for timestamp: Date) -> String {
        let minutes = max(1, Int(Date().timeIntervalSince(timestamp) / 60))
        return minutes == 1 ? "Location updated 1 min ago" : "Location updated \(minutes) mins ago"
    }

    var routeSummary: String {
        guard let origin = route.selectedStation(route.originId), let destination = route.selectedStation(route.destinationId) else {
            return "Lindenwold to 15/16th and Locust"
        }

        return "\(origin.name) to \(destination.name)"
    }

    var routeDetailSummary: String? {
        guard let departure = departures.first(where: { !$0.isRemovedBySpecialSchedule }) else { return nil }

        return "\(departure.directionLabel) • \(departure.travelMinutes) min ride"
    }

    func updateReachabilityLocationIfNeeded(_ location: CLLocation?, force: Bool = false) {
        guard let location, LocationGuidancePolicy.isUsable(location) else {
            if let previousLocation = reachabilityLocation,
               LocationGuidancePolicy.isUsable(previousLocation) {
                return
            }
            reachabilityLocation = nil
            lastReachabilityLocationUpdate = nil
            travelEstimates.driveTimeEstimate = nil
            travelEstimates.walkingTimeEstimate = nil
            refreshDepartures()
            return
        }

        let now = Date()
        let shouldUpdate: Bool
        if force || reachabilityLocation == nil || lastReachabilityLocationUpdate == nil {
            shouldUpdate = true
        } else if let reachabilityLocation,
                  location.distance(from: reachabilityLocation) >= reachabilityLocationMinDistance {
            shouldUpdate = true
        } else if let lastReachabilityLocationUpdate,
                  now.timeIntervalSince(lastReachabilityLocationUpdate) >= reachabilityLocationMinInterval {
            shouldUpdate = true
        } else {
            shouldUpdate = false
        }

        guard shouldUpdate else {
            // Fresh stationary fixes should renew freshness without recalculating travel estimates.
            if let previousLocation = reachabilityLocation,
               location.timestamp > previousLocation.timestamp {
                reachabilityLocation = location
            }
            return
        }

        reachabilityLocation = location
        lastReachabilityLocationUpdate = now
        if let origin = route.selectedStation(route.originId),
           LocationGuidancePolicy.isAtStation(location, station: origin.location),
           SharedReachabilityModeStore.clearOnArrival(originId: origin.id) {
            requestWidgetReload(reason: "Arrived at station", force: true)
            lastWidgetReachabilityReloadAt = now
        } else if lastWidgetReachabilityReloadAt.map({
            now.timeIntervalSince($0) >= widgetReachabilityReloadInterval
        }) ?? true {
            requestWidgetReload(reason: "Location changed")
            lastWidgetReachabilityReloadAt = now
        }
        refreshDepartures()
    }

    func handleLocationUpdate(_ location: CLLocation?) {
        guard journeyLocations.receive(location, isViewingToday: schedule.isViewingToday,
                                       displayedRevision: route.sharedRouteRevision) else { return }
        if let location {
            let destination = route.selectedStation(route.destinationId)
            let nearestStation = schedule.store.nearestStation(to: location)
            let detectedStation = route.stationAtCurrentLocation(location)
            let speed = location.speed.isFinite && location.speed >= 0
                ? "\(LocationDiagnosticFormatting.speedInMPH(location.speed)) (\(location.speed.formatted(.number.precision(.fractionLength(1)))) m/sec)" : "unavailable"
            let nearestDistance = nearestStation.map { "\(Int(location.distance(from: $0.location).rounded())) m" } ?? "unknown"
            let distance = destination.map { "\(Int(location.distance(from: $0.location).rounded())) m" } ?? "unknown"
            ArrivalDiagnostics.record("Location reading", detail: "Age \(Int(Date().timeIntervalSince(location.timestamp))) sec; accuracy \(Int(location.horizontalAccuracy)) m; speed \(speed); nearest station \(nearestStation?.name ?? "unknown") (\(nearestDistance)); nearby station candidate \(detectedStation?.name ?? "none"); origin \(route.selectedStation(route.originId)?.name ?? "none"); destination \(destination?.name ?? "none"); destination distance \(distance); \(LocationDiagnosticFormatting.eligibility(location)); inside destination boundary \(destination.map { LocationGuidancePolicy.isAtStation(location, station: $0.location) } ?? false)")
        }
        if let location, LocationGuidancePolicy.isUsable(location) {
            SharedCurrentLocationCache.save(location)
        }

        let detectedStationId = location.flatMap { route.stationAtCurrentLocation($0)?.id }
        let crossedStationBoundary = detectedStationId != route.currentStationId

        var transaction = Transaction()
        transaction.disablesAnimations = crossedStationBoundary
        withTransaction(transaction) {
            route.applyNearestStation(location)
            if scenePhase == .active {
                updateReachabilityLocationIfNeeded(location, force: crossedStationBoundary)
            }
        }
    }

    func openDirections(to station: Station, mode: StationTravelMode) {
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: station.coordinate))
        destination.name = "\(station.name) PATCO Station"
        destination.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: mode.mapsDirectionsMode
        ])
    }

    func setReachabilityMode(_ mode: StationTravelMode) {
        guard let origin = route.selectedStation(route.originId) else { return }

        showsEarlierDepartures = false
        SharedReachabilityModeStore.save(mode: mode.sharedMode, originId: origin.id)
        refreshReachabilityModeSelection()
    }

    func refreshReachabilityModeSelection() {
        showsEarlierDepartures = false
        refreshDepartures()
        requestWidgetReload(reason: "Reachability mode changed", force: true)
        if let origin = route.selectedStation(route.originId) {
            Task { await refreshTravelTimeEstimatesIfNeeded(origin: origin) }
        }
    }

    func tripStops(for departure: Departure) -> [TripDetailStop] {
        departure.trip.stopTimes
            .filter { $0.sequence >= departure.originTime.sequence && $0.sequence <= departure.destinationTime.sequence }
            .sorted { $0.sequence < $1.sequence }
            .compactMap { stopTime in
                schedule.store.station(for: stopTime.stopId).map {
                    TripDetailStop(station: $0, stopTime: stopTime)
                }
            }
    }

    func refreshDepartures() {
        route.publishAppRoute()
        guard let origin = route.selectedStation(route.originId), let destination = route.selectedStation(route.destinationId), origin != destination else {
            departures = []
            return
        }

        let now = Date()
        if !schedule.isViewingToday {
            sharedTrip = nil
            let selectedDay = schedule.patcoCalendar.startOfDay(for: schedule.selectedScheduleDate)
            departures = schedule.store.departures(
                from: origin,
                to: destination,
                after: selectedDay,
                limit: nil
            )
                .filter { schedule.patcoCalendar.isDate($0.departureDate, inSameDayAs: selectedDay) }
            resolvePendingDepartureDeepLink()
            return
        }

        let permission = locationProvider.authorizationStatus
        let update = route.sharedRouteRevision.flatMap {
            SharedTripState.update(store: schedule.store, routeRevision: $0,
                                   location: reachabilityLocation ?? locationProvider.currentLocation ?? SharedCurrentLocationCache.location(),
                                   locationAllowed: permission == .authorizedAlways || permission == .authorizedWhenInUse,
                                   now: now, specialSchedules: schedule.sharedSpecialSchedules)
        }
        sharedTrip = update?.snapshot ?? SharedTripState.current()
        if update?.shouldReloadWidgets == true { requestWidgetReload(reason: "Shared trip state updated") }
        let upcomingDepartures = sharedTrip?.upcoming(at: now) ?? schedule.store.departures(
            from: origin,
            to: destination,
            after: now,
            limit: nil
        )
        let todayDepartures = upcomingDepartures.filter {
            schedule.patcoCalendar.isDate($0.departureDate, inSameDayAs: now)
        }

        if todayDepartures.count >= 3 {
            departures = todayDepartures
        } else {
            let nextDayDepartures = upcomingDepartures
                .filter { !schedule.patcoCalendar.isDate($0.departureDate, inSameDayAs: now) }
                .prefix(3 - todayDepartures.count)
            departures = todayDepartures + nextDayDepartures
        }

        Task {
            await refreshTravelTimeEstimatesIfNeeded(origin: origin)
        }

        resolvePendingDepartureDeepLink()
    }

    func handleDeepLink(_ url: URL) {
        if url.host == "widget" {
            refreshForForeground()
            return
        }

        guard let deepLink = DepartureDeepLink(url: url) else {
            return
        }

        pendingDepartureDeepLink = deepLink
        resolvePendingDepartureDeepLink()
    }

    func resolvePendingDepartureDeepLink() {
        guard let deepLink = pendingDepartureDeepLink else {
            return
        }

        guard let departure = schedule.store.departure(matching: deepLink) else {
            return
        }

        selectedDeparture = departure
        pendingDepartureDeepLink = nil
    }

    @MainActor
    func refreshTravelTimeEstimatesIfNeeded(origin: Station) async {
        guard scenePhase == .active else { return }
        if reachability.currentReachabilityMode == .driving {
            await refreshDriveTimeEstimate(origin: origin, force: false)
        } else {
            await refreshWalkingTimeEstimate(origin: origin, force: false)
        }
        guard scenePhase == .active, schedule.isViewingToday, route.originId == origin.id, let revision = route.sharedRouteRevision else { return }
        let permission = locationProvider.authorizationStatus
        if let update = SharedTripState.update(store: schedule.store, routeRevision: revision,
                                  location: reachabilityLocation ?? locationProvider.currentLocation,
                                  locationAllowed: permission == .authorizedAlways || permission == .authorizedWhenInUse,
                                  specialSchedules: schedule.sharedSpecialSchedules) {
            sharedTrip = update.snapshot
            if update.shouldReloadWidgets { requestWidgetReload(reason: "Shared travel guidance updated") }
        }
    }

    @MainActor
    var travelEstimateContext: TravelEstimateController.Context {
        .init(isActive: scenePhase == .active, isViewingToday: schedule.isViewingToday, originId: route.originId,
              routeRevision: route.sharedRouteRevision, location: reachability.usableReachabilityLocation,
              authorization: locationProvider.authorizationStatus)
    }

    @MainActor
    func refreshWalkingTimeEstimate(origin: Station, force: Bool) async {
        await travelEstimates.refreshWalkingTimeEstimate(origin: origin, force: force, context: { travelEstimateContext })
    }

    @MainActor
    func refreshDriveTimeEstimate(origin: Station, force: Bool) async {
        await travelEstimates.refreshDriveTimeEstimate(origin: origin, force: force, context: { travelEstimateContext })
    }

    @MainActor
    func refreshAll(forceSpecialScheduleRefresh: Bool = false) async {
        applyCachedSpecialSchedules()
        refreshDepartures()
        await refreshCoordinator.refresh(requestLocation: {
            if LocationInteractionPolicy.isAuthorized(locationProvider.authorizationStatus) {
                locationProvider.requestLocation()
            }
            updateReachabilityLocationIfNeeded(locationProvider.currentLocation, force: true)
        }, specialSchedules: {
            await schedule.specialSchedules.refreshNow(for: schedule.selectedScheduleDate, force: forceSpecialScheduleRefresh)
            guard !Task.isCancelled else { return }
            applyCachedSpecialSchedules()
            refreshDepartures()
            requestWidgetReload(reason: "Special schedules refreshed")
        }, scheduleFeed: {
            await refreshScheduleFeed()
        }, alerts: {
            await alertProvider.refreshNow()
        }, travelEstimates: {
            guard let origin = route.selectedStation(route.originId) else { return }
            async let walking: Void = refreshWalkingTimeEstimate(origin: origin, force: true)
            async let driving: Void = refreshDriveTimeEstimate(origin: origin, force: true)
            _ = await (walking, driving)
            guard !Task.isCancelled else { return }
            refreshDepartures()
            requestWidgetReload(reason: "Travel estimates refreshed")
        })
    }

}

struct ArrivalAnnouncement: Identifiable, Equatable {
    let id = UUID()
    let stationName: String
    let returnStationName: String
    var inferredArrival = false
}
