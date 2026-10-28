import Foundation
import CoreLocation

@main
struct WidgetTimelineCheck {
    static func main() {
        let settingsSuite = "WidgetReachabilitySettingsTests.\(UUID().uuidString)"
        let settings = UserDefaults(suiteName: settingsSuite)!
        defer { settings.removePersistentDomain(forName: settingsSuite) }
        precondition(WidgetReachabilitySettings.isEnabled(defaults: settings))
        settings.set(true, forKey: WidgetReachabilitySettings.enabledKey)
        precondition(WidgetReachabilitySettings.isEnabled(defaults: settings))
        settings.set(false, forKey: WidgetReachabilitySettings.enabledKey)
        precondition(!WidgetReachabilitySettings.isEnabled(defaults: settings))
        struct Item: Identifiable { let id: Int }
        let items = (0..<500).map(Item.init)
        for recommendation in [0, 1, 9, 10, 30, 498, 499, 600] {
            let payload = WidgetDepartureSelection.timelinePayload(items) { $0.id == recommendation }
            precondition(payload.count <= 13)
            precondition(Array(payload.prefix(10).map(\.id)) == Array(0..<10))
            let expected = WidgetDepartureSelection.prioritized(items, limit: 3) { $0.id == recommendation }
            let actual = WidgetDepartureSelection.prioritized(payload, limit: 3) { $0.id == recommendation }
            precondition(actual.map(\.id) == expected.map(\.id))
        }
        let zone = TimeZone(identifier: "America/New_York")!
        let iso = ISO8601DateFormatter()
        let evening = iso.date(from: "2026-10-16T03:59:00Z")!
        let midnight = iso.date(from: "2026-10-16T04:01:00Z")!
        precondition(WidgetDepartureDay.label(for: evening, relativeTo: evening, timeZone: zone) == nil)
        precondition(WidgetDepartureDay.label(for: midnight, relativeTo: evening, timeZone: zone) == "Tomorrow")
        precondition(WidgetDepartureDay.label(for: midnight, relativeTo: midnight, timeZone: zone) == nil)
        let nextMorning = midnight.addingTimeInterval(4 * 3600)
        let visibleDates = [evening, midnight, nextMorning, nextMorning.addingTimeInterval(1800)]
        let labels = visibleDates.enumerated().map { index, date in
            WidgetDepartureDay.groupLabel(for: date, previousDeparture: index > 0 ? visibleDates[index - 1] : nil,
                relativeTo: evening, timeZone: zone)
        }
        precondition(labels == [nil, "Tomorrow", nil, nil])
        precondition(WidgetDepartureDay.groupLabel(for: nextMorning, previousDeparture: nil,
            relativeTo: evening, timeZone: zone) == "Tomorrow", "A window starting tomorrow still needs a label")
        precondition(WidgetDepartureDay.groupLabel(for: nextMorning, previousDeparture: nil,
            relativeTo: midnight, timeZone: zone) == nil, "Tomorrow must clear after midnight")
        precondition(WidgetDepartureDay.groupLabel(for: midnight.addingTimeInterval(86400), previousDeparture: nextMorning,
            relativeTo: evening, timeZone: zone) == "Oct 17")
        let dstEvening = iso.date(from: "2026-11-01T03:59:00Z")!
        let dstTomorrow = iso.date(from: "2026-11-02T04:30:00Z")!
        precondition(WidgetDepartureDay.label(for: dstTomorrow, relativeTo: dstEvening, timeZone: zone) == "Tomorrow")
        precondition(WidgetDepartureDay.label(for: midnight.addingTimeInterval(86400), relativeTo: evening, timeZone: zone) == "Oct 17")
        let widgetSource = try! String(contentsOfFile: "NextPATCOTrainWidget/NextPATCOTrainWidget.swift", encoding: .utf8)
        precondition(widgetSource.contains("Toggle(isOn: workingAction == .reverse, intent: ReversePATCOWidgetRouteIntent(expectedRevision: routeRevision))"))
        precondition(widgetSource.contains("Toggle(isOn: workingAction == .refresh, intent: RefreshPATCOWidgetIntent())"))
        precondition(!widgetSource.contains("Toggle(isOn: false, intent:"),
                     "Commands must not latch an optimistic toggle into a permanent pending state")
        precondition(!widgetSource.contains(".disabled(isPending)"))
        precondition(!widgetSource.contains("WidgetPendingActionStyle"))
        precondition(widgetSource.contains("guard WidgetReachabilitySettings.isEnabled else { return nil }"))
        precondition(widgetSource.contains("guard WidgetReachabilitySettings.isEnabled else { return false }"))
        precondition(widgetSource.contains("guard WidgetReachabilitySettings.isEnabled else { return .result() }"))
        precondition(widgetSource.contains(".disabled(!WidgetReachabilitySettings.isEnabled)"))
        precondition(widgetSource.contains("if !WidgetReachabilitySettings.isEnabled {\n            EmptyView()"),
                     "Schedule-only widgets must not prompt users to refresh reachability")
        precondition(widgetSource.contains("if let originId, let mode = displayedMode"))
        precondition(widgetSource.contains("mode ?? .driving"),
                     "Disabled reachability must retain a visible travel-mode control")
        precondition(widgetSource.contains("WidgetReachabilitySettings.isEnabled && entry.locationFreshness == .fresh"))
        let infoSource = try! String(contentsOfFile: "NextPATCOTrain/InformationViews.swift", encoding: .utf8)
        precondition(infoSource.contains("private var widgetReachabilityEnabled = true"))
        precondition(infoSource.contains(".foregroundStyle(Color.patcoCharcoal)\n        .preferredColorScheme(.light)"),
                     "The light Information sheet must not inherit white dark-mode controls")
        precondition(infoSource.contains("Toggle(\"Widget reachability\", isOn: $widgetReachabilityEnabled)"))
        let diagnosticsParts = infoSource.components(separatedBy: "private struct WidgetDiagnosticsView: View {")
        precondition(!diagnosticsParts[0].contains("widgetReachabilityEnabled"),
                     "Widget reachability must not appear on the Information screen")
        precondition(diagnosticsParts[1].contains("private var widgetReachabilityEnabled = true"))
        precondition(diagnosticsParts[1].contains("if !isArrivalLog {\n                Section {\n                    Toggle(\"Widget reachability\""),
                     "Widget settings belong only in Widget Diagnostics, not Arrival Diagnostics")
        precondition(diagnosticsParts[1].contains(".onChange(of: widgetReachabilityEnabled)"))
        precondition(widgetSource.contains("\"Arrives at \\(arrivalTimeText(for: departure))\""))
        precondition(!widgetSource.contains("Text(\"Leave by\")"))
        precondition(!widgetSource.contains("Text(departure.id == recommendedID ? \"Recommended\""))
        precondition(widgetSource.contains(".accessibilityLabel(spokenDescription)"))
        precondition(widgetSource.contains("Text(\"Arrives at \\(arrivalTimeText(for: departure))\")"))
        precondition(!widgetSource.contains("\"Arrives \\(arrivalTimeText(for: departure))\""))
        precondition(widgetSource.contains("minHeight: 27"))
        precondition(widgetSource.contains(".overlay(alignment: .leading)"))
        precondition(widgetSource.contains("guard hasCurrentCatchability else { return nil }"))
        precondition(!widgetSource.contains("departure.id != displayedDepartures.first?.id ? 8 : 0"),
                     "Recommendation must not introduce a gap or compress one row")
        precondition(widgetSource.contains("? 135 : 100, alignment: .leading)\n                .fixedSize(horizontal: false, vertical: true)"))
        precondition(widgetSource.contains(".padding(.leading, 8)\n            .fixedSize(horizontal: false, vertical: true)"))
        let selectionSource = widgetSource.components(separatedBy: "private var prioritizesCatchability: Bool")[1]
            .components(separatedBy: "private var hasCurrentCatchability")[0]
        precondition(selectionSource.contains(".systemSmall || widgetFamily == .systemMedium"))
        precondition(!selectionSource.contains(".systemLarge"), "Large widget must retain chronological selection")
        let limits = widgetSource.components(separatedBy: "private var displayLimit: Int")[1]
            .components(separatedBy: "private var departureRowSpacing")[0]
        precondition(limits.contains("default:\n            3"))
        precondition(widgetSource.contains("if widgetFamily == .systemSmall {\n                VStack"))
        let compactTitle = widgetSource.components(separatedBy: "Text(\"PATCO\")")[1]
            .components(separatedBy: "Spacer(minLength: 0)")[0]
        precondition(compactTitle.contains(".lineLimit(1)"))
        precondition(compactTitle.contains(".fixedSize(horizontal: true, vertical: false)"),
                     "Small-widget controls must not compress PATCO into multiple lines")
        let appSource = try! String(contentsOfFile: "NextPATCOTrain/ContentView.swift", encoding: .utf8)
        for timer in ["refreshTimer", "alertRefreshTimer", "specialScheduleRefreshTimer"] {
            precondition(appSource.contains(".onReceive(\(timer)) { _ in\n                guard scenePhase == .active else { return }"),
                         "Routine timer work must stop in the background")
        }
        precondition(appSource.contains("!Task.isCancelled, !walkingEstimateInFlight"))
        precondition(appSource.contains("!Task.isCancelled, !drivingEstimateInFlight"))
        precondition(appSource.contains("if !force, let cached = SharedTravelTimeEstimateCache.estimate(mode: .driving"))
        precondition(!appSource.contains("lastReachabilityLocationUpdate = now\n        driveTimeEstimate = nil"))
        precondition(widgetSource.contains("let shared = WidgetRefreshState.recentActionTrip\n            ?? updateSharedTrip(store: store, location: location, reloadWidgets: false)"))
        let reversal = widgetSource.components(separatedBy: "struct ReversePATCOWidgetRouteIntent")[1]
            .components(separatedBy: "struct TogglePATCOReachabilityModeIntent")[0]
        precondition(reversal.components(separatedBy: "PATCOScheduleStore()").count == 2,
                     "Reversal must reuse one schedule store in the intent")
        precondition(reversal.contains("reloadWidgets: false"))
        precondition(reversal.contains("previous.revision == expectedRevision"),
                     "Duplicate actions from the same displayed entry must not reverse twice")
        precondition(reversal.components(separatedBy: "WidgetCenter.shared.").count == 2,
                     "Reversal must request exactly one reload, including stale-action exits")
        let completion = reversal.components(separatedBy: "defer {")[1].components(separatedBy: "let startedAt")[0]
        precondition(completion.range(of: "WidgetActionProgress.finish(progress)")!.lowerBound
                     < completion.range(of: "WidgetCenter.shared.reloadAllTimelines()")!.lowerBound,
                     "Clear the busy state before requesting the final reload")
        let lockTimeline = widgetSource.components(separatedBy: "private struct PATCOLockScreenProvider")[1]
        precondition(lockTimeline.contains("let shared = WidgetRefreshState.recentActionTrip\n            ?? NextPATCOTrainWidgetProvider().updateSharedTrip"))
        precondition(!lockTimeline.contains("await WidgetLocationProvider.currentLocation()"),
                     "Routine Lock Screen refreshes must not wake GPS")
        precondition(!appSource.contains("lastDeparturesUpdatedAt"))
        precondition(appSource.contains("Text(scheduleStore.scheduleFeedLastCheckedAt.map"))
        let suite = "WidgetReachabilityCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(SharedWidgetReachabilityState.pending(defaults: defaults) == nil)
        SharedWidgetReachabilityState.reconcileMode(originId: "2", mode: .driving, defaults: defaults)
        precondition(SharedWidgetReachabilityState.pending(defaults: defaults) == nil,
                     "Ordinary mode selection must not create a pending widget refresh")
        SharedWidgetReachabilityState.requireRefresh(originId: "2", mode: .walking, defaults: defaults)
        let failedWalking = SharedWidgetReachabilityState.pending(defaults: defaults)!
        precondition(SharedWidgetReachabilityState.blocksCatchability(originId: "2", defaults: defaults))
        precondition(!SharedWidgetReachabilityState.blocksCatchability(originId: "14", defaults: defaults))
        SharedWidgetReachabilityState.reconcileMode(originId: "14", mode: .driving, defaults: defaults)
        precondition(SharedWidgetReachabilityState.pending(defaults: defaults) == failedWalking)
        SharedWidgetReachabilityState.reconcileMode(originId: "2", mode: .walking, defaults: defaults)
        precondition(SharedWidgetReachabilityState.pending(defaults: defaults) == failedWalking)
        SharedWidgetReachabilityState.reconcileMode(originId: "2", mode: .driving, defaults: defaults)
        let recoveredDriving = SharedWidgetReachabilityState.pending(defaults: defaults)!
        precondition(recoveredDriving.mode == .driving && recoveredDriving.id != failedWalking.id)
        precondition(!SharedWidgetReachabilityState.complete(failedWalking, defaults: defaults))
        precondition(!SharedWidgetReachabilityState.completeIfReady(recoveredDriving, originId: "2", mode: .driving,
            hasFreshEstimate: false, isAtStation: false, defaults: defaults))
        precondition(SharedWidgetReachabilityState.completeIfReady(recoveredDriving, originId: "2", mode: .driving,
            hasFreshEstimate: true, isAtStation: false, defaults: defaults))
        precondition(!SharedWidgetReachabilityState.blocksCatchability(originId: "2", defaults: defaults))
        let lockProvider = widgetSource.components(separatedBy: "private func makeTimeline(at now: Date")[1]
            .components(separatedBy: "private struct PATCOLockScreenView")[0]
        precondition(lockProvider.contains("SharedWidgetReachabilityState.blocksCatchability(originId: departure.origin.id)"))
        let lockView = widgetSource.components(separatedBy: "private struct PATCOLockScreenView: View")[1]
            .components(separatedBy: "struct NextPATCOLockScreenWidget: Widget")[0]
        precondition(lockView.contains("visibleCatchStatuses[date].map"))
        precondition(lockView.contains("visibleCatchStatuses[date]?.color"))
        let models = try! String(contentsOfFile: "NextPATCOTrain/PATCOModels.swift", encoding: .utf8)
        precondition(models.contains("SharedWidgetReachabilityState.reconcileMode(originId: originId, mode: mode)"))
        precondition(!SharedWidgetReachabilityState.needsFollowUpRefresh(after: nil, defaults: defaults))
        SharedWidgetReachabilityState.requireRefresh(originId: "2", mode: .walking, defaults: defaults)
        let walkingRequest = SharedWidgetReachabilityState.pending(defaults: defaults)!
        precondition(SharedWidgetReachabilityState.needsFollowUpRefresh(after: nil, defaults: defaults))
        precondition(!SharedWidgetReachabilityState.needsFollowUpRefresh(after: walkingRequest, defaults: defaults))
        precondition(walkingRequest.originId == "2" && walkingRequest.mode == .walking)
        // Timeline reloads and extension recreation do not unlock cached guidance.
        let reloadedDefaults = UserDefaults(suiteName: suite)!
        precondition(SharedWidgetReachabilityState.pending(defaults: reloadedDefaults) == walkingRequest)
        SharedWidgetReachabilityState.requireRefresh(originId: "2", mode: .driving, defaults: defaults)
        let drivingRequest = SharedWidgetReachabilityState.pending(defaults: defaults)!
        precondition(SharedWidgetReachabilityState.needsFollowUpRefresh(after: walkingRequest, defaults: defaults))
        precondition(!SharedWidgetReachabilityState.complete(walkingRequest, defaults: defaults))
        precondition(SharedWidgetReachabilityState.pending(defaults: defaults) == drivingRequest)
        SharedWidgetReachabilityState.requireRefresh(originId: "2", mode: .walking, defaults: defaults)
        let newerWalkingRequest = SharedWidgetReachabilityState.pending(defaults: defaults)!
        precondition(newerWalkingRequest.id != walkingRequest.id)
        precondition(!SharedWidgetReachabilityState.complete(walkingRequest, defaults: defaults))
        precondition(!SharedWidgetReachabilityState.complete(drivingRequest, defaults: defaults))
        precondition(SharedWidgetReachabilityState.complete(newerWalkingRequest, defaults: defaults))
        precondition(SharedWidgetReachabilityState.pending(defaults: defaults) == nil)
        precondition(!SharedWidgetReachabilityState.needsFollowUpRefresh(after: newerWalkingRequest, defaults: defaults))
        precondition(!SharedWidgetReachabilityState.complete(newerWalkingRequest, defaults: defaults))

        SharedWidgetReachabilityState.requireRefresh(originId: "2", mode: .walking, defaults: defaults)
        let recovery = SharedWidgetReachabilityState.pending(defaults: defaults)!
        precondition(!SharedWidgetReachabilityState.completeIfReady(recovery, originId: "2", mode: .walking,
            hasFreshEstimate: false, isAtStation: false, defaults: defaults))
        precondition(!SharedWidgetReachabilityState.completeIfReady(recovery, originId: "2", mode: .driving,
            hasFreshEstimate: true, isAtStation: false, defaults: defaults))
        precondition(!SharedWidgetReachabilityState.completeIfReady(recovery, originId: "14", mode: .walking,
            hasFreshEstimate: true, isAtStation: false, defaults: defaults))
        precondition(SharedWidgetReachabilityState.completeIfReady(recovery, originId: "2", mode: .walking,
            hasFreshEstimate: true, isAtStation: false, defaults: defaults), "Background recovery must clear the matching failed request")
        SharedWidgetReachabilityState.requireRefresh(originId: "2", mode: .walking, defaults: defaults)
        let obsolete = SharedWidgetReachabilityState.pending(defaults: defaults)!
        SharedWidgetReachabilityState.requireRefresh(originId: "2", mode: .walking, defaults: defaults)
        precondition(!SharedWidgetReachabilityState.completeIfReady(obsolete, originId: "2", mode: .walking,
            hasFreshEstimate: true, isAtStation: false, defaults: defaults))
        let atStation = SharedWidgetReachabilityState.pending(defaults: defaults)!
        precondition(SharedWidgetReachabilityState.completeIfReady(atStation, originId: "2", mode: nil,
            hasFreshEstimate: false, isAtStation: true, defaults: defaults))
        precondition(widgetSource.contains("force: pendingRefresh != nil"))
        precondition(widgetSource.contains("SharedWidgetReachabilityState.completeIfReady(pendingRefresh"))

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let liveDeparture = now.addingTimeInterval(60)
        let liveArrival = now.addingTimeInterval(1500)
        precondition(ScheduledDeparturePresentation.staleDate(departureDate: liveDeparture, arrivalDate: liveArrival, now: now) == liveDeparture)
        precondition(ScheduledDeparturePresentation.staleDate(departureDate: liveDeparture, arrivalDate: liveArrival, now: liveDeparture) == liveArrival.addingTimeInterval(600))
        precondition(!ScheduledDeparturePresentation.hasDeparted(departureDate: liveDeparture, isStale: false, now: now))
        precondition(ScheduledDeparturePresentation.hasDeparted(departureDate: liveDeparture, isStale: false, now: liveDeparture))
        precondition(ScheduledDeparturePresentation.hasDeparted(departureDate: liveDeparture, isStale: false, now: liveDeparture.addingTimeInterval(420)))
        precondition(ScheduledDeparturePresentation.hasDeparted(departureDate: liveDeparture, isStale: true, now: now))
        let reload = SharedWidgetDiagnostics.ReloadRequest(id: UUID(), date: now, action: "Reversal",
                                                          revision: 10, originId: "2", destinationId: "14")
        precondition(reload.outcome(revision: 10, originId: "2", destinationId: "14") == "Requested route loaded")
        precondition(reload.outcome(revision: 11, originId: "14", destinationId: "2") == "Requested revision superseded by a newer route")
        precondition(reload.outcome(revision: 9, originId: "14", destinationId: "2") == "Route mismatch with reload request")
        precondition(reload.outcome(revision: 10, originId: "14", destinationId: "2") == "Route mismatch with reload request")
        precondition(reload.outcome(revision: nil, originId: nil, destinationId: nil) == "No matching committed route revision")
        let reloadData = try! JSONEncoder().encode(reload)
        let decodedReload = try! JSONDecoder().decode(SharedWidgetDiagnostics.ReloadRequest.self, from: reloadData)
        precondition(decodedReload.id == reload.id && decodedReload.revision == 10)
        let scheduled = Array(0..<8)
        precondition(WidgetDepartureSelection.select(scheduled, limit: 3) == [0, 1, 2])
        let options = Array(0..<10)
        func targets(_ limit: Int) -> [Int] {
            WidgetDepartureSelection.prioritized(options, limit: limit,
                isRecommended: { $0 >= 5 })
        }
        precondition(targets(3) == [4, 5, 6])
        precondition(targets(2) == [4, 5])
        precondition(targets(1) == [5])
        precondition(targets(0).isEmpty)
        precondition(WidgetDepartureSelection.prioritized(options, limit: 3,
            isRecommended: { _ in false }) == [0, 1, 2])
        precondition(WidgetDepartureSelection.prioritized(options, limit: 3,
            isRecommended: { _ in true }) == [0, 1, 2])
        precondition(WidgetDepartureSelection.prioritized(options, limit: 3,
            isRecommended: { $0 == 9 }) == [8, 9])
        let picturedTimes = ["9:32", "9:52", "10:12", "10:32", "10:52"]
        precondition(WidgetDepartureSelection.prioritized(picturedTimes, limit: 3,
            isRecommended: { $0 == "10:12" }) == ["9:52", "10:12", "10:32"])
        precondition(WidgetDepartureSelection.prioritized([Int](), limit: 3,
            isRecommended: { _ in true }).isEmpty)
        for recommendedIndex in options {
            let window = WidgetDepartureSelection.prioritized(options, limit: 3,
                isRecommended: { $0 == recommendedIndex })
            precondition(window.contains(recommendedIndex))
            precondition(window.first == max(0, recommendedIndex - 1))
            precondition(zip(window, window.dropFirst()).allSatisfy { $1 == $0 + 1 })
        }
        precondition(WidgetDepartureSelection.select(scheduled, limit: 20) == scheduled)
        precondition(WidgetDepartureSelection.select([6, 7], limit: 3) == [6, 7])
        precondition(WidgetDepartureSelection.select(scheduled, limit: 0).isEmpty)
        precondition(WidgetDepartureSelection.select(scheduled, limit: -1).isEmpty)
        precondition(WidgetDepartureSelection.select([Int](), limit: 3).isEmpty)
        let homeWindow = WidgetDepartureSelection.select(Array(0..<50), limit: 20)
        let homeDisplay = WidgetDepartureSelection.select(homeWindow, limit: 3)
        let lockDisplay = WidgetDepartureSelection.select(Array(0..<50), limit: 3)
        precondition(homeWindow == Array(0..<20))
        precondition(homeDisplay == lockDisplay && lockDisplay == [0, 1, 2])
        let departureDates = (0..<8).map { now.addingTimeInterval(Double($0 * 600)) }
        let afterFirstDeparture = now.addingTimeInterval(1)
        let upcoming = departureDates.filter { $0 >= afterFirstDeparture }
        precondition(WidgetDepartureSelection.select(upcoming, limit: 3) == Array(departureDates[1...3]))
        func location(age: Double = 0, accuracy: Double = 10) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 39.95, longitude: -75.17), altitude: 0,
                       horizontalAccuracy: accuracy, verticalAccuracy: 1, timestamp: now.addingTimeInterval(-age))
        }
        let stationLocation = location()
        let awayFromStation = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 39.953, longitude: -75.17),
                                        altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 1, timestamp: now)
        let uncertainBoundary = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 39.9515, longitude: -75.17),
                                          altitude: 0, horizontalAccuracy: 100, verticalAccuracy: 1, timestamp: now)
        precondition(!LocationGuidancePolicy.hasLeftStation(location(), station: stationLocation, now: now))
        precondition(LocationGuidancePolicy.hasLeftStation(awayFromStation, station: stationLocation, now: now))
        precondition(!LocationGuidancePolicy.hasLeftStation(uncertainBoundary, station: stationLocation, now: now))
        precondition(!LocationGuidancePolicy.hasLeftStation(awayFromStation, station: stationLocation, now: now.addingTimeInterval(31)))
        precondition(!LocationGuidancePolicy.hasLeftStation(awayFromStation, station: stationLocation, now: now.addingTimeInterval(-1)))
        let inaccurateDeparture = CLLocation(coordinate: awayFromStation.coordinate, altitude: 0,
                                             horizontalAccuracy: 500, verticalAccuracy: 1, timestamp: now)
        precondition(!LocationGuidancePolicy.hasLeftStation(inaccurateDeparture, station: stationLocation, now: now))
        precondition(WidgetTimelinePolicy.hasUsableGuidance(location: location(age: 180, accuracy: 150), at: now))
        for accuracy in [-1.0, 0, 151, 500, 1000] {
            precondition(!WidgetTimelinePolicy.hasUsableGuidance(location: location(accuracy: accuracy), at: now))
        }
        precondition(!WidgetTimelinePolicy.hasUsableGuidance(location: location(age: 181), at: now))
        precondition(!WidgetTimelinePolicy.hasUsableGuidance(location: location(age: -1), at: now))
        precondition(!WidgetTimelinePolicy.hasUsableGuidance(location: nil, at: now))
        let departure = now.addingTimeInterval(90 * 60)
        let dates = WidgetTimelinePolicy.entryDates(now: now, departures: [departure, departure, now.addingTimeInterval(-60)])
        precondition(dates.first == now)
        precondition(dates.last == now.addingTimeInterval(24 * 3600))
        precondition(dates.contains(departure.addingTimeInterval(1)))
        precondition(Set(dates).count == dates.count)
        precondition(dates == dates.sorted())
        precondition(WidgetTimelinePolicy.entryDates(now: now, departures: []).last == now.addingTimeInterval(24 * 3600))
        for age in [0.0, 120, 179, 180] {
            precondition(WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: true,
                locationTimestamp: now.addingTimeInterval(-age)).date == now.addingTimeInterval(max(60, 181 - age)))
        }
        precondition(WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: false, locationTimestamp: now).date == now.addingTimeInterval(300))
        precondition(WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: false, locationTimestamp: nil).date == now.addingTimeInterval(300))
        precondition(WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: true,
            locationTimestamp: now, estimateTimestamp: now.addingTimeInterval(-240)).date == now.addingTimeInterval(60))
        precondition(WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: true,
            locationTimestamp: now.addingTimeInterval(-181)).date == now.addingTimeInterval(300))
        precondition(WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: false,
            locationTimestamp: now, reachabilityEnabled: false).date == now.addingTimeInterval(900))
        precondition(widgetSource.contains("Home Screen reachability prepared"))
        precondition(widgetSource.contains("widgetStatusLine\n                        .frame(maxWidth: .infinity, alignment: .center)\n                        .multilineTextAlignment(.center)"),
                     "The refresh message must be centered across the widget")
        precondition(widgetSource.contains("Widget Maps estimate saved"))
        precondition(WidgetTimelinePolicy.nextRefresh(now: now, hasService: false, hasGuidance: false, locationTimestamp: nil).date == now.addingTimeInterval(1800))
        print("Widget timeline checks passed")
        precondition(WidgetTimelinePolicy.lockScreenRefresh(now: now, trackingDeadline: nil, hasActiveTrip: false) == now.addingTimeInterval(1800))
        precondition(WidgetTimelinePolicy.lockScreenRefresh(now: now, trackingDeadline: now.addingTimeInterval(7200), hasActiveTrip: false) == now.addingTimeInterval(600))
        precondition(WidgetTimelinePolicy.lockScreenRefresh(now: now, trackingDeadline: now, hasActiveTrip: false) == now.addingTimeInterval(1800))
        precondition(WidgetTimelinePolicy.lockScreenRefresh(now: now, trackingDeadline: now.addingTimeInterval(7201), hasActiveTrip: false) == now.addingTimeInterval(1800))
        precondition(WidgetTimelinePolicy.lockScreenRefresh(now: now, trackingDeadline: nil, hasActiveTrip: true) == now.addingTimeInterval(600))
    }
}
