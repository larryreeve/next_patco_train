import ActivityKit
import Combine
import CoreLocation
import Foundation

@MainActor
enum TripTrackingController {
    static func start(departure: Departure, stops: [TripDetailStop], locationProvider: LocationProvider) async -> String? {
        let message = await PATCOLiveActivityStarter.start(departure: departure, stops: stops, trackingOnly: true)
        guard message == "Trip tracking started." else { return message }
        locationProvider.beginJourneyTracking(stations: stops.map(\.station))
        if LocationInteractionPolicy.isAuthorized(locationProvider.authorizationStatus) { locationProvider.requestLocation() }
        return nil
    }

    static func cancel(key: String, departure: Departure, locationProvider: LocationProvider,
                       tripProgress: TripProgressStore = .shared) async -> String? {
        // Persist cancellation before awaiting ActivityKit so callbacks cannot restart the trip.
        guard let route = SharedRouteCoordinator.cancelJourney(key: key),
              route.journey?.key == key, route.journey?.state == .cancelled else {
            return "Unable to stop this trip. Please try again."
        }
        tripProgress.synchronize()
        locationProvider.endJourneyTracking()
        await PATCOLiveActivityStarter.endActivity(forJourneyKey: key)
        NotificationCenter.default.post(name: PATCOLiveActivityStarter.activityDidChangeNotification, object: nil)
        return nil
    }

    static func confirmArrival(departure: Departure, locationProvider: LocationProvider,
                               tripProgress: TripProgressStore = .shared) -> SharedRouteCoordinator.Route? {
        guard let old = SharedRouteCoordinator.current(),
              let result = SharedRouteCoordinator.confirmTripArrival(originId: departure.origin.id,
                destinationId: departure.destination.id, expectedRevision: old.revision),
              result.revision == old.revision + 1 else { return nil }
        TripProgressStore.shared.synchronize()
        locationProvider.endJourneyTracking(reloadWidgets: false)
        Task { await PATCOLiveActivityStarter.endActivities(arrivingAt: departure.destination.name) }
        return result
    }
}

