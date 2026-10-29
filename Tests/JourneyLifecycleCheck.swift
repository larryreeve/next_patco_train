#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation

struct JourneyLifecycleCheck {
    static func run() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var session = JourneyProgressSession(key: "trip", deepLink: "patconext://departure",
            originName: "Origin", destinationName: "Destination", departure: now,
            arrival: now.addingTimeInterval(600), stops: [.init(name: "Destination", arrival: now.addingTimeInterval(600))])
        let restored = try JSONDecoder().decode(JourneyProgressSession.self, from: JSONEncoder().encode(session))
        XCTAssertTrue(restored == session && restored.isActive(at: now))
        XCTAssertTrue(!restored.isActive(at: now.addingTimeInterval(1200)))
        JourneyCoordinator.transition(&session, event: .arrive)
        XCTAssertTrue(!session.isActive(at: now))
        for reason in ["Background arrival", "Estimated arrival", "App arrival", "User confirmed arrival"] {
            let route = SharedRouteCoordinator.Route(originId: "B", destinationId: "A",
                savedOriginId: "B", savedDestinationId: "A", revision: 2, updatedAt: now, reason: reason, manual: false)
            XCTAssertTrue(route.completesJourney && route.endsJourneyTracking)
        }
        print("Journey lifecycle checks passed: persisted session, expiry and completion policy")
    }
}
