import SwiftUI
import UIKit

/// Route editing is presentation-only; the parent commits route changes.
struct HomeRouteHeader<LocationControl: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let savedRouteStore: SavedRouteStore
    let stations: [Station]
    let originId: Station.ID?
    let destinationId: Station.ID?
    @Binding var isRouteExpanded: Bool
    let routeSummary: String
    let routeDetailSummary: String?
    let currentStationName: String?
    let reverseRoute: () -> Void
    let selectRoute: (_ originId: Station.ID?, _ destinationId: Station.ID?, _ destinationOnly: Bool) -> Void
    @ViewBuilder var locationControl: () -> LocationControl

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy) {
                    isRouteExpanded.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    GeometryReader { geometry in
                        Text(routeSummary)
                            .font(.system(size: routeSummaryFontSize(for: geometry.size.width), weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.95)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 28)

                    if let routeDetailSummary {
                        Text(routeDetailSummary)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.74))
                            .lineLimit(dynamicTypeSize >= .xxLarge ? 2 : 1)
                            .minimumScaleFactor(0.75)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(routeSummary)
            .accessibilityIdentifier("home.route.summary")
            .accessibilityValue(isRouteExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isRouteExpanded ? "Hide route controls" : "Change route")

            HStack(alignment: .center, spacing: 4) {
                if SavedRoutesFeature.isAvailable && savedRouteStore.shortcutsEnabled {
                    SavedRouteShortcuts(store: savedRouteStore, stations: stations,
                                        originId: originId, destinationId: destinationId) { route in
                        selectRoute(route.originId, route.destinationId, false)
                    }
                } else {
                    Spacer(minLength: 0)
                }

                Button {
                    reverseRoute()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.14), in: Circle())
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(originId == nil || destinationId == nil || originId == destinationId)
                .accessibilityLabel("Reverse route")
                .help("Reverse route")

                Button {
                    withAnimation(.snappy) {
                        isRouteExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isRouteExpanded ? "checkmark" : "pencil")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.14), in: Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRouteExpanded ? "Hide route controls" : "Change route")
                .accessibilityIdentifier("home.route.edit")
                .help(isRouteExpanded ? "Done editing route" : "Change route")
            }

            if isRouteExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        stationPicker(title: "From", selection: originId) {
                            selectRoute($0, destinationId, false)
                        }
                        stationPicker(title: "To", selection: destinationId) {
                            selectRoute(originId, $0, true)
                        }
                    }

                    if currentStationName == nil {
                        locationControl()
                    }
                }
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
    }


    private func routeSummaryFontSize(for availableWidth: CGFloat) -> CGFloat {
        let maximumFontSize: CGFloat = 24
        let minimumFontSize: CGFloat = 17
        let font = UIFont.systemFont(ofSize: maximumFontSize, weight: .bold)
        let measuredWidth = (routeSummary as NSString).size(withAttributes: [.font: font]).width

        guard measuredWidth > 0 else { return maximumFontSize }
        let fittedSize = maximumFontSize * max(availableWidth - 2, 1) / measuredWidth
        return max(minimumFontSize, min(maximumFontSize, fittedSize))
    }


    private func stationPicker(title: String, selection: Station.ID?, onSelect: @escaping (Station.ID) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.62))

            Menu {
                ForEach(stations) { station in
                    Button(station.name) {
                        onSelect(station.id)
                    }
                    .accessibilityIdentifier("home.route.\(title == "From" ? "from" : "to").\(station.name)")
                }
            } label: {
                HStack(spacing: 6) {
                    Text(stations.first(where: { $0.id == selection })?.name ?? "Select station")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.58))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(title == "From" ? "home.route.from" : "home.route.to")
        }
    }

}
