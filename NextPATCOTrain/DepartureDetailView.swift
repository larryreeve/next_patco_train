import ActivityKit
import MapKit
import SafariServices
import SwiftUI
import UIKit
import WebKit

struct TripDetailStop: Identifiable {
    let station: Station
    let stopTime: StopTime

    var id: String {
        "\(station.id)-\(stopTime.sequence)"
    }
}

struct BrowserURL: Identifiable {
    let url: URL

    var id: String {
        url.absoluteString
    }
}

private struct StationInformationDestination: Identifiable {
    let stationName: String
    let url: URL

    var id: String {
        "\(stationName)|\(url.absoluteString)"
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let viewController = SFSafariViewController(url: url)
        viewController.dismissButtonStyle = .close
        viewController.isModalInPresentation = true
        return viewController
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

private enum StationInformationLoadState: Equatable {
    case loading
    case loaded
    case failed
}

private struct StationInformationWebView: UIViewRepresentable {
    let url: URL
    @Binding var loadState: StationInformationLoadState

    func makeCoordinator() -> Coordinator {
        Coordinator(loadState: $loadState)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        loadState = .loading
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding private var loadState: StationInformationLoadState

        init(loadState: Binding<StationInformationLoadState>) {
            _loadState = loadState
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            loadState = .loading
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            loadState = .loaded
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            loadState = .failed
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
            loadState = .failed
        }
    }
}

private struct StationInformationBrowser: View {
    @Environment(\.openURL) private var openURL

    let url: URL

    @State private var loadState: StationInformationLoadState = .loading
    @State private var reloadID = UUID()

    var body: some View {
        ZStack {
            StationInformationWebView(url: url, loadState: $loadState)
                .id(reloadID)

            if loadState == .loading {
                ProgressView("Loading station information...")
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            } else if loadState == .failed {
                ContentUnavailableView {
                    Label("Unable to Load Station Information", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Check your connection, then try again.")
                } actions: {
                    Button("Try Again") {
                        loadState = .loading
                        reloadID = UUID()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.patcoWine)

                    Button("Open in Safari") {
                        openURL(url)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .background(Color.white)
            }
        }
        .background(Color.white)
    }
}

private struct StationInformationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let destination: StationInformationDestination

    var body: some View {
        NavigationStack {
            StationInformationBrowser(url: destination.url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("\(destination.stationName) Station")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            openURL(destination.url)
                        } label: {
                            Image(systemName: "safari")
                        }
                        .accessibilityLabel("Open in Safari")

                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close station information")
                    }
                }
        }
        .interactiveDismissDisabled()
        .presentationDragIndicator(.hidden)
    }
}

enum PATCOLiveActivityStarter {
    static let activityDidChangeNotification = Notification.Name("PATCOLiveActivityDidChange")

    @MainActor
    static func isShowing(departure: Departure) -> Bool {
        matchingActivity(for: departure) != nil
    }

    @MainActor
    static func stop(departure: Departure) async -> String {
        guard let activity = matchingActivity(for: departure) else {
            return "Not currently showing on Lock Screen."
        }

        await activity.end(nil, dismissalPolicy: .immediate)
        NotificationCenter.default.post(name: activityDidChangeNotification, object: nil)
        return "Removed from Lock Screen."
    }

    @MainActor
    static func start(departure: Departure, stops: [TripDetailStop]) async -> String {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return "Live Activities are disabled in Settings."
        }

        let scheduledStops = Array(stops.dropFirst())
        let attributes = PATCOTripActivityAttributes(
            routeTitle: "\(departure.origin.name) to \(departure.destination.name)",
            originName: departure.origin.name,
            destinationName: departure.destination.name,
            deepLinkURLString: deepLinkURL(for: departure).absoluteString
        )
        let activityStops = scheduledStops.map {
            PATCOTripActivityAttributes.Stop(
                name: $0.station.name,
                arrivalDate: stopDate(for: $0.stopTime, serviceDate: departure.serviceDate)
            )
        }
        let state = contentState(departure: departure, stops: activityStops)
        let content = ActivityContent(
            state: state,
            staleDate: departure.departureDate
        )

        do {
            for activity in Activity<PATCOTripActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }

            _ = try Activity<PATCOTripActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            NotificationCenter.default.post(name: activityDidChangeNotification, object: nil)
            return "Showing on Lock Screen."
        } catch {
            return "Could not start Live Activity."
        }
    }

