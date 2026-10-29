import SwiftUI

struct TripStopTimeline: View {
    let presentation: TripDetailPresentation
    let onOpenStationInformation: (StationInformationDestination) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(alignment: .leading, spacing: 12) {
                Text(presentation.stopCountTitle(at: timeline.date))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.patcoCharcoal)

                let estimate = presentation.destinationEstimate(at: timeline.date)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(presentation.scheduledStops.enumerated()), id: \.element.id) { index, stop in
                        StopTimelineRow(
                            stop: stop,
                            timeText: presentation.timeText(
                                for: stop, isFinalStop: index == presentation.scheduledStops.count - 1),
                            estimatedArrivalText: presentation.completedStationIds.contains(stop.station.id)
                                ? nil
                                : presentation.estimatedArrivalText(for: stop, estimate: estimate, at: timeline.date),
                            isLast: index == presentation.scheduledStops.count - 1,
                            isDestination: index == presentation.scheduledStops.count - 1,
                            isDetected: presentation.detectedStationIds.contains(stop.station.id),
                            isInferred: presentation.completedStationIds.contains(stop.station.id)
                                && !presentation.detectedStationIds.contains(stop.station.id),
                            onOpenStationInformation: { url in
                                onOpenStationInformation(
                                    StationInformationDestination(
                                        stationName: stop.station.name,
                                        url: url
                                    ))
                            }
                        )
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 18)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct StopTimelineRow: View {
    let stop: TripDetailStop
    let timeText: String
    let estimatedArrivalText: String?
    let isLast: Bool
    let isDestination: Bool
    let isDetected: Bool
    let isInferred: Bool
    let onOpenStationInformation: (URL) -> Void

    var body: some View {
        Group {
            if let stationURL {
                Button {
                    onOpenStationInformation(stationURL)
                } label: {
                    rowContent
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens station information")
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Circle()
                    .fill(isDetected ? Color.patcoWine : isInferred ? Color.patcoWine.opacity(0.25) : Color.white)
                    .overlay(
                        Circle().strokeBorder(
                            Color.patcoWine,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: isInferred ? [1, 3] : []))
                    )
                    .overlay {
                        if isDetected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 22, height: 22)
                    .accessibilityLabel(
                        isDetected
                            ? "Station detected"
                            : isInferred ? "Station passed, inferred from route position" : "Station not yet detected")

            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stop.station.name)
                        .font(.title3.weight(isDestination ? .bold : .semibold))
                        .foregroundStyle(Color.patcoCharcoal.opacity(isDetected || isInferred ? 0.65 : 1))
                        .fixedSize(horizontal: false, vertical: true)

                    if isDetected || isInferred {
                        Text(isDetected ? "Passed" : "Passed · estimated")
                            .font(.caption2)
                            .foregroundStyle(Color.patcoCharcoal.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let estimatedArrivalText {
                        Text(estimatedArrivalText)
                            .font(.caption)
                            .foregroundStyle(Color.patcoWine)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("\(isDestination ? "Scheduled arrival" : "Scheduled departure") \(timeText)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.patcoCharcoal.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)

                    if isDestination {
                        Text("Destination")
                            .font(.caption2.weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(Color.patcoWine)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.patcoGold.opacity(0.28), in: Capsule())
                    }
                }

                Spacer(minLength: 8)

                if stationURL != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.patcoCharcoal.opacity(0.5))
                        .accessibilityHidden(true)
                }
            }
            .padding(.bottom, isLast ? 0 : 22)
            .overlay(alignment: .bottom) {
                if !isLast {
                    Divider()
                        .padding(.leading, 4)
                }
            }
        }
        .background(alignment: .topLeading) {
            if !isLast {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.patcoWine)
                        .frame(width: 3, height: max(0, geometry.size.height - 22))
                        .offset(x: 9.5, y: 22)
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, isDestination ? 10 : 0)
        .background(
            isDestination ? Color.patcoGold.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var stationURL: URL? {
        guard let url = URL(string: stop.station.url),
            let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http"
        else {
            return nil
        }
        return url
    }
}
