import ActivityKit
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
    @State private var departures: [Departure] = []
    @State private var nearestRouteStationName: String?
    @State private var currentStationId: Station.ID?
    @State private var currentStationName: String?
    @State private var temporaryRouteOriginalOriginId: Station.ID?
    @State private var temporaryRouteOriginalDestinationId: Station.ID?
    @State private var selectedDeparture: Departure?
    @State private var inAppBrowserURL: BrowserURL?
    @State private var isRouteExpanded = false
    @State private var isAlertsExpanded = false
    @State private var isRefreshing = false
    @State private var isShowingAbout = false
    @State private var isShowingLocationPermissionExplanation = false
    @State private var lastRefreshedAt = Date()
    @State private var driveTimeEstimate: TravelTimeEstimate?
    @State private var walkingTimeEstimate: TravelTimeEstimate?
    @State private var reachabilityLocation: CLLocation?
    @State private var lastReachabilityLocationUpdate: Date?
    @State private var lastWidgetReachabilityReloadAt: Date?
    @State private var pendingDepartureDeepLink: DepartureDeepLink?
    @State private var isScheduleRecoveryRefreshing = false
    @State private var scheduleRecoveryMessage: String?

    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private let alertRefreshTimer = Timer.publish(every: 120, on: .main, in: .common).autoconnect()
    private let specialScheduleRefreshTimer = Timer.publish(every: 900, on: .main, in: .common).autoconnect()
    private let reachabilityLocationMinInterval: TimeInterval = 30
    private let reachabilityLocationMinDistance: CLLocationDistance = 250
    private let widgetReachabilityReloadInterval: TimeInterval = 2 * 60
    private let hidesPromotionalDates = ProcessInfo.processInfo.arguments.contains("-promotionalScreenshots")
    private var patcoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
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
    private var currentAsOfDate: Date {
        if scheduleStore.activeSpecialSchedule != nil, let lastUpdated = specialScheduleProvider.lastUpdated {
            return lastUpdated
        }

        return lastRefreshedAt
    }
    private var showsWalkingEstimateHint: Bool {
        departures.contains { reachabilityStatus(for: $0, enforceOneHourLimit: false) != nil }
    }
    private var isAtDepartureStation: Bool {
        guard let currentLocation = reachabilityLocation,
              let origin = departures.first?.origin else {
            return false
        }

        return currentLocation.distance(from: origin.location) <= StationTravelMode.atStationMeters
    }
    private var reachabilityGuidance: (text: String, systemImage: String)? {
        guard showsWalkingEstimateHint, let origin = departures.first?.origin else {
            return nil
        }

        if isAtDepartureStation {
            return ("You're at \(origin.name) station. Departures below leave from here.", "tram.fill")
        }

        if currentReachabilityMode == .driving {
            return ("Reachability includes driving time plus time to park and walk to the platform.", "car.fill")
        }

        return ("Reachability uses your estimated walking time to \(origin.name) station.", "figure.walk")
    }
    private var currentReachabilityMode: StationTravelMode? {
        guard let currentLocation = reachabilityLocation,
              let firstDeparture = departures.first else {
            return nil
        }

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
            minutesUntilDeparture: minutesUntilDeparture
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
                    if currentStationName != nil {
                        currentStationPanel
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
                    VStack(spacing: 0) {
                        Text("Next PATCO Train")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .accessibilityAddTraits(.isHeader)

                        if !hidesPromotionalDates {
                            Text(todayHeaderText)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.7))
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
            .sheet(isPresented: $isShowingAbout) {
                AboutView(
                    locationAuthorizationStatus: locationProvider.authorizationStatus,
                    scheduleFeedEndDate: scheduleStore.scheduleFeedEndDate,
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
                applyDefaultsIfNeeded()
                prepareLocationAccess()
                refreshDepartures()
                Task {
                    await PATCOLiveActivityStarter.endExpiredActivities()
                    await refreshAll()
                }
            }
            .onReceive(refreshTimer) { _ in
                refreshDepartures()
            }
            .onReceive(alertRefreshTimer) { _ in
                alertProvider.refresh()
            }
            .onReceive(specialScheduleRefreshTimer) { _ in
                specialScheduleProvider.refresh()
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
            .onChange(of: locationProvider.currentLocation) { _, location in
                if let location {
                    SharedCurrentLocationCache.save(location)
                }
                applyNearestStation(location)
                updateReachabilityLocationIfNeeded(location)
            }
            .onChange(of: specialScheduleProvider.specialSchedule) { _, specialSchedule in
                if let specialSchedule {
                    SharedSpecialScheduleCache.save([specialSchedule])
                    scheduleStore.applySpecialSchedules([specialSchedule])
                } else {
                    scheduleStore.clearSpecialSchedule()
                }
                refreshDepartures()
                WidgetCenter.shared.reloadAllTimelines()
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

    @MainActor
    private func forceGTFSUpdate() async -> String {
        guard let currentFeed = scheduleStore.feed else {
            return "Unable to refresh the schedule because the current schedule could not be loaded."
        }

        let result = await PATCOGTFSUpdateService.shared.updateIfNeeded(
            currentFeed: currentFeed,
            force: true
        )
        switch result {
        case .updated:
            scheduleStore.load()
            applyDefaultsIfNeeded()
            refreshDepartures()
            WidgetCenter.shared.reloadAllTimelines()
            return "Schedule refreshed."
        case .notNeeded:
            return "Schedule is up to date."
        case .failed:
            return "Unable to refresh the schedule. Try again."
        }
    }

    private func refreshForForeground() {
        Task {
            await PATCOLiveActivityStarter.endExpiredActivities()
            await refreshAll()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geometry in
                Text(routeSummary)
                    .font(.system(size: routeSummaryFontSize(for: geometry.size.width), weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.95)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 34)

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
                    .padding(.vertical, 7)
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
        .padding(18)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
    }

    private func routeSummaryFontSize(for availableWidth: CGFloat) -> CGFloat {
        let maximumFontSize: CGFloat = 28
        let minimumFontSize: CGFloat = 18
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

                Text("Route direction based on nearest route station")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
            }
        } else if let currentStationName {
            VStack(alignment: .leading, spacing: 2) {
                Label("You're at \(currentStationName) station", systemImage: "mappin.and.ellipse")
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
        if let activeSpecialSchedule = scheduleStore.activeSpecialSchedule {
            specialScheduleBanner(activeSpecialSchedule)
        }
    }

    private func specialScheduleBanner(_ schedule: ActiveSpecialSchedule) -> some View {
        Button {
            inAppBrowserURL = BrowserURL(url: schedule.sourceURL)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.title3.weight(.bold))
                    .frame(width: 34, height: 34)
                    .background(Color.patcoCharcoal.opacity(0.16), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Special schedule applied")
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    if !hidesPromotionalDates {
                        Text(schedule.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Text("View PDF")
                        .font(.caption.weight(.bold))

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.patcoCharcoal.opacity(0.14), in: Capsule())
            }
            .foregroundStyle(Color.patcoCharcoal)
            .padding(14)
            .background(Color.patcoGold, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.42), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the source PDF in the app")
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
        HStack(alignment: .top, spacing: 6) {
            departuresHeading
            Spacer(minLength: 2)
            departureControls
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var departuresHeading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scheduled Departures")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.patcoCharcoal)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .allowsTightening(true)

            Text("Schedule checked \(currentAsOfDate.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(Color.patcoCharcoal.opacity(0.62))
                .lineLimit(1)
        }
    }

    private var departureControls: some View {
        HStack(spacing: 6) {
            if let currentReachabilityMode {
                Button {
                    setReachabilityMode(
                        currentReachabilityMode == .driving ? .walking : .driving
                    )
                } label: {
                    Label(
                        currentReachabilityMode == .driving ? "Car" : "Walk",
                        systemImage: currentReachabilityMode == .driving ? "car.fill" : "figure.walk"
                    )
                    .font(.caption2.weight(.bold))
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .frame(minHeight: 26)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.patcoCharcoal.opacity(0.45))
                .accessibilityLabel(
                    currentReachabilityMode == .driving
                        ? "Car reachability. Switch to walking"
                        : "Walking reachability. Switch to car"
                )
            }

            Button {
                if let origin = selectedStation(originId) {
                    openDirections(to: origin, mode: currentReachabilityMode ?? .walking)
                }
            } label: {
                Label("Map", systemImage: "map.fill")
                    .font(.caption2.weight(.bold))
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .frame(minHeight: 26)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Color.patcoCharcoal.opacity(0.45))
            .disabled(locationProvider.currentLocation == nil || selectedStation(originId) == nil)
            .accessibilityLabel("Open directions to the departure station")

            Button {
                Task {
                    await refreshAll()
                }
            } label: {
                if isRefreshInProgress {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 26, height: 26)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.bold))
                        .frame(width: 26, height: 26)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Color.patcoCharcoal.opacity(0.45))
            .disabled(isRefreshInProgress)
            .accessibilityLabel("Refresh departures")
        }
    }

    private var reachabilityUnavailableMessage: String? {
        guard reachabilityLocation == nil else { return nil }

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

            if let reachabilityGuidance {
                if isAtDepartureStation {
                    Label(reachabilityGuidance.text, systemImage: reachabilityGuidance.systemImage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(red: 0.05, green: 0.38, blue: 0.20))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 0.72, green: 0.92, blue: 0.78).opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Label(reachabilityGuidance.text, systemImage: reachabilityGuidance.systemImage)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.patcoCharcoal.opacity(0.58))
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
                    Text("Try the opposite direction or choose a different station pair.")
                } actions: {
                    Button("Reverse Route") {
                        swapStations(saveRoute: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.patcoWine)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(departures) { departure in
                            DepartureRow(
                                departure: departure,
                                catchStatus: listCatchStatus(for: departure),
                                hidesDayLabel: hidesPromotionalDates,
                                onSelect: {
                                    selectedDeparture = departure
                                }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.visible)
                .refreshable {
                    await refreshAll()
                }
            }
        }
        .padding(16)
        .background(Color.patcoCream.opacity(0.95), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.patcoGold.opacity(0.5), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .layoutPriority(1)
    }

    private var scheduleRefreshButton: some View {
        VStack(spacing: 8) {
            Button {
                Task {
                    isScheduleRecoveryRefreshing = true
                    scheduleRecoveryMessage = await forceGTFSUpdate()
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
        guard let departure = departures.first else { return nil }

        return "\(departure.directionLabel) • \(departure.travelMinutes) min"
    }

    private func catchStatus(for departure: Departure) -> TrainCatchStatus? {
        reachabilityStatus(for: departure, enforceOneHourLimit: true)
    }

    private func listCatchStatus(for departure: Departure) -> TrainCatchStatus? {
        guard let status = reachabilityStatus(for: departure, enforceOneHourLimit: false) else {
            return nil
        }

        if case .atStation = status {
            return nil
        }

        let minutesUntilDeparture = Int(floor(departure.departureDate.timeIntervalSinceNow / 60))
        if minutesUntilDeparture <= 60 {
            return status
        }

        guard let departureIndex = departures.firstIndex(where: { $0.id == departure.id }),
              let firstReachableIndex = departures.firstIndex(where: { candidate in
                  reachabilityStatus(for: candidate, enforceOneHourLimit: false)?.isReachableForDisplay == true
              }) else {
            return nil
        }

        return departureIndex <= firstReachableIndex ? status : nil
    }

    private func reachabilityStatus(for departure: Departure, enforceOneHourLimit: Bool) -> TrainCatchStatus? {
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
        let arrivalAtStationDate = Date().addingTimeInterval(TimeInterval((travelMinutes + stationBufferMinutes) * 60))

        if spareMinutes >= 3 {
            return .comfortable(travelMinutes: travelMinutes, mode: travelMode, arrivalAtStationDate: arrivalAtStationDate)
        }
        if spareMinutes >= 0 {
            return .tight(travelMinutes: travelMinutes, mode: travelMode, arrivalAtStationDate: arrivalAtStationDate)
        }
        if spareMinutes < -5 {
            return .tooLate(travelMinutes: travelMinutes, mode: travelMode, arrivalAtStationDate: arrivalAtStationDate)
        }
        return .probablyMissed(travelMinutes: travelMinutes, mode: travelMode, arrivalAtStationDate: arrivalAtStationDate)
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
            WidgetCenter.shared.reloadAllTimelines()
            lastWidgetReachabilityReloadAt = now
        } else if lastWidgetReachabilityReloadAt.map({
            now.timeIntervalSince($0) >= widgetReachabilityReloadInterval
        }) ?? true {
            WidgetCenter.shared.reloadAllTimelines()
            lastWidgetReachabilityReloadAt = now
        }
        refreshDepartures()
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
        WidgetCenter.shared.reloadAllTimelines()
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

    private var todayHeaderText: String {
        let formatter = DateFormatter()
        formatter.calendar = patcoCalendar
        formatter.timeZone = patcoCalendar.timeZone
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: Date())
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
        currentStationId = station?.id
        currentStationName = station?.name

        if isUsingTemporaryStationRoute {
            guard station?.id == originId else {
                restoreRouteAfterLeavingStation()
                return
            }

            nearestRouteStationName = station?.name
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
        guard let origin = selectedStation(originId), let destination = selectedStation(destinationId), origin != destination else {
            departures = []
            return
        }

        let now = Date()
        let upcomingDepartures = scheduleStore.departures(from: origin, to: destination, after: now, limit: nil)
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
        }
        applyNearestStation(
            locationProvider.currentLocation ?? SharedCurrentLocationCache.location()
        )
        refreshDepartures()
    }

    private var isUsingTemporaryStationRoute: Bool {
        temporaryRouteOriginalOriginId != nil && temporaryRouteOriginalDestinationId != nil
    }

    private var savedStartingStationName: String {
        selectedStation(temporaryRouteOriginalOriginId)?.name ?? "saved starting location"
    }

    private func useCurrentStationAsTemporaryOrigin(_ stationId: Station.ID) {
        guard let originId,
              let destinationId,
              stationId != destinationId else {
            return
        }

        temporaryRouteOriginalOriginId = originId
        temporaryRouteOriginalDestinationId = destinationId
        self.originId = stationId
        SharedRouteDefaults.saveTemporary(originId: stationId, destinationId: destinationId)
        WidgetCenter.shared.reloadAllTimelines()
        isRouteExpanded = false
        refreshDepartures()
    }

    private func restoreRouteAfterLeavingStation() {
        guard let originalOriginId = temporaryRouteOriginalOriginId,
              let originalDestinationId = temporaryRouteOriginalDestinationId else {
            return
        }

        clearTemporaryStationRoute()
        originId = originalOriginId
        destinationId = originalDestinationId
        refreshDepartures()
    }

    private func clearTemporaryStationRoute() {
        let hadTemporaryRoute = isUsingTemporaryStationRoute || SharedRouteDefaults.temporaryRoute() != nil
        temporaryRouteOriginalOriginId = nil
        temporaryRouteOriginalDestinationId = nil
        SharedRouteDefaults.clearTemporary()
        if hadTemporaryRoute {
            WidgetCenter.shared.reloadAllTimelines()
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

        SharedRouteDefaults.save(originId: originId, destinationId: destinationId)
        WidgetCenter.shared.reloadAllTimelines()
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
    private func refreshAll() async {
        guard !isRefreshing else { return }

        isRefreshing = true
        defer {
            lastRefreshedAt = Date()
            isRefreshing = false
        }

        if let currentFeed = scheduleStore.feed {
            let updateResult = await PATCOGTFSUpdateService.shared.updateIfNeeded(currentFeed: currentFeed)
            if case .updated = updateResult {
                scheduleStore.load()
                applyDefaultsIfNeeded()
                WidgetCenter.shared.reloadAllTimelines()
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
        await specialScheduleProvider.refreshNow()

        let specialSchedules = await specialSchedulesForDepartureWindow()
        if !specialSchedules.isEmpty {
            SharedSpecialScheduleCache.save(specialSchedules)
            scheduleStore.applySpecialSchedules(specialSchedules)
        } else {
            scheduleStore.clearSpecialSchedule()
        }

        refreshDepartures()
        if let origin = selectedStation(originId) {
            await refreshWalkingTimeEstimate(origin: origin, force: true)
            await refreshDriveTimeEstimate(origin: origin, force: true)
            refreshDepartures()
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func specialSchedulesForDepartureWindow() async -> [PATCOSpecialSchedule] {
        var schedules: [PATCOSpecialSchedule] = []
        if let specialSchedule = specialScheduleProvider.specialSchedule {
            schedules.append(specialSchedule)
        }

        guard let tomorrow = patcoCalendar.date(byAdding: .day, value: 1, to: Date()),
              let tomorrowSpecialSchedule = try? await PATCOSpecialScheduleLoader.specialSchedule(for: tomorrow, calendar: patcoCalendar),
              !schedules.contains(where: { patcoCalendar.isDate($0.serviceDate, inSameDayAs: tomorrowSpecialSchedule.serviceDate) }) else {
            return schedules
        }

        schedules.append(tomorrowSpecialSchedule)
        return schedules
    }

    private func swapStations(saveRoute: Bool = false) {
        let oldOrigin = originId
        originId = destinationId
        destinationId = oldOrigin
        routeSelectionChanged(saveRoute: saveRoute)
    }
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
}

private struct TripDetailStop: Identifiable {
    let station: Station
    let stopTime: StopTime

    var id: String {
        "\(station.id)-\(stopTime.sequence)"
    }
}

private struct BrowserURL: Identifiable {
    let url: URL

    var id: String {
        url.absoluteString
    }
}

private struct StationInformationDestination: Identifiable {
    let stationName: String
    let url: URL

    var id: String {
        "\(stationName)|\(url.absoluteString)"
    }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let viewController = SFSafariViewController(url: url)
        viewController.dismissButtonStyle = .close
        viewController.isModalInPresentation = true
        return viewController
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

private enum StationInformationLoadState: Equatable {
    case loading
    case loaded
    case failed
}

private struct StationInformationWebView: UIViewRepresentable {
    let url: URL
    @Binding var loadState: StationInformationLoadState

    func makeCoordinator() -> Coordinator {
        Coordinator(loadState: $loadState)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        loadState = .loading
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding private var loadState: StationInformationLoadState

        init(loadState: Binding<StationInformationLoadState>) {
            _loadState = loadState
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            loadState = .loading
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            loadState = .loaded
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            loadState = .failed
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
            loadState = .failed
        }
    }
}

private struct StationInformationBrowser: View {
    @Environment(\.openURL) private var openURL

    let url: URL

    @State private var loadState: StationInformationLoadState = .loading
    @State private var reloadID = UUID()

    var body: some View {
        ZStack {
            StationInformationWebView(url: url, loadState: $loadState)
                .id(reloadID)

            if loadState == .loading {
                ProgressView("Loading station information...")
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            } else if loadState == .failed {
                ContentUnavailableView {
                    Label("Unable to Load Station Information", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Check your connection, then try again.")
                } actions: {
                    Button("Try Again") {
                        loadState = .loading
                        reloadID = UUID()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.patcoWine)

                    Button("Open in Safari") {
                        openURL(url)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .background(Color.white)
            }
        }
        .background(Color.white)
    }
}

private struct StationInformationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let destination: StationInformationDestination

    var body: some View {
        NavigationStack {
            StationInformationBrowser(url: destination.url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("\(destination.stationName) Station")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            openURL(destination.url)
                        } label: {
                            Image(systemName: "safari")
                        }
                        .accessibilityLabel("Open in Safari")

                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close station information")
                    }
                }
        }
        .interactiveDismissDisabled()
        .presentationDragIndicator(.hidden)
    }
}

private enum PATCOLiveActivityStarter {
    static let activityDidChangeNotification = Notification.Name("PATCOLiveActivityDidChange")

    @MainActor
    static func isShowing(departure: Departure) -> Bool {
        matchingActivity(for: departure) != nil
    }

    @MainActor
    static func stop(departure: Departure) async -> String {
        guard let activity = matchingActivity(for: departure) else {
            return "Not currently showing on Lock Screen."
        }

        await activity.end(nil, dismissalPolicy: .immediate)
        NotificationCenter.default.post(name: activityDidChangeNotification, object: nil)
        return "Removed from Lock Screen."
    }

    @MainActor
    static func start(departure: Departure, stops: [TripDetailStop]) async -> String {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return "Live Activities are disabled in Settings."
        }

        let scheduledStops = Array(stops.dropFirst())
        let attributes = PATCOTripActivityAttributes(
            routeTitle: "\(departure.origin.name) to \(departure.destination.name)",
            originName: departure.origin.name,
            destinationName: departure.destination.name,
            deepLinkURLString: deepLinkURL(for: departure).absoluteString
        )
        let activityStops = scheduledStops.map {
            PATCOTripActivityAttributes.Stop(
                name: $0.station.name,
                arrivalDate: stopDate(for: $0.stopTime, serviceDate: departure.serviceDate)
            )
        }
        let state = contentState(departure: departure, stops: activityStops)
        let dismissalDate = departure.arrivalDate.addingTimeInterval(10 * 60)
        let content = ActivityContent(
            state: state,
            staleDate: dismissalDate
        )

        do {
            for activity in Activity<PATCOTripActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }

            _ = try Activity<PATCOTripActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            NotificationCenter.default.post(name: activityDidChangeNotification, object: nil)
            return "Showing on Lock Screen."
        } catch {
            return "Could not start Live Activity."
        }
    }

    @MainActor
    static func endExpiredActivities(now: Date = Date()) async {
        for activity in Activity<PATCOTripActivityAttributes>.activities {
            let dismissalDate = activity.content.state.arrivalDate.addingTimeInterval(10 * 60)
            if now >= dismissalDate {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private static func matchingActivity(for departure: Departure) -> Activity<PATCOTripActivityAttributes>? {
        let deepLinkURLString = deepLinkURL(for: departure).absoluteString
        return Activity<PATCOTripActivityAttributes>.activities.first {
            $0.attributes.deepLinkURLString == deepLinkURLString
        }
    }

    private static func contentState(
        departure: Departure,
        stops: [PATCOTripActivityAttributes.Stop]
    ) -> PATCOTripActivityAttributes.ContentState {
        PATCOTripActivityAttributes.ContentState(
            departureDate: departure.departureDate,
            arrivalDate: departure.arrivalDate,
            stops: stops,
            statusTitle: nil,
            statusDetail: nil,
            lastUpdated: Date()
        )
    }

    private static func deepLinkURL(for departure: Departure) -> URL {
        var components = URLComponents()
        components.scheme = "patconext"
        components.host = "departure"
        components.queryItems = [
            URLQueryItem(name: "origin", value: departure.origin.id),
            URLQueryItem(name: "destination", value: departure.destination.id),
            URLQueryItem(name: "departure", value: String(departure.departureDate.timeIntervalSince1970))
        ]
        return components.url ?? URL(string: "patconext://departure")!
    }

    private static func stopDate(for stopTime: StopTime, serviceDate: Date) -> Date {
        let components = stopTime.arrival.split(separator: ":").compactMap { Int($0) }
        guard components.count == 3 else {
            return serviceDate
        }

        let seconds = components[0] * 3600 + components[1] * 60 + components[2]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar.date(byAdding: .second, value: seconds, to: serviceDate) ?? serviceDate
    }
}

private struct DepartureRow: View {
    let departure: Departure
    let catchStatus: TrainCatchStatus?
    let hidesDayLabel: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            departureDetails
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens scheduled departure details")
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 8))
    }

    private var departureDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(departureTimeText)
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(Color.patcoPlum)

                if !hidesDayLabel, let departureDayText {
                    Text(departureDayText)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.patcoCharcoal.opacity(0.68))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.patcoGold.opacity(0.30), in: Capsule())
                }

                Spacer(minLength: 8)

                Text(minutesUntilText)
                    .font(.headline)
                    .foregroundStyle(Color.patcoPlum)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            HStack(spacing: 6) {
                Text("Arrives \(arrivalTimeText)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: 6)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.42))
                    .accessibilityHidden(true)
            }

            if let catchStatus {
                Label {
                    Text(catchStatus.displayText)
                } icon: {
                    Image(systemName: catchStatus.systemImage)
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(catchStatus.foregroundColor)
                .labelStyle(.titleAndIcon)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(catchStatus.backgroundColor, in: Capsule())
                .accessibilityLabel(catchStatus.accessibilityText)
            }

            if let scheduleAdjustment = departure.scheduleAdjustment {
                Label(adjustedFromText(scheduleAdjustment), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.patcoWine)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.patcoGold.opacity(0.28), in: Capsule())
                    .accessibilityLabel(adjustedFromAccessibilityText(scheduleAdjustment))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var departureTimeText: String {
        departure.departureDate.formatted(date: .omitted, time: .shortened)
    }

    private var departureDayText: String? {
        let calendar = Self.patcoCalendar
        let now = Date()
        if calendar.isDate(departure.departureDate, inSameDayAs: now) {
            return nil
        }

        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           calendar.isDate(departure.departureDate, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: departure.departureDate)
    }

    private static var patcoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }

    private func adjustedFromText(_ adjustment: ScheduleAdjustment) -> String {
        guard let originalDepartureDate = adjustment.originalDepartureDate else {
            return "Adjusted from standard"
        }

        return "Adjusted from \(originalDepartureDate.formatted(date: .omitted, time: .shortened))"
    }

    private func adjustedFromAccessibilityText(_ adjustment: ScheduleAdjustment) -> String {
        guard let originalDepartureDate = adjustment.originalDepartureDate else {
            return "Adjusted from standard schedule"
        }

        return "Adjusted from standard departure time \(originalDepartureDate.formatted(date: .omitted, time: .shortened))"
    }

    private var arrivalTimeText: String {
        departure.arrivalDate.formatted(date: .omitted, time: .shortened)
    }

    private var minutesUntilText: String {
        let minutes = Int(ceil(departure.departureDate.timeIntervalSinceNow / 60))
        if minutes <= 0 {
            return "Now"
        }
        if minutes >= 60 {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            let hourText = hours == 1 ? "1 hr" : "\(hours) hrs"
            if remainingMinutes == 0 {
                return "in \(hourText)"
            }

            let minuteText = remainingMinutes == 1 ? "1 min" : "\(remainingMinutes) mins"
            return "in \(hourText) \(minuteText)"
        }

        return minutes == 1 ? "in 1 min" : "in \(minutes) mins"
    }
}

private struct TravelTimeEstimate {
    let originId: Station.ID
    let sourceLocation: CLLocation
    let minutes: Int
    let fetchedAt: Date

    func isValid(for origin: Station, currentLocation: CLLocation) -> Bool {
        originId == origin.id
            && Date().timeIntervalSince(fetchedAt) < 5 * 60
            && sourceLocation.distance(from: currentLocation) < 250
    }
}

private enum StationTravelMode {
    case walking
    case driving

    static let atStationMeters = 150.0
    static let closeEnoughToWalkMeters = 0.75 * 1_609.34
    static let farEnoughToDriveMeters = 1.25 * 1_609.34
    static let reachabilityMaxDistanceMeters = 150 * 1_609.34

    init(_ sharedMode: SharedReachabilityModeStore.Mode) {
        self = sharedMode == .driving ? .driving : .walking
    }

    var sharedMode: SharedReachabilityModeStore.Mode {
        self == .driving ? .driving : .walking
    }

    var phrase: String {
        switch self {
        case .walking:
            "walking"
        case .driving:
            "car"
        }
    }

    var detailNoun: String {
        switch self {
            case .walking:
            "walk"
        case .driving:
            "drive"
        }
    }

    var stationArrivalLabel: String {
        switch self {
        case .walking:
            "walk"
        case .driving:
            "car"
        }
    }

    func travelMinutes(forMeters meters: CLLocationDistance) -> Int {
        switch self {
        case .walking:
            if meters <= Self.atStationMeters {
                return 0
            }

            return max(1, Int(ceil((meters / 1.25) / 60)))
        case .driving:
            let metersPerMinuteAt25MPH = 670.56
            return max(1, Int(ceil(meters / metersPerMinuteAt25MPH)))
        }
    }

    static func inferred(
        forMeters meters: CLLocationDistance,
        minutesUntilDeparture: Int
    ) -> StationTravelMode {
        if meters <= closeEnoughToWalkMeters {
            return .walking
        }

        if meters >= farEnoughToDriveMeters {
            return .driving
        }

        let walkingMinutes = StationTravelMode.walking.travelMinutes(forMeters: meters)
        if minutesUntilDeparture - walkingMinutes >= 0 {
            return .walking
        }

        return .driving
    }

    var stationBufferMinutes: Int {
        switch self {
        case .walking:
            0
        case .driving:
            3
        }
    }

    var mapsDirectionsMode: String {
        switch self {
        case .walking:
            MKLaunchOptionsDirectionsModeWalking
        case .driving:
            MKLaunchOptionsDirectionsModeDriving
        }
    }
}

private enum TrainCatchStatus {
    case atStation
    case comfortable(travelMinutes: Int, mode: StationTravelMode, arrivalAtStationDate: Date)
    case tight(travelMinutes: Int, mode: StationTravelMode, arrivalAtStationDate: Date)
    case probablyMissed(travelMinutes: Int, mode: StationTravelMode, arrivalAtStationDate: Date)
    case tooLate(travelMinutes: Int, mode: StationTravelMode, arrivalAtStationDate: Date)

    var title: String {
        switch self {
        case .atStation:
            "At station"
        case .comfortable:
            "Reachable"
        case .tight:
            "Tight"
        case .probablyMissed:
            "May miss"
        case .tooLate:
            "Too late"
        }
    }

    var detail: String {
        switch self {
        case .atStation:
            return ""
        case .comfortable(_, let mode, let arrivalAtStationDate),
                .tight(_, let mode, let arrivalAtStationDate),
                .probablyMissed(_, let mode, let arrivalAtStationDate),
                .tooLate(_, let mode, let arrivalAtStationDate):
            return "Arrive by \(mode.stationArrivalLabel) \(arrivalAtStationDate.formatted(date: .omitted, time: .shortened))"
        }
    }

    var displayText: String {
        if detail.isEmpty {
            return title
        }

        return "\(title) • \(detail)"
    }

    var systemImage: String {
        switch self {
        case .atStation:
            "tram.fill"
        case .comfortable:
            "checkmark.circle.fill"
        case .tight(_, let mode, _):
            mode == .walking ? "figure.walk.motion" : "car.fill"
        case .probablyMissed, .tooLate:
            "clock.badge.exclamationmark.fill"
        }
    }

    var foregroundColor: Color {
        switch self {
        case .atStation, .comfortable:
            Color(red: 0.06, green: 0.34, blue: 0.20)
        case .tight:
            Color(red: 0.39, green: 0.20, blue: 0.02)
        case .probablyMissed, .tooLate:
            Color.patcoWine
        }
    }

    var backgroundColor: Color {
        switch self {
        case .atStation, .comfortable:
            Color(red: 0.72, green: 0.92, blue: 0.78).opacity(0.7)
        case .tight:
            Color.patcoGold.opacity(0.34)
        case .probablyMissed, .tooLate:
            Color(red: 0.96, green: 0.70, blue: 0.70).opacity(0.55)
        }
    }

    var accessibilityText: String {
        switch self {
        case .atStation:
            "\(title). \(detail)."
        case .comfortable(_, let mode, let arrivalAtStationDate),
                .tight(_, let mode, let arrivalAtStationDate),
                .probablyMissed(_, let mode, let arrivalAtStationDate),
                .tooLate(_, let mode, let arrivalAtStationDate):
            "\(title). Estimated station arrival time by \(mode.stationArrivalLabel) is \(arrivalAtStationDate.formatted(date: .omitted, time: .shortened))."
        }
    }

    var isReachableForDisplay: Bool {
        switch self {
        case .atStation, .comfortable, .tight:
            true
        case .probablyMissed, .tooLate:
            false
        }
    }

    var travelMinutes: Int {
        switch self {
        case .atStation:
            0
        case .comfortable(let travelMinutes, _, _), .tight(let travelMinutes, _, _), .probablyMissed(let travelMinutes, _, _), .tooLate(let travelMinutes, _, _):
            travelMinutes
        }
    }

    private var mode: StationTravelMode {
        switch self {
        case .atStation:
            .walking
        case .comfortable(_, let mode, _), .tight(_, let mode, _), .probablyMissed(_, let mode, _), .tooLate(_, let mode, _):
            mode
        }
    }

    private var formattedTravelTime: String {
        Self.formattedDuration(minutes: travelMinutes)
    }

    private static func formattedDuration(minutes: Int) -> String {
        guard minutes >= 60 else {
            return "\(minutes) min"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }
}

private struct TripDetailView: View {
    let departure: Departure
    let stops: [TripDetailStop]
    let catchStatus: TrainCatchStatus?
    let onClose: () -> Void

    @State private var cameraPosition: MapCameraPosition
    @State private var liveActivityMessage: String?
    @State private var isLiveActivityShowing = false
    @State private var liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    @State private var selectedStationInformation: StationInformationDestination?

    init(departure: Departure, stops: [TripDetailStop], catchStatus: TrainCatchStatus?, onClose: @escaping () -> Void) {
        self.departure = departure
        self.stops = stops
        self.catchStatus = catchStatus
        self.onClose = onClose
        _cameraPosition = State(initialValue: .region(Self.region(for: stops.map(\.station.coordinate))))
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 12)
                .background(Color(red: 0.94, green: 0.94, blue: 0.96))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    tripHero
                    liveActivityControls
                    tripSummary
                    routeMap
                    stopTimeline
                }
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .padding(.bottom, 30)
            }
        }
        .background(Color(red: 0.94, green: 0.94, blue: 0.96))
        .sheet(item: $selectedStationInformation) { destination in
            StationInformationSheet(destination: destination)
        }
        .task {
            refreshLiveActivityState()
        }
        .onReceive(NotificationCenter.default.publisher(for: PATCOLiveActivityStarter.activityDidChangeNotification)) { _ in
            refreshLiveActivityState()
        }
    }

    private var sheetHeader: some View {
        ZStack {
            Text("Departure Details")
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.patcoCharcoal)
                .frame(maxWidth: .infinity)

            HStack {
                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.patcoCharcoal)
                        .frame(width: 46, height: 46)
                        .background(Color.white.opacity(0.88), in: Circle())
                }
                .accessibilityLabel("Close trip details")
            }
        }
    }

    private var tripSummary: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 22) {
            summaryItem(title: "One way", value: fare.oneWayText)
            summaryItem(title: "Round trip", value: fare.roundTripText, alignment: .trailing)
            iconSummaryItem(value: bikesAllowedText, systemImage: "bicycle")
            iconSummaryItem(value: wheelchairAccessibleText, systemImage: "figure.roll", alignment: .trailing)
        }
        .padding(22)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
    }

    private var tripHero: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(stationPairText)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.patcoCharcoal)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .frame(maxWidth: .infinity, alignment: .leading)

            tripDirectionSummary

            Divider()

            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 16) {
                        heroTimeItem(
                            title: departureTimeTitle(at: timeline.date),
                            value: departureTimeText,
                            adjustmentText: adjustedFromText,
                            isDeparted: timeline.date >= departure.departureDate
                        )

                        Spacer(minLength: 12)

                        heroTimeItem(
                            title: "Scheduled Arrival",
                            value: arrivalTimeText,
                            isDeparted: timeline.date >= departure.departureDate,
                            alignment: .trailing
                        )
                    }

                    detailDepartureStatus(at: timeline.date)
                }
            }
        }
        .padding(22)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
    }

    private var liveActivityControls: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            if isLiveActivityShowing || timeline.date < departure.departureDate {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer(minLength: 0)

                        Button {
                            Task {
                                await toggleLiveActivity()
                            }
                        } label: {
                            Label(
                                isLiveActivityShowing ? "Remove from Lock Screen" : "Show on Lock Screen",
                                systemImage: isLiveActivityShowing ? "xmark.circle.fill" : "platter.filled.top.and.arrow.up.iphone"
                            )
                                .font(.headline.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(isLiveActivityShowing ? Color.patcoCharcoal.opacity(0.78) : Color.patcoWine)
                        .disabled(!isLiveActivityShowing && !liveActivitiesEnabled)

                        Spacer(minLength: 0)
                    }

                    if let liveActivityStatusMessage {
                        Text(liveActivityStatusMessage)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.patcoCharcoal.opacity(0.66))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
    }

    private var tripDirectionSummary: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Direction")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.58))

                Text(departure.fullDirectionLabel)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.patcoCharcoal)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Text("Ride time")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.58))

                Text(rideTimeText)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.patcoCharcoal)
            }
        }
    }

    private func summaryItem(title: String, value: String, alignment: Alignment = .leading, valueFont: Font = .headline.weight(.bold)) -> some View {
        VStack(alignment: alignment == .trailing ? .trailing : .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.patcoCharcoal.opacity(0.56))

            Text(value)
                .font(valueFont)
                .foregroundStyle(Color.patcoCharcoal)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func iconSummaryItem(value: String, systemImage: String, alignment: Alignment = .leading) -> some View {
        Label(value, systemImage: systemImage)
            .font(.headline.weight(.bold))
            .foregroundStyle(Color.patcoCharcoal)
            .labelStyle(.titleAndIcon)
            .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            .lineLimit(2)
            .minimumScaleFactor(0.78)
            .padding(.top, 3)
            .frame(maxWidth: .infinity, alignment: alignment)
            .accessibilityLabel(value)
    }

    private func heroTimeItem(
        title: String,
        value: String,
        adjustmentText: String? = nil,
        isDeparted: Bool = false,
        alignment: Alignment = .leading
    ) -> some View {
        VStack(alignment: alignment == .trailing ? .trailing : .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.patcoCharcoal.opacity(0.58))

            Text(value)
                .font(.title.weight(.bold))
                .foregroundStyle(Color.patcoWine.opacity(isDeparted ? 0.58 : 1))
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            if let adjustmentText {
                Label(adjustmentText, systemImage: "calendar.badge.exclamationmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.patcoWine)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private var routeMap: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Route map")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.patcoCharcoal)

            Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                if routeCoordinates.count > 1 {
                    MapPolyline(coordinates: routeCoordinates)
                        .stroke(Color.patcoWine, lineWidth: 4)
                }

                ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                    Annotation(stop.station.name, coordinate: stop.station.coordinate) {
                        if index == 0 {
                            Image(systemName: "tram.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.patcoCharcoal)
                                .frame(width: 28, height: 28)
                                .background(Color.patcoGold, in: Circle())
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        } else if index == stops.count - 1 {
                            Image(systemName: "flag.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.patcoWine, in: Circle())
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        } else {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(Color.patcoWine, lineWidth: 3))
                        }
                    }
                }
            }
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var stopTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(remainingStopsTitle)
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.patcoCharcoal)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(scheduledStops.enumerated()), id: \.element.id) { index, stop in
                    StopTimelineRow(
                        stop: stop,
                        timeText: timeText(for: stop, isFinalStop: index == scheduledStops.count - 1),
                        isLast: index == scheduledStops.count - 1,
                        isDestination: index == scheduledStops.count - 1,
                        onOpenStationInformation: { url in
                            selectedStationInformation = StationInformationDestination(
                                stationName: stop.station.name,
                                url: url
                            )
                        }
                    )
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 18)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var routeCoordinates: [CLLocationCoordinate2D] {
        stops.map(\.station.coordinate)
    }

    private var scheduledStops: [TripDetailStop] {
        Array(stops.dropFirst())
    }

    private var remainingStopsTitle: String {
        scheduledStops.count == 1 ? "1 remaining stop" : "\(scheduledStops.count) remaining stops"
    }

    private var departureTimeText: String {
        departure.departureDate.formatted(date: .omitted, time: .shortened)
    }

    private var arrivalTimeText: String {
        departure.arrivalDate.formatted(date: .omitted, time: .shortened)
    }

    private var fare: PATCOFare {
        PATCOFare(origin: departure.origin, destination: departure.destination)
    }

    private var rideTimeText: String {
        "\(departure.travelMinutes) min"
    }

    private var stationPairText: String {
        "\(departure.origin.name) \u{2192} \(departure.destination.name)"
    }

    private var adjustedFromText: String? {
        guard let originalDepartureDate = departure.scheduleAdjustment?.originalDepartureDate else {
            return nil
        }

        return "Adjusted from \(originalDepartureDate.formatted(date: .omitted, time: .shortened))"
    }

    private func departureTimeTitle(at date: Date) -> String {
        guard date >= departure.departureDate else { return "Scheduled Departure" }

        let elapsedMinutes = max(0, Int(date.timeIntervalSince(departure.departureDate) / 60))
        if elapsedMinutes == 0 {
            return "Scheduled just now"
        }

        return "Scheduled \(elapsedMinutes) min ago"
    }

    @ViewBuilder
    private func detailDepartureStatus(at date: Date) -> some View {
        if date >= departure.departureDate {
            Label("Scheduled departure time has passed", systemImage: "clock.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.patcoWine, in: Capsule())
                .frame(maxWidth: .infinity, alignment: .center)
        } else if let catchStatus {
            Label(catchStatus.displayText, systemImage: catchStatus.systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(catchStatus.foregroundColor)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(catchStatus.backgroundColor, in: Capsule())
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel(catchStatus.accessibilityText)
        }
    }

    private var bikesAllowedText: String {
        departure.trip.bikesAllowed ? "Allowed" : "Not allowed"
    }

    private var wheelchairAccessibleText: String {
        departure.trip.wheelchairAccessible ? "Accessible" : "Not accessible"
    }

    @MainActor
    private var liveActivityStatusMessage: String? {
        liveActivityMessage ?? (liveActivitiesEnabled ? nil : "Live Activities are disabled in Settings.")
    }

    @MainActor
    private func toggleLiveActivity() async {
        refreshLiveActivityState()

        let message: String
        if isLiveActivityShowing {
            message = await PATCOLiveActivityStarter.stop(departure: departure)
        } else {
            message = await PATCOLiveActivityStarter.start(departure: departure, stops: stops)
        }

        refreshLiveActivityState()
        liveActivityMessage = Self.isSuccessfulLiveActivityMessage(message) ? nil : message
    }

    private static func isSuccessfulLiveActivityMessage(_ message: String) -> Bool {
        message == "Showing on Lock Screen." || message == "Removed from Lock Screen."
    }

    @MainActor
    private func refreshLiveActivityState() {
        liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        isLiveActivityShowing = PATCOLiveActivityStarter.isShowing(departure: departure)
    }

    private func timeText(for stop: TripDetailStop, isFinalStop: Bool) -> String {
        Self.displayTime(isFinalStop ? stop.stopTime.arrival : stop.stopTime.departure)
    }

    private static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coordinates.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 39.928, longitude: -75.055),
                span: MKCoordinateSpan(latitudeDelta: 0.32, longitudeDelta: 0.42)
            )
        }

        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let minLatitude = latitudes.min() ?? first.latitude
        let maxLatitude = latitudes.max() ?? first.latitude
        let minLongitude = longitudes.min() ?? first.longitude
        let maxLongitude = longitudes.max() ?? first.longitude
        let latitudeDelta = max(0.025, (maxLatitude - minLatitude) * 1.65)
        let longitudeDelta = max(0.025, (maxLongitude - minLongitude) * 1.65)

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }

    private static func displayTime(_ timeString: String) -> String {
        let pieces = timeString.split(separator: ":").compactMap { Int($0) }
        guard pieces.count >= 2 else { return timeString }

        let hour = ((pieces[0] % 24) + 24) % 24
        let minute = pieces[1]
        let period = hour >= 12 ? "PM" : "AM"
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", displayHour, minute, period)
    }
}

