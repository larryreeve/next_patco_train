import ActivityKit
import CoreLocation
import MapKit
import SwiftUI
import WidgetKit
import AppIntents

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Next PATCO Train"
    static let description = IntentDescription("Shows upcoming scheduled PATCO trains.")
}

struct PATCOTrainEntry: TimelineEntry {
    let date: Date
    let refreshedAt: Date
    let departures: [Departure]
    let catchStatuses: [UUID: WidgetCatchStatus]
    let routeTitle: String
    let specialScheduleTitle: String?
    let timeZone: TimeZone
    let originId: Station.ID?
    let reachabilityMode: SharedReachabilityModeStore.Mode?
    let scheduleExpired: Bool
    let locationTimestamp: Date?
    let locationFreshness: WidgetLocationFreshness
    let manualLocationRefreshFailed: Bool
}

enum WidgetLocationFreshness {
    case fresh
    case recent
    case unavailable
}

struct NextPATCOTrainWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PATCOTrainEntry {
        PATCOTrainEntry(
            date: Date(),
            refreshedAt: Date(),
            departures: [],
            catchStatuses: [:],
            routeTitle: "Ashland to Locust",
            specialScheduleTitle: "Special schedule",
            timeZone: TimeZone(identifier: "America/New_York") ?? .current,
            originId: nil,
            reachabilityMode: nil,
            scheduleExpired: false,
            locationTimestamp: nil,
            locationFreshness: .unavailable,
            manualLocationRefreshFailed: false
        )
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> PATCOTrainEntry {
        let now = Date()
        let location = await WidgetLocationProvider.currentLocation()
        return makeEntry(at: now, refreshedAt: now, specialSchedules: [], currentLocation: location)
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<PATCOTrainEntry> {
        let now = Date()
        let diagnosticRunID = SharedWidgetDiagnostics.beginWidgetRun()
        let location = await WidgetLocationProvider.currentLocation(diagnosticRunID: diagnosticRunID)
        let specialSchedules = await specialSchedulesForDepartureWindow(from: now)
        let store = PATCOScheduleStore()
        store.applySpecialSchedules(specialSchedules)
        let route = selectedRoute(in: store, currentLocation: location)
        if SharedRouteDefaults.recordHomeWidgetRoute(originId: route.origin?.id, destinationId: route.destination?.id) {
            WidgetCenter.shared.reloadTimelines(ofKind: "NextPATCOLockScreenWidget")
        }
        await refreshTravelTimeEstimate(
            at: now,
            store: store,
            currentLocation: location
        )
        // Future entries keep departure times moving if iOS delays a requested
        // timeline reload. They do not wake the extension on their own.
        let departures = route.origin.flatMap { origin in
            route.destination.map { store.departures(from: origin, to: $0, after: now, limit: 500) }
        } ?? []
        let entryDates = WidgetTimelinePolicy.entryDates(now: now, departures: departures.map(\.departureDate))
        let entries = entryDates.map { entryDate in
            return makeEntry(
                at: entryDate,
                refreshedAt: now,
                specialSchedules: specialSchedules,
                currentLocation: location,
                loadedStore: store,
                resolvedRoute: route
            )
        }
        let hasUpcomingService = entries.contains { !$0.departures.isEmpty }
        let refreshInterval: TimeInterval = hasUpcomingService ? 10 * 60 : 30 * 60
        let nextRefresh = now.addingTimeInterval(refreshInterval)
        SharedWidgetDiagnostics.finishWidgetRun(
            diagnosticRunID,
            departureCount: entries.first?.departures.count,
            nextReloadAt: nextRefresh
        )
        return Timeline(entries: entries, policy: .after(nextRefresh))
    }

    private func refreshTravelTimeEstimate(
        at date: Date,
        store: PATCOScheduleStore,
        currentLocation: CLLocation?
    ) async {
        guard let currentLocation else { return }

        let route = selectedRoute(in: store, currentLocation: currentLocation)
        guard let origin = route.origin,
              let destination = route.destination,
              let firstDeparture = store.departures(
                from: origin,
                to: destination,
                after: date,
                limit: 1
              ).first,
              let mode = WidgetCatchStatus.reachabilityMode(
                for: firstDeparture,
                currentLocation: currentLocation,
                now: date
              ) else {
            return
        }

        await WidgetTravelTimeEstimator.refresh(
            mode: mode,
            origin: origin,
            currentLocation: currentLocation
        )
    }

    private var patcoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }

