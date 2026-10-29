import CoreLocation
import XCTest
@testable import PATCOLogic

@MainActor
final class JourneyWorkflowTests: XCTestCase {
    private final class Progress: JourneyProgressRecording {
        var session: JourneyProgressSession?
        var readings: [CLLocation] = []
        var completions: [String] = []
        func record(_ location: CLLocation, stations: [Station]) { readings.append(location) }
        func complete(arrivingAt name: String) { completions.append(name) }
    }

    func testBrowsingDoesNotLoseJourneyArrivalOrPublishTodayPresentation() throws {
        let feedURL = TestPaths.repository.appendingPathComponent("NextPATCOTrain/Resources/patco_schedule.json")
        let store = PATCOScheduleStore(feed: try JSONDecoder().decode(PATCOFeed.self, from: Data(contentsOf: feedURL)))
        let origin = try XCTUnwrap(store.stations.first { $0.name == "Ashland" })
        let destination = try XCTUnwrap(store.stations.first { $0.name == "Woodcrest" })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = LocationTestEnvironment()
        environment.now = Date()
        let progress = Progress()
        let selected = try XCTUnwrap(SharedRouteCoordinator.commit(originId: origin.id, destinationId: destination.id,
            manual: true, now: environment.now.addingTimeInterval(-60), directory: root))
        let session = JourneyProgressSession(key: "browsing-trip",
            deepLink: "patconext://departure?origin=\(origin.id)&destination=\(destination.id)&departure=\(environment.now.timeIntervalSince1970)",
            originName: origin.name, destinationName: destination.name,
            departure: environment.now.addingTimeInterval(-60), arrival: environment.now, stops: [])
        _ = SharedRouteCoordinator.beginJourney(session, expectedRevision: selected.revision, now: environment.now, directory: root)
        progress.session = session
        environment.session = session
        let provider = environment.provider()
        provider.beginJourneyTracking()
        var effects: [String] = []
        var snapshots: [Int] = []
        let workflow = JourneyLocationWorkflow(progress: progress, locationProvider: provider, store: store,
            directory: root, now: { environment.now },
            endActivities: { effects.append("end:\($0)") }, reloadWidgets: { _ in effects.append("reload") },
            publishSnapshot: { route, _, _ in snapshots.append(route.revision); effects.append("publish") })
        func fix(accuracy: Double = 5) -> CLLocation {
            CLLocation(coordinate: destination.coordinate, altitude: 0, horizontalAccuracy: accuracy,
                verticalAccuracy: 1, course: 0, speed: 0, timestamp: environment.now)
        }
        XCTAssertTrue(workflow.receive(fix(), isViewingToday: true, displayedRevision: selected.revision))
        XCTAssertEqual(progress.readings.count, 1)
        XCTAssertTrue(effects.isEmpty, "Today's presentation remains owned by the route controller")
        XCTAssertFalse(workflow.receive(nil, isViewingToday: false, displayedRevision: selected.revision))
        XCTAssertTrue(effects.isEmpty, "Signal loss must not complete the trip")
        for _ in 0..<7 {
            environment.now += 1
            XCTAssertFalse(workflow.receive(fix(), isViewingToday: false, displayedRevision: selected.revision))
        }
        let arrived = try XCTUnwrap(SharedRouteCoordinator.current(directory: root))
        XCTAssertEqual(arrived.journey?.state, .arrived)
        XCTAssertEqual(progress.completions, [destination.name])
        XCTAssertEqual(effects, ["end:\(destination.name)", "publish", "reload"])
        XCTAssertEqual(snapshots, [arrived.revision])
        XCTAssertNil(provider.journeyTrackingDeadline)
        progress.session = arrived.journey
        XCTAssertFalse(workflow.receive(fix(), isViewingToday: false, displayedRevision: arrived.revision))
        XCTAssertEqual(progress.completions.count, 1, "A completed route must not repeat arrival effects")
    }

    func testBrowsingWithoutActiveJourneyDoesNotChangeRoute() throws {
        let feedURL = TestPaths.repository.appendingPathComponent("NextPATCOTrain/Resources/patco_schedule.json")
        let store = PATCOScheduleStore(feed: try JSONDecoder().decode(PATCOFeed.self, from: Data(contentsOf: feedURL)))
        let environment = LocationTestEnvironment()
        let progress = Progress()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let route = try XCTUnwrap(SharedRouteCoordinator.commit(originId: store.stations[0].id,
            destinationId: store.stations[1].id, manual: true, directory: root))
        let workflow = JourneyLocationWorkflow(progress: progress, locationProvider: environment.provider(),
            store: store, directory: root, endActivities: { _ in XCTFail("No active journey") },
            reloadWidgets: { _ in XCTFail("No route change") }, publishSnapshot: { _, _, _ in XCTFail("No route change") })
        XCTAssertFalse(workflow.receive(environment.fix(), isViewingToday: false, displayedRevision: route.revision))
        XCTAssertEqual(SharedRouteCoordinator.current(directory: root), route)
        XCTAssertEqual(progress.readings.count, 1)
    }
}
