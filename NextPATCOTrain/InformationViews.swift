import CoreLocation
import SwiftUI
import UIKit
import WidgetKit

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let locationAuthorizationStatus: CLAuthorizationStatus
    let scheduleFeedEndDate: Date?
    let scheduleFeedVersion: String?
    let scheduleFeedLastCheckedAt: Date?
    let scheduleFeedLastUpdatedAt: Date?
    let scheduleFeedPreviousVersion: String?
    let onRequestLocation: () -> Void
    let onReloadSchedule: (@escaping @MainActor (PATCOGTFSUpdateService.UpdateStage) -> Void) async -> String
    let onOpenURL: (URL) -> Void

    @State private var isReloadingSchedule = false
    @State private var scheduleReloadMessage: String?
    @State private var scheduleReloadStage: PATCOGTFSUpdateService.UpdateStage?
    @State private var showDiagnostics = false
    @State private var showScheduleUpdateHistory = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.patcoCream, Color.white.opacity(0.88)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    informationHeader
                        .padding(.horizontal, 22)
                        .padding(.top, 18)
                        .padding(.bottom, 12)
                        .background(Color.patcoCream.opacity(0.96))

                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "tram.fill")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(Color.patcoCharcoal)
                                .frame(width: 42, height: 42)
                                .background(Color.patcoGold, in: Circle())

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Next PATCO Train")
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(Color.patcoCharcoal)

                                Text("Unofficial PATCO schedule app")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.patcoCharcoal.opacity(0.62))

                                Text(versionText)
                                    .font(.caption2.weight(.medium).monospacedDigit())
                                    .foregroundStyle(Color.patcoCharcoal.opacity(0.50))
                            }
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 5) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showDiagnostics.toggle()
                                }
                            }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Next PATCO Train is an unofficial PATCO schedule app and is not affiliated with or endorsed by PATCO or the Delaware River Port Authority.")
                                .font(.callout)
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.patcoCharcoal.opacity(0.10), lineWidth: 1)
                        )

                        VStack(spacing: 10) {
                            aboutLinkRow(
                                title: "Official PATCO website",
                                subtitle: "Schedules and service information",
                                systemImage: "safari",
                                url: URL(string: "https://www.ridepatco.org/")!
                            )

                            aboutLinkRow(
                                title: "@ridepatco on X",
                                subtitle: "Check recent posts from PATCO",
                                systemImage: "bubble.left.and.text.bubble.right.fill",
                                url: URL(string: "https://x.com/ridepatco")!,
                                opensExternally: true
                            )
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Label("Schedule information", systemImage: "clock.badge.exclamationmark")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.patcoWine)

                            Text("Schedules are published by PATCO and are not real-time. The app checks for newer published schedule data automatically. Refresh Schedule checks the feed now.")
                                .font(.callout)
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)

                            VStack(alignment: .leading, spacing: 8) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("SCHEDULE DETAILS")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(Color.patcoCharcoal.opacity(0.52))

                                    scheduleMetadataHistoryRow(
                                        title: scheduleFeedIsExpired ? "Schedule expired" : "Valid through",
                                        value: scheduleFeedValidityDateText,
                                        systemImage: scheduleFeedIsExpired
                                            ? "calendar.badge.exclamationmark"
                                            : "calendar.badge.checkmark"
                                    )
                                    scheduleMetadataHistoryRow(
                                        title: "Feed version",
                                        value: scheduleFeedVersionText,
                                        systemImage: "number.circle"
                                    )
                                    scheduleMetadataHistoryRow(
                                        title: "Last checked",
                                        value: scheduleFeedCheckText,
                                        systemImage: "clock.arrow.circlepath"
                                    )

                                    DisclosureGroup("Schedule update history", isExpanded: $showScheduleUpdateHistory) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            scheduleMetadataHistoryRow(
                                                title: "Schedule updated",
                                                value: scheduleFeedUpdateText,
                                                systemImage: "arrow.down.circle"
                                            )
                                            if scheduleFeedPreviousVersion != nil {
                                                scheduleMetadataHistoryRow(
                                                    title: "Updated from",
                                                    value: scheduleFeedPreviousVersionValue,
                                                    systemImage: "arrow.backward.circle"
                                                )
                                            }
                                        }
                                        .padding(.top, 8)
                                    }
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.patcoWine)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.patcoCharcoal.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))

                            Button {
                                Task {
                                    isReloadingSchedule = true
                                    scheduleReloadMessage = nil
                                    scheduleReloadStage = .checkingSource
                                    scheduleReloadMessage = await onReloadSchedule { stage in
                                        scheduleReloadStage = stage
                                    }
                                    scheduleReloadStage = nil
                                    isReloadingSchedule = false
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    if isReloadingSchedule {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(Color.patcoCharcoal)
                                        Text(scheduleReloadStage?.rawValue ?? "Refreshing schedule...")
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.72)
                                    } else {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                        Text("Refresh Schedule")
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .padding(.horizontal, 12)
                                .contentShape(Rectangle())
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.patcoCharcoal)
                            .background(Color.patcoGold, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(Color.patcoCharcoal.opacity(0.10), lineWidth: 1)
                            )
                            .buttonStyle(.plain)
                            .opacity(isReloadingSchedule ? 0.88 : 1)
                            .disabled(isReloadingSchedule)

                            if let scheduleReloadMessage {
                                Label(
                                    scheduleReloadMessage,
                                    systemImage: scheduleReloadMessage.hasPrefix("Unable")
                                        ? "exclamationmark.circle.fill"
                                        : "checkmark.circle.fill"
                                )
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(
                                    scheduleReloadMessage.hasPrefix("Unable")
                                        ? Color.patcoWine
                                        : Color.patcoCharcoal.opacity(0.72)
                                )
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.patcoCharcoal.opacity(0.10), lineWidth: 1)
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            Label("Reachability", systemImage: "figure.walk.motion")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.patcoCharcoal)

                            Text("Choose walking or driving to see whether you can reach a departure in time. Leave-by estimates allow about 2 minutes to reach the platform when walking, or 3 minutes to park and reach it when driving. Allow extra time when needed.")
                                .font(.callout)
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)

                            Text("Widgets keep schedules current, but iOS may limit location updates. Open the app for the most accurate estimate.")
                                .font(.callout)
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)

                            if let locationActionTitle {
                                Button(locationActionTitle) {
                                    performLocationAction()
                                }
                                .font(.subheadline.weight(.semibold))
                                .buttonStyle(.bordered)
                                .tint(Color.patcoWine)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.patcoCharcoal.opacity(0.10), lineWidth: 1)
                        )

                        if showDiagnostics {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Widget diagnostics", systemImage: "waveform.path.ecg")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(Color.patcoCharcoal)

                                Text("See when iOS ran the widget, when the app requested an update, and whether location was available. No coordinates are recorded.")
                                    .font(.callout)
                                    .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                                    .fixedSize(horizontal: false, vertical: true)

                                NavigationLink {
                                    WidgetDiagnosticsView()
                                } label: {
                                    Label("View widget activity", systemImage: "list.bullet.rectangle")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.patcoWine)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.patcoCharcoal.opacity(0.10), lineWidth: 1)
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Label("Siri shortcut", systemImage: "sparkles")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.patcoCharcoal)

                            Text("Create a personal shortcut in the Shortcuts app using the Get Next PATCO Trains action, then give it a phrase such as \"What are the next PATCO trains?\"")
                                .font(.callout)
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.patcoCharcoal.opacity(0.10), lineWidth: 1)
                        )

                        VStack(alignment: .leading, spacing: 10) {
                            Label("Privacy", systemImage: "hand.raised.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.patcoCharcoal)

                            Text("Next PATCO Train does not collect personal data or use your location for tracking. With your permission, location helps find stations and estimate travel time; Apple Maps may process travel-time requests.")
                                .font(.callout)
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)

                            NavigationLink {
                                PrivacyPolicyView()
                            } label: {
                                Label("Read privacy policy", systemImage: "doc.text")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.patcoWine)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.patcoCharcoal.opacity(0.10), lineWidth: 1)
                        )

                        VStack(alignment: .leading, spacing: 10) {
                            Label("Open Source Software", systemImage: "shippingbox.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.patcoCharcoal)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("ZIPFoundation 0.9.20")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(Color.patcoCharcoal)

                                Text("Copyright © 2017–2025 Thomas Zoechling")
                                    .font(.footnote)
                                    .foregroundStyle(Color.patcoCharcoal.opacity(0.66))
                            }

                            NavigationLink {
                                OpenSourceLicenseView()
                            } label: {
                                Label("View MIT license", systemImage: "doc.text")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.patcoWine)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.patcoCharcoal.opacity(0.10), lineWidth: 1)
                        )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 6)
                        .padding(.bottom, 28)
                    }
                    .scrollIndicators(.visible)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var informationHeader: some View {
        ZStack {
            Text("Information")
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.patcoCharcoal)
                .frame(maxWidth: .infinity)

            HStack {
                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.patcoCharcoal)
                        .frame(width: 46, height: 46)
                        .background(Color.white.opacity(0.88), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close information")
            }
        }
    }

    private var versionText: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "Version unavailable"
        }

        return "Version \(version)"
    }

    private var scheduleFeedIsExpired: Bool {
        guard let scheduleFeedEndDate else { return true }
        return Date() >= Calendar.current.date(byAdding: .day, value: 1, to: scheduleFeedEndDate) ?? scheduleFeedEndDate
    }

    private var scheduleFeedValidityDateText: String {
        guard let scheduleFeedEndDate else {
            return "Unavailable"
        }
        return scheduleFeedEndDate.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits).year())
    }

    private var scheduleFeedUpdateText: String {
        guard let scheduleFeedLastUpdatedAt else {
            return "Included with the app"
        }
        return scheduleFeedLastUpdatedAt.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits).year().hour().minute())
    }

    private var scheduleFeedCheckText: String {
        guard let scheduleFeedLastCheckedAt else {
            return "Using the schedule included with the app"
        }
        return scheduleFeedLastCheckedAt.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits).year().hour().minute())
    }

    private var scheduleFeedVersionText: String {
        guard let scheduleFeedVersion, !scheduleFeedVersion.isEmpty else {
            return "Included"
        }
        return "v\(scheduleFeedVersion)"
    }

    private var scheduleFeedPreviousVersionValue: String {
        guard let scheduleFeedPreviousVersion, !scheduleFeedPreviousVersion.isEmpty else {
            return "--"
        }
        return "v\(scheduleFeedPreviousVersion)"
    }

    private func scheduleMetadataHistoryRow(title: String, value: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.patcoCharcoal.opacity(0.58))
                .frame(width: 18)

            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.patcoCharcoal.opacity(0.72))

            Spacer(minLength: 8)

            Text(value)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Color.patcoCharcoal.opacity(0.62))
                .multilineTextAlignment(.trailing)
        }
    }

    private var locationActionTitle: String? {
        switch locationAuthorizationStatus {
        case .notDetermined:
            return "Enable Location"
        case .denied, .restricted:
            return "Open Location Settings"
        default:
            return nil
        }
    }

    private func performLocationAction() {
        switch locationAuthorizationStatus {
        case .notDetermined:
            onRequestLocation()
        case .denied, .restricted:
            guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
            openURL(settingsURL)
        default:
            break
        }
    }

    private func aboutLinkRow(
        title: String,
        subtitle: String,
        systemImage: String,
        url: URL,
        opensExternally: Bool = false
    ) -> some View {
        Button {
            if opensExternally {
                openURL(url)
            } else {
                onOpenURL(url)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(Color.patcoCharcoal)
                    .frame(width: 34, height: 34)
                    .background(Color.patcoGold.opacity(0.95), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.bold))

                    Text(subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.patcoCharcoal.opacity(0.58))
                }

                Spacer()

                Image(systemName: opensExternally ? "arrow.up.right.square" : "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.50))
            }
            .foregroundStyle(Color.patcoCharcoal)
            .padding(14)
            .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.patcoGold.opacity(0.34), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

}

