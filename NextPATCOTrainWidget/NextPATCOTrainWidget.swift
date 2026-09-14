import ActivityKit
import CoreLocation
import MapKit
import SwiftUI
import WidgetKit
import AppIntents

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Next PATCO Train"
    static let description = IntentDescription("Shows upcoming scheduled PATCO trains.")
}

struct PATCOTrainEntry: TimelineEntry {
    let date: Date
    let departures: [Departure]
    let catchStatuses: [UUID: WidgetCatchStatus]
    let routeTitle: String
    let specialScheduleTitle: String?
    let timeZone: TimeZone
    let originId: Station.ID?
    let reachabilityMode: SharedReachabilityModeStore.Mode?
    let scheduleExpired: Bool
}

struct NextPATCOTrainWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PATCOTrainEntry {
        PATCOTrainEntry(
            date: Date(),
            departures: [],
            catchStatuses: [:],
            routeTitle: "Ashland to Locust",
            specialScheduleTitle: "Special schedule",
            timeZone: TimeZone(identifier: "America/New_York") ?? .current,
            originId: nil,
            reachabilityMode: nil,
            scheduleExpired: false
        )
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> PATCOTrainEntry {
        let location = await WidgetLocationProvider.currentLocation()
        return makeEntry(at: Date(), specialSchedules: [], currentLocation: location)
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<PATCOTrainEntry> {
        let now = Date()
        let location = await WidgetLocationProvider.currentLocation()
        let specialSchedules = await specialSchedulesForDepartureWindow(from: now)
        await refreshTravelTimeEstimate(
            at: now,
            specialSchedules: specialSchedules,
            currentLocation: location
        )
        // Timeline entries advance scheduled departures without waking the extension.
        // Advance scheduled departures each minute from one location snapshot,
        // then request a fresh location and ETA after a battery-conscious interval.
        let minuteOffsets = Array(0...15)
        let entries = minuteOffsets.compactMap { minuteOffset -> PATCOTrainEntry? in
            guard let entryDate = patcoCalendar.date(byAdding: .minute, value: minuteOffset, to: now) else {
                return nil
            }

            return makeEntry(at: entryDate, specialSchedules: specialSchedules, currentLocation: location)
        }
        let nextRefresh = entries.last?.date ?? now.addingTimeInterval(15 * 60)
        return Timeline(entries: entries, policy: .after(nextRefresh))
    }

    private func refreshTravelTimeEstimate(
        at date: Date,
        specialSchedules: [PATCOSpecialSchedule],
        currentLocation: CLLocation?
    ) async {
        guard let currentLocation else { return }

        let store = PATCOScheduleStore()
        if !specialSchedules.isEmpty {
            store.applySpecialSchedules(specialSchedules)
        }

        let route = selectedRoute(in: store, currentLocation: currentLocation)
        guard let origin = route.origin,
              let destination = route.destination,
              let firstDeparture = store.departures(
                from: origin,
                to: destination,
                after: date,
                limit: 1
              ).first,
              let mode = WidgetCatchStatus.reachabilityMode(
                for: firstDeparture,
                currentLocation: currentLocation,
                now: date
              ) else {
            return
        }

        await WidgetTravelTimeEstimator.refresh(
            mode: mode,
            origin: origin,
            currentLocation: currentLocation
        )
    }

    private var patcoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }

    private func makeEntry(at date: Date, specialSchedules: [PATCOSpecialSchedule], currentLocation: CLLocation?) -> PATCOTrainEntry {
        let store = PATCOScheduleStore()
        if !specialSchedules.isEmpty {
            store.applySpecialSchedules(specialSchedules)
        }

        let calendar = patcoCalendar
        let route = selectedRoute(in: store, currentLocation: currentLocation)
        let departures = route.origin.flatMap { origin in
            route.destination.map { destination in
                store.departures(from: origin, to: destination, after: date, limit: 20)
            }
        } ?? []
        let reachabilityMode = WidgetCatchStatus.reachabilityMode(
            for: departures.first,
            currentLocation: currentLocation,
            now: date
        )
        let catchStatuses = Dictionary(uniqueKeysWithValues: departures.compactMap { departure -> (UUID, WidgetCatchStatus)? in
            guard let status = WidgetCatchStatus(
                departure: departure,
                currentLocation: currentLocation,
                now: date,
                reachabilityMode: reachabilityMode
            ) else {
                return nil
            }

            return (departure.id, status)
        })

        return PATCOTrainEntry(
            date: date,
            departures: departures,
            catchStatuses: catchStatuses,
            routeTitle: routeTitle(origin: route.origin, destination: route.destination),
            specialScheduleTitle: specialSchedules.first(where: { calendar.isDate($0.serviceDate, inSameDayAs: date) })?.title,
            timeZone: calendar.timeZone,
            originId: route.origin?.id,
            reachabilityMode: reachabilityMode?.sharedMode,
            scheduleExpired: store.feed?.isExpired(on: date) ?? true
        )
    }

