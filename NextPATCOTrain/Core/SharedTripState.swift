import Combine
import CoreLocation
import Foundation
import Darwin

enum SharedTripState {
    struct Guidance: Codable {
        let location: SharedCurrentLocationCache.Snapshot
        let mode: SharedReachabilityModeStore.Mode?
        let travelMinutes: Int
        let estimateSource: String
        var estimateFetchedAt: Date? = nil

        var expirationDate: Date {
            if estimateSource == "At station" { return location.timestamp.addingTimeInterval(31) }
            let locationExpiry = location.timestamp.addingTimeInterval(181)
            guard estimateSource == "Maps estimate", let estimateFetchedAt else { return locationExpiry }
            return min(locationExpiry, estimateFetchedAt.addingTimeInterval(300))
        }

        static func meaningfullyChanged(from previous: Guidance?, to current: Guidance?, at now: Date) -> Bool {
            switch (previous, current) {
            case (nil, nil): return false
            case let (old?, new?):
                return old.mode != new.mode || old.travelMinutes != new.travelMinutes
                    || old.estimateSource != new.estimateSource
                    || (old.expirationDate <= now) != (new.expirationDate <= now)
            default: return true
            }
        }

        func hasFreshMapsEstimate(at date: Date) -> Bool {
            guard estimateSource == "Maps estimate", let estimateFetchedAt,
                  mode != nil, travelMinutes > 0,
                  LocationGuidancePolicy.isUsable(location.location, maxAge: 180, now: date) else { return false }
            return (0..<300).contains(date.timeIntervalSince(estimateFetchedAt))
        }
    }

    struct CatchResult {
        enum Status { case atStation, comfortable, tight, probablyMissed, tooLate }
        let status: Status
        let mode: SharedReachabilityModeStore.Mode?
        let travelMinutes: Int
        let arrivalAtStation: Date
        let leaveBy: Date

        var isMakeable: Bool {
            switch status {
            case .atStation, .comfortable, .tight: true
            case .probablyMissed, .tooLate: false
            }
        }
    }

    struct Snapshot: Codable {
        let schema: Int
        let routeRevision: Int
        let origin: Station
        let destination: Station
        let preparedAt: Date
        let departures: [Departure]
        let scheduleVersion: String?
        let scheduleExpired: Bool
        let scheduleExpiresAt: Date?
        let specialSchedules: [PATCOSpecialSchedule]
        let guidance: Guidance?
        let lastBroadcastAt: Date

        func isScheduleExpired(at date: Date) -> Bool {
            scheduleExpired || scheduleExpiresAt.map { date >= $0 } == true
        }

        func upcoming(at date: Date, limit: Int? = nil) -> [Departure] {
            let result = departures.filter { $0.departureDate >= date && !$0.isRemovedBySpecialSchedule }
            return limit.map { Array(result.prefix($0)) } ?? result
        }

        func catchResult(for departure: Departure, at date: Date, enforceOneHourLimit: Bool = true) -> CatchResult? {
            guard departure.origin.id == origin.id, departure.destination.id == destination.id,
                  departure.departureDate >= date,
                  !enforceOneHourLimit || departure.departureDate.timeIntervalSince(date) <= 3600,
                  !departure.isRemovedBySpecialSchedule, let guidance,
                  LocationGuidancePolicy.isUsable(guidance.location.location, maxAge: 180, now: date) else { return nil }
            let location = guidance.location.location
            if LocationGuidancePolicy.isAtStation(location, station: origin.location, now: date) {
                return .init(status: .atStation, mode: nil, travelMinutes: 0,
                             arrivalAtStation: date, leaveBy: departure.departureDate)
            }
            guard let mode = guidance.mode,
                  mode != .driving || guidance.hasFreshMapsEstimate(at: date),
                  guidance.estimateSource != "Maps estimate" || guidance.hasFreshMapsEstimate(at: date) else { return nil }
            let buffer = mode == .driving ? 3 : 2
            let spare = Int(floor(departure.departureDate.timeIntervalSince(date) / 60)) - guidance.travelMinutes - buffer
            let status: CatchResult.Status = spare >= 5 ? .comfortable : spare >= 0 ? .tight : spare < -5 ? .tooLate : .probablyMissed
            return .init(status: status, mode: mode, travelMinutes: guidance.travelMinutes,
                         arrivalAtStation: date.addingTimeInterval(Double(guidance.travelMinutes * 60)),
                         leaveBy: departure.departureDate.addingTimeInterval(-Double((guidance.travelMinutes + buffer) * 60)))
        }
    }

    struct Update {
        let snapshot: Snapshot
        let shouldReloadWidgets: Bool
    }

