import ActivityKit
import CoreLocation
import MapKit
import SwiftUI
import WidgetKit
import AppIntents

enum SharedRouteDefaults {
    private static let suiteName = "group.com.rhome.patconext"
    private static let originKey = "defaultOriginStationId"
    private static let destinationKey = "defaultDestinationStationId"
    private static let temporaryOriginKey = "temporaryOriginStationId"
    private static let temporaryDestinationKey = "temporaryDestinationStationId"
    private static let temporarySavedAtKey = "temporaryRouteSavedAt"
    private static let journeyDestinationKey = "journeyDestinationStationId"
    private static let journeyDirectionSavedAtKey = "journeyDirectionSavedAt"
    private static let homeWidgetOriginKey = "homeWidgetOriginStationId"
    private static let homeWidgetDestinationKey = "homeWidgetDestinationStationId"

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

    static func journeyDestinationId(maxAge: TimeInterval = 4 * 60 * 60) -> Station.ID? {
        guard let destinationId = defaults.string(forKey: journeyDestinationKey),
              let savedAt = defaults.object(forKey: journeyDirectionSavedAtKey) as? Date,
              Date().timeIntervalSince(savedAt) <= maxAge else {
            return nil
        }
        return destinationId
    }

    static func recordHomeWidgetRoute(originId: Station.ID?, destinationId: Station.ID?) -> Bool {
        guard let originId, let destinationId else { return false }

        let changed = defaults.string(forKey: homeWidgetOriginKey) != originId
            || defaults.string(forKey: homeWidgetDestinationKey) != destinationId
        if changed {
            defaults.set(originId, forKey: homeWidgetOriginKey)
            defaults.set(destinationId, forKey: homeWidgetDestinationKey)
        }
        return changed
    }

}

enum WidgetRefreshState {
    private static let suiteName = "group.com.rhome.patconext"
    private static let locationFailureAtKey = "widgetLocationRefreshFailedAt"
    private static let actionCompletedAtKey = "widgetActionCompletedAt"
    private static let failureVisibility: TimeInterval = 2 * 60

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func actionCompleted() {
        defaults.set(Date(), forKey: actionCompletedAtKey)
    }

    // Interactive reloads must not block on another GPS or network request.
    // The shared snapshot still enforces route revision and location freshness.
    static var recentActionTrip: SharedTripState.Snapshot? {
        if WidgetActionProgress.current() != nil { return SharedTripState.current() }
        guard let completedAt = defaults.object(forKey: actionCompletedAtKey) as? Date,
              (0...30).contains(Date().timeIntervalSince(completedAt)) else { return nil }
        return SharedTripState.current()
    }

    static var authorizedCachedLocation: CLLocation? {
        guard guidanceAllowed else { return nil }
        return SharedCurrentLocationCache.location(maxAge: 15 * 60)
    }

    static var guidanceAllowed: Bool {
        guard WidgetReachabilitySettings.isEnabled else { return false }
        let status = CLLocationManager().authorizationStatus
        return status == .authorizedAlways || status == .authorizedWhenInUse
    }

    static func recordLocationOutcome(available: Bool) {
        if available {
            defaults.removeObject(forKey: locationFailureAtKey)
        } else {
            defaults.set(Date(), forKey: locationFailureAtKey)
        }
    }

    static var hasRecentLocationFailure: Bool {
        guard let failedAt = defaults.object(forKey: locationFailureAtKey) as? Date,
              Date().timeIntervalSince(failedAt) < failureVisibility else {
            defaults.removeObject(forKey: locationFailureAtKey)
            return false
        }
        return true
    }
}