    private func specialSchedulesForDepartureWindow(from date: Date) async -> [PATCOSpecialSchedule] {
        var schedules: [PATCOSpecialSchedule] = []
        if let todaySpecialSchedule = try? await PATCOSpecialScheduleLoader.specialSchedule(for: date, calendar: patcoCalendar) {
            schedules.append(todaySpecialSchedule)
        }

        var requestedDates = [date]
        if let tomorrow = patcoCalendar.date(byAdding: .day, value: 1, to: date) {
            requestedDates.append(tomorrow)
            if let tomorrowSpecialSchedule = try? await PATCOSpecialScheduleLoader.specialSchedule(for: tomorrow, calendar: patcoCalendar),
               !schedules.contains(where: { patcoCalendar.isDate($0.serviceDate, inSameDayAs: tomorrowSpecialSchedule.serviceDate) }) {
                schedules.append(tomorrowSpecialSchedule)
            }
        }

        for cachedSchedule in SharedSpecialScheduleCache.schedules(matching: requestedDates, calendar: patcoCalendar) {
            guard !schedules.contains(where: { patcoCalendar.isDate($0.serviceDate, inSameDayAs: cachedSchedule.serviceDate) }) else {
                continue
            }

            schedules.append(cachedSchedule)
        }

        return schedules
    }

    private func selectedRoute(in store: PATCOScheduleStore, currentLocation: CLLocation?) -> (origin: Station?, destination: Station?) {
        let routePair: (first: Station?, second: Station?)
        if let currentLocation,
           let temporaryRoute = SharedRouteDefaults.temporaryRoute(),
           let temporaryOrigin = store.station(for: temporaryRoute.originId),
           let temporaryDestination = store.station(for: temporaryRoute.destinationId),
           temporaryOrigin != temporaryDestination,
           temporaryOrigin.location.distance(from: currentLocation) <= 150 {
            routePair = (temporaryOrigin, temporaryDestination)
        } else if let savedRoute = SharedRouteDefaults.savedRoute() {
            let origin = store.station(for: savedRoute.originId)
            let destination = store.station(for: savedRoute.destinationId)
            if origin != nil, destination != nil, origin != destination {
                routePair = (origin, destination)
            } else {
                routePair = (station(named: "Lindenwold", in: store), store.locust)
            }
        } else {
            routePair = (station(named: "Lindenwold", in: store), store.locust)
        }

        guard let firstStation = routePair.first,
              let secondStation = routePair.second else {
            return (routePair.first, routePair.second)
        }

        guard let currentLocation else {
            return (firstStation, secondStation)
        }

        let firstDistance = firstStation.location.distance(from: currentLocation)
        let secondDistance = secondStation.location.distance(from: currentLocation)
        return firstDistance <= secondDistance
            ? (firstStation, secondStation)
            : (secondStation, firstStation)
    }

    private func routeTitle(origin: Station?, destination: Station?) -> String {
        guard let origin, let destination else {
            return "PATCO"
        }

        return "\(shortName(for: origin)) to \(shortName(for: destination))"
    }

    private func shortName(for station: Station) -> String {
        station.name == "15/16th and Locust" ? "15/16th" : station.name
    }

    private func station(named name: String, in store: PATCOScheduleStore) -> Station? {
        store.stations.first { $0.name == name }
    }
}

private enum WidgetTravelTimeEstimator {
    static func refresh(
        mode: WidgetCatchStatus.TravelMode,
        origin: Station,
        currentLocation: CLLocation
    ) async {
        let distanceToStation = currentLocation.distance(from: origin.location)
        let cacheMode: SharedTravelTimeEstimateCache.Mode
        let transportType: MKDirectionsTransportType

        switch mode {
        case .walking:
            guard distanceToStation > 150,
                  distanceToStation <= 1.25 * 1_609.34 else {
                SharedTravelTimeEstimateCache.clear(mode: .walking)
                return
            }
            cacheMode = .walking
            transportType = .walking
        case .driving:
            guard distanceToStation > 150 else {
                SharedTravelTimeEstimateCache.clear(mode: .driving)
                return
            }
            cacheMode = .driving
            transportType = .automobile
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocation.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.transportType = transportType
        request.requestsAlternateRoutes = false

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else { return }

            SharedTravelTimeEstimateCache.save(
                mode: cacheMode,
                origin: origin,
                currentLocation: currentLocation,
                minutes: max(1, Int(ceil(route.expectedTravelTime / 60)))
            )
        } catch {
            SharedTravelTimeEstimateCache.clear(mode: cacheMode)
        }
    }
}

