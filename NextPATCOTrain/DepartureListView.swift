import SwiftUI

struct DepartureRow: View {
    let departure: Departure
    let catchStatus: TrainCatchStatus?
    let hidesDayLabel: Bool
    let showsCountdown: Bool
    let showsLeaveCountdown: Bool
    let isPrimaryLikelyDeparture: Bool
    let onSelect: () -> Void

    var body: some View {
        Group {
            if departure.isRemovedBySpecialSchedule {
                departureDetails
            } else {
                Button(action: onSelect) {
                    departureDetails
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens scheduled departure details")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            scheduleChangeBackground,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(scheduleChangeBorder)
    }

    private var accessibilityLabel: String {
        let departureTime = PATCOClock.accessibleTimeText(departure.departureDate, relativeTo: departure.arrivalDate)
        let arrivalTime = PATCOClock.accessibleTimeText(departure.arrivalDate, relativeTo: departure.departureDate)
        if departure.isRemovedBySpecialSchedule {
            return "\(departureTime), departure removed by special schedule"
        }

        var label = "Scheduled departure \(departureTime), arrival \(arrivalTime)"
        if isPrimaryLikelyDeparture { label = "Recommended, " + label }
        if let catchStatus { label += ", " + guidanceText(for: catchStatus) }
        if let adjustment = departure.scheduleAdjustment {
            label += ", " + adjustedFromAccessibilityText(adjustment)
        }
        return label
    }

    private var departureDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isPrimaryLikelyDeparture && !departure.isRemovedBySpecialSchedule {
                Text("Recommended")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(red: 0.06, green: 0.34, blue: 0.20))
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    departureTimeLabel.fixedSize()
                    arrivalTimeLabel.fixedSize()
                    Spacer(minLength: 8)
                    countdownAndDisclosure.fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        departureTimeLabel
                        Spacer(minLength: 8)
                        countdownAndDisclosure
                    }
                    arrivalTimeLabel
                }
            }

