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

#if DEBUG && targetEnvironment(simulator)
@MainActor
enum ArrivalScreenPreview {
    static let screen: TripDetailView = {
        let data = try! Data(contentsOf: Bundle.main.url(forResource: "patco_schedule", withExtension: "json")!)
        let store = PATCOScheduleStore(feed: try! JSONDecoder().decode(PATCOFeed.self, from: data))
        let origin = store.stations.first { $0.name == "Ashland" }!
        let destination = store.stations.first { $0.name == "15/16th and Locust" }!
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let template = store.departures(from: origin, to: destination, after: now, limit: 1).first!
        let times = template.trip.stopTimes.filter {
            $0.sequence >= template.originTime.sequence && $0.sequence <= template.destinationTime.sequence
        }.sorted { $0.sequence < $1.sequence }
        let anchorIndex = max(1, times.count - 4)
        let start = now.addingTimeInterval(-240 - Double(anchorIndex) * 120)
        let formatter = DateFormatter()
        formatter.timeZone = PATCOClock.calendar.timeZone
        formatter.dateFormat = "HH:mm:ss"
        let previewTimes = times.enumerated().map { index, stop in
            let time = formatter.string(from: start.addingTimeInterval(Double(index) * 120))
            return StopTime(stopId: stop.stopId, arrival: time, departure: time, sequence: stop.sequence)
        }
        let trip = Trip(id: "arrival-preview", serviceId: template.trip.serviceId, headsign: template.trip.headsign,
            directionId: template.trip.directionId, bikesAllowed: true, wheelchairAccessible: true, stopTimes: previewTimes)
        let end = start.addingTimeInterval(Double(times.count - 1) * 120)
        let departure = Departure(trip: trip, origin: origin, destination: destination,
            originTime: previewTimes.first!, destinationTime: previewTimes.last!, serviceDate: PATCOClock.calendar.startOfDay(for: start),
            departureDate: start, arrivalDate: end, routeSequenceIndex: 0, isSpecialSchedule: false,
            isRemovedBySpecialSchedule: false, scheduleAdjustment: nil)
        let stops = previewTimes.map { TripDetailStop(station: store.station(for: $0.stopId)!, stopTime: $0) }
        TripProgressStore.shared.installArrivalPreview(departure: departure, stops: stops, anchorIndex: anchorIndex, now: now)
        return TripDetailView(departure: departure, stops: stops, locationProvider: LocationProvider(),
                              catchStatusAt: { _ in nil }, onClose: {})
    }()
}

extension TripProgressStore {
    fileprivate func installArrivalPreview(departure: Departure, stops: [TripDetailStop], anchorIndex: Int, now: Date) {
        let key = "arrival-preview"
        tripKey = key
        session = JourneyProgressSession(key: key,
            deepLink: "patconext://departure?origin=\(departure.origin.id)&destination=\(departure.destination.id)&departure=\(departure.departureDate.timeIntervalSince1970)",
            originName: departure.origin.name, destinationName: departure.destination.name,
            departure: departure.departureDate, arrival: departure.arrivalDate,
            stops: stops.dropFirst().enumerated().map { index, stop in
                .init(name: stop.station.name, arrival: departure.departureDate.addingTimeInterval(Double(index + 1) * 120))
            })
        progress = TripLocationProgress()
        let reading = CLLocation(coordinate: stops[anchorIndex].station.coordinate, altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 1, course: -1, speed: -1, timestamp: now.addingTimeInterval(-20))
        progress.observe(reading, stations: stops.map(\.station), geometry: PATCOTrackGeometry.bundled,
            departure: departure.departureDate, arrival: departure.arrivalDate, now: reading.timestamp)
    }
}
#endif

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

@MainActor
final class TripProgressStore: ObservableObject {
    static let shared = TripProgressStore()
    @Published private(set) var tripKey: String?
    @Published private(set) var session: JourneyProgressSession?
    @Published private(set) var progress = TripLocationProgress()
    private let defaults = UserDefaults.standard
    private var lastPersistedAt: Date?