@MainActor
private final class WidgetLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    static func currentLocation() async -> CLLocation? {
        let cachedLocation = SharedCurrentLocationCache.location(maxAge: 15 * 60)
        let provider = WidgetLocationProvider()
        if let currentLocation = await provider.requestLocation() {
            SharedCurrentLocationCache.save(currentLocation)
            return currentLocation
        }

        return cachedLocation
    }

    private func requestLocation() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run {
                    self?.finish(with: nil)
                }
            }

            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .denied, .restricted:
                finish(with: nil)
            @unknown default:
                finish(with: nil)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            switch self.manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                self.manager.requestLocation()
            case .denied, .restricted:
                finish(with: nil)
            case .notDetermined:
                break
            @unknown default:
                finish(with: nil)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            let freshLocation = locations
                .filter { location in
                    location.horizontalAccuracy >= 0
                        && location.horizontalAccuracy <= 1_000
                        && abs(location.timestamp.timeIntervalSinceNow) <= 2 * 60
                }
                .max { $0.timestamp < $1.timestamp }
            finish(with: freshLocation)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            finish(with: nil)
        }
    }

    private func finish(with location: CLLocation?) {
        guard let continuation else { return }

        timeoutTask?.cancel()
        timeoutTask = nil
        self.continuation = nil
        continuation.resume(returning: location)
    }
}

private enum SharedRouteDefaults {
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

}

enum WidgetCatchStatus: Equatable {
    case reachable
    case tight
    case likelyMiss

    private static let atStationMeters = 150.0
    private static let reachabilityMaxDistanceMeters = 150 * 1_609.34

    init?(
        departure: Departure,
        currentLocation: CLLocation?,
        now: Date,
        reachabilityMode: TravelMode?
    ) {
        guard let currentLocation else { return nil }

        let minutesUntilDeparture = Int(floor(departure.departureDate.timeIntervalSince(now) / 60))
        let distanceToStation = currentLocation.distance(from: departure.origin.location)
        guard distanceToStation <= Self.reachabilityMaxDistanceMeters else {
            return nil
        }

        if distanceToStation <= Self.atStationMeters {
            SharedReachabilityModeStore.clearOnArrival(originId: departure.origin.id)
            self = .reachable
            return
        }

        guard let travelMode = reachabilityMode ?? SharedReachabilityModeStore.resolve(
            originId: departure.origin.id,
            distanceToStation: distanceToStation,
            minutesUntilDeparture: minutesUntilDeparture
        ).map(TravelMode.init) else {
            return nil
        }
        let travelMinutes = Self.travelMinutes(
            for: travelMode,
            meters: distanceToStation,
            origin: departure.origin,
            currentLocation: currentLocation
        )
        let stationAccessMinutes = travelMode == .driving ? 3 : 0
        let spareMinutes = minutesUntilDeparture - travelMinutes - stationAccessMinutes

        if spareMinutes >= 3 {
            self = .reachable
        } else if spareMinutes >= 0 {
            self = .tight
        } else {
            self = .likelyMiss
        }
    }

    var color: Color {
        switch self {
        case .reachable:
            Color(red: 0.43, green: 0.86, blue: 0.55)
        case .tight:
            Color.patcoGold
        case .likelyMiss:
            Color(red: 1.0, green: 0.50, blue: 0.56)
        }
    }

    var isMakeable: Bool {
        switch self {
        case .reachable, .tight:
            true
        case .likelyMiss:
            false
        }
    }

    enum TravelMode {
        case walking
        case driving

        init(_ sharedMode: SharedReachabilityModeStore.Mode) {
            self = sharedMode == .driving ? .driving : .walking
        }

        var sharedMode: SharedReachabilityModeStore.Mode {
            self == .driving ? .driving : .walking
        }
    }

    static func reachabilityMode(
        for departure: Departure?,
        currentLocation: CLLocation?,
        now: Date
    ) -> TravelMode? {
        guard let departure, let currentLocation else { return nil }

        let distanceToStation = currentLocation.distance(from: departure.origin.location)
        guard distanceToStation <= reachabilityMaxDistanceMeters else {
            return nil
        }

        guard distanceToStation > atStationMeters else {
            SharedReachabilityModeStore.clearOnArrival(originId: departure.origin.id)
            return nil
        }

        let minutesUntilDeparture = Int(floor(departure.departureDate.timeIntervalSince(now) / 60))
        guard let sharedMode = SharedReachabilityModeStore.resolve(
            originId: departure.origin.id,
            distanceToStation: distanceToStation,
            minutesUntilDeparture: minutesUntilDeparture
        ) else {
            return nil
        }

        return TravelMode(sharedMode)
    }

