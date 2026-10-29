import Combine
import CoreLocation
import Foundation
import Darwin

enum JourneyTrackingPolicy {
    static func shouldBegin(atOrigin: Bool, arrivalSuppressed: Bool, departedArrivalStation: Bool, explicitTrip: Bool) -> Bool {
        explicitTrip || (!arrivalSuppressed && (atOrigin || departedArrivalStation))
    }
}

enum SharedJourneyTracking {
    private static let key = "journeyTrackingDeadline"
    private static var defaults: UserDefaults { UserDefaults(suiteName: "group.com.rhome.patconext") ?? .standard }
    static var deadline: Date? { defaults.object(forKey: key) as? Date }
    static func begin(until date: Date) { defaults.set(date, forKey: key) }
    static func end() { defaults.removeObject(forKey: key) }
}

enum JourneyRouteEvent: String, Codable {
    case backgroundArrival = "Background arrival"
    case estimatedArrival = "Estimated arrival"
    case appArrival = "App arrival"
    case confirmedArrival = "User confirmed arrival"
    case reversal = "Manual reversal"
    case selection = "Manual selection"
    case nearest = "Find nearest station"
    case recovery = "Return direction recovered; station arrival unconfirmed"
    case stationSelection = "Station departures selection"
    case stationRestored = "Station route restored"
    case bootstrap = "App route"
    case unknown

    var completesJourney: Bool {
        switch self {
        case .backgroundArrival, .estimatedArrival, .appArrival, .confirmedArrival: true
        default: false
        }
    }

    var endsTracking: Bool { completesJourney || self == .reversal || self == .recovery }
    var isTemporary: Bool { self == .stationSelection || self == .stationRestored }
}

enum ScheduledTripExpiration {
    static func deadline(arrivalDate: Date) -> Date {
        arrivalDate.addingTimeInterval(10 * 60)
    }

    static func hasExpired(arrivalDate: Date, now: Date = Date()) -> Bool {
        now >= deadline(arrivalDate: arrivalDate)
    }
}