    private init() {
        tripKey = defaults.string(forKey: "tripProgressKey")
        if let data = defaults.data(forKey: "journeyProgressSession") {
            session = try? JSONDecoder().decode(JourneyProgressSession.self, from: data)
        }
        if let data = defaults.data(forKey: "tripProgress"),
           let saved = try? JSONDecoder().decode(TripLocationProgress.self, from: data) { progress = saved }
        if let route = SharedRouteCoordinator.current() {
            if route.journey == nil, let session, session.isActive() {
                _ = SharedRouteCoordinator.beginJourney(session, expectedRevision: route.revision)
                _ = SharedRouteCoordinator.saveJourneyProgress(progress, key: session.key)
            }
            synchronize()
        }
    }

    func synchronize() {
        guard let route = SharedRouteCoordinator.expireJourney() else { return }
        let changedTrip = session?.key != route.journey?.key
        session = route.journey
        if changedTrip {
            tripKey = session?.key
            progress = route.journeyProgress ?? TripLocationProgress()
            lastPersistedAt = nil
        }
    }

    func begin(key: String, attributes: PATCOTripActivityAttributes, state: PATCOTripActivityAttributes.ContentState) {
        synchronize()
        guard session?.key != key else { return }
        let sameTrip = session?.deepLink == attributes.deepLinkURLString
        let proposed = JourneyProgressSession(key: key, deepLink: attributes.deepLinkURLString,
            originName: attributes.originName, destinationName: attributes.destinationName,
            departure: state.departureDate, arrival: state.arrivalDate,
            stops: state.stops.map { .init(name: $0.name, arrival: $0.arrivalDate) })
        guard let revision = SharedRouteCoordinator.current()?.revision,
              let route = SharedRouteCoordinator.beginJourney(proposed, expectedRevision: revision),
              route.journey?.key == key else { return }
        session = route.journey
        if !sameTrip && tripKey != key { progress = TripLocationProgress(); lastPersistedAt = nil }
        tripKey = key
        defaults.set(tripKey, forKey: "tripProgressKey")
        defaults.set(try? JSONEncoder().encode(progress), forKey: "tripProgress")
        defaults.removeObject(forKey: "journeyProgressSession")
    }

    func complete(arrivingAt name: String) {
        // Completion is committed with the route, never inferred from a display name here.
        synchronize()
    }

    func record(_ location: CLLocation, stations: [Station]) {
        synchronize()
        if let activity = PATCOLiveActivityStarter.currentTripActivity() {
            begin(key: activity.id, attributes: activity.attributes, state: activity.content.state)
        }
        guard let session, session.isActive(),
              let origin = stations.first(where: { $0.name == session.originName }) else { return }
        let ordered = [origin] + session.stops.compactMap { stop in
            stations.first { $0.name == stop.name }
        }
        guard ordered.count == session.stops.count + 1 else { return }
        let key = session.key
        let newTrip = tripKey != key
        if newTrip { tripKey = key; progress = TripLocationProgress(); lastPersistedAt = nil }
        var next = progress
        next.observe(location, stations: ordered, geometry: PATCOTrackGeometry.bundled,
                     departure: session.departure, arrival: session.arrival,
                     stationArrivals: Dictionary(uniqueKeysWithValues: zip(ordered.dropFirst(), session.stops).map {
                         ($0.0.id, $0.1.arrival)
                     }))
        guard newTrip || next != progress else { return }
        let changedStations = next.detectedStationIds != progress.detectedStationIds
            || next.inferredStationIds != progress.inferredStationIds
        let shouldSave = newTrip || changedStations
            || (next.positionAt?.timeIntervalSince(lastPersistedAt ?? .distantPast) ?? 0) >= 10
        progress = next
        if shouldSave {
            _ = SharedRouteCoordinator.saveJourneyProgress(next, key: key)
            defaults.set(key, forKey: "tripProgressKey")
            defaults.set(try? JSONEncoder().encode(next), forKey: "tripProgress")
            lastPersistedAt = next.positionAt
        }
    }
}

