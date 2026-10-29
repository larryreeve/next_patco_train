import CoreLocation
import Combine
import MapKit
import SwiftUI
import UIKit
import WidgetKit

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let savedRouteStore: SavedRouteStore

    let stations: [Station]
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
    @State private var showLiveLocationDiagnostics = false
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
                                Label("Diagnostics", systemImage: "waveform.path.ecg")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(Color.patcoCharcoal)

                                Text("Built: \(buildTimestampText)")
                                    .font(.footnote)
                                    .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)

                                if SavedRoutesFeature.isAvailable {
                                    Toggle("Enable saved routes", isOn: Binding(
                                        get: { savedRouteStore.shortcutsEnabled },
                                        set: { savedRouteStore.setShortcutsEnabled($0) }))
                                        .font(.callout)
                                        .foregroundStyle(Color.patcoCharcoal)
                                        .tint(Color.patcoWine)
                                        .padding(.vertical, 8)
                                }

                                Label("Location Diagnostics", systemImage: "map")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(Color.patcoCharcoal)
                                    .padding(.top, 4)

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
                                .padding(.leading, 24)
                                NavigationLink {
                                    WidgetDiagnosticsView(isArrivalLog: true)
                                } label: {
                                    Label("View arrival activity", systemImage: "location.magnifyingglass")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.patcoWine)
                                }
                                .buttonStyle(.plain)
                                .padding(.leading, 24)
                                Button {
                                    showLiveLocationDiagnostics = true
                                } label: {
                                    Label("View live location map", systemImage: "location.circle")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.patcoWine)
                                }
                                .buttonStyle(.plain)
                                .padding(.leading, 24)
                                .fullScreenCover(isPresented: $showLiveLocationDiagnostics) {
                                    NavigationStack {
                                        LocationDiagnosticsView(stations: stations)
                                    }
                                }
                                ForEach(DiagnosticReportKind.allCases) { kind in
                                    Divider().padding(.vertical, 4)
                                    Label(kind.groupTitle, systemImage: kind.symbol)
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(Color.patcoCharcoal)
                                    NavigationLink {
                                        DiagnosticReportView(kind: kind)
                                    } label: {
                                        Label("View \(kind.rawValue.lowercased())", systemImage: kind.symbol)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Color.patcoWine)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.leading, 24)
                                }
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
        .foregroundStyle(Color.patcoCharcoal)
        .preferredColorScheme(.light)
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

    private var buildTimestampText: String {
        guard let url = Bundle.main.url(forResource: "BuildTimestamp", withExtension: "txt"),
              let value = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return "Unavailable" }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        guard let timestamp = parser.date(from: value) else { return "Unavailable" }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMMdjmmssz")
        return formatter.string(from: timestamp)
    }

    private var versionText: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "Version unavailable"
        }

        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.isEmpty else {
            return "Version \(version)"
        }

        return "Version \(version) (Build \(build))"
    }

    private var scheduleFeedIsExpired: Bool {
        guard let scheduleFeedEndDate else { return true }
        return Date() >= (PATCOClock.calendar.date(byAdding: .day, value: 1, to: scheduleFeedEndDate) ?? scheduleFeedEndDate)
    }

    private var scheduleFeedValidityDateText: String {
        guard let scheduleFeedEndDate else {
            return "Unavailable"
        }
        return scheduleFeedEndDate.formatted(Date.FormatStyle(timeZone: PATCOClock.calendar.timeZone)
            .month(.defaultDigits).day(.defaultDigits).year())
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

@MainActor
private final class DiagnosticLocationMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var status = "Waiting for location"
    @Published private(set) var preciseLocationEnabled = false
    private let manager = CLLocationManager()
    private var active = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func start() {
        active = true
        preciseLocationEnabled = manager.accuracyAuthorization == .fullAccuracy
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            status = "Receiving location updates"
            manager.startUpdatingLocation()
        case .notDetermined:
            status = "Waiting for location permission"
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            status = "Location access is off"
        @unknown default:
            status = "Location access unavailable"
        }
    }

    func stop() {
        active = false
        manager.stopUpdatingLocation()
        status = "Location updates paused"
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self, self.active else { return }
            self.start()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            guard let self, self.active,
                  let latest = locations.filter({ CLLocationCoordinate2DIsValid($0.coordinate) })
                    .max(by: { $0.timestamp < $1.timestamp }) else { return }
            self.location = latest
            self.status = "Receiving location updates"
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = (error as? CLError)?.code == .denied
            ? "Location access is off" : "Location temporarily unavailable"
        Task { @MainActor [weak self] in
            guard let self, self.active else { return }
            self.status = message
        }
    }
}

