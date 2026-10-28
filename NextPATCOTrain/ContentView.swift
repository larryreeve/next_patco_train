import ActivityKit
import Combine
import CoreLocation
import MapKit
import SafariServices
import SwiftUI
import UIKit
import WebKit
import WidgetKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("hasSeenLocationPermissionExplanation") private var hasSeenLocationPermissionExplanation = false
    @AppStorage(SavedRoutesFeature.enabledKey) private var savedRouteShortcutsEnabled = true
    @State private var liveTripRevision = 0
    @StateObject private var savedRouteStore = SavedRouteStore()

    @StateObject private var scheduleStore = PATCOScheduleStore()
    @StateObject private var locationProvider = LocationProvider()
    @StateObject private var alertProvider = PATCOAlertProvider()
    @StateObject private var specialScheduleProvider = PATCOSpecialScheduleProvider()

    @State private var originId: Station.ID?
    @State private var destinationId: Station.ID?
    @State private var sharedRouteRevision: Int?
    @State private var selectedScheduleDate = Date()
    @State private var draftScheduleDate = Date()
    @State private var isShowingScheduleDatePicker = false
    @State private var departures: [Departure] = []
    @State private var sharedTrip: SharedTripState.Snapshot?
    @State private var nearestRouteStationName: String?
    @State private var isFindingNearestStation = false
    @State private var nearestStationMessage: String?
    @State private var currentStationId: Station.ID?
    @State private var currentStationName: String?
    @State private var arrivalAnnouncement: ArrivalAnnouncement?
    @State private var arrivalGate = DestinationArrivalGate()
    @State private var stationStopEvidence = CurrentStationEvidence()
    @State private var undergroundDepartureEvidence = UndergroundDepartureEvidence()
    @State private var estimatedStationAt: Date?
    @State private var completedArrivalLocation: CLLocation?
    @State private var temporaryRouteOriginalOriginId: Station.ID?
    @State private var temporaryRouteOriginalDestinationId: Station.ID?
    @State private var selectedDeparture: Departure?
    @State private var inAppBrowserURL: BrowserURL?
    @State private var isRouteExpanded = false
    @State private var isAlertsExpanded = false
    @State private var showsEarlierDepartures = false
    @State private var isRefreshing = false
    #if DEBUG
    @State private var isShowingAbout = ProcessInfo.processInfo.arguments.contains("-showInformation")
    #else
    @State private var isShowingAbout = false
    #endif
    @State private var isShowingLocationPermissionExplanation = false
    @State private var driveTimeEstimate: TravelTimeEstimate?
    @State private var walkingTimeEstimate: TravelTimeEstimate?
    @State private var walkingEstimateRequests = TravelEstimateRequestGate()
    @State private var drivingEstimateRequests = TravelEstimateRequestGate()
    @State private var walkingEstimateInFlight = false
    @State private var drivingEstimateInFlight = false
    @State private var reachabilityLocation: CLLocation?
    @State private var lastReachabilityLocationUpdate: Date?
    @State private var lastWidgetReachabilityReloadAt: Date?
    @State private var lastWidgetReloadRequestAt: Date?
    @State private var pendingWidgetReload: Task<Void, Never>?
    @State private var pendingWidgetReloadAt: Date?
    @State private var pendingDepartureDeepLink: DepartureDeepLink?
    @State private var isScheduleRecoveryRefreshing = false
    @State private var scheduleRecoveryMessage: String?
    @State private var isCheckingFutureSpecialSchedule = false
    @State private var futureSpecialScheduleCheckFailed = false

    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private let foregroundLocationRefreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private let alertRefreshTimer = Timer.publish(every: 120, on: .main, in: .common).autoconnect()
    private let specialScheduleRefreshTimer = Timer.publish(every: SpecialScheduleRefreshPolicy.todayAppInterval, on: .main, in: .common).autoconnect()
    private let reachabilityLocationMinInterval: TimeInterval = 30
    private let reachabilityLocationMinDistance: CLLocationDistance = 250
    private let widgetReachabilityReloadInterval: TimeInterval = 2 * 60
    private let widgetReloadMinInterval: TimeInterval = 60
    private let forcedWidgetReloadDedupeInterval: TimeInterval = 2
    private let hidesPromotionalDates = ProcessInfo.processInfo.arguments.contains("-promotionalScreenshots")
    private var patcoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }
    private var isViewingToday: Bool {
        patcoCalendar.isDate(selectedScheduleDate, inSameDayAs: Date())
    }
    private var lastSelectableScheduleDate: Date {
        max(patcoCalendar.startOfDay(for: Date()), scheduleStore.scheduleFeedEndDate ?? Date())
    }
    private var visibleAlerts: [VisibleAlert] {
        alertProvider.alerts.compactMap(VisibleAlert.init)
    }
    private var isUsingCachedSchedule: Bool {
        specialScheduleProvider.errorMessage != nil && scheduleStore.activeSpecialSchedule != nil
    }
    private var isRefreshInProgress: Bool {
        isRefreshing || alertProvider.isLoading || specialScheduleProvider.isLoading
    }
    private var isAtDepartureStation: Bool {
        isAtDepartureStation(at: Date())
    }

    private func isAtDepartureStation(at now: Date) -> Bool {
        guard let origin = visibleDepartures(at: now).first?.origin,
              let location = usableReachabilityLocation(at: now) else {
            return false
        }
        return LocationGuidancePolicy.isAtStation(location, station: origin.location, now: now)
    }
    private var usableReachabilityLocation: CLLocation? {
        usableReachabilityLocation(at: Date())
    }

    private func usableReachabilityLocation(at now: Date) -> CLLocation? {
        guard locationProvider.authorizationStatus == .authorizedAlways
                || locationProvider.authorizationStatus == .authorizedWhenInUse,
              let location = sharedTrip?.guidance?.location.location ?? (sharedTrip == nil ? reachabilityLocation : nil),
              LocationGuidancePolicy.isUsable(location, maxAge: 180, now: now) else { return nil }
        return location
    }
    private var reachabilityGuidance: (title: String, detail: String?, systemImage: String)? {
        reachabilityGuidance(at: Date())
    }

    private func visibleDepartures(at now: Date) -> [Departure] {
        EarlierDeparturesPolicy.visibleDepartures(departures, isViewingToday: isViewingToday, now: now)
    }

    private func reachabilityGuidance(at now: Date) -> (title: String, detail: String?, systemImage: String)? {
        guard isViewingToday,
              let departure = visibleDepartures(at: now).first else {
            return nil
        }
        let origin = departure.origin

        // This explains the displayed route, not the latest GPS fix. Keep it
        // until the temporary route is restored, including underground gaps.
        if isUsingTemporaryStationRoute {
            return ("Showing departures from \(origin.name) to \(departure.destination.name) based on your location.", nil, "tram.fill")
        }
        if isAtDepartureStation(at: now) { return nil }

        if currentReachabilityMode(at: now) == .driving {
            let hasEstimate = sharedTrip?.guidance?.hasFreshMapsEstimate(at: now)
                ?? usableReachabilityLocation(at: now).map {
                    SharedTravelTimeEstimateCache.estimate(mode: .driving, origin: origin, currentLocation: $0) != nil
                } ?? false
            if !hasEstimate {
                return (drivingEstimateInFlight ? "Calculating driving time…" : "Driving estimate unavailable", nil, "car.fill")
            }
        }

        guard let status = reachabilityStatus(for: departure, enforceOneHourLimit: true, at: now) else {
            return nil
        }
        let compactOriginName = origin.name.replacingOccurrences(of: " and ", with: " & ")
        guard let arrivalSummary = status.stationArrivalSummary(at: compactOriginName) else {
            return nil
        }
        let systemImage = arrivalSummary.mode == .driving ? "car.fill" : "figure.walk"
        let cachedRoute = usableReachabilityLocation(at: now).flatMap {
            SharedTravelTimeEstimateCache.estimate(mode: arrivalSummary.mode == .walking ? .walking : .driving,
                                                   origin: origin, currentLocation: $0)
        } != nil
        let hasRoute = sharedTrip?.guidance.map { $0.hasFreshMapsEstimate(at: now) } ?? cachedRoute
        let detail = "\(arrivalSummary.arrivalTime) if you leave now"
            + (hasRoute ? "" : " (straight-line estimate)")
        return ("Arrive at \(compactOriginName)", detail, systemImage)
    }
    private var currentReachabilityMode: StationTravelMode? {
        currentReachabilityMode(at: Date())
    }

    private func currentReachabilityMode(at now: Date) -> StationTravelMode? {
        let departures = visibleDepartures(at: now)
        if isViewingToday, let sharedTrip {
            guard !isAtDepartureStation(at: now), usableReachabilityLocation(at: now) != nil,
                  let mode = sharedTrip.guidance?.mode else { return nil }
            return StationTravelMode(mode)
        }
        guard isViewingToday,
              let currentLocation = usableReachabilityLocation(at: now),
              let firstDeparture = departures.first else {
            return nil
        }

        guard !isAtDepartureStation(at: now) else { return nil }

        let distanceToStation = currentLocation.distance(from: firstDeparture.origin.location)
        guard distanceToStation <= StationTravelMode.reachabilityMaxDistanceMeters else {
            return nil
        }

        guard distanceToStation > StationTravelMode.atStationMeters else {
            return nil
        }

        let minutesUntilDeparture = Int(floor(firstDeparture.departureDate.timeIntervalSince(now) / 60))
        guard let sharedMode = SharedReachabilityModeStore.resolve(
            originId: firstDeparture.origin.id,
            distanceToStation: distanceToStation,
            minutesUntilDeparture: minutesUntilDeparture,
            defaultsToWalking: firstDeparture.origin.defaultsToWalkingForReachability,
            walkingEstimate: SharedTravelTimeEstimateCache.estimate(mode: .walking, origin: firstDeparture.origin, currentLocation: currentLocation), now: now
        ) else {
            return nil
        }

        return StationTravelMode(sharedMode)
    }

    private var sheetContent: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color.patcoWine, Color.patcoCharcoal, Color.patcoRail], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                ScrollView {
                  VStack(spacing: 10) {
                    header
                        .padding(.top, 2)
                    liveTripShortcut
                    if currentStationName != nil {
                        currentStationPanel
                    }
                    if let arrivalAnnouncement {
                        arrivalAnnouncementBanner(arrivalAnnouncement)
                            .transition(.opacity)
                    }
                    statusBanners
                    if !visibleAlerts.isEmpty {
                        alertBox
                    }
                    departureList
                }
                .padding()
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollIndicators(.visible)
                .refreshable {
                    await refreshAll(forceSpecialScheduleRefresh: true)
                }

            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        VStack(spacing: 2) {
                            HStack(spacing: 4) {
                                Image(systemName: "tram.fill")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.patcoGold)

                                Text("Next")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.white)

                                Text("PATCO Train")
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)

                            Capsule()
                                .fill(Color.patcoGold.opacity(0.82))
                                .frame(height: 1)
                        }
                        .frame(width: 220)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Next PATCO Train")
                        .accessibilityAddTraits(.isHeader)

                        if !hidesPromotionalDates {
                            Button {
                                draftScheduleDate = selectedScheduleDate
                                isShowingScheduleDatePicker = true
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "calendar")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.patcoGold)

                                    Text(selectedScheduleDateHeaderText)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)

                                    Image(systemName: "chevron.down")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white.opacity(0.78))
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 34)
                                .background(.white.opacity(0.15), in: Capsule())
                                .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .frame(minHeight: 44)
                            .accessibilityLabel("Choose departure date, \(selectedScheduleDateHeaderText)")
                        }
                    }
                    .offset(y: 2)
                }

                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarTrailing) {
                        informationButton
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        informationButton
                    }
                }
            }
            .sheet(item: $selectedDeparture) { departure in
                TripDetailView(departure: departure, stops: tripStops(for: departure),
                    locationProvider: locationProvider,
                    catchStatusAt: { date in
                    catchStatus(for: departure, at: date)
                }, onArrived: { confirmTripArrival(departure) }) {
                    selectedDeparture = nil
                }
                .presentationDetents([.large])
            }
            .sheet(isPresented: $isShowingScheduleDatePicker) {
                scheduleDatePickerSheet
            }
            .sheet(isPresented: $isShowingAbout) {
                AboutView(
                    stations: scheduleStore.stations,
                    locationAuthorizationStatus: locationProvider.authorizationStatus,
                    scheduleFeedEndDate: scheduleStore.scheduleFeedEndDate,
                    scheduleFeedVersion: scheduleStore.scheduleFeedVersion,
                    scheduleFeedLastCheckedAt: scheduleStore.scheduleFeedLastCheckedAt,
                    scheduleFeedLastUpdatedAt: scheduleStore.scheduleFeedLastUpdatedAt,
                    scheduleFeedPreviousVersion: scheduleStore.scheduleFeedPreviousVersion,
                    onRequestLocation: requestLocationAccess,
                    onReloadSchedule: forceGTFSUpdate,
                    onOpenURL: { url in
                        isShowingAbout = false
                        inAppBrowserURL = BrowserURL(url: url)
                    }
                )
                    .presentationDetents([.fraction(0.75)])
            }
            .sheet(item: $inAppBrowserURL) { browserURL in
                SafariView(url: browserURL.url)
                    .ignoresSafeArea()
                    .interactiveDismissDisabled()
                    .presentationDragIndicator(.hidden)
            }
        }
    }

    private var lifecycleContent: some View {
        AnyView(sheetContent)
            .onAppear {
                SharedWidgetDiagnostics.record("App opened", detail: "Main screen appeared")
                applyDefaultsIfNeeded()
                locationProvider.onLocationUpdate = { location in
                    handleLocationUpdate(location)
                }
                DestinationRegionMonitor.shared.onArrival = {
                    locationProvider.endJourneyTracking(reloadWidgets: false)
                    refreshDepartures()
                }
                applyCachedSpecialSchedules()
                prepareLocationAccess()
                refreshDepartures()
                Task {
                    await PATCOLiveActivityStarter.endExpiredActivities()
                    await refreshAll()
                }
            }
            .onReceive(refreshTimer) { _ in
                guard scenePhase == .active else { return }
                if estimatedStationAt.map({ Date().timeIntervalSince($0) > 15 }) ?? (locationProvider.currentLocation.map({
                    !CurrentStationEvidence.isPresenceReading($0, now: Date())
                        || (currentStationId != nil && stationAtCurrentLocation($0)?.id != currentStationId)
                }) ?? true) {
                    clearExpiredStationSelection()
                }
                if selectedScheduleDate < patcoCalendar.startOfDay(for: Date()) {
                    selectedScheduleDate = Date()
                }
                refreshDepartures()
                completeDestinationArrivalIfNeeded()
            }
            .onReceive(foregroundLocationRefreshTimer) { _ in
                guard scenePhase == .active else { return }
                // Continuous updates already supply arrival fixes; request only when they have gone stale.
                if let location = locationProvider.currentLocation,
                   LocationGuidancePolicy.isUsable(location, maxAge: 15) { return }
                guard locationProvider.authorizationStatus == .authorizedAlways
                        || locationProvider.authorizationStatus == .authorizedWhenInUse else {
                    return
                }
                locationProvider.requestLocation()
            }
            .onReceive(alertRefreshTimer) { _ in
                guard scenePhase == .active else { return }
                alertProvider.refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: PATCOLiveActivityStarter.activityDidChangeNotification)) { _ in
                liveTripRevision += 1
                if isViewingToday, scenePhase == .active {
                    applyNearestStation(locationProvider.currentLocation)
                    locationProvider.requestLocation()
                }
            }
            .onReceive(specialScheduleRefreshTimer) { _ in
                guard scenePhase == .active else { return }
                if isViewingToday {
                    specialScheduleProvider.refresh()
                } else {
                    Task { await checkFutureSpecialSchedule(for: selectedScheduleDate) }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                handleScenePhaseChange(phase)
            }
            .onChange(of: scheduleStore.stations) { _, _ in
                applyDefaultsIfNeeded()
                applyNearestStation(locationProvider.currentLocation)
                refreshDepartures()
            }
            .onChange(of: originId) { _, _ in
                showsEarlierDepartures = false
                refreshDepartures()
                resolvePendingDepartureDeepLink()
            }
            .onChange(of: destinationId) { _, _ in
                showsEarlierDepartures = false
                refreshDepartures()
                resolvePendingDepartureDeepLink()
            }
            .onChange(of: selectedScheduleDate) { _, _ in
                showsEarlierDepartures = false
                applyCachedSpecialSchedules()
                refreshDepartures()
                if isViewingToday,
                   (locationProvider.authorizationStatus == .authorizedAlways
                    || locationProvider.authorizationStatus == .authorizedWhenInUse) {
                    locationProvider.requestLocation()
                }
            }
            .task(id: patcoCalendar.startOfDay(for: selectedScheduleDate)) {
                guard !isViewingToday else {
                    isCheckingFutureSpecialSchedule = false
                    futureSpecialScheduleCheckFailed = false
                    return
                }
                await checkFutureSpecialSchedule(for: selectedScheduleDate)
            }
    }

    var body: some View {
        AnyView(lifecycleContent)
            .onChange(of: locationProvider.authorizationStatus) { _, status in
                guard status != .authorizedAlways && status != .authorizedWhenInUse else { return }
                SharedCurrentLocationCache.clear()
                SharedTravelTimeEstimateCache.clear(mode: .walking)
                SharedTravelTimeEstimateCache.clear(mode: .driving)
                handleLocationUpdate(nil)
                requestWidgetReload(reason: "Location permission revoked", force: true)
            }
            .onChange(of: specialScheduleProvider.resultRevision) { _, _ in
                if let specialSchedule = specialScheduleProvider.specialSchedule {
                    SharedSpecialScheduleCache.save([specialSchedule])
                }
                applyCachedSpecialSchedules()
                refreshDepartures()
                requestWidgetReload(reason: "Special schedule changed")
            }
            .onOpenURL { url in
                handleDeepLink(url)
            }
            .alert("Enable Location?", isPresented: $isShowingLocationPermissionExplanation) {
                Button("Enable Location") {
                    hasSeenLocationPermissionExplanation = true
                    requestLocationAccess()
                }

                Button("Not Now", role: .cancel) {
                    hasSeenLocationPermissionExplanation = true
                }
            } message: {
                Text("Enable location to estimate which trains you can reach and identify when you’re at a PATCO station.")
            }
    }

    private func prepareLocationAccess() {
        DestinationRegionMonitor.shared.start(requestAuthorization: true)
        switch locationProvider.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            hasSeenLocationPermissionExplanation = true
            locationProvider.startUpdatingLocation()
        case .notDetermined:
            isShowingLocationPermissionExplanation = !hasSeenLocationPermissionExplanation
        case .denied, .restricted:
            hasSeenLocationPermissionExplanation = true
        @unknown default:
            break
        }
    }

    private func startLocationUpdatesIfAuthorized() {
        guard locationProvider.authorizationStatus == .authorizedAlways
                || locationProvider.authorizationStatus == .authorizedWhenInUse else {
            return
        }

        locationProvider.startUpdatingLocation()
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        locationProvider.isInBackground = phase != .active
        if phase == .active {
            // Reopening the app at the return origin is a new opportunity to track a trip.
            completedArrivalLocation = nil
            startLocationUpdatesIfAuthorized()
            refreshForForeground()
            publishAppRoute()
            requestWidgetReload(reason: "App route takes priority", force: true)
        } else {
            locationProvider.stopUpdatingLocation()
            publishAppRoute()
        }
    }

    private func requestLocationAccess() {
        locationProvider.startUpdatingLocation()
    }

    private func requestWidgetReload(reason: String, force: Bool = false) {
        guard scenePhase == .active || force else { return }
        let now = Date()
        let minInterval = force ? forcedWidgetReloadDedupeInterval : widgetReloadMinInterval
        if let lastWidgetReloadRequestAt,
           now.timeIntervalSince(lastWidgetReloadRequestAt) < minInterval {
            let deadline = lastWidgetReloadRequestAt.addingTimeInterval(minInterval)
            if let pendingWidgetReloadAt, pendingWidgetReloadAt <= deadline { return }
            pendingWidgetReload?.cancel()
            pendingWidgetReloadAt = deadline
            let delay = minInterval - now.timeIntervalSince(lastWidgetReloadRequestAt)
            pendingWidgetReload = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64((delay + 0.05) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                pendingWidgetReloadAt = nil
                requestWidgetReload(reason: reason, force: force)
            }
            SharedWidgetDiagnostics.record(
                "App widget reload skipped",
                detail: "\(reason) throttled"
            )
            return
        }

        pendingWidgetReload?.cancel()
        pendingWidgetReload = nil
        pendingWidgetReloadAt = nil
        lastWidgetReloadRequestAt = now
        // Publish a matching snapshot before asking another process to render this revision.
        if let route = SharedRouteCoordinator.current() {
            let dates = (-1...1).compactMap { patcoCalendar.date(byAdding: .day, value: $0, to: now) }
            _ = SharedTripState.update(store: scheduleStore, routeRevision: route.revision,
                location: locationProvider.currentLocation,
                locationAllowed: LocationInteractionPolicy.isAuthorized(locationProvider.authorizationStatus),
                specialSchedules: SharedSpecialScheduleCache.schedules(matching: dates, calendar: patcoCalendar))
        }
        SharedWidgetDiagnostics.record("App requested widget reload", detail: reason)
        WidgetCenter.shared.reloadAllTimelines()
    }

    @MainActor
    private func forceGTFSUpdate(
        progress: @escaping @MainActor (PATCOGTFSUpdateService.UpdateStage) -> Void
    ) async -> String {
        guard let currentFeed = scheduleStore.baseScheduleFeed else {
            return "Unable to refresh the schedule because the current schedule could not be loaded."
        }

        let result = await PATCOGTFSUpdateService.shared.updateIfNeeded(
            currentFeed: currentFeed,
            force: true,
            progress: progress
        )
        switch result {
        case .updated:
            progress(.reloading)
            scheduleStore.load()
            applyCachedSpecialSchedules()
            applyDefaultsIfNeeded()
            refreshDepartures()
            requestWidgetReload(reason: "Schedule updated", force: true)
            return "Schedule updated."
        case .current:
            // A successful unchanged check still updates the cached check timestamp.
            scheduleStore.load()
            applyCachedSpecialSchedules()
            refreshDepartures()
            return "Current schedule is the latest."
        case .notNeeded:
            return "Current schedule is the latest."
        case .failed:
            return "Unable to refresh the schedule. Try again."
        }
    }

    private func refreshForForeground() {
        SharedWidgetDiagnostics.record("App foregrounded", detail: "Refreshing app data")
        Task {
            await PATCOLiveActivityStarter.endExpiredActivities()
            await refreshAll()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy) {
                    isRouteExpanded.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    GeometryReader { geometry in
                        Text(routeSummary)
                            .font(.system(size: routeSummaryFontSize(for: geometry.size.width), weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.95)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 28)

                    if let routeDetailSummary {
                        Text(routeDetailSummary)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.74))
                            .lineLimit(dynamicTypeSize >= .xxLarge ? 2 : 1)
                            .minimumScaleFactor(0.75)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(routeSummary)
            .accessibilityValue(isRouteExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isRouteExpanded ? "Hide route controls" : "Change route")

            HStack(alignment: .center, spacing: 4) {
                if SavedRoutesFeature.isAvailable && savedRouteShortcutsEnabled {
                    SavedRouteShortcuts(store: savedRouteStore, stations: scheduleStore.stations,
                                        originId: originId, destinationId: destinationId) { route in
                        originId = route.originId
                        destinationId = route.destinationId
                        routeSelectionChanged(saveRoute: true)
                    }
                } else {
                    Spacer(minLength: 0)
                }

                Button {
                    swapStations(saveRoute: true)
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.14), in: Circle())
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(originId == nil || destinationId == nil || originId == destinationId)
                .accessibilityLabel("Reverse route")
                .help("Reverse route")

                Button {
                    withAnimation(.snappy) {
                        isRouteExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isRouteExpanded ? "checkmark" : "pencil")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.14), in: Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRouteExpanded ? "Hide route controls" : "Change route")
                .help(isRouteExpanded ? "Done editing route" : "Change route")
            }

            if isRouteExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        stationPicker(title: "From", selection: $originId) {
                            routeSelectionChanged(saveRoute: true)
                        }
                        stationPicker(title: "To", selection: $destinationId) {
                            routeSelectionChanged(saveRoute: true, destinationOnly: true)
                        }
                    }

                    if currentStationName == nil {
                        locationControl
                    }
                }
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
    }

    private var informationButton: some View {
        Button {
            isShowingAbout = true
        } label: {
            Image(systemName: "info.circle")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.patcoGold)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.14), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Information about Next PATCO Train")
    }

    private func routeSummaryFontSize(for availableWidth: CGFloat) -> CGFloat {
        let maximumFontSize: CGFloat = 24
        let minimumFontSize: CGFloat = 17
        let font = UIFont.systemFont(ofSize: maximumFontSize, weight: .bold)
        let measuredWidth = (routeSummary as NSString).size(withAttributes: [.font: font]).width

        guard measuredWidth > 0 else { return maximumFontSize }
        let fittedSize = maximumFontSize * max(availableWidth - 2, 1) / measuredWidth
        return max(minimumFontSize, min(maximumFontSize, fittedSize))
    }

    @ViewBuilder
    private var currentStationPanel: some View {
        // Keep the station controls tied to the departures being displayed, even
        // when a poor GPS fix temporarily clears current-location confirmation.
        if let panelStation = selectedStation(isUsingTemporaryStationRoute ? originId : currentStationId),
           isUsingTemporaryStationRoute || panelStation.id != originId {
            let currentStationId = panelStation.id
            let currentStationName = panelStation.name
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.patcoGold)
                        .frame(width: 32, height: 32)
                        .background(Color.black.opacity(0.18), in: Circle())

                    VStack(alignment: .leading, spacing: 1) {
                        Text(estimatedStationAt != nil ? "Estimated station departures" : (isUsingTemporaryStationRoute ? "Station departures" : "Current station"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.58))

                        Text(currentStationName)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Button {
                        Task {
                            await refreshAll()
                        }
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.caption.weight(.bold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.72))
                    .accessibilityLabel("Refresh current station")
                }

                if isUsingTemporaryStationRoute {
                    Button {
                        SharedRouteDefaults.saveManualStationSelection(stationId: currentStationId)
                        restoreRouteAfterLeavingStation()
                    } label: {
                        Label("Return to \(savedStartingStationName) departures", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.14), in: Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Restores departures from your saved starting station")
                } else if currentStationId != originId && currentStationId != destinationId {
                    Button {
                        useCurrentStationAsTemporaryOrigin(currentStationId)
                    } label: {
                        Label("Show departures from \(currentStationName)", systemImage: "tram.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.14), in: Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Temporarily uses this station without changing your saved route")
                } else if currentStationId == destinationId, let originId, let originStation = selectedStation(originId) {
                    Button {
                        useCurrentStationAsTemporaryOrigin(currentStationId, destinationId: originId)
                    } label: {
                        Label("Show departures to \(originStation.name)", systemImage: "arrow.left.arrow.right")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.14), in: Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Temporarily shows return-direction departures without changing your saved route")
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
        }
    }

    private var locationControl: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    await findNearestStation()
                }
            } label: {
                Group {
                    if isFindingNearestStation { ProgressView().tint(Color.patcoCharcoal) }
                    else { Image(systemName: "location.fill").font(.subheadline) }
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.patcoGold)
            .foregroundStyle(Color.patcoCharcoal)
            .accessibilityLabel("Find nearest station")
            .disabled(isFindingNearestStation || !isViewingToday)

            locationSummary

            Spacer(minLength: 8)
        }
    }

    @ViewBuilder
    private var locationSummary: some View {
        if let nearestStationMessage {
            Text(nearestStationMessage)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.78))
        } else if let nearestRouteStationName {
            VStack(alignment: .leading, spacing: 2) {
                Label("Nearest route station: \(nearestRouteStationName)", systemImage: "mappin.and.ellipse")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)

                Text("Route direction is based on nearest route station")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
            }
        } else if let currentStationName {
            VStack(alignment: .leading, spacing: 2) {
                Label("Current station: \(currentStationName)", systemImage: "mappin.and.ellipse")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)

                Text("Pick a route to orient departures")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
            }
        } else if let message = locationProvider.errorMessage {
            Label(message, systemImage: "location.slash")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
        } else {
            Text("Use current location")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
        }
    }

    @MainActor
    private func findNearestStation() async {
        guard !isFindingNearestStation, isViewingToday else { return }
        publishAppRoute()
        guard let previous = SharedRouteCoordinator.current() else { return }
        isFindingNearestStation = true
        nearestStationMessage = nil
        defer { isFindingNearestStation = false }
        let requestedAt = Date()
        locationProvider.requestLocation()
        var request = NearestStationSelectionRequest(expectedRevision: previous.revision, requestedAt: requestedAt)
        while true {
            let outcome = request.poll(location: locationProvider.currentLocation,
                authorization: locationProvider.authorizationStatus, isForeground: scenePhase == .active,
                isViewingToday: isViewingToday, cancelled: Task.isCancelled, stations: scheduleStore.stations)
            switch outcome {
            case .waiting:
                break
            case .cancelled:
                return
            case .denied, .timedOut, .routeChanged, .staleLocation, .inaccurateLocation,
                 .ambiguousStation, .invalidLocation, .stationsUnavailable:
                nearestStationMessage = outcome.failureMessage
                SharedWidgetDiagnostics.record("Nearest station selection failed", detail: outcome.failureMessage ?? "Unknown reason")
                return
            case .selected(let selected):
                if let location = locationProvider.currentLocation {
                    SharedWidgetDiagnostics.record("Nearest station selected", detail:
                        "\(request.usedRecentLocationFallback ? "Recent reading fallback" : "Fresh reading"); "
                        + "age \(Int(Date().timeIntervalSince(location.timestamp))) sec; accuracy \(Int(location.horizontalAccuracy)) m")
                }
                SharedRouteDefaults.clearJourneyDirection()
                SharedRouteDefaults.clearManualStationSelection()
                publishAppRoute()
                completedArrivalLocation = nil
                nearestRouteStationName = selectedStation(selected.originId)?.name
                updateReachabilityLocationIfNeeded(locationProvider.currentLocation, force: true)
                refreshDepartures()
                requestWidgetReload(reason: "Nearest station selected", force: true)
                return
            }
            do { try await Task.sleep(nanoseconds: 200_000_000) }
            catch { return }
        }
    }

    @ViewBuilder
    private var statusBanners: some View {
        if let selectedSpecialSchedule = scheduleStore.specialSchedule(on: departures.first?.serviceDate ?? selectedScheduleDate) {
            specialScheduleBanner(selectedSpecialSchedule)
        }
    }

    private func specialScheduleBanner(_ schedule: ActiveSpecialSchedule) -> some View {
        Button {
            inAppBrowserURL = BrowserURL(url: schedule.sourceURL)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.patcoGold)

                VStack(alignment: .leading, spacing: 1) {
                    Text(schedule.hasUnconfirmedTimes ? "DST times unconfirmed" : "Special schedule applied")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    if let subtitle = specialScheduleSubtitle(for: schedule) {
                        Text(subtitle)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 3) {
                    Text("View PDF")
                        .font(.caption.weight(.bold))

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                }
            }
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(Color.patcoGold.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.patcoGold.opacity(0.45), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the source PDF in the app")
    }

    private func specialScheduleSubtitle(for schedule: ActiveSpecialSchedule) -> String? {
        if schedule.hasUnconfirmedTimes { return "Ambiguous trips hidden; check PDF" }
        let components = schedule.title.split(separator: "|", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if components.count == 2, !components[1].isEmpty {
            let detail = components[1]
            if detail.count <= 36 {
                return detail
            }
            if let range = detail.range(of: " for ", options: .caseInsensitive),
               range.lowerBound > detail.startIndex {
                let summary = String(detail[..<range.lowerBound])
                if summary.count <= 36 {
                    return summary
                }
            }
        }

        if patcoCalendar.isDateInToday(schedule.serviceDate) {
            return nil
        }
        return "Applies \(schedule.serviceDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))"
    }

    private func stationPicker(title: String, selection: Binding<Station.ID?>, onSelect: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.62))

            Menu {
                ForEach(scheduleStore.stations) { station in
                    Button(station.name) {
                        selection.wrappedValue = station.id
                        onSelect()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedStation(selection.wrappedValue)?.name ?? "Select station")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.58))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    private func departuresHeader(at now: Date) -> some View {
        let currentReachabilityMode = currentReachabilityMode(at: now)
        let reachabilityGuidance = reachabilityGuidance(at: now)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    departuresHeading

                    Text(scheduleStore.scheduleFeedLastCheckedAt.map {
                        "Schedule checked \($0.formatted(date: .abbreviated, time: .shortened))"
                    } ?? "Using bundled schedule")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.patcoCharcoal.opacity(0.52))
                        .lineLimit(1)
                        .padding(.leading, 2)
                }
                Spacer(minLength: 2)
                departureActions
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let currentReachabilityMode,
               let reachabilityGuidance,
               !isUsingTemporaryStationRoute,
               !isAtDepartureStation(at: now) {
                HStack(alignment: .top, spacing: 8) {
                    travelModePicker(selected: currentReachabilityMode)
                        .fixedSize(horizontal: true, vertical: false)

                    Rectangle()
                        .fill(Color.patcoCharcoal.opacity(0.16))
                        .frame(width: 1, height: 34)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(reachabilityGuidance.title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.patcoCharcoal.opacity(0.74))

                        if let detail = reachabilityGuidance.detail {
                            Text(detail)
                                .font(.caption2.weight(.medium))
                                .lineSpacing(-1)
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.78))
                        }

                        if let reachabilityLocation,
                           Date().timeIntervalSince(reachabilityLocation.timestamp) > 2 * 60 {
                            Text(locationFreshnessText(for: reachabilityLocation.timestamp))
                                .font(.caption2)
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.52))
                        }
                    }
                    .multilineTextAlignment(.leading)
                    .padding(.top, 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var departuresHeading: some View {
        Text("Scheduled Departures")
            .font(.headline.weight(.semibold))
            .foregroundStyle(Color.patcoCharcoal)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .allowsTightening(true)
    }

    private var departureActions: some View {
        HStack(spacing: 2) {
            Button {
                if let origin = selectedStation(originId) {
                    openDirections(to: origin, mode: currentReachabilityMode ?? .walking)
                }
            } label: {
                departureActionLabel(image: "map.fill", title: "Map")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.patcoCharcoal.opacity(0.58))
            .disabled(locationProvider.currentLocation == nil || selectedStation(originId) == nil)
            .accessibilityLabel("Open directions to the departure station")

            Button {
                Task {
                    await refreshAll(forceSpecialScheduleRefresh: true)
                }
            } label: {
                departureActionLabel(
                    image: isRefreshInProgress ? "hourglass" : "arrow.clockwise",
                    title: "Refresh"
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.patcoCharcoal.opacity(0.58))
            .disabled(isRefreshInProgress)
            .accessibilityLabel("Refresh departures")
        }
    }

    private func departureActionLabel(image: String, title: String) -> some View {
        Image(systemName: image)
            .font(.subheadline.weight(.semibold))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(title)
            .help(title)
    }

    private func travelModePicker(selected: StationTravelMode) -> some View {
        return Group {
            HStack(spacing: 0) {
                travelModeControl(label: "Car", image: "car.fill", mode: .driving, selected: selected)
                travelModeControl(label: "Walk", image: "figure.walk", mode: .walking, selected: selected)
            }
            .background(Color.patcoCharcoal.opacity(0.10), in: Capsule())
        }
    }

    @ViewBuilder
    private func travelModeControl(label: String, image: String, mode: StationTravelMode, selected: StationTravelMode) -> some View {
        let manual = originId.map { SharedReachabilityModeStore.isManual(originId: $0) } ?? false
        let controlLabel = Label(label, systemImage: image)
                .font(.caption.weight(.bold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .foregroundStyle(mode == selected ? Color.white : Color.patcoCharcoal.opacity(0.88))
                .background(mode == selected ? Color.patcoWine : .clear, in: Capsule())
        if mode == selected {
            Menu {
                Text(manual ? "Manually selected" : "Automatically selected")
                Button("Use Automatic", systemImage: "arrow.triangle.2.circlepath") {
                    guard let originId else { return }
                    SharedReachabilityModeStore.useAutomatic(originId: originId)
                    refreshReachabilityModeSelection()
                }
                Button("Use \(label) manually", systemImage: image) {
                    setReachabilityMode(mode)
                }
            } label: {
                controlLabel
            }
            .accessibilityLabel("\(label) travel mode settings")
            .accessibilityValue(manual ? "Manual" : "Automatic")
            .accessibilityAddTraits(.isSelected)
        } else {
            Button {
                setReachabilityMode(mode)
            } label: {
                controlLabel
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use \(label.lowercased()) reachability")
        }
    }

    private var reachabilityUnavailableMessage: String? {
        guard isViewingToday, usableReachabilityLocation == nil else { return nil }

        switch locationProvider.authorizationStatus {
        case .notDetermined, .denied, .restricted:
            return "Location unavailable. Enable Location Services to see which train you can make."
        default:
            return "Tap Refresh to see trains you can catch."
        }
    }

    private var reachabilityLocationActionTitle: String {
        switch locationProvider.authorizationStatus {
        case .denied, .restricted:
            return "Open Settings"
        case .notDetermined:
            return "Enable Location"
        default:
            return "Refresh Location"
        }
    }

    private func performReachabilityLocationAction() {
        switch locationProvider.authorizationStatus {
        case .denied, .restricted:
            guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(settingsURL)
        case .notDetermined:
            requestLocationAccess()
        default:
            locationProvider.requestLocation()
        }
    }

    private var departureList: some View {
        let now = Date()
        let departures = visibleDepartures(at: now)
        let reachabilityGuidance = reachabilityGuidance(at: now)
        let currentReachabilityMode = currentReachabilityMode(at: now)
        return VStack(alignment: .leading, spacing: 8) {
            departuresHeader(at: now)

            if !isViewingToday {
                Text(isCheckingFutureSpecialSchedule
                     ? "Checking for a special schedule..."
                     : futureSpecialScheduleCheckFailed
                        ? "Could not check for a special schedule. Check PATCO before traveling."
                        : "Future times may change. Check PATCO before traveling.")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.52))
            }

            if let reachabilityGuidance {
                if isUsingTemporaryStationRoute {
                    Label(reachabilityGuidance.title, systemImage: reachabilityGuidance.systemImage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(red: 0.05, green: 0.38, blue: 0.20))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 0.72, green: 0.92, blue: 0.78).opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                } else if currentReachabilityMode == nil {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(reachabilityGuidance.title, systemImage: reachabilityGuidance.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.patcoCharcoal.opacity(0.74))

                        if let detail = reachabilityGuidance.detail {
                            Text(detail)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.70))
                        }

                        if let reachabilityLocation,
                           Date().timeIntervalSince(reachabilityLocation.timestamp) > 2 * 60 {
                            Text(locationFreshnessText(for: reachabilityLocation.timestamp))
                                .font(.caption2)
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.58))
                        }
                    }
                }
            } else if let reachabilityUnavailableMessage {
                VStack(alignment: .leading, spacing: 7) {
                    Label(reachabilityUnavailableMessage, systemImage: "location")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)

                    if locationProvider.authorizationStatus != .authorizedAlways
                        && locationProvider.authorizationStatus != .authorizedWhenInUse {
                        Button(reachabilityLocationActionTitle) {
                            performReachabilityLocationAction()
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(Color.patcoWine)
                    }
                }
            }

            if let error = scheduleStore.loadError {
                ContentUnavailableView {
                    Label("Schedule unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    scheduleRefreshButton
                }
            } else if scheduleStore.feed?.isExpired() == true {
                ContentUnavailableView {
                    Label("Schedule update needed", systemImage: "calendar.badge.exclamationmark")
                } description: {
                    Text("The current PATCO schedule has expired and an updated schedule could not be downloaded.")
                } actions: {
                    scheduleRefreshButton
                }
            } else if departures.isEmpty {
                ContentUnavailableView {
                    Label("No departures found", systemImage: "tram")
                } description: {
                    Text(isViewingToday
                         ? "Try the opposite direction or choose a different station pair."
                         : "No scheduled service for this date and route. Try another date or reverse the route.")
                } actions: {
                    Button("Reverse Route") {
                        swapStations(saveRoute: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.patcoWine)
                }
            } else {
                departureRows(at: now)
            }
        }
        .padding(16)
        .background(Color.patcoCream.opacity(0.95), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.patcoGold.opacity(0.5), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func departureRows(at now: Date) -> some View {
        // The cached list can outlive a departure between its 30-second refreshes.
        let departures = visibleDepartures(at: now)
        let statuses = departures.map { listCatchStatus(for: $0, at: now) }
        let earlierCount = EarlierDeparturesPolicy.collapsibleCount(
            unreachable: statuses.map { status -> Bool? in
                guard let status else { return nil }
                switch status {
                case .probablyMissed, .tooLate: return true
                case .atStation, .comfortable, .tight: return false
                }
            },
            hasReliableEstimate: hasReliableDepartureEstimate(at: now)
        )
        let lastGuidedIndex = statuses.lastIndex { $0 != nil }
        let laterStartIndex = departures.indices.first { index in
            departures[index].departureDate.timeIntervalSince(now) > 60 * 60
                && index > (lastGuidedIndex ?? -1)
        }
        let firstLikelyDepartureID = departures.indices.first {
            statuses[$0]?.isLikelyToCatch == true
        }.map { departures[$0].id }

        return LazyVStack(spacing: 7) {
            if earlierCount > 0 {
                Rectangle()
                    .fill(Color.patcoCharcoal.opacity(0.16))
                    .frame(height: 1)
                    .accessibilityHidden(true)
                Button {
                    showsEarlierDepartures.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text(earlierCount == 1 ? "1 earlier train · unlikely to catch" : "\(earlierCount) earlier trains · unlikely to catch")
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                        Image(systemName: showsEarlierDepartures ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.58))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsEarlierDepartures ? "Expanded" : "Collapsed")
                .accessibilityHint(showsEarlierDepartures ? "Hide earlier trains you likely can't catch" : "Show earlier trains you likely can't catch")
            }
            ForEach(departures.indices, id: \.self) { index in
                if index >= earlierCount || showsEarlierDepartures {
                    let departure = departures[index]
                    if index == laterStartIndex, index > 0 {
                        laterDeparturesDivider
                    }
                    let catchStatus = statuses[index]
                    DepartureRow(
                        departure: departure,
                        catchStatus: catchStatus,
                        hidesDayLabel: hidesPromotionalDates || !isViewingToday,
                        showsCountdown: isViewingToday,
                        showsLeaveCountdown: catchStatus?.leaveByText != nil,
                        isPrimaryLikelyDeparture: departure.id == firstLikelyDepartureID,
                        onSelect: {
                            selectedDeparture = departure
                        }
                    )
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func hasReliableDepartureEstimate(at now: Date) -> Bool {
        guard isViewingToday, !isAtDepartureStation(at: now),
              let origin = visibleDepartures(at: now).first?.origin,
              let location = usableReachabilityLocation(at: now) else { return false }
        if let sharedTrip {
            return sharedTrip.guidance?.hasFreshMapsEstimate(at: now) == true
        }
        guard let mode = currentReachabilityMode(at: now) else { return false }
        let estimate = mode == .driving ? driveTimeEstimate : walkingTimeEstimate
        return estimate?.isValid(for: origin, currentLocation: location, now: now) == true
    }

    private var laterDeparturesDivider: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.patcoCharcoal.opacity(0.14))
                .frame(height: 1)
            Text("Later departures")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.patcoCharcoal.opacity(0.58))
                .lineLimit(1)
            Rectangle()
                .fill(Color.patcoCharcoal.opacity(0.14))
                .frame(height: 1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Later departures")
    }

    private func locationFreshnessText(for timestamp: Date) -> String {
        let minutes = max(1, Int(Date().timeIntervalSince(timestamp) / 60))
        return minutes == 1 ? "Location updated 1 min ago" : "Location updated \(minutes) mins ago"
    }

    private var scheduleRefreshButton: some View {
        VStack(spacing: 8) {
            Button {
                Task {
                    isScheduleRecoveryRefreshing = true
                    scheduleRecoveryMessage = await forceGTFSUpdate { _ in }
                    isScheduleRecoveryRefreshing = false
                }
            } label: {
                if isScheduleRecoveryRefreshing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Refreshing Schedule...")
                    }
                } else {
                    Text("Refresh Schedule")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.patcoWine)
            .disabled(isScheduleRecoveryRefreshing)

            if let scheduleRecoveryMessage {
                Text(scheduleRecoveryMessage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.66))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var alertBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("PATCO alerts", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(Color.patcoGold)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isAlertsExpanded.toggle()
                    }
                } label: {
                    Label(
                        isAlertsExpanded ? "Hide" : "View",
                        systemImage: isAlertsExpanded ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption.weight(.bold))
                }
                .buttonStyle(.bordered)
                .tint(Color.patcoGold)
                .accessibilityLabel(isAlertsExpanded ? "Collapse PATCO alerts" : "Expand PATCO alerts")
                .disabled(visibleAlerts.isEmpty)

                Button {
                    alertProvider.refresh(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(alertProvider.isLoading)
                .tint(Color.patcoGold)
                .accessibilityLabel("Refresh PATCO alerts")
            }

            alertContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.patcoAlertBackground.opacity(0.94), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.patcoGold.opacity(0.4), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var alertContent: some View {
        let alerts = visibleAlerts

        if !alerts.isEmpty {
            if isAlertsExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(alerts) { alert in
                        AlertRow(alert: alert)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let lastUpdated = alertProvider.lastUpdated {
                    Text("Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
            } else if let firstAlert = alerts.first {
                AlertRow(alert: firstAlert, lineLimit: 2)

                if alerts.count > 1 {
                    Text("\(alerts.count) active alerts")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
        }
    }

    private var routeSummary: String {
        guard let origin = selectedStation(originId), let destination = selectedStation(destinationId) else {
            return "Lindenwold to 15/16th and Locust"
        }

        return "\(origin.name) to \(destination.name)"
    }

    private var routePairSummary: String {
        guard let origin = selectedStation(originId), let destination = selectedStation(destinationId) else {
            return "Lindenwold ↔ 15/16th and Locust"
        }

        return "\(origin.name) ↔ \(destination.name)"
    }

    private var routeDetailSummary: String? {
        guard let departure = departures.first(where: { !$0.isRemovedBySpecialSchedule }) else { return nil }

        return "\(departure.directionLabel) • \(departure.travelMinutes) min ride"
    }

    private func catchStatus(for departure: Departure, at date: Date = Date()) -> TrainCatchStatus? {
        guard !departure.isRemovedBySpecialSchedule else { return nil }
        guard isViewingToday else { return nil }
        return reachabilityStatus(for: departure, enforceOneHourLimit: false, at: date)
    }

    private func listCatchStatus(for departure: Departure, at date: Date) -> TrainCatchStatus? {
        guard !departure.isRemovedBySpecialSchedule else { return nil }
        guard isViewingToday else { return nil }
        guard let status = reachabilityStatus(for: departure, enforceOneHourLimit: true, at: date) else {
            return nil
        }

        if case .atStation = status {
            return nil
        }

        return status
    }

    private func reachabilityStatus(for departure: Departure, enforceOneHourLimit: Bool, at now: Date = Date()) -> TrainCatchStatus? {
        guard locationProvider.authorizationStatus == .authorizedAlways
                || locationProvider.authorizationStatus == .authorizedWhenInUse else { return nil }
        if let sharedTrip {
            guard !enforceOneHourLimit || departure.departureDate.timeIntervalSince(now) <= 3600,
                  let result = sharedTrip.catchResult(for: departure, at: now, enforceOneHourLimit: enforceOneHourLimit) else { return nil }
            if result.status == .atStation { return .atStation }
            guard let mode = result.mode else { return nil }
            let travelMode = StationTravelMode(mode)
            switch result.status {
            case .atStation: return .atStation
            case .comfortable: return .comfortable(travelMinutes: result.travelMinutes, mode: travelMode, arrivalAtStationDate: result.arrivalAtStation, leaveByDate: result.leaveBy)
            case .tight: return .tight(travelMinutes: result.travelMinutes, mode: travelMode, arrivalAtStationDate: result.arrivalAtStation, leaveByDate: result.leaveBy)
            case .probablyMissed: return .probablyMissed(travelMinutes: result.travelMinutes, mode: travelMode, arrivalAtStationDate: result.arrivalAtStation, leaveByDate: result.leaveBy)
            case .tooLate: return .tooLate(travelMinutes: result.travelMinutes, mode: travelMode, arrivalAtStationDate: result.arrivalAtStation, leaveByDate: result.leaveBy)
            }
        }
        guard let currentLocation = usableReachabilityLocation(at: now) else {
            return nil
        }

        let distanceToStation = currentLocation.distance(from: departure.origin.location)
        let minutesUntilDeparture = Int(floor(departure.departureDate.timeIntervalSince(now) / 60))
        guard distanceToStation <= StationTravelMode.reachabilityMaxDistanceMeters else {
            return nil
        }

        guard !enforceOneHourLimit || minutesUntilDeparture <= 60 else {
            return nil
        }
        if LocationGuidancePolicy.isAtStation(currentLocation, station: departure.origin.location, now: now) {
            return .atStation
        }

        let travelMode = currentReachabilityMode(at: now) ?? StationTravelMode.inferred(
            forMeters: distanceToStation,
            minutesUntilDeparture: minutesUntilDeparture
        )
        let stationBufferMinutes = travelMode.stationBufferMinutes
        guard let travelMinutes = travelMinutes(
            for: travelMode,
            distanceToStation: distanceToStation,
            origin: departure.origin,
            currentLocation: currentLocation
        ) else { return nil }
        let spareMinutes = minutesUntilDeparture - travelMinutes - stationBufferMinutes
        let arrivalAtStationDate = now.addingTimeInterval(TimeInterval(travelMinutes * 60))
        let leaveByDate = departure.departureDate.addingTimeInterval(-TimeInterval((travelMinutes + stationBufferMinutes) * 60))

        if spareMinutes >= 5 {
            return .comfortable(travelMinutes: travelMinutes, mode: travelMode, arrivalAtStationDate: arrivalAtStationDate, leaveByDate: leaveByDate)
        }
        if spareMinutes >= 0 {
            return .tight(travelMinutes: travelMinutes, mode: travelMode, arrivalAtStationDate: arrivalAtStationDate, leaveByDate: leaveByDate)
        }
        if spareMinutes < -5 {
            return .tooLate(travelMinutes: travelMinutes, mode: travelMode, arrivalAtStationDate: arrivalAtStationDate, leaveByDate: leaveByDate)
        }
        return .probablyMissed(travelMinutes: travelMinutes, mode: travelMode, arrivalAtStationDate: arrivalAtStationDate, leaveByDate: leaveByDate)
    }

    private func updateReachabilityLocationIfNeeded(_ location: CLLocation?, force: Bool = false) {
        guard let location, LocationGuidancePolicy.isUsable(location) else {
            if let previousLocation = reachabilityLocation,
               LocationGuidancePolicy.isUsable(previousLocation) {
                return
            }
            reachabilityLocation = nil
            lastReachabilityLocationUpdate = nil
            driveTimeEstimate = nil
            walkingTimeEstimate = nil
            refreshDepartures()
            return
        }

        let now = Date()
        let shouldUpdate: Bool
        if force || reachabilityLocation == nil || lastReachabilityLocationUpdate == nil {
            shouldUpdate = true
        } else if let reachabilityLocation,
                  location.distance(from: reachabilityLocation) >= reachabilityLocationMinDistance {
            shouldUpdate = true
        } else if let lastReachabilityLocationUpdate,
                  now.timeIntervalSince(lastReachabilityLocationUpdate) >= reachabilityLocationMinInterval {
            shouldUpdate = true
        } else {
            shouldUpdate = false
        }

        guard shouldUpdate else {
            // Fresh stationary fixes should renew freshness without recalculating travel estimates.
            if let previousLocation = reachabilityLocation,
               location.timestamp > previousLocation.timestamp {
                reachabilityLocation = location
            }
            return
        }

        reachabilityLocation = location
        lastReachabilityLocationUpdate = now
        if let origin = selectedStation(originId),
           LocationGuidancePolicy.isAtStation(location, station: origin.location),
           SharedReachabilityModeStore.clearOnArrival(originId: origin.id) {
            requestWidgetReload(reason: "Arrived at station", force: true)
            lastWidgetReachabilityReloadAt = now
        } else if lastWidgetReachabilityReloadAt.map({
            now.timeIntervalSince($0) >= widgetReachabilityReloadInterval
        }) ?? true {
            requestWidgetReload(reason: "Location changed")
            lastWidgetReachabilityReloadAt = now
        }
        refreshDepartures()
    }

    private func handleLocationUpdate(_ location: CLLocation?) {
        if let location { TripProgressStore.shared.record(location, stations: scheduleStore.stations) }
        if let route = SharedRouteCoordinator.current() {
            locationProvider.reconcileSharedRoute(route, previousRevision: sharedRouteRevision)
        }
        if !isViewingToday {
            // Browsing a schedule is not a new journey or a cancellation of the active one.
            let session = TripProgressStore.shared.session
            if let previous = SharedRouteCoordinator.current(),
               locationProvider.journeyTrackingDeadline != nil
                    || (session?.isActive() == true && session?.destinationName == selectedStation(previous.destinationId)?.name),
               let route = SharedRouteCoordinator.resolveWidgetRoute(location: location, stations: scheduleStore.stations,
                    expectedArrival: session?.isActive() == true && session?.destinationName == selectedStation(previous.destinationId)?.name
                        ? session?.arrival : nil),
               route.endsJourneyTracking, route.revision != sharedRouteRevision {
                locationProvider.reconcileSharedRoute(route, previousRevision: sharedRouteRevision ?? previous.revision)
                if route.completesJourney, let station = selectedStation(route.originId) {
                    TripProgressStore.shared.complete(arrivingAt: station.name)
                    Task { await PATCOLiveActivityStarter.endActivities(arrivingAt: station.name) }
                }
                let dates = (-1...1).compactMap { patcoCalendar.date(byAdding: .day, value: $0, to: Date()) }
                _ = SharedTripState.update(store: scheduleStore, routeRevision: route.revision,
                    location: location, locationAllowed: true,
                    specialSchedules: SharedSpecialScheduleCache.schedules(matching: dates, calendar: patcoCalendar))
                requestWidgetReload(reason: "Active journey route changed while browsing", force: true)
            }
            return
        }
        if let location {
            let destination = selectedStation(destinationId)
            let nearestStation = scheduleStore.nearestStation(to: location)
            let detectedStation = stationAtCurrentLocation(location)
            let speed = location.speed.isFinite && location.speed >= 0
                ? "\(LocationDiagnosticFormatting.speedInMPH(location.speed)) (\(location.speed.formatted(.number.precision(.fractionLength(1)))) m/sec)" : "unavailable"
            let nearestDistance = nearestStation.map { "\(Int(location.distance(from: $0.location).rounded())) m" } ?? "unknown"
            let distance = destination.map { "\(Int(location.distance(from: $0.location).rounded())) m" } ?? "unknown"
            ArrivalDiagnostics.record("Location reading", detail: "Age \(Int(Date().timeIntervalSince(location.timestamp))) sec; accuracy \(Int(location.horizontalAccuracy)) m; speed \(speed); nearest station \(nearestStation?.name ?? "unknown") (\(nearestDistance)); nearby station candidate \(detectedStation?.name ?? "none"); origin \(selectedStation(originId)?.name ?? "none"); destination \(destination?.name ?? "none"); destination distance \(distance); \(LocationDiagnosticFormatting.eligibility(location)); inside destination boundary \(destination.map { LocationGuidancePolicy.isAtStation(location, station: $0.location) } ?? false)")
        }
        if let location, LocationGuidancePolicy.isUsable(location) {
            SharedCurrentLocationCache.save(location)
        }

        let detectedStationId = location.flatMap { stationAtCurrentLocation($0)?.id }
        let crossedStationBoundary = detectedStationId != currentStationId

        var transaction = Transaction()
        transaction.disablesAnimations = crossedStationBoundary
        withTransaction(transaction) {
            applyNearestStation(location)
            if scenePhase == .active {
                updateReachabilityLocationIfNeeded(location, force: crossedStationBoundary)
            }
        }
    }

    private func openDirections(to station: Station, mode: StationTravelMode) {
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: station.coordinate))
        destination.name = "\(station.name) PATCO Station"
        destination.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: mode.mapsDirectionsMode
        ])
    }

    private func setReachabilityMode(_ mode: StationTravelMode) {
        guard let origin = selectedStation(originId) else { return }

        showsEarlierDepartures = false
        SharedReachabilityModeStore.save(mode: mode.sharedMode, originId: origin.id)
        refreshReachabilityModeSelection()
    }

    private func refreshReachabilityModeSelection() {
        showsEarlierDepartures = false
        refreshDepartures()
        requestWidgetReload(reason: "Reachability mode changed", force: true)
        if let origin = selectedStation(originId) {
            Task { await refreshTravelTimeEstimatesIfNeeded(origin: origin) }
        }
    }

    private func tripStops(for departure: Departure) -> [TripDetailStop] {
        departure.trip.stopTimes
            .filter { $0.sequence >= departure.originTime.sequence && $0.sequence <= departure.destinationTime.sequence }
            .sorted { $0.sequence < $1.sequence }
            .compactMap { stopTime in
                scheduleStore.station(for: stopTime.stopId).map {
                    TripDetailStop(station: $0, stopTime: stopTime)
                }
            }
    }

    private var selectedScheduleDateHeaderText: String {
        let formatter = DateFormatter()
        formatter.calendar = patcoCalendar
        formatter.timeZone = patcoCalendar.timeZone
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: selectedScheduleDate)
    }

    private var scheduleDatePickerSheet: some View {
        NavigationStack {
            VStack(spacing: 12) {
                DatePicker(
                    "Departure date",
                    selection: $draftScheduleDate,
                    in: patcoCalendar.startOfDay(for: Date())...lastSelectableScheduleDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .accessibilityLabel("Departure date")
                .environment(\.timeZone, patcoCalendar.timeZone)

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    Button("Today") {
                        selectedScheduleDate = Date()
                        isShowingScheduleDatePicker = false
                    }
                    .buttonStyle(.bordered)

                    Button("Show departures") {
                        selectedScheduleDate = draftScheduleDate
                        isShowingScheduleDatePicker = false
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(16)
            .background(Color.patcoCream.ignoresSafeArea())
            .navigationTitle("Departure date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingScheduleDatePicker = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close date picker")
                }
            }
        }
        .tint(Color.patcoWine)
        .environment(\.colorScheme, .light)
        .presentationDetents([.height(520), .large])
    }

    private func selectedStation(_ id: Station.ID?) -> Station? {
        scheduleStore.stations.first { $0.id == id }
    }

    private func applyDefaultsIfNeeded() {
        savedRouteStore.initializeDefaultRoutesIfNeeded(stations: scheduleStore.stations)
        if originId == nil {
            originId = savedOriginId()
                ?? station(named: "Lindenwold")?.id
                ?? scheduleStore.stations.first?.id
        }
        if destinationId == nil {
            destinationId = savedDestinationId()
                ?? scheduleStore.locust?.id
                ?? scheduleStore.stations.last?.id
        }
    }

    private func applyNearestStation(_ location: CLLocation?) {
        // Planning a future day must not mutate the route based on today's location.
        guard isViewingToday else { return }
        publishAppRoute()
        guard let location else {
            undergroundDepartureEvidence = UndergroundDepartureEvidence()
            clearExpiredStationSelection()
            if let revision = sharedRouteRevision {
                _ = SharedRouteCoordinator.checkArrival(expectedRevision: revision, location: nil, stations: scheduleStore.stations)
                _ = SharedRouteCoordinator.recoverReturnDirection(expectedRevision: revision, location: nil, stations: scheduleStore.stations)
            }
            currentStationId = nil
            currentStationName = nil
            return
        }

        let nearbyStation = stationAtCurrentLocation(location)
        let otherDistance = nearbyStation.map { nearby in
            scheduleStore.stations.filter { $0.id != nearby.id }.map { location.distance(from: $0.location) }.min() ?? .infinity
        } ?? .infinity
        let insideStation = nearbyStation.map { nearby in
            stationStopEvidence.accepts(stationId: nearby.id, station: nearby.location, location: location,
                nearestOtherDistance: otherDistance)
        } ?? false
        if nearbyStation == nil { stationStopEvidence = CurrentStationEvidence() }
        let station = insideStation ? nearbyStation : nil
        if let nearbyStation, !insideStation {
            ArrivalDiagnostics.record("Current station pending",
                detail: "\(nearbyStation.name): \(stationStopEvidence.diagnosticDescription(for: location))")
        }
        SharedRouteCoordinator.observeDeparture(location: location, stations: scheduleStore.stations)
        if let destination = selectedStation(destinationId) {
            arrivalGate.observeDeparture(from: destination.location, location: location)
        }
        // Arrival confirmation has its own uncertainty policy, independent of travel guidance.
        if completeDestinationArrivalIfNeeded(station: station, location: location) {
            return
        }
        if let revision = sharedRouteRevision,
           let recovered = SharedRouteCoordinator.recoverReturnDirection(expectedRevision: revision,
                location: location, stations: scheduleStore.stations),
           recovered.revision == revision + 1 {
            publishAppRoute()
            SharedRouteDefaults.clearTemporary()
            SharedRouteDefaults.clearManualStationSelection()
            SharedRouteDefaults.saveJourneyDirection(destinationId: recovered.destinationId)
            locationProvider.endJourneyTracking()
            refreshDepartures()
            ArrivalDiagnostics.record("Return direction recovered", detail: "Reliable endpoint-side travel evidence; station arrival not confirmed or announced")
            requestWidgetReload(reason: "Return direction recovered", force: true)
            return
        }
        // Keep inferred departures separate from the strict destination-arrival path above.
        let orderedStations = scheduleStore.stations
        let journeyOrigin = temporaryRouteOriginalOriginId ?? originId
        if let start = orderedStations.firstIndex(where: { $0.id == journeyOrigin }),
           let end = orderedStations.firstIndex(where: { $0.id == destinationId }) {
            let segment = Array(orderedStations[min(start, end)...max(start, end)])
            let route = (start <= end ? segment : Array(segment.reversed())).map(\.id)
            let nearest = orderedStations.min { location.distance(from: $0.location) < location.distance(from: $1.location) }
            let others = orderedStations.filter { $0.id != nearest?.id }
                .map { location.distance(from: $0.location) }.min() ?? .infinity
            let inferred = undergroundDepartureEvidence.observe(route: route, stationId: nearest?.id,
                reliable: station != nil && station?.id == nearest?.id,
                underground: nearest?.supportsUndergroundReturnRecovery == true,
                distance: nearest.map { location.distance(from: $0.location) } ?? .infinity,
                otherDistance: others, location: location,
                journeyActive: locationProvider.journeyTrackingDeadline.map { $0 > Date() } == true)
            if let inferred, let inferredStation = selectedStation(inferred),
               SharedRouteDefaults.manuallySelectedAtStationId() == nil {
                if inferred != originId {
                    useCurrentStationAsTemporaryOrigin(inferred, destinationId: destinationId, automatic: true)
                    if originId == inferred {
                        ArrivalDiagnostics.record("Temporary station estimated", detail: "\(inferredStation.name): repeated underground readings; destination arrival not confirmed")
                    }
                }
                if originId == inferred {
                    estimatedStationAt = location.timestamp
                    currentStationId = inferred
                    currentStationName = inferredStation.name
                    nearestRouteStationName = inferredStation.name
                    return
                }
            }
        }
        // Duplicate callbacks must not dismiss a still-fresh inferred station.
        if station == nil, let estimatedStationAt,
           (0...15).contains(Date().timeIntervalSince(estimatedStationAt)),
           location.timestamp <= estimatedStationAt,
           let origin = selectedStation(originId),
           location.distance(from: origin.location) <= LocationGuidancePolicy.stationRadiusMeters {
            return
        }
        if station == nil { clearExpiredStationSelection() }
        estimatedStationAt = nil
        guard LocationGuidancePolicy.isUsable(location, maxAge: 30) else {
            let age = Date().timeIntervalSince(location.timestamp)
            let accuracy = String(format: "%.0f", location.horizontalAccuracy)
            ArrivalDiagnostics.record("GPS station guidance rejected", detail: "Age \(Int(age)) sec; accuracy \(accuracy) m; guidance requires age 0...30 sec and valid accuracy <=150 m. Strict station presence requires age <=15 sec and accuracy <=50 m. Underground station and destination estimates are evaluated separately.")
            currentStationId = nil
            currentStationName = nil
            nearestRouteStationName = nil
            return
        }
        var departedArrivalStation = false
        if let completed = completedArrivalLocation,
           location.horizontalAccuracy > 0, location.horizontalAccuracy <= 150,
           location.distance(from: completed) - location.horizontalAccuracy > LocationGuidancePolicy.stationRadiusMeters {
            completedArrivalLocation = nil
            departedArrivalStation = true
        }
        let explicitTrip = selectedStation(destinationId).map {
            PATCOLiveActivityStarter.hasCurrentTrip(to: $0.name)
        } == true
        if isViewingToday, scenePhase == .active,
           originId != destinationId, originId != nil, destinationId != nil,
           JourneyTrackingPolicy.shouldBegin(atOrigin: nearbyStation?.id == originId,
               arrivalSuppressed: completedArrivalLocation != nil,
               departedArrivalStation: departedArrivalStation, explicitTrip: explicitTrip),
           (0...30).contains(Date().timeIntervalSince(location.timestamp)),
           location.horizontalAccuracy > 0, location.horizontalAccuracy <= 150 {
            locationProvider.beginJourneyTracking(stations: scheduleStore.stations)
        }
        if let station, currentStationId != station.id {
            ArrivalDiagnostics.record("Current station confirmed", detail: "\(station.name); inside station boundary, no stop required. Destination arrival is evaluated separately.")
        }
        currentStationId = station?.id
        currentStationName = station?.name
        if let manuallySelectedAtStationId = SharedRouteDefaults.manuallySelectedAtStationId() {
            if let selectedStation = selectedStation(manuallySelectedAtStationId),
               location.distance(from: selectedStation.location)
                <= StationTravelMode.atStationMeters + max(150, location.horizontalAccuracy) {
                currentStationId = station?.id
                currentStationName = station?.name
                nearestRouteStationName = selectedStation.name
                return
            }
            SharedRouteDefaults.clearManualStationSelection()
        }

        if isUsingTemporaryStationRoute {
            if let temporaryOrigin = selectedStation(originId),
               LocationGuidancePolicy.hasLeftStation(location, station: temporaryOrigin.location) {
                restoreRouteAfterLeavingStation(departureLocation: location)
            } else {
                nearestRouteStationName = selectedStation(originId)?.name
                return
            }
        }

        if let station {
            nearestRouteStationName = station.name

            if station.id == originId, let destinationId {
                SharedRouteDefaults.saveJourneyDirection(destinationId: destinationId)
            } else if station.id != destinationId {
                useCurrentStationAsTemporaryOrigin(
                    station.id,
                    destinationId: destinationId ?? SharedRouteDefaults.journeyDestinationId(),
                    automatic: true
                )
            }
            return
        }

        // Nearest-station presentation must not change direction, including after automatic arrival.
        guard let routeEndpoints = savedRouteEndpoints(),
              routeEndpoints.origin != routeEndpoints.destination else {
            nearestRouteStationName = nil
            return
        }

        let routeStations = stationsBetween(routeEndpoints.origin, routeEndpoints.destination)
        let nearest = routeStations.min {
            $0.location.distance(from: location) < $1.location.distance(from: location)
        } ?? routeEndpoints.origin
        nearestRouteStationName = nearest.name
    }

    @discardableResult
    private func completeDestinationArrivalIfNeeded(
        station: Station? = nil,
        location: CLLocation? = nil,
        expectedDestinationId: Station.ID? = nil
    ) -> Bool {
        guard isViewingToday,
              let location = location ?? locationProvider.currentLocation,
              let arrivalStation = station ?? scheduleStore.nearestStation(to: location) else {
            return false
        }
        let destinationId = expectedDestinationId
            ?? self.destinationId
            ?? SharedRouteDefaults.journeyDestinationId()
        let session = TripProgressStore.shared.session
        let expectedArrival = session?.isActive() == true
            && session?.destinationName == selectedStation(destinationId)?.name ? session?.arrival : nil
        guard let revision = sharedRouteRevision,
              let persistedGate = SharedRouteCoordinator.checkArrival(expectedRevision: revision,
                    location: location, stations: scheduleStore.stations,
                    expectedArrival: expectedArrival) else { return false }
        arrivalGate = persistedGate
        guard let destinationId, arrivalStation.id == destinationId else {
            ArrivalDiagnostics.record("Destination arrival pending", detail: "Nearest \(arrivalStation.name); selected destination \(selectedStation(destinationId)?.name ?? "none"). Current-station detection is evaluated separately.")
            return false
        }
        guard arrivalGate.confirmed else {
            ArrivalDiagnostics.record("Arrival not confirmed", detail: "\(arrivalStation.name): \(arrivalGate.lastDecision); distance \(location.distance(from: arrivalStation.location)) m; accuracy \(location.horizontalAccuracy) m; adaptive radius \(UrbanStationArrivalPolicy.radius(accuracy: location.horizontalAccuracy)) m; scheduled arrival \(expectedArrival?.description ?? "unavailable")")
            return false
        }
        ArrivalDiagnostics.record(arrivalGate.usedNearestStationFallback ? "Estimated arrival" : "Arrival confirmed",
                                  detail: "\(arrivalStation.name): \(arrivalGate.lastDecision)")

        return completeDestinationArrival(at: arrivalStation, destinationId: destinationId,
                                          inferredArrival: arrivalGate.usedNearestStationFallback,
                                          observationAt: location.timestamp)
    }

    @discardableResult
    private func completeDestinationArrival(at arrivalStation: Station, destinationId: Station.ID,
                                            inferredArrival: Bool = false, observationAt: Date) -> Bool {
        guard self.destinationId == destinationId, let route = SharedRouteCoordinator.current(),
              let returnStation = selectedStation(SharedWidgetRouteMemory.returnDestination(
                arrivingAt: destinationId, currentOrigin: route.originId,
                savedOrigin: route.savedOriginId, savedDestination: route.savedDestinationId)),
              returnStation.id != arrivalStation.id else {
            return false
        }

        guard let committed = SharedRouteCoordinator.commit(originId: arrivalStation.id, destinationId: returnStation.id,
                    expectedRevision: sharedRouteRevision, arrival: true,
                    observationAt: observationAt),
              committed.originId == arrivalStation.id, committed.destinationId == returnStation.id else { return false }
        sharedRouteRevision = committed.revision

        if isUsingTemporaryStationRoute {
            temporaryRouteOriginalOriginId = nil
            temporaryRouteOriginalDestinationId = nil
            SharedRouteDefaults.clearTemporary()
        }
        SharedRouteDefaults.clearManualStationSelection()
        originId = arrivalStation.id
        locationProvider.endJourneyTracking(reloadWidgets: false)
        completedArrivalLocation = arrivalStation.location
        arrivalGate = DestinationArrivalGate()
        self.destinationId = returnStation.id
        ArrivalDiagnostics.record("Arrival completed", detail: "\(arrivalStation.name); return route to \(returnStation.name)")
        SharedRouteDefaults.saveJourneyDirection(destinationId: returnStation.id)
        nearestRouteStationName = arrivalStation.name
        refreshDepartures()
        requestWidgetReload(reason: "Journey arrived; return route ready", force: true)
        Task { await PATCOLiveActivityStarter.endActivities(arrivingAt: arrivalStation.name) }
        showArrivalAnnouncement(at: arrivalStation, returningTo: returnStation, inferredArrival: inferredArrival)
        return true
    }

    private func confirmTripArrival(_ departure: Departure) {
        guard let old = SharedRouteCoordinator.current(),
              let result = SharedRouteCoordinator.confirmTripArrival(originId: departure.origin.id,
                destinationId: departure.destination.id, expectedRevision: old.revision),
              result.revision == old.revision + 1 else { return }
        TripProgressStore.shared.complete(arrivingAt: departure.destination.name)
        SharedRouteDefaults.clearTemporary()
        SharedRouteDefaults.clearManualStationSelection()
        SharedRouteDefaults.saveJourneyDirection(destinationId: departure.origin.id)
        locationProvider.endJourneyTracking(reloadWidgets: false)
        completedArrivalLocation = departure.destination.location
        publishAppRoute()
        refreshDepartures()
        requestWidgetReload(reason: "User confirmed trip arrival", force: true)
        showArrivalAnnouncement(at: departure.destination, returningTo: departure.origin)
    }

    private func showArrivalAnnouncement(at arrivalStation: Station, returningTo returnStation: Station, inferredArrival: Bool = false) {
        let announcement = ArrivalAnnouncement(
            stationName: arrivalStation.name,
            returnStationName: returnStation.name,
            inferredArrival: inferredArrival
        )
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
            arrivalAnnouncement = announcement
        }

        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, arrivalAnnouncement?.id == announcement.id else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                arrivalAnnouncement = nil
            }
        }
    }

    private func arrivalAnnouncementBanner(_ announcement: ArrivalAnnouncement) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.uturn.backward")
                .font(.title3.weight(.heavy))
                .foregroundStyle(Color.patcoCharcoal)
                .frame(width: 40, height: 40)
                .background(Color.patcoGold, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("\(announcement.inferredArrival ? "Estimated arrival at" : "At") \(announcement.stationName)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text("Return departures to \(announcement.returnStationName) shown.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.80))
                    .lineLimit(2)
            }

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    arrivalAnnouncement = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.80))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss arrival confirmation")
        }
        .padding(12)
        .background(Color.patcoCharcoal.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.patcoGold.opacity(0.58), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.24), radius: 10, y: 5)
        .accessibilityElement(children: .combine)
    }

    private func savedRouteEndpoints() -> (origin: Station, destination: Station)? {
        if let savedRoute = SharedRouteDefaults.savedRoute(),
           let savedOrigin = selectedStation(savedRoute.originId),
           let savedDestination = selectedStation(savedRoute.destinationId),
           savedOrigin != savedDestination {
            return (savedOrigin, savedDestination)
        }

        guard let currentOrigin = selectedStation(originId),
              let currentDestination = selectedStation(destinationId),
              currentOrigin != currentDestination else {
            return nil
        }

        return (currentOrigin, currentDestination)
    }

    private func stationsBetween(_ origin: Station, _ destination: Station) -> [Station] {
        guard let originIndex = scheduleStore.stations.firstIndex(of: origin),
              let destinationIndex = scheduleStore.stations.firstIndex(of: destination) else {
            return [origin, destination]
        }

        let bounds = min(originIndex, destinationIndex)...max(originIndex, destinationIndex)
        return Array(scheduleStore.stations[bounds])
    }

    private func publishAppRoute() {
        TripProgressStore.shared.synchronize()
        guard isViewingToday, let originId, let destinationId else { return }
        guard let route = SharedRouteCoordinator.routeForApp(defaultOriginId: originId,
                                                             defaultDestinationId: destinationId) else { return }
        locationProvider.reconcileSharedRoute(route, previousRevision: sharedRouteRevision)
        temporaryRouteOriginalOriginId = route.temporaryRoute?.originId
        temporaryRouteOriginalDestinationId = route.temporaryRoute?.destinationId
        arrivalGate = route.arrivalGate ?? DestinationArrivalGate()
        if route.originId != originId || route.destinationId != destinationId {
            self.originId = route.originId
            self.destinationId = route.destinationId
        }
        let changed = sharedRouteRevision != route.revision
        if changed {
            if route.completesJourney {
                completedArrivalLocation = selectedStation(route.originId)?.location
                if let station = selectedStation(route.originId) {
                    TripProgressStore.shared.complete(arrivingAt: station.name)
                    Task { await PATCOLiveActivityStarter.endActivities(arrivingAt: station.name) }
                }
            }
            if !route.event.isTemporary {
                undergroundDepartureEvidence = UndergroundDepartureEvidence()
            }
            estimatedStationAt = nil
            stationStopEvidence = CurrentStationEvidence()
            currentStationId = nil
            currentStationName = nil
        }
        sharedRouteRevision = route.revision
        let diagnosticSpecialSchedule = scheduleStore.specialSchedule(on: departures.first?.serviceDate ?? selectedScheduleDate)
        SharedDiagnosticState.record(.app, origin: selectedStation(route.originId),
                                     destination: selectedStation(route.destinationId), revision: route.revision,
                                     location: locationProvider.currentLocation,
                                     appliedSpecialSchedules: diagnosticSpecialSchedule.map {
                                         ["\($0.title) (\($0.serviceDate.formatted(date: .abbreviated, time: .omitted)))"]
                                     } ?? [])
        if changed {
            SharedWidgetDiagnostics.record("App shared route", detail: "Revision \(route.revision): \(route.originId) to \(route.destinationId); \(route.reason)")
            requestWidgetReload(reason: "App route synchronized", force: true)
        }
    }

    private func refreshDepartures() {
        publishAppRoute()
        guard let origin = selectedStation(originId), let destination = selectedStation(destinationId), origin != destination else {
            departures = []
            return
        }

        let now = Date()
        if !isViewingToday {
            sharedTrip = nil
            let selectedDay = patcoCalendar.startOfDay(for: selectedScheduleDate)
            departures = scheduleStore.departures(
                from: origin,
                to: destination,
                after: selectedDay,
                limit: nil
            )
                .filter { patcoCalendar.isDate($0.departureDate, inSameDayAs: selectedDay) }
            resolvePendingDepartureDeepLink()
            return
        }

        let permission = locationProvider.authorizationStatus
        let update = sharedRouteRevision.flatMap {
            SharedTripState.update(store: scheduleStore, routeRevision: $0,
                                   location: reachabilityLocation ?? locationProvider.currentLocation ?? SharedCurrentLocationCache.location(),
                                   locationAllowed: permission == .authorizedAlways || permission == .authorizedWhenInUse,
                                   now: now, specialSchedules: sharedSpecialSchedules)
        }
        sharedTrip = update?.snapshot ?? SharedTripState.current()
        if update?.shouldReloadWidgets == true { requestWidgetReload(reason: "Shared trip state updated") }
        let upcomingDepartures = sharedTrip?.upcoming(at: now) ?? scheduleStore.departures(
            from: origin,
            to: destination,
            after: now,
            limit: nil
        )
        let todayDepartures = upcomingDepartures.filter {
            patcoCalendar.isDate($0.departureDate, inSameDayAs: now)
        }

        if todayDepartures.count >= 3 {
            departures = todayDepartures
        } else {
            let nextDayDepartures = upcomingDepartures
                .filter { !patcoCalendar.isDate($0.departureDate, inSameDayAs: now) }
                .prefix(3 - todayDepartures.count)
            departures = todayDepartures + nextDayDepartures
        }

        Task {
            await refreshTravelTimeEstimatesIfNeeded(origin: origin)
        }

        resolvePendingDepartureDeepLink()
    }

    private var liveTripShortcut: some View {
        let _ = liveTripRevision
        return TimelineView(.periodic(from: .now, by: 30)) { timeline in
            if let activity = PATCOLiveActivityStarter.currentTripActivity(now: timeline.date),
               let url = URL(string: activity.attributes.deepLinkURLString) {
                    Button {
                        handleDeepLink(url)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "tram.fill")
                                .foregroundStyle(Color.patcoGold)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Your trip").font(.headline)
                                Text(activity.attributes.routeTitle)
                                    .font(.subheadline)
                                    .multilineTextAlignment(.leading)
                                Text("Scheduled arrival \(PATCOClock.timeText(activity.content.state.arrivalDate, relativeTo: timeline.date))")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                        }
                        .foregroundStyle(.white)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                .task(id: activity.id) {
                    for await _ in activity.activityStateUpdates {
                        guard !Task.isCancelled else { return }
                        liveTripRevision += 1
                    }
                }
            }
        }
    }

    private func handleDeepLink(_ url: URL) {
        if url.host == "widget" {
            refreshForForeground()
            return
        }

        guard let deepLink = DepartureDeepLink(url: url) else {
            return
        }

        pendingDepartureDeepLink = deepLink
        resolvePendingDepartureDeepLink()
    }

    private func resolvePendingDepartureDeepLink() {
        guard let deepLink = pendingDepartureDeepLink else {
            return
        }

        guard let departure = scheduleStore.departure(matching: deepLink) else {
            return
        }

        selectedDeparture = departure
        pendingDepartureDeepLink = nil
    }

    private func routeSelectionChanged(saveRoute: Bool = false, destinationOnly: Bool = false) {
        if saveRoute {
            nearestStationMessage = nil
            if destinationOnly, let originalOrigin = temporaryRouteOriginalOriginId {
                originId = originalOrigin
            }
            arrivalGate = DestinationArrivalGate()
            if let destination = selectedStation(destinationId), let location = locationProvider.currentLocation {
                arrivalGate.prepareSelection(destinationId: destination.id, station: destination.location, location: location)
            }
            clearTemporaryStationRoute()
            saveSelectedRoute()
            if let destinationId, originId != destinationId {
                SharedRouteDefaults.saveJourneyDirection(destinationId: destinationId)
                if let location = locationProvider.currentLocation ?? SharedCurrentLocationCache.location(),
                   let station = stationAtCurrentLocation(location) {
                    SharedRouteDefaults.saveManualStationSelection(stationId: station.id)
                } else {
                    SharedRouteDefaults.clearManualStationSelection()
                }
            }
        }
        applyNearestStation(
            locationProvider.currentLocation ?? SharedCurrentLocationCache.location()
        )
    }

    private var isUsingTemporaryStationRoute: Bool {
        temporaryRouteOriginalOriginId != nil && temporaryRouteOriginalDestinationId != nil
    }

    private var savedStartingStationName: String {
        selectedStation(temporaryRouteOriginalOriginId)?.name ?? "saved starting location"
    }

    private func useCurrentStationAsTemporaryOrigin(
        _ stationId: Station.ID,
        destinationId preferredDestinationId: Station.ID? = nil,
        automatic: Bool = false
    ) {
        publishAppRoute()
        guard let originId,
              let destinationId else {
            return
        }
        let temporaryDestinationId = preferredDestinationId ?? destinationId
        guard stationId != temporaryDestinationId else { return }

        if isViewingToday {
            guard let revision = sharedRouteRevision,
                  let route = SharedRouteCoordinator.selectStationDepartures(
                    expectedRevision: revision, originId: stationId, destinationId: temporaryDestinationId,
                    stations: scheduleStore.stations, selectionLocation: locationProvider.currentLocation,
                    automatic: automatic),
                  route.revision == revision + 1 else {
                refreshDepartures()
                return
            }
            sharedRouteRevision = route.revision
            arrivalGate = route.arrivalGate ?? DestinationArrivalGate()
        }

        temporaryRouteOriginalOriginId = originId
        temporaryRouteOriginalDestinationId = destinationId
        self.originId = stationId
        self.destinationId = temporaryDestinationId
        SharedRouteDefaults.saveTemporary(originId: stationId, destinationId: temporaryDestinationId)
        refreshDepartures()
        requestWidgetReload(reason: "Temporary station route changed", force: true)
        isRouteExpanded = false
    }

    private func restoreRouteAfterLeavingStation(departureLocation: CLLocation? = nil) {
        guard let originalOriginId = temporaryRouteOriginalOriginId,
              let originalDestinationId = temporaryRouteOriginalDestinationId else {
            return
        }

        if isViewingToday {
            guard let revision = sharedRouteRevision,
                  let route = SharedRouteCoordinator.restoreStationRoute(expectedRevision: revision,
                    departureLocation: departureLocation, requireDeparture: departureLocation != nil,
                    stations: scheduleStore.stations),
                  route.revision == revision + 1 else {
                publishAppRoute()
                return
            }
            sharedRouteRevision = route.revision
        }

        clearTemporaryStationRoute()
        originId = originalOriginId
        destinationId = originalDestinationId
        refreshDepartures()
    }

    private func clearExpiredStationSelection() {
        estimatedStationAt = nil
        currentStationId = nil
        currentStationName = nil
        nearestRouteStationName = nil
        stationStopEvidence = CurrentStationEvidence()
        // Expiring a temporary selection is not evidence of physical departure or arrival.
        // Use the revision-checked restoration path to preserve saved endpoints and newer choices.
        if isViewingToday, isUsingTemporaryStationRoute {
            restoreRouteAfterLeavingStation()
        }
    }

    private func clearTemporaryStationRoute() {
        let hadTemporaryRoute = isUsingTemporaryStationRoute || SharedRouteDefaults.temporaryRoute() != nil
        temporaryRouteOriginalOriginId = nil
        temporaryRouteOriginalDestinationId = nil
        SharedRouteDefaults.clearTemporary()
        if hadTemporaryRoute {
            requestWidgetReload(reason: "Temporary station route cleared", force: true)
        }
    }

    private func stationAtCurrentLocation(_ location: CLLocation) -> Station? {
        LocationGuidancePolicy.detectedStation(location, stations: scheduleStore.stations)
    }

    private func saveSelectedRoute() {
        guard let originId, let destinationId, originId != destinationId else {
            return
        }

        let previousRevision = SharedRouteCoordinator.current()?.revision
        SharedRouteDefaults.clearJourneyDirection()
        SharedRouteDefaults.save(originId: originId, destinationId: destinationId,
                                 selectionLocation: locationProvider.currentLocation ?? SharedCurrentLocationCache.location(),
                                 destinationLocation: selectedStation(destinationId)?.location)
        if let route = SharedRouteCoordinator.current() {
            locationProvider.reconcileSharedRoute(route, previousRevision: previousRevision)
            sharedRouteRevision = route.revision
        }
        TripProgressStore.shared.synchronize()
        Task { await PATCOLiveActivityStarter.endExpiredActivities() }
        requestWidgetReload(reason: "Saved route changed", force: true)
    }

    private func savedOriginId() -> Station.ID? {
        guard let originId = SharedRouteDefaults.savedRoute()?.originId,
              selectedStation(originId) != nil else {
            return nil
        }

        return originId
    }

    private func savedDestinationId() -> Station.ID? {
        guard let destinationId = SharedRouteDefaults.savedRoute()?.destinationId,
              selectedStation(destinationId) != nil else {
            return nil
        }

        return destinationId
    }

    private func station(named name: String) -> Station? {
        scheduleStore.stations.first { $0.name == name }
    }

    private func travelMinutes(
        for mode: StationTravelMode,
        distanceToStation: CLLocationDistance,
        origin: Station,
        currentLocation: CLLocation
    ) -> Int? {
        if mode == .walking,
           let walkingTimeEstimate,
           walkingTimeEstimate.isValid(for: origin, currentLocation: currentLocation) {
            return walkingTimeEstimate.minutes
        }

        guard mode == .driving,
              let driveTimeEstimate,
              driveTimeEstimate.isValid(for: origin, currentLocation: currentLocation) else {
            if mode == .driving {
                return SharedTravelTimeEstimateCache.estimate(mode: .driving, origin: origin, currentLocation: currentLocation)?.minutes
            }
            return mode.travelMinutes(forMeters: distanceToStation)
        }

        return driveTimeEstimate.minutes
    }

    @MainActor
    private func refreshTravelTimeEstimatesIfNeeded(origin: Station) async {
        guard scenePhase == .active else { return }
        if currentReachabilityMode == .driving {
            await refreshDriveTimeEstimate(origin: origin, force: false)
        } else {
            await refreshWalkingTimeEstimate(origin: origin, force: false)
        }
        guard scenePhase == .active, isViewingToday, originId == origin.id, let revision = sharedRouteRevision else { return }
        let permission = locationProvider.authorizationStatus
        if let update = SharedTripState.update(store: scheduleStore, routeRevision: revision,
                                  location: reachabilityLocation ?? locationProvider.currentLocation,
                                  locationAllowed: permission == .authorizedAlways || permission == .authorizedWhenInUse,
                                  specialSchedules: sharedSpecialSchedules) {
            sharedTrip = update.snapshot
            if update.shouldReloadWidgets { requestWidgetReload(reason: "Shared travel guidance updated") }
        }
    }

    private var sharedSpecialSchedules: [PATCOSpecialSchedule] {
        let dates = (-1...1).compactMap { patcoCalendar.date(byAdding: .day, value: $0, to: Date()) }
        return SharedSpecialScheduleCache.schedules(matching: dates, calendar: patcoCalendar)
    }

    @MainActor
    private func refreshWalkingTimeEstimate(origin: Station, force: Bool) async {
        guard scenePhase == .active, isViewingToday, originId == origin.id,
              !Task.isCancelled, !walkingEstimateInFlight else { return }
        walkingEstimateInFlight = true
        defer { walkingEstimateInFlight = false }
        let requestID = walkingEstimateRequests.begin()
        let requestStartedAt = Date()
        let requestRevision = sharedRouteRevision
        guard let currentLocation = usableReachabilityLocation else {
            walkingTimeEstimate = nil
            SharedTravelTimeEstimateCache.clear(mode: .walking)
            return
        }

        let distanceToStation = currentLocation.distance(from: origin.location)
        guard SharedReachabilityModeStore.shouldRequestWalkingEstimate(distance: distanceToStation, originId: origin.id) else {
            walkingTimeEstimate = nil
            SharedTravelTimeEstimateCache.clear(mode: .walking)
            return
        }

        if !force, let walkingTimeEstimate, walkingTimeEstimate.isValid(for: origin, currentLocation: currentLocation) {
            return
        }

        if !force, let cached = SharedTravelTimeEstimateCache.estimate(mode: .walking, origin: origin, currentLocation: currentLocation),
           cached.routeDistanceMeters != nil {
            walkingTimeEstimate = TravelTimeEstimate(originId: origin.id,
                sourceLocation: CLLocation(latitude: cached.sourceLatitude, longitude: cached.sourceLongitude),
                minutes: cached.minutes, fetchedAt: cached.fetchedAt, routeDistanceMeters: cached.routeDistanceMeters)
            return
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocation.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.transportType = .walking
        request.requestsAlternateRoutes = false

        do {
            let response = try await MKDirections(request: request).calculate()
            guard walkingEstimateRequests.accepts(requestID), sharedRouteRevision == requestRevision,
                  let latestLocation = usableReachabilityLocation,
                  latestLocation.distance(from: currentLocation) < 50 else { return }
            guard isViewingToday, originId == origin.id, !Task.isCancelled else { return }
            guard locationProvider.authorizationStatus == .authorizedAlways
                    || locationProvider.authorizationStatus == .authorizedWhenInUse else { return }
            guard let route = response.routes.first else { return }

            let estimate = TravelTimeEstimate(
                originId: origin.id,
                sourceLocation: currentLocation,
                minutes: max(1, Int(ceil(route.expectedTravelTime / 60))),
                fetchedAt: Date(),
                routeDistanceMeters: route.distance
            )
            walkingTimeEstimate = estimate
            SharedTravelTimeEstimateCache.save(
                mode: .walking,
                origin: origin,
                currentLocation: currentLocation,
                minutes: estimate.minutes,
                fetchedAt: estimate.fetchedAt,
                routeDistanceMeters: estimate.routeDistanceMeters,
                requestStartedAt: requestStartedAt
            )
        } catch {
            guard walkingEstimateRequests.accepts(requestID), sharedRouteRevision == requestRevision else { return }
            guard isViewingToday, originId == origin.id, !Task.isCancelled else { return }
            walkingTimeEstimate = nil
            SharedTravelTimeEstimateCache.clear(mode: .walking, ifNotNewerThan: requestStartedAt, originId: origin.id)
        }
    }

    @MainActor
    private func refreshDriveTimeEstimate(origin: Station, force: Bool) async {
        guard scenePhase == .active, isViewingToday, originId == origin.id,
              !Task.isCancelled, !drivingEstimateInFlight else { return }
        drivingEstimateInFlight = true
        defer { drivingEstimateInFlight = false }
        let requestID = drivingEstimateRequests.begin()
        let requestStartedAt = Date()
        let requestRevision = sharedRouteRevision
        guard let currentLocation = usableReachabilityLocation else {
            driveTimeEstimate = nil
            SharedTravelTimeEstimateCache.clear(mode: .driving)
            return
        }

        let distanceToStation = currentLocation.distance(from: origin.location)
        guard distanceToStation > StationTravelMode.atStationMeters else {
            driveTimeEstimate = nil
            SharedTravelTimeEstimateCache.clear(mode: .driving)
            return
        }

        if !force, let driveTimeEstimate, driveTimeEstimate.isValid(for: origin, currentLocation: currentLocation) {
            return
        }

        if !force, let cached = SharedTravelTimeEstimateCache.estimate(mode: .driving, origin: origin, currentLocation: currentLocation) {
            driveTimeEstimate = TravelTimeEstimate(originId: origin.id,
                sourceLocation: CLLocation(latitude: cached.sourceLatitude, longitude: cached.sourceLongitude),
                minutes: cached.minutes, fetchedAt: cached.fetchedAt, routeDistanceMeters: cached.routeDistanceMeters)
            return
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocation.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false

        do {
            let response = try await MKDirections(request: request).calculate()
            guard drivingEstimateRequests.accepts(requestID), sharedRouteRevision == requestRevision,
                  let latestLocation = usableReachabilityLocation,
                  latestLocation.distance(from: currentLocation) < 50 else { return }
            guard isViewingToday, originId == origin.id, !Task.isCancelled else { return }
            guard locationProvider.authorizationStatus == .authorizedAlways
                    || locationProvider.authorizationStatus == .authorizedWhenInUse else { return }
            guard let route = response.routes.first else { return }

            let routeMinutes = max(1, Int(ceil(route.expectedTravelTime / 60)))
            let estimate = TravelTimeEstimate(
                originId: origin.id,
                sourceLocation: currentLocation,
                minutes: routeMinutes,
                fetchedAt: Date()
            )
            driveTimeEstimate = estimate
            SharedTravelTimeEstimateCache.save(
                mode: .driving,
                origin: origin,
                currentLocation: currentLocation,
                minutes: estimate.minutes,
                fetchedAt: estimate.fetchedAt,
                requestStartedAt: requestStartedAt
            )
        } catch {
            guard drivingEstimateRequests.accepts(requestID), sharedRouteRevision == requestRevision else { return }
            guard isViewingToday, originId == origin.id, !Task.isCancelled else { return }
            driveTimeEstimate = nil
            SharedTravelTimeEstimateCache.clear(mode: .driving, ifNotNewerThan: requestStartedAt, originId: origin.id)
        }
    }

    @MainActor
    private func refreshAll(forceSpecialScheduleRefresh: Bool = false) async {
        guard !isRefreshing else { return }

        isRefreshing = true
        defer {
            isRefreshing = false
        }

        // Schedule revisions take priority over routing estimates and service alerts.
        await specialScheduleProvider.refreshNow(for: selectedScheduleDate, force: forceSpecialScheduleRefresh)
        applyCachedSpecialSchedules()
        refreshDepartures()

        if locationProvider.authorizationStatus == .authorizedAlways
            || locationProvider.authorizationStatus == .authorizedWhenInUse {
            locationProvider.requestLocation()
        }

        if let currentFeed = scheduleStore.baseScheduleFeed {
            let updateResult = await PATCOGTFSUpdateService.shared.updateIfNeeded(currentFeed: currentFeed)
            if case .updated = updateResult {
                scheduleStore.load()
                applyCachedSpecialSchedules()
                applyDefaultsIfNeeded()
                refreshDepartures()
                requestWidgetReload(reason: "Automatic schedule update", force: true)
            } else if case .current = updateResult {
                // An unchanged successful download still advances the schedule-check timestamp.
                scheduleStore.load()
                applyCachedSpecialSchedules()
            }
        }

        driveTimeEstimate = nil
        walkingTimeEstimate = nil
        updateReachabilityLocationIfNeeded(locationProvider.currentLocation, force: true)
        refreshDepartures()
        if let origin = selectedStation(originId) {
            await refreshWalkingTimeEstimate(origin: origin, force: true)
            await refreshDriveTimeEstimate(origin: origin, force: true)
            refreshDepartures()
        }

        await alertProvider.refreshNow()
        requestWidgetReload(reason: "App refresh completed")
    }

    private func applyCachedSpecialSchedules() {
        let now = Date()
        var dates = [now]
        if let yesterday = patcoCalendar.date(byAdding: .day, value: -1, to: now) {
            dates.append(yesterday)
        }
        if let tomorrow = patcoCalendar.date(byAdding: .day, value: 1, to: now) {
            dates.append(tomorrow)
        }
        if !isViewingToday {
            dates.append(selectedScheduleDate)
            if let previousSelectedDay = patcoCalendar.date(byAdding: .day, value: -1, to: selectedScheduleDate) {
                dates.append(previousSelectedDay)
            }
        }
        let schedules = SharedSpecialScheduleCache.schedules(matching: dates, calendar: patcoCalendar)
        scheduleStore.applySpecialSchedules(schedules)
    }

    @MainActor
    private func checkFutureSpecialSchedule(for date: Date) async {
        isCheckingFutureSpecialSchedule = true
        futureSpecialScheduleCheckFailed = false
        let result = await SharedSpecialScheduleCache.refreshIfNeeded(from: date, calendar: patcoCalendar)
        guard !Task.isCancelled, patcoCalendar.isDate(selectedScheduleDate, inSameDayAs: date) else { return }
        applyCachedSpecialSchedules()
        refreshDepartures()
        futureSpecialScheduleCheckFailed = result.failed
        isCheckingFutureSpecialSchedule = false
    }

    private func swapStations(saveRoute: Bool = false) {
        let oldOrigin = originId
        originId = destinationId
        destinationId = oldOrigin
        routeSelectionChanged(saveRoute: saveRoute)
    }
}

private struct ArrivalAnnouncement: Identifiable, Equatable {
    let id = UUID()
    let stationName: String
    let returnStationName: String
    var inferredArrival = false
}

enum SharedRouteDefaults {
    private static let suiteName = "group.com.rhome.patconext"
    private static let originKey = "defaultOriginStationId"
    private static let destinationKey = "defaultDestinationStationId"
    private static let temporaryOriginKey = "temporaryOriginStationId"
    private static let temporaryDestinationKey = "temporaryDestinationStationId"
    private static let temporarySavedAtKey = "temporaryRouteSavedAt"
    private static let journeyDestinationKey = "journeyDestinationStationId"
    private static let journeyDirectionSavedAtKey = "journeyDirectionSavedAt"
    private static let manualStationSelectionKey = "manualStationSelectionId"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func savedRoute() -> (originId: Station.ID, destinationId: Station.ID)? {
        if let route = SharedRouteCoordinator.current() {
            return (route.savedOriginId, route.savedDestinationId)
        }
        guard let originId = defaults.string(forKey: originKey),
              let destinationId = defaults.string(forKey: destinationKey),
              originId != destinationId else {
            return nil
        }

        return (originId, destinationId)
    }

    static func save(originId: Station.ID, destinationId: Station.ID,
                     selectionLocation: CLLocation? = nil, destinationLocation: CLLocation? = nil) {
        SharedRouteCoordinator.commit(originId: originId, destinationId: destinationId, manual: true,
                                      selectionLocation: selectionLocation, destinationLocation: destinationLocation)
        defaults.set(originId, forKey: originKey)
        defaults.set(destinationId, forKey: destinationKey)
    }

    static func temporaryRoute(maxAge: TimeInterval = 12 * 60 * 60) -> (originId: Station.ID, destinationId: Station.ID)? {
        guard let originId = defaults.string(forKey: temporaryOriginKey),
              let destinationId = defaults.string(forKey: temporaryDestinationKey),
              let savedAt = defaults.object(forKey: temporarySavedAtKey) as? Date,
              Date().timeIntervalSince(savedAt) <= maxAge,
              originId != destinationId else {
            return nil
        }

        return (originId, destinationId)
    }

    static func saveTemporary(originId: Station.ID, destinationId: Station.ID) {
        defaults.set(originId, forKey: temporaryOriginKey)
        defaults.set(destinationId, forKey: temporaryDestinationKey)
        defaults.set(Date(), forKey: temporarySavedAtKey)
    }

    static func clearTemporary() {
        defaults.removeObject(forKey: temporaryOriginKey)
        defaults.removeObject(forKey: temporaryDestinationKey)
        defaults.removeObject(forKey: temporarySavedAtKey)
    }

    static func journeyDestinationId(maxAge: TimeInterval = 4 * 60 * 60) -> Station.ID? {
        guard let destinationId = defaults.string(forKey: journeyDestinationKey),
              let savedAt = defaults.object(forKey: journeyDirectionSavedAtKey) as? Date,
              Date().timeIntervalSince(savedAt) <= maxAge else {
            clearJourneyDirection()
            return nil
        }
        return destinationId
    }

    static func saveJourneyDirection(destinationId: Station.ID) {
        defaults.set(destinationId, forKey: journeyDestinationKey)
        defaults.set(Date(), forKey: journeyDirectionSavedAtKey)
    }

    static func clearJourneyDirection() {
        defaults.removeObject(forKey: journeyDestinationKey)
        defaults.removeObject(forKey: journeyDirectionSavedAtKey)
    }

    static func manuallySelectedAtStationId() -> Station.ID? {
        defaults.string(forKey: manualStationSelectionKey)
    }

    static func saveManualStationSelection(stationId: Station.ID) {
        defaults.set(stationId, forKey: manualStationSelectionKey)
    }

    static func clearManualStationSelection() {
        defaults.removeObject(forKey: manualStationSelectionKey)
    }

}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