enum PATCOLiveActivityStarter {
    static let activityDidChangeNotification = Notification.Name("PATCOLiveActivityDidChange")
    @MainActor private static var expirationTasks: [String: Task<Void, Never>] = [:]

    @MainActor
    private static func scheduleExpiration(id: String, deadline: Date) {
        guard expirationTasks[id] == nil else { return }
        expirationTasks[id] = Task {
            do {
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            } catch { return }
            expirationTasks[id] = nil
            await endExpiredActivities()
        }
    }

    @MainActor
    private static func cancelExpiration(id: String) {
        expirationTasks.removeValue(forKey: id)?.cancel()
    }

    @MainActor
    static func currentTripActivity(now: Date = Date()) -> Activity<PATCOTripActivityAttributes>? {
        Activity<PATCOTripActivityAttributes>.activities
            .filter {
                ($0.activityState == .active || $0.activityState == .stale)
                    && !ScheduledTripExpiration.hasExpired(arrivalDate: $0.content.state.arrivalDate, now: now)
                    && URL(string: $0.attributes.deepLinkURLString).flatMap(DepartureDeepLink.init(url:)) != nil
            }
            .max { $0.content.state.lastUpdated < $1.content.state.lastUpdated }
    }

    @MainActor
    static func hasCurrentTrip(to destinationName: String, now: Date = Date()) -> Bool {
        if let session = SharedRouteCoordinator.current()?.journey {
            return session.isActive(at: now) && session.destinationName == destinationName
                && session.departure <= now.addingTimeInterval(3600)
        }
        return Activity<PATCOTripActivityAttributes>.activities.contains {
            $0.activityState == .active && $0.attributes.destinationName == destinationName
                && $0.content.state.arrivalDate > now
                && $0.content.state.departureDate <= now.addingTimeInterval(3600)
        }
    }

    @MainActor
    static func isShowing(departure: Departure) -> Bool {
        matchingActivity(for: departure) != nil
    }

    @MainActor
    static func stop(departure: Departure) async -> String {
        guard let activity = matchingActivity(for: departure) else {
            return "Not currently showing on Lock Screen."
        }

        TripProgressStore.shared.begin(key: activity.id, attributes: activity.attributes, state: activity.content.state)
        await activity.end(nil, dismissalPolicy: .immediate)
        cancelExpiration(id: activity.id)
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
        let activityStops = scheduledStops.compactMap { stop -> PATCOTripActivityAttributes.Stop? in
            guard let arrivalDate = stopDate(for: stop.stopTime, serviceDate: departure.serviceDate,
                                             isSpecialSchedule: departure.isSpecialSchedule) else { return nil }
            return PATCOTripActivityAttributes.Stop(
                name: stop.station.name,
                arrivalDate: arrivalDate
            )
        }
        let state = contentState(departure: departure, stops: activityStops)
        let content = ActivityContent(
            state: state,
            staleDate: ScheduledDeparturePresentation.staleDate(departureDate: departure.departureDate,
                                                               arrivalDate: departure.arrivalDate)
        )

        do {
            for activity in Activity<PATCOTripActivityAttributes>.activities {
                cancelExpiration(id: activity.id)
                await activity.end(nil, dismissalPolicy: .immediate)
            }

            let activity = try Activity<PATCOTripActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            TripProgressStore.shared.begin(key: activity.id, attributes: attributes, state: state)
            scheduleExpiration(id: activity.id, deadline: ScheduledTripExpiration.deadline(arrivalDate: departure.arrivalDate))
            NotificationCenter.default.post(name: activityDidChangeNotification, object: nil)
            return "Showing on Lock Screen."
        } catch {
            return "Could not start Live Activity."
        }
    }

