import Foundation

@main
struct LockScreenRouteSyncCheck {
    static func main() throws {
        let suite = "LockScreenRefreshFeedbackCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let feedbackDate = Date(timeIntervalSince1970: 1_790_000_000)
        precondition(LockScreenRefreshFeedback.visibleUntil(at: feedbackDate, defaults: defaults) == nil)
        LockScreenRefreshFeedback.recordCompletion(defaults: defaults)
        let preparedAt = feedbackDate.addingTimeInterval(600)
        let end = LockScreenRefreshFeedback.visibleUntil(at: preparedAt, defaults: defaults)!
        precondition(end == preparedAt.addingTimeInterval(3), "Delayed delivery must not consume the confirmation before preparation")
        precondition(LockScreenRefreshFeedback.visibleUntil(at: preparedAt.addingTimeInterval(1), defaults: defaults) == end)
        precondition(LockScreenRefreshFeedback.visibleUntil(at: end, defaults: defaults) == nil)
        precondition(LockScreenRefreshFeedback.visibleUntil(at: end.addingTimeInterval(60), defaults: defaults) == nil,
                     "Normal reloads must not restart the confirmation")
        LockScreenRefreshFeedback.recordCompletion(defaults: defaults)
        precondition(LockScreenRefreshFeedback.visibleUntil(at: end, defaults: defaults) == end.addingTimeInterval(3))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try Data(contentsOf: URL(fileURLWithPath: "NextPATCOTrain/Resources/patco_schedule.json"))
        let store = PATCOScheduleStore(feed: try JSONDecoder().decode(PATCOFeed.self, from: data))
        let origin = store.stations.first { $0.name == "Ashland" }!
        let destination = store.stations.first { $0.name == "15/16th and Locust" }!
        let now = Date()
        let initial = SharedRouteCoordinator.commit(originId: origin.id, destinationId: destination.id,
            manual: true, now: now, directory: directory)!
        let oldTimeline = SharedTripState.update(store: store, routeRevision: initial.revision, location: nil,
            now: now, directory: directory)!.snapshot
        let reversed = SharedRouteCoordinator.reverse(expectedRevision: initial.revision,
            now: now.addingTimeInterval(1), directory: directory)!
        precondition(oldTimeline.routeRevision != SharedRouteCoordinator.current(directory: directory)?.revision)
        precondition(SharedTripState.current(directory: directory) == nil, "Old-route shared departures must not survive a reversal")
        precondition(SharedTripState.update(store: store, routeRevision: initial.revision, location: nil,
            now: now.addingTimeInterval(2), directory: directory) == nil, "An in-flight old route cannot republish its departures")
        let newTimeline = SharedTripState.update(store: store, routeRevision: reversed.revision, location: nil,
            now: now.addingTimeInterval(2), directory: directory)!.snapshot
        precondition(newTimeline.origin.id == destination.id && newTimeline.destination.id == origin.id)
        precondition(newTimeline.departures.allSatisfy { $0.origin.id == destination.id && $0.destination.id == origin.id })
        let again = SharedRouteCoordinator.reverse(expectedRevision: reversed.revision,
            now: now.addingTimeInterval(3), directory: directory)!
        precondition(again.originId == initial.originId && again.revision != oldTimeline.routeRevision,
                     "Rapid double reversals must be checked by revision, not just station names")

        let widget = try String(contentsOfFile: "NextPATCOTrainWidget/NextPATCOTrainWidget.swift", encoding: .utf8)
        let home = widget.components(separatedBy: "struct NextPATCOTrainWidgetProvider")[1]
            .components(separatedBy: "fileprivate func refreshTravelTimeEstimate")[0]
        precondition(home.contains("timeline.entries.first?.routeRevision != SharedRouteCoordinator.current()?.revision"))
        precondition(home.contains("for _ in 0..<2"), "Home Screen route rebuilds must be bounded")
        precondition(home.contains("let preparedRevision = shared?.routeRevision ?? startingRevision"))
        precondition(home.contains("entry.routeRevision = preparedRevision"), "Double reversal must invalidate old entries even when stations match")
        precondition(home.contains("Timeline(entries: [neutral]"))
        precondition(home.contains("routeUpdating: true"), "Route churn must show an updating state, not old departures")
        let app = try String(contentsOfFile: "NextPATCOTrain/ContentView.swift", encoding: .utf8)
        let automaticRefresh = app.components(separatedBy: "private func refreshAll(")[1]
            .components(separatedBy: "driveTimeEstimate = nil")[0]
        let unchanged = automaticRefresh.components(separatedBy: "else if case .current = updateResult")[1]
        precondition(unchanged.contains("scheduleStore.load()"))
        precondition(unchanged.contains("applyCachedSpecialSchedules()"), "Reloading metadata must preserve active special schedules")
        let reverse = widget.components(separatedBy: "struct ReversePATCOWidgetRouteIntent")[1]
            .components(separatedBy: "struct TogglePATCOReachabilityModeIntent")[0]
        precondition(reverse.contains("WidgetCenter.shared.reloadAllTimelines()"),
                     "One consolidated reload must update both Home and Lock Screen widgets")
        let provider = widget.components(separatedBy: "private struct PATCOLockScreenProvider")[1]
            .components(separatedBy: "private struct PATCOLockScreenView")[0]
        precondition(provider.range(of: "if SharedTripState.current() != nil")!.lowerBound
            < provider.range(of: "Task { @MainActor in")!.lowerBound,
                     "Route synchronization must bypass the async GPS request")
        precondition(provider.contains("$0.revision != SharedDiagnosticState.snapshot(for: .lockScreen)?.revision"))
        precondition(provider.contains("callback.call(makeCurrentTimeline("))
        precondition(provider.contains("await NextPATCOTrainWidgetProvider().specialSchedulesForDepartureWindow(from: Date())"),
                     "Lock Screen-only installations must fetch special schedules")
        precondition(provider.contains("timeline.entries.first?.routeRevision != SharedRouteCoordinator.current()?.revision"))
        precondition(provider.contains("Timeline(entries: [neutral]"), "Rapid route churn must not publish wrong-route departures")
        let refresh = widget.components(separatedBy: "struct RefreshPATCOLockScreenWidgetIntent")[1]
            .components(separatedBy: "struct ReversePATCOWidgetRouteIntent")[0]
        precondition(refresh.contains("static let openAppWhenRun = false"))
        precondition(refresh.contains("updateSharedTrip(store: PATCOScheduleStore()"))
        precondition(refresh.contains("WidgetRefreshState.actionCompleted()"))
        precondition(refresh.contains("reloadWidgets: false"))
        precondition(refresh.contains("specialSchedulesForDepartureWindow(from: Date(), force: true)"))
        let specialFetch = widget.components(separatedBy: "fileprivate func specialSchedulesForDepartureWindow")[1]
            .components(separatedBy: "fileprivate func selectedRoute")[0]
        precondition(specialFetch.contains("SpecialScheduleRefreshDeadline.wait"))
        precondition(specialFetch.contains("result?.schedules ?? cached"))
        precondition(!refresh.contains("WidgetCenter.shared.reload"), "The interactive button already guarantees its own reload")
        precondition(!refresh.contains("WidgetLocationProvider.currentLocation") && !refresh.contains("WidgetInteractiveRefresh"))
        precondition(!refresh.contains("SharedRouteCoordinator.reverse") && !refresh.contains("SharedRouteCoordinator.commit"))
        let view = widget.components(separatedBy: "private struct PATCOLockScreenView")[1]
            .components(separatedBy: "struct NextPATCOLockScreenWidget")[0]
        precondition(!view.contains("Button(") && !view.contains("PATCOLockScreenRefreshButton"),
                     "Lock Screen widget must not show refresh controls")
        precondition(view.contains(".widgetURL(URL(string: \"patconext://widget\"))"),
                     "Tapping the Lock Screen widget must still open the app")
        precondition(widget.contains("intent: RefreshPATCOWidgetIntent()"),
                     "Home Screen refresh controls must remain available")
        precondition(!view.contains(".invalidatableContent()"), "No flashing invalidation effect")
        precondition(refresh.contains("LockScreenRefreshFeedback.recordCompletion()"))
        precondition(provider.contains("confirmationEnd.map { date < $0 } ?? false"))
        precondition(provider.contains("confirmationEnd.map { [$0] }"), "The reset must use a scheduled entry, not another reload")
        precondition(provider.contains("reloadWidgets: false"), "Preparing a timeline must not trigger another broad reload")
        print("Lock Screen route sync checks passed: reversal, double reversal, obsolete snapshots and provider wiring")
    }
}
