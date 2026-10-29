import SwiftUI

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

            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                let estimate = presentation.destinationEstimate(at: timeline.date)
                VStack(alignment: .leading, spacing: 12) {
                    let timesLayout =
                        dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                    timesLayout {
                        heroTimeItem(
                            title: "Scheduled Departure",
                            value: presentation.departureTimeText,
                            adjustmentText: presentation.adjustedFromText,
                            isDeparted: timeline.date >= departure.departureDate
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
                            "\(estimate.basis) · Updated \(max(0, Int(timeline.date.timeIntervalSince(estimate.observedAt)))) sec ago"
                        )
                        .font(.caption)
                        .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    detailDepartureStatus(at: timeline.date)
                    journeyStatus
                }
            }
        }
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
    }

    private var journeyStatus: some View {
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            let active = presentation.hasTripProgress && presentation.session?.isActive(at: timeline.date) == true
            VStack(alignment: .leading, spacing: 4) {
                if didCompleteTrip || (presentation.hasTripProgress && presentation.session?.completed == true) {
                    Label("Trip completed", systemImage: "checkmark.circle.fill")
                    Text(departure.destination.name).font(.subheadline)
                } else if active && timeline.date >= departure.departureDate {
                    if let next = presentation.nextStop(at: timeline.date) {
                        Text("\(presentation.nextStopLabel): \(next.station.name)")
                            .font(.subheadline)
                        if let arrival = presentation.estimatedArrivalText(
                            for: next, estimate: presentation.destinationEstimate(at: timeline.date), at: timeline.date)
                        {
                            Text(arrival).font(.subheadline)
                        }
                    }
                    if let id = presentation.progress.arrivalAnchorStationId,
                        let station = stops.first(where: { $0.station.id == id }),
                        let at = presentation.progress.arrivalAnchorAt
                    {
                        Text(
                            "\(presentation.detectedStationIds.contains(id) ? "Last detected at" : "Last estimated at") \(station.station.name) · \(observationAge(at, now: timeline.date))"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    } else if timeline.date >= departure.departureDate {
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
        if date < departure.departureDate, let catchStatus = catchStatusAt(date) {
            VStack(alignment: .leading, spacing: 8) {
                if let deadlines = catchStatus.departureDeadlineTimes(for: departure),
                    let summary = catchStatus.stationArrivalSummary(at: departure.origin.name)
                {
                    Label(
                        "Leave by \(deadlines.leaveBy) · \(catchStatus.travelMinutes) min \(summary.mode == .walking ? "walk" : "drive")",
                        systemImage: summary.mode == .walking ? "figure.walk" : "car.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(catchStatus.foregroundColor)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label(catchStatus.title, systemImage: catchStatus.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(catchStatus.foregroundColor)
                }
                DisclosureGroup("Travel details") {
                    expandedTravelDetails(at: date)
                        .padding(.top, 8)
                }
                .font(.caption)
                .tint(Color.patcoCharcoal.opacity(0.65))
            }
        } else if date >= departure.departureDate
            && !(presentation.hasTripProgress && presentation.session?.isActive(at: date) == true)
            && !(presentation.hasTripProgress && presentation.session?.completed == true)
        {
            Label(presentation.departureTimeTitle(at: date), systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func expandedTravelDetails(at date: Date) -> some View {
        if date >= departure.departureDate {
            Label(presentation.departureTimeTitle(at: date), systemImage: "clock")
                .font(.caption)
                .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let catchStatus = catchStatusAt(date) {
            VStack(spacing: 9) {
                Label(catchStatus.title, systemImage: catchStatus.systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(catchStatus.foregroundColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(catchStatus.backgroundColor, in: Capsule())

                if let arrivalSummary = catchStatus.stationArrivalSummary(at: departure.origin.name) {
                    Label(
                        arrivalSummary.title,
                        systemImage: arrivalSummary.mode == .walking ? "figure.walk" : "car.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.68))
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let arrivalSummary = catchStatus.stationArrivalSummary(at: departure.origin.name) {
                    VStack(alignment: .leading, spacing: 5) {
                        reachabilitySectionTitle("If you leave now")

                        HStack(spacing: 14) {
                            deadlineSummary(
                                title: "Leave current location",
                                time: PATCOClock.timeText(date),
                                alignment: .leading
                            )

                            Rectangle()
                                .fill(Color.patcoCharcoal.opacity(0.16))
                                .frame(width: 1, height: 34)

                            deadlineSummary(
                                title: "Arrive at station",
                                time: "about \(arrivalSummary.arrivalTime)",
                                alignment: .trailing
                            )
                        }

                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let deadlines = catchStatus.departureDeadlineTimes(for: departure) {
                    VStack(alignment: .leading, spacing: 6) {
                        Divider()
                            .overlay(Color.patcoCharcoal.opacity(0.12))

                        reachabilitySectionTitle("To make this train")

                        HStack(spacing: 14) {
                            deadlineSummary(
                                title: "Leave current location by",
                                time: deadlines.leaveBy,
                                alignment: .leading
                            )

                            Rectangle()
                                .fill(Color.patcoCharcoal.opacity(0.16))
                                .frame(width: 1, height: 34)

                            deadlineSummary(
                                title: "Arrive at station by",
                                time: "about \(deadlines.stationBy)",
                                alignment: .trailing
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(catchStatus.accessibilityText(at: departure.origin.name, departure: departure))
        }
    }

    private func deadlineSummary(title: String, time: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Color.patcoCharcoal.opacity(0.52))
                .lineLimit(1)

            Text(time)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Color.patcoPlum)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private func reachabilitySectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.patcoCharcoal.opacity(0.52))
    }
}
