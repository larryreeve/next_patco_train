#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct TripMapFocusCheck {
    static func run() throws {
        let stations = (0..<6).map { index in
            Station(id: "\(index)", code: "\(index)", name: "Stop \(index)",
                    latitude: 40 + Double(index) * 0.01, longitude: -75, zone: "1", url: "")
        }
        for route in [stations, Array(stations.reversed())] {
            XCTAssertTrue(TripMapFocus.stationIndices(stations: route, completedIds: [], position: nil) == [0, 1])
            XCTAssertTrue(TripMapFocus.stationIndices(stations: route, completedIds: [route[2].id], position: nil) == [1, 2, 3])
            XCTAssertTrue(TripMapFocus.stationIndices(stations: route, completedIds: [route[2].id], position: route[1].coordinate) == [1, 2, 3],
                         "An older position cannot move focus behind accepted progress")
            XCTAssertTrue(TripMapFocus.stationIndices(stations: route, completedIds: [route[2].id], position: route[4].coordinate) == [3, 4, 5])
            XCTAssertTrue(TripMapFocus.stationIndices(stations: route, completedIds: [route[5].id], position: nil) == [4, 5])
        }
        XCTAssertTrue(TripMapFocus.stationIndices(stations: [], completedIds: [], position: nil).isEmpty)
        XCTAssertTrue(TripMapFocus.stationIndices(stations: [stations[0]], completedIds: [], position: nil) == [0])
        print("Trip map focus checks passed: both directions, origin, destination, stale position and empty route")
    }
}
