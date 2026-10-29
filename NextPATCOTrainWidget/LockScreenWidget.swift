import ActivityKit
import CoreLocation
import MapKit
import SwiftUI
import WidgetKit
import AppIntents

private struct PATCOLockScreenEntry: TimelineEntry {
    let date: Date
    let departureDates: [Date]
    let originName: String
    let destinationName: String
    var catchStatuses: [Date: WidgetCatchStatus] = [:]
    var routeRevision: Int? = nil
    var refreshCompleted = false
    var hasUnconfirmedTimes = false
    var originId: Station.ID? = nil
}

// WidgetKit's completion is invoked once after the main-actor location request finishes.
private struct LockScreenTimelineCompletion: @unchecked Sendable {
    let call: (Timeline<PATCOLockScreenEntry>) -> Void
}

private struct PATCOLockScreenProvider: TimelineProvider {
    func placeholder(in context: Context) -> PATCOLockScreenEntry {
        let now = Date()
        return PATCOLockScreenEntry(
            date: now,
            departureDates: [15, 30, 45].map { now.addingTimeInterval(TimeInterval($0 * 60)) },
            originName: "Ashland",
            destinationName: "15/16th"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (PATCOLockScreenEntry) -> Void) {
        // Previews must not resolve arrivals, publish state, or build future entries.
        let now = Date()
        let route = SharedRouteCoordinator.current()
        let candidate = SharedTripState.current()
        let shared = candidate?.routeRevision == route?.revision ? candidate : nil
        let store = PATCOScheduleStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let dates = (-1...1).compactMap { calendar.date(byAdding: .day, value: $0, to: now) }
        let schedules = SharedSpecialScheduleCache.schedules(matching: dates, calendar: calendar)
        store.applySpecialSchedules(schedules)
        let origin = route.flatMap { store.station(for: $0.originId) }
        let destination = route.flatMap { store.station(for: $0.destinationId) }
        let departures = shared?.upcoming(at: now) ?? origin.flatMap { origin in
            destination.map { store.departures(from: origin, to: $0, after: now, limit: 3) }
        } ?? []
        let selected = WidgetDepartureSelection.select(departures, limit: 3)
        let statuses = Dictionary(selected.compactMap { departure -> (Date, WidgetCatchStatus)? in
            guard WidgetReachabilitySettings.isEnabled, WidgetRefreshState.guidanceAllowed,
                  !SharedWidgetReachabilityState.blocksCatchability(originId: departure.origin.id),
                  let result = shared?.catchResult(for: departure, at: now) else { return nil }
            return (departure.departureDate, WidgetCatchStatus(result))
        }, uniquingKeysWith: { first, _ in first })
        let unconfirmed = WidgetTimelinePolicy.unconfirmedTimesByDay(schedules: schedules, dates: [now])
        completion(PATCOLockScreenEntry(date: now, departureDates: selected.map(\.departureDate),
            originName: origin?.name ?? "PATCO", destinationName: destination?.name ?? "",
            catchStatuses: statuses, routeRevision: route?.revision,
            hasUnconfirmedTimes: unconfirmed[calendar.startOfDay(for: now)] ?? false, originId: origin?.id))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PATCOLockScreenEntry>) -> Void) {
        let request = SharedWidgetDiagnostics.latestReloadRequest
        let runId = UUID()
        let requestDetail = request.map {
            "Latest request \($0.id); \($0.action); expected revision \($0.revision); \(Int(max(0, Date().timeIntervalSince($0.date)))) sec since request (trigger not exposed by iOS)"
        } ?? "No recorded widget action reload request"
        SharedWidgetDiagnostics.record("Lock Screen timeline requested", detail: "Run \(runId); \(requestDetail)")
        let routeChanged = SharedRouteCoordinator.current().map {
            $0.revision != SharedDiagnosticState.snapshot(for: .lockScreen)?.revision
        } ?? false
        if SharedTripState.current() != nil && (routeChanged || WidgetRefreshState.recentActionTrip != nil) {
            SharedWidgetDiagnostics.record("Lock Screen route prioritized",
                detail: "Publishing committed route immediately without waiting for GPS")
            completion(makeCurrentTimeline(currentLocation: WidgetRefreshState.authorizedCachedLocation,
                reloadRequest: request, runId: runId))
            return
        }
        let callback = LockScreenTimelineCompletion(call: completion)
        Task { @MainActor in
            _ = await NextPATCOTrainWidgetProvider().specialSchedulesForDepartureWindow(from: Date())
            let location: CLLocation?
            let status = CLLocationManager().authorizationStatus
            if status != .authorizedAlways && status != .authorizedWhenInUse {
                SharedCurrentLocationCache.clear()
                location = nil
            } else {
                if WidgetRefreshState.recentActionTrip != nil {
                    location = WidgetRefreshState.authorizedCachedLocation
                    SharedWidgetDiagnostics.record("Lock Screen action rendered", detail: "Using committed shared schedule without waiting for location")
                } else {
                    location = WidgetRefreshState.authorizedCachedLocation
                }
            }
            callback.call(makeCurrentTimeline(currentLocation: location, reloadRequest: request, runId: runId))
        }
    }

