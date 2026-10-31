import ActivityKit
import CoreLocation
import SwiftUI

#if DEBUG && targetEnvironment(simulator)
@MainActor
enum ArrivalScreenPreview {
    static let screen: TripDetailView = {
        let data = try! Data(contentsOf: Bundle.main.url(forResource: "patco_schedule", withExtension: "json")!)
        let store = PATCOScheduleStore(feed: try! JSONDecoder().decode(PATCOFeed.self, from: data))
        let origin = store.stations.first { $0.name == "Ashland" }!
        let destination = store.stations.first { $0.name == "15/16th and Locust" }!
        let now = Date(timeIntervalSince1970: ProcessInfo.processInfo.environment["PATCO_UI_NOW"].flatMap(Double.init)
            ?? floor(Date().timeIntervalSince1970))
        let template = store.departures(from: origin, to: destination, after: now, limit: 1).first!
        let times = template.trip.stopTimes.filter {
            $0.sequence >= template.originTime.sequence && $0.sequence <= template.destinationTime.sequence
        }.sorted { $0.sequence < $1.sequence }
        let anchorIndex = max(1, times.count - 4)
        let beforeTrip = ProcessInfo.processInfo.arguments.contains("-beforeTripTrackingPreview")
        let start = now.addingTimeInterval(beforeTrip ? 38 * 60 : -240 - Double(anchorIndex) * 120)
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
        if ProcessInfo.processInfo.arguments.contains("-journeyUITests") {
            if SharedRouteCoordinator.current() == nil {
                _ = SharedRouteCoordinator.commit(originId: origin.id, destinationId: destination.id, manual: true)
                TripProgressStore.shared.installArrivalPreview(departure: departure, stops: stops, anchorIndex: anchorIndex, now: now)
                if let session = TripProgressStore.shared.session {
                    _ = SharedRouteCoordinator.beginJourney(session, expectedRevision: SharedRouteCoordinator.current()!.revision)
                    _ = SharedRouteCoordinator.saveJourneyProgress(TripProgressStore.shared.progress, key: session.key)
                }
            }
            TripProgressStore.shared.synchronize()
        } else {
            TripProgressStore.shared.installArrivalPreview(departure: departure, stops: stops, anchorIndex: anchorIndex, now: now)
        }
        let provider = ProcessInfo.processInfo.arguments.contains("-journeyUITests")
            ? LocationProvider(manager: PreviewLocationManager()) : LocationProvider()
        return TripDetailView(departure: departure, stops: stops, locationProvider: provider,
                              catchStatusAt: { date in
                                  beforeTrip ? .comfortable(travelMinutes: 25, mode: .driving,
                                      arrivalAtStationDate: date.addingTimeInterval(25 * 60),
                                      leaveByDate: start.addingTimeInterval(-28 * 60)) : nil
                              }, onArrived: {
                                  _ = TripTrackingController.confirmArrival(departure: departure, locationProvider: provider)
                              }, onClose: {})
    }()
}

private final class PreviewLocationManager: LocationManaging {
    weak var delegate: CLLocationManagerDelegate?
    var authorizationStatus: CLAuthorizationStatus = .denied
    var desiredAccuracy: CLLocationAccuracy = 0
    var distanceFilter: CLLocationDistance = 0
    var pausesLocationUpdatesAutomatically = true
    var allowsBackgroundLocationUpdates = false
    var showsBackgroundLocationIndicator = false
    func requestWhenInUseAuthorization() {}
    func requestLocation() {}
    func startUpdatingLocation() {}
    func stopUpdatingLocation() {}
}

#endif