    @MainActor
    static func endExpiredActivities(now: Date = Date()) async {
        TripProgressStore.shared.synchronize()
        for activity in Activity<PATCOTripActivityAttributes>.activities {
            let dismissalDate = ScheduledTripExpiration.deadline(arrivalDate: activity.content.state.arrivalDate)
            let session = TripProgressStore.shared.session
            let terminated = session?.key == activity.id && (session?.completed == true || session?.termination != nil)
            if now >= dismissalDate || terminated {
                cancelExpiration(id: activity.id)
                await activity.end(nil, dismissalPolicy: .immediate)
                NotificationCenter.default.post(name: activityDidChangeNotification, object: nil)
            } else {
                let staleDate = ScheduledDeparturePresentation.staleDate(
                    departureDate: activity.content.state.departureDate,
                    arrivalDate: activity.content.state.arrivalDate, now: now)
                if activity.content.staleDate != staleDate {
                    await activity.update(ActivityContent(state: activity.content.state, staleDate: staleDate))
                }
                scheduleExpiration(id: activity.id, deadline: dismissalDate)
            }
        }
    }

    @MainActor
    static func endActivities(arrivingAt stationName: String) async {
        TripProgressStore.shared.complete(arrivingAt: stationName)
        for activity in Activity<PATCOTripActivityAttributes>.activities
        where activity.attributes.destinationName == stationName {
            cancelExpiration(id: activity.id)
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

    private static func stopDate(for stopTime: StopTime, serviceDate: Date, isSpecialSchedule: Bool) -> Date? {
        PATCOScheduleStore.scheduleDate(serviceDate: serviceDate, timeString: stopTime.arrival,
                                        isSpecialSchedule: isSpecialSchedule)
    }
}

struct TripDetailView: View {
    @ObservedObject private var tripProgress = TripProgressStore.shared
    let departure: Departure
    let stops: [TripDetailStop]
    let catchStatusAt: (Date) -> TrainCatchStatus?
    let onClose: () -> Void
    let onArrived: () -> Void
    @ObservedObject var locationProvider: LocationProvider

    @State private var cameraPosition: MapCameraPosition
    @State private var liveActivityMessage: String?
    @State private var isLiveActivityShowing = false
    @State private var isCompletingTrip = false
    @State private var liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    @State private var selectedStationInformation: StationInformationDestination?

    init(departure: Departure, stops: [TripDetailStop], locationProvider: LocationProvider,
         catchStatusAt: @escaping (Date) -> TrainCatchStatus?, onArrived: @escaping () -> Void = {},
         onClose: @escaping () -> Void) {
        self.departure = departure
        self.stops = stops
        self.catchStatusAt = catchStatusAt
        self.onClose = onClose
        self.onArrived = onArrived
        self.locationProvider = locationProvider
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
                    routeMap
                    stopTimeline
                    tripSummary
                }
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .padding(.bottom, 30)
            }
            #if DEBUG && targetEnvironment(simulator)
            .defaultScrollAnchor(ProcessInfo.processInfo.arguments.contains("-arrivalStopsPreview") ? .bottom : .top)
            #endif
        }
        .background(Color(red: 0.94, green: 0.94, blue: 0.96))
        .preferredColorScheme(.light)
        .sheet(item: $selectedStationInformation) { destination in
            StationInformationSheet(destination: destination)
        }
        .task {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("-arrivalScreenPreview") { return }
            #endif
            refreshLiveActivityState()
            if let location = locationProvider.currentLocation {
                TripProgressStore.shared.record(location, stations: stops.map(\.station))
            }
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
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(fare.oneWayText) one way · \(fare.roundTripText) round trip")
                Label("Bikes \(bikesAllowedText.lowercased())", systemImage: "bicycle")
                Divider().padding(.vertical, 4)
                Text("Station accessibility and live elevator status aren't available in the app. Check each station's information before traveling.")
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
    }