    private func makeEntry(
        at date: Date,
        refreshedAt: Date,
        specialSchedules: [PATCOSpecialSchedule],
        currentLocation: CLLocation?,
        loadedStore: PATCOScheduleStore? = nil,
        resolvedRoute: (origin: Station?, destination: Station?)? = nil
    ) -> PATCOTrainEntry {
        let store = loadedStore ?? PATCOScheduleStore()
        if loadedStore == nil && !specialSchedules.isEmpty {
            store.applySpecialSchedules(specialSchedules)
        }

        let calendar = patcoCalendar
        let usableLocation = currentLocation.flatMap { location in
            date.timeIntervalSince(location.timestamp) <= 15 * 60 ? location : nil
        }
        let locationFreshness = Self.locationFreshness(for: usableLocation, at: date)
        let route = resolvedRoute ?? selectedRoute(in: store, currentLocation: usableLocation)
        let departures = route.origin.flatMap { origin in
            route.destination.map { destination in
                store.departures(from: origin, to: destination, after: date, limit: 20)
            }
        } ?? []
        let reachabilityMode = locationFreshness == .fresh
            ? WidgetCatchStatus.reachabilityMode(
                for: departures.first,
                currentLocation: usableLocation,
                now: date
            )
            : nil
        let catchStatuses: [UUID: WidgetCatchStatus]
        if locationFreshness == .fresh {
            catchStatuses = Dictionary(uniqueKeysWithValues: departures.compactMap { departure -> (UUID, WidgetCatchStatus)? in
                guard let status = WidgetCatchStatus(
                    departure: departure,
                    currentLocation: usableLocation,
                    now: date,
                    reachabilityMode: reachabilityMode
                ) else {
                    return nil
                }

                return (departure.id, status)
            })
        } else {
            catchStatuses = [:]
        }

        return PATCOTrainEntry(
            date: date,
            refreshedAt: refreshedAt,
            departures: departures,
            catchStatuses: catchStatuses,
            routeTitle: routeTitle(origin: route.origin, destination: route.destination),
            specialScheduleTitle: specialSchedules.first(where: { calendar.isDate($0.serviceDate, inSameDayAs: departures.first?.serviceDate ?? date) })?.title,
            timeZone: calendar.timeZone,
            originId: route.origin?.id,
            reachabilityMode: reachabilityMode?.sharedMode,
            scheduleExpired: store.feed?.isExpired(on: date) ?? true,
            locationTimestamp: usableLocation?.timestamp,
            locationFreshness: locationFreshness,
            manualLocationRefreshFailed: usableLocation == nil && WidgetRefreshState.hasRecentLocationFailure
        )
    }

    private static func locationFreshness(for location: CLLocation?, at date: Date) -> WidgetLocationFreshness {
        guard let location else { return .unavailable }

        let age = date.timeIntervalSince(location.timestamp)
        if age <= 3 * 60 {
            return .fresh
        }
        if age <= 15 * 60 {
            return .recent
        }
        return .unavailable
    }

    private func specialSchedulesForDepartureWindow(from date: Date) async -> [PATCOSpecialSchedule] {
        let calendar = patcoCalendar
        let dates = (-1...1).compactMap { calendar.date(byAdding: .day, value: $0, to: date) }
        let cached = SharedSpecialScheduleCache.schedules(matching: dates, calendar: calendar)
        return await withTaskGroup(of: [PATCOSpecialSchedule]?.self) { group in
            group.addTask {
                await SharedSpecialScheduleCache.refreshIfNeeded(from: date, calendar: calendar).schedules
            }
            group.addTask {
                do { try await Task.sleep(nanoseconds: 4_000_000_000) }
                catch { return nil }
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result ?? cached
        }
    }

    fileprivate func selectedRoute(in store: PATCOScheduleStore, currentLocation: CLLocation?) -> (origin: Station?, destination: Station?) {
        if let route = SharedAppRouteAuthority.current(),
           let origin = store.station(for: route.originId),
           let destination = store.station(for: route.destinationId) {
            return (origin, destination)
        }
        var routePair: (first: Station?, second: Station?)
        if let currentLocation,
           let temporaryRoute = SharedRouteDefaults.temporaryRoute(),
           let temporaryOrigin = store.station(for: temporaryRoute.originId),
           let temporaryDestination = store.station(for: temporaryRoute.destinationId),
           temporaryOrigin != temporaryDestination,
           temporaryOrigin.location.distance(from: currentLocation) <= 150 {
            routePair = (temporaryOrigin, temporaryDestination)
        } else if let savedRoute = SharedRouteDefaults.savedRoute() {
            let origin = store.station(for: savedRoute.originId)
            let destination = store.station(for: savedRoute.destinationId)
            if origin != nil, destination != nil, origin != destination {
                routePair = (origin, destination)
            } else {
                routePair = (station(named: "Lindenwold", in: store), store.locust)
            }
        } else {
            routePair = (station(named: "Lindenwold", in: store), store.locust)
        }

        let saved = SharedRouteDefaults.savedRoute()
        let remembered = saved.flatMap { SharedWidgetRouteMemory.load(savedOriginId: $0.originId, savedDestinationId: $0.destinationId) }
        if let remembered, let origin = store.station(for: remembered.originId), let destination = store.station(for: remembered.destinationId) {
            routePair = (origin, destination)
        }
        func remember(_ origin: Station, _ destination: Station) -> (origin: Station?, destination: Station?) {
            if let saved {
                SharedWidgetRouteMemory.save(originId: origin.id, destinationId: destination.id, savedOriginId: saved.originId, savedDestinationId: saved.destinationId)
            }
            return (origin, destination)
        }
        guard let firstStation = routePair.first,
              let secondStation = routePair.second else {
            return (routePair.first, routePair.second)
        }

        // Widgets may resolve a station independently only when the app lease has expired.
        if let location = currentLocation,
           (0...120).contains(Date().timeIntervalSince(location.timestamp)),
           location.horizontalAccuracy > 0, location.horizontalAccuracy <= 75,
           let station = store.nearestStation(to: location),
           location.distance(from: station.location) + location.horizontalAccuracy <= 150 {
            if station.id == secondStation.id {
                let returnId = SharedWidgetRouteMemory.returnDestination(
                    arrivingAt: secondStation.id, currentOrigin: firstStation.id,
                    savedOrigin: saved?.originId, savedDestination: saved?.destinationId
                )
                return remember(secondStation, store.station(for: returnId) ?? firstStation)
            }
            if station.id == firstStation.id { return remember(firstStation, secondStation) }
            return remember(station, secondStation)
        }

        if remembered != nil { return (firstStation, secondStation) }

        if let journeyDestinationId = SharedRouteDefaults.journeyDestinationId(),
           journeyDestinationId == firstStation.id || journeyDestinationId == secondStation.id {
            return journeyDestinationId == firstStation.id
                ? (secondStation, firstStation)
                : (firstStation, secondStation)
        }

        return (firstStation, secondStation)
    }

    private func routeTitle(origin: Station?, destination: Station?) -> String {
        guard let origin, let destination else {
            return "PATCO"
        }

        return "\(shortName(for: origin)) to \(shortName(for: destination))"
    }

    private func shortName(for station: Station) -> String {
        station.name == "15/16th and Locust" ? "15/16th" : station.name
    }

    private func station(named name: String, in store: PATCOScheduleStore) -> Station? {
        store.stations.first { $0.name == name }
    }
}

@MainActor
private final class BoundedWidgetDirections {
    private let directions: MKDirections
    private var continuation: CheckedContinuation<TimeInterval?, Never>?
    private var timeout: Task<Void, Never>?