struct TripDetailView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var tripProgress: TripProgressStore
    let departure: Departure
    let stops: [TripDetailStop]
    let catchStatusAt: (Date) -> TrainCatchStatus?
    let onClose: () -> Void
    let onArrived: () -> Void
    let locationProvider: LocationProvider

    @State private var liveActivityMessage: String?
    @State private var isLiveActivityShowing = false
    @State private var isCompletingTrip = false
    @State private var isChangingTracking = false
    @State private var showsArrivalConfirmation = false
    @State private var showsStopConfirmation = false
    @State private var didCompleteTrip = false
    @State private var liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    @State private var selectedStationInformation: StationInformationDestination?

    init(departure: Departure, stops: [TripDetailStop], locationProvider: LocationProvider,
         tripProgress: TripProgressStore = .shared,
         catchStatusAt: @escaping (Date) -> TrainCatchStatus?, onArrived: @escaping () -> Void = {},
         onClose: @escaping () -> Void) {
        self.tripProgress = tripProgress
        self.departure = departure
        self.stops = stops
        self.catchStatusAt = catchStatusAt
        self.onClose = onClose
        self.onArrived = onArrived
        self.locationProvider = locationProvider
    }

    private var presentation: TripDetailPresentation {
        TripDetailPresentation(departure: departure, stops: stops, session: tripProgress.session,
            tripKey: tripProgress.tripKey, progress: tripProgress.progress)
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
                    TripJourneySummary(presentation: presentation, didCompleteTrip: didCompleteTrip, catchStatusAt: catchStatusAt)
                    liveActivityControls
                    TripRouteMap(presentation: presentation, location: locationProvider.currentLocation)
                    TripStopTimeline(presentation: presentation) { selectedStationInformation = $0 }
                    TripFareSummary(departure: departure) { selectedStationInformation = $0 }
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
        .confirmationDialog("End trip at \(departure.destination.name)?", isPresented: $showsArrivalConfirmation, titleVisibility: .visible) {
            Button("I've arrived") { Task { await completeTrip() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your location does not confirm arrival. This will end tracking and show return departures.")
        }
        .confirmationDialog("Cancel tracking this trip?", isPresented: $showsStopConfirmation, titleVisibility: .visible) {
            Button("Cancel tracking", role: .destructive) { Task { await stopTracking() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This also removes the trip from your Lock Screen. Your route will not be reversed.")
        }
        .sheet(item: $selectedStationInformation) { destination in
            StationInformationSheet(destination: destination)
        }
        .task {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("-arrivalScreenPreview") { return }
            #endif
            refreshLiveActivityState()
            if let location = locationProvider.currentLocation {
                tripProgress.record(location, stations: stops.map(\.station))
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
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .padding(.horizontal, 54)
                .foregroundStyle(Color.patcoCharcoal)
                .frame(maxWidth: .infinity)

            HStack {
                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.patcoCharcoal)
                        .frame(width: 46, height: 46)
                        .background(Color.white.opacity(0.88), in: Circle())
                }
                .accessibilityLabel("Close trip details")
            }
        }
    }

    private var liveActivityControls: some View {
        LiveTimeline(interval: 30) { now in
            let activeJourney = presentation.hasTripProgress && tripProgress.session?.isActive(at: now) == true
            let completed = didCompleteTrip || (presentation.hasTripProgress && tripProgress.session?.completed == true)
            if completed {
                Button("Return to departures", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 8))
                    .tint(Color.patcoWine)
            } else if !departure.isRemovedBySpecialSchedule
                && !ScheduledTripExpiration.hasExpired(arrivalDate: departure.arrivalDate, now: now) {
                VStack(alignment: .leading, spacing: 10) {
                    if activeJourney {
                        let layout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                            : AnyLayout(HStackLayout(spacing: 12))
                        layout {
                            Label(isChangingTracking ? "Updating trip..." : "Trip tracking on",
                                  systemImage: isChangingTracking ? "hourglass" : "location.fill")
                                .font(.subheadline.weight(.semibold))
                            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                            Button {
                                showsStopConfirmation = true
                            } label: {
                                Label("Cancel tracking", systemImage: "xmark")
                                    .font(.subheadline.weight(.medium))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 12)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .background(Color.patcoWine.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(Color.patcoWine.opacity(0.45), lineWidth: 1)
                                    }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.patcoWine)
                            .accessibilityIdentifier("trip.stop")
                            .help("Cancel tracking this trip")
                        }
                    } else {
                    Button {
                        Task { await startTracking() }
                    } label: {
                        Label(isChangingTracking ? "Updating trip..." : "Track this trip",
                              systemImage: isChangingTracking ? "hourglass" : "location.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(Color.white)
                            .background(Color.patcoWine, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("trip.start")
                    .tint(Color.patcoWine)
                    }

                    if activeJourney {
                        Toggle(isOn: Binding(get: { isLiveActivityShowing }, set: { _ in
                            Task { await toggleLiveActivity() }
                        })) {
                            Label("Show on Lock Screen", systemImage: "platter.filled.top.and.arrow.up.iphone")
                        }
                        .tint(Color.patcoWine)
                        .font(.subheadline)
                        .accessibilityIdentifier("trip.lockScreen")
                        .disabled(!isLiveActivityShowing && !liveActivitiesEnabled)

                        if now >= departure.departureDate {
                            Button {
                                if isNearDestination { Task { await completeTrip() } }
                                else { showsArrivalConfirmation = true }
                            } label: {
                                Label(isCompletingTrip ? "Completing trip..." : "I've arrived", systemImage: "checkmark.circle")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .foregroundStyle(Color.patcoWine)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.patcoWine.opacity(0.25)))
                            }
                            .buttonStyle(.plain)
                            .tint(Color.patcoWine)
                            .background(isNearDestination ? Color.patcoGold.opacity(0.2) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    if let liveActivityStatusMessage {
                        Text(liveActivityStatusMessage)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.patcoCharcoal.opacity(0.66))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .disabled(isChangingTracking || isCompletingTrip)
            }
        }
    }

    private var isNearDestination: Bool {
        guard let location = locationProvider.currentLocation,
              LocationGuidancePolicy.isUsable(location, maxAge: 15), location.horizontalAccuracy <= 50 else { return false }
        return location.distance(from: departure.destination.location) + location.horizontalAccuracy <= 150
    }

    @MainActor
    private func startTracking() async {
        guard !isChangingTracking, !isCompletingTrip else { return }
        isChangingTracking = true
        defer { isChangingTracking = false }
        liveActivityMessage = await TripTrackingController.start(departure: departure, stops: stops,
                                                               locationProvider: locationProvider, tripProgress: tripProgress)
        refreshLiveActivityState()
    }

    @MainActor
    private func stopTracking() async {
        guard !isChangingTracking, !isCompletingTrip, presentation.hasTripProgress, let key = tripProgress.session?.key else { return }
        isChangingTracking = true
        defer { isChangingTracking = false }
        liveActivityMessage = await TripTrackingController.cancel(key: key, departure: departure,
                                                                locationProvider: locationProvider, tripProgress: tripProgress)
        refreshLiveActivityState()
    }

    @MainActor
    private func completeTrip() async {
        guard !isChangingTracking, !isCompletingTrip else { return }
        isCompletingTrip = true
        defer { isCompletingTrip = false }
        onArrived()
        tripProgress.synchronize()
        guard presentation.hasTripProgress, tripProgress.session?.completed == true else {
            liveActivityMessage = "Unable to complete this trip. Check the selected route and try again."
            return
        }
        didCompleteTrip = true
        _ = await PATCOLiveActivityStarter.stop(departure: departure, tripProgress: tripProgress)
        refreshLiveActivityState()
    }

    @MainActor
    private var liveActivityStatusMessage: String? {
        liveActivityMessage ?? (liveActivitiesEnabled ? nil : "Live Activities are disabled in Settings.")
    }

    @MainActor
    private func toggleLiveActivity() async {
        guard !isChangingTracking, !isCompletingTrip else { return }
        isChangingTracking = true
        defer { isChangingTracking = false }
        refreshLiveActivityState()

        let message: String
        if isLiveActivityShowing {
            message = await PATCOLiveActivityStarter.stop(departure: departure, tripProgress: tripProgress)
        } else {
            message = await PATCOLiveActivityStarter.start(departure: departure, stops: stops, tripProgress: tripProgress)
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

}
