import CoreLocation
import Foundation

/// Owns station evidence independently of the screen's presentation state.
struct JourneyStationEvidence {
    var precise = CurrentStationEvidence()
    var underground = UndergroundDepartureEvidence()

    mutating func station(for location: CLLocation, stations: [Station], now: Date = Date()) -> Station? {
        guard let nearby = LocationGuidancePolicy.detectedStation(location, stations: stations, now: now) else {
            precise = CurrentStationEvidence()
            return nil
        }
        let otherDistance = stations.filter { $0.id != nearby.id }
            .map { location.distance(from: $0.location) }.min() ?? .infinity
        return precise.accepts(stationId: nearby.id, station: nearby.location, location: location,
            nearestOtherDistance: otherDistance, now: now) ? nearby : nil
    }

    mutating func inferredStation(for location: CLLocation, stations: [Station], origin: String?,
                                 destination: String?, reliableStation: Station?, journeyActive: Bool,
                                 now: Date = Date()) -> String? {
        guard let start = stations.firstIndex(where: { $0.id == origin }),
              let end = stations.firstIndex(where: { $0.id == destination }) else { return nil }
        let segment = Array(stations[min(start, end)...max(start, end)])
        let route = (start <= end ? segment : Array(segment.reversed())).map(\.id)
        let nearest = stations.min { location.distance(from: $0.location) < location.distance(from: $1.location) }
        let others = stations.filter { $0.id != nearest?.id }
            .map { location.distance(from: $0.location) }.min() ?? .infinity
        return underground.observe(route: route, stationId: nearest?.id,
            reliable: reliableStation != nil && reliableStation?.id == nearest?.id,
            underground: nearest?.supportsUndergroundReturnRecovery == true,
            distance: nearest.map { location.distance(from: $0.location) } ?? .infinity,
            otherDistance: others, location: location, journeyActive: journeyActive, now: now)
    }
}

struct JourneyArrivalController {
    struct Completion {
        let route: SharedRouteCoordinator.Route
        let station: Station
        let returnStation: Station
        let inferred: Bool
    }

    struct Dependencies {
        var current: () -> SharedRouteCoordinator.Route?
        var check: (Int, CLLocation, [Station], Date?) -> DestinationArrivalGate?
        var commit: (String, String, Int, Date) -> SharedRouteCoordinator.Route?
        var record: (String, String) -> Void

        static var live: Self {
            Self(current: { SharedRouteCoordinator.current() },
                 check: { SharedRouteCoordinator.checkArrival(expectedRevision: $0, location: $1,
                    stations: $2, expectedArrival: $3) },
                 commit: { SharedRouteCoordinator.commit(originId: $0, destinationId: $1,
                    expectedRevision: $2, arrival: true, observationAt: $3) },
                 record: { ArrivalDiagnostics.record($0, detail: $1) })
        }
    }

    var dependencies: Dependencies = .live

    func evaluate(location: CLLocation, stations: [Station], station: Station?,
                  destinationId: String?, revision: Int?, expectedArrival: Date?,
                  isViewingToday: Bool) -> Completion? {
        guard isViewingToday, let destinationId, let revision,
              let arrivalStation = station ?? stations.min(by: {
                  location.distance(from: $0.location) < location.distance(from: $1.location)
              }),
              let gate = dependencies.check(revision, location, stations, expectedArrival) else { return nil }
        guard arrivalStation.id == destinationId else {
            let destination = stations.first { $0.id == destinationId }?.name ?? "none"
            dependencies.record("Destination arrival pending", "Nearest \(arrivalStation.name); selected destination \(destination). Current-station detection is evaluated separately.")
            return nil
        }
        guard gate.confirmed else {
            dependencies.record("Arrival not confirmed", "\(arrivalStation.name): \(gate.lastDecision); distance \(location.distance(from: arrivalStation.location)) m; accuracy \(location.horizontalAccuracy) m; adaptive radius \(UrbanStationArrivalPolicy.radius(accuracy: location.horizontalAccuracy)) m; scheduled arrival \(expectedArrival?.description ?? "unavailable")")
            return nil
        }
        dependencies.record(gate.usedNearestStationFallback ? "Estimated arrival" : "Arrival confirmed",
                            "\(arrivalStation.name): \(gate.lastDecision)")
        guard let route = dependencies.current(), route.revision == revision,
              route.destinationId == destinationId,
              let returnStation = stations.first(where: { $0.id == SharedWidgetRouteMemory.returnDestination(
                arrivingAt: destinationId, currentOrigin: route.originId,
                savedOrigin: route.savedOriginId, savedDestination: route.savedDestinationId) }),
              returnStation.id != arrivalStation.id,
              let committed = dependencies.commit(arrivalStation.id, returnStation.id, revision, location.timestamp),
              committed.originId == arrivalStation.id, committed.destinationId == returnStation.id else { return nil }
        return Completion(route: committed, station: arrivalStation, returnStation: returnStation,
                          inferred: gate.usedNearestStationFallback)
    }
}

