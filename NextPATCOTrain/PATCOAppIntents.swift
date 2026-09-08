import AppIntents
import CoreLocation
import Foundation

struct GetNextPATCOTrainsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Next PATCO Trains"
    static let description = IntentDescription("Shows the next scheduled PATCO departures for your saved route.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = PATCOSiriScheduleService()
        let response = await service.nextTrainsSummary()
        return .result(dialog: IntentDialog(stringLiteral: response))
    }
}

struct GetNextReachablePATCOTrainIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Next Reachable PATCO Train"
    static let description = IntentDescription("Finds the next scheduled PATCO train you are likely able to reach from your current location.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = PATCOSiriScheduleService()
        let response = await service.nextReachableTrainSummary()
        return .result(dialog: IntentDialog(stringLiteral: response))
    }
}

struct GetPATCOTrainDetailsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get PATCO Train Details"
    static let description = IntentDescription("Shows scheduled departure, arrival, direction, ride time, fare, and special schedule details for the next PATCO train.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = PATCOSiriScheduleService()
        let response = await service.nextTrainDetailsSummary()
        return .result(dialog: IntentDialog(stringLiteral: response))
    }
}

struct CheckPATCOAlertsIntent: AppIntent {
    static let title: LocalizedStringResource = "Check PATCO Alerts"
    static let description = IntentDescription("Checks current PATCO alert and service advisory messages.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = PATCOSiriScheduleService()
        let response = await service.alertsSummary()
        return .result(dialog: IntentDialog(stringLiteral: response))
    }
}

struct PATCOAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetNextPATCOTrainsIntent(),
            phrases: [
                "In \(.applicationName) when are the next trains",
                "Ask \(.applicationName) when the next trains are",
                "Show next PATCO trains with \(.applicationName)"
            ],
            shortTitle: "Next Trains",
            systemImageName: "tram.fill"
        )

        AppShortcut(
            intent: GetNextReachablePATCOTrainIntent(),
            phrases: [
                "In \(.applicationName) what train can I make",
                "Ask \(.applicationName) what PATCO train I can make",
                "Ask \(.applicationName) for the next reachable train"
            ],
            shortTitle: "Reachable Train",
            systemImageName: "figure.walk.motion"
        )

        AppShortcut(
            intent: GetPATCOTrainDetailsIntent(),
            phrases: [
                "In \(.applicationName) show my train details",
                "Ask \(.applicationName) for my PATCO train details",
                "Show next train details with \(.applicationName)"
            ],
            shortTitle: "Train Details",
            systemImageName: "list.bullet.rectangle"
        )

        AppShortcut(
            intent: CheckPATCOAlertsIntent(),
            phrases: [
                "In \(.applicationName) are there PATCO alerts",
                "Ask \(.applicationName) if there are PATCO alerts",
                "Check PATCO alerts with \(.applicationName)"
            ],
            shortTitle: "PATCO Alerts",
            systemImageName: "exclamationmark.triangle.fill"
        )
    }
}

