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
    func refreshTravelTimeEstimate(
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

    func updateSharedTrip(store: PATCOScheduleStore, location: CLLocation?, specialSchedules: [PATCOSpecialSchedule]? = nil,
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

    func specialSchedulesForDepartureWindow(from date: Date, force: Bool = false) async -> [PATCOSpecialSchedule] {
        let calendar = patcoCalendar
        let dates = (-1...1).compactMap { calendar.date(byAdding: .day, value: $0, to: date) }
        let cached = SharedSpecialScheduleCache.schedules(matching: dates, calendar: calendar)
        let result = await SpecialScheduleRefreshDeadline.wait {
            await SharedSpecialScheduleCache.refreshIfNeeded(from: date, calendar: calendar, force: force)
        }
        return result?.schedules ?? cached
    }

    func selectedRoute(in store: PATCOScheduleStore, currentLocation: CLLocation?,
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
