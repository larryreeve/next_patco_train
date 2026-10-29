#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct TripProgressCheck {
    static func run() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stations = (0...3).map { i in
            Station(id: String(i), code: String(i), name: "Station \(i)", latitude: 39.95 + Double(i) * 0.01,
                    longitude: -75.16, zone: "6", url: "")
        }
        let geometry = PATCOTrackGeometry(shapes: [stations.map { [$0.latitude, $0.longitude] }])
        var progress = TripLocationProgress()
        func feed(_ index: Int, time: Double, accuracy: Double = 10, age: Double = 0, longitude: Double = -75.16) {
            let location = CLLocation(coordinate: .init(latitude: stations[index].latitude, longitude: longitude),
                altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 1, course: 0, speed: 10,
                timestamp: now.addingTimeInterval(time - age))
            progress.observe(location, stations: stations, geometry: geometry, departure: now,
                             arrival: now.addingTimeInterval(600), now: now.addingTimeInterval(time))
        }
        feed(0, time: -1)
        XCTAssertTrue(progress.positionAt == nil && progress.detectedStationIds.isEmpty)
        feed(0, time: 0)
        XCTAssertTrue(progress.detectedStationIds == ["0"] && progress.latitude == stations[0].latitude)
        feed(1, time: 30)
        XCTAssertTrue(progress.detectedStationIds == ["0", "1"])
        let saved = progress
        feed(0, time: 40)
        XCTAssertTrue(progress.detectedStationIds == saved.detectedStationIds && progress.latitude == saved.latitude)
        feed(2, time: 45, accuracy: 1414)
        feed(2, time: 46, age: 20)
        feed(2, time: 47, age: -1)
        feed(2, time: 30)
        XCTAssertTrue(!progress.detectedStationIds.contains("2") && progress.latitude == saved.latitude)
        feed(2, time: 50, longitude: -75.15)
        XCTAssertTrue(progress.latitude == saved.latitude, "Off-track positions cannot move the marker")
        feed(3, time: 60)
        XCTAssertTrue(progress.detectedStationIds == ["0", "1", "3"], "Do not fill missed stations by assumption")
        XCTAssertTrue(progress.completedStationIds == ["0", "1", "2", "3"])
        XCTAssertTrue(progress.inferredStationIds == ["2"], "Keep inferred passage separate from detection")
        let restored = try JSONDecoder().decode(TripLocationProgress.self, from: JSONEncoder().encode(progress))
        XCTAssertTrue(restored == progress)
        let route = geometry.route(from: stations[3].location, to: stations[1].location)
        XCTAssertTrue(route.first?.latitude == stations[3].latitude && route.last?.latitude == stations[1].latitude)
        print("Trip progress checks passed")
    }
}
