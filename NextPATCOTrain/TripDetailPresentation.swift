import CoreLocation
import Foundation

struct TripDetailStop: Identifiable {
    let station: Station
    let stopTime: StopTime
    var id: String { "\(station.id)-\(stopTime.sequence)" }
}

/// A read-only snapshot shared by the summary, map and stop list.
struct TripDetailPresentation {
    let departure: Departure
    let stops: [TripDetailStop]
    let session: JourneyProgressSession?
    let tripKey: String?
    let progress: TripLocationProgress

    func destinationEstimate(at date: Date) -> TripLocationProgress.ArrivalEstimate? {
        guard hasTripProgress, session?.isActive(at: date) == true,
            !departure.isRemovedBySpecialSchedule
        else { return nil }
        var scheduled: [Station.ID: Date] = [:]
        for stop in stops {
            scheduled[stop.station.id] = PATCOScheduleStore.scheduleDate(
                serviceDate: departure.serviceDate,
                timeString: stop.stopTime.arrival, isSpecialSchedule: departure.isSpecialSchedule)
        }
        scheduled[departure.origin.id] = departure.departureDate
        scheduled[departure.destination.id] = departure.arrivalDate
        return progress.arrivalEstimate(
            stations: stops.map(\.station), scheduled: scheduled,
            geometry: PATCOTrackGeometry.bundled, now: date)
    }

    func progressIsCurrent(at date: Date) -> Bool {
        guard hasTripProgress else { return false }
        if progress.mapPosition(
            stations: stops.map(\.station),
            geometry: PATCOTrackGeometry.bundled, now: date)?.isFreshGPS == true
        {
            return true
        }
        return progress.arrivalAnchorAt.map {
            (0...TripArrivalEstimatePolicy.stationAnchorMaximumAge).contains(date.timeIntervalSince($0))
        } ?? false
    }

    var hasTripProgress: Bool {
        guard let session = session,
            session.key == tripKey,
            let url = URL(string: session.deepLink),
            let link = DepartureDeepLink(url: url)
        else { return false }
        return link.originId == departure.origin.id && link.destinationId == departure.destination.id
            && link.departureDate == departure.departureDate
    }

    var detectedStationIds: Set<String> {
        hasTripProgress ? progress.detectedStationIds : []
    }

    var completedStationIds: Set<String> {
        hasTripProgress ? progress.completedStationIds : []
    }

    var scheduledStops: [TripDetailStop] {
        Array(stops.dropFirst())
    }

    func nextStop(at date: Date) -> TripDetailStop? {
        guard date >= departure.departureDate, hasTripProgress,
            progressIsCurrent(at: date),
            session?.isActive(at: date) == true,
            !departure.isRemovedBySpecialSchedule,
            let index = stops.lastIndex(where: { completedStationIds.contains($0.station.id) }),
            index + 1 < stops.count
        else { return nil }
        return stops[index + 1]
    }

    var nextStopLabel: String {
        guard let last = stops.last(where: { completedStationIds.contains($0.station.id) }),
            detectedStationIds.contains(last.station.id)
        else { return "Next expected stop" }
        return "Next stop"
    }

    func stopCountTitle(at now: Date) -> String {
        if hasTripProgress, session?.isActive(at: now) == true, now >= departure.departureDate {
            let count = scheduledStops.filter { !completedStationIds.contains($0.station.id) }.count
            return count == 1 ? "1 stop remaining" : "\(count) stops remaining"
        }
        return scheduledStops.count == 1 ? "1 stop" : "\(scheduledStops.count) stops"
    }

    var departureTimeText: String {
        PATCOClock.timeText(departure.departureDate, relativeTo: departure.arrivalDate)
    }

    var arrivalTimeText: String {
        PATCOClock.timeText(departure.arrivalDate, relativeTo: departure.departureDate)
    }

    var rideTimeText: String {
        "\(departure.travelMinutes) min"
    }

    var stationPairText: String {
        "\(departure.origin.name) \u{2192} \(departure.destination.name)"
    }

    var adjustedFromText: String? {
        guard let adjustment = departure.scheduleAdjustment else { return nil }
        guard let originalDepartureDate = adjustment.originalDepartureDate else {
            return "Departure added by special schedule"
        }

        return "Adjusted from \(PATCOClock.timeText(originalDepartureDate))"
    }

    func departureTimeTitle(at date: Date) -> String {
        guard date >= departure.departureDate else { return "Scheduled Departure" }

        let elapsedMinutes = max(0, Int(date.timeIntervalSince(departure.departureDate) / 60))
        if elapsedMinutes == 0 {
            return "Scheduled departure: just now"
        }

        return "Scheduled departure: \(elapsedMinutes) min ago"
    }

    func timeText(for stop: TripDetailStop, isFinalStop: Bool) -> String {
        let value = isFinalStop ? stop.stopTime.arrival : stop.stopTime.departure
        guard
            let date = PATCOScheduleStore.scheduleDate(
                serviceDate: departure.serviceDate, timeString: value,
                isSpecialSchedule: departure.isSpecialSchedule)
        else { return "Time unconfirmed" }
        return PATCOClock.timeText(date, relativeTo: departure.departureDate)
    }

    func estimatedArrivalText(
        for stop: TripDetailStop,
        estimate: TripLocationProgress.ArrivalEstimate?, at date: Date
    ) -> String? {
        guard date >= departure.departureDate, hasTripProgress,
            session?.isActive(at: date) == true,
            !departure.isRemovedBySpecialSchedule
        else { return nil }
        guard let estimate,
            let scheduled = PATCOScheduleStore.scheduleDate(
                serviceDate: departure.serviceDate,
                timeString: stop.stopTime.arrival, isSpecialSchedule: departure.isSpecialSchedule),
            let arrival = estimate.arrival(at: scheduled, scheduledDestination: departure.arrivalDate, now: date)
        else { return nil }
        return "Est. arrival \(PATCOClock.timeText(arrival, relativeTo: departure.departureDate))"
    }
}