private struct LocationDiagnosticsView: View {
    let stations: [Station]
    @StateObject private var monitor = DiagnosticLocationMonitor()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var visible = false
    @State private var followLocation = true
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            Map(position: $camera) {
                if let location = monitor.location {
                    if location.horizontalAccuracy >= 0 {
                        MapCircle(center: location.coordinate, radius: location.horizontalAccuracy)
                            .foregroundStyle(.blue.opacity(0.16))
                            .stroke(.blue, lineWidth: 2)
                    }
                    Annotation("Reported location", coordinate: location.coordinate) {
                        Circle()
                            .fill(.blue)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .accessibilityLabel("Reported location")
                    }
                }
            }
            .overlay {
                if monitor.location == nil {
                    Text(monitor.status)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ViewThatFits(in: .vertical) {
                readings.fixedSize(horizontal: false, vertical: true)
                ScrollView { readings }
            }
            .frame(maxHeight: geometry.size.height * 0.55)
            .layoutPriority(1)
            .background(Color(uiColor: .systemBackground))
        }
        }
        .navigationTitle("Location Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Close location diagnostics")
            }
        }
        .onAppear {
            visible = true
            if scenePhase == .active { monitor.start() }
        }
        .onDisappear {
            visible = false
            monitor.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if visible && phase == .active { monitor.start() }
            else { monitor.stop() }
        }
        .onChange(of: monitor.location) { _, location in
            if followLocation, let location { center(on: location) }
        }
        .onChange(of: followLocation) { _, follow in
            if follow, let location = monitor.location { center(on: location) }
        }
    }

    private var readings: some View {
                VStack(alignment: .leading, spacing: 6) {
                    Text(monitor.status).font(.subheadline).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        LabeledContent("Nearest station") {
                            Text(LocationDiagnosticFormatting.nearbyStation(monitor.location, stations: stations, now: context.date))
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    LabeledContent("Precise Location", value: monitor.preciseLocationEnabled ? "Enabled" : "Reduced accuracy")
                    if let location = monitor.location {
                        LabeledContent("Latitude", value: String(format: "%.6f", location.coordinate.latitude))
                        LabeledContent("Longitude", value: String(format: "%.6f", location.coordinate.longitude))
                        LabeledContent("Accuracy radius", value: location.horizontalAccuracy >= 0
                            ? String(format: "%.0f ft", location.horizontalAccuracy / 0.3048) : "Unavailable")
                        LabeledContent("Speed", value: LocationDiagnosticFormatting.speedInMPH(location.speed))
                        LabeledContent("Reading time", value: location.timestamp.formatted(date: .omitted, time: .standard))
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            VStack(spacing: 6) {
                                LabeledContent("Reading quality", value: readingQuality(location, now: context.date))
                                LabeledContent("Reading age", value: "\(max(0, Int(context.date.timeIntervalSince(location.timestamp)))) sec")
                            }
                        }
                    }
                    Toggle("Follow location", isOn: $followLocation)
                }
                .font(.subheadline)
                .monospacedDigit()
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
    }

    private func center(on location: CLLocation) {
        // Inspect the reported dot at street level; uncertainty remains visible in the circle and text.
        let span = 350.0
        camera = .region(MKCoordinateRegion(center: location.coordinate,
                                             latitudinalMeters: span, longitudinalMeters: span))
    }

    private func readingQuality(_ location: CLLocation, now: Date) -> String {
        guard location.horizontalAccuracy > 0 else { return "Unknown" }
        guard (0...120).contains(now.timeIntervalSince(location.timestamp)) else { return "Stale reading" }
        switch location.horizontalAccuracy {
        case ...75: return "High accuracy"
        case ...150: return "Moderate accuracy"
        case ...300: return "Low accuracy"
        default: return "Very low accuracy"
        }
    }
}

private enum DiagnosticReportKind: String, CaseIterable, Identifiable {
    case route = "Route Decisions"
    case refresh = "Refresh Status"
    case schedule = "Schedule Data"
    var id: String { rawValue }
    var groupTitle: String {
        switch self {
        case .route: "Route Diagnostics"
        case .refresh: "Refresh Diagnostics"
        case .schedule: "Schedule Diagnostics"
        }
    }
    var symbol: String {
        switch self {
        case .route: "arrow.left.arrow.right"
        case .refresh: "arrow.clockwise"
        case .schedule: "calendar"
        }
    }
}

private struct DiagnosticReportSection {
    let title: String
    let rows: [(label: String, value: String)]
}

private struct DiagnosticReportView: View {
    let kind: DiagnosticReportKind
    @State private var sections: [DiagnosticReportSection] = []

    private var exportText: String {
        ([kind.rawValue] + sections.map { section in
            section.title + "\n" + section.rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        }).joined(separator: "\n\n")
    }

