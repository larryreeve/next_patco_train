import CoreLocation
import MapKit
import SwiftUI

struct TravelTimeEstimate {
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

enum StationTravelMode {
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
            2
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

enum TrainCatchStatus {
    case atStation
    case comfortable(travelMinutes: Int, mode: StationTravelMode, arrivalAtStationDate: Date, leaveByDate: Date)
    case tight(travelMinutes: Int, mode: StationTravelMode, arrivalAtStationDate: Date, leaveByDate: Date)
    case probablyMissed(travelMinutes: Int, mode: StationTravelMode, arrivalAtStationDate: Date, leaveByDate: Date)
    case tooLate(travelMinutes: Int, mode: StationTravelMode, arrivalAtStationDate: Date, leaveByDate: Date)

    var title: String {
        switch self {
        case .atStation:
            "At station"
        case .comfortable:
            "Likely to make this train"
        case .tight:
            "Timing is tight"
        case .probablyMissed:
            missedByText
        case .tooLate:
            missedByText
        }
    }

    var primaryGuidanceText: String {
        guard let leaveByText else { return title }
        return "\(title) · \(leaveByText)"
    }

    private var missedByText: String {
        let minutes = max(1, Int(ceil(abs(leaveByDate?.timeIntervalSinceNow ?? 0) / 60)))
        let unit = minutes == 1 ? "min" : "mins"
        return "You'd miss this train by about \(minutes) \(unit)"
    }

    func stationArrivalSummary(at stationName: String) -> (title: String, detail: String, arrivalTime: String, mode: StationTravelMode)? {
        switch self {
        case .atStation:
            return nil
        case .comfortable(_, let mode, let arrivalAtStationDate, _),
                .tight(_, let mode, let arrivalAtStationDate, _),
                .probablyMissed(_, let mode, let arrivalAtStationDate, _),
                .tooLate(_, let mode, let arrivalAtStationDate, _):
            let approach = mode == .walking ? "Walk" : "Drive"
            let arrivalTime = arrivalAtStationDate.formatted(date: .omitted, time: .shortened)
            return ("\(approach) to \(stationName)",
                    "Arrive at station about \(arrivalTime) if leaving now",
                    arrivalTime,
                    mode)
        }
    }

    func estimatedStationArrivalText(at stationName: String) -> String? {
        switch self {
        case .atStation:
            return nil
        case .comfortable(_, let mode, let arrivalAtStationDate, _),
                .tight(_, let mode, let arrivalAtStationDate, _),
                .probablyMissed(_, let mode, let arrivalAtStationDate, _),
                .tooLate(_, let mode, let arrivalAtStationDate, _):
            let travelMode = mode == .walking ? "walking" : "driving"
            return "Estimated arrival at \(stationName) if you leave now: \(arrivalAtStationDate.formatted(date: .omitted, time: .shortened)) · \(travelMode)"
        }
    }

    var leaveByText: String? {
        switch self {
        case .atStation, .probablyMissed, .tooLate:
            nil
        case .comfortable(_, _, _, let date), .tight(_, _, _, let date):
            "Leave by about \(date.formatted(date: .omitted, time: .shortened))"
        }
    }

    func leaveByStationText(for departure: Departure) -> String? {
        guard let deadlines = departureDeadlineTimes(for: departure) else { return nil }
        return "Leave by about \(deadlines.leaveBy) to arrive at the station by \(deadlines.stationBy)"
    }

    func departureDeadlineTimes(for departure: Departure) -> (leaveBy: String, stationBy: String)? {
        guard leaveByText != nil, let leaveByDate, let travelMode else { return nil }
        let stationArrivalDeadline = departure.departureDate.addingTimeInterval(
            -TimeInterval(travelMode.stationBufferMinutes * 60)
        )
        return (
            leaveByDate.formatted(date: .omitted, time: .shortened),
            stationArrivalDeadline.formatted(date: .omitted, time: .shortened)
        )
    }

    var imminentLeaveText: String? {
        guard let leaveByDate else { return nil }
        let secondsRemaining = leaveByDate.timeIntervalSinceNow
        let timeText = leaveByDate.formatted(date: .omitted, time: .shortened)
        if secondsRemaining < 60 {
            return "Leave now (by about \(timeText))"
        }

        let minutesRemaining = Int(floor(secondsRemaining / 60))
        let minuteText = minutesRemaining == 1 ? "1 min" : "\(minutesRemaining) mins"
        return "Leave in \(minuteText) (about \(timeText))"
    }

    private var leaveByDate: Date? {
        switch self {
        case .atStation:
            nil
        case .comfortable(_, _, _, let date),
                .tight(_, _, _, let date),
                .probablyMissed(_, _, _, let date),
                .tooLate(_, _, _, let date):
            date
        }
    }

    private var travelMode: StationTravelMode? {
        switch self {
        case .atStation:
            nil
        case .comfortable(_, let mode, _, _),
                .tight(_, let mode, _, _),
                .probablyMissed(_, let mode, _, _),
                .tooLate(_, let mode, _, _):
            mode
        }
    }

    var systemImage: String {
        switch self {
        case .atStation:
            "tram.fill"
        case .comfortable:
            "checkmark.circle.fill"
        case .tight(_, let mode, _, _):
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
            Color.patcoWine.opacity(0.82)
        }
    }

    var backgroundColor: Color {
        switch self {
        case .atStation, .comfortable:
            Color(red: 0.72, green: 0.92, blue: 0.78).opacity(0.7)
        case .tight:
            Color.patcoGold.opacity(0.34)
        case .probablyMissed, .tooLate:
            Color.patcoWine.opacity(0.09)
        }
    }

    func accessibilityText(at stationName: String, departure: Departure) -> String {
        let parts: [String?] = [title, leaveByStationText(for: departure), estimatedStationArrivalText(at: stationName)]
        return parts.compactMap { $0 }.joined(separator: ". ")
    }

    var isReachableForDisplay: Bool {
        switch self {
        case .atStation, .comfortable, .tight:
            true
        case .probablyMissed, .tooLate:
            false
        }
    }

    var isLikelyToCatch: Bool {
        if case .comfortable = self {
            return true
        }
        return false
    }

    var isTight: Bool {
        if case .tight = self {
            return true
        }
        return false
    }

    var travelMinutes: Int {
        switch self {
        case .atStation:
            0
        case .comfortable(let travelMinutes, _, _, _), .tight(let travelMinutes, _, _, _), .probablyMissed(let travelMinutes, _, _, _), .tooLate(let travelMinutes, _, _, _):
            travelMinutes
        }
    }

    private var mode: StationTravelMode {
        switch self {
        case .atStation:
            .walking
        case .comfortable(_, let mode, _, _), .tight(_, let mode, _, _), .probablyMissed(_, let mode, _, _), .tooLate(_, let mode, _, _):
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
