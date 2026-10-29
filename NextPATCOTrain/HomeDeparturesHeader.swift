import SwiftUI

struct HomeDeparturesHeader: View {
    let scheduleFeedLastCheckedAt: Date?
    let currentReachabilityMode: StationTravelMode?
    let reachabilityGuidance: (title: String, detail: String?, systemImage: String)?
    let isUsingTemporaryStationRoute: Bool
    let isAtDepartureStation: Bool
    let locationTimestamp: Date?
    let locationFreshness: String?
    let isRefreshInProgress: Bool
    let canOpenDirections: Bool
    let isManualMode: Bool
    let openDirections: () -> Void
    let refresh: () -> Void
    let selectMode: (StationTravelMode) -> Void
    let useAutomaticMode: () -> Void

    var body: some View {
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    departuresHeading

                    Text(scheduleFeedLastCheckedAt.map {
                        "Schedule checked \($0.formatted(date: .abbreviated, time: .shortened))"
                    } ?? "Using bundled schedule")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.patcoCharcoal.opacity(0.52))
                        .lineLimit(1)
                        .padding(.leading, 2)
                }
                Spacer(minLength: 2)
                departureActions
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let currentReachabilityMode,
               let reachabilityGuidance,
               !isUsingTemporaryStationRoute,
               !isAtDepartureStation {
                HStack(alignment: .top, spacing: 8) {
                    travelModePicker(selected: currentReachabilityMode)
                        .fixedSize(horizontal: true, vertical: false)

                    Rectangle()
                        .fill(Color.patcoCharcoal.opacity(0.16))
                        .frame(width: 1, height: 34)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(reachabilityGuidance.title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.patcoCharcoal.opacity(0.74))

                        if let detail = reachabilityGuidance.detail {
                            Text(detail)
                                .font(.caption2.weight(.medium))
                                .lineSpacing(-1)
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.78))
                        }

                        if let locationTimestamp, let locationFreshness,
                           Date().timeIntervalSince(locationTimestamp) > 2 * 60 {
                            Text(locationFreshness)
                                .font(.caption2)
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.52))
                        }
                    }
                    .multilineTextAlignment(.leading)
                    .padding(.top, 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var departuresHeading: some View {
        Text("Scheduled Departures")
            .font(.headline.weight(.semibold))
            .foregroundStyle(Color.patcoCharcoal)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .allowsTightening(true)
    }

    private var departureActions: some View {
        HStack(spacing: 2) {
            Button {
                openDirections()
            } label: {
                departureActionLabel(image: "map.fill", title: "Map")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.patcoCharcoal.opacity(0.58))
            .disabled(!canOpenDirections)
            .accessibilityLabel("Open directions to the departure station")

            Button {
                refresh()
            } label: {
                departureActionLabel(
                    image: isRefreshInProgress ? "hourglass" : "arrow.clockwise",
                    title: "Refresh"
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.patcoCharcoal.opacity(0.58))
            .disabled(isRefreshInProgress)
            .accessibilityLabel("Refresh departures")
        }
    }

    private func departureActionLabel(image: String, title: String) -> some View {
        Image(systemName: image)
            .font(.subheadline.weight(.semibold))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(title)
            .help(title)
    }

    private func travelModePicker(selected: StationTravelMode) -> some View {
        return Group {
            HStack(spacing: 0) {
                travelModeControl(label: "Car", image: "car.fill", mode: .driving, selected: selected)
                travelModeControl(label: "Walk", image: "figure.walk", mode: .walking, selected: selected)
            }
            .background(Color.patcoCharcoal.opacity(0.10), in: Capsule())
        }
    }

    @ViewBuilder
    private func travelModeControl(label: String, image: String, mode: StationTravelMode, selected: StationTravelMode) -> some View {
        let manual = isManualMode
        let controlLabel = Label(label, systemImage: image)
                .font(.caption.weight(.bold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .foregroundStyle(mode == selected ? Color.white : Color.patcoCharcoal.opacity(0.88))
                .background(mode == selected ? Color.patcoWine : .clear, in: Capsule())
        if mode == selected {
            Menu {
                Text(manual ? "Manually selected" : "Automatically selected")
                Button("Use Automatic", systemImage: "arrow.triangle.2.circlepath") {
                    useAutomaticMode()
                }
                Button("Use \(label) manually", systemImage: image) {
                    selectMode(mode)
                }
            } label: {
                controlLabel
            }
            .accessibilityLabel("\(label) travel mode settings")
            .accessibilityValue(manual ? "Manual" : "Automatic")
            .accessibilityAddTraits(.isSelected)
        } else {
            Button {
                selectMode(mode)
            } label: {
                controlLabel
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use \(label.lowercased()) reachability")
        }
    }



}