@MainActor
final class TripProgressStore: ObservableObject, JourneyProgressRecording {
    static let shared = TripProgressStore()
    @Published private(set) var tripKey: String?
    @Published private(set) var session: JourneyProgressSession?
    @Published private(set) var progress = TripLocationProgress()
    private static var defaultPreferences: UserDefaults {
        #if DEBUG && targetEnvironment(simulator)
        if let testID = ProcessInfo.processInfo.environment["PATCO_TEST_ROUTE_DIRECTORY"] {
            return UserDefaults(suiteName: "patco.tests.\(testID)")!
        }
        #endif
        return .standard
    }
    private let defaults: UserDefaults
    private var lastPersistedAt: Date?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? Self.defaultPreferences
        let defaults = self.defaults
        tripKey = defaults.string(forKey: "tripProgressKey")
        if let data = defaults.data(forKey: "journeyProgressSession") {
            session = try? JSONDecoder().decode(JourneyProgressSession.self, from: data)
        }
        if let data = defaults.data(forKey: "tripProgress"),
           let saved = try? JSONDecoder().decode(TripLocationProgress.self, from: data) { progress = saved }
        if let route = SharedRouteCoordinator.current() {
            if route.journey == nil, let session, session.isActive() {
                _ = SharedRouteCoordinator.beginJourney(session, expectedRevision: route.revision)
                _ = SharedRouteCoordinator.saveJourneyProgress(progress, key: session.key)
            }
            synchronize()
        }
    }

    func synchronize() {
        guard let route = SharedRouteCoordinator.expireJourney() else { return }
        let changedTrip = session?.key != route.journey?.key
        session = route.journey
        if changedTrip {
            tripKey = session?.key
            progress = route.journeyProgress ?? TripLocationProgress()
            lastPersistedAt = nil
        }
    }

    func begin(key: String, attributes: PATCOTripActivityAttributes, state: PATCOTripActivityAttributes.ContentState,
               explicitRestart: Bool = false) {
        synchronize()
        guard session?.key != key else { return }
        let sameTrip = session?.deepLink == attributes.deepLinkURLString
        let proposed = JourneyProgressSession(key: key, deepLink: attributes.deepLinkURLString,
            originName: attributes.originName, destinationName: attributes.destinationName,
            departure: state.departureDate, arrival: state.arrivalDate,
            stops: state.stops.map { .init(name: $0.name, arrival: $0.arrivalDate) })
        guard let revision = SharedRouteCoordinator.current()?.revision,
              let route = SharedRouteCoordinator.beginJourney(proposed, expectedRevision: revision, explicitRestart: explicitRestart),
              route.journey?.key == key else { return }
        session = route.journey
        if !sameTrip && tripKey != key { progress = TripLocationProgress(); lastPersistedAt = nil }
        tripKey = key
        defaults.set(tripKey, forKey: "tripProgressKey")
        defaults.set(try? JSONEncoder().encode(progress), forKey: "tripProgress")
        defaults.removeObject(forKey: "journeyProgressSession")
    }

    func complete(arrivingAt name: String) {
        // Completion is committed with the route, never inferred from a display name here.
        synchronize()
    }

    func record(_ location: CLLocation, stations: [Station]) {
        synchronize()
        if let activity = PATCOLiveActivityStarter.currentTripActivity() {
            begin(key: activity.id, attributes: activity.attributes, state: activity.content.state)
        }
        guard let session, session.isActive(),
              let origin = stations.first(where: { $0.name == session.originName }) else { return }
        let ordered = [origin] + session.stops.compactMap { stop in
            stations.first { $0.name == stop.name }
        }
        guard ordered.count == session.stops.count + 1 else { return }
        let key = session.key
        let newTrip = tripKey != key
        if newTrip { tripKey = key; progress = TripLocationProgress(); lastPersistedAt = nil }
        var next = progress
        next.observe(location, stations: ordered, geometry: PATCOTrackGeometry.bundled,
                     departure: session.departure, arrival: session.arrival,
                     stationArrivals: Dictionary(uniqueKeysWithValues: zip(ordered.dropFirst(), session.stops).map {
                         ($0.0.id, $0.1.arrival)
                     }))
        guard newTrip || next != progress else { return }
        let changedStations = next.detectedStationIds != progress.detectedStationIds
            || next.inferredStationIds != progress.inferredStationIds
        let shouldSave = newTrip || changedStations
            || (next.positionAt?.timeIntervalSince(lastPersistedAt ?? .distantPast) ?? 0) >= 10
        progress = next
        if shouldSave {
            _ = SharedRouteCoordinator.saveJourneyProgress(next, key: key)
            defaults.set(key, forKey: "tripProgressKey")
            defaults.set(try? JSONEncoder().encode(next), forKey: "tripProgress")
            lastPersistedAt = next.positionAt
        }
    }
}

enum PATCOLiveActivityStarter {
    static let activityDidChangeNotification = Notification.Name("PATCOLiveActivityDidChange")
    @MainActor private static var expirationTasks: [String: Task<Void, Never>] = [:]