    private func makeCurrentTimeline(currentLocation: CLLocation?,
                                     reloadRequest: SharedWidgetDiagnostics.ReloadRequest? = nil,
                                     runId: UUID? = nil) -> Timeline<PATCOLockScreenEntry> {
        var timeline = makeTimeline(at: Date(), currentLocation: currentLocation,
                                    reloadRequest: reloadRequest, runId: runId)
        // Another widget process may reverse the route while this timeline is being built.
        for _ in 0..<2 {
            guard timeline.entries.first?.routeRevision != SharedRouteCoordinator.current()?.revision else { return timeline }
            SharedWidgetDiagnostics.record("Lock Screen timeline superseded",
                detail: "Rebuilding for the latest committed route before completion")
            timeline = makeTimeline(at: Date(), currentLocation: currentLocation,
                                    reloadRequest: reloadRequest, runId: runId)
        }
        if timeline.entries.first?.routeRevision != SharedRouteCoordinator.current()?.revision {
            WidgetCenter.shared.reloadTimelines(ofKind: "NextPATCOLockScreenWidget")
            let store = PATCOScheduleStore()
            let route = SharedRouteCoordinator.current()
            let neutral = PATCOLockScreenEntry(date: Date(), departureDates: [],
                originName: route.flatMap { store.station(for: $0.originId)?.name } ?? "PATCO",
                destinationName: route.flatMap { store.station(for: $0.destinationId)?.name } ?? "",
                routeRevision: route?.revision)
            return Timeline(entries: [neutral], policy: .after(Date().addingTimeInterval(60)))
        }
        return timeline
    }