    @MainActor
    static func endExpiredActivities(now: Date = Date()) async {
        for activity in Activity<PATCOTripActivityAttributes>.activities {
            let dismissalDate = activity.content.state.arrivalDate.addingTimeInterval(10 * 60)
            if now >= dismissalDate {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    @MainActor
    static func endActivities(arrivingAt stationName: String) async {
        for activity in Activity<PATCOTripActivityAttributes>.activities
        where activity.attributes.destinationName == stationName {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        NotificationCenter.default.post(name: activityDidChangeNotification, object: nil)
    }

    private static func matchingActivity(for departure: Departure) -> Activity<PATCOTripActivityAttributes>? {
        let deepLinkURLString = deepLinkURL(for: departure).absoluteString
        return Activity<PATCOTripActivityAttributes>.activities.first {
            $0.attributes.deepLinkURLString == deepLinkURLString
        }
    }

    private static func contentState(
        departure: Departure,
        stops: [PATCOTripActivityAttributes.Stop]
    ) -> PATCOTripActivityAttributes.ContentState {
        PATCOTripActivityAttributes.ContentState(
            departureDate: departure.departureDate,
            arrivalDate: departure.arrivalDate,
            stops: stops,
            statusTitle: nil,
            statusDetail: nil,
            lastUpdated: Date()
        )
    }

    private static func deepLinkURL(for departure: Departure) -> URL {
        var components = URLComponents()
        components.scheme = "patconext"
        components.host = "departure"
        components.queryItems = [
            URLQueryItem(name: "origin", value: departure.origin.id),
            URLQueryItem(name: "destination", value: departure.destination.id),
            URLQueryItem(name: "departure", value: String(departure.departureDate.timeIntervalSince1970))
        ]
        return components.url ?? URL(string: "patconext://departure")!
    }

    private static func stopDate(for stopTime: StopTime, serviceDate: Date) -> Date {
        let components = stopTime.arrival.split(separator: ":").compactMap { Int($0) }
        guard components.count == 3 else {
            return serviceDate
        }

        let seconds = components[0] * 3600 + components[1] * 60 + components[2]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar.date(byAdding: .second, value: seconds, to: serviceDate) ?? serviceDate
    }
}

struct TripDetailView: View {
    let departure: Departure
    let stops: [TripDetailStop]
    let catchStatus: TrainCatchStatus?
    let onClose: () -> Void

    @State private var cameraPosition: MapCameraPosition
    @State private var liveActivityMessage: String?
    @State private var isLiveActivityShowing = false
    @State private var liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    @State private var selectedStationInformation: StationInformationDestination?

    init(departure: Departure, stops: [TripDetailStop], catchStatus: TrainCatchStatus?, onClose: @escaping () -> Void) {
        self.departure = departure
        self.stops = stops
        self.catchStatus = catchStatus
        self.onClose = onClose
        _cameraPosition = State(initialValue: .region(Self.region(for: stops.map(\.station.coordinate))))
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 12)
                .background(Color(red: 0.94, green: 0.94, blue: 0.96))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    tripHero
                    liveActivityControls
                    tripSummary
                    routeMap
                    stopTimeline
                }
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .padding(.bottom, 30)
            }
        }
        .background(Color(red: 0.94, green: 0.94, blue: 0.96))
        .sheet(item: $selectedStationInformation) { destination in
            StationInformationSheet(destination: destination)
        }
        .task {
            refreshLiveActivityState()
        }
        .onReceive(NotificationCenter.default.publisher(for: PATCOLiveActivityStarter.activityDidChangeNotification)) { _ in
            refreshLiveActivityState()
        }
    }

