#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct WalkingRouteDistanceCheck {
    static func run() throws {
        let defaults = UserDefaults(suiteName: "group.com.rhome.patconext")!
        let key = "stickyReachabilityMode"
        let previous = defaults.data(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let now = Date()
        let store = PATCOScheduleStore(feed: try JSONDecoder().decode(PATCOFeed.self,
            from: Data(contentsOf: URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json"))))
        let origin = store.stations.first!
        func estimate(_ distance: Double?, minutes: Int = 20, age: Double = 0) -> SharedTravelTimeEstimateCache.Estimate {
            .init(originId: origin.id, sourceLatitude: 39.9, sourceLongitude: -75,
                  minutes: minutes, fetchedAt: now.addingTimeInterval(-age), routeDistanceMeters: distance)
        }
        func resolve(_ route: SharedTravelTimeEstimateCache.Estimate?, direct: Double = 900, departure: Int = 30) -> SharedReachabilityModeStore.Mode? {
            SharedReachabilityModeStore.resolve(originId: origin.id, distanceToStation: direct,
                minutesUntilDeparture: departure, walkingEstimate: route, now: now)
        }
        defaults.removeObject(forKey: key)
        XCTAssertTrue(resolve(nil) == .walking)
        XCTAssertTrue(resolve(estimate(2400)) == .driving, "A long walking detour must correct the provisional mode")
        XCTAssertTrue(resolve(nil) == .driving, "Temporary routing loss must not flip the mode")
        defaults.removeObject(forKey: key)
        XCTAssertTrue(resolve(nil, direct: 1500, departure: 15) == .driving)
        XCTAssertTrue(resolve(estimate(1600, minutes: 12), direct: 1500, departure: 15) == .walking,
                     "Use Maps time, including the station buffer, in the middle band")
        XCTAssertTrue(resolve(estimate(1600, minutes: 12), direct: 1500, departure: 2) == .walking,
                     "Countdown changes must not switch an established mode")
        SharedReachabilityModeStore.save(mode: .walking, originId: origin.id)
        XCTAssertTrue(SharedReachabilityModeStore.isManual(originId: origin.id))
        XCTAssertTrue(SharedReachabilityModeStore.shouldRequestWalkingEstimate(distance: 3000, originId: origin.id))
        XCTAssertTrue(resolve(estimate(3000)) == .walking, "Manual selection wins")
        XCTAssertTrue(resolve(estimate(3000), direct: 100) == nil, "Arrival still uses geographic distance")
        SharedReachabilityModeStore.useAutomatic(originId: origin.id)
        XCTAssertTrue(!SharedReachabilityModeStore.isManual(originId: origin.id))
        XCTAssertTrue(!SharedReachabilityModeStore.shouldRequestWalkingEstimate(distance: 3000, originId: origin.id))
        XCTAssertTrue(resolve(estimate(3000)) == .driving, "Reset must discard the manual override")
        defaults.removeObject(forKey: key)
        XCTAssertTrue(resolve(estimate(2400, age: 301)) == .walking, "Expired route must not choose mode")
        defaults.removeObject(forKey: key)
        XCTAssertTrue(resolve(estimate(nil)) == .walking, "Legacy time-only cache remains supported")
        let encoded = try JSONEncoder().encode(estimate(2400))
        let decoded = try JSONDecoder().decode(SharedTravelTimeEstimateCache.Estimate.self, from: encoded)
        XCTAssertTrue(decoded.routeDistanceMeters == 2400)
        let legacy = try JSONEncoder().encode(estimate(nil))
        let decodedLegacy = try JSONDecoder().decode(SharedTravelTimeEstimateCache.Estimate.self, from: legacy)
        XCTAssertTrue(decodedLegacy.routeDistanceMeters == nil)
        print("Walking route distance checks passed")
    }
}
