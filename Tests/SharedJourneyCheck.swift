#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct SharedJourneyCheck {
    static func run() throws {
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
            XCTAssertTrue(route.journey == session)
            var progress = TripLocationProgress()
            progress.detectedStationIds = ["A"]
            _ = SharedRouteCoordinator.saveJourneyProgress(progress, key: session.key, now: now, directory: directory)
            route = SharedRouteCoordinator.selectStationDepartures(expectedRevision: route.revision, originId: "C", destinationId: "B",
                stations: stations, automatic: true, now: now.addingTimeInterval(1), directory: directory)!
            XCTAssertTrue(route.journey == session && route.journeyProgress == progress)
            route = SharedRouteCoordinator.restoreStationRoute(expectedRevision: route.revision,
                now: now.addingTimeInterval(2), directory: directory)!
            XCTAssertTrue(route.journey == session)
            let oldRevision = route.revision
            switch ending {
            case "arrival":
                route = SharedRouteCoordinator.destinationRegionEntered(stationId: "B", expectedRevision: oldRevision,
                    stations: stations, now: now.addingTimeInterval(600), directory: directory)!
                XCTAssertTrue(route.journey?.completed == true && route.journey?.termination == .arrived)
                XCTAssertTrue(route.originId == "B" && route.destinationId == "A")
            case "reverse":
                route = SharedRouteCoordinator.reverse(expectedRevision: oldRevision, now: now.addingTimeInterval(3), directory: directory)!
                XCTAssertTrue(route.journey?.termination == .cancelled && route.journey?.completed == false)
            case "selection":
                route = SharedRouteCoordinator.commit(originId: "C", destinationId: "A", manual: true,
                    now: now.addingTimeInterval(3), directory: directory)!
                XCTAssertTrue(route.journey?.termination == .cancelled)
            default:
                route = SharedRouteCoordinator.expireJourney(now: now.addingTimeInterval(1200), directory: directory)!
                XCTAssertTrue(route.journey?.termination == .expired && route.revision == oldRevision)
            }
            XCTAssertTrue(route.journeyProgress == progress, "Terminal transitions retain displayable progress")
            var late = progress
            late.detectedStationIds.insert("B")
            _ = SharedRouteCoordinator.saveJourneyProgress(late, key: session.key, now: now, directory: directory)
            _ = SharedRouteCoordinator.beginJourney(session, expectedRevision: oldRevision, now: now, directory: directory)
            XCTAssertTrue(SharedRouteCoordinator.current(directory: directory) == route,
                         "Late callbacks must not revive or overwrite a finished journey")
            let decoded = try JSONDecoder().decode(SharedRouteCoordinator.Route.self, from: JSONEncoder().encode(route))
            XCTAssertTrue(decoded == route)
        }
        let boarding = root.appendingPathComponent("boarding")
        let cancellation = root.appendingPathComponent("explicit-cancellation")
        _ = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true, now: now, directory: cancellation)
        let tracked = SharedRouteCoordinator.beginJourney(session, expectedRevision: 1, now: now.addingTimeInterval(60), directory: cancellation)!
        XCTAssertTrue(tracked.journey == session, "Late boarding can start tracking after scheduled departure")
        let wrongKey = SharedRouteCoordinator.cancelJourney(key: "obsolete", directory: cancellation)!
        XCTAssertTrue(wrongKey == tracked, "An obsolete screen cannot cancel another trip")
        let cancelled = SharedRouteCoordinator.cancelJourney(key: session.key, directory: cancellation)!
        XCTAssertTrue(cancelled.originId == "A" && cancelled.destinationId == "B" && cancelled.revision == tracked.revision)
        XCTAssertTrue(cancelled.journey?.termination == .cancelled && cancelled.journey?.completed == false)
        XCTAssertTrue(cancelled.journey?.suppressesAutomaticTracking(originId: "A", destinationId: "B", at: now) == true)
        XCTAssertTrue(cancelled.journey?.suppressesAutomaticTracking(originId: "B", destinationId: "A", at: now) == false)
        XCTAssertTrue(cancelled.journey?.suppressesAutomaticTracking(originId: "A", destinationId: "B", at: now.addingTimeInterval(1200)) == false)
        let retry = JourneyProgressSession(key: "restart", deepLink: session.deepLink,
            originName: session.originName, destinationName: session.destinationName,
            departure: session.departure, arrival: session.arrival, stops: session.stops)
        let passive = SharedRouteCoordinator.beginJourney(retry, expectedRevision: 1, now: now, directory: cancellation)!
        XCTAssertTrue(passive.journey?.termination == .cancelled, "Callbacks must not restart cancelled tracking")
        let restarted = SharedRouteCoordinator.beginJourney(retry, expectedRevision: 1, now: now, directory: cancellation, explicitRestart: true)!
        XCTAssertTrue(restarted.journey == retry, "An explicit user action can restart cancelled tracking")
        _ = SharedRouteCoordinator.confirmTripArrival(originId: "A", destinationId: "B", expectedRevision: 1,
            now: now.addingTimeInterval(600), directory: cancellation)
        let afterArrival = SharedRouteCoordinator.cancelJourney(key: retry.key, directory: cancellation)!
        XCTAssertTrue(afterArrival.journey?.completed == true, "Cancellation cannot overwrite arrival")
        _ = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", manual: true, now: now, directory: boarding)
        _ = SharedRouteCoordinator.selectStationDepartures(expectedRevision: 1, originId: "C", destinationId: "B",
            stations: stations, now: now, directory: boarding)
        let intermediateTrip = JourneyProgressSession(key: "boarding", deepLink: "patconext://departure?origin=C&destination=B&departure=1800000000",
            originName: "C", destinationName: "B", departure: now, arrival: now.addingTimeInterval(600), stops: [])
        let started = SharedRouteCoordinator.beginJourney(intermediateTrip, expectedRevision: 2, now: now, directory: boarding)!
        XCTAssertTrue(started.journey == intermediateTrip, "A trip may start at the displayed intermediate station")
        let finished = SharedRouteCoordinator.confirmTripArrival(originId: "C", destinationId: "B", expectedRevision: 2,
            now: now.addingTimeInterval(600), directory: boarding)!
        XCTAssertTrue(finished.journey?.termination == .arrived && finished.destinationId == "C")
        // Old installations have no shared session fields.
        let legacy = SharedRouteCoordinator.Route(originId: "A", destinationId: "B", savedOriginId: "A",
            savedDestinationId: "B", revision: 1, updatedAt: now, reason: "Background arrival", manual: false)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        object.removeValue(forKey: "journey")
        object.removeValue(forKey: "journeyProgress")
        let decoded = try JSONDecoder().decode(SharedRouteCoordinator.Route.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.event == .backgroundArrival && decoded.journey == nil)
        print("Shared journey checks passed: temporary browsing, arrival, cancellation, expiry, stale callbacks, persistence and legacy migration")
    }
}