    private init(_ request: MKDirections.Request) {
        directions = MKDirections(request: request)
    }

    static func calculate(_ request: MKDirections.Request) async -> TimeInterval? {
        let operation = BoundedWidgetDirections(request)
        return await withCheckedContinuation { continuation in
            operation.continuation = continuation
            operation.timeout = Task {
                do { try await Task.sleep(nanoseconds: 4_000_000_000) }
                catch { return }
                operation.directions.cancel()
                operation.finish(nil)
            }
            operation.directions.calculate { response, _ in
                let travelTime = response?.routes.first?.expectedTravelTime
                Task { @MainActor in operation.finish(travelTime) }
            }
        }
    }

    private func finish(_ response: TimeInterval?) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(returning: response)
    }
}

private enum WidgetTravelTimeEstimator {
    @MainActor
    static func refresh(
        mode: WidgetCatchStatus.TravelMode,
        origin: Station,
        currentLocation: CLLocation
    ) async {
        let distanceToStation = currentLocation.distance(from: origin.location)
        let cacheMode: SharedTravelTimeEstimateCache.Mode
        let transportType: MKDirectionsTransportType

        switch mode {
        case .walking:
            guard distanceToStation > 150,
                  distanceToStation <= 1.25 * 1_609.34 else {
                SharedTravelTimeEstimateCache.clear(mode: .walking)
                return
            }
            cacheMode = .walking
            transportType = .walking
        case .driving:
            guard distanceToStation > 150 else {
                SharedTravelTimeEstimateCache.clear(mode: .driving)
                return
            }
            cacheMode = .driving
            transportType = .automobile
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocation.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.transportType = transportType
        request.requestsAlternateRoutes = false

        guard let travelTime = await BoundedWidgetDirections.calculate(request) else { return }

        SharedTravelTimeEstimateCache.save(
            mode: cacheMode,
            origin: origin,
            currentLocation: currentLocation,
            minutes: max(1, Int(ceil(travelTime / 60)))
        )
    }
}

@MainActor
private final class WidgetLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let allowsCachedFallback: Bool
    private let requestStartedAt = Date()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var fallbackLocation: CLLocation?
    private var failureReason = "No usable fix"

    init(allowsCachedFallback: Bool) {
        self.allowsCachedFallback = allowsCachedFallback
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    static func currentLocation(
        allowsCachedFallback: Bool = true,
        diagnosticRunID: UUID? = nil
    ) async -> CLLocation? {
        let startedAt = Date()
        let effectiveAllowsCachedFallback = allowsCachedFallback
            && !SharedCurrentLocationCache.freshLocationRequired
        let cachedLocation = effectiveAllowsCachedFallback
            ? SharedCurrentLocationCache.location(maxAge: 15 * 60)
            : nil
        let provider = WidgetLocationProvider(allowsCachedFallback: effectiveAllowsCachedFallback)
        guard provider.manager.authorizationStatus == .authorizedAlways
                || provider.manager.authorizationStatus == .authorizedWhenInUse else {
            SharedCurrentLocationCache.clear()
            return nil
        }
        if let cachedLocation, LocationGuidancePolicy.isUsable(cachedLocation, now: startedAt) {
            if let diagnosticRunID {
                let age = Int(startedAt.timeIntervalSince(cachedLocation.timestamp))
                SharedWidgetDiagnostics.recordLocation(
                    "Reused recent shared location (\(age) sec old)",
                    duration: Date().timeIntervalSince(startedAt),
                    for: diagnosticRunID
                )
            }
            return cachedLocation
        }
        let requestedLocation = await provider.requestLocation()
        guard provider.manager.authorizationStatus == .authorizedAlways
                || provider.manager.authorizationStatus == .authorizedWhenInUse else {
            SharedCurrentLocationCache.clear()
            return nil
        }
        let bestLocation = [requestedLocation, cachedLocation]
            .compactMap { $0 }
            .max { $0.timestamp < $1.timestamp }
        if let bestLocation {
            SharedCurrentLocationCache.save(bestLocation)
        }
        if let diagnosticRunID {
            let outcome: String
            if let bestLocation {
                let age = max(0, Int(Date().timeIntervalSince(bestLocation.timestamp)))
                outcome = age <= 2 && bestLocation.timestamp >= startedAt.addingTimeInterval(-1)
                    ? "Fresh location"
                    : "Older location (\(age) sec old)"
            } else {
                outcome = provider.failureReason
            }
            SharedWidgetDiagnostics.recordLocation(
                outcome,
                duration: Date().timeIntervalSince(startedAt),
                for: diagnosticRunID
            )
        }
        return bestLocation
    }

    private func requestLocation() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.fallbackLocation = self.allowsCachedFallback
                ? usableFallback(from: manager.location)
                : nil
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await MainActor.run {
                    self?.failureReason = "Timed out"
                    self?.finish(with: self?.fallbackLocation)
                }
            }

            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .denied, .restricted:
                failureReason = "Location access denied"
                finish(with: nil)
            @unknown default:
                failureReason = "Location access unavailable"
                finish(with: nil)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            switch self.manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                self.manager.requestLocation()
            case .denied, .restricted:
                failureReason = "Location access denied"
                finish(with: nil)
            case .notDetermined:
                break
            @unknown default:
                failureReason = "Location access unavailable"
                finish(with: nil)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            let freshLocation = locations
                .filter { location in
                    location.horizontalAccuracy >= 0
                        && location.horizontalAccuracy <= 1_000
                        && abs(location.timestamp.timeIntervalSinceNow) <= 2 * 60
                        && (allowsCachedFallback || location.timestamp >= requestStartedAt.addingTimeInterval(-1))
                }
                .max { $0.timestamp < $1.timestamp }
            if let freshLocation {
                finish(with: freshLocation)
                return
            }

