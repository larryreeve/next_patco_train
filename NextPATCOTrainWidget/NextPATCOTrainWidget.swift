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
    let locationRequestFailed: Bool
    var hasUnconfirmedTimes = false
    var isAtStation: Bool = false
    var leaveByDates: [UUID: Date] = [:]
    var routeRevision: Int? = nil
    var routeUpdating = false
    var workingAction: WidgetActionProgress.Kind? = nil
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
            locationRequestFailed: false
        )
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> PATCOTrainEntry {
        let now = Date()
        let location = WidgetRefreshState.authorizedCachedLocation
        let route = SharedRouteCoordinator.current()
        let candidate = SharedTripState.current()
        let shared = candidate?.routeRevision == route?.revision ? candidate : nil
        let dates = (-1...1).compactMap { patcoCalendar.date(byAdding: .day, value: $0, to: now) }
        let schedules = SharedSpecialScheduleCache.schedules(matching: dates, calendar: patcoCalendar)
        let store = PATCOScheduleStore()
        store.applySpecialSchedules(schedules)
        return makeEntry(at: now, refreshedAt: now, specialSchedules: schedules, currentLocation: location,
                         loadedStore: store,
                         resolvedRoute: (route.flatMap { store.station(for: $0.originId) },
                                         route.flatMap { store.station(for: $0.destinationId) }),
                         sharedTrip: shared)
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<PATCOTrainEntry> {
        let now = Date()
        let diagnosticRunID = SharedWidgetDiagnostics.beginWidgetRun()
        let actionTrip = WidgetRefreshState.recentActionTrip
        let location = actionTrip != nil
            ? WidgetRefreshState.authorizedCachedLocation
            : await WidgetLocationProvider.currentLocation(diagnosticRunID: diagnosticRunID)
        let specialSchedules = if let actionTrip {
            actionTrip.specialSchedules
        } else {
            await specialSchedulesForDepartureWindow(from: now)
        }
        let store = PATCOScheduleStore()
        store.applySpecialSchedules(specialSchedules)
        let pendingRefresh = SharedWidgetReachabilityState.pending()
        var refreshedEstimate = false
        if actionTrip == nil {
            refreshedEstimate = await refreshTravelTimeEstimate(at: now, store: store, currentLocation: location,
                                                                force: pendingRefresh != nil)
        } else {
            SharedWidgetDiagnostics.record("Widget action rendered", detail: "Using committed shared schedule without waiting for location or network")
        }
        if actionTrip == nil, let pendingRefresh,
           let shared = updateSharedTrip(store: store, location: location, reloadWidgets: false),
           let guidance = shared.guidance {
            SharedWidgetReachabilityState.completeIfReady(pendingRefresh, originId: shared.origin.id,
                mode: guidance.mode, hasFreshEstimate: refreshedEstimate && guidance.hasFreshMapsEstimate(at: Date()),
                isAtStation: LocationGuidancePolicy.isAtStation(guidance.location.location, station: shared.origin.location))
        }
        var timeline = makeHomeTimeline(store: store, location: location, specialSchedules: specialSchedules,
                                        diagnosticRunID: diagnosticRunID)
        for _ in 0..<2 {
            guard timeline.entries.first?.routeRevision != SharedRouteCoordinator.current()?.revision else { return timeline }
            SharedWidgetDiagnostics.record("Home Screen timeline superseded",
                detail: "Rebuilding for the latest committed route before completion")
            timeline = makeHomeTimeline(store: store, location: location, specialSchedules: specialSchedules,
                                        diagnosticRunID: diagnosticRunID)
        }
        guard timeline.entries.first?.routeRevision != SharedRouteCoordinator.current()?.revision else { return timeline }
        WidgetCenter.shared.reloadTimelines(ofKind: "NextPATCOTrainWidget")
        let route = SharedRouteCoordinator.current()
        let neutral = PATCOTrainEntry(date: Date(), refreshedAt: Date(), departures: [], catchStatuses: [:],
            routeTitle: routeTitle(origin: route.flatMap { store.station(for: $0.originId) },
                                   destination: route.flatMap { store.station(for: $0.destinationId) }),
            specialScheduleTitle: nil, timeZone: patcoCalendar.timeZone, originId: route?.originId,
            reachabilityMode: nil, scheduleExpired: false, locationTimestamp: nil,
            locationFreshness: .unavailable, locationRequestFailed: false,
            routeRevision: route?.revision, routeUpdating: true)
        return Timeline(entries: [neutral], policy: .after(Date().addingTimeInterval(60)))
    }

    private func makeHomeTimeline(store: PATCOScheduleStore, location: CLLocation?,
                                  specialSchedules: [PATCOSpecialSchedule],
                                  diagnosticRunID: UUID) -> Timeline<PATCOTrainEntry> {
        let now = Date()
        let startingRevision = SharedRouteCoordinator.current()?.revision
        // Capture the revision of the data, never infer it from matching station names afterward.
        var route = selectedRoute(in: store, currentLocation: location,
                                  reloadKind: "NextPATCOLockScreenWidget")
        let shared = WidgetRefreshState.recentActionTrip
            ?? updateSharedTrip(store: store, location: location, reloadWidgets: false)
        if let shared { route = (shared.origin, shared.destination) }
        let preparedRevision = shared?.routeRevision ?? startingRevision
        // Future entries keep departure times moving if iOS delays a requested
        // timeline reload. They do not wake the extension on their own.
        let departures = shared?.upcoming(at: now) ?? route.origin.flatMap { origin in
            route.destination.map { store.departures(from: origin, to: $0, after: now, limit: 500) }
        } ?? []
        let guidanceExpiration = shared?.guidance?.expirationDate
        let progress = WidgetActionProgress.current(now: now)
        let scheduledDates = WidgetTimelinePolicy.entryDates(now: now, departures: departures.map(\.departureDate),
                                                            guidanceExpiration: guidanceExpiration)
        let entryDates = Array(Set(scheduledDates + (progress.map { [$0.expiresAt] } ?? []))).sorted()
        let unconfirmedDays = WidgetTimelinePolicy.unconfirmedTimesByDay(
            schedules: shared?.specialSchedules ?? specialSchedules, dates: entryDates)
        let entries = entryDates.map { entryDate in
            var entry = makeEntry(
                at: entryDate,
                refreshedAt: now,
                specialSchedules: specialSchedules,
                currentLocation: location,
                loadedStore: store,
                resolvedRoute: route,
                sharedTrip: shared,
                unconfirmedTimes: unconfirmedDays[patcoCalendar.startOfDay(for: entryDate)] ?? false
            )
            entry.routeRevision = preparedRevision
            entry.workingAction = progress.flatMap { $0.isActive(at: entryDate) ? $0.kind : nil }
            return entry
        }
        let hasUpcomingService = entries.contains { !$0.departures.isEmpty }
        let refresh = WidgetTimelinePolicy.nextRefresh(
            now: Date(), hasService: hasUpcomingService,
            hasGuidance: entries.first?.catchStatuses.isEmpty == false,
            locationTimestamp: shared?.guidance?.location.timestamp ?? location?.timestamp,
            estimateTimestamp: shared?.guidance?.estimateFetchedAt,
            reachabilityEnabled: WidgetRefreshState.guidanceAllowed
        )
        let nextRefresh = refresh.date
        let firstEntry = entries.first
        let pending = SharedWidgetReachabilityState.pending()
        let blocked = pending?.originId == route.origin?.id && pending != nil
        let locationAge = firstEntry?.locationTimestamp.map { "\(Int(now.timeIntervalSince($0))) sec" } ?? "none"
        let estimateAge = shared?.guidance?.estimateFetchedAt.map { "\(Int(now.timeIntervalSince($0))) sec" } ?? "none"
        SharedWidgetDiagnostics.record("Home Screen reachability prepared",
            detail: "Run \(diagnosticRunID); revision \(preparedRevision.map(String.init) ?? "none"); \(firstEntry?.catchStatuses.count ?? 0) departure statuses; location age \(locationAge); source \(shared?.guidance?.estimateSource ?? "none"); Maps estimate age \(estimateAge); pending mode refresh \(blocked); guidance allowed \(WidgetRefreshState.guidanceAllowed); next request \(Int(nextRefresh.timeIntervalSince(now))) sec; on-screen redraw not confirmed")
        var estimateSource = "No usable location guidance"
        if let mode = entries.first?.reachabilityMode, let origin = route.origin, let location {
            let cacheMode: SharedTravelTimeEstimateCache.Mode = mode == .driving ? .driving : .walking
            estimateSource = SharedTravelTimeEstimateCache.estimate(mode: cacheMode, origin: origin, currentLocation: location) != nil
                ? "Maps estimate (cached)" : "Distance-based fallback"
        } else if entries.first?.catchStatuses.isEmpty == false {
            estimateSource = "At station; no travel estimate needed"
        }
        SharedDiagnosticState.record(.homeScreen, origin: route.origin, destination: route.destination,
                                     revision: preparedRevision, nextRequestedAt: nextRefresh,
                                     location: location, travelEstimateSource: estimateSource,
                                     appliedSpecialSchedules: specialSchedules.map { "\($0.title) (\($0.serviceDate.formatted(date: .abbreviated, time: .omitted)))" })
        SharedWidgetDiagnostics.finishWidgetRun(
            diagnosticRunID,
            departureCount: entries.first?.departures.count,
            nextReloadAt: nextRefresh,
            nextReloadReason: refresh.reason
        )
        return Timeline(entries: entries, policy: .after(nextRefresh))
    }

    @discardableResult
    fileprivate func refreshTravelTimeEstimate(
        at date: Date,
        store: PATCOScheduleStore,
        currentLocation: CLLocation?,
        force: Bool = false,
        reloadWidgets: Bool = true
    ) async -> Bool {
        guard WidgetReachabilitySettings.isEnabled, let currentLocation,
              LocationGuidancePolicy.isUsable(currentLocation, maxAge: 180) else { return false }

        let route = selectedRoute(in: store, currentLocation: currentLocation,
                                  reloadKind: "NextPATCOLockScreenWidget", reloadWidgets: reloadWidgets)
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
            return false
        }

        // Resolve the automatic mode using a walking route before requesting
        // the chosen mode's ETA. A cached walking route avoids another request.
        let distance = currentLocation.distance(from: origin.location)
        if distance > 150 && distance <= 1.25 * 1_609.34 {
            let walkingRefreshed = await WidgetTravelTimeEstimator.refresh(
                mode: .walking, origin: origin, currentLocation: currentLocation, force: force)
            let resolved = WidgetCatchStatus.reachabilityMode(for: firstDeparture, currentLocation: currentLocation, now: date) ?? mode
            if resolved == .walking { return walkingRefreshed }
        }
        let resolvedMode = WidgetCatchStatus.reachabilityMode(for: firstDeparture, currentLocation: currentLocation, now: date) ?? mode
        return await WidgetTravelTimeEstimator.refresh(
            mode: resolvedMode,
            origin: origin,
            currentLocation: currentLocation,
            force: force
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
        resolvedRoute: (origin: Station?, destination: Station?)? = nil,
        sharedTrip: SharedTripState.Snapshot? = nil,
        unconfirmedTimes: Bool? = nil
    ) -> PATCOTrainEntry {
        let store = loadedStore ?? PATCOScheduleStore()
        if loadedStore == nil && !specialSchedules.isEmpty {
            store.applySpecialSchedules(specialSchedules)
        }

        let calendar = patcoCalendar
        var route = resolvedRoute ?? selectedRoute(in: store, currentLocation: currentLocation)
        let shared = sharedTrip ?? (loadedStore == nil ? updateSharedTrip(store: store, location: currentLocation) : nil)
        if let shared { route = (shared.origin, shared.destination) }
        // An expired reading may still explain the refresh prompt; it never supplies catchability.
        let effectiveLocation = WidgetRefreshState.guidanceAllowed
            ? (shared?.guidance?.location.location ?? currentLocation) : nil
        let usableLocation = effectiveLocation.flatMap { location in
            date.timeIntervalSince(location.timestamp) <= 15 * 60 ? location : nil
        }
        let locationFreshness = Self.locationFreshness(for: usableLocation, at: date)
        let candidates = shared?.upcoming(at: date) ?? route.origin.flatMap { origin in
            route.destination.map { destination in
                store.departures(from: origin, to: destination, after: date, limit: 500)
            }
        } ?? []
        let departures = WidgetDepartureSelection.select(candidates, limit: 500)
        let pendingRefresh = (WidgetReachabilitySettings.isEnabled ? SharedWidgetReachabilityState.pending() : nil).flatMap {
            $0.originId == route.origin?.id ? $0 : nil
        }
        let reachabilityMode = !WidgetRefreshState.guidanceAllowed ? nil : pendingRefresh.map { WidgetCatchStatus.TravelMode($0.mode) }
            ?? shared?.guidance?.mode.map(WidgetCatchStatus.TravelMode.init) ?? (locationFreshness == .fresh
            ? WidgetCatchStatus.reachabilityMode(
                for: departures.first,
                currentLocation: usableLocation,
                now: date
            )
            : nil)
        let catchStatuses: [UUID: WidgetCatchStatus]
        let estimateIsFresh = shared?.guidance.map {
            $0.estimateSource != "Maps estimate" || $0.hasFreshMapsEstimate(at: date)
        } ?? true
        if locationFreshness == .fresh && pendingRefresh == nil && estimateIsFresh {
            catchStatuses = Dictionary(uniqueKeysWithValues: departures.compactMap { departure -> (UUID, WidgetCatchStatus)? in
                if let shared {
                    guard let result = shared.catchResult(for: departure, at: date, enforceOneHourLimit: false) else { return nil }
                    return (departure.id, WidgetCatchStatus(result))
                }
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

        let retainedDepartures = WidgetDepartureSelection.timelinePayload(departures,
            isRecommended: { catchStatuses[$0.id] == .reachable })
        let retainedIDs = Set(retainedDepartures.map(\.id))
        return PATCOTrainEntry(
            date: date,
            refreshedAt: refreshedAt,
            departures: retainedDepartures,
            catchStatuses: catchStatuses.filter { retainedIDs.contains($0.key) },
            routeTitle: routeTitle(origin: shared?.origin ?? route.origin, destination: shared?.destination ?? route.destination),
            specialScheduleTitle: (shared?.specialSchedules ?? specialSchedules).first(where: { calendar.isDate($0.serviceDate, inSameDayAs: departures.first?.serviceDate ?? date) })?.title,
            timeZone: calendar.timeZone,
            originId: shared?.origin.id ?? route.origin?.id,
            reachabilityMode: reachabilityMode?.sharedMode,
            scheduleExpired: shared?.isScheduleExpired(at: date) ?? (store.feed?.isExpired(on: date) ?? true),
            locationTimestamp: effectiveLocation?.timestamp,
            locationFreshness: locationFreshness,
            locationRequestFailed: WidgetRefreshState.hasRecentLocationFailure,
            hasUnconfirmedTimes: unconfirmedTimes ?? (shared?.specialSchedules ?? specialSchedules).contains {
                $0.hasUnconfirmedTimes(on: date)
            },
            isAtStation: usableLocation.flatMap { location in
                route.origin.map { LocationGuidancePolicy.isAtStation(location, station: $0.location, now: date) }
            } ?? false,
            leaveByDates: Dictionary(uniqueKeysWithValues: retainedDepartures.compactMap { departure in
                guard catchStatuses[departure.id] != nil,
                      let result = shared?.catchResult(for: departure, at: date, enforceOneHourLimit: false) else { return nil }
                return (departure.id, result.leaveBy)
            })
        )
    }

    fileprivate func updateSharedTrip(store: PATCOScheduleStore, location: CLLocation?, specialSchedules: [PATCOSpecialSchedule]? = nil,
                                      reloadWidgets: Bool = true) -> SharedTripState.Snapshot? {
        guard let route = SharedRouteCoordinator.current() else { return nil }
        let permission = CLLocationManager().authorizationStatus
        let dates = (-1...1).compactMap { patcoCalendar.date(byAdding: .day, value: $0, to: Date()) }
        guard let update = SharedTripState.update(store: store, routeRevision: route.revision, location: location,
                         locationAllowed: permission == .authorizedAlways || permission == .authorizedWhenInUse,
                         specialSchedules: specialSchedules ?? SharedSpecialScheduleCache.schedules(matching: dates, calendar: patcoCalendar)) else {
            return SharedTripState.current()
        }
        if reloadWidgets && update.shouldReloadWidgets { WidgetCenter.shared.reloadAllTimelines() }
        return update.snapshot
    }

    private static func locationFreshness(for location: CLLocation?, at date: Date) -> WidgetLocationFreshness {
        guard let location else { return .unavailable }

        let age = date.timeIntervalSince(location.timestamp)
        if WidgetTimelinePolicy.hasUsableGuidance(location: location, at: date) {
            return .fresh
        }
        if (0...15 * 60).contains(age) {
            return .recent
        }
        return .unavailable
    }

    fileprivate func specialSchedulesForDepartureWindow(from date: Date, force: Bool = false) async -> [PATCOSpecialSchedule] {
        let calendar = patcoCalendar
        let dates = (-1...1).compactMap { calendar.date(byAdding: .day, value: $0, to: date) }
        let cached = SharedSpecialScheduleCache.schedules(matching: dates, calendar: calendar)
        let result = await SpecialScheduleRefreshDeadline.wait {
            await SharedSpecialScheduleCache.refreshIfNeeded(from: date, calendar: calendar, force: force)
        }
        return result?.schedules ?? cached
    }

    fileprivate func selectedRoute(in store: PATCOScheduleStore, currentLocation: CLLocation?,
                                   reloadKind: String? = nil, reloadWidgets: Bool = true) -> (origin: Station?, destination: Station?) {
        var previous = SharedRouteCoordinator.current()
        if previous == nil {
            let saved = SharedRouteDefaults.savedRoute()
            if let origin = saved.flatMap({ store.station(for: $0.originId) }) ?? station(named: "Lindenwold", in: store),
               let destination = saved.flatMap({ store.station(for: $0.destinationId) }) ?? store.locust {
                previous = SharedRouteCoordinator.commit(originId: origin.id, destinationId: destination.id)
            }
        }
        let now = Date()
        var arrivalCheck: DestinationArrivalGate?
        let route = SharedRouteCoordinator.resolveWidgetRoute(location: currentLocation, stations: store.stations, now: now,
            onArrivalCheck: { arrivalCheck = $0 }) ?? previous
        if let location = currentLocation, let previous,
           let destination = store.station(for: previous.destinationId) {
            let distance = Int(location.distance(from: destination.location))
            let accuracy = Int(location.horizontalAccuracy)
            let age = Int(now.timeIntervalSince(location.timestamp))
            let decision = arrivalCheck?.diagnosticDescription(for: location, now: now) ?? "Arrival check unavailable"
            SharedWidgetDiagnostics.record("Widget arrival check", detail: "Destination \(destination.name): \(distance) m away; accuracy \(accuracy) m; reading \(age) sec old; \(route?.revision != previous.revision ? "route changed" : "route unchanged"); \(decision). Confirmation requires distinct stopped readings spanning 5 sec with accuracy up to 20 m and drift up to 10 m, or 10 sec with accuracy up to 50 m; speed 0 to 0.5 m/sec, gaps no longer than 15 sec, distance plus accuracy within 150 m, an unambiguous station, and readings newer than the route selection.")
        }
        if let route {
            SharedWidgetDiagnostics.record("Widget shared route", detail: "Revision \(route.revision): \(store.station(for: route.originId)?.name ?? route.originId) to \(store.station(for: route.destinationId)?.name ?? route.destinationId); \(route.reason)")
            if route.revision != previous?.revision {
                if route.endsJourneyTracking {
                    SharedJourneyTracking.end()
                }
                _ = updateSharedTrip(store: store, location: currentLocation, reloadWidgets: false)
                if reloadWidgets {
                    // The caller already builds its own timeline; only invalidate its sibling.
                    if let reloadKind {
                        WidgetCenter.shared.reloadTimelines(ofKind: reloadKind)
                    } else {
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                }
            }
            return (store.station(for: route.originId), store.station(for: route.destinationId))
        }
        return (nil, nil)
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
    struct RouteEstimate: Sendable {
        let expectedTravelTime: TimeInterval
        let distance: Double
    }
    private let directions: MKDirections
    private var continuation: CheckedContinuation<RouteEstimate?, Never>?
    private var timeout: Task<Void, Never>?

    private init(_ request: MKDirections.Request) {
        directions = MKDirections(request: request)
    }

    static func calculate(_ request: MKDirections.Request) async -> RouteEstimate? {
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
                let travelTime = response?.routes.first.map {
                    RouteEstimate(expectedTravelTime: $0.expectedTravelTime, distance: $0.distance)
                }
                Task { @MainActor in operation.finish(travelTime) }
            }
        }
    }

    private func finish(_ response: RouteEstimate?) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(returning: response)
    }
}

private enum WidgetTravelTimeEstimator {
    @MainActor private static var walkingRequests = TravelEstimateRequestGate()
    @MainActor private static var drivingRequests = TravelEstimateRequestGate()
    @MainActor private static var pendingEstimates: [String: Task<Bool, Never>] = [:]
    @MainActor
    static func refresh(
        mode: WidgetCatchStatus.TravelMode,
        origin: Station,
        currentLocation: CLLocation,
        force: Bool
    ) async -> Bool {
        let key = "\(origin.id)|\(mode)|\(SharedRouteCoordinator.current()?.revision ?? -1)|\(currentLocation.coordinate.latitude)|\(currentLocation.coordinate.longitude)|\(force)"
        if let pending = pendingEstimates[key] { return await pending.value }
        let task = Task { @MainActor in
            await performRefresh(mode: mode, origin: origin, currentLocation: currentLocation, force: force)
        }
        pendingEstimates[key] = task
        defer { pendingEstimates[key] = nil }
        return await task.value
    }

    @MainActor
    private static func performRefresh(mode: WidgetCatchStatus.TravelMode, origin: Station,
                                       currentLocation: CLLocation, force: Bool) async -> Bool {
        guard WidgetReachabilitySettings.isEnabled else { return false }
        let requestID = mode == .walking ? walkingRequests.begin() : drivingRequests.begin()
        let requestRevision = SharedRouteCoordinator.current()?.revision
        let requestStartedAt = Date()
        let distanceToStation = currentLocation.distance(from: origin.location)
        let cacheMode: SharedTravelTimeEstimateCache.Mode
        let transportType: MKDirectionsTransportType

        switch mode {
        case .walking:
            guard distanceToStation > 150 else {
                SharedTravelTimeEstimateCache.clear(mode: .walking)
                return false
            }
            cacheMode = .walking
            transportType = .walking
        case .driving:
            guard distanceToStation > 150 else {
                SharedTravelTimeEstimateCache.clear(mode: .driving)
                return false
            }
            cacheMode = .driving
            transportType = .automobile
        }

        // Reuse the route estimate, not its old location or catchability result.
        if !force, let estimate = SharedTravelTimeEstimateCache.estimate(
            mode: cacheMode, origin: origin, currentLocation: currentLocation
        ) {
            SharedWidgetDiagnostics.record("Widget travel estimate reused",
                detail: "\(cacheMode.rawValue); \(estimate.minutes) min; original estimate age \(Int(Date().timeIntervalSince(estimate.fetchedAt))) sec")
            return true
        }

        SharedWidgetDiagnostics.record("Widget Maps estimate requested",
            detail: "\(cacheMode.rawValue); \(force ? "interactive refresh" : "cache absent or invalid")")
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocation.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.transportType = transportType
        request.requestsAlternateRoutes = false

        guard let travelTime = await BoundedWidgetDirections.calculate(request) else {
            SharedWidgetDiagnostics.record("Widget Maps estimate unavailable", detail: "\(cacheMode.rawValue); request failed or timed out")
            return false
        }
        guard WidgetReachabilitySettings.isEnabled, !Task.isCancelled,
              (mode == .walking ? walkingRequests.accepts(requestID) : drivingRequests.accepts(requestID)),
              let route = SharedRouteCoordinator.current(), route.revision == requestRevision, route.originId == origin.id,
              let latestLocation = SharedCurrentLocationCache.location(),
              LocationGuidancePolicy.isUsable(latestLocation, maxAge: 180),
              latestLocation.distance(from: currentLocation) < (mode == .walking ? 50 : 100) else {
            SharedWidgetDiagnostics.record("Widget Maps estimate discarded",
                detail: "\(cacheMode.rawValue); request superseded, route/location changed, permission setting changed, or work cancelled")
            return false
        }

        let saved = SharedTravelTimeEstimateCache.save(
            mode: cacheMode,
            origin: origin,
            currentLocation: currentLocation,
            minutes: max(1, Int(ceil(travelTime.expectedTravelTime / 60))),
            routeDistanceMeters: travelTime.distance,
            requestStartedAt: requestStartedAt
        )
        SharedWidgetDiagnostics.record(saved ? "Widget Maps estimate saved" : "Widget Maps estimate not saved",
            detail: "\(cacheMode.rawValue); \(max(1, Int(ceil(travelTime.expectedTravelTime / 60)))) min; route revision \(requestRevision.map(String.init) ?? "none")")
        return saved
    }
}

@MainActor
private final class WidgetLocationProvider: NSObject, CLLocationManagerDelegate {
    private static var pendingLocations: [Bool: Task<CLLocation?, Never>] = [:]
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
        guard WidgetReachabilitySettings.isEnabled else { return nil }
        let allowsFallback = allowsCachedFallback && !SharedCurrentLocationCache.freshLocationRequired
        if let pending = pendingLocations[allowsFallback] { return await pending.value }
        let task = Task { @MainActor in
            await requestSharedLocation(allowsCachedFallback: allowsFallback,
                manual: !allowsCachedFallback, diagnosticRunID: diagnosticRunID)
        }
        pendingLocations[allowsFallback] = task
        defer { pendingLocations[allowsFallback] = nil }
        return await task.value
    }

    private static func requestSharedLocation(allowsCachedFallback: Bool,
                                              manual: Bool,
                                              diagnosticRunID: UUID?) async -> CLLocation? {
        guard WidgetReachabilitySettings.isEnabled else { return nil }
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
            WidgetRefreshState.recordLocationOutcome(available: false)
            return nil
        }
        if let cachedLocation, LocationGuidancePolicy.isUsable(cachedLocation, now: startedAt) {
            WidgetRefreshState.recordLocationOutcome(available: true)
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
        let attemptDefaults = UserDefaults(suiteName: "group.com.rhome.patconext")
        let attemptKey = "widgetLocationLastAttemptAt"
        let lastAttempt = attemptDefaults?.object(forKey: attemptKey) as? Date
        let lastSuccessfulLocation = cachedLocation.flatMap {
            LocationGuidancePolicy.isUsable($0, now: $0.timestamp) ? $0.timestamp : nil
        }
        guard WidgetTimelinePolicy.shouldAttemptLocation(lastAttempt: lastAttempt, now: startedAt,
                                                        manual: manual, lastSuccessfulLocation: lastSuccessfulLocation) else {
            WidgetRefreshState.recordLocationOutcome(available: false)
            if let diagnosticRunID {
                SharedWidgetDiagnostics.recordLocation("Automatic GPS retry deferred; using cached location",
                    duration: Date().timeIntervalSince(startedAt), for: diagnosticRunID)
            }
            return cachedLocation
        }
        attemptDefaults?.set(startedAt, forKey: attemptKey)
        let requestedLocation = await provider.requestLocation()
        WidgetRefreshState.recordLocationOutcome(available: requestedLocation.map {
            LocationGuidancePolicy.isUsable($0, maxAge: 180)
        } ?? false)
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
                manager.startUpdatingLocation()
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
                if self.continuation != nil { self.manager.startUpdatingLocation() }
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
            guard continuation != nil else { return }
            let freshLocation = locations
                .filter { location in
                    LocationGuidancePolicy.isUsable(location)
                        && (allowsCachedFallback || location.timestamp >= requestStartedAt.addingTimeInterval(-1))
                }
                .max { $0.timestamp < $1.timestamp }
            if let freshLocation {
                finish(with: freshLocation)
                return
            }

            // A manual request may retain a new imprecise fix, but never an old cached one.
            let candidates = locations.filter {
                $0.horizontalAccuracy > 0 && $0.horizontalAccuracy <= 1_000
                    && (0...120).contains(Date().timeIntervalSince($0.timestamp))
                    && (allowsCachedFallback || $0.timestamp >= requestStartedAt.addingTimeInterval(-1))
            }
            fallbackLocation = ([fallbackLocation].compactMap { $0 } + candidates)
                .max { $0.timestamp < $1.timestamp }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            guard continuation != nil else { return }
            if (error as? CLError)?.code == .locationUnknown {
                failureReason = "Location temporarily unavailable"
                return
            }
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
        manager.stopUpdatingLocation()
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

    private static let reachabilityMaxDistanceMeters = 150 * 1_609.34

    init?(
        departure: Departure,
        currentLocation: CLLocation?,
        now: Date,
        reachabilityMode: TravelMode?
    ) {
        guard let currentLocation, LocationGuidancePolicy.isUsable(currentLocation, maxAge: 180, now: now) else { return nil }

        let minutesUntilDeparture = Int(floor(departure.departureDate.timeIntervalSince(now) / 60))
        let distanceToStation = currentLocation.distance(from: departure.origin.location)
        guard distanceToStation <= Self.reachabilityMaxDistanceMeters else {
            return nil
        }

        if LocationGuidancePolicy.isAtStation(currentLocation, station: departure.origin.location, now: now) {
            SharedReachabilityModeStore.clearOnArrival(originId: departure.origin.id)
            self = .reachable
            return
        }

        guard let travelMode = reachabilityMode ?? SharedReachabilityModeStore.resolve(
            originId: departure.origin.id,
            distanceToStation: distanceToStation,
            minutesUntilDeparture: minutesUntilDeparture,
            defaultsToWalking: departure.origin.defaultsToWalkingForReachability,
            walkingEstimate: SharedTravelTimeEstimateCache.estimate(mode: .walking, origin: departure.origin, currentLocation: currentLocation)
        ).map(TravelMode.init) else {
            return nil
        }
        guard let travelMinutes = Self.travelMinutes(
            for: travelMode,
            meters: distanceToStation,
            origin: departure.origin,
            currentLocation: currentLocation
        ) else { return nil }
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

    var accessibilityDescription: String {
        switch self {
        case .reachable: "Likely to make this train"
        case .tight: "Timing is tight"
        case .likelyMiss: "Likely to miss this train"
        }
    }

    init(_ result: SharedTripState.CatchResult) {
        switch result.status {
        case .atStation, .comfortable: self = .reachable
        case .tight: self = .tight
        case .probablyMissed, .tooLate: self = .likelyMiss
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
        guard let departure, let currentLocation,
              LocationGuidancePolicy.isUsable(currentLocation, maxAge: 180, now: now) else { return nil }

        let distanceToStation = currentLocation.distance(from: departure.origin.location)
        guard distanceToStation <= reachabilityMaxDistanceMeters else {
            return nil
        }

        guard !LocationGuidancePolicy.isAtStation(currentLocation, station: departure.origin.location, now: now) else {
            SharedReachabilityModeStore.clearOnArrival(originId: departure.origin.id)
            return nil
        }

        let minutesUntilDeparture = Int(floor(departure.departureDate.timeIntervalSince(now) / 60))
        guard let sharedMode = SharedReachabilityModeStore.resolve(
            originId: departure.origin.id,
            distanceToStation: distanceToStation,
            minutesUntilDeparture: minutesUntilDeparture,
            defaultsToWalking: departure.origin.defaultsToWalkingForReachability,
            walkingEstimate: SharedTravelTimeEstimateCache.estimate(mode: .walking, origin: departure.origin, currentLocation: currentLocation)
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
    ) -> Int? {
        let cacheMode: SharedTravelTimeEstimateCache.Mode = mode == .walking ? .walking : .driving
        if let estimate = SharedTravelTimeEstimateCache.estimate(
            mode: cacheMode,
            origin: origin,
            currentLocation: currentLocation
        ) {
            return estimate.minutes
        }

        guard mode != .driving else { return nil }
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
    private static let locationFailureAtKey = "widgetLocationRefreshFailedAt"
    private static let actionCompletedAtKey = "widgetActionCompletedAt"
    private static let failureVisibility: TimeInterval = 2 * 60

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func actionCompleted() {
        defaults.set(Date(), forKey: actionCompletedAtKey)
    }

    // Interactive reloads must not block on another GPS or network request.
    // The shared snapshot still enforces route revision and location freshness.
    static var recentActionTrip: SharedTripState.Snapshot? {
        if WidgetActionProgress.current() != nil { return SharedTripState.current() }
        guard let completedAt = defaults.object(forKey: actionCompletedAtKey) as? Date,
              (0...30).contains(Date().timeIntervalSince(completedAt)) else { return nil }
        return SharedTripState.current()
    }

    static var authorizedCachedLocation: CLLocation? {
        guard guidanceAllowed else { return nil }
        return SharedCurrentLocationCache.location(maxAge: 15 * 60)
    }

    static var guidanceAllowed: Bool {
        guard WidgetReachabilitySettings.isEnabled else { return false }
        let status = CLLocationManager().authorizationStatus
        return status == .authorizedAlways || status == .authorizedWhenInUse
    }

    static func recordLocationOutcome(available: Bool) {
        if available {
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

private enum WidgetInteractiveRefresh {
    static func perform(progress: WidgetActionProgress.Ticket) async {
        // One bounded pass per tap. Leave time to publish before the action lease expires.
        func canContinue(reserving seconds: TimeInterval = 0) -> Bool {
            WidgetReachabilitySettings.isEnabled && !Task.isCancelled
                && progress.permitsWork(reserving: seconds)
                && WidgetActionProgress.current()?.id == progress.id
        }
        guard canContinue(reserving: 8) else { return }
        SharedWidgetDiagnostics.record("Widget refresh action started", detail: "Requesting location before publishing departures")
        let diagnosticRunID = SharedWidgetDiagnostics.beginWidgetRun(manual: true)
        defer { SharedWidgetDiagnostics.finishWidgetRun(diagnosticRunID, manual: true) }
        let pendingRefresh = SharedWidgetReachabilityState.pending()
        SharedCurrentLocationCache.requireFreshLocation()
        let location = await WidgetLocationProvider.currentLocation(
            allowsCachedFallback: false,
            diagnosticRunID: diagnosticRunID
        )
        guard canContinue(reserving: 4) else { return }
        let store = PATCOScheduleStore()
        let schedules = await NextPATCOTrainWidgetProvider().specialSchedulesForDepartureWindow(from: Date(), force: true)
        guard canContinue() else { return }
        store.applySpecialSchedules(schedules)
        _ = NextPATCOTrainWidgetProvider().selectedRoute(in: store, currentLocation: location, reloadWidgets: false)
        let refreshedEstimate = canContinue(reserving: 8) ? await NextPATCOTrainWidgetProvider().refreshTravelTimeEstimate(
            at: Date(), store: store, currentLocation: location, force: true, reloadWidgets: false
        ) : false
        guard canContinue() else { return }
        if let pendingRefresh,
           let route = SharedRouteCoordinator.current(), route.originId == pendingRefresh.originId,
           let origin = store.stations.first(where: { $0.id == route.originId }),
           let location, LocationGuidancePolicy.isUsable(location, maxAge: 180),
           refreshedEstimate || LocationGuidancePolicy.isAtStation(location, station: origin.location) {
            SharedWidgetReachabilityState.complete(pendingRefresh)
        }
        _ = NextPATCOTrainWidgetProvider().updateSharedTrip(store: store, location: location,
            specialSchedules: schedules, reloadWidgets: false)
        WidgetRefreshState.actionCompleted()
        WidgetRefreshState.recordLocationOutcome(available: location.map {
            LocationGuidancePolicy.isUsable($0, maxAge: 180)
        } ?? false)
        SharedWidgetDiagnostics.record("Widget refresh action completed", detail: "Shared departures published; reload deferred until action completion")
    }
}

struct RefreshPATCOWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh trains"
    static let description = IntentDescription("Refreshes departures and estimates whether you can catch the train.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        guard WidgetReachabilitySettings.isEnabled else { return .result() }
        guard let progress = WidgetActionProgress.begin(.refresh) else { return .result() }
        defer {
            WidgetActionProgress.finish(progress)
            SharedWidgetDiagnostics.recordReloadRequest(action: "Home Screen refresh")
            WidgetCenter.shared.reloadAllTimelines()
        }
        await WidgetInteractiveRefresh.perform(progress: progress)
        return .result()
    }
}

struct RefreshPATCOLockScreenWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh scheduled departures"
    static let description = IntentDescription("Reloads the shared route and scheduled departures on the Lock Screen.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        guard WidgetReachabilitySettings.isEnabled else { return .result() }
        SharedWidgetDiagnostics.record("Lock Screen refresh action started", detail: "Reading committed route and cached schedule")
        _ = await NextPATCOTrainWidgetProvider().specialSchedulesForDepartureWindow(from: Date(), force: true)
        _ = NextPATCOTrainWidgetProvider().updateSharedTrip(store: PATCOScheduleStore(),
            location: WidgetRefreshState.authorizedCachedLocation, reloadWidgets: false)
        WidgetRefreshState.actionCompleted()
        // WidgetKit reloads this widget automatically after the intent returns.
        LockScreenRefreshFeedback.recordCompletion()
        SharedWidgetDiagnostics.recordReloadRequest(action: "Lock Screen departure refresh",
            deliveryDescription: "Lock Screen automatic reload on intent completion")
        SharedWidgetDiagnostics.record("Lock Screen refresh action completed", detail: "Shared departures published; using automatic button reload without GPS or Maps")
        return .result()
    }
}

struct ReversePATCOWidgetRouteIntent: AppIntent {
    static let title: LocalizedStringResource = "Reverse route"
    static let description = IntentDescription("Swaps the departure and destination stations for both widgets.")
    static let openAppWhenRun = false

    @Parameter(title: "Displayed route revision")
    var expectedRevision: Int

    init() { expectedRevision = -1 }
    init(expectedRevision: Int) { self.expectedRevision = expectedRevision }

    func perform() async throws -> some IntentResult {
        guard let progress = WidgetActionProgress.begin(.reverse) else { return .result() }
        defer {
            WidgetActionProgress.finish(progress)
            SharedWidgetDiagnostics.recordReloadRequest(action: "Home Screen route reversal")
            WidgetCenter.shared.reloadAllTimelines()
        }
        let startedAt = Date()
        SharedWidgetDiagnostics.record("Widget reversal action started", detail: "Reading committed route")
        guard let previous = SharedRouteCoordinator.current(), previous.revision == expectedRevision else {
            SharedWidgetDiagnostics.record("Widget reversal skipped", detail: "Displayed route already changed; refreshing controls")
            return .result()
        }
        let store = PATCOScheduleStore()
        if
           let route = SharedRouteCoordinator.reverse(expectedRevision: previous.revision,
                selectionLocation: SharedCurrentLocationCache.location(), stations: store.stations),
           route.revision != previous.revision {
            SharedJourneyTracking.end()
            SharedWidgetDiagnostics.record("Widget route reversed", detail: "Revision \(route.revision): \(route.originId) to \(route.destinationId)")
        }
        let shared = NextPATCOTrainWidgetProvider().updateSharedTrip(store: store,
            location: WidgetRefreshState.authorizedCachedLocation, reloadWidgets: false)
        if let shared {
            _ = SharedRouteDefaults.recordHomeWidgetRoute(originId: shared.origin.id,
                                                          destinationId: shared.destination.id)
        }
        WidgetRefreshState.actionCompleted()
        SharedWidgetDiagnostics.record("Widget reversal action completed",
            detail: "Prepared in \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms; reload deferred until action completion")
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
        guard WidgetReachabilitySettings.isEnabled else { return .result() }
        guard let progress = WidgetActionProgress.begin(.mode) else { return .result() }
        defer {
            WidgetActionProgress.finish(progress)
            SharedWidgetDiagnostics.recordReloadRequest(action: "Home Screen travel mode change")
            WidgetCenter.shared.reloadAllTimelines()
        }
        let mode: SharedReachabilityModeStore.Mode = currentMode == SharedReachabilityModeStore.Mode.driving.rawValue
            ? .walking
            : .driving
        SharedReachabilityModeStore.save(mode: mode, originId: originId, isManual: true)
        SharedWidgetReachabilityState.requireRefresh(originId: originId, mode: mode)
        _ = NextPATCOTrainWidgetProvider().updateSharedTrip(store: PATCOScheduleStore(),
                                                          location: SharedCurrentLocationCache.location(), reloadWidgets: false)
        WidgetRefreshState.actionCompleted()
        await WidgetInteractiveRefresh.perform(progress: progress)
        return .result()
    }
}

struct NextPATCOTrainWidgetEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily

    let entry: PATCOTrainEntry

    var body: some View {
        VStack(alignment: .leading, spacing: widgetFamily == .systemSmall ? 6 : 8) {
            if widgetFamily == .systemSmall {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 2) {
                        Text("PATCO")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.patcoGold)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        WidgetRouteControls(originId: entry.originId, mode: entry.reachabilityMode, routeRevision: entry.routeRevision, workingAction: entry.workingAction, size: 22)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(entry.routeTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(2)
                        if WidgetReachabilitySettings.isEnabled && entry.locationFreshness == .unavailable {
                            Image(systemName: "location.slash")
                                .foregroundStyle(Color.patcoGold)
                                .accessibilityLabel("Location unavailable")
                        }
                    }
                    .font(.system(size: 10))
                }
            } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next PATCO Train")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.patcoGold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(entry.routeTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

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
                        Image(systemName: "location")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.patcoGold)
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.10), in: Circle())
                            .accessibilityLabel(entry.locationRequestFailed || entry.locationTimestamp == nil ? "Location unavailable. Your arrival time can't be estimated." : "Tap refresh to check which train you can make")
                    }

                    WidgetRouteControls(originId: entry.originId, mode: entry.reachabilityMode, routeRevision: entry.routeRevision, workingAction: entry.workingAction)

                }
                .fixedSize(horizontal: true, vertical: false)
            }
            }

            Group {
                if entry.departures.isEmpty {
                    Spacer()
                    Text(entry.hasUnconfirmedTimes ? "DST times unconfirmed" : entry.routeUpdating ? "Updating route" : entry.scheduleExpired ? "Schedule update needed" : "No upcoming trains")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(
                        entry.hasUnconfirmedTimes ? "Open the app to check the schedule PDF." : entry.routeUpdating ? "Refresh to load departures for your selected route." : entry.scheduleExpired
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
                if entry.hasUnconfirmedTimes {
                    Text("DST times unconfirmed; check PDF")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.patcoGold)
                        .lineLimit(2)
                } else if widgetFamily != .systemSmall {
                    widgetStatusLine
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
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
        let departures = displayedDepartures
        VStack(spacing: departureRowSpacing) {
            ForEach(Array(departures.enumerated()), id: \.element.id) { index, departure in
                departureRow(departure, previousDeparture: index > 0 ? departures[index - 1].departureDate : nil)
            }
        }
    }

    private var displayedDepartures: [Departure] {
        guard prioritizesCatchability else {
            return WidgetDepartureSelection.select(entry.departures, limit: displayLimit)
        }
        return WidgetDepartureSelection.prioritized(entry.departures, limit: displayLimit,
            isRecommended: { entry.catchStatuses[$0.id] == .reachable })
    }

    private var prioritizesCatchability: Bool {
        (widgetFamily == .systemSmall || widgetFamily == .systemMedium)
            && hasCurrentCatchability
    }

    private var hasCurrentCatchability: Bool {
        WidgetReachabilitySettings.isEnabled && entry.locationFreshness == .fresh && !entry.isAtStation
            && !(entry.originId != nil && SharedWidgetReachabilityState.pending()?.originId == entry.originId)
    }

    private var recommendedID: UUID? {
        guard hasCurrentCatchability else { return nil }
        return entry.departures.first { entry.catchStatuses[$0.id] == .reachable }?.id
    }

    @ViewBuilder
    private var widgetStatusLine: some View {
        if !WidgetReachabilitySettings.isEnabled {
            EmptyView()
        } else if SharedWidgetReachabilityState.pending()?.originId == entry.originId,
           entry.originId != nil {
            Label("Refresh to update travel estimate", systemImage: "arrow.clockwise")
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(Color.patcoGold.opacity(0.64))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        } else {
            switch entry.locationFreshness {
            case .fresh:
                Text("Updated \(entry.refreshedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.white.opacity(0.44))
            case .recent:
                Label(
                    entry.locationRequestFailed ? "Location unavailable · Your arrival time can't be estimated" : "Tap refresh to check which train you can make",
                    systemImage: "location"
                )
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(Color.patcoGold.opacity(0.64))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            case .unavailable:
                Label(
                    entry.locationRequestFailed || entry.locationTimestamp == nil ? "Location unavailable · Your arrival time can't be estimated" : "Tap refresh to check which train you can make",
                    systemImage: "location"
                )
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(Color.patcoGold.opacity(0.64))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            }
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

    private func departureRow(_ departure: Departure, previousDeparture: Date?) -> some View {
        let needsRefresh = entry.originId != nil
            && SharedWidgetReachabilityState.pending()?.originId == entry.originId
        let catchStatus = needsRefresh || !WidgetReachabilitySettings.isEnabled ? nil : entry.catchStatuses[departure.id]
        let recommendation = departure.id == recommendedID ? ", Recommended" : ""
        let deadline = departure.id == recommendedID
            ? entry.leaveByDates[departure.id].map { ", Leave by \(PATCOClock.timeText($0))" } ?? "" : ""
        let statusDescription = catchStatus.map { ", \($0.accessibilityDescription)" } ?? ""
        let day = WidgetDepartureDay.label(for: departure.departureDate, relativeTo: entry.date, timeZone: entry.timeZone)
        let visibleDay = WidgetDepartureDay.groupLabel(for: departure.departureDate,
            previousDeparture: previousDeparture, relativeTo: entry.date, timeZone: entry.timeZone)
        let spokenDescription = "Scheduled departure \(day.map { $0 + " " } ?? "")\(departureTimeText(for: departure)), arrives \(arrivalTimeText(for: departure))"
            + recommendation + deadline + statusDescription
        return Group {
            if widgetFamily == .systemSmall {
                HStack(spacing: 3) {
                Text(departureTimeText(for: departure))
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .foregroundStyle(catchStatus?.color ?? .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let day = visibleDay {
                    Text(day)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                }
                    .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
                    .padding(.horizontal, 8)
                    .background((catchStatus?.color ?? .white).opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 6))
            } else {
            HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
            if let day = visibleDay {
                Text(day).font(.system(size: 9)).foregroundStyle(.white.opacity(0.8))
            }
            Text(departureTimeText(for: departure))
                .font(.system(size: 19, weight: .semibold).monospacedDigit())
                .foregroundStyle(catchStatus?.color ?? .white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: displayedDepartures.contains { PATCOClock.needsTimeZone($0.departureDate, relativeTo: $0.arrivalDate) } ? 135 : 100, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text("Arrives at \(arrivalTimeText(for: departure))")
                .font(.system(size: widgetFamily == .systemMedium ? 14 : 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .fixedSize(horizontal: false, vertical: true)
            }
        }
        .overlay(alignment: .leading) {
            if departure.id == recommendedID {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(catchStatus?.color ?? .clear)
                    .frame(width: 3)
                    .padding(.vertical, 3)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenDescription)
    }

    private func departureTimeText(for departure: Departure) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = entry.timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: departure.departureDate)
            + PATCOClock.timeZoneSuffix(departure.departureDate, relativeTo: departure.arrivalDate)
    }

    private func arrivalTimeText(for departure: Departure) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = entry.timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = entry.timeZone

        if calendar.isDate(departure.arrivalDate, inSameDayAs: departure.departureDate) {
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: departure.arrivalDate)
                + PATCOClock.timeZoneSuffix(departure.arrivalDate, relativeTo: departure.departureDate)
        }

        formatter.dateFormat = "EEE h:mm a"
        return formatter.string(from: departure.arrivalDate)
            + PATCOClock.timeZoneSuffix(departure.arrivalDate, relativeTo: departure.departureDate)
    }

}

private struct WidgetRouteControls: View {
    let originId: Station.ID?
    let mode: SharedReachabilityModeStore.Mode?
    let routeRevision: Int?
    let workingAction: WidgetActionProgress.Kind?
    var size: CGFloat = 30

    private var displayedMode: SharedReachabilityModeStore.Mode? {
        mode ?? .driving
    }

    var body: some View {
        HStack(spacing: size < 30 ? 4 : 6) {
            if originId != nil, let routeRevision {
                Toggle(isOn: workingAction == .reverse, intent: ReversePATCOWidgetRouteIntent(expectedRevision: routeRevision)) {
                    Image(systemName: "arrow.left.arrow.right")
                }
                    .toggleStyle(WidgetActionProgressStyle(size: size))
                    .accessibilityLabel("Reverse route")
            }
            if let originId, let mode = displayedMode {
                Toggle(isOn: workingAction == .mode, intent: TogglePATCOReachabilityModeIntent(originId: originId, currentMode: mode)) {
                    Image(systemName: mode == .driving ? "car.fill" : "figure.walk")
                }
                .toggleStyle(WidgetActionProgressStyle(size: size))
                .disabled(!WidgetReachabilitySettings.isEnabled || self.mode == nil)
                .accessibilityLabel(!WidgetReachabilitySettings.isEnabled
                    ? "Travel mode. Widget reachability is off"
                    : self.mode == nil ? "Travel mode unavailable. Refresh location to enable"
                    : mode == .driving ? "Driving estimate. Switch to walking" : "Walking estimate. Switch to driving")
            }
            Toggle(isOn: workingAction == .refresh, intent: RefreshPATCOWidgetIntent()) {
                Image(systemName: "arrow.clockwise")
            }
                .toggleStyle(WidgetActionProgressStyle(size: size))
                .disabled(!WidgetReachabilitySettings.isEnabled)
                .accessibilityLabel("Refresh departures and travel estimates")
        }
        .fixedSize(horizontal: true, vertical: false)
        .disabled(workingAction != nil)
        .accessibilityValue(workingAction == nil ? "" : "Updating")
    }

}

// WidgetKit archives both toggle appearances, allowing immediate tap feedback.
// Only persisted action state disables controls; optimistic state must not latch them.
private struct WidgetActionProgressStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack {
                configuration.label.opacity(configuration.isOn ? 0 : 1)
                Image(systemName: "hourglass").opacity(configuration.isOn ? 1 : 0)
            }
                .font(.caption.weight(.bold))
                .foregroundStyle(isEnabled ? Color.patcoGold : .gray)
                .frame(width: size, height: size)
                .background(.white.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "Updating" : "")
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
    var catchStatuses: [Date: WidgetCatchStatus] = [:]
    var routeRevision: Int? = nil
    var refreshCompleted = false
    var hasUnconfirmedTimes = false
    var originId: Station.ID? = nil
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
        // Previews must not resolve arrivals, publish state, or build future entries.
        let now = Date()
        let route = SharedRouteCoordinator.current()
        let candidate = SharedTripState.current()
        let shared = candidate?.routeRevision == route?.revision ? candidate : nil
        let store = PATCOScheduleStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let dates = (-1...1).compactMap { calendar.date(byAdding: .day, value: $0, to: now) }
        let schedules = SharedSpecialScheduleCache.schedules(matching: dates, calendar: calendar)
        store.applySpecialSchedules(schedules)
        let origin = route.flatMap { store.station(for: $0.originId) }
        let destination = route.flatMap { store.station(for: $0.destinationId) }
        let departures = shared?.upcoming(at: now) ?? origin.flatMap { origin in
            destination.map { store.departures(from: origin, to: $0, after: now, limit: 3) }
        } ?? []
        let selected = WidgetDepartureSelection.select(departures, limit: 3)
        let statuses = Dictionary(selected.compactMap { departure -> (Date, WidgetCatchStatus)? in
            guard WidgetReachabilitySettings.isEnabled, WidgetRefreshState.guidanceAllowed,
                  !SharedWidgetReachabilityState.blocksCatchability(originId: departure.origin.id),
                  let result = shared?.catchResult(for: departure, at: now) else { return nil }
            return (departure.departureDate, WidgetCatchStatus(result))
        }, uniquingKeysWith: { first, _ in first })
        let unconfirmed = WidgetTimelinePolicy.unconfirmedTimesByDay(schedules: schedules, dates: [now])
        completion(PATCOLockScreenEntry(date: now, departureDates: selected.map(\.departureDate),
            originName: origin?.name ?? "PATCO", destinationName: destination?.name ?? "",
            catchStatuses: statuses, routeRevision: route?.revision,
            hasUnconfirmedTimes: unconfirmed[calendar.startOfDay(for: now)] ?? false, originId: origin?.id))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PATCOLockScreenEntry>) -> Void) {
        let request = SharedWidgetDiagnostics.latestReloadRequest
        let runId = UUID()
        let requestDetail = request.map {
            "Latest request \($0.id); \($0.action); expected revision \($0.revision); \(Int(max(0, Date().timeIntervalSince($0.date)))) sec since request (trigger not exposed by iOS)"
        } ?? "No recorded widget action reload request"
        SharedWidgetDiagnostics.record("Lock Screen timeline requested", detail: "Run \(runId); \(requestDetail)")
        let routeChanged = SharedRouteCoordinator.current().map {
            $0.revision != SharedDiagnosticState.snapshot(for: .lockScreen)?.revision
        } ?? false
        if SharedTripState.current() != nil && (routeChanged || WidgetRefreshState.recentActionTrip != nil) {
            SharedWidgetDiagnostics.record("Lock Screen route prioritized",
                detail: "Publishing committed route immediately without waiting for GPS")
            completion(makeCurrentTimeline(currentLocation: WidgetRefreshState.authorizedCachedLocation,
                reloadRequest: request, runId: runId))
            return
        }
        let callback = LockScreenTimelineCompletion(call: completion)
        Task { @MainActor in
            _ = await NextPATCOTrainWidgetProvider().specialSchedulesForDepartureWindow(from: Date())
            let location: CLLocation?
            let status = CLLocationManager().authorizationStatus
            if status != .authorizedAlways && status != .authorizedWhenInUse {
                SharedCurrentLocationCache.clear()
                location = nil
            } else {
                if WidgetRefreshState.recentActionTrip != nil {
                    location = WidgetRefreshState.authorizedCachedLocation
                    SharedWidgetDiagnostics.record("Lock Screen action rendered", detail: "Using committed shared schedule without waiting for location")
                } else {
                    location = WidgetRefreshState.authorizedCachedLocation
                }
            }
            callback.call(makeCurrentTimeline(currentLocation: location, reloadRequest: request, runId: runId))
        }
    }

    private func makeCurrentTimeline(currentLocation: CLLocation?,
                                     reloadRequest: SharedWidgetDiagnostics.ReloadRequest? = nil,
                                     runId: UUID? = nil) -> Timeline<PATCOLockScreenEntry> {
        var timeline = makeTimeline(at: Date(), currentLocation: currentLocation,
                                    reloadRequest: reloadRequest, runId: runId)
        // Another widget process may reverse the route while this timeline is being built.
        for _ in 0..<2 {
            guard timeline.entries.first?.routeRevision != SharedRouteCoordinator.current()?.revision else { return timeline }
            SharedWidgetDiagnostics.record("Lock Screen timeline superseded",
                detail: "Rebuilding for the latest committed route before completion")
            timeline = makeTimeline(at: Date(), currentLocation: currentLocation,
                                    reloadRequest: reloadRequest, runId: runId)
        }
        if timeline.entries.first?.routeRevision != SharedRouteCoordinator.current()?.revision {
            WidgetCenter.shared.reloadTimelines(ofKind: "NextPATCOLockScreenWidget")
            let store = PATCOScheduleStore()
            let route = SharedRouteCoordinator.current()
            let neutral = PATCOLockScreenEntry(date: Date(), departureDates: [],
                originName: route.flatMap { store.station(for: $0.originId)?.name } ?? "PATCO",
                destinationName: route.flatMap { store.station(for: $0.destinationId)?.name } ?? "",
                routeRevision: route?.revision)
            return Timeline(entries: [neutral], policy: .after(Date().addingTimeInterval(60)))
        }
        return timeline
    }

    private func makeTimeline(at now: Date, currentLocation: CLLocation?, reloadRequest: SharedWidgetDiagnostics.ReloadRequest? = nil, runId: UUID? = nil) -> Timeline<PATCOLockScreenEntry> {
        let store = PATCOScheduleStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let serviceDates = (-1...1).compactMap { calendar.date(byAdding: .day, value: $0, to: now) }
        let specialSchedules = SharedSpecialScheduleCache.schedules(matching: serviceDates, calendar: calendar)
        if !specialSchedules.isEmpty {
            store.applySpecialSchedules(specialSchedules)
        }
        var route = NextPATCOTrainWidgetProvider().selectedRoute(in: store, currentLocation: currentLocation,
                                                               reloadKind: "NextPATCOTrainWidget")
        let shared = WidgetRefreshState.recentActionTrip
            ?? NextPATCOTrainWidgetProvider().updateSharedTrip(store: store, location: currentLocation,
            reloadWidgets: false)
        if let shared { route = (shared.origin, shared.destination) }
        let routeRevision = shared?.routeRevision ?? SharedRouteCoordinator.current().flatMap {
            $0.originId == route.origin?.id && $0.destinationId == route.destination?.id ? $0.revision : nil
        }
        let departures: [Departure]
        if let shared {
            departures = shared.upcoming(at: now)
        } else if let origin = route.origin, let destination = route.destination {
            departures = store.departures(from: origin, to: destination, after: now, limit: 500)
        } else {
            departures = []
        }

        let confirmationEnd = LockScreenRefreshFeedback.visibleUntil(at: now)
        let scheduledDates = WidgetTimelinePolicy.entryDates(now: now, departures: departures.map(\.departureDate),
                                                            guidanceExpiration: shared?.guidance?.expirationDate)
        let entryDates = Array(Set(scheduledDates + (confirmationEnd.map { [$0] } ?? []))).sorted()
        let unconfirmedDays = WidgetTimelinePolicy.unconfirmedTimesByDay(
            schedules: specialSchedules, dates: entryDates)
        let entries = entryDates.map { date in
            let upcoming = departures.filter { $0.departureDate >= date }
            let selected = WidgetDepartureSelection.select(upcoming, limit: 3)
            let statuses = Dictionary(selected.compactMap { departure -> (Date, WidgetCatchStatus)? in
                guard WidgetReachabilitySettings.isEnabled,
                      !SharedWidgetReachabilityState.blocksCatchability(originId: departure.origin.id) else { return nil }
                guard WidgetRefreshState.guidanceAllowed,
                      let result = shared?.catchResult(for: departure, at: date) else { return nil }
                return (departure.departureDate, WidgetCatchStatus(result))
            }, uniquingKeysWith: { first, _ in first })
            return PATCOLockScreenEntry(
                date: date,
                departureDates: selected.map(\.departureDate),
                originName: shared?.origin.name ?? route.origin?.name ?? "PATCO",
                destinationName: shared?.destination.name ?? route.destination?.name ?? "",
                catchStatuses: statuses,
                routeRevision: routeRevision,
                refreshCompleted: confirmationEnd.map { date < $0 } ?? false,
                hasUnconfirmedTimes: unconfirmedDays[calendar.startOfDay(for: date)] ?? false,
                originId: shared?.origin.id ?? route.origin?.id
            )
        }
        let journey = SharedRouteCoordinator.current()?.journey
        let legacyActivity = Activity<PATCOTripActivityAttributes>.activities.contains {
            ($0.activityState == .active || $0.activityState == .stale)
                && $0.attributes.originName == route.origin?.name
                && $0.attributes.destinationName == route.destination?.name
                && $0.content.state.departureDate <= now.addingTimeInterval(3600)
                && !ScheduledTripExpiration.hasExpired(arrivalDate: $0.content.state.arrivalDate, now: now)
        }
        let hasActiveTrip = journey.map { $0.isActive(at: now) && $0.departure <= now.addingTimeInterval(3600) }
            ?? legacyActivity
        let nextRefresh = WidgetTimelinePolicy.lockScreenRefresh(
            now: now, trackingDeadline: journey?.isActive(at: now) == false ? nil : SharedJourneyTracking.deadline,
            hasActiveTrip: hasActiveTrip
        )
        SharedWidgetDiagnostics.record("Lock Screen timeline prepared", detail: "\(departures.count) departures; next requested \(nextRefresh.formatted(date: .omitted, time: .shortened)); \(Int(nextRefresh.timeIntervalSince(now) / 60))-minute interval")
        let committed = SharedRouteCoordinator.current()
        let recordedRevision = committed?.originId == route.origin?.id && committed?.destinationId == route.destination?.id
            ? committed?.revision : nil
        if let runId {
            let result = reloadRequest.map {
                "Request \($0.id); \($0.outcome(revision: recordedRevision, originId: route.origin?.id, destinationId: route.destination?.id))"
            } ?? "No recorded widget action reload request"
            SharedWidgetDiagnostics.record("Lock Screen route loaded", detail: "Run \(runId); \(result); loaded revision \(recordedRevision.map(String.init) ?? "unknown"): \(route.origin?.name ?? "none") to \(route.destination?.name ?? "none"); timeline prepared for WidgetKit, on-screen redraw not confirmed")
        }
        SharedDiagnosticState.record(.lockScreen, origin: route.origin, destination: route.destination,
                                     revision: recordedRevision, nextRequestedAt: nextRefresh,
                                     location: currentLocation, travelEstimateSource: shared?.guidance?.estimateSource ?? "Scheduled times only",
                                     appliedSpecialSchedules: specialSchedules.map { "\($0.title) (\($0.serviceDate.formatted(date: .abbreviated, time: .omitted)))" })
        return Timeline(entries: entries, policy: .after(nextRefresh))
    }
}

private struct PATCOLockScreenView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: PATCOLockScreenEntry

    private var visibleCatchStatuses: [Date: WidgetCatchStatus] {
        guard WidgetReachabilitySettings.isEnabled, let originId = entry.originId,
              !SharedWidgetReachabilityState.blocksCatchability(originId: originId) else { return [:] }
        return entry.catchStatuses
    }

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            Text(entry.destinationName.isEmpty ? "PATCO" : "\(shortName(entry.originName)) → \(shortName(entry.destinationName))\(dayContextText.map { " · \($0)" } ?? "")")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)

            if entry.hasUnconfirmedTimes {
                Text("Check PDF: DST times unconfirmed")
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if !entry.departureDates.isEmpty {
                departureTimesText
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .accessibilityLabel(
                        "Scheduled departures: " + entry.departureDates
                            .map { date in
                                PATCOClock.timeText(date)
                                    + (visibleCatchStatuses[date].map { ", \($0.accessibilityDescription)" } ?? "")
                            }
                            .joined(separator: ", ")
                    )

            } else {
                Text("Open for scheduled departures")
                    .font(.caption)
                    .lineLimit(2)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
        .containerBackground(.clear, for: .widget)
        .widgetURL(URL(string: "patconext://widget"))
    }

    private func shortName(_ name: String) -> String {
        name == "15/16th and Locust" ? "15/16th" : name
    }

    private var departureTimesText: Text {
        let formatter = DateFormatter()
        formatter.timeZone = PATCOClock.calendar.timeZone
        let hourFormat = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h a"
        formatter.dateFormat = hourFormat.contains("a") ? "h:mm" : "HH:mm"
        var text = AttributedString()
        for (index, date) in entry.departureDates.enumerated() {
            if index > 0 { text.append(AttributedString(" · ")) }
            var time = AttributedString(formatter.string(from: date) + PATCOClock.timeZoneSuffix(date))
            time.foregroundColor = renderingMode == .fullColor
                ? visibleCatchStatuses[date]?.color ?? .primary
                : .primary
            text.append(time)
        }
        return Text(text)
    }

    private var dayContextText: String? {
        let calendar = PATCOClock.calendar
        let nextDayDates = entry.departureDates.filter { !calendar.isDate($0, inSameDayAs: entry.date) }
        guard !nextDayDates.isEmpty else { return nil }

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: entry.date)
        let dayName = tomorrow.map { calendar.isDate(nextDayDates[0], inSameDayAs: $0) } == true
            ? "tomorrow"
            : nextDayDates[0].formatted(Date.FormatStyle(timeZone: PATCOClock.calendar.timeZone).weekday(.wide))
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
                        Text(PATCOClock.timeText(context.state.departureDate, relativeTo: context.state.arrivalDate))
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
                        Text("Arrives \(PATCOClock.timeText(context.state.arrivalDate, relativeTo: context.state.departureDate))")
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
                            isStale: context.isStale,
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
        PATCOClock.timeText(date)
    }

    private func shortTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = PATCOClock.calendar.timeZone
        formatter.dateFormat = "h:mm"
        return formatter.string(from: date) + PATCOClock.timeZoneSuffix(date)
    }

    private func arrivalTimeText(_ date: Date) -> String {
        "Arrives \(PATCOClock.timeText(date))"
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
                    Text(PATCOClock.timeText(context.state.arrivalDate, relativeTo: context.state.departureDate))
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
                    departureDate: context.state.departureDate,
                    isStale: context.isStale
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
            Text(PATCOClock.timeText(context.state.departureDate, relativeTo: context.state.arrivalDate))
                .font(.title3.monospacedDigit().weight(.bold))
                .foregroundStyle(.white)
        }
    }

}

private struct ScheduledDepartureCountdownView: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    let startDate: Date
    let departureDate: Date
    let isStale: Bool
    var compact = false

    private var intervalStart: Date {
        min(startDate, departureDate)
    }

    var body: some View {
        if ScheduledDeparturePresentation.hasDeparted(departureDate: departureDate, isStale: isStale) {
            Text("Scheduled departure time has passed")
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.white.opacity(0.64))
        } else {
            countdown
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
            // An absolute time cannot mistake elapsed minutes for time remaining in Always-On mode.
            Text(PATCOClock.timeText(departureDate))
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
