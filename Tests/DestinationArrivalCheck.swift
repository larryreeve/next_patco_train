#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct DestinationArrivalCheck {
    static func run() {
        XCTAssertTrue(!JourneyTrackingPolicy.shouldBegin(atOrigin: true, arrivalSuppressed: true, departedArrivalStation: false, explicitTrip: false))
        XCTAssertTrue(JourneyTrackingPolicy.shouldBegin(atOrigin: true, arrivalSuppressed: true, departedArrivalStation: false, explicitTrip: true))
        XCTAssertTrue(JourneyTrackingPolicy.shouldBegin(atOrigin: false, arrivalSuppressed: false, departedArrivalStation: true, explicitTrip: false))
        XCTAssertTrue(JourneyTrackingPolicy.shouldBegin(atOrigin: true, arrivalSuppressed: false, departedArrivalStation: false, explicitTrip: false))
        XCTAssertTrue(!JourneyTrackingPolicy.shouldBegin(atOrigin: false, arrivalSuppressed: false, departedArrivalStation: false, explicitTrip: false))
        XCTAssertTrue(SharedWidgetRouteMemory.returnDestination(arrivingAt: "B", currentOrigin: "intermediate", savedOrigin: "A", savedDestination: "B") == "A")
        XCTAssertTrue(SharedWidgetRouteMemory.returnDestination(arrivingAt: "A", currentOrigin: "intermediate", savedOrigin: "A", savedDestination: "B") == "B")
        XCTAssertTrue(SharedWidgetRouteMemory.returnDestination(arrivingAt: "C", currentOrigin: "A", savedOrigin: nil, savedDestination: nil) == "A")
        let now = Date()
        XCTAssertTrue(!ScheduledTripExpiration.hasExpired(arrivalDate: now, now: now))
        XCTAssertTrue(!ScheduledTripExpiration.hasExpired(arrivalDate: now, now: now.addingTimeInterval(599)))
        XCTAssertTrue(ScheduledTripExpiration.hasExpired(arrivalDate: now, now: now.addingTimeInterval(600)))
        XCTAssertTrue(ScheduledTripExpiration.hasExpired(arrivalDate: now, now: now.addingTimeInterval(7200)))
        let station = CLLocation(latitude: 39.95, longitude: -75.16)
        func fix(_ seconds: Double, accuracy: Double = 20, latitude: Double = 39.95) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -75.16),
                       altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 1, course: 0, speed: 0,
                       timestamp: now.addingTimeInterval(seconds))
        }
        let routeSelectedAt = now.addingTimeInterval(-60)
        var missedArrival = DestinationArrivalGate()
        let tripOrigin = CLLocation(latitude: 39.98, longitude: -75.16)
        missedArrival.observeJourney(origin: tripOrigin, destination: station,
            location: fix(-50, latitude: 39.98), selectedAt: routeSelectedAt, now: now.addingTimeInterval(-50))
        missedArrival.observeJourney(origin: tripOrigin, destination: station,
            location: fix(-10, latitude: 39.965), selectedAt: routeSelectedAt, now: now.addingTimeInterval(-10))
        let undergroundFix = fix(0, accuracy: 1414, latitude: 39.9503)
        let walkedAwayFix = fix(900, accuracy: 52, latitude: 39.9556)
        XCTAssertTrue(!missedArrival.accepts(destinationId: "B", station: station, location: undergroundFix,
            nearestOtherStationDistance: 480, routeSelectedAt: routeSelectedAt, now: now))
        XCTAssertTrue(!missedArrival.accepts(destinationId: "B", station: station, location: walkedAwayFix,
            nearestOtherStationDistance: 1000, routeSelectedAt: routeSelectedAt, now: now.addingTimeInterval(1000)))
        XCTAssertTrue(!missedArrival.accepts(destinationId: "B", station: station, location: walkedAwayFix,
            nearestOtherStationDistance: 1000, routeSelectedAt: routeSelectedAt, now: now.addingTimeInterval(900)))
        XCTAssertTrue(!missedArrival.usedNearestStationFallback)
        var noStationEvidence = DestinationArrivalGate()
        XCTAssertTrue(!noStationEvidence.accepts(destinationId: "B", station: station, location: walkedAwayFix,
            nearestOtherStationDistance: 1000, routeSelectedAt: routeSelectedAt, now: now.addingTimeInterval(900)))
        for rejected in [fix(900, accuracy: 570, latitude: 39.9556), fix(900, accuracy: 52, latitude: 39.96)] {
            XCTAssertTrue(!missedArrival.accepts(destinationId: "B", station: station, location: rejected,
                nearestOtherStationDistance: 2000, routeSelectedAt: routeSelectedAt, now: now.addingTimeInterval(900)))
        }
        XCTAssertTrue(!missedArrival.accepts(destinationId: "B", station: station, location: walkedAwayFix,
            nearestOtherStationDistance: 650, routeSelectedAt: routeSelectedAt, now: now.addingTimeInterval(900)))
        XCTAssertTrue(!missedArrival.accepts(destinationId: "B", station: station, location: walkedAwayFix,
            nearestOtherStationDistance: 1000, routeSelectedAt: now.addingTimeInterval(1), now: now.addingTimeInterval(900)))
        let expiredEvidenceFix = fix(1900, accuracy: 52, latitude: 39.9556)
        XCTAssertTrue(!missedArrival.accepts(destinationId: "B", station: station, location: expiredEvidenceFix,
            nearestOtherStationDistance: 1000, routeSelectedAt: routeSelectedAt, now: now.addingTimeInterval(1900)))
        missedArrival.resetEvidence()
        XCTAssertTrue(!missedArrival.accepts(destinationId: "B", station: station, location: walkedAwayFix,
            nearestOtherStationDistance: 1000, routeSelectedAt: routeSelectedAt, now: now.addingTimeInterval(900)))
        var gate = DestinationArrivalGate()
        XCTAssertTrue(LocationGuidancePolicy.isUsable(fix(0), now: now))
        XCTAssertTrue(LocationGuidancePolicy.isUsable(fix(-120), now: now))
        XCTAssertTrue(!LocationGuidancePolicy.isUsable(fix(-121), now: now))
        XCTAssertTrue(!LocationGuidancePolicy.isUsable(fix(1), now: now))
        XCTAssertTrue(!LocationGuidancePolicy.isUsable(fix(0, accuracy: -1), now: now))
        XCTAssertTrue(!LocationGuidancePolicy.isUsable(fix(0, accuracy: 0), now: now))
        XCTAssertTrue(!LocationGuidancePolicy.isUsable(fix(0, accuracy: 151), now: now))
        XCTAssertTrue(LocationGuidancePolicy.isAtStation(fix(-30), station: station, now: now))
        XCTAssertTrue(!LocationGuidancePolicy.isAtStation(fix(-31), station: station, now: now))
        XCTAssertTrue(!LocationGuidancePolicy.isAtStation(fix(0, accuracy: 100, latitude: 39.9506), station: station, now: now))
        let platformEnd = fix(0, accuracy: 20, latitude: 39.952)
        XCTAssertTrue(!LocationGuidancePolicy.isAtStation(platformEnd, station: station, now: now))
        XCTAssertTrue(LocationGuidancePolicy.hasLeftStation(platformEnd, station: station, now: now))
        XCTAssertTrue(!LocationGuidancePolicy.isAtStation(fix(0, accuracy: 100, latitude: 39.952), station: station, now: now))
        let boundaryReading = fix(0, accuracy: 40, latitude: 39.9513)
        XCTAssertTrue(!LocationGuidancePolicy.isAtStation(boundaryReading, station: station, now: now))
        XCTAssertTrue(!LocationGuidancePolicy.hasLeftStation(boundaryReading, station: station, now: now))
        XCTAssertTrue(LocationGuidancePolicy.hasLeftStation(fix(0, accuracy: 20, latitude: 39.954), station: station, now: now))
        XCTAssertTrue(!gate.accepts(destinationId: "platform", station: station, location: platformEnd, now: now))
        gate.prepareSelection(destinationId: "original", station: station, location: fix(0))
        XCTAssertTrue(!gate.accepts(destinationId: "original", station: station, location: fix(0), now: now))
        gate.observeDeparture(from: station, location: fix(1, latitude: 39.96), now: now.addingTimeInterval(1))
        XCTAssertTrue(!gate.accepts(destinationId: "original", station: station, location: fix(2), now: now.addingTimeInterval(2)))
        XCTAssertTrue(gate.accepts(destinationId: "original", station: station, location: fix(12), now: now.addingTimeInterval(12)))
        for destination in ["changed1", "changed2", "original"] {
            gate.prepareSelection(destinationId: destination, station: station, location: fix(0, latitude: 39.96))
            XCTAssertTrue(!gate.accepts(destinationId: destination, station: station, location: fix(0), now: now))
            XCTAssertTrue(gate.accepts(destinationId: destination, station: station, location: fix(10), now: now.addingTimeInterval(10)))
        }
        gate = DestinationArrivalGate()
        XCTAssertTrue(!gate.accepts(destinationId: "original", station: station, location: fix(0, accuracy: 100), now: now))
        XCTAssertTrue(!gate.accepts(destinationId: "original", station: station, location: fix(0, accuracy: 100), now: now.addingTimeInterval(10)))
        XCTAssertTrue(!gate.accepts(destinationId: "original", station: station, location: fix(10, accuracy: 100), now: now.addingTimeInterval(10)))
        XCTAssertTrue(!gate.accepts(destinationId: "original", station: station, location: fix(-61), now: now))
        gate = DestinationArrivalGate()
        XCTAssertTrue(!gate.accepts(destinationId: "underground", station: station, location: fix(0, accuracy: 220), nearestOtherStationDistance: 270, now: now))
        XCTAssertTrue(!gate.accepts(destinationId: "underground", station: station, location: fix(0, accuracy: 220), nearestOtherStationDistance: 270, now: now.addingTimeInterval(20)))
        XCTAssertTrue(!gate.accepts(destinationId: "underground", station: station, location: fix(20, accuracy: 220), nearestOtherStationDistance: 270, now: now.addingTimeInterval(20)))
        XCTAssertTrue(!gate.accepts(destinationId: "underground", station: station, location: fix(25, accuracy: 301), now: now.addingTimeInterval(25)))
        XCTAssertTrue(!gate.accepts(destinationId: "underground", station: station, location: fix(30, accuracy: 220), nearestOtherStationDistance: 60, now: now.addingTimeInterval(30)))
        XCTAssertTrue(!gate.accepts(destinationId: "underground", station: station, location: fix(40, accuracy: 220), nearestOtherStationDistance: 270, now: now.addingTimeInterval(40)))
        gate.resetEvidence()
        XCTAssertTrue(!gate.accepts(destinationId: "underground", station: station, location: fix(50, accuracy: 220), now: now.addingTimeInterval(50)))
        XCTAssertTrue(!gate.accepts(destinationId: "underground", station: station, location: fix(111, accuracy: 220), now: now.addingTimeInterval(111)))
        XCTAssertTrue(!gate.accepts(destinationId: "underground", station: station, location: fix(125, accuracy: 220), now: now.addingTimeInterval(125)))
        gate = DestinationArrivalGate()
        XCTAssertTrue(!gate.accepts(destinationId: "A", station: station, location: fix(0, accuracy: 220), now: now))
        XCTAssertTrue(!gate.accepts(destinationId: "B", station: station, location: fix(12, accuracy: 220), now: now.addingTimeInterval(12)))
        XCTAssertTrue(!gate.accepts(destinationId: "B", station: station, location: fix(24, accuracy: 220), now: now.addingTimeInterval(24)))
        print("Destination arrival checks passed")
    }
}