    private var sheetHeader: some View {
        ZStack {
            Text("Departure Details")
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.patcoCharcoal)
                .frame(maxWidth: .infinity)

            HStack {
                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.patcoCharcoal)
                        .frame(width: 46, height: 46)
                        .background(Color.white.opacity(0.88), in: Circle())
                }
                .accessibilityLabel("Close trip details")
            }
        }
    }

    private var tripSummary: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 30) {
            summaryItem(title: "One way", value: fare.oneWayText)
            summaryItem(title: "Round trip", value: fare.roundTripText, alignment: .trailing)
            iconSummaryItem(value: bikesAllowedText, systemImage: "bicycle")
            iconSummaryItem(value: wheelchairAccessibleText, systemImage: "figure.roll", alignment: .trailing)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
    }

    private var tripHero: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(stationPairText)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.patcoCharcoal)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .frame(maxWidth: .infinity, alignment: .leading)

            tripDirectionSummary

            Divider()

            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 16) {
                        heroTimeItem(
                            title: departureTimeTitle(at: timeline.date),
                            value: departureTimeText,
                            adjustmentText: adjustedFromText,
                            isDeparted: timeline.date >= departure.departureDate
                        )

                        Spacer(minLength: 12)

                        heroTimeItem(
                            title: "Scheduled Arrival",
                            value: arrivalTimeText,
                            isDeparted: timeline.date >= departure.departureDate,
                            alignment: .trailing
                        )
                    }

                    detailDepartureStatus(at: timeline.date)
                }
            }
        }
        .padding(22)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
    }

    private var liveActivityControls: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            if isLiveActivityShowing || (timeline.date < departure.departureDate && canShowLiveActivity) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Spacer(minLength: 0)

                        Button {
                            Task {
                                await toggleLiveActivity()
                            }
                        } label: {
                            Label(
                                isLiveActivityShowing ? "Remove from Lock Screen" : "Show on Lock Screen",
                                systemImage: isLiveActivityShowing ? "xmark.circle.fill" : "platter.filled.top.and.arrow.up.iphone"
                            )
                                .font(.headline.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(isLiveActivityShowing ? Color.patcoCharcoal.opacity(0.78) : Color.patcoWine)
                        .disabled(!isLiveActivityShowing && !liveActivitiesEnabled)

                        Spacer(minLength: 0)
                    }

                    if let liveActivityStatusMessage {
                        Text(liveActivityStatusMessage)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.patcoCharcoal.opacity(0.66))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
    }

    private var tripDirectionSummary: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Direction")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.52))

                Text(departure.fullDirectionLabel)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.patcoCharcoal)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Text("Ride time")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.52))

                Text(rideTimeText)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.patcoCharcoal)
            }
        }
    }

    private func summaryItem(title: String, value: String, alignment: Alignment = .leading, valueFont: Font = .headline.weight(.bold)) -> some View {
        VStack(alignment: alignment == .trailing ? .trailing : .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.patcoCharcoal.opacity(0.56))

            Text(value)
                .font(valueFont)
                .foregroundStyle(Color.patcoCharcoal)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func iconSummaryItem(value: String, systemImage: String, alignment: Alignment = .leading) -> some View {
        Label(value, systemImage: systemImage)
            .font(.headline.weight(.bold))
            .foregroundStyle(Color.patcoCharcoal)
            .labelStyle(.titleAndIcon)
            .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            .lineLimit(2)
            .minimumScaleFactor(0.78)
            .padding(.top, 3)
            .frame(maxWidth: .infinity, alignment: alignment)
            .accessibilityLabel(value)
    }

    private func heroTimeItem(
        title: String,
        value: String,
        adjustmentText: String? = nil,
        isDeparted: Bool = false,
        alignment: Alignment = .leading
    ) -> some View {
        VStack(alignment: alignment == .trailing ? .trailing : .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.patcoCharcoal.opacity(0.52))

            Text(value)
                .font(.title.weight(.bold))
                .foregroundStyle(Color.patcoWine.opacity(isDeparted ? 0.58 : 1))
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            if let adjustmentText {
                Label(adjustmentText, systemImage: "calendar.badge.exclamationmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.patcoWine)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private var routeMap: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Route map")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.patcoCharcoal)

            Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                if routeCoordinates.count > 1 {
                    MapPolyline(coordinates: routeCoordinates)
                        .stroke(Color.patcoWine, lineWidth: 4)
                }

                ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                    Annotation(stop.station.name, coordinate: stop.station.coordinate) {
                        if index == 0 {
                            Image(systemName: "tram.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.patcoCharcoal)
                                .frame(width: 28, height: 28)
                                .background(Color.patcoGold, in: Circle())
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        } else if index == stops.count - 1 {
                            Image(systemName: "flag.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.patcoWine, in: Circle())
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        } else {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(Color.patcoWine, lineWidth: 3))
                        }
                    }
                }
            }
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var stopTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(stopCountTitle)
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.patcoCharcoal)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(scheduledStops.enumerated()), id: \.element.id) { index, stop in
                    StopTimelineRow(
                        stop: stop,
                        timeText: timeText(for: stop, isFinalStop: index == scheduledStops.count - 1),
                        isLast: index == scheduledStops.count - 1,
                        isDestination: index == scheduledStops.count - 1,
                        onOpenStationInformation: { url in
                            selectedStationInformation = StationInformationDestination(
                                stationName: stop.station.name,
                                url: url
                            )
                        }
                    )
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 18)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var routeCoordinates: [CLLocationCoordinate2D] {
        stops.map(\.station.coordinate)
    }

    private var scheduledStops: [TripDetailStop] {
        Array(stops.dropFirst())
    }

    private var stopCountTitle: String {
        scheduledStops.count == 1 ? "1 stop" : "\(scheduledStops.count) stops"
    }

    private var departureTimeText: String {
        departure.departureDate.formatted(date: .omitted, time: .shortened)
    }

    private var arrivalTimeText: String {
        departure.arrivalDate.formatted(date: .omitted, time: .shortened)
    }

    private var fare: PATCOFare {
        PATCOFare(origin: departure.origin, destination: departure.destination)
    }

    private var rideTimeText: String {
        "\(departure.travelMinutes) min"
    }

    private var stationPairText: String {
        "\(departure.origin.name) \u{2192} \(departure.destination.name)"
    }

    private var adjustedFromText: String? {
        guard let adjustment = departure.scheduleAdjustment else { return nil }
        guard let originalDepartureDate = adjustment.originalDepartureDate else {
            return "Departure added by special schedule"
        }

        return "Adjusted from \(originalDepartureDate.formatted(date: .omitted, time: .shortened))"
    }

    private func departureTimeTitle(at date: Date) -> String {
        guard date >= departure.departureDate else { return "Scheduled Departure" }

        let elapsedMinutes = max(0, Int(date.timeIntervalSince(departure.departureDate) / 60))
        if elapsedMinutes == 0 {
            return "Scheduled just now"
        }

        return "Scheduled \(elapsedMinutes) min ago"
    }

    @ViewBuilder
    private func detailDepartureStatus(at date: Date) -> some View {
        if date >= departure.departureDate {
            Label("Scheduled departure time has passed", systemImage: "clock.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.patcoWine, in: Capsule())
                .frame(maxWidth: .infinity, alignment: .center)
        } else if let catchStatus {
            VStack(spacing: 9) {
                Label(catchStatus.title, systemImage: catchStatus.systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(catchStatus.foregroundColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(catchStatus.backgroundColor, in: Capsule())

                if let arrivalSummary = catchStatus.stationArrivalSummary(at: departure.origin.name) {
                    Label(
                        arrivalSummary.title,
                        systemImage: arrivalSummary.mode == .walking ? "figure.walk" : "car.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.68))
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let arrivalSummary = catchStatus.stationArrivalSummary(at: departure.origin.name) {
                    VStack(alignment: .leading, spacing: 5) {
                        reachabilitySectionTitle("If you leave now")

                        HStack(spacing: 14) {
                            deadlineSummary(
                                title: "Leave current location",
                                time: date.formatted(date: .omitted, time: .shortened),
                                alignment: .leading
                            )

                            Rectangle()
                                .fill(Color.patcoCharcoal.opacity(0.16))
                                .frame(width: 1, height: 34)

                            deadlineSummary(
                                title: "Arrive at station",
                                time: "about \(arrivalSummary.arrivalTime)",
                                alignment: .trailing
                            )
                        }

                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let deadlines = catchStatus.departureDeadlineTimes(for: departure) {
                    VStack(alignment: .leading, spacing: 6) {
                        Divider()
                            .overlay(Color.patcoCharcoal.opacity(0.12))

                        reachabilitySectionTitle("To make this train")

                        HStack(spacing: 14) {
                            deadlineSummary(
                                title: "Leave current location by",
                                time: deadlines.leaveBy,
                                alignment: .leading
                            )

                            Rectangle()
                                .fill(Color.patcoCharcoal.opacity(0.16))
                                .frame(width: 1, height: 34)

                            deadlineSummary(
                                title: "Arrive at station by",
                                time: "about \(deadlines.stationBy)",
                                alignment: .trailing
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(catchStatus.accessibilityText(at: departure.origin.name, departure: departure))
        }
    }

    private func deadlineSummary(title: String, time: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Color.patcoCharcoal.opacity(0.52))
                .lineLimit(1)

            Text(time)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Color.patcoPlum)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private func reachabilitySectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.patcoCharcoal.opacity(0.52))
    }

    private var canShowLiveActivity: Bool {
        guard let catchStatus else { return true }
        switch catchStatus {
        case .probablyMissed, .tooLate:
            return false
        case .atStation, .comfortable, .tight:
            return true
        }
    }

    private var bikesAllowedText: String {
        departure.trip.bikesAllowed ? "Allowed" : "Not allowed"
    }

    private var wheelchairAccessibleText: String {
        departure.trip.wheelchairAccessible ? "Accessible" : "Not accessible"
    }

    @MainActor
    private var liveActivityStatusMessage: String? {
        liveActivityMessage ?? (liveActivitiesEnabled ? nil : "Live Activities are disabled in Settings.")
    }

    @MainActor
    private func toggleLiveActivity() async {
        refreshLiveActivityState()

        let message: String
        if isLiveActivityShowing {
            message = await PATCOLiveActivityStarter.stop(departure: departure)
        } else {
            message = await PATCOLiveActivityStarter.start(departure: departure, stops: stops)
        }

        refreshLiveActivityState()
        liveActivityMessage = Self.isSuccessfulLiveActivityMessage(message) ? nil : message
    }

    private static func isSuccessfulLiveActivityMessage(_ message: String) -> Bool {
        message == "Showing on Lock Screen." || message == "Removed from Lock Screen."
    }

    @MainActor
    private func refreshLiveActivityState() {
        liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        isLiveActivityShowing = PATCOLiveActivityStarter.isShowing(departure: departure)
    }

    private func timeText(for stop: TripDetailStop, isFinalStop: Bool) -> String {
        Self.displayTime(isFinalStop ? stop.stopTime.arrival : stop.stopTime.departure)
    }

    private static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coordinates.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 39.928, longitude: -75.055),
                span: MKCoordinateSpan(latitudeDelta: 0.32, longitudeDelta: 0.42)
            )
        }

        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let minLatitude = latitudes.min() ?? first.latitude
        let maxLatitude = latitudes.max() ?? first.latitude
        let minLongitude = longitudes.min() ?? first.longitude
        let maxLongitude = longitudes.max() ?? first.longitude
        let latitudeDelta = max(0.025, (maxLatitude - minLatitude) * 1.65)
        let longitudeDelta = max(0.025, (maxLongitude - minLongitude) * 1.65)

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }

    private static func displayTime(_ timeString: String) -> String {
        let pieces = timeString.split(separator: ":").compactMap { Int($0) }
        guard pieces.count >= 2 else { return timeString }

        let hour = ((pieces[0] % 24) + 24) % 24
        let minute = pieces[1]
        let period = hour >= 12 ? "PM" : "AM"
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", displayHour, minute, period)
    }
}

private struct PATCOFare {
    let oneWayCents: Int

    init(origin: Station, destination: Station) {
        oneWayCents = Self.oneWayFareCents(origin: origin, destination: destination)
    }

    var oneWayText: String {
        Self.currencyText(cents: oneWayCents)
    }

    var roundTripText: String {
        Self.currencyText(cents: oneWayCents * 2)
    }

    private static func oneWayFareCents(origin: Station, destination: Station) -> Int {
        if isPhiladelphia(origin), isPhiladelphia(destination) {
            return 140
        }

        if isBroadwayCityHallPair(origin, destination) {
            return 140
        }

        if isPhiladelphia(origin) || isPhiladelphia(destination) {
            let newJerseyStation = isPhiladelphia(origin) ? destination : origin
            switch newJerseyStation.name {
            case "Lindenwold", "Ashland", "Woodcrest":
                return 300
            case "Haddonfield", "Westmont", "Collingswood":
                return 260
            case "Ferry Avenue":
                return 225
            case "Broadway", "City Hall":
                return 140
            default:
                return 160
            }
        }

        return 160
    }

    private static func isPhiladelphia(_ station: Station) -> Bool {
        station.name == "Franklin Square"
            || station.name == "8th and Market"
            || station.name == "9/10th and Locust"
            || station.name == "12/13th and Locust"
            || station.name == "15/16th and Locust"
    }

    private static func isBroadwayCityHallPair(_ origin: Station, _ destination: Station) -> Bool {
        Set([origin.name, destination.name]) == Set(["Broadway", "City Hall"])
    }

    private static func currencyText(cents: Int) -> String {
        String(format: "$%.2f", Double(cents) / 100)
    }
}

private struct StopTimelineRow: View {
    let stop: TripDetailStop
    let timeText: String
    let isLast: Bool
    let isDestination: Bool
    let onOpenStationInformation: (URL) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Circle()
                    .fill(isDestination ? Color.patcoWine : Color.white)
                    .overlay(Circle().stroke(Color.patcoWine, lineWidth: 3))
                    .frame(width: 22, height: 22)

                if !isLast {
                    Rectangle()
                        .fill(Color.patcoWine)
                        .frame(width: 3, height: 38)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let stationURL {
                        Button {
                            onOpenStationInformation(stationURL)
                        } label: {
                            Text(stop.station.name)
                                .font(.title3.weight(isDestination ? .bold : .semibold))
                                .foregroundStyle(Color.patcoCharcoal)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show information for \(stop.station.name) station")
                    } else {
                        Text(stop.station.name)
                            .font(.title3.weight(isDestination ? .bold : .semibold))
                            .foregroundStyle(Color.patcoCharcoal)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }

                    if isDestination {
                        Text("Destination")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.patcoWine)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.patcoGold.opacity(0.28), in: Capsule())
                    }
                }

                Spacer(minLength: 8)

                Text(timeText)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.62))

                if let stationURL {
                    Button {
                        onOpenStationInformation(stationURL)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.patcoWine)
                            .frame(width: 44, height: 44)
                            .background(Color.patcoWine.opacity(0.08), in: Circle())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show information for \(stop.station.name) station")
                    .help("Show station information")
                }
            }
            .padding(.bottom, isLast ? 0 : 22)
            .overlay(alignment: .bottom) {
                if !isLast {
                    Divider()
                        .padding(.leading, 4)
                }
            }
        }
        .padding(.horizontal, isDestination ? 10 : 0)
        .padding(.vertical, isDestination ? 10 : 0)
        .background(
            isDestination ? Color.patcoGold.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private var stationURL: URL? {
        guard let url = URL(string: stop.station.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        return url
    }
}