    // Uses the route coordinator's file lock so a result cannot commit across a route change.
    private static func locked<T>(directory: URL?, body: (URL, SharedRouteCoordinator.Route) -> T?) -> T? {
        guard let root = directory ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.rhome.patconext") else { return nil }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let descriptor = open(root.appendingPathComponent("route.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { return nil }
            defer { flock(descriptor, LOCK_UN) }
            let route = try JSONDecoder().decode(SharedRouteCoordinator.Route.self,
                                                 from: Data(contentsOf: root.appendingPathComponent("resolved-route.json")))
            return body(root, route)
        } catch { return nil }
    }

    static func current(directory: URL? = nil) -> Snapshot? {
        locked(directory: directory) { root, route in
            guard let snapshot = read(root), snapshot.schema == 1, snapshot.routeRevision == route.revision,
                  snapshot.origin.id == route.originId, snapshot.destination.id == route.destinationId else { return nil }
            return snapshot
        }
    }

    private static func read(_ root: URL) -> Snapshot? {
        guard let snapshot = (try? Data(contentsOf: root.appendingPathComponent("trip-state.json"))).flatMap({
            try? JSONDecoder().decode(Snapshot.self, from: $0)
        }), snapshot.schema == 1 else { return nil }
        return snapshot
    }

    static func update(store: PATCOScheduleStore, routeRevision: Int, location: CLLocation?,
                       locationAllowed: Bool = true, now: Date = Date(), directory: URL? = nil,
                       specialSchedules: [PATCOSpecialSchedule] = []) -> Update? {
        // Compute schedules without holding the route lock needed by interactive actions.
        guard let preparedRoute = SharedRouteCoordinator.current(directory: directory),
              preparedRoute.revision == routeRevision else { return nil }
        let store = directory == nil ? PATCOScheduleStore() : store
        guard let origin = store.station(for: preparedRoute.originId),
              let destination = store.station(for: preparedRoute.destinationId), store.loadError == nil else { return nil }
        let specials = specialSchedules
        store.applySpecialSchedules(specials)
        let preparedDepartures = store.departures(from: origin, to: destination, after: now, limit: 500)
            .filter { !$0.isRemovedBySpecialSchedule }
        return locked(directory: directory) { root, route -> Update? in
            guard route.revision == routeRevision else { return nil }
            let previous = read(root)
            if let previous, previous.routeRevision == routeRevision, previous.preparedAt > now {
                return .init(snapshot: previous, shouldReloadWidgets: false)
            }
            var departures = preparedDepartures
            if previous?.routeRevision == routeRevision {
                // Preserve identity across refreshes for the same scheduled departure.
                let priorIDs = Dictionary(previous!.departures.map {
                    ("\($0.trip.id)|\($0.departureDate.timeIntervalSince1970)", $0.id)
                }, uniquingKeysWith: { first, _ in first })
                for index in departures.indices {
                    if let id = priorIDs["\(departures[index].trip.id)|\(departures[index].departureDate.timeIntervalSince1970)"] {
                        departures[index].id = id
                    }
                }
            }
            var best = locationAllowed ? location : nil
            if locationAllowed, let older = previous?.guidance?.location.location,
               LocationGuidancePolicy.isUsable(older, maxAge: 180, now: now),
               best.map({ !LocationGuidancePolicy.isUsable($0, maxAge: 180, now: now) || $0.timestamp < older.timestamp }) ?? true {
                best = older
            }
            var guidance: Guidance?
            if let best, LocationGuidancePolicy.isUsable(best, maxAge: 180, now: now) {
                let distance = best.distance(from: origin.location)
                if distance <= 150 * 1_609.34 {
                    let atStation = LocationGuidancePolicy.isAtStation(best, station: origin.location, now: now)
                    if atStation { SharedReachabilityModeStore.clearOnArrival(originId: origin.id) }
                    let mode = atStation ? nil : SharedReachabilityModeStore.resolve(
                        originId: origin.id, distanceToStation: distance,
                        minutesUntilDeparture: Int((departures.first?.departureDate ?? now).timeIntervalSince(now) / 60),
                        defaultsToWalking: origin.defaultsToWalkingForReachability,
                        walkingEstimate: SharedTravelTimeEstimateCache.estimate(mode: .walking, origin: origin, currentLocation: best), now: now)
                    let estimate = mode.flatMap {
                        SharedTravelTimeEstimateCache.estimate(mode: $0 == .driving ? .driving : .walking,
                                                               origin: origin, currentLocation: best)
                    }
                    let minutes = atStation ? 0 : estimate?.minutes ?? (mode == .driving ? 0 : max(1, Int(ceil(distance / 75))))
                    guidance = .init(location: .init(latitude: best.coordinate.latitude, longitude: best.coordinate.longitude,
                                                     horizontalAccuracy: best.horizontalAccuracy, timestamp: best.timestamp),
                                     mode: mode, travelMinutes: minutes,
                                     estimateSource: atStation ? "At station" : estimate == nil ? (mode == .driving ? "Driving estimate unavailable" : "Distance-based fallback") : "Maps estimate",
                                     estimateFetchedAt: estimate?.fetchedAt)
                }
            }
            let routeChanged = previous?.routeRevision != routeRevision
            let scheduleChanged = previous?.scheduleVersion != store.scheduleFeedVersion
                || previous?.specialSchedules != specials
                || previous?.departures.first?.departureDate != departures.first?.departureDate
            // Coalesce cross-surface reloads; timeline generation must not create a reload loop.
            let guidanceChanged = Guidance.meaningfullyChanged(from: previous?.guidance, to: guidance, at: now)
            let broadcast = routeChanged || scheduleChanged || guidanceChanged || now.timeIntervalSince(previous?.lastBroadcastAt ?? .distantPast) >= 180
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
            let expiration = store.scheduleFeedEndDate.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
            let snapshot = Snapshot(schema: 1, routeRevision: routeRevision, origin: origin, destination: destination,
                                    preparedAt: now, departures: departures, scheduleVersion: store.scheduleFeedVersion,
                                    scheduleExpired: store.feed?.isExpired(on: now) ?? true, scheduleExpiresAt: expiration,
                                    specialSchedules: specials,
                                    guidance: guidance, lastBroadcastAt: broadcast ? now : previous!.lastBroadcastAt)
            do {
                try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("trip-state.json"), options: .atomic)
                return .init(snapshot: snapshot, shouldReloadWidgets: broadcast)
            } catch { return nil }
        }
    }
}
