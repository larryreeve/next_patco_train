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
        print("Widget timeline checks passed")
    }
}