            fallbackLocation = ([fallbackLocation] + locations.map(Optional.some))
                .compactMap { usableFallback(from: $0) }
                .max { $0.timestamp < $1.timestamp }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            failureReason = "Core Location error"
            finish(with: fallbackLocation)
        }
    }

    private func usableFallback(from location: CLLocation?) -> CLLocation? {
        guard allowsCachedFallback,
              let location,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 1_000,
              abs(location.timestamp.timeIntervalSinceNow) <= 15 * 60 else {
            return nil
        }
        return location
    }

    private func finish(with location: CLLocation?) {
        guard let continuation else { return }

        timeoutTask?.cancel()
        timeoutTask = nil
        self.continuation = nil
        continuation.resume(returning: location)
    }
}

private enum SharedRouteDefaults {
    private static let suiteName = "group.com.rhome.patconext"
    private static let originKey = "defaultOriginStationId"
    private static let destinationKey = "defaultDestinationStationId"
    private static let temporaryOriginKey = "temporaryOriginStationId"
    private static let temporaryDestinationKey = "temporaryDestinationStationId"
    private static let temporarySavedAtKey = "temporaryRouteSavedAt"
    private static let journeyDestinationKey = "journeyDestinationStationId"
    private static let journeyDirectionSavedAtKey = "journeyDirectionSavedAt"
    private static let homeWidgetOriginKey = "homeWidgetOriginStationId"
    private static let homeWidgetDestinationKey = "homeWidgetDestinationStationId"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func savedRoute() -> (originId: Station.ID, destinationId: Station.ID)? {
        guard let originId = defaults.string(forKey: originKey),
              let destinationId = defaults.string(forKey: destinationKey),
              originId != destinationId else {
            return nil
        }

        return (originId, destinationId)
    }

    static func temporaryRoute(maxAge: TimeInterval = 12 * 60 * 60) -> (originId: Station.ID, destinationId: Station.ID)? {
        guard let originId = defaults.string(forKey: temporaryOriginKey),
              let destinationId = defaults.string(forKey: temporaryDestinationKey),
              let savedAt = defaults.object(forKey: temporarySavedAtKey) as? Date,
              Date().timeIntervalSince(savedAt) <= maxAge,
              originId != destinationId else {
            return nil
        }

        return (originId, destinationId)
    }

    static func journeyDestinationId(maxAge: TimeInterval = 4 * 60 * 60) -> Station.ID? {
        guard let destinationId = defaults.string(forKey: journeyDestinationKey),
              let savedAt = defaults.object(forKey: journeyDirectionSavedAtKey) as? Date,
              Date().timeIntervalSince(savedAt) <= maxAge else {
            return nil
        }
        return destinationId
    }

    static func recordHomeWidgetRoute(originId: Station.ID?, destinationId: Station.ID?) -> Bool {
        guard let originId, let destinationId else { return false }

        let changed = defaults.string(forKey: homeWidgetOriginKey) != originId
            || defaults.string(forKey: homeWidgetDestinationKey) != destinationId
        if changed {
            defaults.set(originId, forKey: homeWidgetOriginKey)
            defaults.set(destinationId, forKey: homeWidgetDestinationKey)
        }
        return changed
    }

}

enum WidgetCatchStatus: Equatable {
    case reachable
    case tight
    case likelyMiss

    private static let atStationMeters = 150.0
    private static let reachabilityMaxDistanceMeters = 150 * 1_609.34

    init?(
        departure: Departure,
        currentLocation: CLLocation?,
        now: Date,
        reachabilityMode: TravelMode?
    ) {
        guard let currentLocation else { return nil }

        let minutesUntilDeparture = Int(floor(departure.departureDate.timeIntervalSince(now) / 60))
        let distanceToStation = currentLocation.distance(from: departure.origin.location)
        guard distanceToStation <= Self.reachabilityMaxDistanceMeters else {
            return nil
        }

        if distanceToStation <= Self.atStationMeters {
            SharedReachabilityModeStore.clearOnArrival(originId: departure.origin.id)
            self = .reachable
            return
        }

        guard let travelMode = reachabilityMode ?? SharedReachabilityModeStore.resolve(
            originId: departure.origin.id,
            distanceToStation: distanceToStation,
            minutesUntilDeparture: minutesUntilDeparture,
            defaultsToWalking: departure.origin.defaultsToWalkingForReachability
        ).map(TravelMode.init) else {
            return nil
        }
        let travelMinutes = Self.travelMinutes(
            for: travelMode,
            meters: distanceToStation,
            origin: departure.origin,
            currentLocation: currentLocation
        )
        let stationAccessMinutes = travelMode == .driving ? 3 : 2
        let spareMinutes = minutesUntilDeparture - travelMinutes - stationAccessMinutes

        if spareMinutes >= 5 {
            self = .reachable
        } else if spareMinutes >= 0 {
            self = .tight
        } else {
            self = .likelyMiss
        }
    }

