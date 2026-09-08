import ActivityKit
import CoreLocation
import MapKit
import SafariServices
import SwiftUI
import WidgetKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var scheduleStore = PATCOScheduleStore()
    @StateObject private var locationProvider = LocationProvider()
    @StateObject private var alertProvider = PATCOAlertProvider()
    @StateObject private var specialScheduleProvider = PATCOSpecialScheduleProvider()

    @State private var originId: Station.ID?
    @State private var destinationId: Station.ID?
    @State private var departures: [Departure] = []
    @State private var nearestRouteStationName: String?
    @State private var currentStationName: String?
    @State private var selectedDeparture: Departure?
    @State private var inAppBrowserURL: BrowserURL?
    @State private var isRouteExpanded = false
    @State private var isRefreshing = false
    @State private var isShowingAbout = false
    @State private var lastRefreshedAt = Date()
    @State private var driveTimeEstimate: TravelTimeEstimate?
    @State private var walkingTimeEstimate: TravelTimeEstimate?
    @State private var reachabilityLocation: CLLocation?
    @State private var lastReachabilityLocationUpdate: Date?
    @State private var pendingDepartureDeepLink: DepartureDeepLink?

    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private let alertRefreshTimer = Timer.publish(every: 120, on: .main, in: .common).autoconnect()
    private let specialScheduleRefreshTimer = Timer.publish(every: 900, on: .main, in: .common).autoconnect()
    private let reachabilityLocationMinInterval: TimeInterval = 30
    private let reachabilityLocationMinDistance: CLLocationDistance = 250
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
        departures.contains { listCatchStatus(for: $0) != nil }
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
            return .walking
        }

        let minutesUntilDeparture = Int(floor(firstDeparture.departureDate.timeIntervalSinceNow / 60))
        return StationTravelMode.inferred(
            forMeters: distanceToStation,
            minutesUntilDeparture: minutesUntilDeparture
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color.patcoWine, Color.patcoCharcoal, Color.patcoRail], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                VStack(spacing: 12) {
                    header
                    statusBanners
                    departureList
                    if !visibleAlerts.isEmpty {
                        alertBox
                    }
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

                        Text(todayHeaderText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
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
                    .accessibilityLabel("About Next PATCO Train")
                }
            }
            .sheet(item: $selectedDeparture) { departure in
                TripDetailView(departure: departure, stops: tripStops(for: departure), catchStatus: catchStatus(for: departure)) {
                    selectedDeparture = nil
                }
                .presentationDetents([.large])
            }
            .sheet(isPresented: $isShowingAbout) {
                AboutView { url in
                    isShowingAbout = false
                    inAppBrowserURL = BrowserURL(url: url)
                }
                    .presentationDetents([.medium])
            }
            .sheet(item: $inAppBrowserURL) { browserURL in
                SafariView(url: browserURL.url)
                    .ignoresSafeArea()
                    .interactiveDismissDisabled()
            }
            .onAppear {
                applyDefaultsIfNeeded()
                locationProvider.startUpdatingLocation()
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
                    locationProvider.startUpdatingLocation()
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
            Text(routeSummary)
                .font(.system(size: 28, weight: .bold, design: .default))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    if let routeDetailSummary {
                        Text(routeDetailSummary)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.74))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }

                    if let currentStationName {
                        Label("You're at \(currentStationName) station", systemImage: "mappin.and.ellipse")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
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
                    locationControl

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

                    Text(schedule.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
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

    private var departureList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scheduled Departures")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.patcoCharcoal)
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)

                    Text("Current as of \(currentAsOfDate.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(Color.patcoCharcoal.opacity(0.62))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Spacer(minLength: 8)

                Button {
                    if let origin = selectedStation(originId) {
                        openDirections(to: origin, mode: currentReachabilityMode ?? .walking)
                    }
                } label: {
                    Image(systemName: "map.fill")
                        .font(.caption.weight(.bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.bordered)
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
                .tint(Color.patcoCharcoal.opacity(0.45))
                .disabled(isRefreshInProgress)
                .accessibilityLabel("Refresh departures")
            }

            if showsWalkingEstimateHint {
                Label("Reachability uses your current location and accounts for the time needed to walk from the parking lot to the station.", systemImage: "location")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.58))
            }

            if let error = scheduleStore.loadError {
                ContentUnavailableView("Schedule unavailable", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
            } else if departures.isEmpty {
                ContentUnavailableView("No departures found", systemImage: "tram", description: Text("Try the opposite direction or a different station pair."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(departures) { departure in
                            DepartureRow(
                                departure: departure,
                                catchStatus: listCatchStatus(for: departure),
                                onSelect: {
                                    selectedDeparture = departure
                                },
                                onTrack: {
                                    await PATCOLiveActivityStarter.start(
                                        departure: departure,
                                        stops: tripStops(for: departure)
                                    )
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

    private var alertBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("PATCO alerts", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(Color.patcoGold)

                Spacer()

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

        return "\(departure.fullDirectionLabel) • \(departure.travelMinutes) min ride"
    }

    private func catchStatus(for departure: Departure) -> TrainCatchStatus? {
        reachabilityStatus(for: departure, enforceOneHourLimit: true)
    }

    private func listCatchStatus(for departure: Departure) -> TrainCatchStatus? {
        guard let status = reachabilityStatus(for: departure, enforceOneHourLimit: false) else {
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
        refreshDepartures()
    }

    private func openDirections(to station: Station, mode: StationTravelMode) {
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: station.coordinate))
        destination.name = "\(station.name) PATCO Station"
        destination.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: mode.mapsDirectionsMode
        ])
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
            currentStationName = nil
            return
        }

        if let nearestStation = scheduleStore.nearestStation(to: location),
           nearestStation.location.distance(from: location) <= StationTravelMode.atStationMeters {
            currentStationName = nearestStation.name
        } else {
            currentStationName = nil
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
            saveSelectedRoute()
        }
        refreshDepartures()
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
        guard distanceToStation > StationTravelMode.closeEnoughToWalkMeters else {
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

        driveTimeEstimate = nil
        walkingTimeEstimate = nil
        updateReachabilityLocationIfNeeded(locationProvider.currentLocation, force: true)
        locationProvider.requestLocation()
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

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

private enum PATCOLiveActivityStarter {
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
    let onSelect: () -> Void
    let onTrack: () async -> String

    @State private var trackingMessage: String?
    @State private var isStartingLiveActivity = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(departureTimeText)
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(Color.patcoPlum)

                    if let departureDayText {
                        Text(departureDayText)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.patcoCharcoal.opacity(0.68))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.patcoGold.opacity(0.30), in: Capsule())
                    }
                }

                Spacer(minLength: 8)

                Text(minutesUntilText)
                    .font(.headline)
                    .foregroundStyle(Color.patcoPlum)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Button {
                    Task {
                        isStartingLiveActivity = true
                        trackingMessage = await onTrack()
                        isStartingLiveActivity = false
                    }
                } label: {
                    if isStartingLiveActivity {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "lock.iphone")
                            .font(.caption.weight(.bold))
                            .frame(width: 28, height: 28)
                    }
                }
                .buttonStyle(.bordered)
                .tint(Color.patcoWine.opacity(0.78))
                .disabled(departure.departureDate <= Date() || isStartingLiveActivity)
                .accessibilityLabel("Show scheduled trip on Lock Screen")
            }

            Text("Arrives \(arrivalTimeText)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            if let catchStatus {
                HStack(alignment: .center, spacing: 6) {
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

            if let trackingMessage {
                Text(trackingMessage)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.62))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .accessibilityAddTraits(.isButton)
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

    init(departure: Departure, stops: [TripDetailStop], catchStatus: TrainCatchStatus?, onClose: @escaping () -> Void) {
        self.departure = departure
        self.stops = stops
        self.catchStatus = catchStatus
        self.onClose = onClose
        _cameraPosition = State(initialValue: .region(Self.region(for: stops.map(\.station.coordinate))))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sheetHeader
                tripHero
                liveActivityControls
                tripDirectionSummary
                tripSummary
                stopTimeline
                routeMap
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 30)
        }
        .background(Color(red: 0.94, green: 0.94, blue: 0.96))
    }

    private var sheetHeader: some View {
        ZStack {
            Text("Scheduled Departure Details")
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
            HStack(alignment: .top, spacing: 16) {
                heroTimeItem(title: "Departs", value: departureTimeText, adjustmentText: adjustedFromText)

                Spacer(minLength: 12)

                heroTimeItem(title: "Arrives", value: arrivalTimeText, alignment: .trailing)
            }

            Divider()

            Text(stationPairText)
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.patcoCharcoal)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
        }
        .padding(22)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
    }

    private var liveActivityControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task {
                    await startLiveActivity()
                }
            } label: {
                Label("Show on Lock Screen", systemImage: "platter.filled.top.and.arrow.up.iphone")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.patcoWine)
            .disabled(departure.departureDate <= Date())

            if let liveActivityMessage {
                Text(liveActivityMessage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.66))
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
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.patcoCharcoal)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Text("Ride time")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.58))

                Text(rideTimeText)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.patcoCharcoal)
            }
        }
        .padding(18)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
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

    private func heroTimeItem(title: String, value: String, adjustmentText: String? = nil, alignment: Alignment = .leading) -> some View {
        VStack(alignment: alignment == .trailing ? .trailing : .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.patcoCharcoal.opacity(0.58))

            Text(value)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Color.patcoWine)
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
                        .stroke(Color.patcoWine, lineWidth: 5)
                }

                ForEach(stops) { stop in
                    Marker(stop.station.name, coordinate: stop.station.coordinate)
                        .tint(Color.patcoWine)
                }
            }
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var stopTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(max(stops.count - 1, 0)) scheduled stops")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.patcoCharcoal)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(scheduledStops.enumerated()), id: \.element.id) { index, stop in
                    StopTimelineRow(
                        stop: stop,
                        timeText: timeText(for: stop, isFinalStop: index == scheduledStops.count - 1),
                        isLast: index == scheduledStops.count - 1
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

    private var bikesAllowedText: String {
        departure.trip.bikesAllowed ? "Allowed" : "Not allowed"
    }

    private var wheelchairAccessibleText: String {
        departure.trip.wheelchairAccessible ? "Accessible" : "Not accessible"
    }

    @MainActor
    private func startLiveActivity() async {
        liveActivityMessage = await PATCOLiveActivityStarter.start(departure: departure, stops: stops)
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
        let latitudeDelta = max(0.025, (maxLatitude - minLatitude) * 1.45)
        let longitudeDelta = max(0.025, (maxLongitude - minLongitude) * 1.45)

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

    let onOpenURL: (URL) -> Void

    private let disclaimer = """
    Next PATCO Train is an unofficial transit schedule application and is not affiliated with or endorsed by PATCO or the Delaware River Port Authority. Schedule information may change without notice and does not reflect real-time train operations. Confirm service changes through PATCO’s official website before traveling.
    """

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.patcoCream, Color.white.opacity(0.88)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                    .ignoresSafeArea()

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

                                Text("Unofficial transit schedule app")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.patcoCharcoal.opacity(0.62))
                            }
                        }
                        .padding(.bottom, 2)

                        VStack(alignment: .leading, spacing: 10) {
                            Label("Important", systemImage: "info.circle.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.patcoWine)

                            Text(disclaimer)
                                .font(.callout)
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.78))
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.patcoGold.opacity(0.30), lineWidth: 1)
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            Label("Scheduled information", systemImage: "clock.badge.exclamationmark")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.patcoCharcoal)

                            Text("Departures, widgets, and Lock Screen views show scheduled times only. They do not reflect real-time train movement. Driving estimates include 3 additional minutes to allow for walking from the parking lot to the station platform.")
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
                                url: URL(string: "https://x.com/ridepatco")!
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.top, 56)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.visible)
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.patcoCharcoal)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(0.88), in: Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Color.patcoGold.opacity(0.28), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func aboutLinkRow(title: String, subtitle: String, systemImage: String, url: URL) -> some View {
        Button {
            onOpenURL(url)
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

                Image(systemName: "chevron.right")
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

private struct StopTimelineRow: View {
    let stop: TripDetailStop
    let timeText: String
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Circle()
                    .stroke(Color.patcoWine, lineWidth: 3)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white))

                if !isLast {
                    Rectangle()
                        .fill(Color.patcoWine)
                        .frame(width: 3, height: 38)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(stop.station.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.patcoCharcoal)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Spacer(minLength: 8)

                Text(timeText)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.62))
            }
            .padding(.bottom, isLast ? 0 : 22)
            .overlay(alignment: .bottom) {
                if !isLast {
                    Divider()
                        .padding(.leading, 4)
                }
            }
        }
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
            .lineLimit(nil)
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