    var body: some View {
        List {
            ForEach(sections.indices, id: \.self) { index in
                Section(sections[index].title) {
                    ForEach(sections[index].rows.indices, id: \.self) { rowIndex in
                        let row = sections[index].rows[rowIndex]
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.label).font(.subheadline.weight(.semibold))
                            Text(row.value).font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
        .navigationTitle(kind.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ShareLink(item: exportText) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Export \(kind.rawValue.lowercased())")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: reload) { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Reload recorded diagnostics")
            }
        }
        .onAppear(perform: reload)
    }

    private func dateText(_ date: Date?) -> String {
        date?.formatted(.iso8601) ?? "Not recorded"
    }

    private func reload() {
        let now = Date()
        let store = PATCOScheduleStore()
        let events = SharedWidgetDiagnostics.events
        func stationName(_ id: String) -> String { store.station(for: id)?.name ?? id }
        switch kind {
        case .route:
            var report: [DiagnosticReportSection] = []
            if let route = SharedRouteCoordinator.current() {
                report.append(.init(title: "Shared route", rows: [
                    ("Route", "\(stationName(route.originId)) to \(stationName(route.destinationId))"),
                    ("Revision", String(route.revision)), ("Reason", route.reason),
                    ("Selected / changed", dateText(route.updatedAt)),
                    ("Arrival protection", route.blockedArrivalDestinationId.map {
                        "Suppressed at \(stationName($0)) until a reliable fix confirms departure"
                    } ?? "Not suppressed"),
                    ("Last station observation", dateText(route.lastLocationAt))
                ]))
            } else {
                report.append(.init(title: "Shared route", rows: [("Status", "No committed route recorded")]))
            }
            for surface in SharedDiagnosticState.Surface.allCases {
                if let snapshot = SharedDiagnosticState.snapshot(for: surface) {
                    report.append(.init(title: surface.rawValue, rows: [
                        ("Last reported route", snapshot.routeTitle),
                        ("Revision", snapshot.revision.map(String.init) ?? "Changed during preparation / unknown"),
                        ("Recorded", dateText(snapshot.recordedAt))
                    ]))
                } else {
                    report.append(.init(title: surface.rawValue, rows: [("Status", "No snapshot recorded yet")]))
                }
            }
            let decisions = events.filter { $0.title == "Route decision" || $0.title.contains("route reversed") }
            report.append(.init(title: "Recent decisions", rows: decisions.prefix(30).map {
                (dateText($0.date), $0.detail)
            }))
            if let lastArrival = ArrivalDiagnostics.events.first(where: { $0.title.hasPrefix("Arrival ") }) {
                report.append(.init(title: "Last app arrival decision", rows: [(dateText(lastArrival.date), lastArrival.detail)]))
            }
            report.append(.init(title: "Snapshot limits", rows: [("Status", "Widget routes are their last prepared routes, not confirmation of what iOS currently displays. Station names may reveal your journey.")]))
            sections = report
        case .refresh:
            var report: [DiagnosticReportSection] = [.init(title: "Refresh semantics", rows: [
                ("Requested versus completed", "Prepared means the extension built a timeline. Next requested is not a guaranteed execution or display time. Reloading this report does not refresh widgets, request location, or access the network.")
            ])]
            if let trip = SharedTripState.current() {
                report.append(.init(title: "Shared trip state", rows: [
                    ("Route revision", String(trip.routeRevision)),
                    ("Prepared", dateText(trip.preparedAt)),
                    ("Upcoming departures", String(trip.upcoming(at: now).count)),
                    ("Shared estimate", trip.guidance?.estimateSource ?? "No usable guidance"),
                    ("Guidance expires", dateText(trip.guidance?.location.timestamp.addingTimeInterval(180))),
                    ("Last cross-widget reload requested", dateText(trip.lastBroadcastAt))
                ]))
            }
            for surface in [SharedDiagnosticState.Surface.homeScreen, .lockScreen] {
                guard let snapshot = SharedDiagnosticState.snapshot(for: surface) else {
                    report.append(.init(title: surface.rawValue, rows: [("Status", "No completed timeline recorded yet")]))
                    continue
                }
                var rows: [(String, String)] = [
                    ("Last timeline prepared", dateText(snapshot.recordedAt)),
                    ("Next refresh requested", dateText(snapshot.nextRequestedAt)),
                    ("Location reading used", dateText(snapshot.locationTimestamp)),
                    ("Travel estimate source", snapshot.travelEstimateSource ?? "Not recorded")
                ]
                if let timestamp = snapshot.locationTimestamp {
                    rows.append(("Reading age now", "\(max(0, Int(now.timeIntervalSince(timestamp)))) sec"))
                }
                if let accuracy = snapshot.accuracyMeters {
                    rows.append(("Accuracy radius", accuracy > 0 ? String(format: "%.0f ft", accuracy / 0.3048) : "Invalid"))
                }
                report.append(.init(title: surface.rawValue, rows: rows))
            }
            let attempts = events.filter { $0.title.contains("timeline") || $0.title.hasPrefix("Manual location") || $0.title == "App requested widget reload" }
            report.append(.init(title: "Recent requests and attempts", rows: attempts.prefix(20).map {
                ("\(dateText($0.date)) | \($0.title)", $0.detail)
            }))
            sections = report
        case .schedule:
            let metadata = store.feedMetadata
            var report: [DiagnosticReportSection] = [.init(title: "Schedule feed", rows: [
                ("Source", metadata == nil ? "Bundled schedule" : "Downloaded cache"),
                ("Feed version", store.scheduleFeedVersion ?? "Unavailable"),
                ("Valid through", dateText(store.scheduleFeedEndDate)),
                ("Last successful download/check", dateText(store.scheduleFeedLastCheckedAt)),
                ("Last schedule change", dateText(store.scheduleFeedLastUpdatedAt)),
                ("Expired", store.feed.map { $0.isExpired(on: now) ? "Yes" : "No" } ?? "Unknown"),
                ("Feed URL", metadata?.sourceURL.absoluteString ?? "Bundled resource"),
                ("Load error", store.loadError.map { String(describing: $0) } ?? "None")
            ])]
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
            let dates = (-1...1).compactMap { calendar.date(byAdding: .day, value: $0, to: now) }
            let schedules = SharedSpecialScheduleCache.schedules(matching: dates, calendar: calendar)
            for surface in SharedDiagnosticState.Surface.allCases {
                let snapshot = SharedDiagnosticState.snapshot(for: surface)
                report.append(.init(title: "\(surface.rawValue) last reported special schedules", rows: [
                    ("Recorded", dateText(snapshot?.recordedAt)),
                    ("Applied to reported data", snapshot?.appliedSpecialSchedules.map {
                        $0.isEmpty ? "None" : $0.joined(separator: "; ")
                    } ?? "Not recorded")
                ]))
            }
            report.append(.init(title: "Special schedules cached for yesterday / today / tomorrow", rows:
                schedules.isEmpty ? [("Status", "None in the compatible cache")] : schedules.map {
                    ($0.title, "Service date: \(dateText($0.serviceDate)); \($0.trips.count) trips; PDF: \($0.sourceURL.absoluteString)")
                }))
            report.append(.init(title: "Scope", rows: [("Status", "This report reads local data only. A cached special schedule is not necessarily applied to the route or selected date.")]))
            sections = report
        }
    }
}

private struct WidgetDiagnosticsView: View {
    @AppStorage(WidgetReachabilitySettings.enabledKey,
                store: UserDefaults(suiteName: WidgetReachabilitySettings.suiteName))
    private var widgetReachabilityEnabled = true
    var isArrivalLog = false
    private enum ActivityFilter: String, CaseIterable, Identifiable {
        case widget = "Widget"
        case app = "App"
        case all = "All"