    var color: Color {
        switch self {
        case .reachable:
            Color(red: 0.43, green: 0.86, blue: 0.55)
        case .tight:
            Color.patcoGold
        case .likelyMiss:
            Color(red: 1.0, green: 0.50, blue: 0.56)
        }
    }

    var isMakeable: Bool {
        switch self {
        case .reachable, .tight:
            true
        case .likelyMiss:
            false
        }
    }

    enum TravelMode {
        case walking
        case driving

        init(_ sharedMode: SharedReachabilityModeStore.Mode) {
            self = sharedMode == .driving ? .driving : .walking
        }

        var sharedMode: SharedReachabilityModeStore.Mode {
            self == .driving ? .driving : .walking
        }
    }

    static func reachabilityMode(
        for departure: Departure?,
        currentLocation: CLLocation?,
        now: Date
    ) -> TravelMode? {
        guard let departure, let currentLocation else { return nil }

        let distanceToStation = currentLocation.distance(from: departure.origin.location)
        guard distanceToStation <= reachabilityMaxDistanceMeters else {
            return nil
        }

        guard distanceToStation > atStationMeters else {
            SharedReachabilityModeStore.clearOnArrival(originId: departure.origin.id)
            return nil
        }

        let minutesUntilDeparture = Int(floor(departure.departureDate.timeIntervalSince(now) / 60))
        guard let sharedMode = SharedReachabilityModeStore.resolve(
            originId: departure.origin.id,
            distanceToStation: distanceToStation,
            minutesUntilDeparture: minutesUntilDeparture,
            defaultsToWalking: departure.origin.defaultsToWalkingForReachability
        ) else {
            return nil
        }

        return TravelMode(sharedMode)
    }

    private static func travelMinutes(
        for mode: TravelMode,
        meters: CLLocationDistance,
        origin: Station,
        currentLocation: CLLocation
    ) -> Int {
        let cacheMode: SharedTravelTimeEstimateCache.Mode = mode == .walking ? .walking : .driving
        if let estimate = SharedTravelTimeEstimateCache.estimate(
            mode: cacheMode,
            origin: origin,
            currentLocation: currentLocation
        ) {
            return estimate.minutes
        }

        return travelMinutes(for: mode, meters: meters)
    }

    private static func travelMinutes(for mode: TravelMode, meters: CLLocationDistance) -> Int {
        switch mode {
        case .walking:
            return max(1, Int(ceil((meters / 1.25) / 60)))
        case .driving:
            let metersPerMinuteAt25MPH = 670.56
            return max(1, Int(ceil(meters / metersPerMinuteAt25MPH)))
        }
    }
}

private enum WidgetRefreshState {
    private static let suiteName = "group.com.rhome.patconext"
    private static let startedAtKey = "widgetRefreshStartedAt"
    private static let locationFailureAtKey = "widgetLocationRefreshFailedAt"
    private static let timeout: TimeInterval = 15
    private static let failureVisibility: TimeInterval = 2 * 60

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static var isRefreshing: Bool {
        guard let startedAt = defaults.object(forKey: startedAtKey) as? Date,
              Date().timeIntervalSince(startedAt) < timeout else {
            defaults.removeObject(forKey: startedAtKey)
            return false
        }
        return true
    }

    static func begin() -> Bool {
        guard !isRefreshing else { return false }
        defaults.set(Date(), forKey: startedAtKey)
        return true
    }

    static func finish() {
        defaults.removeObject(forKey: startedAtKey)
    }

    static func finish(locationAvailable: Bool) {
        finish()
        if locationAvailable {
            defaults.removeObject(forKey: locationFailureAtKey)
        } else {
            defaults.set(Date(), forKey: locationFailureAtKey)
        }
    }

    static var hasRecentLocationFailure: Bool {
        guard let failedAt = defaults.object(forKey: locationFailureAtKey) as? Date,
              Date().timeIntervalSince(failedAt) < failureVisibility else {
            defaults.removeObject(forKey: locationFailureAtKey)
            return false
        }
        return true
    }
}

struct RefreshPATCOWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh trains"
    static let description = IntentDescription("Refreshes departures and estimates whether you can catch the train.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        guard WidgetRefreshState.begin() else {
            return .result()
        }

        let diagnosticRunID = SharedWidgetDiagnostics.beginWidgetRun(manual: true)
        SharedCurrentLocationCache.requireFreshLocation()
        let location = await WidgetLocationProvider.currentLocation(
            allowsCachedFallback: false,
            diagnosticRunID: diagnosticRunID
        )
        SharedWidgetDiagnostics.finishWidgetRun(diagnosticRunID, manual: true)
        WidgetRefreshState.finish(locationAvailable: location != nil)
        return .result()
    }
}

struct TogglePATCOReachabilityModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch travel mode"
    static let description = IntentDescription("Switches between driving and walking estimates to the station.")
    static let openAppWhenRun = false

    @Parameter(title: "Origin station")
    var originId: String

    @Parameter(title: "Current mode")
    var currentMode: String

    init() {}

    init(originId: String, currentMode: SharedReachabilityModeStore.Mode) {
        self.originId = originId
        self.currentMode = currentMode.rawValue
    }

    func perform() async throws -> some IntentResult {
        let mode: SharedReachabilityModeStore.Mode = currentMode == SharedReachabilityModeStore.Mode.driving.rawValue
            ? .walking
            : .driving
        SharedReachabilityModeStore.save(mode: mode, originId: originId, isManual: true)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct NextPATCOTrainWidgetEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily

    let entry: PATCOTrainEntry

    var body: some View {
        VStack(alignment: .leading, spacing: widgetFamily == .systemSmall ? 6 : 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next PATCO Train")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.patcoGold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(entry.routeTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)

                    if entry.specialScheduleTitle != nil {
                        Label("Special schedule", systemImage: "calendar.badge.exclamationmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.patcoGold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                }
                .layoutPriority(1)

                Spacer()

                HStack(spacing: 6) {
                    if widgetFamily == .systemSmall && entry.locationFreshness == .unavailable {
                        Image(systemName: "location.slash")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.patcoGold)
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.10), in: Circle())
                            .accessibilityLabel("Location unavailable")
                    }

                    if let originId = entry.originId,
                       let reachabilityMode = entry.reachabilityMode {
                        Toggle(
                            isOn: reachabilityMode == .driving,
                            intent: TogglePATCOReachabilityModeIntent(
                            originId: originId,
                            currentMode: reachabilityMode
                            )
                        ) {
                            EmptyView()
                        }
                        .toggleStyle(WidgetReachabilityToggleStyle(mode: reachabilityMode))
                        .frame(width: 30, height: 30)
                        .accessibilityLabel(
                            reachabilityMode == .driving
                                ? "Driving estimate. Switch to walking"
                                : "Walking estimate. Switch to driving"
                        )
                    }

                    Toggle(isOn: false, intent: RefreshPATCOWidgetIntent()) {
                        EmptyView()
                    }
                    .toggleStyle(WidgetRefreshToggleStyle())
                    .frame(width: 30, height: 30)
                    .accessibilityLabel("Refresh departures and travel estimates")

                }
                .fixedSize(horizontal: true, vertical: false)
            }

            Group {
                if entry.departures.isEmpty {
                    Spacer()
                    Text(entry.scheduleExpired ? "Schedule update needed" : "No upcoming trains")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(
                        entry.scheduleExpired
                            ? "Open Next PATCO Train to download the current schedule."
                            : "Open Next PATCO Train to pick stations."
                    )
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.68))
                } else {
                    departureList
                }
            }

            Spacer(minLength: 0)

            Group {
                if widgetFamily != .systemSmall {
                    widgetStatusLine
                }
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color.patcoWine, Color.patcoCharcoal, Color.patcoRail],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .widgetURL(URL(string: "patconext://widget"))
    }

    @ViewBuilder
    private var departureList: some View {
        VStack(spacing: departureRowSpacing) {
            ForEach(displayedDepartures) { departure in
                departureRow(departure)
            }
        }
    }

    private var displayedDepartures: [Departure] {
        let departures = entry.departures
        guard widgetFamily == .systemSmall || widgetFamily == .systemMedium else {
            return Array(departures.prefix(displayLimit))
        }

        guard let firstMakeableIndex = departures.firstIndex(where: { departure in
            entry.catchStatuses[departure.id]?.isMakeable == true
        }) else {
            return Array(departures.prefix(displayLimit))
        }

        let startIndex = firstMakeableIndex > departures.startIndex
            ? departures.index(before: firstMakeableIndex)
            : firstMakeableIndex
        var selected = Array(departures[startIndex...].prefix(displayLimit))

        if selected.count < displayLimit {
            let selectedIds = Set(selected.map(\.id))
            selected.append(contentsOf: departures.filter { departure in
                !selectedIds.contains(departure.id)
            }.prefix(displayLimit - selected.count))
        }

        return selected
    }

    @ViewBuilder
    private var widgetStatusLine: some View {
        switch entry.locationFreshness {
        case .fresh:
            Text("Updated \(entry.refreshedAt.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(.white.opacity(0.44))
        case .recent:
            Label(
                "Open app to check if you'll make it",
                systemImage: "location"
            )
            .font(.system(size: 9, weight: .regular))
            .foregroundStyle(Color.patcoGold.opacity(0.64))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        case .unavailable:
            Label(
                "Open app to check if you'll make it",
                systemImage: "location.slash"
            )
            .font(.system(size: 9, weight: .regular))
            .foregroundStyle(Color.patcoGold.opacity(0.64))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        }
    }

    private var displayLimit: Int {
        switch widgetFamily {
        case .systemSmall:
            3
        case .systemLarge:
            10
        default:
            3
        }
    }

    private var departureRowSpacing: CGFloat {
        switch widgetFamily {
        case .systemLarge:
            5
        case .systemMedium:
            6
        default:
            5
        }
    }

    private func departureRow(_ departure: Departure) -> some View {
        let catchStatus = entry.catchStatuses[departure.id]
        return HStack(alignment: .center, spacing: 6) {
            Text(departureTimeText(for: departure))
                .font(.system(size: 19, weight: .semibold).monospacedDigit())
                .foregroundStyle(catchStatus?.color ?? .white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 100, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                if widgetFamily == .systemMedium || widgetFamily == .systemLarge {
                    Text("Arrives \(arrivalTimeText(for: departure))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                } else {
                    Text(arrivalTimeText(for: departure))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func departureTimeText(for departure: Departure) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = entry.timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: departure.departureDate)
    }

    private func arrivalTimeText(for departure: Departure) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = entry.timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = entry.timeZone

        if calendar.isDate(departure.arrivalDate, inSameDayAs: departure.departureDate) {
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: departure.arrivalDate)
        }

        formatter.dateFormat = "EEE h:mm a"
        return formatter.string(from: departure.arrivalDate)
    }

}

private struct WidgetRefreshToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Group {
                if configuration.isOn {
                    Image(systemName: "hourglass")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.patcoGold)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.patcoGold)
                }
            }
            .frame(width: 30, height: 30)
            .background(.white.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct WidgetReachabilityToggleStyle: ToggleStyle {
    let mode: SharedReachabilityModeStore.Mode

    func makeBody(configuration: Configuration) -> some View {
        let initialIsDriving = mode == .driving

        Button {
            configuration.isOn.toggle()
        } label: {
            Group {
                if configuration.isOn != initialIsDriving {
                    Image(systemName: "hourglass")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.patcoGold)
                } else {
                    Image(systemName: initialIsDriving ? "car.fill" : "figure.walk")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.patcoGold)
                }
            }
            .frame(width: 30, height: 30)
            .background(.white.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct NextPATCOTrainHomeWidget: Widget {
    let kind = "NextPATCOTrainWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: NextPATCOTrainWidgetProvider()) { entry in
            NextPATCOTrainWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Next PATCO Train")
        .description("See the next PATCO trains from Ashland to 15/16th and Locust.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct PATCOLockScreenEntry: TimelineEntry {
    let date: Date
    let departureDates: [Date]
    let originName: String
    let destinationName: String
}

// WidgetKit's completion is invoked once after the main-actor location request finishes.
private struct LockScreenTimelineCompletion: @unchecked Sendable {
    let call: (Timeline<PATCOLockScreenEntry>) -> Void
}

private struct PATCOLockScreenProvider: TimelineProvider {
    func placeholder(in context: Context) -> PATCOLockScreenEntry {
        let now = Date()
        return PATCOLockScreenEntry(
            date: now,
            departureDates: [15, 30, 45].map { now.addingTimeInterval(TimeInterval($0 * 60)) },
            originName: "Ashland",
            destinationName: "15/16th"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (PATCOLockScreenEntry) -> Void) {
        let status = CLLocationManager().authorizationStatus
        let location = status == .authorizedAlways || status == .authorizedWhenInUse
            ? SharedCurrentLocationCache.location(maxAge: 15 * 60) : nil
        completion(makeTimeline(at: Date(), currentLocation: location).entries[0])
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PATCOLockScreenEntry>) -> Void) {
        let callback = LockScreenTimelineCompletion(call: completion)
        Task { @MainActor in
            let location: CLLocation?
            let status = CLLocationManager().authorizationStatus
            if status != .authorizedAlways && status != .authorizedWhenInUse {
                SharedCurrentLocationCache.clear()
                location = nil
            } else {
                location = await WidgetLocationProvider.currentLocation()
            }
            callback.call(makeTimeline(at: Date(), currentLocation: location))
        }
    }

    private func makeTimeline(at now: Date, currentLocation: CLLocation?) -> Timeline<PATCOLockScreenEntry> {
        let store = PATCOScheduleStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let serviceDates = (-1...1).compactMap { calendar.date(byAdding: .day, value: $0, to: now) }
        let specialSchedules = SharedSpecialScheduleCache.schedules(matching: serviceDates, calendar: calendar)
        if !specialSchedules.isEmpty {
            store.applySpecialSchedules(specialSchedules)
        }
        let route = NextPATCOTrainWidgetProvider().selectedRoute(in: store, currentLocation: currentLocation)
        let departures: [Departure]
        if let origin = route.origin, let destination = route.destination {
            departures = store.departures(from: origin, to: destination, after: now, limit: 500)
        } else {
            departures = []
        }

        let entryDates = WidgetTimelinePolicy.entryDates(now: now, departures: departures.map(\.departureDate))
        let entries = entryDates.map { date in
            PATCOLockScreenEntry(
                date: date,
                departureDates: departures.lazy
                    .filter { $0.departureDate >= date }
                    .prefix(3)
                    .map(\.departureDate),
                originName: route.origin?.name ?? "PATCO",
                destinationName: route.destination?.name ?? ""
            )
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60)))
    }
}

private struct PATCOLockScreenView: View {
    let entry: PATCOLockScreenEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !entry.departureDates.isEmpty {
                Text("\(shortName(entry.originName)) → \(shortName(entry.destinationName))")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(departureTimesText)
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .accessibilityLabel(
                        "Scheduled departures: " + entry.departureDates
                            .map { $0.formatted(date: .omitted, time: .shortened) }
                            .joined(separator: ", ")
                    )

                if let dayContextText {
                    Text(dayContextText)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                }
            } else {
                Text("Open for scheduled departures")
                    .font(.caption)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.clear, for: .widget)
        .widgetURL(URL(string: "patconext://widget"))
    }

    private func shortName(_ name: String) -> String {
        name == "15/16th and Locust" ? "15/16th" : name
    }

    private var departureTimesText: String {
        let formatter = DateFormatter()
        let hourFormat = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h a"
        formatter.dateFormat = hourFormat.contains("a") ? "h:mm" : "HH:mm"
        return entry.departureDates.map(formatter.string(from:)).joined(separator: " · ")
    }

    private var dayContextText: String? {
        let calendar = Calendar.current
        let nextDayDates = entry.departureDates.filter { !calendar.isDate($0, inSameDayAs: entry.date) }
        guard !nextDayDates.isEmpty else { return nil }

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: entry.date)
        let dayName = tomorrow.map { calendar.isDate(nextDayDates[0], inSameDayAs: $0) } == true
            ? "tomorrow"
            : nextDayDates[0].formatted(.dateTime.weekday(.wide))
        if nextDayDates.count == entry.departureDates.count {
            return "\(dayName.capitalized) · scheduled"
        }
        return "Later trains \(dayName)"
    }
}

