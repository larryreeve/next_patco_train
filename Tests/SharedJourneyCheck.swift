import Foundation
import CoreLocation

@main
struct SharedJourneyCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stations = ["A", "C", "B"].enumerated().map { index, id in
            Station(id: id, code: id, name: id, latitude: 40 - Double(index) * 0.01,
                    longitude: -75, zone: "1", url: "")
        }
        let session = JourneyProgressSession(key: "first", deepLink: "patconext://departure?origin=A&destination=B&departure=1800000000",
            originName: "A", destinationName: "B", departure: now, arrival: now.addingTimeInterval(600),
            stops: [.init(name: "C", arrival: now.addingTimeInterval(300)), .init(name: "B", arrival: now.addingTimeInterval(600))])
        for ending in ["arrival", "reverse", "selection", "expire"] {
            let directory = root.appendingPathComponent(ending)
            var route = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true, now: now, directory: directory)!
            route = SharedRouteCoordinator.beginJourney(session, expectedRevision: route.revision, now: now, directory: directory)!
            precondition(route.journey == session)
            var progress = TripLocationProgress()
            progress.detectedStationIds = ["A"]
            _ = SharedRouteCoordinator.saveJourneyProgress(progress, key: session.key, now: now, directory: directory)
            route = SharedRouteCoordinator.selectStationDepartures(expectedRevision: route.revision, originId: "C", destinationId: "B",
                stations: stations, automatic: true, now: now.addingTimeInterval(1), directory: directory)!
            precondition(route.journey == session && route.journeyProgress == progress)
            route = SharedRouteCoordinator.restoreStationRoute(expectedRevision: route.revision,
                now: now.addingTimeInterval(2), directory: directory)!
            precondition(route.journey == session)
            let oldRevision = route.revision
            switch ending {
            case "arrival":
                route = SharedRouteCoordinator.destinationRegionEntered(stationId: "B", expectedRevision: oldRevision,
                    stations: stations, now: now.addingTimeInterval(600), directory: directory)!
                precondition(route.journey?.completed == true && route.journey?.termination == .arrived)
                precondition(route.originId == "B" && route.destinationId == "A")
            case "reverse":
                route = SharedRouteCoordinator.reverse(expectedRevision: oldRevision, now: now.addingTimeInterval(3), directory: directory)!
                precondition(route.journey?.termination == .cancelled && route.journey?.completed == false)
            case "selection":
                route = SharedRouteCoordinator.commit(originId: "C", destinationId: "A", manual: true,
                    now: now.addingTimeInterval(3), directory: directory)!
                precondition(route.journey?.termination == .cancelled)
            default:
                route = SharedRouteCoordinator.expireJourney(now: now.addingTimeInterval(1200), directory: directory)!
                precondition(route.journey?.termination == .expired && route.revision == oldRevision)
            }
            precondition(route.journeyProgress == progress, "Terminal transitions retain displayable progress")
            var late = progress
            late.detectedStationIds.insert("B")
            _ = SharedRouteCoordinator.saveJourneyProgress(late, key: session.key, now: now, directory: directory)
            _ = SharedRouteCoordinator.beginJourney(session, expectedRevision: oldRevision, now: now, directory: directory)
            precondition(SharedRouteCoordinator.current(directory: directory) == route,
                         "Late callbacks must not revive or overwrite a finished journey")
            let decoded = try JSONDecoder().decode(SharedRouteCoordinator.Route.self, from: JSONEncoder().encode(route))
            precondition(decoded == route)
        }
        let boarding = root.appendingPathComponent("boarding")
        _ = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true, now: now, directory: boarding)
        _ = SharedRouteCoordinator.selectStationDepartures(expectedRevision: 1, originId: "C", destinationId: "B",
            stations: stations, now: now, directory: boarding)
        let intermediateTrip = JourneyProgressSession(key: "boarding", deepLink: "patconext://departure?origin=C&destination=B&departure=1800000000",
            originName: "C", destinationName: "B", departure: now, arrival: now.addingTimeInterval(600), stops: [])
        let started = SharedRouteCoordinator.beginJourney(intermediateTrip, expectedRevision: 2, now: now, directory: boarding)!
        precondition(started.journey == intermediateTrip, "A trip may start at the displayed intermediate station")
        let finished = SharedRouteCoordinator.confirmTripArrival(originId: "C", destinationId: "B", expectedRevision: 2,
            now: now.addingTimeInterval(600), directory: boarding)!
        precondition(finished.journey?.termination == .arrived && finished.destinationId == "C")
        // Old installations have no shared session fields.
        let legacy = SharedRouteCoordinator.Route(originId: "A", destinationId: "B", savedOriginId: "A",
            savedDestinationId: "B", revision: 1, updatedAt: now, reason: "Background arrival", manual: false)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        object.removeValue(forKey: "journey")
        object.removeValue(forKey: "journeyProgress")
        let decoded = try JSONDecoder().decode(SharedRouteCoordinator.Route.self, from: JSONSerialization.data(withJSONObject: object))
        precondition(decoded.event == .backgroundArrival && decoded.journey == nil)
        print("Shared journey checks passed: temporary browsing, arrival, cancellation, expiry, stale callbacks, persistence and legacy migration")
    }
}
