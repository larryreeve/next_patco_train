#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct PresentationRefreshCheck {
    static func run() throws {
        let locale = Locale(identifier: "en_US")
        let originalZone = NSTimeZone.default
        defer { NSTimeZone.default = originalZone }
        let iso = ISO8601DateFormatter()
        let winter = iso.date(from: "2026-01-15T13:46:00Z")!
        let summer = iso.date(from: "2026-07-15T12:46:00Z")!
        let information = try String(contentsOfFile: "NextPATCOTrain/InformationViews.swift", encoding: .utf8)
        let validitySection = information.components(separatedBy: "private var scheduleFeedIsExpired: Bool")[1]
            .components(separatedBy: "private var scheduleFeedUpdateText")[0]
        XCTAssertTrue(!validitySection.contains("Calendar.current"))
        XCTAssertTrue(validitySection.contains("PATCOClock.calendar.date(byAdding: .day, value: 1"))
        XCTAssertTrue(validitySection.contains("Date.FormatStyle(timeZone: PATCOClock.calendar.timeZone)"))
        for zone in ["America/Los_Angeles", "Asia/Tokyo", "Europe/London"] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            for (startText, endText, expectedDate) in [
                ("2026-11-01T04:00:00Z", "2026-11-02T05:00:00Z", "11/1/2026"),
                ("2026-03-08T05:00:00Z", "2026-03-09T04:00:00Z", "3/8/2026")
            ] {
                let endDate = iso.date(from: startText)!
                let expiration = PATCOClock.calendar.date(byAdding: .day, value: 1, to: endDate)!
                XCTAssertTrue(expiration == iso.date(from: endText)!)
                let label = endDate.formatted(Date.FormatStyle(locale: locale, timeZone: PATCOClock.calendar.timeZone)
                    .month(.defaultDigits).day(.defaultDigits).year())
                XCTAssertTrue(label == expectedDate, "Wrong schedule validity date in \(zone): \(label)")
            }
            for date in [winter, summer] {
                let text = PATCOClock.timeText(date, locale: locale)
                XCTAssertTrue(text.contains("8:46") && text.contains("AM"), text)
            }
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json"))
        let store = PATCOScheduleStore(feed: try JSONDecoder().decode(PATCOFeed.self, from: data))
        let origin = store.stations.first { $0.name == "Ashland" }!
        let destination = store.stations.first { $0.name == "15/16th and Locust" }!
        let start = PATCOClock.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!
        let departure = store.departures(from: origin, to: destination, after: start, limit: 1).first!
        let now = departure.departureDate.addingTimeInterval(-10 * 60)
        let snapshot = SharedTripState.Snapshot(
            schema: 1, routeRevision: 1, origin: origin, destination: destination,
            preparedAt: now, departures: [departure], scheduleVersion: nil,
            scheduleExpired: false, scheduleExpiresAt: nil, specialSchedules: [],
            guidance: .init(location: .init(latitude: origin.latitude + 0.01,
                                           longitude: origin.longitude,
                                           horizontalAccuracy: 5, timestamp: now),
                            mode: .driving, travelMinutes: 2, estimateSource: "Maps estimate", estimateFetchedAt: now),
            lastBroadcastAt: now)
        let initial = snapshot.catchResult(for: departure, at: now)!
        let later = snapshot.catchResult(for: departure, at: now.addingTimeInterval(60))!
        XCTAssertTrue(initial.status == .comfortable && later.status == .tight)
        XCTAssertTrue(later.arrivalAtStation == initial.arrivalAtStation.addingTimeInterval(60))
        XCTAssertTrue(initial.leaveBy == later.leaveBy)
        XCTAssertTrue(snapshot.catchResult(for: departure, at: now.addingTimeInterval(181)) == nil)
        let distantDeparture = store.departures(from: origin, to: destination, after: now.addingTimeInterval(3601), limit: 1).first!
        XCTAssertTrue(snapshot.catchResult(for: distantDeparture, at: now) == nil,
                     "Later rows keep their compact presentation")
        XCTAssertTrue(snapshot.catchResult(for: distantDeparture, at: now, enforceOneHourLimit: false) != nil,
                     "Opening a later train must provide current travel guidance")
        XCTAssertTrue(snapshot.catchResult(for: distantDeparture, at: now.addingTimeInterval(181), enforceOneHourLimit: false) == nil,
                     "Detail guidance must still reject stale locations")
        var expiredMaps = snapshot
        // Fresh location cannot extend the life of a Maps estimate.
        expiredMaps = .init(schema: snapshot.schema, routeRevision: snapshot.routeRevision,
            origin: origin, destination: destination, preparedAt: now, departures: [departure],
            scheduleVersion: nil, scheduleExpired: false, scheduleExpiresAt: nil, specialSchedules: [],
            guidance: .init(location: snapshot.guidance!.location, mode: .driving, travelMinutes: 2,
                            estimateSource: "Maps estimate", estimateFetchedAt: now.addingTimeInterval(-300)),
            lastBroadcastAt: now)
        XCTAssertTrue(expiredMaps.catchResult(for: departure, at: now) == nil)
        XCTAssertTrue(expiredMaps.catchResult(for: distantDeparture, at: now, enforceOneHourLimit: false) == nil)
        for source in ["Distance-based fallback", "Driving estimate unavailable", "test"] {
            let unavailable = SharedTripState.Snapshot(schema: 1, routeRevision: 1,
                origin: origin, destination: destination, preparedAt: now, departures: [departure],
                scheduleVersion: nil, scheduleExpired: false, scheduleExpiresAt: nil, specialSchedules: [],
                guidance: .init(location: snapshot.guidance!.location, mode: .driving,
                                travelMinutes: 2, estimateSource: source, estimateFetchedAt: now),
                lastBroadcastAt: now)
            XCTAssertTrue(unavailable.catchResult(for: departure, at: now) == nil,
                         "Driving recommendations require a real Maps estimate, including legacy snapshots")
        }

        // UI and intent code cannot run in this command-line harness; guard their wiring too.
        let main = try SourceInspection.home()
        XCTAssertTrue(main.contains("Driving estimate unavailable") && main.contains("Calculating driving time"))
        XCTAssertTrue(main.components(separatedBy: "ScrollView {").count == 2,
                     "Main screen must use one vertical scroll area instead of clipping departures in a nested panel")
        XCTAssertTrue(main.contains(".padding(.bottom, 16)"))
        let row = try String(contentsOfFile: "NextPATCOTrain/DepartureListView.swift", encoding: .utf8)
        XCTAssertTrue(row.contains("Recommended") && !row.contains("Next likely train"))
        XCTAssertTrue(row.contains("isPrimaryLikelyDeparture ? .caption.weight(.bold)"))
        XCTAssertTrue(row.contains("isPrimaryLikelyDeparture ? status.leaveCountdownText() : status.primaryGuidanceText"))
        XCTAssertTrue(row.contains("else if isPrimaryLikelyDeparture {"))
        XCTAssertTrue(main.contains("Arrive at \\(compactOriginName)"))
        let toolbar = try String(contentsOfFile: "NextPATCOTrain/HomeDeparturesHeader.swift", encoding: .utf8)
        XCTAssertTrue(!toolbar.contains("Auto-selected"))
        XCTAssertTrue(toolbar.contains("Automatically selected"))
        XCTAssertTrue(main.contains("earlier trains · unlikely to catch"))
        let reachability = try String(contentsOfFile: "NextPATCOTrain/Reachability.swift", encoding: .utf8)
        XCTAssertTrue(reachability.contains("At \\(stationName) by \\(arrivalTime) if you leave now"))
        let estimates = try String(contentsOfFile: "NextPATCOTrain/TravelEstimateController.swift", encoding: .utf8)
        XCTAssertTrue(estimates.contains("SharedReachabilityModeStore.shouldRequestWalkingEstimate(distance:"))
        XCTAssertTrue(main.contains("SharedReachabilityModeStore.useAutomatic(originId:"))
        let siri = try String(contentsOfFile: "NextPATCOTrain/PATCOAppIntents.swift", encoding: .utf8)
        XCTAssertTrue(siri.contains("SharedReachabilityModeStore.resolve(originId:"))
        XCTAssertTrue(siri.contains("let minutes = estimate?.minutes"))
        XCTAssertTrue(!siri.contains("let mode = SiriTravelMode.inferred("))
        let quality = CLLocation(coordinate: origin.coordinate, altitude: 0, horizontalAccuracy: 80,
            verticalAccuracy: 1, timestamp: now.addingTimeInterval(-40))
        let diagnostic = LocationDiagnosticFormatting.eligibility(quality, now: now)
        XCTAssertTrue(diagnostic.contains("guidance eligible (180 sec/150 m): true"))
        XCTAssertTrue(diagnostic.contains("station reading eligible (15 sec/50 m): false"))
        let guidance = main.components(separatedBy: "var reachabilityGuidance:")[1]
            .components(separatedBy: "var currentReachabilityMode:")[0]
        XCTAssertTrue(guidance.range(of: "if isUsingTemporaryStationRoute {")!.lowerBound
            < guidance.range(of: "if isAtDepartureStation")!.lowerBound,
            "Temporary-route explanation must survive loss of station GPS confirmation")
        XCTAssertTrue(main.contains("if let reachabilityGuidance {\n                if model.route.isUsingTemporaryStationRoute {"),
            "Green banner must follow the displayed temporary route, not a new location fix")
        XCTAssertTrue(toolbar.contains("let reachabilityGuidance,\n               !isUsingTemporaryStationRoute,"),
            "Temporary-route explanation must not also appear in the Walk/Car header")
        let publishing = main.components(separatedBy: "func publishAppRoute()")[1]
            .components(separatedBy: "func refreshDepartures()")[0]
        XCTAssertTrue(publishing.contains("SharedRouteCoordinator.routeForApp("))
        XCTAssertTrue(!publishing.contains("SharedRouteCoordinator.commit("), "Routine app publishing must not select a new direction")
        let nearestPresentation = main.components(separatedBy: "// Nearest-station presentation must not change direction")[1]
            .components(separatedBy: "func completeDestinationArrivalIfNeeded")[0]
        XCTAssertTrue(!nearestPresentation.contains("originId =") && !nearestPresentation.contains("destinationId ="))
        let detail = try String(contentsOfFile: "NextPATCOTrain/DepartureDetailView.swift", encoding: .utf8)
        let summary = try String(contentsOfFile: "NextPATCOTrain/TripJourneySummary.swift", encoding: .utf8)
        XCTAssertTrue(summary.contains("catchStatus = catchStatusAt(date)"))
        XCTAssertTrue(detail.contains("!ScheduledTripExpiration.hasExpired(arrivalDate: departure.arrivalDate, now: timeline.date)"),
                     "Tracking can start after scheduled departure until the journey expires")
        let widget = try SourceInspection.widget()
        let intent = widget.components(separatedBy: "struct RefreshPATCOWidgetIntent")[1]
            .components(separatedBy: "struct ReversePATCOWidgetRouteIntent")[0]
        XCTAssertTrue(intent.contains("await WidgetInteractiveRefresh.perform(progress: progress)"))
        let toggle = widget.components(separatedBy: "struct TogglePATCOReachabilityModeIntent")[1]
            .components(separatedBy: "struct NextPATCOTrainWidgetEntryView")[0]
        XCTAssertTrue(toggle.contains("await WidgetInteractiveRefresh.perform(progress: progress)"))
        XCTAssertTrue(toggle.range(of: "SharedWidgetReachabilityState.requireRefresh")!.lowerBound
            < toggle.range(of: "await WidgetInteractiveRefresh.perform(progress: progress)")!.lowerBound)
        let refresh = widget.components(separatedBy: "private enum WidgetInteractiveRefresh")[1]
            .components(separatedBy: "struct RefreshPATCOWidgetIntent")[0]
        XCTAssertTrue(refresh.contains("specialSchedulesForDepartureWindow(from: Date(), force: true)"))
        XCTAssertTrue(refresh.contains("specialSchedules: schedules, reloadWidgets: false)"))
        XCTAssertTrue(refresh.contains("allowsCachedFallback: false"))
        XCTAssertTrue(refresh.contains("currentLocation: location, force: true"),
                     "Interactive refreshes must bypass Maps cache reuse")
        XCTAssertTrue(!refresh.contains("SharedWidgetReachabilityState.needsFollowUpRefresh(after: pendingRefresh)"),
                     "Interactive work must not retry beyond its action budget")
        XCTAssertTrue(refresh.contains("progress.permitsWork(reserving: seconds)"))
        let estimator = widget.components(separatedBy: "enum WidgetTravelTimeEstimator")[1]
            .components(separatedBy: "final class WidgetLocationProvider")[0]
        let walkingEstimate = estimator.components(separatedBy: "case .walking:")[1]
            .components(separatedBy: "case .driving:")[0]
        XCTAssertTrue(walkingEstimate.contains("transportType = .walking"))
        XCTAssertTrue(!walkingEstimate.contains("distanceToStation <="),
                     "Manually selected walking must request Maps estimates beyond the automatic mode cutoff")
        XCTAssertTrue(estimator.contains("if !force, let estimate = SharedTravelTimeEstimateCache.estimate("))
        XCTAssertTrue(estimator.range(of: "if !force")!.lowerBound < estimator.range(of: "let request = MKDirections.Request()")!.lowerBound)
        XCTAssertTrue(widget.contains("guidanceExpiration: guidanceExpiration"))
        XCTAssertTrue(widget.contains("&& estimateIsFresh"))
        print("Presentation refresh checks passed: Eastern time/DST, live catchability, freshness, detail and refresh wiring")
    }
}
