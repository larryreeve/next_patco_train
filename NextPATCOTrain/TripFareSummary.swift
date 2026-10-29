import SwiftUI

struct TripFareSummary: View {
    let departure: Departure
    let onOpenStationInformation: (StationInformationDestination) -> Void
    private var fare: PATCOFare { PATCOFare(origin: departure.origin, destination: departure.destination) }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(fare.oneWayText) one way · \(fare.roundTripText) round trip")
                Label("Bikes \(departure.trip.bikesAllowed ? "allowed" : "not allowed")", systemImage: "bicycle")
                Divider().padding(.vertical, 4)
                Text(
                    "Station accessibility and live elevator status aren't available in the app. Check each station's information before traveling."
                )
                .font(.caption)
                .foregroundStyle(Color.patcoCharcoal.opacity(0.7))
                stationAccessibility(departure.origin, role: "Departure")
                stationAccessibility(departure.destination, role: "Destination")
            }
            .font(.subheadline)
            .foregroundStyle(Color.patcoCharcoal)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .padding(.bottom, 8)
        } label: {
            Text("Fares & accessibility")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.patcoCharcoal)
                .frame(minHeight: 44)
        }
        .tint(Color.patcoWine)
        .accessibilityIdentifier("trip.fares")
    }

    private func stationAccessibility(_ station: Station, role: String) -> some View {
        Group {
            if let url = URL(string: station.url),
                ["https", "http"].contains(url.scheme?.lowercased() ?? "")
            {
                Button {
                    onOpenStationInformation(StationInformationDestination(stationName: station.name, url: url))
                } label: {
                    stationInformationRow(station, role: role, canOpen: true)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.patcoWine)
                .accessibilityLabel("Station information for \(role.lowercased()), \(station.name)")
                .accessibilityHint("Opens station information")
            } else {
                stationInformationRow(station, role: role, canOpen: false)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func stationInformationRow(_ station: Station, role: String, canOpen: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(role)
                    .font(.caption)
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.7))
                Text(station.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(canOpen ? Color.patcoWine : Color.patcoCharcoal)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if canOpen {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
