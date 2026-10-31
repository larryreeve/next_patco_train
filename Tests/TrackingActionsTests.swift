import Foundation
import XCTest
@testable import PATCOLogic

@MainActor
final class TrackingActionsTests: XCTestCase {
    private func fixture() throws -> (URL, SharedRouteCoordinator.Route) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let route = try XCTUnwrap(SharedRouteCoordinator.commit(originId: "2", destinationId: "3", manual: true, now: now, directory: root))
        let session = JourneyProgressSession(key: "trip", deepLink: "patconext://departure?origin=2&destination=3&departure=\(now.timeIntervalSince1970)",
            originName: "Ashland", destinationName: "Woodcrest", departure: now,
            arrival: now.addingTimeInterval(600), stops: [])
        let started = try XCTUnwrap(SharedRouteCoordinator.beginJourney(session,
            expectedRevision: route.revision, now: now, directory: root))
        XCTAssertEqual(started.journey?.key, "trip")
        return (root, started)
    }

    func testCancellationCommitsBeforeEffectsAndNotifiesAfterActivityEnds() async throws {
        let (root, _) = try fixture()
        var events: [String] = []
        let actions = TrackingActions(current: { SharedRouteCoordinator.current(directory: root) },
            cancelJourney: { SharedRouteCoordinator.cancelJourney(key: $0, directory: root) },
            confirmArrival: { _, _, _ in XCTFail("Unexpected arrival"); return nil },
            synchronize: {
                XCTAssertEqual(SharedRouteCoordinator.current(directory: root)?.journey?.state, .cancelled)
                events.append("sync")
            }, stopLocation: { reload in XCTAssertTrue(reload); events.append("location") },
            endActivity: { key in XCTAssertEqual(key, "trip"); events.append("activity") },
            changed: { events.append("notify") })
        let cancelled = await actions.cancel(key: "trip")
        XCTAssertTrue(cancelled)
        XCTAssertEqual(events, ["sync", "location", "activity", "notify"])
        events.removeAll()
        let rejected = await actions.cancel(key: "other-trip")
        XCTAssertFalse(rejected)
        XCTAssertTrue(events.isEmpty, "A mismatched trip cannot trigger effects")
    }

    func testArrivalSynchronizesProvidedDependencyOnlyAfterCommit() throws {
        let (root, route) = try fixture()
        var effects: [String] = []
        var synchronized: SharedRouteCoordinator.Route?
        let actions = TrackingActions(current: { SharedRouteCoordinator.current(directory: root) },
            cancelJourney: { _ in XCTFail("Unexpected cancellation"); return nil },
            confirmArrival: { SharedRouteCoordinator.confirmTripArrival(originId: $0, destinationId: $1,
                expectedRevision: $2, directory: root) },
            synchronize: { synchronized = SharedRouteCoordinator.current(directory: root); effects.append("sync") },
            stopLocation: { reload in XCTAssertFalse(reload); effects.append("location") },
            endActivity: { _ in XCTFail("Arrival has a separate display effect") }, changed: {})
        let arrived = try XCTUnwrap(actions.arrive(originId: "2", destinationId: "3"))
        XCTAssertEqual(arrived.revision, route.revision + 1)
        XCTAssertEqual(synchronized?.journey?.state, .arrived)
        XCTAssertEqual(effects, ["sync", "location"])
        effects.removeAll()
        XCTAssertNil(actions.arrive(originId: "2", destinationId: "3"))
        XCTAssertTrue(effects.isEmpty, "Repeated arrival cannot reapply effects")
    }

    func testRejectedArrivalHasNoEffects() throws {
        let (_, route) = try fixture()
        let actions = TrackingActions(current: { route }, cancelJourney: { _ in nil },
            confirmArrival: { _, _, _ in route }, synchronize: { XCTFail("No commit") },
            stopLocation: { _ in XCTFail("No commit") }, endActivity: { _ in }, changed: {})
        XCTAssertNil(actions.arrive(originId: "2", destinationId: "3"))
    }

    func testDisplayRequestFailurePreservesPreviousDisplay() async {
        enum Failure: Error { case unavailable }
        var ended: [String] = []
        do {
            _ = try await TrackingDisplayReplacement.replace(previous: ["old"],
                request: { throw Failure.unavailable }, accept: { _ in XCTFail("Request failed"); return false },
                end: { ended.append($0) })
            XCTFail("Expected failure")
        } catch {}
        XCTAssertTrue(ended.isEmpty)
    }

    func testRejectedDisplayEndsOnlyReplacement() async throws {
        var ended: [String] = []
        let result = try await TrackingDisplayReplacement.replace(previous: ["old"],
            request: { "new" }, accept: { _ in false }, end: { ended.append($0) })
        XCTAssertNil(result)
        XCTAssertEqual(ended, ["new"])
    }

    func testAcceptedDisplayCommitsBeforeRemovingPreviousDisplays() async throws {
        var events: [String] = []
        let result = try await TrackingDisplayReplacement.replace(previous: ["old", "older"],
            request: { events.append("request"); return "new" },
            accept: { _ in events.append("commit"); return true }, end: { events.append("end:\($0)") })
        XCTAssertEqual(result, "new")
        XCTAssertEqual(events, ["request", "commit", "end:old", "end:older"])
    }
}