    private func stationAccessibility(_ station: Station, role: String) -> some View {
        Group {
            if let url = URL(string: station.url),
               ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                Button {
                    selectedStationInformation = StationInformationDestination(stationName: station.name, url: url)
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

    private func destinationEstimate(at date: Date) -> TripLocationProgress.ArrivalEstimate? {
        guard hasTripProgress, tripProgress.session?.isActive(at: date) == true,
              !departure.isRemovedBySpecialSchedule else { return nil }
        var scheduled: [Station.ID: Date] = [:]
        for stop in stops {
            scheduled[stop.station.id] = PATCOScheduleStore.scheduleDate(serviceDate: departure.serviceDate,
                timeString: stop.stopTime.arrival, isSpecialSchedule: departure.isSpecialSchedule)
        }
        scheduled[departure.origin.id] = departure.departureDate
        scheduled[departure.destination.id] = departure.arrivalDate
        return tripProgress.progress.arrivalEstimate(stations: stops.map(\.station), scheduled: scheduled,
            geometry: PATCOTrackGeometry.bundled, now: date)
    }

    private var tripHero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(stationPairText)
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.patcoCharcoal)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            tripDirectionSummary

            Divider()

            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                let estimate = destinationEstimate(at: timeline.date)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 16) {
                        heroTimeItem(
                            title: "Scheduled Departure",
                            value: departureTimeText,
                            adjustmentText: adjustedFromText,
                            isDeparted: timeline.date >= departure.departureDate
                        )

                        Spacer(minLength: 12)

                        heroTimeItem(
                            title: estimate == nil ? "Scheduled Arrival" : "Estimated Arrival",
                            value: estimate.map { PATCOClock.timeText($0.date, relativeTo: departure.departureDate) } ?? arrivalTimeText,
                            scheduledText: estimate == nil ? nil : "Scheduled arrival: \(arrivalTimeText)",
                            adjustmentText: estimate?.delayText(scheduled: departure.arrivalDate),
                            isDeparted: false,
                            alignment: .trailing
                        )
                    }

                    if let estimate {
                        Text("\(estimate.basis) · Updated \(max(0, Int(timeline.date.timeIntervalSince(estimate.observedAt)))) sec ago")
                            .font(.caption)
                            .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    detailDepartureStatus(at: timeline.date)
                }
            }
        }
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
    }

    private var liveActivityControls: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let activeJourney = hasTripProgress && tripProgress.session?.isActive(at: timeline.date) == true
            let primaryLockScreenAction = !isLiveActivityShowing && timeline.date < departure.departureDate
            if isLiveActivityShowing || activeJourney || (timeline.date < departure.departureDate && canShowLiveActivity(at: timeline.date)) {
                VStack(alignment: .leading, spacing: 10) {

                    if (isLiveActivityShowing || (hasTripProgress && tripProgress.session?.isActive(at: timeline.date) == true))
                        && timeline.date >= departure.departureDate {
                        Button {
                            guard !isCompletingTrip else { return }
                            isCompletingTrip = true
                            onArrived()
                            Task {
                                _ = await PATCOLiveActivityStarter.stop(departure: departure)
                                refreshLiveActivityState()
                                isCompletingTrip = false
                                onClose()
                            }
                        } label: {
                            Label("I've arrived", systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .foregroundStyle(Color.white)
                                .background(Color.patcoWine, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .opacity(isCompletingTrip ? 0.45 : 1)
                        .disabled(isCompletingTrip)
                    }

                    Button {
                        Task {
                            await toggleLiveActivity()
                        }
                    } label: {
                        Label(
                            isLiveActivityShowing ? "Remove from Lock Screen" : "Show on Lock Screen",
                            systemImage: isLiveActivityShowing ? "xmark.circle" : "platter.filled.top.and.arrow.up.iphone"
                        )
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(primaryLockScreenAction ? Color.white : Color.patcoWine)
                            .background(primaryLockScreenAction ? Color.patcoWine : Color.white, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.patcoWine.opacity(0.25), lineWidth: 1)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .opacity(isCompletingTrip || (!isLiveActivityShowing && !liveActivitiesEnabled) ? 0.45 : 1)
                    .disabled(isCompletingTrip || (!isLiveActivityShowing && !liveActivitiesEnabled))

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
        Text("\(departure.directionLabel) · \(rideTimeText)")
            .font(.subheadline)
            .foregroundStyle(Color.patcoCharcoal.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
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
        scheduledText: String? = nil,
        adjustmentText: String? = nil,
        isDeparted: Bool = false,
        alignment: Alignment = .leading
    ) -> some View {
        VStack(alignment: alignment == .trailing ? .trailing : .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.patcoCharcoal.opacity(0.52))

            Text(value)
                .font(isDeparted ? .headline : .title.weight(.bold))
                .foregroundStyle(isDeparted ? Color.patcoCharcoal.opacity(0.72) : Color.patcoWine)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            if let scheduledText {
                Text(scheduledText)
                    .font(.caption)
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                    .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let adjustmentText {
                Label(adjustmentText, systemImage: adjustmentText == "On time" ? "checkmark.circle" : "clock")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(adjustmentText == "On time" ? Color.patcoCharcoal.opacity(0.72) : Color.patcoWine)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private var estimatedSpeed: some View {
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            if TripSpeedPresentation.isDuringTrip(departure: departure.departureDate,
                arrival: departure.arrivalDate, now: timeline.date),
               !departure.isRemovedBySpecialSchedule {
                let position = hasTripProgress ? tripProgress.progress.mapPosition(
                    stations: stops.map(\.station), geometry: PATCOTrackGeometry.bundled, now: timeline.date) : nil
                let freshLocation = hasTripProgress ? position?.isFreshGPS == true
                    : locationProvider.currentLocation.map {
                        LocationGuidancePolicy.isUsable($0, maxAge: 15, now: timeline.date)
                            && PATCOTrackGeometry.bundled?.isNearTrack($0) == true
                    } == true
                Group {
                    if !freshLocation {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Live location unavailable")
                                Text(position == nil ? "Waiting for a reliable location" : "Showing last known position")
                                    .font(.caption)
                                    .foregroundStyle(Color.patcoCharcoal.opacity(0.65))
                            }
                        } icon: {
                            Image(systemName: "location.slash")
                        }
                    } else if let location = locationProvider.currentLocation,
                       let speed = TripSpeedPresentation.milesPerHour(location, now: timeline.date),
                       PATCOTrackGeometry.bundled?.isNearTrack(location) == true {
                        HStack {
                            Label("Estimated speed", systemImage: "speedometer")
                            Spacer()
                            Text("\(speed) mph").monospacedDigit().fontWeight(.semibold)
                        }
                    } else {
                        Label("Location up to date", systemImage: "location.fill")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.subheadline)
                .foregroundStyle(Color.patcoCharcoal)
                .padding(.vertical, 8)
                .transaction { $0.animation = nil }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var routeMap: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Route map")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.patcoCharcoal)

            estimatedSpeed

            TimelineView(.periodic(from: .now, by: 5)) { timeline in
            Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                if routeCoordinates.count > 1 {
                    MapPolyline(coordinates: routeCoordinates)
                        .stroke(Color.patcoWine, lineWidth: 4)
                }

                ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                    Annotation(index == 0 ? "Start" : index == stops.count - 1 ? "Destination" : "",
                               coordinate: stop.station.coordinate,
                               anchor: index == 0 || index == stops.count - 1 ? .bottom : .center) {
                        if index == 0 {
                            Image(systemName: "circle.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.patcoCharcoal)
                                .frame(width: 20, height: 20)
                                .background(Color.patcoGold, in: Circle())
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                .accessibilityLabel("Origin: \(stop.station.name)")
                        } else if index == stops.count - 1 {
                            Image(systemName: "flag.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Color.patcoWine, in: Circle())
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                .accessibilityLabel("Destination: \(stop.station.name)")
                        } else {
                            Circle()
                                .fill(detectedStationIds.contains(stop.station.id) ? Color.patcoWine : Color.white)
                                .frame(width: 7, height: 7)
                                .overlay(Circle().stroke(Color.patcoWine, style: StrokeStyle(lineWidth: 1.5,
                                    dash: completedStationIds.contains(stop.station.id) && !detectedStationIds.contains(stop.station.id) ? [2, 2] : [])))
                                .accessibilityLabel("\(stop.station.name), \(detectedStationIds.contains(stop.station.id) ? "detected" : completedStationIds.contains(stop.station.id) ? "passed, inferred from route position" : "not detected")")
                        }
                    }
                }
                if hasTripProgress, let position = tripProgress.progress.mapPosition(
                    stations: stops.map(\.station), geometry: PATCOTrackGeometry.bundled, now: timeline.date) {
                    Annotation(position.title, coordinate: position.coordinate, anchor: .bottom) {
                        VStack(spacing: 0) {
                        Image(systemName: "tram.fill")
                            .font(.callout.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(position.isFreshGPS ? Color.blue : Color.gray, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                        Rectangle()
                            .fill(position.isFreshGPS ? Color.blue : Color.gray)
                            .frame(width: 2, height: 22)
                        }
                    }
                }
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var stopTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(stopCountTitle)
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.patcoCharcoal)

            TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let estimate = destinationEstimate(at: timeline.date)
            if let next = nextStop(at: timeline.date) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Next stop")
                        .font(.caption.weight(.semibold))
                    Text(next.station.name)
                        .font(.title3.weight(.bold))
                    if let arrival = estimatedArrivalText(for: next, estimate: estimate, at: timeline.date) {
                        Text(arrival).font(.subheadline)
                    } else {
                        Text("Scheduled \(next.station.id == departure.destination.id ? "arrival" : "departure") \(timeText(for: next, isFinalStop: next.station.id == departure.destination.id))")
                            .font(.subheadline)
                    }
                }
                .foregroundStyle(Color.patcoWine)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(scheduledStops.enumerated()), id: \.element.id) { index, stop in
                    StopTimelineRow(
                        stop: stop,
                        timeText: timeText(for: stop, isFinalStop: index == scheduledStops.count - 1),
                        estimatedArrivalText: completedStationIds.contains(stop.station.id) ? nil
                            : estimatedArrivalText(for: stop, estimate: estimate, at: timeline.date),
                        isLast: index == scheduledStops.count - 1,
                        isDestination: index == scheduledStops.count - 1,
                        isDetected: detectedStationIds.contains(stop.station.id),
                        isInferred: completedStationIds.contains(stop.station.id) && !detectedStationIds.contains(stop.station.id),
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
    }

    private var routeCoordinates: [CLLocationCoordinate2D] {
        let track = PATCOTrackGeometry.bundled?.route(from: departure.origin.location, to: departure.destination.location) ?? []
        return track.isEmpty ? stops.map(\.station.coordinate) : track
    }

    private var hasTripProgress: Bool {
        guard let session = tripProgress.session,
              session.key == tripProgress.tripKey,
              let url = URL(string: session.deepLink),
              let link = DepartureDeepLink(url: url) else { return false }
        return link.originId == departure.origin.id && link.destinationId == departure.destination.id
            && link.departureDate == departure.departureDate
    }

    private var detectedStationIds: Set<String> {
        hasTripProgress ? tripProgress.progress.detectedStationIds : []
    }

    private var completedStationIds: Set<String> {
        hasTripProgress ? tripProgress.progress.completedStationIds : []
    }

    private var scheduledStops: [TripDetailStop] {
        Array(stops.dropFirst())
    }

    private func nextStop(at date: Date) -> TripDetailStop? {
        guard date >= departure.departureDate, hasTripProgress,
              tripProgress.session?.isActive(at: date) == true,
              !departure.isRemovedBySpecialSchedule,
              let index = stops.lastIndex(where: { completedStationIds.contains($0.station.id) }),
              index + 1 < stops.count else { return nil }
        return stops[index + 1]
    }

    private var stopCountTitle: String {
        scheduledStops.count == 1 ? "1 stop" : "\(scheduledStops.count) stops"
    }

    private var departureTimeText: String {
        PATCOClock.timeText(departure.departureDate, relativeTo: departure.arrivalDate)
    }

    private var arrivalTimeText: String {
        PATCOClock.timeText(departure.arrivalDate, relativeTo: departure.departureDate)
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

        return "Adjusted from \(PATCOClock.timeText(originalDepartureDate))"
    }

    private func departureTimeTitle(at date: Date) -> String {
        guard date >= departure.departureDate else { return "Scheduled Departure" }

        let elapsedMinutes = max(0, Int(date.timeIntervalSince(departure.departureDate) / 60))
        if elapsedMinutes == 0 {
            return "Scheduled departure: just now"
        }

        return "Scheduled departure: \(elapsedMinutes) min ago"
    }

    @ViewBuilder
    private func detailDepartureStatus(at date: Date) -> some View {
        if date >= departure.departureDate {
            Label(departureTimeTitle(at: date), systemImage: "clock")
                .font(.caption)
                .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let catchStatus = catchStatusAt(date) {
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
                                time: PATCOClock.timeText(date),
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

    private func canShowLiveActivity(at date: Date) -> Bool {
        guard let catchStatus = catchStatusAt(date) else { return true }
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
        let value = isFinalStop ? stop.stopTime.arrival : stop.stopTime.departure
        guard let date = PATCOScheduleStore.scheduleDate(serviceDate: departure.serviceDate, timeString: value,
                                                         isSpecialSchedule: departure.isSpecialSchedule) else { return "Time unconfirmed" }
        return PATCOClock.timeText(date, relativeTo: departure.departureDate)
    }

    private func estimatedArrivalText(for stop: TripDetailStop,
                                      estimate: TripLocationProgress.ArrivalEstimate?, at date: Date) -> String? {
        guard date >= departure.departureDate, hasTripProgress,
              tripProgress.session?.isActive(at: date) == true,
              !departure.isRemovedBySpecialSchedule else { return nil }
        guard let estimate,
              let scheduled = PATCOScheduleStore.scheduleDate(serviceDate: departure.serviceDate,
                timeString: stop.stopTime.arrival, isSpecialSchedule: departure.isSpecialSchedule),
              let arrival = estimate.arrival(at: scheduled, scheduledDestination: departure.arrivalDate, now: date)
        else { return nil }
        return "Est. arrival \(PATCOClock.timeText(arrival, relativeTo: departure.departureDate))"
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
    let estimatedArrivalText: String?
    let isLast: Bool
    let isDestination: Bool
    let isDetected: Bool
    let isInferred: Bool
    let onOpenStationInformation: (URL) -> Void

    var body: some View {
        Group {
            if let stationURL {
                Button { onOpenStationInformation(stationURL) } label: { rowContent }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens station information")
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Circle()
                    .fill(isDetected ? Color.patcoWine : isInferred ? Color.patcoWine.opacity(0.25) : Color.white)
                    .overlay(Circle().strokeBorder(Color.patcoWine,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: isInferred ? [1, 3] : [])))
                    .overlay {
                        if isDetected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 22, height: 22)
                    .accessibilityLabel(isDetected ? "Station detected" : isInferred ? "Station passed, inferred from route position" : "Station not yet detected")

            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stop.station.name)
                        .font(.title3.weight(isDestination ? .bold : .semibold))
                        .foregroundStyle(Color.patcoCharcoal.opacity(isDetected || isInferred ? 0.65 : 1))
                        .fixedSize(horizontal: false, vertical: true)

                    if isDetected || isInferred {
                        Text(isDetected ? "Passed" : "Passed · estimated")
                            .font(.caption2)
                            .foregroundStyle(Color.patcoCharcoal.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let estimatedArrivalText {
                        Text(estimatedArrivalText)
                            .font(.caption)
                            .foregroundStyle(Color.patcoWine)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("\(isDestination ? "Scheduled arrival" : "Scheduled departure") \(timeText)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.patcoCharcoal.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)

                    if isDestination {
                        Text("Destination")
                            .font(.caption2.weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(Color.patcoWine)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.patcoGold.opacity(0.28), in: Capsule())
                    }
                }

                Spacer(minLength: 8)

                if stationURL != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.patcoCharcoal.opacity(0.5))
                        .accessibilityHidden(true)
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
        .background(alignment: .topLeading) {
            if !isLast {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.patcoWine)
                        .frame(width: 3, height: max(0, geometry.size.height - 22))
                        .offset(x: 9.5, y: 22)
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, isDestination ? 10 : 0)
        .background(
            isDestination ? Color.patcoGold.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
