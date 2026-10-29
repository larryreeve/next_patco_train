import ActivityKit
import CoreLocation
import MapKit
import SwiftUI
import WidgetKit
import AppIntents

private enum WidgetInteractiveRefresh {
    static func perform(progress: WidgetActionProgress.Ticket) async {
        // One bounded pass per tap. Leave time to publish before the action lease expires.
        func canContinue(reserving seconds: TimeInterval = 0) -> Bool {
            WidgetReachabilitySettings.isEnabled && !Task.isCancelled
                && progress.permitsWork(reserving: seconds)
                && WidgetActionProgress.current()?.id == progress.id
        }
        guard canContinue(reserving: 8) else { return }
        SharedWidgetDiagnostics.record("Widget refresh action started", detail: "Requesting location before publishing departures")
        let diagnosticRunID = SharedWidgetDiagnostics.beginWidgetRun(manual: true)
        defer { SharedWidgetDiagnostics.finishWidgetRun(diagnosticRunID, manual: true) }
        let pendingRefresh = SharedWidgetReachabilityState.pending()
        SharedCurrentLocationCache.requireFreshLocation()
        let location = await WidgetLocationProvider.currentLocation(
            allowsCachedFallback: false,
            diagnosticRunID: diagnosticRunID
        )
        guard canContinue(reserving: 4) else { return }
        let store = PATCOScheduleStore()
        let schedules = await NextPATCOTrainWidgetProvider().specialSchedulesForDepartureWindow(from: Date(), force: true)
        guard canContinue() else { return }
        store.applySpecialSchedules(schedules)
        _ = NextPATCOTrainWidgetProvider().selectedRoute(in: store, currentLocation: location, reloadWidgets: false)
        let refreshedEstimate = canContinue(reserving: 8) ? await NextPATCOTrainWidgetProvider().refreshTravelTimeEstimate(
            at: Date(), store: store, currentLocation: location, force: true, reloadWidgets: false
        ) : false
        guard canContinue() else { return }
        if let pendingRefresh,
           let route = SharedRouteCoordinator.current(), route.originId == pendingRefresh.originId,
           let origin = store.stations.first(where: { $0.id == route.originId }),
           let location, LocationGuidancePolicy.isUsable(location, maxAge: 180),
           refreshedEstimate || LocationGuidancePolicy.isAtStation(location, station: origin.location) {
            SharedWidgetReachabilityState.complete(pendingRefresh)
        }
        _ = NextPATCOTrainWidgetProvider().updateSharedTrip(store: store, location: location,
            specialSchedules: schedules, reloadWidgets: false)
        WidgetRefreshState.actionCompleted()
        WidgetRefreshState.recordLocationOutcome(available: location.map {
            LocationGuidancePolicy.isUsable($0, maxAge: 180)
        } ?? false)
        SharedWidgetDiagnostics.record("Widget refresh action completed", detail: "Shared departures published; reload deferred until action completion")
    }
}

struct RefreshPATCOWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh trains"
    static let description = IntentDescription("Refreshes departures and estimates whether you can catch the train.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        guard WidgetReachabilitySettings.isEnabled else { return .result() }
        guard let progress = WidgetActionProgress.begin(.refresh) else { return .result() }
        defer {
            WidgetActionProgress.finish(progress)
            SharedWidgetDiagnostics.recordReloadRequest(action: "Home Screen refresh")
            WidgetCenter.shared.reloadAllTimelines()
        }
        await WidgetInteractiveRefresh.perform(progress: progress)
        return .result()
    }
}

struct RefreshPATCOLockScreenWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh scheduled departures"
    static let description = IntentDescription("Reloads the shared route and scheduled departures on the Lock Screen.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        guard WidgetReachabilitySettings.isEnabled else { return .result() }
        SharedWidgetDiagnostics.record("Lock Screen refresh action started", detail: "Reading committed route and cached schedule")
        _ = await NextPATCOTrainWidgetProvider().specialSchedulesForDepartureWindow(from: Date(), force: true)
        _ = NextPATCOTrainWidgetProvider().updateSharedTrip(store: PATCOScheduleStore(),
            location: WidgetRefreshState.authorizedCachedLocation, reloadWidgets: false)
        WidgetRefreshState.actionCompleted()
        // WidgetKit reloads this widget automatically after the intent returns.
        LockScreenRefreshFeedback.recordCompletion()
        SharedWidgetDiagnostics.recordReloadRequest(action: "Lock Screen departure refresh",
            deliveryDescription: "Lock Screen automatic reload on intent completion")
        SharedWidgetDiagnostics.record("Lock Screen refresh action completed", detail: "Shared departures published; using automatic button reload without GPS or Maps")
        return .result()
    }
}

