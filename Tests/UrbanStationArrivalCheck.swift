#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct UrbanStationArrivalCheck {
    static func run() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(UrbanStationArrivalPolicy.radius(accuracy: 51) == 100)
        XCTAssertTrue(UrbanStationArrivalPolicy.radius(accuracy: 80) == 120)
        XCTAssertTrue(UrbanStationArrivalPolicy.radius(accuracy: 1414) == 150)
        XCTAssertTrue(!UrbanStationArrivalPolicy.isNearScheduledArrival(base, now: base.addingTimeInterval(-181)))
        XCTAssertTrue(!UrbanStationArrivalPolicy.isNearScheduledArrival(base, now: base.addingTimeInterval(601)))
        func fix(_ seconds: Double, latitude: Double, accuracy: Double, speed: Double = -1) -> CLLocation {
            CLLocation(coordinate: .init(latitude: latitude, longitude: -75), altitude: 0,
                       horizontalAccuracy: accuracy, verticalAccuracy: 1, course: -1, speed: speed,
                       timestamp: base.addingTimeInterval(seconds))
        }
        for code in ["8", "9", "10", "11", "12", "13", "14"] {
            let stations = [Station(id: "2", code: "2", name: "Origin", latitude: 39.99, longitude: -75, zone: "1", url: ""),
                            Station(id: code, code: code, name: "Urban", latitude: 40, longitude: -75, zone: "6", url: ""),
                            Station(id: "end", code: "1", name: "Destination", latitude: 40.01, longitude: -75, zone: "1", url: "")]
            for scenario in ["valid", "future", "fast", "outside", "no timing", "no progress", "duplicate", "too soon", "gap", "two readings"] {
                var progress = TripLocationProgress()
                func observe(_ reading: CLLocation) {
                    progress.observe(reading, stations: stations, geometry: nil, departure: base,
                        arrival: base.addingTimeInterval(1000), now: reading.timestamp,
                        stationArrivals: scenario == "no timing" ? [:] : [code: base.addingTimeInterval(scenario == "future" ? 600 : 100)])
                }
                if scenario != "no progress" { observe(fix(1, latitude: 39.99, accuracy: 10, speed: 0)) }
                let latitude = scenario == "outside" ? 40.002 : 40.0003
                let speed = scenario == "fast" ? 10.0 : -1.0
                observe(fix(100, latitude: latitude, accuracy: 1414, speed: speed))
                XCTAssertTrue(!progress.detectedStationIds.contains(code))
                if scenario != "two readings" {
                    observe(fix(scenario == "duplicate" ? 100 : 102, latitude: latitude, accuracy: 1414, speed: speed))
                }
                XCTAssertTrue(progress.inferredStationIds?.contains(code) != true, "Must wait for distinct fixes spanning at least five seconds")
                progress = try JSONDecoder().decode(TripLocationProgress.self, from: JSONEncoder().encode(progress))
                let finalTime = scenario == "duplicate" ? 100.0 : scenario == "too soon" ? 104 : scenario == "gap" ? 148 : 105
                observe(fix(finalTime, latitude: latitude, accuracy: 1414, speed: speed))
                XCTAssertTrue(!progress.detectedStationIds.contains(code))
                XCTAssertTrue((progress.inferredStationIds?.contains(code) == true) == (scenario == "valid" || scenario == "two readings"), "\(code): \(scenario)")
                XCTAssertTrue(progress.latitude == nil, "Poor fixes must not move the train marker")
            }
            var destinationProgress = TripLocationProgress()
            for seconds in [1.0, 100.0, 102.0, 105.0, 109.0, 110.0] {
                let reading = seconds == 1 ? fix(seconds, latitude: 39.99, accuracy: 10, speed: 0)
                    : fix(seconds, latitude: 40.0003, accuracy: 1414)
                destinationProgress.observe(reading, stations: Array(stations.prefix(2)), geometry: nil,
                    departure: base, arrival: base.addingTimeInterval(1000), now: reading.timestamp,
                    stationArrivals: [code: base.addingTimeInterval(100)])
                XCTAssertTrue((destinationProgress.inferredStationIds?.contains(code) == true) == (seconds == 110),
                             "The destination stop must retain the longer ten-second window")
            }
        }
        for offset in [0.0, 1000.0, -1000.0] {
            var gate = DestinationArrivalGate()
            let origin = CLLocation(latitude: 39.9, longitude: -75)
            let destination = CLLocation(latitude: 40, longitude: -75)
            for reading in [fix(1, latitude: 39.91, accuracy: 10), fix(60, latitude: 39.98, accuracy: 10)] {
                gate.observeJourney(origin: origin, destination: destination, location: reading,
                                    selectedAt: base, now: reading.timestamp)
            }
            gate.expectedArrival = base.addingTimeInterval(130 + offset)
            for seconds in [100.0, 105.0, 109.0, 110.0] {
                let reading = fix(seconds, latitude: 40.0003, accuracy: 1414)
                let accepted = gate.accepts(destinationId: "11", station: destination, location: reading,
                    nearestOtherStationDistance: 500, routeSelectedAt: base, now: reading.timestamp,
                    undergroundDestination: true)
                XCTAssertTrue(accepted == (seconds == 110 && offset == 0), "Destination schedule window and ten-second confirmation")
            }
        }
        print("Urban station arrival checks passed")
    }
}
