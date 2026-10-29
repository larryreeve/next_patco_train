import SwiftUI

struct HomeAlertsView: View {
    let visibleAlerts: [VisibleAlert]
    let isLoading: Bool
    let lastUpdated: Date?
    let refresh: () -> Void
    @State private var isAlertsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("PATCO alerts", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(Color.patcoGold)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isAlertsExpanded.toggle()
                    }
                } label: {
                    Label(
                        isAlertsExpanded ? "Hide" : "View",
                        systemImage: isAlertsExpanded ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption.weight(.bold))
                }
                .buttonStyle(.bordered)
                .tint(Color.patcoGold)
                .accessibilityLabel(isAlertsExpanded ? "Collapse PATCO alerts" : "Expand PATCO alerts")
                .disabled(visibleAlerts.isEmpty)

                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .tint(Color.patcoGold)
                .accessibilityLabel("Refresh PATCO alerts")
            }

            alertContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.patcoAlertBackground.opacity(0.94), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.patcoGold.opacity(0.4), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var alertContent: some View {
        let alerts = visibleAlerts

        if !alerts.isEmpty {
            if isAlertsExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(alerts) { alert in
                        AlertRow(alert: alert)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let lastUpdated = lastUpdated {
                    Text("Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
            } else if let firstAlert = alerts.first {
                AlertRow(alert: firstAlert, lineLimit: 2)

                if alerts.count > 1 {
                    Text("\(alerts.count) active alerts")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
        }
    }

}