    private static func travelMinutes(
        for mode: TravelMode,
        meters: CLLocationDistance,
        origin: Station,
        currentLocation: CLLocation
    ) -> Int {
        let cacheMode: SharedTravelTimeEstimateCache.Mode = mode == .walking ? .walking : .driving
        if let estimate = SharedTravelTimeEstimateCache.estimate(
            mode: cacheMode,
            origin: origin,
            currentLocation: currentLocation
        ) {
            return estimate.minutes
        }

        return travelMinutes(for: mode, meters: meters)
    }

    private static func travelMinutes(for mode: TravelMode, meters: CLLocationDistance) -> Int {
        switch mode {
        case .walking:
            return max(1, Int(ceil((meters / 1.25) / 60)))
        case .driving:
            let metersPerMinuteAt25MPH = 670.56
            return max(1, Int(ceil(meters / metersPerMinuteAt25MPH)))
        }
    }
}

struct RefreshPATCOWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh trains"
    static let description = IntentDescription("Refreshes departures and reachability using your current location.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadTimelines(ofKind: "NextPATCOTrainWidget")
        return .result()
    }
}

struct TogglePATCOReachabilityModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch reachability mode"
    static let description = IntentDescription("Switches widget reachability between car and walking.")
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
        let mode: SharedReachabilityModeStore.Mode = currentMode == SharedReachabilityModeStore.Mode.driving.rawValue
            ? .walking
            : .driving
        SharedReachabilityModeStore.save(mode: mode, originId: originId, isManual: true)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct NextPATCOTrainWidgetEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily

    let entry: PATCOTrainEntry

    var body: some View {
        VStack(alignment: .leading, spacing: widgetFamily == .systemSmall ? 6 : 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next PATCO Train")
                        .font(.caption.bold())
                        .foregroundStyle(Color.patcoGold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(entry.routeTitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)

                    if entry.specialScheduleTitle != nil {
                        Label("Special schedule", systemImage: "calendar.badge.exclamationmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.patcoGold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    if let originId = entry.originId,
                       let reachabilityMode = entry.reachabilityMode {
                        Button(intent: TogglePATCOReachabilityModeIntent(
                            originId: originId,
                            currentMode: reachabilityMode
                        )) {
                            Image(systemName: reachabilityMode == .driving ? "car.fill" : "figure.walk")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color.patcoGold)
                                .frame(width: 30, height: 30)
                                .background(.white.opacity(0.10), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            reachabilityMode == .driving
                                ? "Car reachability. Switch to walking"
                                : "Walking reachability. Switch to car"
                        )
                    }

                    Button(intent: RefreshPATCOWidgetIntent()) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.patcoGold)
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh departures and reachability")

                }
            }

            if entry.departures.isEmpty {
                Spacer()
                Text(entry.scheduleExpired ? "Schedule update needed" : "No upcoming trains")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(
                    entry.scheduleExpired
                        ? "Open Next PATCO Train to download the current schedule."
                        : "Open Next PATCO Train to pick stations."
                )
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
            } else {
                departureList
            }

            Spacer(minLength: 0)

            if widgetFamily != .systemSmall {
                Text("Updated \(entry.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color.patcoWine, Color.patcoCharcoal, Color.patcoRail],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .widgetURL(URL(string: "patconext://widget"))
    }

    @ViewBuilder
    private var departureList: some View {
        VStack(spacing: departureRowSpacing) {
            ForEach(displayedDepartures) { departure in
                departureRow(departure)
            }
        }
    }

    private var displayedDepartures: [Departure] {
        let departures = entry.departures
        guard widgetFamily == .systemSmall || widgetFamily == .systemMedium else {
            return Array(departures.prefix(displayLimit))
        }

        guard let firstMakeableIndex = departures.firstIndex(where: { departure in
            entry.catchStatuses[departure.id]?.isMakeable == true
        }) else {
            return Array(departures.prefix(displayLimit))
        }

        let startIndex = firstMakeableIndex > departures.startIndex
            ? departures.index(before: firstMakeableIndex)
            : firstMakeableIndex
        var selected = Array(departures[startIndex...].prefix(displayLimit))

        if selected.count < displayLimit {
            let selectedIds = Set(selected.map(\.id))
            selected.append(contentsOf: departures.filter { departure in
                !selectedIds.contains(departure.id)
            }.prefix(displayLimit - selected.count))
        }

        return selected
    }

    private var displayLimit: Int {
        switch widgetFamily {
        case .systemSmall:
            3
        case .systemLarge:
            10
        default:
            3
        }
    }

    private var departureRowSpacing: CGFloat {
        switch widgetFamily {
        case .systemLarge:
            5
        case .systemMedium:
            6
        default:
            5
        }
    }

    private func departureRow(_ departure: Departure) -> some View {
        let catchStatus = entry.catchStatuses[departure.id]
        return HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(departureTimeText(for: departure))
                    .font(.headline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(catchStatus?.color ?? .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

            }
            .frame(width: 76, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                if widgetFamily == .systemMedium || widgetFamily == .systemLarge {
                    Text("Arrives \(arrivalTimeText(for: departure))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                } else {
                    Text(arrivalTimeText(for: departure))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func departureTimeText(for departure: Departure) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = entry.timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: departure.departureDate)
    }

    private func arrivalTimeText(for departure: Departure) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = entry.timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = entry.timeZone

        if calendar.isDate(departure.arrivalDate, inSameDayAs: departure.departureDate) {
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: departure.arrivalDate)
        }

        formatter.dateFormat = "EEE h:mm a"
        return formatter.string(from: departure.arrivalDate)
    }

}

struct NextPATCOTrainHomeWidget: Widget {
    let kind = "NextPATCOTrainWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: NextPATCOTrainWidgetProvider()) { entry in
            NextPATCOTrainWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Next PATCO Train")
        .description("See the next PATCO trains from Ashland to 15/16th and Locust.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct PATCOTripLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PATCOTripActivityAttributes.self) { context in
            PATCOTripLiveActivityView(context: context)
                .activityBackgroundTint(Color.patcoCharcoal)
                .activitySystemActionForegroundColor(Color.patcoGold)
                .widgetURL(context.attributes.deepLinkURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.originName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                        Text(departureTimeText(context.state.departureDate))
                            .font(.headline.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.attributes.destinationName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                        Text(arrivalTimeText(context.state.arrivalDate))
                            .font(.headline.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    EmptyView()
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: "tram.fill")
                        .font(.caption.weight(.bold))
                    Text(shortTimeText(context.state.departureDate))
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .minimumScaleFactor(0.65)
                }
                .foregroundStyle(Color.patcoGold)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Text(shortTimeText(context.state.departureDate))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.65)
                .foregroundStyle(Color.patcoGold)
            }
            .widgetURL(context.attributes.deepLinkURL)
        }
    }

    private func departureTimeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func shortTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter.string(from: date)
    }

    private func arrivalTimeText(_ date: Date) -> String {
        "Arrives \(date.formatted(date: .omitted, time: .shortened))"
    }
}