private struct PATCOFare {
    let oneWayCents: Int

    init(origin: Station, destination: Station) {
        oneWayCents = Self.oneWayFareCents(origin: origin, destination: destination)
    }

    var oneWayText: String {
        Self.currencyText(cents: oneWayCents)
    }

    var roundTripText: String {
        Self.currencyText(cents: oneWayCents * 2)
    }

    private static func oneWayFareCents(origin: Station, destination: Station) -> Int {
        if isPhiladelphia(origin), isPhiladelphia(destination) {
            return 140
        }

        if isBroadwayCityHallPair(origin, destination) {
            return 140
        }

        if isPhiladelphia(origin) || isPhiladelphia(destination) {
            let newJerseyStation = isPhiladelphia(origin) ? destination : origin
            switch newJerseyStation.name {
            case "Lindenwold", "Ashland", "Woodcrest":
                return 300
            case "Haddonfield", "Westmont", "Collingswood":
                return 260
            case "Ferry Avenue":
                return 225
            case "Broadway", "City Hall":
                return 140
            default:
                return 160
            }
        }

        return 160
    }

    private static func isPhiladelphia(_ station: Station) -> Bool {
        station.name == "Franklin Square"
            || station.name == "8th and Market"
            || station.name == "9/10th and Locust"
            || station.name == "12/13th and Locust"
            || station.name == "15/16th and Locust"
    }

