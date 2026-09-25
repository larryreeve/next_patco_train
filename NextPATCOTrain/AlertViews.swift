import SwiftUI

struct VisibleAlert: Identifiable {
    let id: String
    let title: String
    let url: URL?

    init?(_ alert: PATCOAlertItem) {
        guard let title = alert.displayTitle,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        self.title = title
        self.url = alert.url
        self.id = "\(title.lowercased())|\(alert.url?.absoluteString ?? "")"
    }
}

struct AlertRow: View {
    let alert: VisibleAlert
    var lineLimit: Int? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(Color.patcoGold)
                .padding(.top, 7)

            if let url = alert.url {
                Link(destination: url) {
                    alertTitle
                }
            } else {
                alertTitle
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var alertTitle: some View {
        Text(alert.title)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .lineLimit(lineLimit)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