        var id: Self { self }
    }

    @State private var events: [SharedWidgetDiagnostics.Event] = []
    @State private var activityFilter: ActivityFilter = .widget

    private var visibleEvents: [SharedWidgetDiagnostics.Event] {
        if isArrivalLog { return events }
        return events.filter { event in
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
                Text(isArrivalLog ? "The latest 500 arrival and location events are stored on this device. No coordinates are recorded. Station names and estimated distances may reveal your route." : "Each widget row is one attempt. Timeline prepared means the extension built new entries, not that iOS displayed them immediately. Next requested is not a guaranteed run time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !isArrivalLog {
                Section {
                    Toggle("Widget reachability", isOn: $widgetReachabilityEnabled)
                        .tint(Color.patcoWine)
                        .onChange(of: widgetReachabilityEnabled) { _, _ in
                            WidgetCenter.shared.reloadAllTimelines()
                        }
                } header: {
                    Text("Widget settings")
                } footer: {
                    Text("Use your location to show which trains you can catch in widgets. May increase battery use.")
                }
              Picker("Activity", selection: $activityFilter) {
                ForEach(ActivityFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            }

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
                        if isArrivalLog { ArrivalDiagnostics.clear() }
                        else { SharedWidgetDiagnostics.clear() }
                        reload()
                    }
                }
            }
        }
        .navigationTitle(isArrivalLog ? "Arrival Diagnostics" : "Widget Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: visibleEvents.map(\.exportLine).joined(separator: "\n")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(isArrivalLog ? "Share arrival diagnostics" : "Share widget diagnostics")
                }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(isArrivalLog ? "Refresh arrival diagnostics" : "Refresh widget diagnostics")
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        events = isArrivalLog ? ArrivalDiagnostics.events : SharedWidgetDiagnostics.events
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