struct PATCOTripLiveActivityView: View {
    let context: ActivityViewContext<PATCOTripActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next PATCO Train")
                        .font(.caption.bold())
                        .foregroundStyle(Color.patcoGold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(context.attributes.routeTitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer()

                Image(systemName: "tram.fill")
                    .font(.title3)
                    .foregroundStyle(Color.patcoGold)
            }

            TimelineView(.periodic(from: .now, by: 15)) { timeline in
                HStack(alignment: .firstTextBaseline) {
                    primaryScheduleBlock(now: timeline.date)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Scheduled Arrival")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.58))
                        Text(context.state.arrivalDate.formatted(date: .omitted, time: .shortened))
                            .font(.title3.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
            }

            EmptyView()
        }
        .padding()
    }

    @ViewBuilder
    private func primaryScheduleBlock(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Scheduled Departure")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.58))
            Text(context.state.departureDate.formatted(date: .omitted, time: .shortened))
                .font(.title3.monospacedDigit().weight(.bold))
                .foregroundStyle(.white)
        }
    }

}

@main
struct NextPATCOTrainWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextPATCOTrainHomeWidget()
        PATCOTripLiveActivityWidget()
    }
}

private extension Color {
    static let patcoWine = Color(red: 0.42, green: 0.02, blue: 0.11)
    static let patcoCharcoal = Color(red: 0.08, green: 0.10, blue: 0.12)
    static let patcoRail = Color(red: 0.15, green: 0.18, blue: 0.21)
    static let patcoGold = Color(red: 1.0, green: 0.73, blue: 0.22)
    static let patcoPlum = Color(red: 0.48, green: 0.16, blue: 0.38)
}
