import SwiftUI

struct HomeSpecialScheduleBanner: View {
    let schedule: ActiveSpecialSchedule
    let patcoCalendar: Calendar
    let openSource: (URL) -> Void

    var body: some View {
        Button {
            openSource(schedule.sourceURL)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.patcoGold)

                VStack(alignment: .leading, spacing: 1) {
                    Text(schedule.hasUnconfirmedTimes ? "DST times unconfirmed" : "Special schedule applied")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    if let subtitle = specialScheduleSubtitle(for: schedule) {
                        Text(subtitle)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 3) {
                    Text("View PDF")
                        .font(.caption.weight(.bold))

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                }
            }
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(Color.patcoGold.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.patcoGold.opacity(0.45), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the source PDF in the app")
    }

    private func specialScheduleSubtitle(for schedule: ActiveSpecialSchedule) -> String? {
        if schedule.hasUnconfirmedTimes { return "Ambiguous trips hidden; check PDF" }
        let components = schedule.title.split(separator: "|", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if components.count == 2, !components[1].isEmpty {
            let detail = components[1]
            if detail.count <= 36 {
                return detail
            }
            if let range = detail.range(of: " for ", options: .caseInsensitive),
               range.lowerBound > detail.startIndex {
                let summary = String(detail[..<range.lowerBound])
                if summary.count <= 36 {
                    return summary
                }
            }
        }

        if patcoCalendar.isDateInToday(schedule.serviceDate) {
            return nil
        }
        return "Applies \(schedule.serviceDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))"
    }

}
