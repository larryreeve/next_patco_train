import SwiftUI

struct HomeScheduleDatePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedScheduleDate: Date
    @Binding var draftScheduleDate: Date
    let patcoCalendar: Calendar
    let lastSelectableScheduleDate: Date

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                DatePicker(
                    "Departure date",
                    selection: $draftScheduleDate,
                    in: patcoCalendar.startOfDay(for: Date())...lastSelectableScheduleDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .accessibilityLabel("Departure date")
                .environment(\.timeZone, patcoCalendar.timeZone)

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    Button("Today") {
                        selectedScheduleDate = Date()
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Button("Show departures") {
                        selectedScheduleDate = draftScheduleDate
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(16)
            .background(Color.patcoCream.ignoresSafeArea())
            .navigationTitle("Departure date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close date picker")
                }
            }
        }
        .tint(Color.patcoWine)
        .environment(\.colorScheme, .light)
        .presentationDetents([.height(520), .large])
    }

}
