import Combine
import CoreLocation
import Foundation
import Darwin

enum SharedRouteCoordinator {
    struct TemporaryRoute: Codable, Equatable {
        let originId: String
        let destinationId: String
        let manual: Bool
    }
    struct Route: Codable, Equatable {
        let originId: String
        let destinationId: String
        let savedOriginId: String
        let savedDestinationId: String
        let revision: Int
        let updatedAt: Date
        var lastLocationAt: Date?
        let reason: String
        let manual: Bool
        var blockedArrivalDestinationId: String?
        var temporaryRoute: TemporaryRoute? = nil
        var arrivalGate: DestinationArrivalGate? = nil
        var journeySelectedAt: Date? = nil
        var returnDirectionEvidence: ReturnDirectionEvidence? = nil
        var journey: JourneyProgressSession? = nil
        var journeyProgress: TripLocationProgress? = nil

        var event: JourneyRouteEvent { JourneyRouteEvent(rawValue: reason) ?? .unknown }

        var completesJourney: Bool {
            event.completesJourney
        }

        var endsJourneyTracking: Bool {
            event.endsTracking
        }

        func endpointStations(in stations: [Station]) -> [Station] {
            stations.filter { $0.id == savedOriginId || $0.id == savedDestinationId }
        }
    }
    private static let lock = NSLock()

    static func current(directory: URL? = nil) -> Route? {
        transaction(directory: directory) { _ in }
    }

    @discardableResult
    static func beginJourney(_ session: JourneyProgressSession, expectedRevision: Int,
                             now: Date = Date(), directory: URL? = nil, explicitRestart: Bool = false) -> Route? {
        transaction(directory: directory) { route in
            JourneyCoordinator.start(session, route: &route, expectedRevision: expectedRevision,
                                     now: now, explicitRestart: explicitRestart)
        }
    }

