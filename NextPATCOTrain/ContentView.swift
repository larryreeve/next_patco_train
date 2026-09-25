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
    @AppStorage("hasSeenLocationPermissionExplanation") private var hasSeenLocationPermissionExplanation = false

    @StateObject private var scheduleStore = PATCOScheduleStore()
    @StateObject private var locationProvider = LocationProvider()
    @StateObject private var alertProvider = PATCOAlertProvider()
    @StateObject private var specialScheduleProvider = PATCOSpecialScheduleProvider()

    @State private var originId: Station.ID?
    @State private var destinationId: Station.ID?
    @State private var selectedScheduleDate = Date()
    @State private var draftScheduleDate = Date()
    @State private var isShowingScheduleDatePicker = false
    @State private var departures: [Departure] = []
    @State private var nearestRouteStationName: String?
    @State private var currentStationId: Station.ID?
    @State private var currentStationName: String?
    @State private var arrivalAnnouncement: ArrivalAnnouncement?
    @State private var temporaryRouteOriginalOriginId: Station.ID?
    @State private var temporaryRouteOriginalDestinationId: Station.ID?
    @State private var selectedDeparture: Departure?
    @State private var inAppBrowserURL: BrowserURL?
    @State private var isRouteExpanded = false
    @State private var isAlertsExpanded = false
    @State private var isRefreshing = false
    @State private var isShowingAbout = false
    @State private var isShowingLocationPermissionExplanation = false
    @State private var lastDeparturesUpdatedAt = Date()
    @State private var driveTimeEstimate: TravelTimeEstimate?
    @State private var walkingTimeEstimate: TravelTimeEstimate?
    @State private var reachabilityLocation: CLLocation?
    @State private var lastReachabilityLocationUpdate: Date?
    @State private var lastWidgetReachabilityReloadAt: Date?
    @State private var lastWidgetReloadRequestAt: Date?
    @State private var pendingDepartureDeepLink: DepartureDeepLink?
    @State private var isScheduleRecoveryRefreshing = false
    @State private var scheduleRecoveryMessage: String?
    @State private var isCheckingFutureSpecialSchedule = false
    @State private var futureSpecialScheduleCheckFailed = false

    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private let foregroundLocationRefreshTimer = Timer.publish(every: 2 * 60, on: .main, in: .common).autoconnect()
    private let alertRefreshTimer = Timer.publish(every: 120, on: .main, in: .common).autoconnect()
    private let specialScheduleRefreshTimer = Timer.publish(every: 60 * 60, on: .main, in: .common).autoconnect()
    private let reachabilityLocationMinInterval: TimeInterval = 30
    private let reachabilityLocationMinDistance: CLLocationDistance = 250
    private let widgetReachabilityReloadInterval: TimeInterval = 2 * 60
    private let widgetReloadMinInterval: TimeInterval = 60
    private let forcedWidgetReloadDedupeInterval: TimeInterval = 2
    private let destinationArrivalMaxLocationAge: TimeInterval = 30
    private let destinationArrivalMaxLocationAccuracy: CLLocationAccuracy = 75
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
        guard let origin = departures.first?.origin else {
            return false
        }

        if currentStationId == origin.id {
            return true
        }
        return reachabilityLocation.map {
            $0.distance(from: origin.location) <= StationTravelMode.atStationMeters
        } ?? false
    }
    private var reachabilityGuidance: (title: String, detail: String?, systemImage: String)? {
        guard isViewingToday,
              let departure = departures.first else {
            return nil
        }
        let origin = departure.origin

        if isAtDepartureStation {
            return ("Showing departures from \(origin.name) to \(departure.destination.name) based on your location.", nil, "tram.fill")
        }

        guard let status = reachabilityStatus(for: departure, enforceOneHourLimit: true) else {
            return nil
        }
        let compactOriginName = origin.name.replacingOccurrences(of: " and ", with: " & ")
        guard let arrivalSummary = status.stationArrivalSummary(at: compactOriginName) else {
            return nil
        }
        let systemImage = arrivalSummary.mode == .driving ? "car.fill" : "figure.walk"
        return (arrivalSummary.title, arrivalSummary.detail, systemImage)
    }
    private var currentReachabilityMode: StationTravelMode? {
        guard isViewingToday,
              let currentLocation = reachabilityLocation,
              let firstDeparture = departures.first else {
            return nil
        }

        guard currentStationId != firstDeparture.origin.id else { return nil }

        let distanceToStation = currentLocation.distance(from: firstDeparture.origin.location)
        guard distanceToStation <= StationTravelMode.reachabilityMaxDistanceMeters else {
            return nil
        }

        guard distanceToStation > StationTravelMode.atStationMeters else {
            SharedReachabilityModeStore.clearOnArrival(originId: firstDeparture.origin.id)
            return nil
        }

        let minutesUntilDeparture = Int(floor(firstDeparture.departureDate.timeIntervalSinceNow / 60))
        guard let sharedMode = SharedReachabilityModeStore.resolve(
            originId: firstDeparture.origin.id,
            distanceToStation: distanceToStation,
            minutesUntilDeparture: minutesUntilDeparture,
            defaultsToWalking: firstDeparture.origin.defaultsToWalkingForReachability
        ) else {
            return nil
        }

        return StationTravelMode(sharedMode)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color.patcoWine, Color.patcoCharcoal, Color.patcoRail], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                VStack(spacing: 12) {
                    header
                        .padding(.top, 10)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 3) {
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

                            Capsule()
                                .fill(Color.patcoGold.opacity(0.82))
                                .frame(height: 1)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Next PATCO Train")
                        .accessibilityAddTraits(.isHeader)

                        if !hidesPromotionalDates {
                            Button {
                                draftScheduleDate = selectedScheduleDate
                                isShowingScheduleDatePicker = true
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "calendar")
                                    Text(selectedScheduleDateHeaderText)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.88))
                                .padding(.horizontal, 8)
                                .frame(minHeight: 30)
                                .background(.white.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Choose departure date, \(selectedScheduleDateHeaderText)")
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingAbout = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.title3.weight(.bold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.patcoGold)
                            .frame(width: 36, height: 36)
                            .background(Color.patcoCharcoal.opacity(0.78), in: Circle())
                            .overlay(
                                Circle()
                                    .stroke(Color.patcoGold.opacity(0.42), lineWidth: 1)
                            )
                            .shadow(color: Color.black.opacity(0.20), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Information about Next PATCO Train")
                }
            }
            .sheet(item: $selectedDeparture) { departure in
                TripDetailView(departure: departure, stops: tripStops(for: departure), catchStatus: catchStatus(for: departure)) {
                    selectedDeparture = nil
                }
                .presentationDetents([.large])
            }
            .sheet(isPresented: $isShowingScheduleDatePicker) {
                scheduleDatePickerSheet
            }
            .sheet(isPresented: $isShowingAbout) {
                AboutView(
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
                    .presentationDetents([.medium])
            }
            .sheet(item: $inAppBrowserURL) { browserURL in
                SafariView(url: browserURL.url)
                    .ignoresSafeArea()
                    .interactiveDismissDisabled()
                    .presentationDragIndicator(.hidden)
            }
            .onAppear {
                SharedWidgetDiagnostics.record("App opened", detail: "Main screen appeared")
                applyDefaultsIfNeeded()
                applyCachedSpecialSchedules()
                prepareLocationAccess()
                refreshDepartures()
                Task {
                    await PATCOLiveActivityStarter.endExpiredActivities()
                    await refreshAll()
                }
            }
            .onReceive(refreshTimer) { _ in
                if selectedScheduleDate < patcoCalendar.startOfDay(for: Date()) {
                    selectedScheduleDate = Date()
                }
                refreshDepartures()
                completeDestinationArrivalIfNeeded()
            }
            .onReceive(foregroundLocationRefreshTimer) { _ in
                guard scenePhase == .active else { return }
                guard locationProvider.authorizationStatus == .authorizedAlways
                        || locationProvider.authorizationStatus == .authorizedWhenInUse else {
                    return
                }
                locationProvider.requestLocation()
            }
            .onReceive(alertRefreshTimer) { _ in
                alertProvider.refresh()
            }
            .onReceive(specialScheduleRefreshTimer) { _ in
                if isViewingToday {
                    specialScheduleProvider.refresh()
                } else {
                    Task { await checkFutureSpecialSchedule(for: selectedScheduleDate) }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    startLocationUpdatesIfAuthorized()
                    refreshForForeground()
                } else {
                    locationProvider.stopUpdatingLocation()
                }
            }
            .onChange(of: scheduleStore.stations) { _, _ in
                applyDefaultsIfNeeded()
                applyNearestStation(locationProvider.currentLocation)
                refreshDepartures()
            }
            .onChange(of: originId) { _, _ in
                refreshDepartures()
                resolvePendingDepartureDeepLink()
            }
            .onChange(of: destinationId) { _, _ in
                refreshDepartures()
                resolvePendingDepartureDeepLink()
            }
            .onChange(of: selectedScheduleDate) { _, _ in
                applyCachedSpecialSchedules()
                refreshDepartures()
            }
            .task(id: patcoCalendar.startOfDay(for: selectedScheduleDate)) {
                guard !isViewingToday else {
                    isCheckingFutureSpecialSchedule = false
                    futureSpecialScheduleCheckFailed = false
                    return
                }
                await checkFutureSpecialSchedule(for: selectedScheduleDate)
            }
            .onChange(of: locationProvider.currentLocation) { _, location in
                handleLocationUpdate(location)
            }
            .onChange(of: specialScheduleProvider.lastUpdated) { _, _ in
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
    }

    private func prepareLocationAccess() {
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

    private func requestLocationAccess() {
        locationProvider.startUpdatingLocation()
    }

    private func requestWidgetReload(reason: String, force: Bool = false) {
        let now = Date()
        let minInterval = force ? forcedWidgetReloadDedupeInterval : widgetReloadMinInterval
        if let lastWidgetReloadRequestAt,
           now.timeIntervalSince(lastWidgetReloadRequestAt) < minInterval {
            SharedWidgetDiagnostics.record(
                "App widget reload skipped",
                detail: "\(reason) throttled"
            )
            return
        }

        lastWidgetReloadRequestAt = now
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
            GeometryReader { geometry in
                Text(routeSummary)
                    .font(.system(size: routeSummaryFontSize(for: geometry.size.width), weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.95)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 28)

            HStack(alignment: .center, spacing: 12) {
                if let routeDetailSummary {
                    Text(routeDetailSummary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.74))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer(minLength: 8)

                Button {
                    withAnimation(.snappy) {
                        isRouteExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(isRouteExpanded ? "Done" : "Change")
                            .font(.caption.weight(.bold))

                        Image(systemName: isRouteExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.14), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRouteExpanded ? "Hide route controls" : "Change route")
            }

            if isRouteExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if currentStationName == nil {
                        locationControl
                    }

                    HStack(spacing: 10) {
                        stationPicker(title: "From", selection: $originId) {
                            routeSelectionChanged(saveRoute: true)
                        }
                        stationPicker(title: "To", selection: $destinationId) {
                            routeSelectionChanged(saveRoute: true)
                        }
                    }

                    Button {
                        swapStations(saveRoute: true)
                    } label: {
                        Label("Swap direction", systemImage: "arrow.left.arrow.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .accessibilityLabel("Swap stations")
                }
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
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
        if let currentStationId, let currentStationName {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.patcoGold)
                        .frame(width: 32, height: 32)
                        .background(Color.black.opacity(0.18), in: Circle())

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Current station")
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
                } else if currentStationId == originId {
                    Label("This route departs from your current station", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
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
                    await refreshAll()
                }
            } label: {
                Image(systemName: "location.fill")
                    .font(.subheadline)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.patcoGold)
            .foregroundStyle(Color.patcoCharcoal)
            .accessibilityLabel("Find nearest station")

            locationSummary

            Spacer(minLength: 8)
        }
    }

    @ViewBuilder
    private var locationSummary: some View {
        if let nearestRouteStationName {
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
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 30, height: 30)
                    .background(Color.patcoCharcoal.opacity(0.16), in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text("Special schedule applied")
                        .font(.subheadline.weight(.bold))
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
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.patcoCharcoal.opacity(0.14), in: Capsule())
            }
            .foregroundStyle(Color.patcoCharcoal)
            .padding(10)
            .background(Color.patcoGold, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.42), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the source PDF in the app")
    }

    private func specialScheduleSubtitle(for schedule: ActiveSpecialSchedule) -> String? {
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

    private var departuresHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    departuresHeading

                    Text("Departures updated \(lastDeparturesUpdatedAt.formatted(date: .omitted, time: .shortened))")
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
               !isAtDepartureStation {
                HStack(alignment: .top, spacing: 12) {
                    travelModePicker(selected: currentReachabilityMode)
                        .frame(maxWidth: .infinity, alignment: .leading)

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
                                .font(.caption.weight(.medium))
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
        HStack(spacing: 8) {
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
        VStack(spacing: 2) {
            Image(systemName: image)
                .font(.subheadline.weight(.bold))
                .frame(width: 38, height: 38)
                .background(Color.patcoCharcoal.opacity(0.10), in: Circle())

            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.patcoCharcoal.opacity(0.74))
        }
        .frame(width: 46)
    }

    private func travelModePicker(selected: StationTravelMode) -> some View {
        HStack(spacing: 0) {
            travelModeControl(label: "Car", image: "car.fill", mode: .driving, selected: selected)
            travelModeControl(label: "Walk", image: "figure.walk", mode: .walking, selected: selected)
        }
        .background(Color.patcoCharcoal.opacity(0.10), in: Capsule())
    }

    private func travelModeControl(label: String, image: String, mode: StationTravelMode, selected: StationTravelMode) -> some View {
        Button {
            setReachabilityMode(mode)
        } label: {
            Label(label, systemImage: image)
                .font(.caption.weight(.bold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .foregroundStyle(mode == selected ? Color.white : Color.patcoCharcoal.opacity(0.58))
                .background(mode == selected ? Color.patcoWine : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use \(label.lowercased()) reachability")
        .accessibilityAddTraits(mode == selected ? .isSelected : [])
    }

    private var reachabilityUnavailableMessage: String? {
        guard isViewingToday, reachabilityLocation == nil else { return nil }

        switch locationProvider.authorizationStatus {
        case .notDetermined, .denied, .restricted:
            return "Reachability unavailable - enable Location Services"
        default:
            return locationProvider.errorMessage == nil
                ? nil
                : "Reachability unavailable - refresh your location"
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
        VStack(alignment: .leading, spacing: 12) {
            departuresHeader

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
                if isAtDepartureStation {
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
                    Label(reachabilityUnavailableMessage, systemImage: "location.slash")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.patcoWine.opacity(0.78))

                    Button(reachabilityLocationActionTitle) {
                        performReachabilityLocationAction()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(Color.patcoWine)
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
                ViewThatFits(in: .vertical) {
                    departureRows()
                        .fixedSize(horizontal: false, vertical: true)

                    ScrollView {
                        departureRows()
                    }
                    .scrollIndicators(.visible)
                    .refreshable {
                        await refreshAll(forceSpecialScheduleRefresh: true)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
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

    private func departureRows() -> some View {
        let firstLikelyDepartureID = departures.first { departure in
            listCatchStatus(for: departure)?.isLikelyToCatch == true
        }?.id

        return LazyVStack(spacing: 7) {
            ForEach(departures.indices, id: \.self) { index in
                let departure = departures[index]
                if index == laterDepartureStartIndex {
                    laterDeparturesDivider
                }
                let catchStatus = listCatchStatus(for: departure)
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
        .padding(.vertical, 2)
    }

    private var laterDepartureStartIndex: Int? {
        guard let index = departures.firstIndex(where: {
            $0.departureDate.timeIntervalSinceNow > 60 * 60
        }), index > 0 else {
            return nil
        }
        return index
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

                Button {
                    alertProvider.refresh()
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
                    ForEach(alerts.prefix(3)) { alert in
                        AlertRow(alert: alert)
                    }

                    if alerts.count > 3 {
                        Text("+\(alerts.count - 3) more")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.62))
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

    private func catchStatus(for departure: Departure) -> TrainCatchStatus? {
        guard !departure.isRemovedBySpecialSchedule else { return nil }
        guard isViewingToday else { return nil }
        return reachabilityStatus(for: departure, enforceOneHourLimit: true)
    }

    private func listCatchStatus(for departure: Departure) -> TrainCatchStatus? {
        guard !departure.isRemovedBySpecialSchedule else { return nil }
        guard isViewingToday else { return nil }
        guard let status = reachabilityStatus(for: departure, enforceOneHourLimit: true) else {
            return nil
        }

        if case .atStation = status {
            return nil
        }

        return status
    }

    private func reachabilityStatus(for departure: Departure, enforceOneHourLimit: Bool) -> TrainCatchStatus? {
        if currentStationId == departure.origin.id {
            return .atStation
        }
        guard let currentLocation = reachabilityLocation else {
            return nil
        }

        let distanceToStation = currentLocation.distance(from: departure.origin.location)
        let minutesUntilDeparture = Int(floor(departure.departureDate.timeIntervalSinceNow / 60))
        guard distanceToStation <= StationTravelMode.reachabilityMaxDistanceMeters else {
            return nil
        }

        guard !enforceOneHourLimit || minutesUntilDeparture <= 60 else {
            return nil
        }
        if distanceToStation <= StationTravelMode.atStationMeters {
            return .atStation
        }

        let travelMode = currentReachabilityMode ?? StationTravelMode.inferred(
            forMeters: distanceToStation,
            minutesUntilDeparture: minutesUntilDeparture
        )
        let stationBufferMinutes = travelMode.stationBufferMinutes
        let travelMinutes = travelMinutes(
            for: travelMode,
            distanceToStation: distanceToStation,
            origin: departure.origin,
            currentLocation: currentLocation
        )
        let spareMinutes = minutesUntilDeparture - travelMinutes - stationBufferMinutes
        let arrivalAtStationDate = Date().addingTimeInterval(TimeInterval(travelMinutes * 60))
        let leaveByDate = departure.departureDate.addingTimeInterval(-TimeInterval((travelMinutes + stationBufferMinutes) * 60))

        if spareMinutes >= 10 {
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
        guard let location else {
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

        guard shouldUpdate else { return }

        reachabilityLocation = location
        lastReachabilityLocationUpdate = now
        driveTimeEstimate = nil
        walkingTimeEstimate = nil
        if let origin = selectedStation(originId),
           origin.location.distance(from: location) <= StationTravelMode.atStationMeters,
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
        if let location {
            SharedCurrentLocationCache.save(location)
        }

        let detectedStationId = location.flatMap { stationAtCurrentLocation($0)?.id }
        let crossedStationBoundary = detectedStationId != currentStationId

        var transaction = Transaction()
        transaction.disablesAnimations = crossedStationBoundary
        withTransaction(transaction) {
            applyNearestStation(location)
            updateReachabilityLocationIfNeeded(location, force: crossedStationBoundary)
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

        SharedReachabilityModeStore.save(mode: mode.sharedMode, originId: origin.id)
        refreshDepartures()
        requestWidgetReload(reason: "Reachability mode changed", force: true)
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
        guard let location else {
            nearestRouteStationName = nil
            currentStationId = nil
            currentStationName = nil
            restoreRouteAfterLeavingStation()
            return
        }

        let station = stationAtCurrentLocation(location)
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

        currentStationId = station?.id
        currentStationName = station?.name

        let expectedArrivalDestinationId = SharedRouteDefaults.journeyDestinationId() ?? destinationId
        if let expectedArrivalDestinationId,
           station?.id == expectedArrivalDestinationId,
           completeDestinationArrivalIfNeeded(
               station: station,
               location: location,
               expectedDestinationId: expectedArrivalDestinationId
           ) {
            return
        }

        if isUsingTemporaryStationRoute {
            if station?.id != originId {
                restoreRouteAfterLeavingStation()
            } else {
                nearestRouteStationName = station?.name
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
                    destinationId: SharedRouteDefaults.journeyDestinationId() ?? destinationId
                )
            }
            return
        }

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

        if let journeyDestinationId = SharedRouteDefaults.journeyDestinationId(),
           journeyDestinationId == routeEndpoints.origin.id || journeyDestinationId == routeEndpoints.destination.id {
            originId = journeyDestinationId == routeEndpoints.origin.id
                ? routeEndpoints.destination.id
                : routeEndpoints.origin.id
            destinationId = journeyDestinationId
            return
        }

        guard !isRouteExpanded else {
            return
        }

        let originDistance = routeEndpoints.origin.location.distance(from: location)
        let destinationDistance = routeEndpoints.destination.location.distance(from: location)
        if originDistance <= destinationDistance {
            originId = routeEndpoints.origin.id
            destinationId = routeEndpoints.destination.id
        } else {
            originId = routeEndpoints.destination.id
            destinationId = routeEndpoints.origin.id
        }
    }

    @discardableResult
    private func completeDestinationArrivalIfNeeded(
        station: Station? = nil,
        location: CLLocation? = nil,
        expectedDestinationId: Station.ID? = nil
    ) -> Bool {
        guard let location = location ?? locationProvider.currentLocation,
              let arrivalStation = station ?? stationAtCurrentLocation(location) else {
            return false
        }
        if let manuallySelectedAtStationId = SharedRouteDefaults.manuallySelectedAtStationId(),
           manuallySelectedAtStationId == arrivalStation.id {
            return false
        }

        let destinationId = expectedDestinationId
            ?? SharedRouteDefaults.journeyDestinationId()
            ?? self.destinationId
        guard let destinationId,
              arrivalStation.id == destinationId,
              location.horizontalAccuracy > 0,
              location.horizontalAccuracy <= destinationArrivalMaxLocationAccuracy,
              (0...destinationArrivalMaxLocationAge).contains(Date().timeIntervalSince(location.timestamp)),
              location.distance(from: arrivalStation.location) + location.horizontalAccuracy
                <= StationTravelMode.atStationMeters else {
            return false
        }

        return completeDestinationArrival(at: arrivalStation, destinationId: destinationId)
    }

    @discardableResult
    private func completeDestinationArrival(at arrivalStation: Station, destinationId: Station.ID) -> Bool {
        guard self.destinationId == destinationId,
              let returnStation = selectedStation(isUsingTemporaryStationRoute ? temporaryRouteOriginalOriginId : originId),
              returnStation.id != arrivalStation.id else {
            return false
        }

        if isUsingTemporaryStationRoute {
            temporaryRouteOriginalOriginId = nil
            temporaryRouteOriginalDestinationId = nil
            SharedRouteDefaults.clearTemporary()
        }
        originId = arrivalStation.id
        self.destinationId = returnStation.id
        SharedRouteDefaults.save(originId: arrivalStation.id, destinationId: returnStation.id)
        SharedRouteDefaults.saveJourneyDirection(destinationId: returnStation.id)
        nearestRouteStationName = arrivalStation.name
        refreshDepartures()
        requestWidgetReload(reason: "Journey arrived; return route ready", force: true)
        Task { await PATCOLiveActivityStarter.endActivities(arrivingAt: arrivalStation.name) }
        showArrivalAnnouncement(at: arrivalStation, returningTo: returnStation)
        return true
    }

    private func showArrivalAnnouncement(at arrivalStation: Station, returningTo returnStation: Station) {
        let announcement = ArrivalAnnouncement(
            stationName: arrivalStation.name,
            returnStationName: returnStation.name
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
                Text("Near \(announcement.stationName)")
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

    private func refreshDepartures() {
        lastDeparturesUpdatedAt = Date()
        guard let origin = selectedStation(originId), let destination = selectedStation(destinationId), origin != destination else {
            departures = []
            return
        }

        let now = Date()
        if !isViewingToday {
            let selectedDay = patcoCalendar.startOfDay(for: selectedScheduleDate)
            departures = scheduleStore.departures(
                from: origin,
                to: destination,
                after: selectedDay,
                limit: nil,
                includingRemovedSpecialScheduleDepartures: true
            )
                .filter { patcoCalendar.isDate($0.departureDate, inSameDayAs: selectedDay) }
            resolvePendingDepartureDeepLink()
            return
        }

        let upcomingDepartures = scheduleStore.departures(
            from: origin,
            to: destination,
            after: now,
            limit: nil,
            includingRemovedSpecialScheduleDepartures: true
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

    private func handleDeepLink(_ url: URL) {
        if url.host == "widget" {
            refreshForForeground()
            return
        }

        guard let deepLink = DepartureDeepLink(url: url) else {
            return
        }

        pendingDepartureDeepLink = deepLink
        selectedScheduleDate = Date()
        originId = deepLink.originId
        destinationId = deepLink.destinationId
        refreshDepartures()
        resolvePendingDepartureDeepLink()
    }

    private func resolvePendingDepartureDeepLink() {
        guard let deepLink = pendingDepartureDeepLink else {
            return
        }

        guard originId == deepLink.originId, destinationId == deepLink.destinationId else {
            return
        }

        guard let departure = departure(matching: deepLink) else {
            return
        }

        selectedDeparture = departure
        pendingDepartureDeepLink = nil
    }

    private func departure(matching deepLink: DepartureDeepLink) -> Departure? {
        if let visibleDeparture = departures.first(where: { candidate in
            abs(candidate.departureDate.timeIntervalSince(deepLink.departureDate)) < 60
        }) {
            return visibleDeparture
        }

        guard let origin = selectedStation(deepLink.originId),
              let destination = selectedStation(deepLink.destinationId),
              origin != destination else {
            return nil
        }

        let lookupStart = deepLink.departureDate.addingTimeInterval(-60)
        return scheduleStore.departures(from: origin, to: destination, after: lookupStart, limit: 6)
            .first { candidate in
                abs(candidate.departureDate.timeIntervalSince(deepLink.departureDate)) < 60
            }
    }

    private func routeSelectionChanged(saveRoute: Bool = false) {
        if saveRoute {
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
        destinationId preferredDestinationId: Station.ID? = nil
    ) {
        guard let originId,
              let destinationId else {
            return
        }
        let temporaryDestinationId = preferredDestinationId ?? destinationId
        guard stationId != temporaryDestinationId else { return }

        temporaryRouteOriginalOriginId = originId
        temporaryRouteOriginalDestinationId = destinationId
        self.originId = stationId
        self.destinationId = temporaryDestinationId
        SharedRouteDefaults.saveTemporary(originId: stationId, destinationId: temporaryDestinationId)
        requestWidgetReload(reason: "Temporary station route changed", force: true)
        isRouteExpanded = false
    }

    private func restoreRouteAfterLeavingStation() {
        guard let originalOriginId = temporaryRouteOriginalOriginId,
              let originalDestinationId = temporaryRouteOriginalDestinationId else {
            return
        }

        clearTemporaryStationRoute()
        originId = originalOriginId
        destinationId = originalDestinationId
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
        guard let nearestStation = scheduleStore.nearestStation(to: location),
              nearestStation.location.distance(from: location) <= StationTravelMode.atStationMeters else {
            return nil
        }

        return nearestStation
    }

    private func saveSelectedRoute() {
        guard let originId, let destinationId, originId != destinationId else {
            return
        }

        SharedRouteDefaults.clearJourneyDirection()
        SharedRouteDefaults.save(originId: originId, destinationId: destinationId)
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
    ) -> Int {
        if mode == .walking,
           let walkingTimeEstimate,
           walkingTimeEstimate.isValid(for: origin, currentLocation: currentLocation) {
            return walkingTimeEstimate.minutes
        }

        guard mode == .driving,
              let driveTimeEstimate,
              driveTimeEstimate.isValid(for: origin, currentLocation: currentLocation) else {
            return mode.travelMinutes(forMeters: distanceToStation)
        }

        return driveTimeEstimate.minutes
    }

    @MainActor
    private func refreshTravelTimeEstimatesIfNeeded(origin: Station) async {
        await refreshWalkingTimeEstimate(origin: origin, force: false)
        await refreshDriveTimeEstimate(origin: origin, force: false)
    }

    @MainActor
    private func refreshWalkingTimeEstimate(origin: Station, force: Bool) async {
        guard let currentLocation = reachabilityLocation ?? locationProvider.currentLocation else {
            walkingTimeEstimate = nil
            SharedTravelTimeEstimateCache.clear(mode: .walking)
            return
        }

        let distanceToStation = currentLocation.distance(from: origin.location)
        guard distanceToStation > StationTravelMode.atStationMeters,
              distanceToStation <= StationTravelMode.farEnoughToDriveMeters else {
            walkingTimeEstimate = nil
            SharedTravelTimeEstimateCache.clear(mode: .walking)
            return
        }

        if !force, let walkingTimeEstimate, walkingTimeEstimate.isValid(for: origin, currentLocation: currentLocation) {
            return
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocation.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.transportType = .walking
        request.requestsAlternateRoutes = false

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else { return }

            let estimate = TravelTimeEstimate(
                originId: origin.id,
                sourceLocation: currentLocation,
                minutes: max(1, Int(ceil(route.expectedTravelTime / 60))),
                fetchedAt: Date()
            )
            walkingTimeEstimate = estimate
            SharedTravelTimeEstimateCache.save(
                mode: .walking,
                origin: origin,
                currentLocation: currentLocation,
                minutes: estimate.minutes,
                fetchedAt: estimate.fetchedAt
            )
        } catch {
            walkingTimeEstimate = nil
            SharedTravelTimeEstimateCache.clear(mode: .walking)
        }
    }

    @MainActor
    private func refreshDriveTimeEstimate(origin: Station, force: Bool) async {
        guard let currentLocation = reachabilityLocation ?? locationProvider.currentLocation else {
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

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocation.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false

        do {
            let response = try await MKDirections(request: request).calculate()
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
                fetchedAt: estimate.fetchedAt
            )
        } catch {
            driveTimeEstimate = nil
            SharedTravelTimeEstimateCache.clear(mode: .driving)
        }
    }

    @MainActor
    private func refreshAll(forceSpecialScheduleRefresh: Bool = false) async {
        guard !isRefreshing else { return }

        isRefreshing = true
        defer {
            isRefreshing = false
        }

        if let currentFeed = scheduleStore.baseScheduleFeed {
            let updateResult = await PATCOGTFSUpdateService.shared.updateIfNeeded(currentFeed: currentFeed)
            if case .updated = updateResult {
                scheduleStore.load()
                applyCachedSpecialSchedules()
                applyDefaultsIfNeeded()
                refreshDepartures()
                requestWidgetReload(reason: "Automatic schedule update", force: true)
            }
        }

        driveTimeEstimate = nil
        walkingTimeEstimate = nil
        updateReachabilityLocationIfNeeded(locationProvider.currentLocation, force: true)
        if locationProvider.authorizationStatus == .authorizedAlways
            || locationProvider.authorizationStatus == .authorizedWhenInUse {
            locationProvider.requestLocation()
        }
        refreshDepartures()
        if let origin = selectedStation(originId) {
            await refreshWalkingTimeEstimate(origin: origin, force: true)
            await refreshDriveTimeEstimate(origin: origin, force: true)
            refreshDepartures()
        }

        await alertProvider.refreshNow()
        Task {
            await specialScheduleProvider.refreshNow(for: selectedScheduleDate, force: forceSpecialScheduleRefresh)
        }
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
}

private struct DepartureDeepLink: Equatable {
    let originId: Station.ID
    let destinationId: Station.ID
    let departureDate: Date

    init?(url: URL) {
        guard url.scheme == "patconext",
              url.host == "departure",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let originId = components.queryItems?.first(where: { $0.name == "origin" })?.value,
              let destinationId = components.queryItems?.first(where: { $0.name == "destination" })?.value,
              let departureValue = components.queryItems?.first(where: { $0.name == "departure" })?.value,
              let departureTimeInterval = TimeInterval(departureValue) else {
            return nil
        }

        self.originId = originId
        self.destinationId = destinationId
        self.departureDate = Date(timeIntervalSince1970: departureTimeInterval)
    }
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
        guard let originId = defaults.string(forKey: originKey),
              let destinationId = defaults.string(forKey: destinationKey),
              originId != destinationId else {
            return nil
        }

        return (originId, destinationId)
    }

    static func save(originId: Station.ID, destinationId: Station.ID) {
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