private struct PATCOSiriScheduleService {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }()

    func nextTrainsSummary() async -> String {
        let context = await scheduleContext()
        guard let route = context.route else {
            return "I could not find your PATCO route."
        }

        let departures = context.store.departures(from: route.origin, to: route.destination, after: Date(), limit: 3)
        guard !departures.isEmpty else {
            return "No upcoming scheduled PATCO departures were found for \(routeTitle(route))."
        }

        let scheduleNotice = context.specialScheduleTitle.map { " Special schedule applied: \($0)." } ?? ""
        let trainList = departures.map {
            "\($0.departureDate.formatted(date: .omitted, time: .shortened)), arriving \($0.arrivalDate.formatted(date: .omitted, time: .shortened))"
        }.joined(separator: "; ")

        return "Next scheduled PATCO trains for \(routeTitle(route)): \(trainList).\(scheduleNotice)"
    }

    func nextReachableTrainSummary() async -> String {
        let context = await scheduleContext()
        guard let route = context.route else {
            return "I could not find your PATCO route."
        }

        guard let location = context.currentLocation else {
            return "I could not determine your current location. The next scheduled PATCO train for \(routeTitle(route)) is \(nextTrainFallback(context: context, route: route))."
        }

        let departures = context.store.departures(from: route.origin, to: route.destination, after: Date(), limit: 12)
        guard !departures.isEmpty else {
            return "No upcoming scheduled PATCO departures were found for \(routeTitle(route))."
        }

        if let reachable = departures.first(where: { catchStatus(for: $0, currentLocation: location).isReachable }) {
            let status = catchStatus(for: reachable, currentLocation: location)
            return "The next likely reachable scheduled PATCO train from \(route.origin.name) is \(reachable.departureDate.formatted(date: .omitted, time: .shortened)), arriving \(reachable.arrivalDate.formatted(date: .omitted, time: .shortened)). \(status.summary)."
        }

        let first = departures[0]
        let status = catchStatus(for: first, currentLocation: location)
        return "The next scheduled PATCO train from \(route.origin.name) is \(first.departureDate.formatted(date: .omitted, time: .shortened)), but you may miss it. \(status.summary)."
    }

    func nextTrainDetailsSummary() async -> String {
        let context = await scheduleContext()
        guard let route = context.route else {
            return "I could not find your PATCO route."
        }

        guard let departure = context.store.departures(from: route.origin, to: route.destination, after: Date(), limit: 1).first else {
            return "No upcoming scheduled PATCO departures were found for \(routeTitle(route))."
        }

        var details = [
            "Scheduled departure details for \(routeTitle(route)).",
            "Departs \(departure.departureDate.formatted(date: .omitted, time: .shortened)).",
            "Arrives \(departure.arrivalDate.formatted(date: .omitted, time: .shortened)).",
            "\(departure.fullDirectionLabel).",
            "\(durationText(departure.travelMinutes)) ride.",
            "Fare is three dollars one way, six dollars round trip."
        ]

        if let originalDepartureDate = departure.scheduleAdjustment?.originalDepartureDate {
            details.append("Special schedule adjustment: adjusted from \(originalDepartureDate.formatted(date: .omitted, time: .shortened)).")
        } else if context.specialScheduleTitle != nil {
            details.append("Special schedule applied.")
        }

        if departure.trip.bikesAllowed {
            details.append("Bikes are allowed.")
        }

        if departure.trip.wheelchairAccessible {
            details.append("Accessible train.")
        }

        return details.joined(separator: " ")
    }

    func alertsSummary() async -> String {
        guard let url = URL(string: "https://www.ridepatco.org/schedules/schedules.asp") else {
            return "I could not check PATCO alerts."
        }

        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 12
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
                return "I could not refresh PATCO alerts."
            }

            let html = String(decoding: data, as: UTF8.self)
            let alerts = await PATCOAlertProvider.parseAlerts(from: html, baseURL: url).compactMap(\.displayTitle)
            guard !alerts.isEmpty else {
                return "No active PATCO alerts were found."
            }

            return "PATCO alerts: \(alerts.prefix(3).joined(separator: " "))"
        } catch {
            return "I could not refresh PATCO alerts."
        }
    }

    private func scheduleContext() async -> ScheduleContext {
        let store = PATCOScheduleStore()
        let now = Date()
        let specialSchedules = await specialSchedulesForDepartureWindow(from: now)
        if !specialSchedules.isEmpty {
            store.applySpecialSchedules(specialSchedules)
        }

        let location = await SiriLocationProvider.currentLocation()
        let route = selectedRoute(in: store, currentLocation: location)
        let specialScheduleTitle = specialSchedules.first {
            calendar.isDate($0.serviceDate, inSameDayAs: now)
        }?.title

        return ScheduleContext(
            store: store,
            route: route,
            currentLocation: location,
            specialScheduleTitle: specialScheduleTitle
        )
    }

    private func specialSchedulesForDepartureWindow(from date: Date) async -> [PATCOSpecialSchedule] {
        var schedules: [PATCOSpecialSchedule] = []
        if let todaySpecialSchedule = try? await PATCOSpecialScheduleLoader.specialSchedule(for: date, calendar: calendar) {
            schedules.append(todaySpecialSchedule)
        }

        var requestedDates = [date]
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) {
            requestedDates.append(tomorrow)
            if let tomorrowSpecialSchedule = try? await PATCOSpecialScheduleLoader.specialSchedule(for: tomorrow, calendar: calendar),
               !schedules.contains(where: { calendar.isDate($0.serviceDate, inSameDayAs: tomorrowSpecialSchedule.serviceDate) }) {
                schedules.append(tomorrowSpecialSchedule)
            }
        }

        for cachedSchedule in SharedSpecialScheduleCache.schedules(matching: requestedDates, calendar: calendar) {
            guard !schedules.contains(where: { calendar.isDate($0.serviceDate, inSameDayAs: cachedSchedule.serviceDate) }) else {
                continue
            }

            schedules.append(cachedSchedule)
        }

        return schedules
    }

    private func selectedRoute(in store: PATCOScheduleStore, currentLocation: CLLocation?) -> (origin: Station, destination: Station)? {
        let routePair: (first: Station?, second: Station?)
        if let savedRoute = SharedRouteDefaults.savedRoute() {
            let origin = store.station(for: savedRoute.originId)
            let destination = store.station(for: savedRoute.destinationId)
            routePair = origin != nil && destination != nil && origin != destination
                ? (origin, destination)
                : (station(named: "Lindenwold", in: store), store.locust)
        } else {
            routePair = (station(named: "Lindenwold", in: store), store.locust)
        }

        guard let firstStation = routePair.first, let secondStation = routePair.second else {
            return nil
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

    private func station(named name: String, in store: PATCOScheduleStore) -> Station? {
        store.stations.first { $0.name == name }
    }

    private func routeTitle(_ route: (origin: Station, destination: Station)) -> String {
        "\(route.origin.name) to \(route.destination.name)"
    }

    private func nextTrainFallback(context: ScheduleContext, route: (origin: Station, destination: Station)) -> String {
        guard let departure = context.store.departures(from: route.origin, to: route.destination, after: Date(), limit: 1).first else {
            return "not available"
        }

        return "\(departure.departureDate.formatted(date: .omitted, time: .shortened)), arriving \(departure.arrivalDate.formatted(date: .omitted, time: .shortened))"
    }

    private func catchStatus(for departure: Departure, currentLocation: CLLocation) -> SiriCatchStatus {
        let distanceToStation = departure.origin.location.distance(from: currentLocation)
        if distanceToStation <= SiriTravelMode.atStationMeters {
            return .atStation
        }

        let minutesUntilDeparture = Int(floor(departure.departureDate.timeIntervalSinceNow / 60))
        let mode = SiriTravelMode.inferred(forMeters: distanceToStation, minutesUntilDeparture: minutesUntilDeparture)
        let travelMinutes = mode.travelMinutes(forMeters: distanceToStation)
        let spareMinutes = minutesUntilDeparture - travelMinutes - mode.stationBufferMinutes

        if spareMinutes >= 10 {
            return .reachable(travelMinutes: travelMinutes, mode: mode)
        }

        if spareMinutes >= 0 {
            return .tight(travelMinutes: travelMinutes, mode: mode)
        }

        if spareMinutes < -5 {
            return .tooLate(travelMinutes: travelMinutes, mode: mode)
        }

        return .mayMiss(travelMinutes: travelMinutes, mode: mode)
    }

    private func durationText(_ minutes: Int) -> String {
        guard minutes >= 60 else {
            return "\(minutes) minute"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }

        let hourText = hours == 1 ? "1 hour" : "\(hours) hours"
        let minuteText = remainingMinutes == 1 ? "1 minute" : "\(remainingMinutes) minutes"
        return "\(hourText) \(minuteText)"
    }
}

private struct ScheduleContext {
    let store: PATCOScheduleStore
    let route: (origin: Station, destination: Station)?
    let currentLocation: CLLocation?
    let specialScheduleTitle: String?
}

@MainActor
private final class SiriLocationProvider: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    static func currentLocation() async -> CLLocation? {
        let provider = SiriLocationProvider()
        return await provider.requestLocation()
    }

    private func requestLocation() async -> CLLocation? {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.finish(with: nil)
                }
                manager.requestLocation()
            }
        case .notDetermined:
            return nil
        case .denied, .restricted:
            return nil
        @unknown default:
            return nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(with: locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: nil)
    }

    private func finish(with location: CLLocation?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume(returning: location)
        continuation = nil
    }
}