struct NextPATCOLockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextPATCOLockScreenWidget", provider: PATCOLockScreenProvider()) { entry in
            PATCOLockScreenView(entry: entry)
        }
        .configurationDisplayName("Next PATCO Train")
        .description("See the next three scheduled trains and open the app from the Lock Screen.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct PATCOTripLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PATCOTripActivityAttributes.self) { context in
            PATCOTripLiveActivityView(context: context)
                .activityBackgroundTint(Color.patcoCharcoal)
                .activitySystemActionForegroundColor(Color.patcoGold)
                .widgetURL(context.attributes.deepLinkURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.originName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                        Text(departureTimeText(context.state.departureDate))
                            .font(.headline.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.attributes.destinationName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                        Text(arrivalTimeText(context.state.arrivalDate))
                            .font(.headline.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    if context.isStale && ScheduledTripExpiration.hasExpired(arrivalDate: context.state.arrivalDate) {
                        Text("Scheduled trip ended")
                            .font(.caption)
                    } else {
                        ScheduledDepartureCountdownView(
                            startDate: context.state.lastUpdated,
                            departureDate: context.state.departureDate,
                            compact: true
                        )
                    }
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: "tram.fill")
                        .font(.caption.weight(.bold))
                    Text(context.isStale && ScheduledTripExpiration.hasExpired(arrivalDate: context.state.arrivalDate) ? "Ended" : shortTimeText(context.state.departureDate))
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .minimumScaleFactor(0.65)
                }
                .foregroundStyle(Color.patcoGold)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Text(context.isStale && ScheduledTripExpiration.hasExpired(arrivalDate: context.state.arrivalDate) ? "Ended" : shortTimeText(context.state.departureDate))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.65)
                .foregroundStyle(Color.patcoGold)
            }
            .widgetURL(context.attributes.deepLinkURL)
        }
    }

    private func departureTimeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func shortTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter.string(from: date)
    }

    private func arrivalTimeText(_ date: Date) -> String {
        "Arrives \(date.formatted(date: .omitted, time: .shortened))"
    }
}