struct ReversePATCOWidgetRouteIntent: AppIntent {
    static let title: LocalizedStringResource = "Reverse route"
    static let description = IntentDescription("Swaps the departure and destination stations for both widgets.")
    static let openAppWhenRun = false

    @Parameter(title: "Displayed route revision")
    var expectedRevision: Int

    init() { expectedRevision = -1 }
    init(expectedRevision: Int) { self.expectedRevision = expectedRevision }

    func perform() async throws -> some IntentResult {
        guard let progress = WidgetActionProgress.begin(.reverse) else { return .result() }
        defer {
            WidgetActionProgress.finish(progress)
            SharedWidgetDiagnostics.recordReloadRequest(action: "Home Screen route reversal")
            WidgetCenter.shared.reloadAllTimelines()
        }
        let startedAt = Date()
        SharedWidgetDiagnostics.record("Widget reversal action started", detail: "Reading committed route")
        guard let previous = SharedRouteCoordinator.current(), previous.revision == expectedRevision else {
            SharedWidgetDiagnostics.record("Widget reversal skipped", detail: "Displayed route already changed; refreshing controls")
            return .result()
        }
        let store = PATCOScheduleStore()
        if
           let route = SharedRouteCoordinator.reverse(expectedRevision: previous.revision,
                selectionLocation: SharedCurrentLocationCache.location(), stations: store.stations),
           route.revision != previous.revision {
            SharedJourneyTracking.end()
            SharedWidgetDiagnostics.record("Widget route reversed", detail: "Revision \(route.revision): \(route.originId) to \(route.destinationId)")
        }
        let shared = NextPATCOTrainWidgetProvider().updateSharedTrip(store: store,
            location: WidgetRefreshState.authorizedCachedLocation, reloadWidgets: false)
        if let shared {
            _ = SharedRouteDefaults.recordHomeWidgetRoute(originId: shared.origin.id,
                                                          destinationId: shared.destination.id)
        }
        WidgetRefreshState.actionCompleted()
        SharedWidgetDiagnostics.record("Widget reversal action completed",
            detail: "Prepared in \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms; reload deferred until action completion")
        return .result()
    }
}

struct TogglePATCOReachabilityModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch travel mode"
    static let description = IntentDescription("Switches between driving and walking estimates to the station.")
    static let openAppWhenRun = false

    @Parameter(title: "Origin station")
    var originId: String

    @Parameter(title: "Current mode")
    var currentMode: String

    init() {}

    init(originId: String, currentMode: SharedReachabilityModeStore.Mode) {
        self.originId = originId
        self.currentMode = currentMode.rawValue
    }

    func perform() async throws -> some IntentResult {
        guard WidgetReachabilitySettings.isEnabled else { return .result() }
        guard let progress = WidgetActionProgress.begin(.mode) else { return .result() }
        defer {
            WidgetActionProgress.finish(progress)
            SharedWidgetDiagnostics.recordReloadRequest(action: "Home Screen travel mode change")
            WidgetCenter.shared.reloadAllTimelines()
        }
        let mode: SharedReachabilityModeStore.Mode = currentMode == SharedReachabilityModeStore.Mode.driving.rawValue
            ? .walking
            : .driving
        SharedReachabilityModeStore.save(mode: mode, originId: originId, isManual: true)
        SharedWidgetReachabilityState.requireRefresh(originId: originId, mode: mode)
        _ = NextPATCOTrainWidgetProvider().updateSharedTrip(store: PATCOScheduleStore(),
                                                          location: SharedCurrentLocationCache.location(), reloadWidgets: false)
        WidgetRefreshState.actionCompleted()
        await WidgetInteractiveRefresh.perform(progress: progress)
        return .result()
    }
}