    private func makeTimeline(at now: Date, currentLocation: CLLocation?, reloadRequest: SharedWidgetDiagnostics.ReloadRequest? = nil, runId: UUID? = nil) -> Timeline<PATCOLockScreenEntry> {
        let store = PATCOScheduleStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let serviceDates = (-1...1).compactMap { calendar.date(byAdding: .day, value: $0, to: now) }
        let specialSchedules = SharedSpecialScheduleCache.schedules(matching: serviceDates, calendar: calendar)
        if !specialSchedules.isEmpty {
            store.applySpecialSchedules(specialSchedules)
        }
        var route = NextPATCOTrainWidgetProvider().selectedRoute(in: store, currentLocation: currentLocation,
                                                               reloadKind: "NextPATCOTrainWidget")
        let shared = WidgetRefreshState.recentActionTrip
            ?? NextPATCOTrainWidgetProvider().updateSharedTrip(store: store, location: currentLocation,
            reloadWidgets: false)
        if let shared { route = (shared.origin, shared.destination) }
        let routeRevision = shared?.routeRevision ?? SharedRouteCoordinator.current().flatMap {
            $0.originId == route.origin?.id && $0.destinationId == route.destination?.id ? $0.revision : nil
        }
        let departures: [Departure]
        if let shared {
            departures = shared.upcoming(at: now)
        } else if let origin = route.origin, let destination = route.destination {
            departures = store.departures(from: origin, to: destination, after: now, limit: 500)
        } else {
            departures = []
        }

        let confirmationEnd = LockScreenRefreshFeedback.visibleUntil(at: now)
        let scheduledDates = WidgetTimelinePolicy.entryDates(now: now, departures: departures.map(\.departureDate),
                                                            guidanceExpiration: shared?.guidance?.expirationDate)
        let entryDates = Array(Set(scheduledDates + (confirmationEnd.map { [$0] } ?? []))).sorted()
        let unconfirmedDays = WidgetTimelinePolicy.unconfirmedTimesByDay(
            schedules: specialSchedules, dates: entryDates)
        let entries = entryDates.map { date in
            let upcoming = departures.filter { $0.departureDate >= date }
            let selected = WidgetDepartureSelection.select(upcoming, limit: 3)
            let statuses = Dictionary(selected.compactMap { departure -> (Date, WidgetCatchStatus)? in
                guard WidgetReachabilitySettings.isEnabled,
                      !SharedWidgetReachabilityState.blocksCatchability(originId: departure.origin.id) else { return nil }
                guard WidgetRefreshState.guidanceAllowed,
                      let result = shared?.catchResult(for: departure, at: date) else { return nil }
                return (departure.departureDate, WidgetCatchStatus(result))
            }, uniquingKeysWith: { first, _ in first })
            return PATCOLockScreenEntry(
                date: date,
                departureDates: selected.map(\.departureDate),
                originName: shared?.origin.name ?? route.origin?.name ?? "PATCO",
                destinationName: shared?.destination.name ?? route.destination?.name ?? "",
                catchStatuses: statuses,
                routeRevision: routeRevision,
                refreshCompleted: confirmationEnd.map { date < $0 } ?? false,
                hasUnconfirmedTimes: unconfirmedDays[calendar.startOfDay(for: date)] ?? false,
                originId: shared?.origin.id ?? route.origin?.id
            )
        }
        let journey = SharedRouteCoordinator.current()?.journey
        let legacyActivity = Activity<PATCOTripActivityAttributes>.activities.contains {
            ($0.activityState == .active || $0.activityState == .stale)
                && $0.attributes.originName == route.origin?.name
                && $0.attributes.destinationName == route.destination?.name
                && $0.content.state.departureDate <= now.addingTimeInterval(3600)
                && !ScheduledTripExpiration.hasExpired(arrivalDate: $0.content.state.arrivalDate, now: now)
        }
        let hasActiveTrip = journey.map { $0.isActive(at: now) && $0.departure <= now.addingTimeInterval(3600) }
            ?? legacyActivity
        let nextRefresh = WidgetTimelinePolicy.lockScreenRefresh(
            now: now, trackingDeadline: journey?.isActive(at: now) == false ? nil : SharedJourneyTracking.deadline,
            hasActiveTrip: hasActiveTrip
        )
        SharedWidgetDiagnostics.record("Lock Screen timeline prepared", detail: "\(departures.count) departures; next requested \(nextRefresh.formatted(date: .omitted, time: .shortened)); \(Int(nextRefresh.timeIntervalSince(now) / 60))-minute interval")
        let committed = SharedRouteCoordinator.current()
        let recordedRevision = committed?.originId == route.origin?.id && committed?.destinationId == route.destination?.id
            ? committed?.revision : nil
        if let runId {
            let result = reloadRequest.map {
                "Request \($0.id); \($0.outcome(revision: recordedRevision, originId: route.origin?.id, destinationId: route.destination?.id))"
            } ?? "No recorded widget action reload request"
            SharedWidgetDiagnostics.record("Lock Screen route loaded", detail: "Run \(runId); \(result); loaded revision \(recordedRevision.map(String.init) ?? "unknown"): \(route.origin?.name ?? "none") to \(route.destination?.name ?? "none"); timeline prepared for WidgetKit, on-screen redraw not confirmed")
        }
        SharedDiagnosticState.record(.lockScreen, origin: route.origin, destination: route.destination,
                                     revision: recordedRevision, nextRequestedAt: nextRefresh,
                                     location: currentLocation, travelEstimateSource: shared?.guidance?.estimateSource ?? "Scheduled times only",
                                     appliedSpecialSchedules: specialSchedules.map { "\($0.title) (\($0.serviceDate.formatted(date: .abbreviated, time: .omitted)))" })
        return Timeline(entries: entries, policy: .after(nextRefresh))
    }
}