@MainActor
protocol JourneyProgressRecording: AnyObject {
    var session: JourneyProgressSession? { get }
    func record(_ location: CLLocation, stations: [Station])
    func complete(arrivingAt name: String)
}

/// Keeps an active journey reconciled even while the user browses another day's schedule.
@MainActor
final class JourneyLocationWorkflow {
    private let progress: any JourneyProgressRecording
    private let locationProvider: LocationProvider
    private let store: PATCOScheduleStore
    private let directory: URL?
    private let now: () -> Date
    private let endActivities: (String) -> Void
    private let reloadWidgets: (String) -> Void
    private let publishSnapshot: (SharedRouteCoordinator.Route, CLLocation?, Date) -> Void

    init(progress: any JourneyProgressRecording, locationProvider: LocationProvider,
         store: PATCOScheduleStore, directory: URL? = nil, now: @escaping () -> Date = Date.init,
         endActivities: @escaping (String) -> Void, reloadWidgets: @escaping (String) -> Void,
         publishSnapshot: ((SharedRouteCoordinator.Route, CLLocation?, Date) -> Void)? = nil) {
        self.progress = progress
        self.locationProvider = locationProvider
        self.store = store
        self.directory = directory
        self.now = now
        self.endActivities = endActivities
        self.reloadWidgets = reloadWidgets
        self.publishSnapshot = publishSnapshot ?? { route, location, now in
            let dates = (-1...1).compactMap { PATCOClock.calendar.date(byAdding: .day, value: $0, to: now) }
            _ = SharedTripState.update(store: store, routeRevision: route.revision,
                location: location, locationAllowed: true, now: now,
                specialSchedules: SharedSpecialScheduleCache.schedules(matching: dates, calendar: PATCOClock.calendar))
        }
    }

    /// Returns whether this reading should also update today's station presentation.
    func receive(_ location: CLLocation?, isViewingToday: Bool, displayedRevision: Int?) -> Bool {
        let stations = store.stations
        let now = now()
        if let location { progress.record(location, stations: stations) }
        if let route = SharedRouteCoordinator.current(directory: directory) {
            locationProvider.reconcileSharedRoute(route, previousRevision: displayedRevision)
        }
        guard !isViewingToday else { return true }
        let session = progress.session
        guard let previous = SharedRouteCoordinator.current(directory: directory) else { return false }
        let destination = stations.first { $0.id == previous.destinationId }
        let activeSession = session?.isActive(at: now) == true && session?.destinationName == destination?.name
        guard locationProvider.journeyTrackingDeadline != nil || activeSession,
              let route = SharedRouteCoordinator.resolveWidgetRoute(location: location, stations: stations,
                  now: now, directory: directory, expectedArrival: activeSession ? session?.arrival : nil),
              route.endsJourneyTracking, route.revision != displayedRevision else { return false }

        locationProvider.reconcileSharedRoute(route, previousRevision: displayedRevision ?? previous.revision)
        if route.completesJourney, let station = stations.first(where: { $0.id == route.originId }) {
            progress.complete(arrivingAt: station.name)
            endActivities(station.name)
        }
        publishSnapshot(route, location, now)
        reloadWidgets("Active journey route changed while browsing")
        return false
    }
}