private struct WidgetDiagnosticsView: View {
    private enum ActivityFilter: String, CaseIterable, Identifiable {
        case widget = "Widget"
        case app = "App"
        case all = "All"

        var id: Self { self }
    }

    @State private var events: [SharedWidgetDiagnostics.Event] = []
    @State private var activityFilter: ActivityFilter = .widget

    private var visibleEvents: [SharedWidgetDiagnostics.Event] {
        events.filter { event in
            switch activityFilter {
            case .widget: !event.title.hasPrefix("App ")
            case .app: event.title.hasPrefix("App ")
            case .all: true
            }
        }
    }

    var body: some View {
        List {
            Section {
                Text("Each widget row is one attempt. Timeline prepared means the extension built new entries, not that iOS displayed them immediately. Next requested is not a guaranteed run time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Picker("Activity", selection: $activityFilter) {
                ForEach(ActivityFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            Section("Recent activity") {
                if visibleEvents.isEmpty {
                    Text("No \(activityFilter.rawValue.lowercased()) activity recorded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleEvents) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.title)
                                .font(.subheadline.weight(.semibold))
                            Text(event.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(event.date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            if !events.isEmpty {
                Section {
                    Button("Clear diagnostics", role: .destructive) {
                        SharedWidgetDiagnostics.clear()
                        reload()
                    }
                }
            }
        }
        .navigationTitle("Widget Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh widget diagnostics")
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        events = SharedWidgetDiagnostics.events
    }
}

private struct PrivacyPolicyView: View {
    private enum LoadState {
        case loading
        case loaded([Block])
        case failed
    }

    private enum Block: Identifiable {
        case heading(String)
        case paragraph(String)
        case link(URL)

        var id: String {
            switch self {
            case .heading(let text): "heading-\(text)"
            case .paragraph(let text): "paragraph-\(text)"
            case .link(let url): "link-\(url.absoluteString)"
            }
        }
    }

    @State private var loadState: LoadState = .loading

    private let rawPolicyURL = URL(
        string: "https://raw.githubusercontent.com/larryreeve/next_patco_train/main/privacy.md"
    )!
    private let githubPolicyURL = URL(
        string: "https://github.com/larryreeve/next_patco_train/blob/main/privacy.md"
    )!

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading privacy policy...")
                        .font(.callout)
                        .foregroundStyle(Color.patcoCharcoal.opacity(0.66))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .loaded(let blocks):
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(blocks) { block in
                            blockView(block)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 24)
                }

            case .failed:
                ContentUnavailableView {
                    Label("Privacy Policy Unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("The policy could not be loaded from GitHub.")
                } actions: {
                    Button("Try Again") {
                        loadState = .loading
                        Task { await loadPolicy() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.patcoWine)

                    Link("View on GitHub", destination: githubPolicyURL)
                }
            }
        }
        .background(Color.white.ignoresSafeArea())
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task {
            guard case .loading = loadState else { return }
            await loadPolicy()
        }
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let text):
            Text(text)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.patcoCharcoal)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(text)
                .font(.body)
                .foregroundStyle(Color.patcoCharcoal.opacity(0.84))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .link(let url):
            Link(url.absoluteString, destination: url)
                .font(.body)
                .foregroundStyle(Color.patcoWine)
        }
    }

    @MainActor
    private func loadPolicy() async {
        do {
            var request = URLRequest(url: rawPolicyURL)
            request.cachePolicy = .reloadRevalidatingCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let markdown = String(data: data, encoding: .utf8) else {
                loadState = .failed
                return
            }
            loadState = .loaded(Self.parse(markdown))
        } catch {
            loadState = .failed
        }
    }

    private static func parse(_ markdown: String) -> [Block] {
        markdown
            .components(separatedBy: "\n\n")
            .compactMap { rawBlock -> Block? in
                let text = rawBlock.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                if text.hasPrefix("# ") {
                    return .heading(String(text.dropFirst(2)))
                }
                if let url = URL(string: text), url.scheme == "https" {
                    return .link(url)
                }
                return .paragraph(text.replacingOccurrences(of: "\n", with: " "))
            }
    }
}

private struct OpenSourceLicenseView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                Text("Open Source Software included in Next PATCO Train")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Color.patcoCharcoal)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 7) {
                    Text("ZIPFoundation")
                        .font(.headline.weight(.bold))

                    Text("MIT License (MIT)")
                        .font(.body)

                    Link(
                        "github.com/weichsel/ZIPFoundation",
                        destination: URL(string: "https://github.com/weichsel/ZIPFoundation")!
                    )
                    .font(.body)
                    .foregroundStyle(Color.patcoWine)

                    Text("Copyright (c) 2017-2025 Thomas Zoechling")
                        .font(.body)
                        .padding(.top, 8)

                    Text(Self.licenseText)
                        .font(.body)
                        .foregroundStyle(Color.patcoCharcoal.opacity(0.86))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
        }
        .background(Color.white.ignoresSafeArea())
        .navigationTitle("Open Source Software")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let licenseText = """
    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}