struct PATCOTripLiveActivityView: View {
    let context: ActivityViewContext<PATCOTripActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next PATCO Train")
                        .font(.caption.bold())
                        .foregroundStyle(Color.patcoGold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(context.attributes.routeTitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer()

                Image(systemName: "tram.fill")
                    .font(.title3)
                    .foregroundStyle(Color.patcoGold)
            }

            HStack(alignment: .firstTextBaseline) {
                primaryScheduleBlock

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("Scheduled Arrival")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.58))
                    Text(context.state.arrivalDate.formatted(date: .omitted, time: .shortened))
                        .font(.title3.monospacedDigit().weight(.bold))
                        .foregroundStyle(.white)
                }
            }

            if context.isStale && ScheduledTripExpiration.hasExpired(arrivalDate: context.state.arrivalDate) {
                Text("Scheduled trip ended")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                ScheduledDepartureCountdownView(
                    startDate: context.state.lastUpdated,
                    departureDate: context.state.departureDate
                )
            }
        }
        .padding()
    }

    private var primaryScheduleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Scheduled Departure")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.58))
            Text(context.state.departureDate.formatted(date: .omitted, time: .shortened))
                .font(.title3.monospacedDigit().weight(.bold))
                .foregroundStyle(.white)
        }
    }

}

private struct ScheduledDepartureCountdownView: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    let startDate: Date
    let departureDate: Date
    var compact = false

    private var intervalStart: Date {
        min(startDate, departureDate)
    }

    var body: some View {
        TimelineView(.explicit([startDate, departureDate])) { timeline in
            if timeline.date >= departureDate {
                Text("Scheduled departure time has passed")
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.white.opacity(0.64))
            } else {
                countdown
            }
        }
    }

    private var countdown: some View {
        HStack(spacing: 8) {
            Text(isLuminanceReduced ? "Scheduled departure" : "Scheduled departure in")
                .font(compact ? .caption2 : .caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.64))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            countdownText
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var countdownText: some View {
        if isLuminanceReduced {
            // Relative time is system-managed and remains meaningful when Always-On
            // display suppresses the seconds portion of a clock-style timer.
            Text(departureDate, style: .relative)
                .font((compact ? Font.caption : Font.headline).monospacedDigit().weight(.bold))
                .foregroundStyle(Color.patcoGold)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.leading)
                .frame(width: compact ? 86 : 122, alignment: .leading)
        } else {
            Text(
                timerInterval: intervalStart...departureDate,
                countsDown: true,
                showsHours: true
            )
            .font((compact ? Font.caption : Font.headline).monospacedDigit().weight(.bold))
            .foregroundStyle(Color.patcoGold)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .multilineTextAlignment(.leading)
            .frame(width: compact ? 86 : 122, alignment: .leading)
        }
    }
}

@main
struct NextPATCOTrainWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextPATCOTrainHomeWidget()
        NextPATCOLockScreenWidget()
        PATCOTripLiveActivityWidget()
    }
}

private extension Color {
    static let patcoWine = Color(red: 0.42, green: 0.02, blue: 0.11)
    static let patcoCharcoal = Color(red: 0.08, green: 0.10, blue: 0.12)
    static let patcoRail = Color(red: 0.15, green: 0.18, blue: 0.21)
    static let patcoGold = Color(red: 1.0, green: 0.73, blue: 0.22)
    static let patcoPlum = Color(red: 0.48, green: 0.16, blue: 0.38)
}
