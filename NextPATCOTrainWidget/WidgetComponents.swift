import ActivityKit
import CoreLocation
import MapKit
import SwiftUI
import WidgetKit
import AppIntents

struct ScheduledDepartureCountdownView: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    let startDate: Date
    let departureDate: Date
    let isStale: Bool
    var compact = false

    private var intervalStart: Date {
        min(startDate, departureDate)
    }

    var body: some View {
        if ScheduledDeparturePresentation.hasDeparted(departureDate: departureDate, isStale: isStale) {
            Text("Scheduled departure time has passed")
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.white.opacity(0.64))
        } else {
            countdown
        }
    }

    private var countdown: some View {
        HStack(spacing: 8) {
            Text(isLuminanceReduced ? "Scheduled departure" : "Scheduled departure in")
                .font(compact ? .caption2 : .caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.64))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            countdownText
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var countdownText: some View {
        if isLuminanceReduced {
            // An absolute time cannot mistake elapsed minutes for time remaining in Always-On mode.
            Text(PATCOClock.timeText(departureDate))
                .font((compact ? Font.caption : Font.headline).monospacedDigit().weight(.bold))
                .foregroundStyle(Color.patcoGold)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.leading)
                .frame(width: compact ? 86 : 122, alignment: .leading)
        } else {
            Text(
                timerInterval: intervalStart...departureDate,
                countsDown: true,
                showsHours: true
            )
            .font((compact ? Font.caption : Font.headline).monospacedDigit().weight(.bold))
            .foregroundStyle(Color.patcoGold)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .multilineTextAlignment(.leading)
            .frame(width: compact ? 86 : 122, alignment: .leading)
        }
    }
}

extension Color {
    static let patcoWine = Color(red: 0.42, green: 0.02, blue: 0.11)
    static let patcoCharcoal = Color(red: 0.08, green: 0.10, blue: 0.12)
    static let patcoRail = Color(red: 0.15, green: 0.18, blue: 0.21)
    static let patcoGold = Color(red: 1.0, green: 0.73, blue: 0.22)
    static let patcoPlum = Color(red: 0.48, green: 0.16, blue: 0.38)
}
