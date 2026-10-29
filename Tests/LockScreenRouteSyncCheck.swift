#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import XCTest
import Foundation

struct LockScreenRouteSyncCheck {
    static func run() throws {
        let suite = "LockScreenRefreshFeedbackCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let feedbackDate = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertTrue(LockScreenRefreshFeedback.visibleUntil(at: feedbackDate, defaults: defaults) == nil)
        LockScreenRefreshFeedback.recordCompletion(defaults: defaults)
        let preparedAt = feedbackDate.addingTimeInterval(600)
        let end = LockScreenRefreshFeedback.visibleUntil(at: preparedAt, defaults: defaults)!
        XCTAssertTrue(end == preparedAt.addingTimeInterval(3), "Delayed delivery must not consume the confirmation before preparation")
        XCTAssertTrue(LockScreenRefreshFeedback.visibleUntil(at: preparedAt.addingTimeInterval(1), defaults: defaults) == end)
        XCTAssertTrue(LockScreenRefreshFeedback.visibleUntil(at: end, defaults: defaults) == nil)
        XCTAssertTrue(LockScreenRefreshFeedback.visibleUntil(at: end.addingTimeInterval(60), defaults: defaults) == nil,
                     "Normal reloads must not restart the confirmation")
        LockScreenRefreshFeedback.recordCompletion(defaults: defaults)
        XCTAssertTrue(LockScreenRefreshFeedback.visibleUntil(at: end, defaults: defaults) == end.addingTimeInterval(3))
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
        XCTAssertTrue(oldTimeline.routeRevision != SharedRouteCoordinator.current(directory: directory)?.revision)
        XCTAssertTrue(SharedTripState.current(directory: directory) == nil, "Old-route shared departures must not survive a reversal")
        XCTAssertTrue(SharedTripState.update(store: store, routeRevision: initial.revision, location: nil,
            now: now.addingTimeInterval(2), directory: directory) == nil, "An in-flight old route cannot republish its departures")
        let newTimeline = SharedTripState.update(store: store, routeRevision: reversed.revision, location: nil,
            now: now.addingTimeInterval(2), directory: directory)!.snapshot
        XCTAssertTrue(newTimeline.origin.id == destination.id && newTimeline.destination.id == origin.id)
        XCTAssertTrue(newTimeline.departures.allSatisfy { $0.origin.id == destination.id && $0.destination.id == origin.id })
        let again = SharedRouteCoordinator.reverse(expectedRevision: reversed.revision,
            now: now.addingTimeInterval(3), directory: directory)!
        XCTAssertTrue(again.originId == initial.originId && again.revision != oldTimeline.routeRevision,
                     "Rapid double reversals must be checked by revision, not just station names")

        let widget = try SourceInspection.widget()
        let home = widget.components(separatedBy: "struct NextPATCOTrainWidgetProvider")[1]
            .components(separatedBy: "func refreshTravelTimeEstimate")[0]
        XCTAssertTrue(home.contains("timeline.entries.first?.routeRevision != SharedRouteCoordinator.current()?.revision"))
        XCTAssertTrue(home.contains("for _ in 0..<2"), "Home Screen route rebuilds must be bounded")
        XCTAssertTrue(home.contains("let preparedRevision = shared?.routeRevision ?? startingRevision"))
        XCTAssertTrue(home.contains("entry.routeRevision = preparedRevision"), "Double reversal must invalidate old entries even when stations match")
        XCTAssertTrue(home.contains("Timeline(entries: [neutral]"))
        XCTAssertTrue(home.contains("routeUpdating: true"), "Route churn must show an updating state, not old departures")
        let schedules = try String(contentsOfFile: "NextPATCOTrain/HomeScheduleController.swift", encoding: .utf8)
        let unchanged = schedules.components(separatedBy: "else if case .current = updateResult")[1]
        XCTAssertTrue(unchanged.contains("store.load()"))
        XCTAssertTrue(unchanged.contains("applyCachedSpecialSchedules()"), "Reloading metadata must preserve active special schedules")
        let reverse = widget.components(separatedBy: "struct ReversePATCOWidgetRouteIntent")[1]
            .components(separatedBy: "struct TogglePATCOReachabilityModeIntent")[0]
        XCTAssertTrue(reverse.contains("WidgetCenter.shared.reloadAllTimelines()"),
                     "One consolidated reload must update both Home and Lock Screen widgets")
        let provider = widget.components(separatedBy: "private struct PATCOLockScreenProvider")[1]
            .components(separatedBy: "private struct PATCOLockScreenView")[0]
        XCTAssertTrue(provider.range(of: "if SharedTripState.current() != nil")!.lowerBound
            < provider.range(of: "Task { @MainActor in")!.lowerBound,
                     "Route synchronization must bypass the async GPS request")
        XCTAssertTrue(provider.contains("$0.revision != SharedDiagnosticState.snapshot(for: .lockScreen)?.revision"))
        XCTAssertTrue(provider.contains("callback.call(makeCurrentTimeline("))
        XCTAssertTrue(provider.contains("await NextPATCOTrainWidgetProvider().specialSchedulesForDepartureWindow(from: Date())"),
                     "Lock Screen-only installations must fetch special schedules")
        XCTAssertTrue(provider.contains("timeline.entries.first?.routeRevision != SharedRouteCoordinator.current()?.revision"))
        XCTAssertTrue(provider.contains("Timeline(entries: [neutral]"), "Rapid route churn must not publish wrong-route departures")
        let refresh = widget.components(separatedBy: "struct RefreshPATCOLockScreenWidgetIntent")[1]
            .components(separatedBy: "struct ReversePATCOWidgetRouteIntent")[0]
        XCTAssertTrue(refresh.contains("static let openAppWhenRun = false"))
        XCTAssertTrue(refresh.contains("updateSharedTrip(store: PATCOScheduleStore()"))
        XCTAssertTrue(refresh.contains("WidgetRefreshState.actionCompleted()"))
        XCTAssertTrue(refresh.contains("reloadWidgets: false"))
        XCTAssertTrue(refresh.contains("specialSchedulesForDepartureWindow(from: Date(), force: true)"))
        let specialFetch = widget.components(separatedBy: "func specialSchedulesForDepartureWindow")[1]
            .components(separatedBy: "func selectedRoute")[0]
        XCTAssertTrue(specialFetch.contains("SpecialScheduleRefreshDeadline.wait"))
        XCTAssertTrue(specialFetch.contains("result?.schedules ?? cached"))
        XCTAssertTrue(!refresh.contains("WidgetCenter.shared.reload"), "The interactive button already guarantees its own reload")
        XCTAssertTrue(!refresh.contains("WidgetLocationProvider.currentLocation") && !refresh.contains("WidgetInteractiveRefresh"))
        XCTAssertTrue(!refresh.contains("SharedRouteCoordinator.reverse") && !refresh.contains("SharedRouteCoordinator.commit"))
        let view = widget.components(separatedBy: "private struct PATCOLockScreenView")[1]
            .components(separatedBy: "struct NextPATCOLockScreenWidget")[0]
        XCTAssertTrue(!view.contains("Button(") && !view.contains("PATCOLockScreenRefreshButton"),
                     "Lock Screen widget must not show refresh controls")
        XCTAssertTrue(view.contains(".widgetURL(URL(string: \"patconext://widget\"))"),
                     "Tapping the Lock Screen widget must still open the app")
        XCTAssertTrue(widget.contains("intent: RefreshPATCOWidgetIntent()"),
                     "Home Screen refresh controls must remain available")
        XCTAssertTrue(!view.contains(".invalidatableContent()"), "No flashing invalidation effect")
        XCTAssertTrue(refresh.contains("LockScreenRefreshFeedback.recordCompletion()"))
        XCTAssertTrue(provider.contains("confirmationEnd.map { date < $0 } ?? false"))
        XCTAssertTrue(provider.contains("confirmationEnd.map { [$0] }"), "The reset must use a scheduled entry, not another reload")
        XCTAssertTrue(provider.contains("reloadWidgets: false"), "Preparing a timeline must not trigger another broad reload")
        print("Lock Screen route sync checks passed: reversal, double reversal, obsolete snapshots and provider wiring")
    }
}
