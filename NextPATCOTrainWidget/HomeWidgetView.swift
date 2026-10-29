import ActivityKit
import CoreLocation
import MapKit
import SwiftUI
import WidgetKit
import AppIntents

struct NextPATCOTrainWidgetEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily

    let entry: PATCOTrainEntry

    var body: some View {
        VStack(alignment: .leading, spacing: widgetFamily == .systemSmall ? 6 : 8) {
            if widgetFamily == .systemSmall {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 2) {
                        Text("PATCO")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.patcoGold)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        WidgetRouteControls(originId: entry.originId, mode: entry.reachabilityMode, routeRevision: entry.routeRevision, workingAction: entry.workingAction, size: 22)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(entry.routeTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(2)
                        if WidgetReachabilitySettings.isEnabled && entry.locationFreshness == .unavailable {
                            Image(systemName: "location.slash")
                                .foregroundStyle(Color.patcoGold)
                                .accessibilityLabel("Location unavailable")
                        }
                    }
                    .font(.system(size: 10))
                }
            } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next PATCO Train")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.patcoGold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(entry.routeTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    if entry.specialScheduleTitle != nil {
                        Label("Special schedule", systemImage: "calendar.badge.exclamationmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.patcoGold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                }
                .layoutPriority(1)

                Spacer()

                HStack(spacing: 6) {
                    if widgetFamily == .systemSmall && entry.locationFreshness == .unavailable {
                        Image(systemName: "location")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.patcoGold)
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.10), in: Circle())
                            .accessibilityLabel(entry.locationRequestFailed || entry.locationTimestamp == nil ? "Location unavailable. Your arrival time can't be estimated." : "Tap refresh to check which train you can make")
                    }

                    WidgetRouteControls(originId: entry.originId, mode: entry.reachabilityMode, routeRevision: entry.routeRevision, workingAction: entry.workingAction)

                }
                .fixedSize(horizontal: true, vertical: false)
            }
            }

            Group {
                if entry.departures.isEmpty {
                    Spacer()
                    Text(entry.hasUnconfirmedTimes ? "DST times unconfirmed" : entry.routeUpdating ? "Updating route" : entry.scheduleExpired ? "Schedule update needed" : "No upcoming trains")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(
                        entry.hasUnconfirmedTimes ? "Open the app to check the schedule PDF." : entry.routeUpdating ? "Refresh to load departures for your selected route." : entry.scheduleExpired
                            ? "Open Next PATCO Train to download the current schedule."
                            : "Open Next PATCO Train to pick stations."
                    )
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.68))
                } else {
                    departureList
                }
            }

            Spacer(minLength: 0)

            Group {
                if entry.hasUnconfirmedTimes {
                    Text("DST times unconfirmed; check PDF")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.patcoGold)
                        .lineLimit(2)
                } else if widgetFamily != .systemSmall {
                    widgetStatusLine
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color.patcoWine, Color.patcoCharcoal, Color.patcoRail],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .widgetURL(URL(string: "patconext://widget"))
    }

    @ViewBuilder
    private var departureList: some View {
        let departures = displayedDepartures
        VStack(spacing: departureRowSpacing) {
            ForEach(Array(departures.enumerated()), id: \.element.id) { index, departure in
                departureRow(departure, previousDeparture: index > 0 ? departures[index - 1].departureDate : nil)
            }
        }
    }

    private var displayedDepartures: [Departure] {
        guard prioritizesCatchability else {
            return WidgetDepartureSelection.select(entry.departures, limit: displayLimit)
        }
        return WidgetDepartureSelection.prioritized(entry.departures, limit: displayLimit,
            isRecommended: { entry.catchStatuses[$0.id] == .reachable })
    }

    private var prioritizesCatchability: Bool {
        (widgetFamily == .systemSmall || widgetFamily == .systemMedium)
            && hasCurrentCatchability
    }

    private var hasCurrentCatchability: Bool {
        WidgetReachabilitySettings.isEnabled && entry.locationFreshness == .fresh && !entry.isAtStation
            && !(entry.originId != nil && SharedWidgetReachabilityState.pending()?.originId == entry.originId)
    }

    private var recommendedID: UUID? {
        guard hasCurrentCatchability else { return nil }
        return entry.departures.first { entry.catchStatuses[$0.id] == .reachable }?.id
    }

    @ViewBuilder
    private var widgetStatusLine: some View {
        if !WidgetReachabilitySettings.isEnabled {
            EmptyView()
        } else if SharedWidgetReachabilityState.pending()?.originId == entry.originId,
           entry.originId != nil {
            Label("Refresh to update travel estimate", systemImage: "arrow.clockwise")
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(Color.patcoGold.opacity(0.64))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        } else {
            switch entry.locationFreshness {
            case .fresh:
                Text("Updated \(entry.refreshedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.white.opacity(0.44))
            case .recent:
                Label(
                    entry.locationRequestFailed ? "Location unavailable · Your arrival time can't be estimated" : "Tap refresh to check which train you can make",
                    systemImage: "location"
                )
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(Color.patcoGold.opacity(0.64))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            case .unavailable:
                Label(
                    entry.locationRequestFailed || entry.locationTimestamp == nil ? "Location unavailable · Your arrival time can't be estimated" : "Tap refresh to check which train you can make",
                    systemImage: "location"
                )
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(Color.patcoGold.opacity(0.64))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            }
        }
    }

    private var displayLimit: Int {
        switch widgetFamily {
        case .systemSmall:
            3
        case .systemLarge:
            10
        default:
            3
        }
    }

    private var departureRowSpacing: CGFloat {
        switch widgetFamily {
        case .systemLarge:
            5
        case .systemMedium:
            6
        default:
            5
        }
    }

    private func departureRow(_ departure: Departure, previousDeparture: Date?) -> some View {
        let needsRefresh = entry.originId != nil
            && SharedWidgetReachabilityState.pending()?.originId == entry.originId
        let catchStatus = needsRefresh || !WidgetReachabilitySettings.isEnabled ? nil : entry.catchStatuses[departure.id]
        let recommendation = departure.id == recommendedID ? ", Recommended" : ""
        let deadline = departure.id == recommendedID
            ? entry.leaveByDates[departure.id].map { ", Leave by \(PATCOClock.timeText($0))" } ?? "" : ""
        let statusDescription = catchStatus.map { ", \($0.accessibilityDescription)" } ?? ""
        let day = WidgetDepartureDay.label(for: departure.departureDate, relativeTo: entry.date, timeZone: entry.timeZone)
        let visibleDay = WidgetDepartureDay.groupLabel(for: departure.departureDate,
            previousDeparture: previousDeparture, relativeTo: entry.date, timeZone: entry.timeZone)
        let spokenDescription = "Scheduled departure \(day.map { $0 + " " } ?? "")\(departureTimeText(for: departure)), arrives \(arrivalTimeText(for: departure))"
            + recommendation + deadline + statusDescription
        return Group {
            if widgetFamily == .systemSmall {
                HStack(spacing: 3) {
                Text(departureTimeText(for: departure))
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .foregroundStyle(catchStatus?.color ?? .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let day = visibleDay {
                    Text(day)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                }
                    .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
                    .padding(.horizontal, 8)
                    .background((catchStatus?.color ?? .white).opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 6))
            } else {
            HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
            if let day = visibleDay {
                Text(day).font(.system(size: 9)).foregroundStyle(.white.opacity(0.8))
            }
            Text(departureTimeText(for: departure))
                .font(.system(size: 19, weight: .semibold).monospacedDigit())
                .foregroundStyle(catchStatus?.color ?? .white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: displayedDepartures.contains { PATCOClock.needsTimeZone($0.departureDate, relativeTo: $0.arrivalDate) } ? 135 : 100, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text("Arrives at \(arrivalTimeText(for: departure))")
                .font(.system(size: widgetFamily == .systemMedium ? 14 : 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .fixedSize(horizontal: false, vertical: true)
            }
        }
        .overlay(alignment: .leading) {
            if departure.id == recommendedID {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(catchStatus?.color ?? .clear)
                    .frame(width: 3)
                    .padding(.vertical, 3)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenDescription)
    }

    private func departureTimeText(for departure: Departure) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = entry.timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: departure.departureDate)
            + PATCOClock.timeZoneSuffix(departure.departureDate, relativeTo: departure.arrivalDate)
    }

    private func arrivalTimeText(for departure: Departure) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = entry.timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = entry.timeZone

        if calendar.isDate(departure.arrivalDate, inSameDayAs: departure.departureDate) {
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: departure.arrivalDate)
                + PATCOClock.timeZoneSuffix(departure.arrivalDate, relativeTo: departure.departureDate)
        }

        formatter.dateFormat = "EEE h:mm a"
        return formatter.string(from: departure.arrivalDate)
            + PATCOClock.timeZoneSuffix(departure.arrivalDate, relativeTo: departure.departureDate)
    }

}

private struct WidgetRouteControls: View {
    let originId: Station.ID?
    let mode: SharedReachabilityModeStore.Mode?
    let routeRevision: Int?
    let workingAction: WidgetActionProgress.Kind?
    var size: CGFloat = 30

    private var displayedMode: SharedReachabilityModeStore.Mode? {
        mode ?? .driving
    }

    var body: some View {
        HStack(spacing: size < 30 ? 4 : 6) {
            if originId != nil, let routeRevision {
                Toggle(isOn: workingAction == .reverse, intent: ReversePATCOWidgetRouteIntent(expectedRevision: routeRevision)) {
                    Image(systemName: "arrow.left.arrow.right")
                }
                    .toggleStyle(WidgetActionProgressStyle(size: size))
                    .accessibilityLabel("Reverse route")
            }
            if let originId, let mode = displayedMode {
                Toggle(isOn: workingAction == .mode, intent: TogglePATCOReachabilityModeIntent(originId: originId, currentMode: mode)) {
                    Image(systemName: mode == .driving ? "car.fill" : "figure.walk")
                }
                .toggleStyle(WidgetActionProgressStyle(size: size))
                .disabled(!WidgetReachabilitySettings.isEnabled || self.mode == nil)
                .accessibilityLabel(!WidgetReachabilitySettings.isEnabled
                    ? "Travel mode. Widget reachability is off"
                    : self.mode == nil ? "Travel mode unavailable. Refresh location to enable"
                    : mode == .driving ? "Driving estimate. Switch to walking" : "Walking estimate. Switch to driving")
            }
            Toggle(isOn: workingAction == .refresh, intent: RefreshPATCOWidgetIntent()) {
                Image(systemName: "arrow.clockwise")
            }
                .toggleStyle(WidgetActionProgressStyle(size: size))
                .disabled(!WidgetReachabilitySettings.isEnabled)
                .accessibilityLabel("Refresh departures and travel estimates")
        }
        .fixedSize(horizontal: true, vertical: false)
        .disabled(workingAction != nil)
        .accessibilityValue(workingAction == nil ? "" : "Updating")
    }

}

// WidgetKit archives both toggle appearances, allowing immediate tap feedback.
// Only persisted action state disables controls; optimistic state must not latch them.
private struct WidgetActionProgressStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack {
                configuration.label.opacity(configuration.isOn ? 0 : 1)
                Image(systemName: "hourglass").opacity(configuration.isOn ? 1 : 0)
            }
                .font(.caption.weight(.bold))
                .foregroundStyle(isEnabled ? Color.patcoGold : .gray)
                .frame(width: size, height: size)
                .background(.white.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "Updating" : "")
    }
}

struct NextPATCOTrainHomeWidget: Widget {
    let kind = "NextPATCOTrainWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: NextPATCOTrainWidgetProvider()) { entry in
            NextPATCOTrainWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Next PATCO Train")
        .description("See the next PATCO trains from Ashland to 15/16th and Locust.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
