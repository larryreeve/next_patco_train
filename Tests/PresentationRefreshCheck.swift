import Foundation
import CoreLocation

@main
struct PresentationRefreshCheck {
    static func main() throws {
        let locale = Locale(identifier: "en_US")
        let originalZone = NSTimeZone.default
        defer { NSTimeZone.default = originalZone }
        let iso = ISO8601DateFormatter()
        let winter = iso.date(from: "2026-01-15T13:46:00Z")!
        let summer = iso.date(from: "2026-07-15T12:46:00Z")!
        let information = try String(contentsOfFile: "NextPATCOTrain/InformationViews.swift", encoding: .utf8)
        let validitySection = information.components(separatedBy: "private var scheduleFeedIsExpired: Bool")[1]
            .components(separatedBy: "private var scheduleFeedUpdateText")[0]
        precondition(!validitySection.contains("Calendar.current"))
        precondition(validitySection.contains("PATCOClock.calendar.date(byAdding: .day, value: 1"))
        precondition(validitySection.contains("Date.FormatStyle(timeZone: PATCOClock.calendar.timeZone)"))
        for zone in ["America/Los_Angeles", "Asia/Tokyo", "Europe/London"] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            for (startText, endText, expectedDate) in [
                ("2026-11-01T04:00:00Z", "2026-11-02T05:00:00Z", "11/1/2026"),
                ("2026-03-08T05:00:00Z", "2026-03-09T04:00:00Z", "3/8/2026")
            ] {
                let endDate = iso.date(from: startText)!
                let expiration = PATCOClock.calendar.date(byAdding: .day, value: 1, to: endDate)!
                precondition(expiration == iso.date(from: endText)!)
                let label = endDate.formatted(Date.FormatStyle(locale: locale, timeZone: PATCOClock.calendar.timeZone)
                    .month(.defaultDigits).day(.defaultDigits).year())
                precondition(label == expectedDate, "Wrong schedule validity date in \(zone): \(label)")
            }
            for date in [winter, summer] {
                let text = PATCOClock.timeText(date, locale: locale)
                precondition(text.contains("8:46") && text.contains("AM"), text)
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
        precondition(initial.status == .comfortable && later.status == .tight)
        precondition(later.arrivalAtStation == initial.arrivalAtStation.addingTimeInterval(60))
        precondition(initial.leaveBy == later.leaveBy)
        precondition(snapshot.catchResult(for: departure, at: now.addingTimeInterval(181)) == nil)
        let distantDeparture = store.departures(from: origin, to: destination, after: now.addingTimeInterval(3601), limit: 1).first!
        precondition(snapshot.catchResult(for: distantDeparture, at: now) == nil,
                     "Later rows keep their compact presentation")
        precondition(snapshot.catchResult(for: distantDeparture, at: now, enforceOneHourLimit: false) != nil,
                     "Opening a later train must provide current travel guidance")
        precondition(snapshot.catchResult(for: distantDeparture, at: now.addingTimeInterval(181), enforceOneHourLimit: false) == nil,
                     "Detail guidance must still reject stale locations")
        var expiredMaps = snapshot
        // Fresh location cannot extend the life of a Maps estimate.
        expiredMaps = .init(schema: snapshot.schema, routeRevision: snapshot.routeRevision,
            origin: origin, destination: destination, preparedAt: now, departures: [departure],
            scheduleVersion: nil, scheduleExpired: false, scheduleExpiresAt: nil, specialSchedules: [],
            guidance: .init(location: snapshot.guidance!.location, mode: .driving, travelMinutes: 2,
                            estimateSource: "Maps estimate", estimateFetchedAt: now.addingTimeInterval(-300)),
            lastBroadcastAt: now)
        precondition(expiredMaps.catchResult(for: departure, at: now) == nil)
        precondition(expiredMaps.catchResult(for: distantDeparture, at: now, enforceOneHourLimit: false) == nil)
        for source in ["Distance-based fallback", "Driving estimate unavailable", "test"] {
            let unavailable = SharedTripState.Snapshot(schema: 1, routeRevision: 1,
                origin: origin, destination: destination, preparedAt: now, departures: [departure],
                scheduleVersion: nil, scheduleExpired: false, scheduleExpiresAt: nil, specialSchedules: [],
                guidance: .init(location: snapshot.guidance!.location, mode: .driving,
                                travelMinutes: 2, estimateSource: source, estimateFetchedAt: now),
                lastBroadcastAt: now)
            precondition(unavailable.catchResult(for: departure, at: now) == nil,
                         "Driving recommendations require a real Maps estimate, including legacy snapshots")
        }

        // UI and intent code cannot run in this command-line harness; guard their wiring too.
        let main = try String(contentsOfFile: "NextPATCOTrain/ContentView.swift", encoding: .utf8)
        precondition(main.contains("Driving estimate unavailable") && main.contains("Calculating driving time"))
        precondition(main.components(separatedBy: "ScrollView {").count == 2,
                     "Main screen must use one vertical scroll area instead of clipping departures in a nested panel")
        precondition(main.contains(".padding(.bottom, 16)"))
        let row = try String(contentsOfFile: "NextPATCOTrain/DepartureListView.swift", encoding: .utf8)
        precondition(row.contains("Recommended") && !row.contains("Next likely train"))
        precondition(row.contains("isPrimaryLikelyDeparture ? .caption.weight(.bold)"))
        precondition(row.contains("isPrimaryLikelyDeparture ? status.leaveCountdownText() : status.primaryGuidanceText"))
        precondition(row.contains("else if isPrimaryLikelyDeparture {"))
        precondition(main.contains("Arrive at \\(compactOriginName)"))
        precondition(!main.contains("Auto-selected"))
        precondition(main.contains("Automatically selected"))
        precondition(main.contains("earlier trains · unlikely to catch"))
        let reachability = try String(contentsOfFile: "NextPATCOTrain/Reachability.swift", encoding: .utf8)
        precondition(reachability.contains("At \\(stationName) by \\(arrivalTime) if you leave now"))
        precondition(main.contains("SharedReachabilityModeStore.shouldRequestWalkingEstimate(distance:"))
        precondition(main.contains("SharedReachabilityModeStore.useAutomatic(originId:"))
        let siri = try String(contentsOfFile: "NextPATCOTrain/PATCOAppIntents.swift", encoding: .utf8)
        precondition(siri.contains("SharedReachabilityModeStore.resolve(originId:"))
        precondition(siri.contains("let minutes = estimate?.minutes"))
        precondition(!siri.contains("let mode = SiriTravelMode.inferred("))
        let quality = CLLocation(coordinate: origin.coordinate, altitude: 0, horizontalAccuracy: 80,
            verticalAccuracy: 1, timestamp: now.addingTimeInterval(-40))
        let diagnostic = LocationDiagnosticFormatting.eligibility(quality, now: now)
        precondition(diagnostic.contains("guidance eligible (180 sec/150 m): true"))
        precondition(diagnostic.contains("station reading eligible (15 sec/50 m): false"))
        let guidance = main.components(separatedBy: "private var reachabilityGuidance:")[1]
            .components(separatedBy: "private var currentReachabilityMode:")[0]
        precondition(guidance.range(of: "if isUsingTemporaryStationRoute {")!.lowerBound
            < guidance.range(of: "if isAtDepartureStation")!.lowerBound,
            "Temporary-route explanation must survive loss of station GPS confirmation")
        precondition(main.contains("if let reachabilityGuidance {\n                if isUsingTemporaryStationRoute {"),
            "Green banner must follow the displayed temporary route, not a new location fix")
        precondition(main.contains("let reachabilityGuidance,\n               !isUsingTemporaryStationRoute,"),
            "Temporary-route explanation must not also appear in the Walk/Car header")
        let publishing = main.components(separatedBy: "private func publishAppRoute()")[1]
            .components(separatedBy: "private func refreshDepartures()")[0]
        precondition(publishing.contains("SharedRouteCoordinator.routeForApp("))
        precondition(!publishing.contains("SharedRouteCoordinator.commit("), "Routine app publishing must not select a new direction")
        let nearestPresentation = main.components(separatedBy: "// Nearest-station presentation must not change direction")[1]
            .components(separatedBy: "private func completeDestinationArrivalIfNeeded")[0]
        precondition(!nearestPresentation.contains("originId =") && !nearestPresentation.contains("destinationId ="))
        let detail = try String(contentsOfFile: "NextPATCOTrain/DepartureDetailView.swift", encoding: .utf8)
        precondition(detail.contains("catchStatus = catchStatusAt(date)"))
        precondition(detail.contains("canShowLiveActivity(at: timeline.date)"))
        let widget = try String(contentsOfFile: "NextPATCOTrainWidget/NextPATCOTrainWidget.swift", encoding: .utf8)
        let intent = widget.components(separatedBy: "struct RefreshPATCOWidgetIntent")[1]
            .components(separatedBy: "struct ReversePATCOWidgetRouteIntent")[0]
        precondition(intent.contains("await WidgetInteractiveRefresh.perform(progress: progress)"))
        let toggle = widget.components(separatedBy: "struct TogglePATCOReachabilityModeIntent")[1]
            .components(separatedBy: "struct NextPATCOTrainWidgetEntryView")[0]
        precondition(toggle.contains("await WidgetInteractiveRefresh.perform(progress: progress)"))
        precondition(toggle.range(of: "SharedWidgetReachabilityState.requireRefresh")!.lowerBound
            < toggle.range(of: "await WidgetInteractiveRefresh.perform(progress: progress)")!.lowerBound)
        let refresh = widget.components(separatedBy: "private enum WidgetInteractiveRefresh")[1]
            .components(separatedBy: "struct RefreshPATCOWidgetIntent")[0]
        precondition(refresh.contains("specialSchedulesForDepartureWindow(from: Date(), force: true)"))
        precondition(refresh.contains("specialSchedules: schedules, reloadWidgets: false)"))
        precondition(refresh.contains("allowsCachedFallback: false"))
        precondition(refresh.contains("currentLocation: location, force: true"),
                     "Interactive refreshes must bypass Maps cache reuse")
        precondition(!refresh.contains("SharedWidgetReachabilityState.needsFollowUpRefresh(after: pendingRefresh)"),
                     "Interactive work must not retry beyond its action budget")
        precondition(refresh.contains("progress.permitsWork(reserving: seconds)"))
        let estimator = widget.components(separatedBy: "private enum WidgetTravelTimeEstimator")[1]
            .components(separatedBy: "private final class WidgetLocationProvider")[0]
        let walkingEstimate = estimator.components(separatedBy: "case .walking:")[1]
            .components(separatedBy: "case .driving:")[0]
        precondition(walkingEstimate.contains("transportType = .walking"))
        precondition(!walkingEstimate.contains("distanceToStation <="),
                     "Manually selected walking must request Maps estimates beyond the automatic mode cutoff")
        precondition(estimator.contains("if !force, let estimate = SharedTravelTimeEstimateCache.estimate("))
        precondition(estimator.range(of: "if !force")!.lowerBound < estimator.range(of: "let request = MKDirections.Request()")!.lowerBound)
        precondition(widget.contains("guidanceExpiration: guidanceExpiration"))
        precondition(widget.contains("&& estimateIsFresh"))
        print("Presentation refresh checks passed: Eastern time/DST, live catchability, freshness, detail and refresh wiring")
    }
}