    @discardableResult
    static func cancelJourney(key: String, directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            JourneyCoordinator.cancel(key: key, route: &route)
        }
    }

    @discardableResult
    static func saveJourneyProgress(_ progress: TripLocationProgress, key: String,
                                    now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            guard route?.journey?.key == key, route?.journey?.isActive(at: now) == true else { return }
            route?.journeyProgress = progress
        }
    }

    @discardableResult
    static func expireJourney(now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            JourneyCoordinator.restore(route: &route, now: now)
        }
    }

    @discardableResult
    static func destinationRegionEntered(stationId: String, expectedRevision: Int, stations: [Station],
                                         now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            guard let old = route, old.revision == expectedRevision, old.destinationId == stationId,
                  old.blockedArrivalDestinationId == nil, now > old.updatedAt,
                  stations.contains(where: { $0.id == stationId }) else { return }
            let returnId = SharedWidgetRouteMemory.returnDestination(arrivingAt: stationId,
                currentOrigin: old.originId, savedOrigin: old.savedOriginId, savedDestination: old.savedDestinationId)
            guard returnId != stationId, stations.contains(where: { $0.id == returnId }) else { return }
            route = Route(originId: stationId, destinationId: returnId,
                savedOriginId: stationId, savedDestinationId: returnId,
                revision: old.revision + 1, updatedAt: now, lastLocationAt: nil,
                reason: JourneyRouteEvent.backgroundArrival.rawValue, manual: false)
        }
    }

    static func destinationRegionExited(stationId: String, expectedRevision: Int, directory: URL? = nil) {
        _ = transaction(directory: directory) { route in
            guard route?.revision == expectedRevision, route?.destinationId == stationId else { return }
            route?.blockedArrivalDestinationId = nil
            route?.arrivalGate = nil
        }
    }

    @discardableResult
    static func reverse(expectedRevision: Int, selectionLocation: CLLocation? = nil,
                        stations: [Station] = [], now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            guard let old = route, old.revision == expectedRevision else { return }
            route = Route(originId: old.destinationId, destinationId: old.originId,
                          savedOriginId: old.destinationId, savedDestinationId: old.originId,
                          revision: old.revision + 1, updatedAt: now, lastLocationAt: old.lastLocationAt,
                          reason: JourneyRouteEvent.reversal.rawValue, manual: true,
                          blockedArrivalDestinationId: LocationGuidancePolicy.shouldSuppressArrival(
                            location: selectionLocation, station: stations.first { $0.id == old.originId }?.location,
                            now: now) ? old.originId : nil)
        }
    }

    @discardableResult
    static func selectStationDepartures(expectedRevision: Int, originId: String, destinationId: String,
                                        stations: [Station], selectionLocation: CLLocation? = nil,
                                        automatic: Bool = false,
                                        now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            guard let old = route, old.revision == expectedRevision, originId != destinationId,
                  stations.contains(where: { $0.id == originId }),
                  let destination = stations.first(where: { $0.id == destinationId }) else { return }
            // Explicit station departures change the active route, not the saved endpoints.
            route = Route(originId: originId, destinationId: destinationId,
                          savedOriginId: old.savedOriginId, savedDestinationId: old.savedDestinationId,
                          revision: old.revision + 1, updatedAt: now, lastLocationAt: old.lastLocationAt,
                          reason: JourneyRouteEvent.stationSelection.rawValue, manual: automatic ? old.manual : true,
                          blockedArrivalDestinationId: LocationGuidancePolicy.shouldSuppressArrival(
                            location: selectionLocation, station: destination.location, now: now) ? destinationId : nil)
            route?.temporaryRoute = old.temporaryRoute ?? TemporaryRoute(
                originId: old.originId, destinationId: old.destinationId, manual: old.manual)
            if destinationId == old.destinationId {
                route?.arrivalGate = old.arrivalGate
                route?.journeySelectedAt = old.journeySelectedAt ?? old.updatedAt
                route?.returnDirectionEvidence = old.returnDirectionEvidence
            }
        }
    }

    static func restoreStationRoute(expectedRevision: Int, departureLocation: CLLocation? = nil,
                                    requireDeparture: Bool = false, stations: [Station] = [],
                                    now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            guard let old = route, old.revision == expectedRevision, let original = old.temporaryRoute else { return }
            if requireDeparture {
                guard let departureLocation, let station = stations.first(where: { $0.id == old.originId }),
                      departureLocation.timestamp > old.updatedAt,
                      LocationGuidancePolicy.hasLeftStation(departureLocation, station: station.location, now: now) else { return }
            }
            route = Route(originId: original.originId, destinationId: original.destinationId,
                          savedOriginId: old.savedOriginId, savedDestinationId: old.savedDestinationId,
                          revision: old.revision + 1, updatedAt: now, lastLocationAt: old.lastLocationAt,
                          reason: JourneyRouteEvent.stationRestored.rawValue, manual: original.manual,
                          blockedArrivalDestinationId: original.destinationId == old.destinationId ? old.blockedArrivalDestinationId : nil,
                          arrivalGate: original.destinationId == old.destinationId ? old.arrivalGate : nil,
                          journeySelectedAt: original.destinationId == old.destinationId ? old.journeySelectedAt ?? old.updatedAt : nil)
            if original.destinationId == old.destinationId {
                route?.returnDirectionEvidence = old.returnDirectionEvidence
            }
        }
    }

    @discardableResult
    static func recoverReturnDirection(expectedRevision: Int, location: CLLocation?, stations: [Station],
                                       now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            guard let old = route, old.revision == expectedRevision,
                  let origin = stations.first(where: { $0.id == old.savedOriginId }),
                  let destination = stations.first(where: { $0.id == old.destinationId }),
                  origin.id != destination.id else { return }
            var evidence = old.returnDirectionEvidence ?? ReturnDirectionEvidence()
            guard let location else {
                if destination.supportsUndergroundReturnRecovery {
                    evidence.resetUndergroundCandidate()
                    route?.returnDirectionEvidence = evidence
                } else {
                    route?.returnDirectionEvidence = nil
                }
                return
            }
            let recovered = evidence.accepts(location: location, origin: origin.location,
                destination: destination.location, selectedAt: old.journeySelectedAt ?? old.updatedAt, now: now,
                undergroundDestination: destination.supportsUndergroundReturnRecovery ? destination : nil, stations: stations)
            route?.returnDirectionEvidence = evidence
            if directory == nil, let diagnostic = evidence.undergroundDiagnostic,
               diagnostic != old.returnDirectionEvidence?.undergroundDiagnostic {
                ArrivalDiagnostics.record("Underground return recovery", detail: "\(destination.name): \(diagnostic)")
            }
            guard recovered, old.blockedArrivalDestinationId == nil else { return }
            let returnId = SharedWidgetRouteMemory.returnDestination(arrivingAt: destination.id,
                currentOrigin: old.originId, savedOrigin: old.savedOriginId, savedDestination: old.savedDestinationId)
            guard returnId != destination.id else { return }
            route = Route(originId: destination.id, destinationId: returnId,
                savedOriginId: destination.id, savedDestinationId: returnId,
                revision: old.revision + 1, updatedAt: now, lastLocationAt: location.timestamp,
                reason: JourneyRouteEvent.recovery.rawValue, manual: false)
        }
    }

    static func checkArrival(expectedRevision: Int, location: CLLocation?, stations: [Station],
                             now: Date = Date(), directory: URL? = nil,
                             expectedArrival: Date? = nil) -> DestinationArrivalGate? {
        var result: DestinationArrivalGate?
        _ = transaction(directory: directory) { route in
            guard let old = route, old.revision == expectedRevision else { return }
            guard let location else {
                route?.arrivalGate?.resetEvidence()
                return
            }
            guard
                  let destination = stations.first(where: { $0.id == old.destinationId }),
                  let origin = stations.first(where: { $0.id == old.savedOriginId }) else { return }
            var gate = old.arrivalGate ?? DestinationArrivalGate()
            gate.expectedArrival = expectedArrival ?? (old.journey?.isActive(at: now) == true ? old.journey?.arrival : nil)
            if location.horizontalAccuracy <= 75,
               let station = LocationGuidancePolicy.detectedStation(location, stations: stations, now: now),
               station.id != destination.id {
                gate.invalidateDestinationEvidence(location: location)
            }
            let selectedAt = old.journeySelectedAt ?? old.updatedAt
            gate.observeJourney(origin: origin.location, destination: destination.location,
                                location: location, selectedAt: selectedAt, now: now)
            gate.observeDeparture(from: destination.location, location: location, now: now)
            let otherDistance = stations.filter { $0.id != destination.id }
                .map { location.distance(from: $0.location) }.min() ?? .infinity
            _ = gate.accepts(destinationId: destination.id, station: destination.location,
                             location: location, nearestOtherStationDistance: otherDistance,
                             routeSelectedAt: selectedAt, now: now,
                             undergroundDestination: destination.supportsUndergroundReturnRecovery,
                             arrivalSuppressed: old.blockedArrivalDestinationId == destination.id)
            route?.arrivalGate = gate
            result = gate
            if directory == nil {
                ArrivalDiagnostics.record("Arrival decision", detail: gate.lastDecision,
                    context: .arrival(component: "app.arrival", route: old, location: location, gate: gate))
            }
        }
        return result
    }

    @discardableResult
    static func selectNearestStation(expectedRevision: Int, location: CLLocation,
                                     stations: [Station], now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            guard let old = route, old.revision == expectedRevision,
                  old.endpointStations(in: stations).count == 2,
                  let nearest = LocationGuidancePolicy.nearestUnambiguousStation(location,
                    stations: old.endpointStations(in: stations), now: now) else { return }
            // The compass chooses direction, never a new route endpoint.
            let destinationId = nearest.id == old.savedOriginId ? old.savedDestinationId : old.savedOriginId
            guard destinationId != nearest.id,
                  let destination = stations.first(where: { $0.id == destinationId }) else { return }
            route = Route(originId: nearest.id, destinationId: destinationId,
                          savedOriginId: nearest.id, savedDestinationId: destinationId,
                          revision: old.revision + 1, updatedAt: now, lastLocationAt: location.timestamp,
                          reason: JourneyRouteEvent.nearest.rawValue, manual: true,
                          blockedArrivalDestinationId: LocationGuidancePolicy.shouldSuppressArrival(
                            location: location, station: destination.location, now: now) ? destinationId : nil)
        }
    }

    @discardableResult
    static func routeForApp(defaultOriginId: String, defaultDestinationId: String,
                            now: Date = Date(), directory: URL? = nil) -> Route? {
        // Refreshing local UI is not a route selection. Bootstrap only when nothing is persisted.
        current(directory: directory) ?? commit(originId: defaultOriginId, destinationId: defaultDestinationId,
                                               now: now, directory: directory)
    }

    @discardableResult
    static func commit(originId: String, destinationId: String, manual: Bool = false,
                       expectedRevision: Int? = nil, arrival: Bool = false,
                       observationAt: Date? = nil,
                       selectionLocation: CLLocation? = nil, destinationLocation: CLLocation? = nil,
                       now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            guard originId != destinationId else { return }
            if !manual, let old = route, old.revision != expectedRevision { return }
            // Fresh GPS must not undo an explicit route choice from another surface.
            if !manual, !arrival, route?.manual == true { return }
            if !manual, let old = route, old.originId == originId, old.destinationId == destinationId { return }
            if !manual, let old = route, let observationAt, observationAt <= old.updatedAt { return }
            if arrival, route?.blockedArrivalDestinationId != nil { return }
            let old = route
            route = Route(originId: originId, destinationId: destinationId,
                          savedOriginId: manual || arrival ? originId : old?.savedOriginId ?? originId,
                          savedDestinationId: manual || arrival ? destinationId : old?.savedDestinationId ?? destinationId,
                          revision: (old?.revision ?? 0) + 1, updatedAt: now, lastLocationAt: old?.lastLocationAt,
                          reason: (manual ? JourneyRouteEvent.selection : arrival ? .appArrival : .bootstrap).rawValue,
                          manual: manual || (!arrival && old?.manual == true),
                          blockedArrivalDestinationId: manual
                            ? (LocationGuidancePolicy.shouldSuppressArrival(location: selectionLocation,
                                station: destinationLocation, now: now) ? destinationId : nil)
                            : (arrival ? nil : old?.blockedArrivalDestinationId))
        }
    }

    static func confirmTripArrival(originId: String, destinationId: String, expectedRevision: Int,
                                   now: Date = Date(), directory: URL? = nil) -> Route? {
        transaction(directory: directory) { route in
            guard let old = route, old.revision == expectedRevision,
                  old.destinationId == destinationId,
                  (old.originId == originId || old.temporaryRoute?.originId == originId),
                  originId != destinationId else { return }
            route = Route(originId: destinationId, destinationId: originId,
                          savedOriginId: destinationId, savedDestinationId: originId,
                          revision: old.revision + 1, updatedAt: now, lastLocationAt: old.lastLocationAt,
                          reason: JourneyRouteEvent.confirmedArrival.rawValue, manual: false)
        }
    }

    static func resolve(location: CLLocation?, stations: [Station], now: Date = Date(), directory: URL? = nil,
                        onArrivalCheck: ((DestinationArrivalGate) -> Void)? = nil,
                        expectedArrival: Date? = nil) -> Route? {
        transaction(directory: directory) { route in
            clearArrivalSuppressionIfDeparted(route: &route, location: location, stations: stations, now: now)
            if location == nil { route?.arrivalGate?.resetEvidence() }
            guard let old = route, let location,
                  let station = stations.first(where: { $0.id == old.destinationId }) else { return }
            var gate = old.arrivalGate ?? DestinationArrivalGate()
            if let expectedArrival = expectedArrival ?? (old.journey?.isActive(at: now) == true ? old.journey?.arrival : nil) {
                gate.expectedArrival = expectedArrival
            }
            if let origin = stations.first(where: { $0.id == old.savedOriginId }) {
                gate.observeJourney(origin: origin.location, destination: station.location, location: location,
                                    selectedAt: old.journeySelectedAt ?? old.updatedAt, now: now)
            }
            let otherDistance = stations.filter { $0.id != station.id }.map { location.distance(from: $0.location) }.min() ?? .infinity
            let arrived = gate.accepts(destinationId: station.id, station: station.location, location: location,
                nearestOtherStationDistance: otherDistance, routeSelectedAt: old.journeySelectedAt ?? old.updatedAt,
                now: now, undergroundDestination: station.supportsUndergroundReturnRecovery,
                arrivalSuppressed: old.blockedArrivalDestinationId != nil)
            onArrivalCheck?(gate)
            if directory == nil {
                SharedWidgetDiagnostics.record("Shared arrival decision", detail: gate.lastDecision,
                    context: .arrival(component: "shared.arrival", route: old, location: location, gate: gate))
            }
            if old.arrivalGate != nil || gate.hasArrivalEvidence { route?.arrivalGate = gate }
            guard arrived else { return }
            let destination = SharedWidgetRouteMemory.returnDestination(arrivingAt: station.id, currentOrigin: old.originId,
                savedOrigin: old.savedOriginId, savedDestination: old.savedDestinationId)
            guard destination != station.id else { return }
            route = Route(originId: station.id, destinationId: destination,
                          savedOriginId: station.id, savedDestinationId: destination,
                          revision: old.revision + 1, updatedAt: now, lastLocationAt: location.timestamp,
                          reason: (gate.usedNearestStationFallback ? JourneyRouteEvent.estimatedArrival : .backgroundArrival).rawValue, manual: false)
        }
    }

    static func resolveWidgetRoute(location: CLLocation?, stations: [Station], now: Date = Date(), directory: URL? = nil,
                                   onArrivalCheck: ((DestinationArrivalGate) -> Void)? = nil,
                                   expectedArrival: Date? = nil) -> Route? {
        let previousRevision = current(directory: directory)?.revision
        guard let resolved = resolve(location: location, stations: stations, now: now, directory: directory,
                                     onArrivalCheck: onArrivalCheck, expectedArrival: expectedArrival) else { return nil }
        // Confirmed arrival or a concurrent selection takes precedence over direction recovery.
        guard resolved.revision == previousRevision else { return resolved }
        return recoverReturnDirection(expectedRevision: resolved.revision, location: location,
            stations: stations, now: now, directory: directory) ?? resolved
    }

    static func observeDeparture(location: CLLocation, stations: [Station], now: Date = Date(), directory: URL? = nil) {
        _ = transaction(directory: directory) { route in
            clearArrivalSuppressionIfDeparted(route: &route, location: location, stations: stations, now: now)
        }
    }

    static func selectedStations(in stations: [Station], directory: URL? = nil) -> (origin: Station, destination: Station)? {
        guard let route = current(directory: directory),
              let origin = stations.first(where: { $0.id == route.originId }),
              let destination = stations.first(where: { $0.id == route.destinationId }),
              origin.id != destination.id else { return nil }
        return (origin, destination)
    }

    private static func clearArrivalSuppressionIfDeparted(route: inout Route?, location: CLLocation?, stations: [Station], now: Date) {
        guard let old = route, let blocked = old.blockedArrivalDestinationId,
              let location, location.timestamp > old.updatedAt,
              old.lastLocationAt.map({ location.timestamp > $0 }) ?? true,
              LocationGuidancePolicy.isUsable(location, maxAge: 30, now: now),
              let station = stations.first(where: { $0.id == blocked }),
              location.distance(from: station.location) - location.horizontalAccuracy > 150 else { return }
        route?.blockedArrivalDestinationId = nil
        route?.lastLocationAt = location.timestamp
    }

    private static func transaction(directory: URL?, change: (inout Route?) -> Void) -> Route? {
        lock.lock()
        defer { lock.unlock() }
        // Never create per-extension fallbacks: they would become competing route authorities.
        var directory = directory
        #if DEBUG && targetEnvironment(simulator)
        // UI tests use a private simulator directory, never the user's shared route.
        if directory == nil, let path = ProcessInfo.processInfo.environment["PATCO_TEST_ROUTE_DIRECTORY"] {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(path)
        }
        #endif
        guard let root = directory ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.rhome.patconext") else {
            SharedRoutePersistence.report(.storageUnavailable)
            return nil
        }
        do {
            do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
            catch { throw SharedRoutePersistence.Failure.storageUnavailable }
            let descriptor = open(root.appendingPathComponent("route.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw SharedRoutePersistence.Failure.lockFailed }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw SharedRoutePersistence.Failure.lockFailed }
            defer { flock(descriptor, LOCK_UN) }
            var route = try SharedRoutePersistence.load(root: root)
            let previous = route
            change(&route)
            JourneyCoordinator.reconcile(previous: previous, next: &route)
            if route != previous, let route {
                try SharedRoutePersistence.save(route, previous: previous, root: root)
                if directory == nil, (route.revision != previous?.revision && route.endsJourneyTracking)
                    || (route.journey?.termination != nil && route.journey?.termination != previous?.journey?.termination) {
                    SharedJourneyTracking.end()
                }
                if directory == nil, route.revision != previous?.revision {
                    ArrivalDiagnostics.record("Route changed", detail:
                        "Revision \(previous?.revision ?? 0) -> \(route.revision); "
                        + "\(previous?.originId ?? "none") to \(previous?.destinationId ?? "none") -> "
                        + "\(route.originId) to \(route.destinationId); reason: \(route.reason); "
                        + "temporary station route: \(route.temporaryRoute != nil)",
                        context: .init(component: "shared.route", journeyID: route.journey?.key ?? previous?.journey?.key,
                            routeRevision: route.revision, decision: .committed))
                }
                if directory == nil, route.revision != previous?.revision
                    || route.blockedArrivalDestinationId != previous?.blockedArrivalDestinationId {
                    SharedWidgetDiagnostics.record("Route decision", detail:
                        "Revision \(route.revision): \(route.originId) to \(route.destinationId); \(route.reason); "
                        + (route.blockedArrivalDestinationId.map { "arrival suppressed at \($0) until departure" }
                            ?? "arrival not suppressed"),
                        context: .init(component: "shared.route", journeyID: route.journey?.key ?? previous?.journey?.key,
                            routeRevision: route.revision, decision: .committed))
                }
            }
            return route
        } catch {
            SharedRoutePersistence.report((error as? SharedRoutePersistence.Failure) ?? .writeFailed)
            return nil
        }
    }
}
