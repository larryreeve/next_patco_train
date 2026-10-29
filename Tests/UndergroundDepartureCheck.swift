#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct UndergroundDepartureCheck {
    static func run() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var evidence = UndergroundDepartureEvidence()
        func sample(_ t: Double, station: String = "B", reliable: Bool = false,
                    distance: Double = 30, other: Double = 500, active: Bool = true,
                    wall: Double? = nil, route: [String] = ["A", "B", "C", "D"]) -> String? {
            let location = CLLocation(coordinate: .init(latitude: 39.95, longitude: -75.16),
                altitude: 0, horizontalAccuracy: reliable ? 10 : 1414, verticalAccuracy: -1,
                timestamp: base.addingTimeInterval(t))
            return evidence.observe(route: route, stationId: station, reliable: reliable,
                underground: true, distance: distance, otherDistance: other, location: location,
                journeyActive: active, now: base.addingTimeInterval(wall ?? t))
        }
        for t in [0.0, 5, 10] { XCTAssertTrue(sample(t) == nil, "Requires reliable journey anchor") }
        XCTAssertTrue(sample(11, station: "A", reliable: true) == nil)
        XCTAssertTrue(sample(12) == nil)
        for _ in 0..<10 { XCTAssertTrue(sample(12) == nil, "Duplicates cannot build evidence") }
        XCTAssertTrue(sample(17) == nil)
        XCTAssertTrue(sample(22) == "B")
        XCTAssertTrue(sample(23, station: "A") == nil, "Cannot move backward")
        XCTAssertTrue(sample(24, station: "C") == nil)
        XCTAssertTrue(sample(29, station: "C") == nil)
        XCTAssertTrue(sample(34, station: "C") == "C")
        for t in [35.0, 40, 45] { XCTAssertTrue(sample(t, station: "D") == nil, "Never infer destination arrival") }
        for t in [46.0, 51, 56] { XCTAssertTrue(sample(t, station: "C", distance: 500) == nil) }
        for t in [57.0, 62, 67] { XCTAssertTrue(sample(t, station: "C", other: 60) == nil) }
        for t in [68.0, 73, 78] { XCTAssertTrue(sample(t, station: "C", active: false) == nil) }
        XCTAssertTrue(sample(79, station: "C", wall: 100) == nil, "Stale readings rejected")
        XCTAssertTrue(sample(101, station: "C", wall: 100) == nil, "Future readings rejected")
        XCTAssertTrue(sample(102, station: "C") == nil)
        XCTAssertTrue(sample(107, station: "C") == nil)
        XCTAssertTrue(sample(160, station: "C") == nil, "Long gaps reset evidence")
        XCTAssertTrue(sample(161, station: "C", route: ["D", "C", "B", "A"]) == nil)
        XCTAssertTrue(sample(166, station: "C", route: ["D", "C", "B", "A"]) == nil)
        XCTAssertTrue(sample(171, station: "C", route: ["D", "C", "B", "A"]) == nil, "New route needs new anchor")
        print("Underground departure checks passed")
    }
}
