import SwiftUI

struct HomeStationPanel: View {
    let station: Station
    let isEstimated: Bool
    let isUsingTemporaryStationRoute: Bool
    let originId: Station.ID?
    let destinationId: Station.ID?
    let originStation: Station?
    let savedStartingStationName: String
    let refresh: () -> Void
    let restoreSavedRoute: () -> Void
    let showStationDepartures: (Station.ID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.patcoGold)
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.18), in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(isEstimated ? "Estimated station departures" : (isUsingTemporaryStationRoute ? "Station departures" : "Current station"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.58))

                    Text(station.name)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button {
                    refresh()
                } label: {
                    Image(systemName: "location.fill")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.72))
                .accessibilityLabel("Refresh current station")
            }

            if isUsingTemporaryStationRoute {
                Button {
                    restoreSavedRoute()
                } label: {
                    Label("Return to \(savedStartingStationName) departures", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.14), in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Restores departures from your saved starting station")
            } else if station.id != originId && station.id != destinationId {
                Button {
                    showStationDepartures(nil)
                } label: {
                    Label("Show departures from \(station.name)", systemImage: "tram.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.14), in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Temporarily uses this station without changing your saved route")
            } else if station.id == destinationId, let originId, let originStation {
                Button {
                    showStationDepartures(originId)
                } label: {
                    Label("Show departures to \(originStation.name)", systemImage: "arrow.left.arrow.right")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.14), in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Temporarily shows return-direction departures without changing your saved route")
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
    }

}