private struct PATCOLockScreenView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: PATCOLockScreenEntry

    private var visibleCatchStatuses: [Date: WidgetCatchStatus] {
        guard WidgetReachabilitySettings.isEnabled, let originId = entry.originId,
              !SharedWidgetReachabilityState.blocksCatchability(originId: originId) else { return [:] }
        return entry.catchStatuses
    }

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            Text(entry.destinationName.isEmpty ? "PATCO" : "\(shortName(entry.originName)) → \(shortName(entry.destinationName))\(dayContextText.map { " · \($0)" } ?? "")")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)

            if entry.hasUnconfirmedTimes {
                Text("Check PDF: DST times unconfirmed")
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if !entry.departureDates.isEmpty {
                departureTimesText
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .accessibilityLabel(
                        "Scheduled departures: " + entry.departureDates
                            .map { date in
                                PATCOClock.timeText(date)
                                    + (visibleCatchStatuses[date].map { ", \($0.accessibilityDescription)" } ?? "")
                            }
                            .joined(separator: ", ")
                    )

            } else {
                Text("Open for scheduled departures")
                    .font(.caption)
                    .lineLimit(2)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
        .containerBackground(.clear, for: .widget)
        .widgetURL(URL(string: "patconext://widget"))
    }

    private func shortName(_ name: String) -> String {
        name == "15/16th and Locust" ? "15/16th" : name
    }

    private var departureTimesText: Text {
        let formatter = DateFormatter()
        formatter.timeZone = PATCOClock.calendar.timeZone
        let hourFormat = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h a"
        formatter.dateFormat = hourFormat.contains("a") ? "h:mm" : "HH:mm"
        var text = AttributedString()
        for (index, date) in entry.departureDates.enumerated() {
            if index > 0 { text.append(AttributedString(" · ")) }
            var time = AttributedString(formatter.string(from: date) + PATCOClock.timeZoneSuffix(date))
            time.foregroundColor = renderingMode == .fullColor
                ? visibleCatchStatuses[date]?.color ?? .primary
                : .primary
            text.append(time)
        }
        return Text(text)
    }

    private var dayContextText: String? {
        let calendar = PATCOClock.calendar
        let nextDayDates = entry.departureDates.filter { !calendar.isDate($0, inSameDayAs: entry.date) }
        guard !nextDayDates.isEmpty else { return nil }

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: entry.date)
        let dayName = tomorrow.map { calendar.isDate(nextDayDates[0], inSameDayAs: $0) } == true
            ? "tomorrow"
            : nextDayDates[0].formatted(Date.FormatStyle(timeZone: PATCOClock.calendar.timeZone).weekday(.wide))
        if nextDayDates.count == entry.departureDates.count {
            return "\(dayName.capitalized) · scheduled"
        }
        return "Later trains \(dayName)"
    }
}

struct NextPATCOLockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextPATCOLockScreenWidget", provider: PATCOLockScreenProvider()) { entry in
            PATCOLockScreenView(entry: entry)
        }
        .configurationDisplayName("Next PATCO Train")
        .description("See the next three scheduled trains and open the app from the Lock Screen.")
        .supportedFamilies([.accessoryRectangular])
    }
}