    @MainActor
    static func endActivity(forJourneyKey key: String) async {
        for activity in Activity<PATCOTripActivityAttributes>.activities where activity.id == key {
            cancelExpiration(id: key)
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    @MainActor
    private static func scheduleExpiration(id: String, deadline: Date) {
        guard expirationTasks[id] == nil else { return }
        expirationTasks[id] = Task {
            do {
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            } catch { return }
            expirationTasks[id] = nil
            await endExpiredActivities()
        }
    }

    @MainActor
    private static func cancelExpiration(id: String) {
        expirationTasks.removeValue(forKey: id)?.cancel()
    }

    @MainActor
    static func currentTripActivity(now: Date = Date()) -> Activity<PATCOTripActivityAttributes>? {
        Activity<PATCOTripActivityAttributes>.activities
            .filter {
                ($0.activityState == .active || $0.activityState == .stale)
                    && !ScheduledTripExpiration.hasExpired(arrivalDate: $0.content.state.arrivalDate, now: now)
                    && URL(string: $0.attributes.deepLinkURLString).flatMap(DepartureDeepLink.init(url:)) != nil
            }
            .max { $0.content.state.lastUpdated < $1.content.state.lastUpdated }
    }

    @MainActor
    static func hasCurrentTrip(to destinationName: String, now: Date = Date()) -> Bool {
        if let session = SharedRouteCoordinator.current()?.journey {
            return session.isActive(at: now) && session.destinationName == destinationName
                && session.departure <= now.addingTimeInterval(3600)
        }
        return Activity<PATCOTripActivityAttributes>.activities.contains {
            $0.activityState == .active && $0.attributes.destinationName == destinationName
                && $0.content.state.arrivalDate > now
                && $0.content.state.departureDate <= now.addingTimeInterval(3600)
        }
    }

    @MainActor
    static func isShowing(departure: Departure) -> Bool {
        matchingActivity(for: departure) != nil
    }

    @MainActor
    static func stop(departure: Departure) async -> String {
        guard let activity = matchingActivity(for: departure) else {
            return "Not currently showing on Lock Screen."
        }

        TripProgressStore.shared.begin(key: activity.id, attributes: activity.attributes, state: activity.content.state)
        await activity.end(nil, dismissalPolicy: .immediate)
        cancelExpiration(id: activity.id)
        NotificationCenter.default.post(name: activityDidChangeNotification, object: nil)
        return "Removed from Lock Screen."
    }

    @MainActor
    static func start(departure: Departure, stops: [TripDetailStop], trackingOnly: Bool = false) async -> String {
        guard trackingOnly || ActivityAuthorizationInfo().areActivitiesEnabled else {
            return "Live Activities are disabled in Settings."
        }

        let scheduledStops = Array(stops.dropFirst())
        let attributes = PATCOTripActivityAttributes(
            routeTitle: "\(departure.origin.name) to \(departure.destination.name)",
            originName: departure.origin.name,
            destinationName: departure.destination.name,
            deepLinkURLString: deepLinkURL(for: departure).absoluteString
        )
        let activityStops = scheduledStops.compactMap { stop -> PATCOTripActivityAttributes.Stop? in
            guard let arrivalDate = stopDate(for: stop.stopTime, serviceDate: departure.serviceDate,
                                             isSpecialSchedule: departure.isSpecialSchedule) else { return nil }
            return PATCOTripActivityAttributes.Stop(
                name: stop.station.name,
                arrivalDate: arrivalDate
            )
        }
        let state = contentState(departure: departure, stops: activityStops)
        if trackingOnly {
            let key = UUID().uuidString
            TripProgressStore.shared.begin(key: key, attributes: attributes, state: state, explicitRestart: true)
            guard TripProgressStore.shared.session?.key == key else { return "Unable to track this trip. Check the selected route and try again." }
            for activity in Activity<PATCOTripActivityAttributes>.activities {
                cancelExpiration(id: activity.id)
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            NotificationCenter.default.post(name: activityDidChangeNotification, object: nil)
            return "Trip tracking started."
        }
        let content = ActivityContent(
            state: state,
            staleDate: ScheduledDeparturePresentation.staleDate(departureDate: departure.departureDate,
                                                               arrivalDate: departure.arrivalDate)
        )

        do {
            for activity in Activity<PATCOTripActivityAttributes>.activities {
                cancelExpiration(id: activity.id)
                await activity.end(nil, dismissalPolicy: .immediate)
            }

            let activity = try Activity<PATCOTripActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            TripProgressStore.shared.begin(key: activity.id, attributes: attributes, state: state, explicitRestart: true)
            guard TripProgressStore.shared.session?.key == activity.id else {
                await activity.end(nil, dismissalPolicy: .immediate)
                return "Unable to track this trip. Check the selected route and try again."
            }
            scheduleExpiration(id: activity.id, deadline: ScheduledTripExpiration.deadline(arrivalDate: departure.arrivalDate))
            NotificationCenter.default.post(name: activityDidChangeNotification, object: nil)
            return "Showing on Lock Screen."
        } catch {
            return "Could not start Live Activity."
        }
    }

    @MainActor
    static func endExpiredActivities(now: Date = Date()) async {
        TripProgressStore.shared.synchronize()
        for activity in Activity<PATCOTripActivityAttributes>.activities {
            let dismissalDate = ScheduledTripExpiration.deadline(arrivalDate: activity.content.state.arrivalDate)
            let session = TripProgressStore.shared.session
            let terminated = session?.key == activity.id && (session?.completed == true || session?.termination != nil)
            if now >= dismissalDate || terminated {
                cancelExpiration(id: activity.id)
                await activity.end(nil, dismissalPolicy: .immediate)
                NotificationCenter.default.post(name: activityDidChangeNotification, object: nil)
            } else {
                let staleDate = ScheduledDeparturePresentation.staleDate(
                    departureDate: activity.content.state.departureDate,
                    arrivalDate: activity.content.state.arrivalDate, now: now)
                if activity.content.staleDate != staleDate {
                    await activity.update(ActivityContent(state: activity.content.state, staleDate: staleDate))
                }
                scheduleExpiration(id: activity.id, deadline: dismissalDate)
            }
        }
    }

    @MainActor
    static func endActivities(arrivingAt stationName: String) async {
        TripProgressStore.shared.complete(arrivingAt: stationName)
        for activity in Activity<PATCOTripActivityAttributes>.activities
        where activity.attributes.destinationName == stationName {
            cancelExpiration(id: activity.id)
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        NotificationCenter.default.post(name: activityDidChangeNotification, object: nil)
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

    private static func stopDate(for stopTime: StopTime, serviceDate: Date, isSpecialSchedule: Bool) -> Date? {
        PATCOScheduleStore.scheduleDate(serviceDate: serviceDate, timeString: stopTime.arrival,
                                        isSpecialSchedule: isSpecialSchedule)
    }
}


#if DEBUG && targetEnvironment(simulator)
extension TripProgressStore {
    func installArrivalPreview(departure: Departure, stops: [TripDetailStop], anchorIndex: Int, now: Date) {
        let key = "arrival-preview"
        tripKey = key
        session = JourneyProgressSession(key: key,
            deepLink: "patconext://departure?origin=\(departure.origin.id)&destination=\(departure.destination.id)&departure=\(departure.departureDate.timeIntervalSince1970)",
            originName: departure.origin.name, destinationName: departure.destination.name,
            departure: departure.departureDate, arrival: departure.arrivalDate,
            stops: stops.dropFirst().enumerated().map { index, stop in
                .init(name: stop.station.name, arrival: departure.departureDate.addingTimeInterval(Double(index + 1) * 120))
            })
        progress = TripLocationProgress()
        let stale = ProcessInfo.processInfo.arguments.contains("-staleTrackingPreview")
        let reading = CLLocation(coordinate: stops[anchorIndex].station.coordinate, altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 1, course: -1, speed: -1, timestamp: now.addingTimeInterval(stale ? -180 : -20))
        progress.observe(reading, stations: stops.map(\.station), geometry: PATCOTrackGeometry.bundled,
            departure: departure.departureDate, arrival: departure.arrivalDate, now: reading.timestamp)
        if ProcessInfo.processInfo.arguments.contains("-untrackedTrackingPreview") { session = nil; tripKey = nil }
        if ProcessInfo.processInfo.arguments.contains("-completedTrackingPreview"), var finished = session {
            JourneyCoordinator.transition(&finished, event: .arrive)
            session = finished
        }
    }
}
#endif
