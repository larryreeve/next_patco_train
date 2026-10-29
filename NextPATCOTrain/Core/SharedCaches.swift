import Combine
import CoreLocation
import Foundation
import Darwin

enum SharedTravelTimeEstimateCache {
    enum Mode: String, Codable {
        case walking
        case driving
    }

    struct Estimate: Codable {
        let originId: Station.ID
        let sourceLatitude: Double
        let sourceLongitude: Double
        let minutes: Int
        let fetchedAt: Date
        var routeDistanceMeters: Double? = nil
        var requestStartedAt: Date? = nil

        func isValid(for origin: Station, currentLocation: CLLocation,
                     mode: Mode? = nil, now: Date = Date()) -> Bool {
            let movementLimit: CLLocationDistance
            switch mode {
            case .walking: movementLimit = 50
            case .driving: movementLimit = 100
            case nil: movementLimit = 250
            }
            return originId == origin.id
                && (0..<5 * 60).contains(now.timeIntervalSince(fetchedAt))
                && sourceLocation.distance(from: currentLocation) < movementLimit
        }

        private var sourceLocation: CLLocation {
            CLLocation(latitude: sourceLatitude, longitude: sourceLongitude)
        }
    }

    private static let suiteName = "group.com.rhome.patconext"
    private static let walkingKey = "cachedWalkingTravelTimeEstimate"
    private static let drivingKey = "cachedDrivingTravelTimeEstimate"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    @discardableResult
    static func save(mode: Mode, origin: Station, currentLocation: CLLocation, minutes: Int, fetchedAt: Date = Date(), routeDistanceMeters: Double? = nil,
                     requestStartedAt: Date? = nil, defaults suppliedDefaults: UserDefaults? = nil, directory: URL? = nil) -> Bool {
        let defaults = suppliedDefaults ?? self.defaults
        let root = directory ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
        guard let root else { return false }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = open(root.appendingPathComponent("travel-estimate.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return false }
        defer { flock(descriptor, LOCK_UN) }
        if let data = defaults.data(forKey: key(for: mode)),
           let existing = try? JSONDecoder().decode(Estimate.self, from: data) {
            if let requestStartedAt {
                if (existing.requestStartedAt ?? existing.fetchedAt) > requestStartedAt { return false }
            } else if existing.fetchedAt > fetchedAt {
                return false
            }
        }
        let estimate = Estimate(
            originId: origin.id,
            sourceLatitude: currentLocation.coordinate.latitude,
            sourceLongitude: currentLocation.coordinate.longitude,
            minutes: minutes,
            fetchedAt: fetchedAt,
            routeDistanceMeters: routeDistanceMeters,
            requestStartedAt: requestStartedAt
        )

        if let data = try? JSONEncoder().encode(estimate) {
            defaults.set(data, forKey: key(for: mode))
            return true
        }
        return false
    }

    static func estimate(mode: Mode, origin: Station, currentLocation: CLLocation,
                         now: Date = Date(), defaults suppliedDefaults: UserDefaults? = nil) -> Estimate? {
        let defaults = suppliedDefaults ?? self.defaults
        guard let data = defaults.data(forKey: key(for: mode)),
              let estimate = try? JSONDecoder().decode(Estimate.self, from: data),
              estimate.isValid(for: origin, currentLocation: currentLocation, mode: mode, now: now) else {
            return nil
        }

        return estimate
    }

    @discardableResult
    static func clear(mode: Mode, ifNotNewerThan requestStartedAt: Date? = nil,
                      originId: Station.ID? = nil, defaults suppliedDefaults: UserDefaults? = nil,
                      directory: URL? = nil) -> Bool {
        let defaults = suppliedDefaults ?? self.defaults
        let root = directory ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
        guard let root else { return false }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = open(root.appendingPathComponent("travel-estimate.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return false }
        defer { flock(descriptor, LOCK_UN) }
        if let requestStartedAt {
            guard let data = defaults.data(forKey: key(for: mode)),
                  let existing = try? JSONDecoder().decode(Estimate.self, from: data),
                  originId == nil || existing.originId == originId,
                  existing.fetchedAt <= requestStartedAt,
                  (existing.requestStartedAt ?? existing.fetchedAt) <= requestStartedAt else { return false }
        }
        defaults.removeObject(forKey: key(for: mode))
        return true
    }

    private static func key(for mode: Mode) -> String {
        switch mode {
        case .walking:
            walkingKey
        case .driving:
            drivingKey
        }
    }
}

enum LockScreenRefreshFeedback {
    private struct Completion: Codable {
        let id: UUID
        var visibleUntil: Date?
    }

    private static let key = "lockScreenRefreshCompletion"
    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: "group.com.rhome.patconext") ?? .standard
    }

    static func recordCompletion(defaults: UserDefaults? = nil) {
        let completion = Completion(id: UUID(), visibleUntil: nil)
        if let data = try? JSONEncoder().encode(completion) {
            (defaults ?? sharedDefaults).set(data, forKey: key)
        }
    }

    static func visibleUntil(at now: Date, defaults: UserDefaults? = nil) -> Date? {
        let storage = defaults ?? sharedDefaults
        guard let data = storage.data(forKey: key),
              var completion = try? JSONDecoder().decode(Completion.self, from: data) else { return nil }
        if let end = completion.visibleUntil { return end > now ? end : nil }
        // Start the confirmation window when a timeline is prepared, not when the tap occurred.
        let end = now.addingTimeInterval(3)
        completion.visibleUntil = end
        if let encoded = try? JSONEncoder().encode(completion) { storage.set(encoded, forKey: key) }
        return end
    }
}

enum SharedWidgetReachabilityState {
    struct PendingRefresh: Codable, Equatable {
        let id: UUID
        let originId: Station.ID
        let mode: SharedReachabilityModeStore.Mode
    }

    private static let key = "widgetReachabilityPendingRefresh"
    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: "group.com.rhome.patconext") ?? .standard
    }

