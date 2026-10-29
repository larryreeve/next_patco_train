#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct LocationBoundaryCheck {
    static func run() {
        let locale = Locale(identifier: "en_US")
        XCTAssertTrue(LocationDiagnosticFormatting.speedInMPH(0, locale: locale) == "0.0 mph")
        XCTAssertTrue(LocationDiagnosticFormatting.speedInMPH(0.44704, locale: locale) == "1.0 mph")
        XCTAssertTrue(LocationDiagnosticFormatting.speedInMPH(26.8224, locale: locale) == "60.0 mph")
        for invalid in [-1.0, Double.nan, .infinity, -.infinity] {
            XCTAssertTrue(LocationDiagnosticFormatting.speedInMPH(invalid) == "Unavailable")
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let station = CLLocation(latitude: 39.95, longitude: -75.16)
        func location(meters: Double = 0, accuracy: Double = 20, age: Double = 0) -> CLLocation {
            var low = 39.95, high = 40.0
            for _ in 0..<60 {
                let mid = (low + high) / 2
                if CLLocation(latitude: mid, longitude: -75.16).distance(from: station) < meters { low = mid } else { high = mid }
            }
            return CLLocation(coordinate: .init(latitude: (low + high) / 2, longitude: -75.16), altitude: 0,
                horizontalAccuracy: accuracy, verticalAccuracy: 1, course: 0, speed: 0, timestamp: now.addingTimeInterval(-age))
        }
        for (age, valid) in [(30.0, true), (30.001, false), (-0.001, false)] {
            XCTAssertTrue(LocationGuidancePolicy.isUsable(location(age: age), maxAge: 30, now: now) == valid)
        }
        for (accuracy, valid) in [(0.0, false), (150.0, true), (150.001, false), (-1.0, false), (.infinity, false), (.nan, false)] {
            XCTAssertTrue(LocationGuidancePolicy.isUsable(location(accuracy: accuracy), now: now) == valid)
        }
        XCTAssertTrue(LocationGuidancePolicy.isAtStation(location(meters: 129.99), station: station, now: now))
        XCTAssertTrue(!LocationGuidancePolicy.isAtStation(location(meters: 130.01), station: station, now: now))
        XCTAssertTrue(!LocationGuidancePolicy.hasLeftStation(location(meters: 169.99), station: station, now: now))
        XCTAssertTrue(LocationGuidancePolicy.hasLeftStation(location(meters: 170.01), station: station, now: now))
        for (distance, expected) in [(75.0 - 0.01, false), (75.0 + 0.01, true)] {
            let other = location(meters: distance)
            let stations = [Station(id: "A", code: "A", name: "A", latitude: 39.95, longitude: -75.16, zone: "1", url: ""),
                Station(id: "B", code: "B", name: "B", latitude: other.coordinate.latitude, longitude: -75.16, zone: "1", url: "")]
            XCTAssertTrue((LocationGuidancePolicy.nearestUnambiguousStation(location(), stations: stations, now: now) != nil) == expected)
        }
        for (distance, expected) in [(103.99, false), (104.01, true)] {
            let other = location(meters: distance)
            let stations = [Station(id: "A", code: "A", name: "A", latitude: 39.95, longitude: -75.16, zone: "1", url: ""),
                Station(id: "B", code: "B", name: "B", latitude: other.coordinate.latitude, longitude: -75.16, zone: "1", url: "")]
            XCTAssertTrue((LocationGuidancePolicy.nearestUnambiguousStation(location(accuracy: 52),
                stations: stations, now: now) != nil) == expected)
        }
        for (distance, expected) in [(129.99, true), (130.01, false)] {
            var gate = DestinationArrivalGate()
            XCTAssertTrue(!gate.accepts(destinationId: "B", station: station, location: location(meters: distance), now: now))
            XCTAssertTrue(gate.accepts(destinationId: "B", station: station, location: location(meters: distance, age: -10), now: now.addingTimeInterval(10)) == expected)
        }
        for (age, expected) in [(15.0, true), (15.001, false), (-0.001, false)] {
            var gate = DestinationArrivalGate()
            XCTAssertTrue(!gate.accepts(destinationId: "B", station: station, location: location(age: age), now: now))
            XCTAssertTrue(gate.hasStopEvidence == expected)
        }
        for (accuracy, expected) in [(50.0, true), (50.001, false)] {
            var gate = DestinationArrivalGate()
            XCTAssertTrue(!gate.accepts(destinationId: "B", station: station,
                location: location(accuracy: accuracy), now: now))
            XCTAssertTrue(gate.hasStopEvidence == expected)
        }
        var uncertain = DestinationArrivalGate()
        XCTAssertTrue(!uncertain.accepts(destinationId: "B", station: station, location: location(accuracy: 100), now: now))
        XCTAssertTrue(!uncertain.accepts(destinationId: "B", station: station, location: location(accuracy: 100, age: -9.999), now: now.addingTimeInterval(9.999)))
        XCTAssertTrue(!uncertain.accepts(destinationId: "B", station: station, location: location(accuracy: 100, age: -10), now: now.addingTimeInterval(10)))
        for distance in [899.99, 900.01] {
            var gate = DestinationArrivalGate()
            let origin = location(meters: 3000)
            gate.observeJourney(origin: origin, destination: station, location: location(meters: 3000, age: 50),
                selectedAt: now.addingTimeInterval(-60), now: now.addingTimeInterval(-50))
            gate.observeJourney(origin: origin, destination: station, location: location(meters: 1500, age: 10),
                selectedAt: now.addingTimeInterval(-60), now: now.addingTimeInterval(-10))
            XCTAssertTrue(!gate.accepts(destinationId: "B", station: station, location: location(accuracy: 1414),
                routeSelectedAt: now.addingTimeInterval(-60), now: now))
            XCTAssertTrue(!gate.accepts(destinationId: "B", station: station, location: location(meters: distance, age: -10),
                routeSelectedAt: now.addingTimeInterval(-60), now: now.addingTimeInterval(10)))
        }
        for elapsed in [9.999, 10.0, 1800.0, 1800.001] {
            var gate = DestinationArrivalGate()
            let origin = location(meters: 3000)
            let selectedAt = now.addingTimeInterval(-60)
            gate.observeJourney(origin: origin, destination: station, location: location(meters: 3000, age: 50),
                selectedAt: selectedAt, now: now.addingTimeInterval(-50))
            gate.observeJourney(origin: origin, destination: station, location: location(meters: 1500, age: 10),
                selectedAt: selectedAt, now: now.addingTimeInterval(-10))
            XCTAssertTrue(!gate.accepts(destinationId: "B", station: station, location: location(accuracy: 1414),
                routeSelectedAt: selectedAt, now: now))
            if elapsed > 1000 {
                gate.observeJourney(origin: origin, destination: station, location: location(meters: 1500, age: -1790),
                    selectedAt: selectedAt, now: now.addingTimeInterval(1790))
            }
            XCTAssertTrue(!gate.accepts(destinationId: "B", station: station, location: location(meters: 620, age: -elapsed),
                routeSelectedAt: selectedAt, now: now.addingTimeInterval(elapsed)))
        }
        XCTAssertTrue(LocationGuidancePolicy.shouldSuppressArrival(location: location(meters: 169.99), station: station, now: now))
        XCTAssertTrue(!LocationGuidancePolicy.shouldSuppressArrival(location: location(meters: 170.01), station: station, now: now))
        print("Location boundary checks passed: freshness, accuracy, footprint, ambiguity, arrival, fallback and suppression")
    }
}
