#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation
import CoreLocation

struct WidgetTimelineCheck {
    static func run() {
        let settingsSuite = "WidgetReachabilitySettingsTests.\(UUID().uuidString)"
        let settings = UserDefaults(suiteName: settingsSuite)!
        defer { settings.removePersistentDomain(forName: settingsSuite) }
        XCTAssertTrue(WidgetReachabilitySettings.isEnabled(defaults: settings))
        settings.set(true, forKey: WidgetReachabilitySettings.enabledKey)
        XCTAssertTrue(WidgetReachabilitySettings.isEnabled(defaults: settings))
        settings.set(false, forKey: WidgetReachabilitySettings.enabledKey)
        XCTAssertTrue(!WidgetReachabilitySettings.isEnabled(defaults: settings))
        struct Item: Identifiable { let id: Int }
        let items = (0..<500).map(Item.init)
        for recommendation in [0, 1, 9, 10, 30, 498, 499, 600] {
            let payload = WidgetDepartureSelection.timelinePayload(items) { $0.id == recommendation }
            XCTAssertTrue(payload.count <= 13)
            XCTAssertTrue(Array(payload.prefix(10).map(\.id)) == Array(0..<10))
            let expected = WidgetDepartureSelection.prioritized(items, limit: 3) { $0.id == recommendation }
            let actual = WidgetDepartureSelection.prioritized(payload, limit: 3) { $0.id == recommendation }
            XCTAssertTrue(actual.map(\.id) == expected.map(\.id))
        }
        let zone = TimeZone(identifier: "America/New_York")!
        let iso = ISO8601DateFormatter()
        let evening = iso.date(from: "2026-10-16T03:59:00Z")!
        let midnight = iso.date(from: "2026-10-16T04:01:00Z")!
        XCTAssertTrue(WidgetDepartureDay.label(for: evening, relativeTo: evening, timeZone: zone) == nil)
        XCTAssertTrue(WidgetDepartureDay.label(for: midnight, relativeTo: evening, timeZone: zone) == "Tomorrow")
        XCTAssertTrue(WidgetDepartureDay.label(for: midnight, relativeTo: midnight, timeZone: zone) == nil)
        let nextMorning = midnight.addingTimeInterval(4 * 3600)
        let visibleDates = [evening, midnight, nextMorning, nextMorning.addingTimeInterval(1800)]
        let labels = visibleDates.enumerated().map { index, date in
            WidgetDepartureDay.groupLabel(for: date, previousDeparture: index > 0 ? visibleDates[index - 1] : nil,
                relativeTo: evening, timeZone: zone)
        }
        XCTAssertTrue(labels == [nil, "Tomorrow", nil, nil])
        XCTAssertTrue(WidgetDepartureDay.groupLabel(for: nextMorning, previousDeparture: nil,
            relativeTo: evening, timeZone: zone) == "Tomorrow", "A window starting tomorrow still needs a label")
        XCTAssertTrue(WidgetDepartureDay.groupLabel(for: nextMorning, previousDeparture: nil,
            relativeTo: midnight, timeZone: zone) == nil, "Tomorrow must clear after midnight")
        XCTAssertTrue(WidgetDepartureDay.groupLabel(for: midnight.addingTimeInterval(86400), previousDeparture: nextMorning,
            relativeTo: evening, timeZone: zone) == "Oct 17")
        let dstEvening = iso.date(from: "2026-11-01T03:59:00Z")!
        let dstTomorrow = iso.date(from: "2026-11-02T04:30:00Z")!
        XCTAssertTrue(WidgetDepartureDay.label(for: dstTomorrow, relativeTo: dstEvening, timeZone: zone) == "Tomorrow")
        XCTAssertTrue(WidgetDepartureDay.label(for: midnight.addingTimeInterval(86400), relativeTo: evening, timeZone: zone) == "Oct 17")
        let widgetSource = try! SourceInspection.widget()
        XCTAssertTrue(widgetSource.contains("Toggle(isOn: workingAction == .reverse, intent: ReversePATCOWidgetRouteIntent(expectedRevision: routeRevision))"))
        XCTAssertTrue(widgetSource.contains("Toggle(isOn: workingAction == .refresh, intent: RefreshPATCOWidgetIntent())"))
        XCTAssertTrue(!widgetSource.contains("Toggle(isOn: false, intent:"),
                     "Commands must not latch an optimistic toggle into a permanent pending state")
        XCTAssertTrue(!widgetSource.contains(".disabled(isPending)"))
        XCTAssertTrue(!widgetSource.contains("WidgetPendingActionStyle"))
        XCTAssertTrue(widgetSource.contains("guard WidgetReachabilitySettings.isEnabled else { return nil }"))
        XCTAssertTrue(widgetSource.contains("guard WidgetReachabilitySettings.isEnabled else { return false }"))
        XCTAssertTrue(widgetSource.contains("guard WidgetReachabilitySettings.isEnabled else { return .result() }"))
        XCTAssertTrue(widgetSource.contains(".disabled(!WidgetReachabilitySettings.isEnabled)"))
        XCTAssertTrue(widgetSource.contains("if !WidgetReachabilitySettings.isEnabled {\n            EmptyView()"),
                     "Schedule-only widgets must not prompt users to refresh reachability")
        XCTAssertTrue(widgetSource.contains("if let originId, let mode = displayedMode"))
        XCTAssertTrue(widgetSource.contains("mode ?? .driving"),
                     "Disabled reachability must retain a visible travel-mode control")
        XCTAssertTrue(widgetSource.contains("WidgetReachabilitySettings.isEnabled && entry.locationFreshness == .fresh"))
        let infoSource = try! String(contentsOfFile: "NextPATCOTrain/InformationViews.swift", encoding: .utf8)
        XCTAssertTrue(infoSource.contains("private var widgetReachabilityEnabled = true"))
        XCTAssertTrue(infoSource.contains(".foregroundStyle(Color.patcoCharcoal)\n        .preferredColorScheme(.light)"),
                     "The light Information sheet must not inherit white dark-mode controls")
        XCTAssertTrue(infoSource.contains("Toggle(\"Widget reachability\", isOn: $widgetReachabilityEnabled)"))
        let diagnosticsParts = infoSource.components(separatedBy: "private struct WidgetDiagnosticsView: View {")
        XCTAssertTrue(!diagnosticsParts[0].contains("widgetReachabilityEnabled"),
                     "Widget reachability must not appear on the Information screen")
        XCTAssertTrue(diagnosticsParts[1].contains("private var widgetReachabilityEnabled = true"))
        XCTAssertTrue(diagnosticsParts[1].contains("if !isArrivalLog {\n                Section {\n                    Toggle(\"Widget reachability\""),
                     "Widget settings belong only in Widget Diagnostics, not Arrival Diagnostics")
        XCTAssertTrue(diagnosticsParts[1].contains(".onChange(of: widgetReachabilityEnabled)"))
        XCTAssertTrue(widgetSource.contains("\"Arrives at \\(arrivalTimeText(for: departure))\""))
        XCTAssertTrue(!widgetSource.contains("Text(\"Leave by\")"))
        XCTAssertTrue(!widgetSource.contains("Text(departure.id == recommendedID ? \"Recommended\""))
        XCTAssertTrue(widgetSource.contains(".accessibilityLabel(spokenDescription)"))
        XCTAssertTrue(widgetSource.contains("Text(\"Arrives at \\(arrivalTimeText(for: departure))\")"))
        XCTAssertTrue(!widgetSource.contains("\"Arrives \\(arrivalTimeText(for: departure))\""))
        XCTAssertTrue(widgetSource.contains("minHeight: 27"))
        XCTAssertTrue(widgetSource.contains(".overlay(alignment: .leading)"))
        XCTAssertTrue(widgetSource.contains("guard hasCurrentCatchability else { return nil }"))
        XCTAssertTrue(!widgetSource.contains("departure.id != displayedDepartures.first?.id ? 8 : 0"),
                     "Recommendation must not introduce a gap or compress one row")
        XCTAssertTrue(widgetSource.contains("? 135 : 100, alignment: .leading)\n                .fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(widgetSource.contains(".padding(.leading, 8)\n            .fixedSize(horizontal: false, vertical: true)"))
        let selectionSource = widgetSource.components(separatedBy: "private var prioritizesCatchability: Bool")[1]
            .components(separatedBy: "private var hasCurrentCatchability")[0]
        XCTAssertTrue(selectionSource.contains(".systemSmall || widgetFamily == .systemMedium"))
        XCTAssertTrue(!selectionSource.contains(".systemLarge"), "Large widget must retain chronological selection")
        let limits = widgetSource.components(separatedBy: "private var displayLimit: Int")[1]
            .components(separatedBy: "private var departureRowSpacing")[0]
        XCTAssertTrue(limits.contains("default:\n            3"))
        XCTAssertTrue(widgetSource.contains("if widgetFamily == .systemSmall {\n                VStack"))
        let compactTitle = widgetSource.components(separatedBy: "Text(\"PATCO\")")[1]
            .components(separatedBy: "Spacer(minLength: 0)")[0]
        XCTAssertTrue(compactTitle.contains(".lineLimit(1)"))
        XCTAssertTrue(compactTitle.contains(".fixedSize(horizontal: true, vertical: false)"),
                     "Small-widget controls must not compress PATCO into multiple lines")
        let appSource = try! SourceInspection.home()
        for timer in ["refreshTimer", "alertRefreshTimer", "specialScheduleRefreshTimer"] {
            XCTAssertTrue(appSource.contains(".onReceive(\(timer)) { _ in\n                guard scenePhase == .active else { return }"),
                         "Routine timer work must stop in the background")
        }
        let estimates = try! String(contentsOfFile: "NextPATCOTrain/TravelEstimateController.swift", encoding: .utf8)
        XCTAssertTrue(estimates.contains("!Task.isCancelled, !walkingEstimateInFlight"))
        XCTAssertTrue(estimates.contains("!Task.isCancelled, !drivingEstimateInFlight"))
        XCTAssertTrue(estimates.contains("if !force, let cached = cache.estimate(mode: .driving"))
        XCTAssertTrue(!appSource.contains("lastReachabilityLocationUpdate = now\n        driveTimeEstimate = nil"))
        XCTAssertTrue(widgetSource.contains("let shared = WidgetRefreshState.recentActionTrip\n            ?? updateSharedTrip(store: store, location: location, reloadWidgets: false)"))
        let reversal = widgetSource.components(separatedBy: "struct ReversePATCOWidgetRouteIntent")[1]
            .components(separatedBy: "struct TogglePATCOReachabilityModeIntent")[0]
        XCTAssertTrue(reversal.components(separatedBy: "PATCOScheduleStore()").count == 2,
                     "Reversal must reuse one schedule store in the intent")
        XCTAssertTrue(reversal.contains("reloadWidgets: false"))
        XCTAssertTrue(reversal.contains("previous.revision == expectedRevision"),
                     "Duplicate actions from the same displayed entry must not reverse twice")
        XCTAssertTrue(reversal.components(separatedBy: "WidgetCenter.shared.").count == 2,
                     "Reversal must request exactly one reload, including stale-action exits")
        let completion = reversal.components(separatedBy: "defer {")[1].components(separatedBy: "let startedAt")[0]
        XCTAssertTrue(completion.range(of: "WidgetActionProgress.finish(progress)")!.lowerBound
                     < completion.range(of: "WidgetCenter.shared.reloadAllTimelines()")!.lowerBound,
                     "Clear the busy state before requesting the final reload")
        let lockTimeline = widgetSource.components(separatedBy: "private struct PATCOLockScreenProvider")[1]
        XCTAssertTrue(lockTimeline.contains("let shared = WidgetRefreshState.recentActionTrip\n            ?? NextPATCOTrainWidgetProvider().updateSharedTrip"))
        XCTAssertTrue(!lockTimeline.contains("await WidgetLocationProvider.currentLocation()"),
                     "Routine Lock Screen refreshes must not wake GPS")
        XCTAssertTrue(!appSource.contains("lastDeparturesUpdatedAt"))
        XCTAssertTrue(appSource.contains("scheduleFeedLastCheckedAt: model.schedule.store.scheduleFeedLastCheckedAt"))
        let toolbar = try! String(contentsOfFile: "NextPATCOTrain/HomeDeparturesHeader.swift", encoding: .utf8)
        XCTAssertTrue(toolbar.contains("Text(scheduleFeedLastCheckedAt.map"))
        let suite = "WidgetReachabilityCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(SharedWidgetReachabilityState.pending(defaults: defaults) == nil)
        SharedWidgetReachabilityState.reconcileMode(originId: "2", mode: .driving, defaults: defaults)
        XCTAssertTrue(SharedWidgetReachabilityState.pending(defaults: defaults) == nil,
                     "Ordinary mode selection must not create a pending widget refresh")
        SharedWidgetReachabilityState.requireRefresh(originId: "2", mode: .walking, defaults: defaults)
        let failedWalking = SharedWidgetReachabilityState.pending(defaults: defaults)!
        XCTAssertTrue(SharedWidgetReachabilityState.blocksCatchability(originId: "2", defaults: defaults))
        XCTAssertTrue(!SharedWidgetReachabilityState.blocksCatchability(originId: "14", defaults: defaults))
        SharedWidgetReachabilityState.reconcileMode(originId: "14", mode: .driving, defaults: defaults)
        XCTAssertTrue(SharedWidgetReachabilityState.pending(defaults: defaults) == failedWalking)
        SharedWidgetReachabilityState.reconcileMode(originId: "2", mode: .walking, defaults: defaults)
        XCTAssertTrue(SharedWidgetReachabilityState.pending(defaults: defaults) == failedWalking)
        SharedWidgetReachabilityState.reconcileMode(originId: "2", mode: .driving, defaults: defaults)
        let recoveredDriving = SharedWidgetReachabilityState.pending(defaults: defaults)!
        XCTAssertTrue(recoveredDriving.mode == .driving && recoveredDriving.id != failedWalking.id)
        XCTAssertTrue(!SharedWidgetReachabilityState.complete(failedWalking, defaults: defaults))
        XCTAssertTrue(!SharedWidgetReachabilityState.completeIfReady(recoveredDriving, originId: "2", mode: .driving,
            hasFreshEstimate: false, isAtStation: false, defaults: defaults))
        XCTAssertTrue(SharedWidgetReachabilityState.completeIfReady(recoveredDriving, originId: "2", mode: .driving,
            hasFreshEstimate: true, isAtStation: false, defaults: defaults))
        XCTAssertTrue(!SharedWidgetReachabilityState.blocksCatchability(originId: "2", defaults: defaults))
        let lockProvider = widgetSource.components(separatedBy: "private func makeTimeline(at now: Date")[1]
            .components(separatedBy: "private struct PATCOLockScreenView")[0]
        XCTAssertTrue(lockProvider.contains("SharedWidgetReachabilityState.blocksCatchability(originId: departure.origin.id)"))
        let lockView = widgetSource.components(separatedBy: "private struct PATCOLockScreenView: View")[1]
            .components(separatedBy: "struct NextPATCOLockScreenWidget: Widget")[0]
        XCTAssertTrue(lockView.contains("visibleCatchStatuses[date].map"))
        XCTAssertTrue(lockView.contains("visibleCatchStatuses[date]?.color"))
        let models = try! SourceInspection.models()
        XCTAssertTrue(models.contains("SharedWidgetReachabilityState.reconcileMode(originId: originId, mode: mode)"))
        XCTAssertTrue(!SharedWidgetReachabilityState.needsFollowUpRefresh(after: nil, defaults: defaults))
        SharedWidgetReachabilityState.requireRefresh(originId: "2", mode: .walking, defaults: defaults)
        let walkingRequest = SharedWidgetReachabilityState.pending(defaults: defaults)!
        XCTAssertTrue(SharedWidgetReachabilityState.needsFollowUpRefresh(after: nil, defaults: defaults))
        XCTAssertTrue(!SharedWidgetReachabilityState.needsFollowUpRefresh(after: walkingRequest, defaults: defaults))
        XCTAssertTrue(walkingRequest.originId == "2" && walkingRequest.mode == .walking)
        // Timeline reloads and extension recreation do not unlock cached guidance.
        let reloadedDefaults = UserDefaults(suiteName: suite)!
        XCTAssertTrue(SharedWidgetReachabilityState.pending(defaults: reloadedDefaults) == walkingRequest)
        SharedWidgetReachabilityState.requireRefresh(originId: "2", mode: .driving, defaults: defaults)
        let drivingRequest = SharedWidgetReachabilityState.pending(defaults: defaults)!
        XCTAssertTrue(SharedWidgetReachabilityState.needsFollowUpRefresh(after: walkingRequest, defaults: defaults))
        XCTAssertTrue(!SharedWidgetReachabilityState.complete(walkingRequest, defaults: defaults))
        XCTAssertTrue(SharedWidgetReachabilityState.pending(defaults: defaults) == drivingRequest)
        SharedWidgetReachabilityState.requireRefresh(originId: "2", mode: .walking, defaults: defaults)
        let newerWalkingRequest = SharedWidgetReachabilityState.pending(defaults: defaults)!
        XCTAssertTrue(newerWalkingRequest.id != walkingRequest.id)
        XCTAssertTrue(!SharedWidgetReachabilityState.complete(walkingRequest, defaults: defaults))
        XCTAssertTrue(!SharedWidgetReachabilityState.complete(drivingRequest, defaults: defaults))
        XCTAssertTrue(SharedWidgetReachabilityState.complete(newerWalkingRequest, defaults: defaults))
        XCTAssertTrue(SharedWidgetReachabilityState.pending(defaults: defaults) == nil)
        XCTAssertTrue(!SharedWidgetReachabilityState.needsFollowUpRefresh(after: newerWalkingRequest, defaults: defaults))
        XCTAssertTrue(!SharedWidgetReachabilityState.complete(newerWalkingRequest, defaults: defaults))

        SharedWidgetReachabilityState.requireRefresh(originId: "2", mode: .walking, defaults: defaults)
        let recovery = SharedWidgetReachabilityState.pending(defaults: defaults)!
        XCTAssertTrue(!SharedWidgetReachabilityState.completeIfReady(recovery, originId: "2", mode: .walking,
            hasFreshEstimate: false, isAtStation: false, defaults: defaults))
        XCTAssertTrue(!SharedWidgetReachabilityState.completeIfReady(recovery, originId: "2", mode: .driving,
            hasFreshEstimate: true, isAtStation: false, defaults: defaults))
        XCTAssertTrue(!SharedWidgetReachabilityState.completeIfReady(recovery, originId: "14", mode: .walking,
            hasFreshEstimate: true, isAtStation: false, defaults: defaults))
        XCTAssertTrue(SharedWidgetReachabilityState.completeIfReady(recovery, originId: "2", mode: .walking,
            hasFreshEstimate: true, isAtStation: false, defaults: defaults), "Background recovery must clear the matching failed request")
        SharedWidgetReachabilityState.requireRefresh(originId: "2", mode: .walking, defaults: defaults)
        let obsolete = SharedWidgetReachabilityState.pending(defaults: defaults)!
        SharedWidgetReachabilityState.requireRefresh(originId: "2", mode: .walking, defaults: defaults)
        XCTAssertTrue(!SharedWidgetReachabilityState.completeIfReady(obsolete, originId: "2", mode: .walking,
            hasFreshEstimate: true, isAtStation: false, defaults: defaults))
        let atStation = SharedWidgetReachabilityState.pending(defaults: defaults)!
        XCTAssertTrue(SharedWidgetReachabilityState.completeIfReady(atStation, originId: "2", mode: nil,
            hasFreshEstimate: false, isAtStation: true, defaults: defaults))
        XCTAssertTrue(widgetSource.contains("force: pendingRefresh != nil"))
        XCTAssertTrue(widgetSource.contains("SharedWidgetReachabilityState.completeIfReady(pendingRefresh"))

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let liveDeparture = now.addingTimeInterval(60)
        let liveArrival = now.addingTimeInterval(1500)
        XCTAssertTrue(ScheduledDeparturePresentation.staleDate(departureDate: liveDeparture, arrivalDate: liveArrival, now: now) == liveDeparture)
        XCTAssertTrue(ScheduledDeparturePresentation.staleDate(departureDate: liveDeparture, arrivalDate: liveArrival, now: liveDeparture) == liveArrival.addingTimeInterval(600))
        XCTAssertTrue(!ScheduledDeparturePresentation.hasDeparted(departureDate: liveDeparture, isStale: false, now: now))
        XCTAssertTrue(ScheduledDeparturePresentation.hasDeparted(departureDate: liveDeparture, isStale: false, now: liveDeparture))
        XCTAssertTrue(ScheduledDeparturePresentation.hasDeparted(departureDate: liveDeparture, isStale: false, now: liveDeparture.addingTimeInterval(420)))
        XCTAssertTrue(ScheduledDeparturePresentation.hasDeparted(departureDate: liveDeparture, isStale: true, now: now))
        let reload = SharedWidgetDiagnostics.ReloadRequest(id: UUID(), date: now, action: "Reversal",
                                                          revision: 10, originId: "2", destinationId: "14")
        XCTAssertTrue(reload.outcome(revision: 10, originId: "2", destinationId: "14") == "Requested route loaded")
        XCTAssertTrue(reload.outcome(revision: 11, originId: "14", destinationId: "2") == "Requested revision superseded by a newer route")
        XCTAssertTrue(reload.outcome(revision: 9, originId: "14", destinationId: "2") == "Route mismatch with reload request")
        XCTAssertTrue(reload.outcome(revision: 10, originId: "14", destinationId: "2") == "Route mismatch with reload request")
        XCTAssertTrue(reload.outcome(revision: nil, originId: nil, destinationId: nil) == "No matching committed route revision")
        let reloadData = try! JSONEncoder().encode(reload)
        let decodedReload = try! JSONDecoder().decode(SharedWidgetDiagnostics.ReloadRequest.self, from: reloadData)
        XCTAssertTrue(decodedReload.id == reload.id && decodedReload.revision == 10)
        let scheduled = Array(0..<8)
        XCTAssertTrue(WidgetDepartureSelection.select(scheduled, limit: 3) == [0, 1, 2])
        let options = Array(0..<10)
        func targets(_ limit: Int) -> [Int] {
            WidgetDepartureSelection.prioritized(options, limit: limit,
                isRecommended: { $0 >= 5 })
        }
        XCTAssertTrue(targets(3) == [4, 5, 6])
        XCTAssertTrue(targets(2) == [4, 5])
        XCTAssertTrue(targets(1) == [5])
        XCTAssertTrue(targets(0).isEmpty)
        XCTAssertTrue(WidgetDepartureSelection.prioritized(options, limit: 3,
            isRecommended: { _ in false }) == [0, 1, 2])
        XCTAssertTrue(WidgetDepartureSelection.prioritized(options, limit: 3,
            isRecommended: { _ in true }) == [0, 1, 2])
        XCTAssertTrue(WidgetDepartureSelection.prioritized(options, limit: 3,
            isRecommended: { $0 == 9 }) == [8, 9])
        let picturedTimes = ["9:32", "9:52", "10:12", "10:32", "10:52"]
        XCTAssertTrue(WidgetDepartureSelection.prioritized(picturedTimes, limit: 3,
            isRecommended: { $0 == "10:12" }) == ["9:52", "10:12", "10:32"])
        XCTAssertTrue(WidgetDepartureSelection.prioritized([Int](), limit: 3,
            isRecommended: { _ in true }).isEmpty)
        for recommendedIndex in options {
            let window = WidgetDepartureSelection.prioritized(options, limit: 3,
                isRecommended: { $0 == recommendedIndex })
            XCTAssertTrue(window.contains(recommendedIndex))
            XCTAssertTrue(window.first == max(0, recommendedIndex - 1))
            XCTAssertTrue(zip(window, window.dropFirst()).allSatisfy { $1 == $0 + 1 })
        }
        XCTAssertTrue(WidgetDepartureSelection.select(scheduled, limit: 20) == scheduled)
        XCTAssertTrue(WidgetDepartureSelection.select([6, 7], limit: 3) == [6, 7])
        XCTAssertTrue(WidgetDepartureSelection.select(scheduled, limit: 0).isEmpty)
        XCTAssertTrue(WidgetDepartureSelection.select(scheduled, limit: -1).isEmpty)
        XCTAssertTrue(WidgetDepartureSelection.select([Int](), limit: 3).isEmpty)
        let homeWindow = WidgetDepartureSelection.select(Array(0..<50), limit: 20)
        let homeDisplay = WidgetDepartureSelection.select(homeWindow, limit: 3)
        let lockDisplay = WidgetDepartureSelection.select(Array(0..<50), limit: 3)
        XCTAssertTrue(homeWindow == Array(0..<20))
        XCTAssertTrue(homeDisplay == lockDisplay && lockDisplay == [0, 1, 2])
        let departureDates = (0..<8).map { now.addingTimeInterval(Double($0 * 600)) }
        let afterFirstDeparture = now.addingTimeInterval(1)
        let upcoming = departureDates.filter { $0 >= afterFirstDeparture }
        XCTAssertTrue(WidgetDepartureSelection.select(upcoming, limit: 3) == Array(departureDates[1...3]))
        func location(age: Double = 0, accuracy: Double = 10) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 39.95, longitude: -75.17), altitude: 0,
                       horizontalAccuracy: accuracy, verticalAccuracy: 1, timestamp: now.addingTimeInterval(-age))
        }
        let stationLocation = location()
        let awayFromStation = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 39.953, longitude: -75.17),
                                        altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 1, timestamp: now)
        let uncertainBoundary = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 39.9515, longitude: -75.17),
                                          altitude: 0, horizontalAccuracy: 100, verticalAccuracy: 1, timestamp: now)
        XCTAssertTrue(!LocationGuidancePolicy.hasLeftStation(location(), station: stationLocation, now: now))
        XCTAssertTrue(LocationGuidancePolicy.hasLeftStation(awayFromStation, station: stationLocation, now: now))
        XCTAssertTrue(!LocationGuidancePolicy.hasLeftStation(uncertainBoundary, station: stationLocation, now: now))
        XCTAssertTrue(!LocationGuidancePolicy.hasLeftStation(awayFromStation, station: stationLocation, now: now.addingTimeInterval(31)))
        XCTAssertTrue(!LocationGuidancePolicy.hasLeftStation(awayFromStation, station: stationLocation, now: now.addingTimeInterval(-1)))
        let inaccurateDeparture = CLLocation(coordinate: awayFromStation.coordinate, altitude: 0,
                                             horizontalAccuracy: 500, verticalAccuracy: 1, timestamp: now)
        XCTAssertTrue(!LocationGuidancePolicy.hasLeftStation(inaccurateDeparture, station: stationLocation, now: now))
        XCTAssertTrue(WidgetTimelinePolicy.hasUsableGuidance(location: location(age: 180, accuracy: 150), at: now))
        for accuracy in [-1.0, 0, 151, 500, 1000] {
            XCTAssertTrue(!WidgetTimelinePolicy.hasUsableGuidance(location: location(accuracy: accuracy), at: now))
        }
        XCTAssertTrue(!WidgetTimelinePolicy.hasUsableGuidance(location: location(age: 181), at: now))
        XCTAssertTrue(!WidgetTimelinePolicy.hasUsableGuidance(location: location(age: -1), at: now))
        XCTAssertTrue(!WidgetTimelinePolicy.hasUsableGuidance(location: nil, at: now))
        let departure = now.addingTimeInterval(90 * 60)
        let dates = WidgetTimelinePolicy.entryDates(now: now, departures: [departure, departure, now.addingTimeInterval(-60)])
        XCTAssertTrue(dates.first == now)
        XCTAssertTrue(dates.last == now.addingTimeInterval(24 * 3600))
        XCTAssertTrue(dates.contains(departure.addingTimeInterval(1)))
        XCTAssertTrue(Set(dates).count == dates.count)
        XCTAssertTrue(dates == dates.sorted())
        XCTAssertTrue(WidgetTimelinePolicy.entryDates(now: now, departures: []).last == now.addingTimeInterval(24 * 3600))
        for age in [0.0, 120, 179, 180] {
            XCTAssertTrue(WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: true,
                locationTimestamp: now.addingTimeInterval(-age)).date == now.addingTimeInterval(max(60, 181 - age)))
        }
        XCTAssertTrue(WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: false, locationTimestamp: now).date == now.addingTimeInterval(300))
        XCTAssertTrue(WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: false, locationTimestamp: nil).date == now.addingTimeInterval(300))
        XCTAssertTrue(WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: true,
            locationTimestamp: now, estimateTimestamp: now.addingTimeInterval(-240)).date == now.addingTimeInterval(60))
        XCTAssertTrue(WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: true,
            locationTimestamp: now.addingTimeInterval(-181)).date == now.addingTimeInterval(300))
        XCTAssertTrue(WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: false,
            locationTimestamp: now, reachabilityEnabled: false).date == now.addingTimeInterval(900))
        XCTAssertTrue(widgetSource.contains("Home Screen reachability prepared"))
        XCTAssertTrue(widgetSource.contains("widgetStatusLine\n                        .frame(maxWidth: .infinity, alignment: .center)\n                        .multilineTextAlignment(.center)"),
                     "The refresh message must be centered across the widget")
        XCTAssertTrue(widgetSource.contains("Widget Maps estimate saved"))
        XCTAssertTrue(WidgetTimelinePolicy.nextRefresh(now: now, hasService: false, hasGuidance: false, locationTimestamp: nil).date == now.addingTimeInterval(1800))
        print("Widget timeline checks passed")
        XCTAssertTrue(WidgetTimelinePolicy.lockScreenRefresh(now: now, trackingDeadline: nil, hasActiveTrip: false) == now.addingTimeInterval(1800))
        XCTAssertTrue(WidgetTimelinePolicy.lockScreenRefresh(now: now, trackingDeadline: now.addingTimeInterval(7200), hasActiveTrip: false) == now.addingTimeInterval(600))
        XCTAssertTrue(WidgetTimelinePolicy.lockScreenRefresh(now: now, trackingDeadline: now, hasActiveTrip: false) == now.addingTimeInterval(1800))
        XCTAssertTrue(WidgetTimelinePolicy.lockScreenRefresh(now: now, trackingDeadline: now.addingTimeInterval(7201), hasActiveTrip: false) == now.addingTimeInterval(1800))
        XCTAssertTrue(WidgetTimelinePolicy.lockScreenRefresh(now: now, trackingDeadline: nil, hasActiveTrip: true) == now.addingTimeInterval(600))
    }
}
