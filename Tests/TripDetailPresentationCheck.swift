#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct TripDetailPresentationCheck {
    static func run() throws {
        let feed = try JSONDecoder().decode(PATCOFeed.self, from: Data(contentsOf:
            URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json")))
        let store = PATCOScheduleStore(feed: feed)
        let day = PATCOClock.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 8))!
        let ashland = store.stations.first { $0.name == "Ashland" }!
        let locust = store.stations.first { $0.name == "15/16th and Locust" }!
        for (origin, destination) in [(ashland, locust), (locust, ashland)] {
            let departure = store.departures(from: origin, to: destination, after: day, limit: 1).first!
            let stops = departure.trip.stopTimes
                .filter { $0.sequence >= departure.originTime.sequence && $0.sequence <= departure.destinationTime.sequence }
                .sorted { $0.sequence < $1.sequence }
                .map { TripDetailStop(station: store.station(for: $0.stopId)!, stopTime: $0) }
            let session = JourneyProgressSession(key: "trip", deepLink:
                "patconext://departure?origin=\(origin.id)&destination=\(destination.id)&departure=\(departure.departureDate.timeIntervalSince1970)",
                originName: origin.name, destinationName: destination.name,
                departure: departure.departureDate, arrival: departure.arrivalDate, stops: [])
            var progress = TripLocationProgress()
            func snapshot(session selected: JourneyProgressSession? = session, key: String = "trip") -> TripDetailPresentation {
                .init(departure: departure, stops: stops, session: selected, tripKey: key, progress: progress)
            }
            let before = departure.departureDate.addingTimeInterval(-60)
            let proposedEstimate = TripLocationProgress.ArrivalEstimate(
                date: departure.arrivalDate.addingTimeInterval(180), basis: "Test", observedAt: before)
            XCTAssertTrue(snapshot().hasTripProgress)
            XCTAssertTrue(snapshot().nextStop(at: before) == nil)
            XCTAssertTrue(snapshot().estimatedArrivalText(for: stops[1], estimate: proposedEstimate, at: before) == nil)
            XCTAssertTrue(snapshot().stopCountTitle(at: before) == "\(stops.count - 1) stops")
            XCTAssertTrue(snapshot().scheduledStops.first?.id == stops[1].id)
            XCTAssertTrue(snapshot().departureTimeText == PATCOClock.timeText(departure.departureDate, relativeTo: departure.arrivalDate))
            XCTAssertTrue(snapshot().arrivalTimeText == PATCOClock.timeText(departure.arrivalDate, relativeTo: departure.departureDate))

            let anchor = stops[1]
            let scheduled = PATCOScheduleStore.scheduleDate(serviceDate: departure.serviceDate,
                timeString: anchor.stopTime.arrival, isSpecialSchedule: departure.isSpecialSchedule)!
            let observed = scheduled.addingTimeInterval(180)
            let fix = CLLocation(coordinate: anchor.station.coordinate, altitude: 0,
                horizontalAccuracy: 5, verticalAccuracy: 1, course: -1, speed: 0, timestamp: observed)
            progress.observe(fix, stations: stops.map(\.station), geometry: nil,
                departure: departure.departureDate, arrival: departure.arrivalDate, now: observed)
            let active = snapshot()
            XCTAssertTrue(active.detectedStationIds.contains(anchor.station.id))
            XCTAssertTrue(active.nextStop(at: observed)?.id == stops[2].id)
            XCTAssertTrue(active.nextStop(at: before) == nil)
            XCTAssertTrue(active.nextStopLabel == "Next stop")
            XCTAssertTrue(active.stopCountTitle(at: observed) == "\(stops.count - 2) stops remaining")
            let estimate = active.destinationEstimate(at: observed)!
            XCTAssertTrue(estimate.date == departure.arrivalDate.addingTimeInterval(180))
            XCTAssertTrue(estimate.delayText(scheduled: departure.arrivalDate) == "3 min late")
            XCTAssertTrue(active.estimatedArrivalText(for: stops.last!, estimate: estimate, at: observed)
                == "Est. arrival \(PATCOClock.timeText(estimate.date, relativeTo: departure.departureDate))")
            XCTAssertTrue(active.timeText(for: anchor, isFinalStop: false) == PATCOClock.timeText(
                PATCOScheduleStore.scheduleDate(serviceDate: departure.serviceDate,
                    timeString: anchor.stopTime.departure, isSpecialSchedule: departure.isSpecialSchedule)!,
                relativeTo: departure.departureDate))
            XCTAssertTrue(active.timeText(for: stops.last!, isFinalStop: true) == active.arrivalTimeText)
            XCTAssertTrue(active.destinationEstimate(at: observed.addingTimeInterval(121)) == nil)
            XCTAssertTrue(active.nextStop(at: observed.addingTimeInterval(121)) == nil)
            XCTAssertTrue(snapshot(session: nil).completedStationIds.isEmpty)
            XCTAssertTrue(snapshot(session: nil).destinationEstimate(at: observed) == nil)
            XCTAssertTrue(snapshot(session: nil).estimatedArrivalText(for: stops.last!, estimate: estimate, at: observed) == nil)
            XCTAssertTrue(!snapshot(key: "other-trip").hasTripProgress)
            XCTAssertTrue(snapshot(key: "other-trip").nextStop(at: observed) == nil)

            let end = CLLocation(coordinate: destination.coordinate, altitude: 0,
                horizontalAccuracy: 5, verticalAccuracy: 1, course: -1, speed: 0, timestamp: estimate.date)
            progress.observe(end, stations: stops.map(\.station), geometry: nil,
                departure: departure.departureDate, arrival: departure.arrivalDate, now: estimate.date)
            XCTAssertTrue(snapshot().nextStop(at: estimate.date) == nil)
            XCTAssertTrue(snapshot().destinationEstimate(at: estimate.date) == nil)
        }
        print("Trip detail presentation checks passed: both directions, pre-trip, schedule preservation, station progress, ETA, stale evidence and trip isolation")
    }
}
