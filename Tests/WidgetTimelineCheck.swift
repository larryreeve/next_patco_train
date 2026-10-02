import Foundation

@main
struct WidgetTimelineCheck {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let departure = now.addingTimeInterval(90 * 60)
        let dates = WidgetTimelinePolicy.entryDates(now: now, departures: [departure, departure, now.addingTimeInterval(-60)])
        precondition(dates.first == now)
        precondition(dates.last == now.addingTimeInterval(24 * 3600))
        precondition(dates.contains(departure.addingTimeInterval(1)))
        precondition(Set(dates).count == dates.count)
        precondition(dates == dates.sorted())
        precondition(WidgetTimelinePolicy.entryDates(now: now, departures: []).last == now.addingTimeInterval(24 * 3600))
        precondition(WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: true, locationTimestamp: now).date == now.addingTimeInterval(180))
        precondition(WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: true, locationTimestamp: now.addingTimeInterval(-120)).date == now.addingTimeInterval(60))
        precondition(WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: true, locationTimestamp: now.addingTimeInterval(-179)).date == now.addingTimeInterval(60))
        precondition(WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: true, locationTimestamp: now.addingTimeInterval(-180)).date == now.addingTimeInterval(600))
        precondition(WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: false, locationTimestamp: now).date == now.addingTimeInterval(600))
        precondition(WidgetTimelinePolicy.nextRefresh(now: now, hasService: true, hasGuidance: false, locationTimestamp: nil).date == now.addingTimeInterval(600))
        precondition(WidgetTimelinePolicy.nextRefresh(now: now, hasService: false, hasGuidance: false, locationTimestamp: nil).date == now.addingTimeInterval(1800))
        print("Widget timeline checks passed")
        precondition(WidgetTimelinePolicy.lockScreenRefresh(now: now, trackingDeadline: nil, hasActiveTrip: false) == now.addingTimeInterval(900))
        precondition(WidgetTimelinePolicy.lockScreenRefresh(now: now, trackingDeadline: now.addingTimeInterval(7200), hasActiveTrip: false) == now.addingTimeInterval(300))
        precondition(WidgetTimelinePolicy.lockScreenRefresh(now: now, trackingDeadline: now, hasActiveTrip: false) == now.addingTimeInterval(900))
        precondition(WidgetTimelinePolicy.lockScreenRefresh(now: now, trackingDeadline: now.addingTimeInterval(7201), hasActiveTrip: false) == now.addingTimeInterval(900))
        precondition(WidgetTimelinePolicy.lockScreenRefresh(now: now, trackingDeadline: nil, hasActiveTrip: true) == now.addingTimeInterval(300))
    }
}