    private static func isBroadwayCityHallPair(_ origin: Station, _ destination: Station) -> Bool {
        Set([origin.name, destination.name]) == Set(["Broadway", "City Hall"])
    }

    private static func currencyText(cents: Int) -> String {
        String(format: "$%.2f", Double(cents) / 100)
    }
}

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let locationAuthorizationStatus: CLAuthorizationStatus
    let scheduleFeedEndDate: Date?
    let onRequestLocation: () -> Void
    let onReloadSchedule: () async -> String
    let onOpenURL: (URL) -> Void

    @State private var isReloadingSchedule = false
    @State private var scheduleReloadMessage: String?

    private let privacyPolicyURL = URL(
        string: "https://github.com/larryreeve/next_patco_train/blob/main/privacy.md"
    )!

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.patcoCream, Color.white.opacity(0.88)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    informationHeader
                        .padding(.horizontal, 22)
                        .padding(.top, 18)
                        .padding(.bottom, 12)
                        .background(Color.patcoCream.opacity(0.96))

                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "tram.fill")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(Color.patcoCharcoal)
                                .frame(width: 42, height: 42)
                                .background(Color.patcoGold, in: Circle())

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Next PATCO Train")
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(Color.patcoCharcoal)

                                Text("Unofficial PATCO schedule app")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.patcoCharcoal.opacity(0.62))

                                Text(versionText)
                                    .font(.caption2.weight(.medium).monospacedDigit())
                                    .foregroundStyle(Color.patcoCharcoal.opacity(0.50))
                            }
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Next PATCO Train is an unofficial PATCO schedule app and is not affiliated with or endorsed by PATCO or the Delaware River Port Authority.")
                                .font(.callout)
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.patcoCharcoal.opacity(0.10), lineWidth: 1)
                        )

                        VStack(spacing: 10) {
                            aboutLinkRow(
                                title: "Official PATCO website",
                                subtitle: "Confirm alerts and service changes",
                                systemImage: "safari",
                                url: URL(string: "https://www.ridepatco.org/")!
                            )

                            aboutLinkRow(
                                title: "@ridepatco on X",
                                subtitle: "Check recent posts from PATCO",
                                systemImage: "bubble.left.and.text.bubble.right.fill",
                                url: URL(string: "https://x.com/ridepatco")!,
                                opensExternally: true
                            )
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Label("Schedule information", systemImage: "clock.badge.exclamationmark")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.patcoWine)

                            Text("Departures, widgets, and Lock Screen views show scheduled times only and do not reflect real-time train movement. Schedule information may change without notice. Confirm service changes through PATCO’s official website before traveling.")
                                .font(.callout)
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.78))
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)

                            Text("Driving estimates include 3 additional minutes to allow for walking from the parking lot to the station platform.")
                                .font(.callout)
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)

                            Text("Schedules update automatically. Refresh manually to check now.")
                                .font(.footnote)
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.66))
                                .fixedSize(horizontal: false, vertical: true)

                            Label(scheduleFeedStatusText, systemImage: scheduleFeedStatusIcon)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(scheduleFeedStatusColor)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 4)

                            Button {
                                Task {
                                    isReloadingSchedule = true
                                    scheduleReloadMessage = await onReloadSchedule()
                                    isReloadingSchedule = false
                                }
                            } label: {
                                if isReloadingSchedule {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(Color.patcoCharcoal)
                                        Text("Refreshing Schedule...")
                                    }
                                } else {
                                    Label("Refresh Schedule", systemImage: "arrow.triangle.2.circlepath")
                                }
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.patcoCharcoal)
                            .buttonStyle(.borderedProminent)
                            .tint(Color.patcoGold)
                            .disabled(isReloadingSchedule)

                            if let scheduleReloadMessage {
                                Text(scheduleReloadMessage)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.patcoCharcoal.opacity(0.66))
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.patcoCharcoal.opacity(0.10), lineWidth: 1)
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            Label("Reachability", systemImage: "figure.walk.motion")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.patcoCharcoal)

                            Text("Choose driving or walking to control estimates to the station. Your choice remains active until you arrive at a station, when the app returns to automatic mode for the next trip.")
                                .font(.callout)
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)

                            if let locationActionTitle {
                                Button(locationActionTitle) {
                                    performLocationAction()
                                }
                                .font(.subheadline.weight(.semibold))
                                .buttonStyle(.bordered)
                                .tint(Color.patcoWine)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.patcoCharcoal.opacity(0.10), lineWidth: 1)
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            Label("Siri shortcut", systemImage: "sparkles")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.patcoCharcoal)

                            Text("To ask Siri \"what are the next PATCO trains,\" create a personal shortcut in the Shortcuts app. Add the Next PATCO Train action named Get Next PATCO Trains, then name the shortcut \"What are the next PATCO trains.\"")
                                .font(.callout)
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.patcoCharcoal.opacity(0.10), lineWidth: 1)
                        )

                        VStack(alignment: .leading, spacing: 10) {
                            Label("Privacy", systemImage: "hand.raised.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.patcoCharcoal)

                            Text("Next PATCO Train does not collect personal data. With your permission, location is used for route orientation and reachability, stored locally for widgets, and may be sent to Apple Maps to calculate travel estimates. It is not sent to the developer or used for tracking.")
                                .font(.callout)
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)

                            Button {
                                onOpenURL(privacyPolicyURL)
                            } label: {
                                Label("Read privacy policy", systemImage: "doc.text")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.patcoWine)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.patcoCharcoal.opacity(0.10), lineWidth: 1)
                        )

                        VStack(alignment: .leading, spacing: 10) {
                            Label("Open Source Software", systemImage: "shippingbox.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.patcoCharcoal)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("ZIPFoundation 0.9.20")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(Color.patcoCharcoal)

                                Text("Copyright © 2017–2025 Thomas Zoechling")
                                    .font(.footnote)
                                    .foregroundStyle(Color.patcoCharcoal.opacity(0.66))
                            }

                            NavigationLink {
                                OpenSourceLicenseView()
                            } label: {
                                Label("View MIT license", systemImage: "doc.text")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.patcoWine)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.patcoCharcoal.opacity(0.10), lineWidth: 1)
                        )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 6)
                        .padding(.bottom, 28)
                    }
                    .scrollIndicators(.visible)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var informationHeader: some View {
        ZStack {
            Text("Information")
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.patcoCharcoal)
                .frame(maxWidth: .infinity)

            HStack {
                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.patcoCharcoal)
                        .frame(width: 46, height: 46)
                        .background(Color.white.opacity(0.88), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close information")
            }
        }
    }

    private var versionText: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "Version unavailable"
        }

        return "Version \(version)"
    }

    private var scheduleFeedIsExpired: Bool {
        guard let scheduleFeedEndDate else { return true }
        return Date() >= Calendar.current.date(byAdding: .day, value: 1, to: scheduleFeedEndDate) ?? scheduleFeedEndDate
    }

    private var scheduleFeedStatusText: String {
        guard let scheduleFeedEndDate else {
            return "Schedule feed expiration is unavailable."
        }
        let date = scheduleFeedEndDate.formatted(date: .long, time: .omitted)
        return scheduleFeedIsExpired
            ? "Schedule feed expired on \(date)."
            : "Current schedule is valid through \(date)."
    }

    private var scheduleFeedStatusIcon: String {
        scheduleFeedIsExpired ? "calendar.badge.exclamationmark" : "calendar.badge.checkmark"
    }

    private var scheduleFeedStatusColor: Color {
        scheduleFeedIsExpired ? Color.patcoWine : Color.patcoCharcoal.opacity(0.72)
    }

    private var locationActionTitle: String? {
        switch locationAuthorizationStatus {
        case .notDetermined:
            return "Enable Location"
        case .denied, .restricted:
            return "Open Location Settings"
        default:
            return nil
        }
    }

    private func performLocationAction() {
        switch locationAuthorizationStatus {
        case .notDetermined:
            onRequestLocation()
        case .denied, .restricted:
            guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
            openURL(settingsURL)
        default:
            break
        }
    }

    private func aboutLinkRow(
        title: String,
        subtitle: String,
        systemImage: String,
        url: URL,
        opensExternally: Bool = false
    ) -> some View {
        Button {
            if opensExternally {
                openURL(url)
            } else {
                onOpenURL(url)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(Color.patcoCharcoal)
                    .frame(width: 34, height: 34)
                    .background(Color.patcoGold.opacity(0.95), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.bold))

                    Text(subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.patcoCharcoal.opacity(0.58))
                }

                Spacer()

                Image(systemName: opensExternally ? "arrow.up.right.square" : "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.50))
            }
            .foregroundStyle(Color.patcoCharcoal)
            .padding(14)
            .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.patcoGold.opacity(0.34), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct OpenSourceLicenseView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                Text("Open Source Software included in Next PATCO Train")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Color.patcoCharcoal)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 7) {
                    Text("ZIPFoundation")
                        .font(.headline.weight(.bold))

                    Text("MIT License (MIT)")
                        .font(.body)

                    Link(
                        "github.com/weichsel/ZIPFoundation",
                        destination: URL(string: "https://github.com/weichsel/ZIPFoundation")!
                    )
                    .font(.body)
                    .foregroundStyle(Color.patcoWine)

                    Text("Copyright (c) 2017-2025 Thomas Zoechling")
                        .font(.body)
                        .padding(.top, 8)

                    Text(Self.licenseText)
                        .font(.body)
                        .foregroundStyle(Color.patcoCharcoal.opacity(0.86))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
        }
        .background(Color.white.ignoresSafeArea())
        .navigationTitle("Open Source Software")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let licenseText = """
    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}

private struct StopTimelineRow: View {
    let stop: TripDetailStop
    let timeText: String
    let isLast: Bool
    let isDestination: Bool
    let onOpenStationInformation: (URL) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Circle()
                    .fill(isDestination ? Color.patcoWine : Color.white)
                    .overlay(Circle().stroke(Color.patcoWine, lineWidth: 3))
                    .frame(width: 22, height: 22)

                if !isLast {
                    Rectangle()
                        .fill(Color.patcoWine)
                        .frame(width: 3, height: 38)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let stationURL {
                        Button {
                            onOpenStationInformation(stationURL)
                        } label: {
                            Text(stop.station.name)
                                .font(.title3.weight(isDestination ? .bold : .semibold))
                                .foregroundStyle(Color.patcoCharcoal)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show information for \(stop.station.name) station")
                    } else {
                        Text(stop.station.name)
                            .font(.title3.weight(isDestination ? .bold : .semibold))
                            .foregroundStyle(Color.patcoCharcoal)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }

                    if isDestination {
                        Text("Destination")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.patcoWine)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.patcoGold.opacity(0.28), in: Capsule())
                    }
                }

                Spacer(minLength: 8)

                Text(timeText)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.62))

                if let stationURL {
                    Button {
                        onOpenStationInformation(stationURL)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.patcoWine)
                            .frame(width: 44, height: 44)
                            .background(Color.patcoWine.opacity(0.08), in: Circle())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show information for \(stop.station.name) station")
                    .help("Show station information")
                }
            }
            .padding(.bottom, isLast ? 0 : 22)
            .overlay(alignment: .bottom) {
                if !isLast {
                    Divider()
                        .padding(.leading, 4)
                }
            }
        }
        .padding(.horizontal, isDestination ? 10 : 0)
        .padding(.vertical, isDestination ? 10 : 0)
        .background(
            isDestination ? Color.patcoGold.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private var stationURL: URL? {
        guard let url = URL(string: stop.station.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        return url
    }
}

private struct VisibleAlert: Identifiable {
    let id: String
    let title: String
    let url: URL?

    init?(_ alert: PATCOAlertItem) {
        guard let title = alert.displayTitle,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        self.title = title
        self.url = alert.url
        self.id = "\(title.lowercased())|\(alert.url?.absoluteString ?? "")"
    }
}

private struct AlertRow: View {
    let alert: VisibleAlert
    var lineLimit: Int? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(Color.patcoGold)
                .padding(.top, 7)

            if let url = alert.url {
                Link(destination: url) {
                    alertTitle
                }
            } else {
                alertTitle
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var alertTitle: some View {
        Text(alert.title)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .lineLimit(lineLimit)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension Color {
    static let patcoWine = Color(red: 0.42, green: 0.02, blue: 0.11)
    static let patcoCharcoal = Color(red: 0.08, green: 0.10, blue: 0.12)
    static let patcoRail = Color(red: 0.15, green: 0.18, blue: 0.21)
    static let patcoGold = Color(red: 1.0, green: 0.73, blue: 0.22)
    static let patcoCream = Color(red: 0.98, green: 0.95, blue: 0.90)
    static let patcoAlertBackground = Color(red: 0.22, green: 0.12, blue: 0.08)
    static let patcoPlum = Color(red: 0.48, green: 0.16, blue: 0.38)
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
