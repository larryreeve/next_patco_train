import ActivityKit
import CoreLocation
import MapKit
import SwiftUI
import WidgetKit
import AppIntents

struct PATCOTripLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PATCOTripActivityAttributes.self) { context in
            PATCOTripLiveActivityView(context: context)
                .activityBackgroundTint(Color.patcoCharcoal)
                .activitySystemActionForegroundColor(Color.patcoGold)
                .widgetURL(context.attributes.deepLinkURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.originName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                        Text(PATCOClock.timeText(context.state.departureDate, relativeTo: context.state.arrivalDate))
                            .font(.headline.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.attributes.destinationName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                        Text("Arrives \(PATCOClock.timeText(context.state.arrivalDate, relativeTo: context.state.departureDate))")
                            .font(.headline.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    if context.isStale && ScheduledTripExpiration.hasExpired(arrivalDate: context.state.arrivalDate) {
                        Text("Scheduled trip ended")
                            .font(.caption)
                    } else {
                        ScheduledDepartureCountdownView(
                            startDate: context.state.lastUpdated,
                            departureDate: context.state.departureDate,
                            isStale: context.isStale,
                            compact: true
                        )
                    }
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: "tram.fill")
                        .font(.caption.weight(.bold))
                    Text(context.isStale && ScheduledTripExpiration.hasExpired(arrivalDate: context.state.arrivalDate) ? "Ended" : shortTimeText(context.state.departureDate))
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .minimumScaleFactor(0.65)
                }
                .foregroundStyle(Color.patcoGold)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Text(context.isStale && ScheduledTripExpiration.hasExpired(arrivalDate: context.state.arrivalDate) ? "Ended" : shortTimeText(context.state.departureDate))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.65)
                .foregroundStyle(Color.patcoGold)
            }
            .widgetURL(context.attributes.deepLinkURL)
        }
    }

    private func departureTimeText(_ date: Date) -> String {
        PATCOClock.timeText(date)
    }

    private func shortTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = PATCOClock.calendar.timeZone
        formatter.dateFormat = "h:mm"
        return formatter.string(from: date) + PATCOClock.timeZoneSuffix(date)
    }

    private func arrivalTimeText(_ date: Date) -> String {
        "Arrives \(PATCOClock.timeText(date))"
    }
}

struct PATCOTripLiveActivityView: View {
    let context: ActivityViewContext<PATCOTripActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next PATCO Train")
                        .font(.caption.bold())
                        .foregroundStyle(Color.patcoGold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(context.attributes.routeTitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer()

                Image(systemName: "tram.fill")
                    .font(.title3)
                    .foregroundStyle(Color.patcoGold)
            }

            HStack(alignment: .firstTextBaseline) {
                primaryScheduleBlock

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("Scheduled Arrival")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.58))
                    Text(PATCOClock.timeText(context.state.arrivalDate, relativeTo: context.state.departureDate))
                        .font(.title3.monospacedDigit().weight(.bold))
                        .foregroundStyle(.white)
                }
            }

            if context.isStale && ScheduledTripExpiration.hasExpired(arrivalDate: context.state.arrivalDate) {
                Text("Scheduled trip ended")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                ScheduledDepartureCountdownView(
                    startDate: context.state.lastUpdated,
                    departureDate: context.state.departureDate,
                    isStale: context.isStale
                )
            }
        }
        .padding()
    }

    private var primaryScheduleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Scheduled Departure")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.58))
            Text(PATCOClock.timeText(context.state.departureDate, relativeTo: context.state.arrivalDate))
                .font(.title3.monospacedDigit().weight(.bold))
                .foregroundStyle(.white)
        }
    }

}