private enum SiriTravelMode {
    case walking
    case driving

    static let atStationMeters = 150.0
    static let closeEnoughToWalkMeters = 0.75 * 1_609.34
    static let farEnoughToDriveMeters = 1.25 * 1_609.34

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

    static func inferred(forMeters meters: CLLocationDistance, minutesUntilDeparture: Int) -> SiriTravelMode {
        if meters <= closeEnoughToWalkMeters {
            return .walking
        }

        if meters >= farEnoughToDriveMeters {
            return .driving
        }

        let walkingMinutes = SiriTravelMode.walking.travelMinutes(forMeters: meters)
        return minutesUntilDeparture - walkingMinutes >= 0 ? .walking : .driving
    }

    var stationBufferMinutes: Int {
        switch self {
        case .walking:
            0
        case .driving:
            3
        }
    }
}

private enum SiriCatchStatus {
    case atStation
    case reachable(travelMinutes: Int, mode: SiriTravelMode)
    case tight(travelMinutes: Int, mode: SiriTravelMode)
    case mayMiss(travelMinutes: Int, mode: SiriTravelMode)
    case tooLate(travelMinutes: Int, mode: SiriTravelMode)

    var isReachable: Bool {
        switch self {
        case .atStation, .reachable, .tight:
            true
        case .mayMiss, .tooLate:
            false
        }
    }

    var summary: String {
        switch self {
        case .atStation:
            return "You appear to be at the station."
        case .reachable(let travelMinutes, let mode):
            return "Reachable by \(mode.phrase), with an estimated \(travelTimeText(travelMinutes)) \(mode.detailNoun)."
        case .tight(let travelMinutes, let mode):
            return "Tight by \(mode.phrase), with an estimated \(travelTimeText(travelMinutes)) \(mode.detailNoun)."
        case .mayMiss(let travelMinutes, let mode):
            return "May miss by \(mode.phrase), with an estimated \(travelTimeText(travelMinutes)) \(mode.detailNoun)."
        case .tooLate(let travelMinutes, let mode):
            return "Too late by \(mode.phrase), with an estimated \(travelTimeText(travelMinutes)) \(mode.detailNoun)."
        }
    }

    private func travelTimeText(_ minutes: Int) -> String {
        guard minutes >= 60 else {
            return "\(minutes) minute"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }

        return "\(hours) hour \(remainingMinutes) minutes"
    }
}