    static func pending(defaults: UserDefaults? = nil) -> PendingRefresh? {
        guard let data = (defaults ?? sharedDefaults).data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PendingRefresh.self, from: data)
    }

    static func requireRefresh(originId: Station.ID, mode: SharedReachabilityModeStore.Mode,
                               defaults: UserDefaults? = nil) {
        let request = PendingRefresh(id: UUID(), originId: originId, mode: mode)
        guard let data = try? JSONEncoder().encode(request) else { return }
        (defaults ?? sharedDefaults).set(data, forKey: key)
    }

    static func needsFollowUpRefresh(after request: PendingRefresh?, defaults: UserDefaults? = nil) -> Bool {
        guard let current = pending(defaults: defaults) else { return false }
        return current.id != request?.id
    }

    static func reconcileMode(originId: Station.ID, mode: SharedReachabilityModeStore.Mode,
                              defaults: UserDefaults? = nil) {
        guard let request = pending(defaults: defaults), request.originId == originId,
              request.mode != mode else { return }
        requireRefresh(originId: originId, mode: mode, defaults: defaults)
    }

    static func blocksCatchability(originId: Station.ID, defaults: UserDefaults? = nil) -> Bool {
        pending(defaults: defaults)?.originId == originId
    }

    @discardableResult
    static func complete(_ request: PendingRefresh, defaults: UserDefaults? = nil) -> Bool {
        // A refresh for an earlier toggle must not unlock the newly selected mode.
        guard pending(defaults: defaults) == request else { return false }
        (defaults ?? sharedDefaults).removeObject(forKey: key)
        return true
    }

    @discardableResult
    static func completeIfReady(_ request: PendingRefresh, originId: Station.ID,
                                mode: SharedReachabilityModeStore.Mode?, hasFreshEstimate: Bool,
                                isAtStation: Bool, defaults: UserDefaults? = nil) -> Bool {
        guard request.originId == originId,
              isAtStation || (request.mode == mode && hasFreshEstimate) else { return false }
        return complete(request, defaults: defaults)
    }
}

