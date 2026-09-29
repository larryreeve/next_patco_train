import Foundation
import CoreLocation

@main
struct DestinationArrivalCheck {
    static func main() {
        precondition(!JourneyTrackingPolicy.shouldBegin(atOrigin: true, arrivalSuppressed: true, departedArrivalStation: false, explicitTrip: false))
        precondition(JourneyTrackingPolicy.shouldBegin(atOrigin: true, arrivalSuppressed: true, departedArrivalStation: false, explicitTrip: true))
        precondition(JourneyTrackingPolicy.shouldBegin(atOrigin: false, arrivalSuppressed: false, departedArrivalStation: true, explicitTrip: false))
        precondition(JourneyTrackingPolicy.shouldBegin(atOrigin: true, arrivalSuppressed: false, departedArrivalStation: false, explicitTrip: false))
        precondition(!JourneyTrackingPolicy.shouldBegin(atOrigin: false, arrivalSuppressed: false, departedArrivalStation: false, explicitTrip: false))
        precondition(SharedWidgetRouteMemory.returnDestination(arrivingAt: "B", currentOrigin: "intermediate", savedOrigin: "A", savedDestination: "B") == "A")
        precondition(SharedWidgetRouteMemory.returnDestination(arrivingAt: "A", currentOrigin: "intermediate", savedOrigin: "A", savedDestination: "B") == "B")
        precondition(SharedWidgetRouteMemory.returnDestination(arrivingAt: "C", currentOrigin: "A", savedOrigin: nil, savedDestination: nil) == "A")
        let now = Date()
        precondition(!ScheduledTripExpiration.hasExpired(arrivalDate: now, now: now))
        precondition(!ScheduledTripExpiration.hasExpired(arrivalDate: now, now: now.addingTimeInterval(599)))
        precondition(ScheduledTripExpiration.hasExpired(arrivalDate: now, now: now.addingTimeInterval(600)))
        precondition(ScheduledTripExpiration.hasExpired(arrivalDate: now, now: now.addingTimeInterval(7200)))
        let station = CLLocation(latitude: 39.95, longitude: -75.16)
        func fix(_ seconds: Double, accuracy: Double = 20, latitude: Double = 39.95) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -75.16),
                       altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 1,
                       timestamp: now.addingTimeInterval(seconds))
        }
        var gate = DestinationArrivalGate()
        precondition(LocationGuidancePolicy.isUsable(fix(0), now: now))
        precondition(LocationGuidancePolicy.isUsable(fix(-120), now: now))
        precondition(!LocationGuidancePolicy.isUsable(fix(-121), now: now))
        precondition(!LocationGuidancePolicy.isUsable(fix(1), now: now))
        precondition(!LocationGuidancePolicy.isUsable(fix(0, accuracy: -1), now: now))
        precondition(!LocationGuidancePolicy.isUsable(fix(0, accuracy: 0), now: now))
        precondition(!LocationGuidancePolicy.isUsable(fix(0, accuracy: 151), now: now))
        precondition(LocationGuidancePolicy.isAtStation(fix(-30), station: station, now: now))
        precondition(!LocationGuidancePolicy.isAtStation(fix(-31), station: station, now: now))
        precondition(!LocationGuidancePolicy.isAtStation(fix(0, accuracy: 100, latitude: 39.9506), station: station, now: now))
        gate.prepareSelection(destinationId: "original", station: station, location: fix(0))
        precondition(!gate.accepts(destinationId: "original", station: station, location: fix(0), now: now))
        gate.observeDeparture(from: station, location: fix(1, latitude: 39.96), now: now.addingTimeInterval(1))
        precondition(gate.accepts(destinationId: "original", station: station, location: fix(2), now: now.addingTimeInterval(2)))
        for destination in ["changed1", "changed2", "original"] {
            gate.prepareSelection(destinationId: destination, station: station, location: fix(0, latitude: 39.96))
            precondition(gate.accepts(destinationId: destination, station: station, location: fix(0), now: now))
        }
        gate = DestinationArrivalGate()
        precondition(!gate.accepts(destinationId: "original", station: station, location: fix(0, accuracy: 100), now: now))
        precondition(!gate.accepts(destinationId: "original", station: station, location: fix(0, accuracy: 100), now: now.addingTimeInterval(10)))
        precondition(gate.accepts(destinationId: "original", station: station, location: fix(10, accuracy: 100), now: now.addingTimeInterval(10)))
        precondition(!gate.accepts(destinationId: "original", station: station, location: fix(-60), now: now))
        print("Destination arrival checks passed")
    }
}
