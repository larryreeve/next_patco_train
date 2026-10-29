import Combine
import CoreLocation
import Foundation
import Darwin

struct PATCOFeed: Codable {
    let generatedFrom: String
    let feed: [String: String]
    let route: [String: String]
    let stops: [Station]
    let calendars: [ServiceCalendar]
    let calendarDates: [CalendarDateException]
    let trips: [Trip]

    func validateStopIdentifiers() throws {
        let ids = stops.map(\.id)
        guard !ids.isEmpty,
              ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(ids).count == ids.count else {
            throw ScheduleLoadError.invalidStopIdentifiers
        }
    }
}

struct Station: Codable, Identifiable, Hashable {
    let id: String
    let code: String
    let name: String
    let latitude: Double
    let longitude: Double
    let zone: String
    let url: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    var defaultsToWalkingForReachability: Bool {
        zone == "6"
    }

    var supportsUndergroundReturnRecovery: Bool {
        // PATCO's Camden and Philadelphia underground city stops, using bundled feed codes.
        ["8", "9", "10", "11", "12", "13", "14"].contains(code)
    }
}

struct DepartureDeepLink: Equatable {
    let originId: Station.ID
    let destinationId: Station.ID
    let departureDate: Date

    init?(url: URL) {
        guard url.scheme == "patconext", url.host == "departure",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let originId = components.queryItems?.first(where: { $0.name == "origin" })?.value,
              let destinationId = components.queryItems?.first(where: { $0.name == "destination" })?.value,
              !originId.isEmpty, !destinationId.isEmpty, originId != destinationId,
              let departureValue = components.queryItems?.first(where: { $0.name == "departure" })?.value,
              let departureTimeInterval = TimeInterval(departureValue), departureTimeInterval.isFinite else { return nil }
        self.originId = originId
        self.destinationId = destinationId
        departureDate = Date(timeIntervalSince1970: departureTimeInterval)
    }
}

struct ServiceCalendar: Codable {
    let serviceId: String
    let weekdays: Weekdays
    let startDate: String
    let endDate: String
}

struct Weekdays: Codable {
    let monday: Bool
    let tuesday: Bool
    let wednesday: Bool
    let thursday: Bool
    let friday: Bool
    let saturday: Bool
    let sunday: Bool

    func contains(_ weekday: Int) -> Bool {
        switch weekday {
        case 1: sunday
        case 2: monday
        case 3: tuesday
        case 4: wednesday
        case 5: thursday
        case 6: friday
        case 7: saturday
        default: false
        }
    }
}

struct CalendarDateException: Codable {
    let serviceId: String
    let date: String
    let exceptionType: Int
}

struct Trip: Codable, Identifiable {
    let id: String
    let serviceId: String
    let headsign: String
    let directionId: Int?
    let bikesAllowed: Bool
    let wheelchairAccessible: Bool
    let stopTimes: [StopTime]
}

struct StopTime: Codable {
    let stopId: String
    let arrival: String
    let departure: String
    let sequence: Int
}

struct Departure: Identifiable, Codable {
    var id = UUID()
    let trip: Trip
    let origin: Station
    let destination: Station
    let originTime: StopTime
    let destinationTime: StopTime
    let serviceDate: Date
    let departureDate: Date
    let arrivalDate: Date
    let routeSequenceIndex: Int
    let isSpecialSchedule: Bool
    let isRemovedBySpecialSchedule: Bool
    let scheduleAdjustment: ScheduleAdjustment?

    var deviatesFromStandardSchedule: Bool {
        scheduleAdjustment != nil
    }

    var travelMinutes: Int {
        max(0, Int(arrivalDate.timeIntervalSince(departureDate) / 60))
    }

    var directionLabel: String {
        trip.headsign == "Philadelphia" ? "Westbound" : "Eastbound"
    }

    var fullDirectionLabel: String {
        "\(directionLabel) to \(trip.headsign)"
    }

    func withScheduleAdjustment(_ adjustment: ScheduleAdjustment?, routeSequenceIndex: Int) -> Departure {
        Departure(
            trip: trip,
            origin: origin,
            destination: destination,
            originTime: originTime,
            destinationTime: destinationTime,
            serviceDate: serviceDate,
            departureDate: departureDate,
            arrivalDate: arrivalDate,
            routeSequenceIndex: routeSequenceIndex,
            isSpecialSchedule: isSpecialSchedule,
            isRemovedBySpecialSchedule: isRemovedBySpecialSchedule,
            scheduleAdjustment: adjustment
        )
    }

    func markedRemovedBySpecialSchedule(routeSequenceIndex: Int) -> Departure {
        Departure(
            trip: trip,
            origin: origin,
            destination: destination,
            originTime: originTime,
            destinationTime: destinationTime,
            serviceDate: serviceDate,
            departureDate: departureDate,
            arrivalDate: arrivalDate,
            routeSequenceIndex: routeSequenceIndex,
            isSpecialSchedule: true,
            isRemovedBySpecialSchedule: true,
            scheduleAdjustment: nil
        )
    }
}

struct ScheduleAdjustment: Codable {
    let originalDepartureDate: Date?
}

struct PATCOSpecialSchedule: Codable, Equatable {
    struct ScheduledTrip: Codable, Equatable {
        let directionId: Int
        let stopTimes: [String]
    }

    let title: String
    let serviceDate: Date
    let sourceURL: URL
    let trips: [ScheduledTrip]

    var hasUnconfirmedTimes: Bool {
        trips.contains { trip in
            trip.stopTimes.contains { !$0.isEmpty && PATCOScheduleStore.scheduleDate(
                serviceDate: serviceDate, timeString: $0, isSpecialSchedule: true) == nil }
        }
    }

    func hasUnconfirmedTimes(on date: Date) -> Bool {
        guard hasUnconfirmedTimes else { return false }
        let calendar = PATCOClock.calendar
        if calendar.isDate(serviceDate, inSameDayAs: date) { return true }
        return trips.contains { trip in
            trip.stopTimes.contains { time in
                guard let hourText = time.split(separator: ":").first, let hours = Int(hourText), hours >= 0,
                      let day = calendar.date(byAdding: .day, value: hours / 24, to: calendar.startOfDay(for: serviceDate)),
                      calendar.isDate(day, inSameDayAs: date) else { return false }
                return PATCOScheduleStore.scheduleDate(serviceDate: serviceDate, timeString: time, isSpecialSchedule: true) == nil
            }
        }
    }
}

struct ActiveSpecialSchedule: Equatable {
    let title: String
    let serviceDate: Date
    let sourceURL: URL
    let tripCount: Int
    var hasUnconfirmedTimes: Bool = false
}

enum ScheduleLoadError: LocalizedError {
    case missingResource
    case invalidStopIdentifiers

    var errorDescription: String? {
        switch self {
        case .missingResource: "The bundled PATCO schedule could not be loaded."
        case .invalidStopIdentifiers: "The PATCO schedule contains invalid or duplicate station identifiers."
        }
    }
}

struct PATCOFeedMetadata: Codable {
    let downloadedAt: Date
    let feedStartDate: String
    let feedEndDate: String
    let feedVersion: String?
    let lastUpdatedAt: Date?
    let previousFeedVersion: String?
    let sourceURL: URL
}