enum SharedReachabilityModeStore {
    enum Mode: String, Codable {
        case walking
        case driving
    }

    private struct Snapshot: Codable {
        let originId: Station.ID
        let mode: Mode
        let selectedAt: Date
        let isManual: Bool?
        var usesWalkingRoute: Bool? = nil
    }

    private static let suiteName = "group.com.rhome.patconext"
    private static let snapshotKey = "stickyReachabilityMode"
    private static let maxAge: TimeInterval = 3 * 60 * 60
    private static let atStationMeters = LocationGuidancePolicy.stationRadiusMeters
    private static let closeEnoughToWalkMeters = 0.75 * 1_609.34
    private static let farEnoughToDriveMeters = 1.25 * 1_609.34
    private static let reachabilityMaxDistanceMeters = 150 * 1_609.34

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func resolve(
        originId: Station.ID,
        distanceToStation: CLLocationDistance,
        minutesUntilDeparture: Int,
        defaultsToWalking: Bool = false,
        walkingEstimate: SharedTravelTimeEstimateCache.Estimate? = nil,
        now: Date = Date()
    ) -> Mode? {
        guard distanceToStation > atStationMeters,
              distanceToStation <= reachabilityMaxDistanceMeters else {
            return nil
        }

        let validEstimate = walkingEstimate.flatMap {
            $0.originId == originId && (0..<300).contains(now.timeIntervalSince($0.fetchedAt)) ? $0 : nil
        }
        let routeDistance = validEstimate?.routeDistanceMeters.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let decisionDistance = routeDistance ?? distanceToStation
        if let snapshot = snapshot(now: now), snapshot.originId == originId {
            if snapshot.isManual == true {
                return snapshot.mode
            }
            // Correct a provisional choice once routing arrives, then retain the
            // established mode across countdown ticks and temporary routing loss.
            if routeDistance == nil || snapshot.usesWalkingRoute == true {
                if snapshot.mode == .driving {
                    return .driving
                }
                if decisionDistance < farEnoughToDriveMeters {
                    return .walking
                }
            }
        }

        let mode = inferredMode(
            distanceToStation: decisionDistance,
            minutesUntilDeparture: minutesUntilDeparture,
            defaultsToWalking: defaultsToWalking,
            walkingMinutes: routeDistance == nil ? nil : validEstimate?.minutes
        )
        save(mode: mode, originId: originId, now: now, isManual: false, usesWalkingRoute: routeDistance != nil)
        return mode
    }

    static func save(
        mode: Mode,
        originId: Station.ID,
        now: Date = Date(),
        isManual: Bool = true,
        usesWalkingRoute: Bool = false
    ) {
        let snapshot = Snapshot(
            originId: originId,
            mode: mode,
            selectedAt: now,
            isManual: isManual,
            usesWalkingRoute: usesWalkingRoute
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
        SharedWidgetReachabilityState.reconcileMode(originId: originId, mode: mode)
    }

    static func isManual(originId: Station.ID) -> Bool {
        guard let snapshot = snapshot(now: Date()), snapshot.originId == originId else { return false }
        return snapshot.isManual == true
    }

    static func useAutomatic(originId: Station.ID) {
        guard let snapshot = snapshot(now: Date()), snapshot.originId == originId else { return }
        defaults.removeObject(forKey: snapshotKey)
    }

    static func shouldRequestWalkingEstimate(distance: Double, originId: Station.ID) -> Bool {
        guard distance > atStationMeters, distance <= reachabilityMaxDistanceMeters else { return false }
        return distance <= farEnoughToDriveMeters
            || (snapshot(now: Date()).map { $0.originId == originId && $0.isManual == true && $0.mode == .walking } ?? false)
    }

    @discardableResult
    static func clearOnArrival(originId: Station.ID) -> Bool {
        guard let snapshot = snapshot(now: Date()), snapshot.originId == originId else {
            return false
        }

        defaults.removeObject(forKey: snapshotKey)
        return true
    }

    private static func snapshot(now: Date) -> Snapshot? {
        guard let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            defaults.removeObject(forKey: snapshotKey)
            return nil
        }

        if snapshot.isManual != true,
           now.timeIntervalSince(snapshot.selectedAt) > maxAge {
            defaults.removeObject(forKey: snapshotKey)
            return nil
        }

        return snapshot
    }

