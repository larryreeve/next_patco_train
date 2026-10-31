import SwiftUI

/// Timer ticks trigger redraws; current time evaluates data arriving between ticks.
struct LiveTimeline<Content: View>: View {
    let interval: TimeInterval
    var now: () -> Date = Date.init
    @ViewBuilder var content: (Date) -> Content

    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { _ in
            content(now())
        }
    }
}

struct TripJourneySummary: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let presentation: TripDetailPresentation
    let didCompleteTrip: Bool
    let catchStatusAt: (Date) -> TrainCatchStatus?
    private var departure: Departure { presentation.departure }
    private var stops: [TripDetailStop] { presentation.stops }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(presentation.stationPairText)
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.patcoCharcoal)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            tripDirectionSummary

            Divider()

            LiveTimeline(interval: 30) { now in
                let estimate = presentation.destinationEstimate(at: now)
                VStack(alignment: .leading, spacing: 12) {
                    if let day = presentation.departureDayText(at: now) {
                        Text(day)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    let timesLayout =
                        dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                    timesLayout {
                        heroTimeItem(
                            title: "Scheduled Departure",
                            value: presentation.departureTimeText,
                            adjustmentText: presentation.adjustedFromText,
                            isDeparted: now >= departure.departureDate
                        )

                        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 12) }

                        heroTimeItem(
                            title: estimate == nil ? "Scheduled Arrival" : "Estimated Arrival",
                            value: estimate.map { PATCOClock.timeText($0.date, relativeTo: departure.departureDate) }
                                ?? presentation.arrivalTimeText,
                            scheduledText: estimate == nil ? nil : "Scheduled arrival: \(presentation.arrivalTimeText)",
                            adjustmentText: estimate?.delayText(scheduled: departure.arrivalDate),
                            isDeparted: false,
                            alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing
                        )
                    }

                    if let estimate {
                        Text(
                            "\(estimate.basis) · Updated \(max(0, Int(now.timeIntervalSince(estimate.observedAt)))) sec ago"
                        )
                        .font(.caption)
                        .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    detailDepartureStatus(at: now)
                    journeyStatus
                }
            }
        }
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
    }

    private var journeyStatus: some View {
        LiveTimeline(interval: 5) { now in
            let active = presentation.hasTripProgress && presentation.session?.isActive(at: now) == true
            VStack(alignment: .leading, spacing: 4) {
                if didCompleteTrip || (presentation.hasTripProgress && presentation.session?.completed == true) {
                    Label("Trip completed", systemImage: "checkmark.circle.fill")
                    Text(departure.destination.name).font(.subheadline)
                } else if active && now >= departure.departureDate {
                    if let next = presentation.nextStop(at: now) {
                        Text("\(presentation.nextStopLabel): \(next.station.name)")
                            .font(.subheadline)
                        if let arrival = presentation.estimatedArrivalText(
                            for: next, estimate: presentation.destinationEstimate(at: now), at: now)
                        {
                            Text(arrival).font(.subheadline)
                        }
                    }
                    if let id = presentation.progress.arrivalAnchorStationId,
                        let station = stops.first(where: { $0.station.id == id }),
                        let at = presentation.progress.arrivalAnchorAt
                    {
                        Text(
                            "\(presentation.detectedStationIds.contains(id) ? "Last detected at" : "Last estimated at") \(station.station.name) · \(observationAge(at, now: now))"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    } else if now >= departure.departureDate {
                        Text("Waiting for station progress").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private func observationAge(_ observedAt: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(observedAt)))
        return seconds < 60 ? "\(seconds) sec ago" : "\(seconds / 60) min ago"
    }

    private var tripDirectionSummary: some View {
        Text("\(departure.directionLabel) · \(presentation.rideTimeText)")
            .font(.subheadline)
            .foregroundStyle(Color.patcoCharcoal.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func heroTimeItem(
        title: String,
        value: String,
        scheduledText: String? = nil,
        adjustmentText: String? = nil,
        isDeparted: Bool = false,
        alignment: Alignment = .leading
    ) -> some View {
        VStack(alignment: alignment == .trailing ? .trailing : .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.patcoCharcoal.opacity(0.52))

            Text(value)
                .font(isDeparted ? .headline : .title.weight(.bold))
                .foregroundStyle(isDeparted ? Color.patcoCharcoal.opacity(0.72) : Color.patcoWine)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            if let scheduledText {
                Text(scheduledText)
                    .font(.caption)
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                    .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let adjustmentText {
                Label(adjustmentText, systemImage: adjustmentText == "On time" ? "checkmark.circle" : "clock")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(adjustmentText == "On time" ? Color.patcoCharcoal.opacity(0.72) : Color.patcoWine)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    @ViewBuilder
    private func detailDepartureStatus(at date: Date) -> some View {
        if date < departure.departureDate {
            let catchStatus = catchStatusAt(date)
            travelDetails(catchStatus: catchStatus)
        }
    }

    @ViewBuilder
    private func travelDetails(catchStatus: TrainCatchStatus?) -> some View {
        if let catchStatus {
            VStack(alignment: .leading, spacing: 12) {
                if let deadlines = catchStatus.departureDeadlineTimes(for: departure) {
                    Text("Leave by \(deadlines.leaveBy)")
                        .font(.headline)
                        .foregroundStyle(Color.patcoWine)
                } else {
                    Label(catchStatus.title, systemImage: catchStatus.systemImage)
                        .font(.headline)
                        .foregroundStyle(catchStatus.foregroundColor)
                }

                if let arrivalSummary = catchStatus.stationArrivalSummary(at: departure.origin.name) {
                    Label(
                        "\(catchStatus.travelMinutes)-minute \(arrivalSummary.mode == .walking ? "walk" : "drive") to \(departure.origin.name)",
                        systemImage: arrivalSummary.mode == .walking ? "figure.walk" : "car.fill"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let deadlines = catchStatus.departureDeadlineTimes(for: departure) {
                    (Text("Be at the station by ") + Text(deadlines.stationBy).bold())
                        .font(.subheadline)
                }
            }
            .foregroundStyle(Color.patcoCharcoal)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            Label("Travel estimate unavailable", systemImage: "location.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}
