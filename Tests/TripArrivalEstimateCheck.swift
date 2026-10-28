import Foundation
import CoreLocation

@main
struct TripArrivalEstimateCheck {
    static func main() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let stations = [39.9, 39.91, 39.92].enumerated().map { index, latitude in
            Station(id: "\(index)", code: "\(index)", name: "Station \(index)", latitude: latitude,
                    longitude: -75, zone: "1", url: "")
        }
        let geometry = PATCOTrackGeometry(shapes: [[[39.9, -75], [39.91, -75], [39.92, -75]]])
        func reading(_ seconds: Double, latitude: Double) -> CLLocation {
            CLLocation(coordinate: .init(latitude: latitude, longitude: -75), altitude: 0,
                horizontalAccuracy: 5, verticalAccuracy: 1, course: -1, speed: -1,
                timestamp: base.addingTimeInterval(seconds))
        }
        for ordered in [stations, Array(stations.reversed())] {
            let schedule = Dictionary(uniqueKeysWithValues: ordered.enumerated().map {
                ($0.element.id, base.addingTimeInterval(Double($0.offset) * 300))
            })
            var progress = TripLocationProgress()
            let midpoint = (ordered[0].latitude + ordered[1].latitude) / 2
            let fix = reading(390, latitude: midpoint)
            progress.observe(fix, stations: ordered, geometry: geometry, departure: base,
                             arrival: base.addingTimeInterval(600), now: fix.timestamp)
            let estimate = progress.arrivalEstimate(stations: ordered, scheduled: schedule, geometry: geometry, now: fix.timestamp)!
            precondition(abs(estimate.date.timeIntervalSince(base) - 840) < 1)
            precondition(estimate.delayText(scheduled: base.addingTimeInterval(600)) == "4 min late")
            precondition(estimate.basis == "Based on current location")
            precondition(progress.arrivalEstimate(stations: ordered, scheduled: schedule, geometry: geometry,
                now: base.addingTimeInterval(406)) == nil, "Stale GPS without a station anchor must use the schedule")

            let stationFix = reading(540, latitude: ordered[1].latitude)
            progress.observe(stationFix, stations: ordered, geometry: geometry, departure: base,
                arrival: base.addingTimeInterval(600), now: stationFix.timestamp)
            progress = try JSONDecoder().decode(TripLocationProgress.self, from: JSONEncoder().encode(progress))
            let stationEstimate = progress.arrivalEstimate(stations: ordered, scheduled: schedule, geometry: geometry,
                now: base.addingTimeInterval(570))!
            precondition(stationEstimate.basis == "Based on Station 1")
            precondition(abs(stationEstimate.date.timeIntervalSince(base) - 840) < 1)
            precondition(progress.arrivalEstimate(stations: ordered, scheduled: schedule, geometry: geometry,
                now: base.addingTimeInterval(661)) == nil)
            precondition(progress.arrivalEstimate(stations: ordered, scheduled: schedule, geometry: geometry,
                now: base.addingTimeInterval(-1)) == nil)
            let destinationFix = reading(840, latitude: ordered[2].latitude)
            progress.observe(destinationFix, stations: ordered, geometry: geometry, departure: base,
                arrival: base.addingTimeInterval(600), now: destinationFix.timestamp)
            precondition(progress.arrivalEstimate(stations: ordered, scheduled: schedule, geometry: geometry,
                now: destinationFix.timestamp) == nil, "Completed destination must not show a future ETA")
        }
        let empty = TripLocationProgress()
        let stopEstimate = TripLocationProgress.ArrivalEstimate(date: base.addingTimeInterval(840),
            basis: "Test", observedAt: base.addingTimeInterval(390))
        for stopSeconds in [300.0, 450, 600] {
            precondition(stopEstimate.arrival(at: base.addingTimeInterval(stopSeconds),
                scheduledDestination: base.addingTimeInterval(600), now: base.addingTimeInterval(390))
                == base.addingTimeInterval(stopSeconds + 240), "Every remaining stop shares the destination delay")
        }
        precondition(stopEstimate.arrival(at: base.addingTimeInterval(100),
            scheduledDestination: base.addingTimeInterval(600), now: base.addingTimeInterval(390)) == nil,
            "Never display a past arrival as an upcoming ETA")
        precondition(stopEstimate.arrival(at: base.addingTimeInterval(601),
            scheduledDestination: base.addingTimeInterval(600), now: base) == nil)
        let detail = try String(contentsOfFile: "NextPATCOTrain/DepartureDetailView.swift", encoding: .utf8)
        let summary = detail.components(separatedBy: "private var tripSummary: some View")[1]
            .components(separatedBy: "private func destinationEstimate")[0]
        precondition(summary.contains("DisclosureGroup {"), "Secondary trip information starts collapsed")
        precondition(summary.contains("Fares & accessibility"))
        precondition(summary.contains("Station accessibility and live elevator status aren't available in the app."))
        precondition(summary.contains("stationAccessibility(departure.origin, role: \"Departure\")"))
        precondition(summary.contains("stationAccessibility(departure.destination, role: \"Destination\")"))
        precondition(!summary.contains("Station accessibility not verified"))
        precondition(summary.contains("stationInformationRow(station, role: role, canOpen: true)"))
        precondition(summary.contains(".contentShape(Rectangle())"))
        precondition(!summary.contains("wheelchairAccessibleText"), "Trip accessibility must not be presented as station accessibility")
        precondition(!summary.contains("LazyVGrid"), "Keep secondary information compact")
        precondition(detail.contains("estimatedArrivalText: completedStationIds.contains(stop.station.id) ? nil"))
        precondition(detail.contains("\"Scheduled arrival\" : \"Scheduled departure\""))
        precondition(!detail.contains("Est. arrival unavailable"), "Report unavailable location once, not per stop")
        precondition(detail.contains("let index = stops.lastIndex(where: { completedStationIds.contains($0.station.id) })"),
                     "Next stop requires observed journey progress")
        precondition(detail.contains("index + 1 < stops.count else { return nil }"), "No next stop after the destination")
        precondition(detail.contains(".accessibilityHint(\"Opens station information\")"))
        precondition(detail.contains("Text(isDetected ? \"Passed\" : \"Passed · estimated\")"))
        precondition(detail.contains("geometry.size.height - 22"), "Route connectors follow the full row height")
        precondition(detail.contains("timeline.date.timeIntervalSince(estimate.observedAt)"),
                     "Freshness describes the observation behind the estimate, not the redraw time")
        precondition(detail.contains("isInferred ? Color.patcoWine.opacity(0.25) : Color.white"),
                     "Inferred passed stations have a visible fill")
        precondition(detail.contains("lineCap: .round, dash: isInferred ? [1, 3] : []"),
                     "Inferred passed stations retain a dotted outline")
        precondition(detail.contains("adjustmentText == \"On time\" ? \"checkmark.circle\" : \"clock\""))
        precondition(detail.contains("guard date >= departure.departureDate, hasTripProgress,"),
                     "Do not show unavailable stop estimates before departure or for an untracked trip")
        precondition(detail.contains("estimate: TripLocationProgress.ArrivalEstimate?, at date: Date) -> String?"),
                     "Stop estimate lines can be hidden when the trip has not started")
        precondition(detail.contains("let value = isFinalStop ? stop.stopTime.arrival : stop.stopTime.departure"),
                     "Keep each intermediate stop's scheduled departure time")
        precondition(empty.arrivalEstimate(stations: stations, scheduled: [:], geometry: geometry, now: base) == nil)
        let legacy = try JSONDecoder().decode(TripLocationProgress.self, from: Data("{\"detectedStationIds\":[],\"lastStationIndex\":-1}".utf8))
        precondition(legacy.arrivalAnchorAt == nil)
        let parser = ISO8601DateFormatter()
        for (scheduledText, estimatedText, expected) in [
            ("2026-10-22T18:04:05-04:00", "2026-10-22T18:07:45-04:00", "3 min late"),
            ("2026-10-22T18:04:59-04:00", "2026-10-22T18:05:01-04:00", "1 min late"),
            ("2026-10-22T18:04:01-04:00", "2026-10-22T18:04:59-04:00", "On time"),
            ("2026-10-22T18:07:45-04:00", "2026-10-22T18:04:05-04:00", "3 min early"),
            ("2026-10-22T23:59:50-04:00", "2026-10-23T00:02:01-04:00", "3 min late"),
            ("2026-10-23T00:02:01-04:00", "2026-10-22T23:59:50-04:00", "3 min early")
        ] {
            let scheduled = parser.date(from: scheduledText)!
            let estimated = parser.date(from: estimatedText)!
            let result = TripLocationProgress.ArrivalEstimate(date: estimated, basis: "Test", observedAt: base)
            precondition(result.delayText(scheduled: scheduled) == expected,
                         "Delay label must agree with the displayed minute-level times")
            precondition(result.date == estimated, "Display rounding must not change the underlying ETA")
        }
        print("Trip arrival estimate checks passed: both directions, scheduled interpolation, delay, station fallback, expiry, completion and persistence")
    }
}
