import SwiftUI
import Combine
import CoreLocation

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = HomeScreenModel()
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private let foregroundLocationRefreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private let alertRefreshTimer = Timer.publish(every: 120, on: .main, in: .common).autoconnect()
    private let specialScheduleRefreshTimer = Timer.publish(every: SpecialScheduleRefreshPolicy.todayAppInterval, on: .main, in: .common).autoconnect()

    private var lifecycleContent: some View {
        AnyView(HomeScreenContent(model: model))
            .onAppear {
                model.scenePhase = scenePhase
                SharedWidgetDiagnostics.record("App opened", detail: "Main screen appeared")
                model.route.applyDefaultsIfNeeded()
                model.locationProvider.onLocationUpdate = { [weak screenModel = model] location in
                    screenModel?.handleLocationUpdate(location)
                }
                DestinationRegionMonitor.shared.onArrival = { [weak screenModel = model] in
                    guard let screenModel else { return }
                    screenModel.locationProvider.endJourneyTracking(reloadWidgets: false)
                    screenModel.refreshDepartures()
                }
                model.applyCachedSpecialSchedules()
                model.prepareLocationAccess()
                model.refreshDepartures()
                Task {
                    await PATCOLiveActivityStarter.endExpiredActivities(tripProgress: model.tripProgress)
                    await model.refreshAll()
                }
            }
            .onReceive(refreshTimer) { _ in
                guard scenePhase == .active else { return }
                if model.route.estimatedStationAt.map({ Date().timeIntervalSince($0) > 15 }) ?? (model.locationProvider.currentLocation.map({
                    !CurrentStationEvidence.isPresenceReading($0, now: Date())
                        || (model.route.currentStationId != nil && model.route.stationAtCurrentLocation($0)?.id != model.route.currentStationId)
                }) ?? true) {
                    model.route.clearExpiredStationSelection()
                }
                if model.schedule.selectedScheduleDate < model.schedule.patcoCalendar.startOfDay(for: Date()) {
                    model.schedule.selectedScheduleDate = Date()
                }
                model.refreshDepartures()
                model.route.completeDestinationArrivalIfNeeded()
            }
            .onReceive(foregroundLocationRefreshTimer) { _ in
                guard scenePhase == .active else { return }
                // Continuous updates already supply arrival fixes; request only when they have gone stale.
                if let location = model.locationProvider.currentLocation,
                   LocationGuidancePolicy.isUsable(location, maxAge: 15) { return }
                guard model.locationProvider.authorizationStatus == .authorizedAlways
                        || model.locationProvider.authorizationStatus == .authorizedWhenInUse else {
                    return
                }
                model.locationProvider.requestLocation()
            }
            .onReceive(alertRefreshTimer) { _ in
                guard scenePhase == .active else { return }
                model.alertProvider.refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: PATCOLiveActivityStarter.activityDidChangeNotification)) { _ in
                model.liveTripRevision += 1
                if model.schedule.isViewingToday, scenePhase == .active {
                    model.route.applyNearestStation(model.locationProvider.currentLocation)
                    model.locationProvider.requestLocation()
                }
            }
            .onReceive(specialScheduleRefreshTimer) { _ in
                guard scenePhase == .active else { return }
                if model.schedule.isViewingToday {
                    model.schedule.specialSchedules.refresh()
                } else {
                    Task { await model.checkFutureSpecialSchedule(for: model.schedule.selectedScheduleDate) }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                model.handleScenePhaseChange(phase)
            }
            .onChange(of: model.schedule.store.stations) { _, _ in
                model.route.applyDefaultsIfNeeded()
                model.route.applyNearestStation(model.locationProvider.currentLocation)
                model.refreshDepartures()
            }
            .onChange(of: model.route.originId) { _, _ in
                model.showsEarlierDepartures = false
                model.refreshDepartures()
                model.resolvePendingDepartureDeepLink()
            }
            .onChange(of: model.route.destinationId) { _, _ in
                model.showsEarlierDepartures = false
                model.refreshDepartures()
                model.resolvePendingDepartureDeepLink()
            }
            .onChange(of: model.schedule.selectedScheduleDate) { _, _ in
                model.showsEarlierDepartures = false
                model.applyCachedSpecialSchedules()
                model.refreshDepartures()
                if model.schedule.isViewingToday,
                   (model.locationProvider.authorizationStatus == .authorizedAlways
                    || model.locationProvider.authorizationStatus == .authorizedWhenInUse) {
                    model.locationProvider.requestLocation()
                }
            }
            .task(id: model.schedule.patcoCalendar.startOfDay(for: model.schedule.selectedScheduleDate)) {
                guard !model.schedule.isViewingToday else {
                    model.schedule.isCheckingFutureSpecialSchedule = false
                    model.schedule.futureSpecialScheduleCheckFailed = false
                    return
                }
                await model.checkFutureSpecialSchedule(for: model.schedule.selectedScheduleDate)
            }
    }


    var body: some View {
        return AnyView(lifecycleContent)
            .onChange(of: model.locationProvider.authorizationStatus) { _, status in
                guard status != .authorizedAlways && status != .authorizedWhenInUse else { return }
                SharedCurrentLocationCache.clear()
                SharedTravelTimeEstimateCache.clear(mode: .walking)
                SharedTravelTimeEstimateCache.clear(mode: .driving)
                model.handleLocationUpdate(nil)
                model.requestWidgetReload(reason: "Location permission revoked", force: true)
            }
            .onChange(of: model.schedule.specialSchedules.resultRevision) { _, _ in
                if let specialSchedule = model.schedule.specialSchedules.specialSchedule {
                    SharedSpecialScheduleCache.save([specialSchedule])
                }
                model.applyCachedSpecialSchedules()
                model.refreshDepartures()
                model.requestWidgetReload(reason: "Special schedule changed")
            }
            .onOpenURL { url in
                model.handleDeepLink(url)
            }
            .alert("Enable Location?", isPresented: $model.isShowingLocationPermissionExplanation) {
                Button("Enable Location") {
                    model.hasSeenLocationPermissionExplanation = true
                    model.requestLocationAccess()
                }

                Button("Not Now", role: .cancel) {
                    model.hasSeenLocationPermissionExplanation = true
                }
            } message: {
                Text("Enable location to estimate which trains you can reach and identify when you’re at a PATCO station.")
            }
    }

}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}