    private static func inferredMode(
        distanceToStation: CLLocationDistance,
        minutesUntilDeparture: Int,
        defaultsToWalking: Bool,
        walkingMinutes: Int? = nil
    ) -> Mode {
        if distanceToStation <= closeEnoughToWalkMeters {
            return .walking
        }

        if distanceToStation >= farEnoughToDriveMeters {
            return .driving
        }

        if defaultsToWalking {
            return .walking
        }

        let minutes = walkingMinutes ?? max(1, Int(ceil((distanceToStation / 1.25) / 60)))
        return minutesUntilDeparture - minutes - 2 >= 0 ? .walking : .driving
    }
}

enum SharedCurrentLocationCache {
    struct Snapshot: Codable {
        let latitude: Double
        let longitude: Double
        let horizontalAccuracy: Double
        let timestamp: Date
        var speed: CLLocationSpeed? = nil

        var location: CLLocation {
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                altitude: 0,
                horizontalAccuracy: horizontalAccuracy,
                verticalAccuracy: -1,
                course: -1,
                speed: speed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? -1,
                timestamp: timestamp
            )
        }
    }

    private static let suiteName = "group.com.rhome.patconext"
    private static let locationKey = "cachedCurrentLocation"
    private static let freshLocationRequiredUntilKey = "freshLocationRequiredUntil"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func save(_ location: CLLocation) {
        let snapshot = Snapshot(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp,
            speed: location.speed.isFinite && location.speed >= 0 ? location.speed : nil
        )

        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: locationKey)
            defaults.removeObject(forKey: freshLocationRequiredUntilKey)
        }
    }

    static func clear() {
        defaults.removeObject(forKey: locationKey)
    }

    static func requireFreshLocation(for duration: TimeInterval = 30) {
        defaults.set(Date().addingTimeInterval(duration), forKey: freshLocationRequiredUntilKey)
    }

    static var freshLocationRequired: Bool {
        guard let requiredUntil = defaults.object(forKey: freshLocationRequiredUntilKey) as? Date,
              requiredUntil > Date() else {
            defaults.removeObject(forKey: freshLocationRequiredUntilKey)
            return false
        }
        return true
    }

    static func location(maxAge: TimeInterval = 10 * 60) -> CLLocation? {
        guard let data = defaults.data(forKey: locationKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              Date().timeIntervalSince(snapshot.timestamp) <= maxAge else {
            return nil
        }

        return snapshot.location
    }
}

struct TravelEstimateRequestGate {
    private var latest: UUID?

    mutating func begin() -> UUID {
        let id = UUID()
        latest = id
        return id
    }

    func accepts(_ id: UUID) -> Bool { latest == id }
}

enum EarlierDeparturesPolicy {
    static func visibleDepartures(_ departures: [Departure], isViewingToday: Bool, now: Date) -> [Departure] {
        departures.filter { shouldDisplay(departureDate: $0.departureDate, isViewingToday: isViewingToday, now: now) }
    }

    static func shouldDisplay(departureDate: Date, isViewingToday: Bool, now: Date) -> Bool {
        !isViewingToday || departureDate >= now
    }

    static func collapsibleCount(unreachable: [Bool?], hasReliableEstimate: Bool) -> Int {
        guard hasReliableEstimate else { return 0 }
        // Unknown guidance breaks the group; never collapse the entire list.
        let count = unreachable.prefix { $0 == true }.count
        return count < unreachable.count ? count : 0
    }
}