            if departure.isRemovedBySpecialSchedule {
                Label("Departure removed by special schedule", systemImage: "minus.circle")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.patcoWine)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            } else {
                activeDepartureDetails
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var departureTimeLabel: some View {
        Text(departureTimeText)
            .font(.title3.bold().monospacedDigit())
            .foregroundStyle(departure.isRemovedBySpecialSchedule ? Color.patcoCharcoal.opacity(0.56) : Color.patcoPlum)
            .strikethrough(departure.isRemovedBySpecialSchedule, color: Color.patcoWine)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private var arrivalTimeLabel: some View {
        Text("Arrives \(arrivalTimeText)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.patcoCharcoal.opacity(departure.isRemovedBySpecialSchedule ? 0.50 : 0.68))
            .strikethrough(departure.isRemovedBySpecialSchedule, color: Color.patcoWine)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
    }

    private var countdownAndDisclosure: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if showsCountdown && !departure.isRemovedBySpecialSchedule {
                Text(minutesUntilText)
                    .font(.headline)
                    .foregroundStyle(Color.patcoPlum)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            if !departure.isRemovedBySpecialSchedule {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.42))
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var activeDepartureDetails: some View {
        if !hidesDayLabel, let departureDayText {
            Text(departureDayText)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.patcoCharcoal.opacity(0.68))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.patcoGold.opacity(0.30), in: Capsule())
        }

        if let catchStatus {
            if catchStatus.isLikelyToCatch && !isPrimaryLikelyDeparture {
                Text(guidanceText(for: catchStatus))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
            Label {
                Text(guidanceText(for: catchStatus))
            } icon: {
                Image(systemName: catchStatus.systemImage)
            }
            .font(isPrimaryLikelyDeparture ? .caption.weight(.bold) : .caption2.weight(.bold))
            .foregroundStyle(catchStatus.foregroundColor)
            .labelStyle(.titleAndIcon)
            .lineLimit(2)
            .minimumScaleFactor(0.78)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 7)
            .padding(.vertical, isPrimaryLikelyDeparture ? 6 : showsLeaveCountdown ? 4 : 3)
            .background(catchStatusBackground, in: Capsule())
            .accessibilityLabel(guidanceText(for: catchStatus))
            }
        }

        if let adjustment = departure.scheduleAdjustment {
            Label(adjustedFromText(adjustment), systemImage: adjustment.originalDepartureDate == nil ? "plus.circle" : "calendar")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(scheduleChangeAccent)
                .labelStyle(.titleAndIcon)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)
                .accessibilityLabel(adjustedFromAccessibilityText(adjustment))
        }
    }

    private func guidanceText(for status: TrainCatchStatus) -> String {
        guard showsLeaveCountdown else { return status.title }
        return isPrimaryLikelyDeparture ? status.leaveCountdownText() : status.primaryGuidanceText
    }

    private var catchStatusBackground: Color {
        guard let catchStatus else { return .clear }

        if catchStatus.isLikelyToCatch && !isPrimaryLikelyDeparture {
            return Color(red: 0.72, green: 0.92, blue: 0.78).opacity(0.45)
        }

        return catchStatus.backgroundColor
    }

    private var departureTimeText: String {
        PATCOClock.timeText(departure.departureDate, relativeTo: departure.arrivalDate)
    }

    private var scheduleChangeBackground: Color {
        Color.white.opacity(0.86)
    }

    private var scheduleChangeAccent: Color {
        if departure.isRemovedBySpecialSchedule {
            return Color.patcoWine
        }
        guard let adjustment = departure.scheduleAdjustment else {
            return Color.patcoCharcoal.opacity(0.68)
        }
        return adjustment.originalDepartureDate == nil
            ? Color(red: 0.08, green: 0.32, blue: 0.46)
            : Color.patcoPlum
    }

    @ViewBuilder
    private var scheduleChangeBorder: some View {
        if let adjustment = departure.scheduleAdjustment,
           adjustment.originalDepartureDate == nil {
            scheduleChangeMarker
        } else if departure.isRemovedBySpecialSchedule || departure.scheduleAdjustment != nil {
            scheduleChangeMarker
        } else if isPrimaryLikelyDeparture {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: 0.06, green: 0.34, blue: 0.20).opacity(0.65))
                    .frame(width: 3)
                    .padding(.vertical, 10)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
        }
    }

    private var scheduleChangeMarker: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(scheduleChangeAccent.opacity(0.72))
                .frame(width: 3)
                .padding(.vertical, 10)
            Spacer(minLength: 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var departureDayText: String? {
        let calendar = Self.patcoCalendar
        let now = Date()
        if calendar.isDate(departure.departureDate, inSameDayAs: now) {
            return nil
        }

        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           calendar.isDate(departure.departureDate, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: departure.departureDate)
    }

    private static var patcoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }

    private func adjustedFromText(_ adjustment: ScheduleAdjustment) -> String {
        guard let originalDepartureDate = adjustment.originalDepartureDate else {
            return "Departure added by special schedule"
        }

        return "Adjusted from \(PATCOClock.timeText(originalDepartureDate))"
    }

    private func adjustedFromAccessibilityText(_ adjustment: ScheduleAdjustment) -> String {
        guard let originalDepartureDate = adjustment.originalDepartureDate else {
            return "Departure added by special schedule"
        }

        return "Adjusted from standard departure time \(PATCOClock.timeText(originalDepartureDate))"
    }

    private var arrivalTimeText: String {
        PATCOClock.timeText(departure.arrivalDate, relativeTo: departure.departureDate)
    }

    private var minutesUntilText: String {
        let minutes = Int(ceil(departure.departureDate.timeIntervalSinceNow / 60))
        if minutes <= 0 {
            return "Now"
        }
        if minutes >= 60 {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            if remainingMinutes == 0 {
                return "in \(hours)h"
            }
            return "in \(hours)h \(remainingMinutes)m"
        }
        return "in \(minutes)m"
    }
}
