#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation

struct JourneyCoordinatorCheck {
    static func run() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func session(_ key: String = "first") -> JourneyProgressSession {
            JourneyProgressSession(key: key, deepLink: "patconext://departure?origin=A&destination=B&departure=1800000000",
                originName: "A", destinationName: "B", departure: now, arrival: now.addingTimeInterval(600), stops: [])
        }
        // Every terminal state is absorbing: late callbacks cannot arrive a cancelled trip or cancel an arrival.
        for event in [JourneyCoordinator.Event.arrive, .cancel, .expire] {
            var value = session()
            JourneyCoordinator.transition(&value, event: event)
            let terminal = value
            for next in [JourneyCoordinator.Event.arrive, .cancel, .expire] {
                JourneyCoordinator.transition(&value, event: next)
                XCTAssertTrue(value == terminal)
            }
            XCTAssertTrue(!value.isActive(at: now))
            let encoded = try JSONEncoder().encode(value)
            XCTAssertTrue(tryDecode(encoded) == value)
            var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            legacy.removeValue(forKey: "state")
            let legacyData = try JSONSerialization.data(withJSONObject: legacy)
            XCTAssertTrue(tryDecode(legacyData) == value, "Old saved trip must restore identically")
        }
        var original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session())) as! [String: Any]
        original.removeValue(forKey: "state")
        original.removeValue(forKey: "termination")
        original.removeValue(forKey: "completed")
        let originalData = try JSONSerialization.data(withJSONObject: original)
        XCTAssertTrue(tryDecode(originalData).state == .tracking)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = SharedRouteCoordinator.commit(originId: "A", destinationId: "B", now: now, directory: root)!
        let started = SharedRouteCoordinator.beginJourney(session(), expectedRevision: initial.revision, now: now, directory: root)!
        XCTAssertTrue(started.journey?.state == .tracking)
        let cancelled = SharedRouteCoordinator.cancelJourney(key: "first", directory: root)!
        XCTAssertTrue(cancelled.journey?.state == .cancelled)
        let passive = SharedRouteCoordinator.beginJourney(session("second"), expectedRevision: initial.revision, now: now, directory: root)!
        XCTAssertTrue(passive.journey == cancelled.journey)
        let restarted = SharedRouteCoordinator.beginJourney(session("second"), expectedRevision: initial.revision,
            now: now, directory: root, explicitRestart: true)!
        XCTAssertTrue(restarted.journey?.key == "second" && restarted.journey?.state == .tracking)
        let staleCancel = SharedRouteCoordinator.cancelJourney(key: "first", directory: root)!
        XCTAssertTrue(staleCancel.journey == restarted.journey)
        let expired = SharedRouteCoordinator.expireJourney(now: now.addingTimeInterval(1200), directory: root)!
        XCTAssertTrue(expired.journey?.state == .expired)
        XCTAssertTrue(SharedRouteCoordinator.current(directory: root)?.journey == expired.journey)
        print("Journey coordinator checks passed: terminal transitions, legacy migration, restoration, explicit restart, stale cancellation")
    }

    static func tryDecode(_ data: Data) -> JourneyProgressSession {
        try! JSONDecoder().decode(JourneyProgressSession.self, from: data)
    }
}
