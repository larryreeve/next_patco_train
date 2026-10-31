import ActivityKit
import CoreLocation
import Observation
import SwiftUI

/// Owns displayed route and station-selection transitions. SharedRouteCoordinator
/// remains authoritative for durable journey state and revision-checked commits.
@MainActor @Observable
final class HomeRouteController {
    private(set) var originId: Station.ID?
    private(set) var destinationId: Station.ID?
    private(set) var sharedRouteRevision: Int?
    var nearestRouteStationName: String?
    var nearestStationMessage: String?
    private(set) var currentStation: Station?
    var currentStationId: Station.ID? { currentStation?.id }
    var currentStationName: String? { currentStation?.name }
    var arrivalAnnouncement: ArrivalAnnouncement?
    private(set) var estimatedStationAt: Date?
    private(set) var completedArrivalLocation: CLLocation?
    private var temporaryRoute: SharedRouteCoordinator.TemporaryRoute?
    var isRouteExpanded: Bool = false
    private var stationEvidence = JourneyStationEvidence()
    private let journeyArrivals = JourneyArrivalController()
    let schedule: HomeScheduleController
    let locationProvider: LocationProvider
    let savedRouteStore: SavedRouteStore
    let tripProgress: TripProgressStore
    let routePreferences: RoutePreferences
    private let refreshDepartures: () -> Void
    private let reloadWidgets: (String, Bool) -> Void
    private let displayedDepartures: () -> [Departure]
    private let isActive: () -> Bool

    init(schedule: HomeScheduleController, locationProvider: LocationProvider,
         savedRouteStore: SavedRouteStore, routePreferences: RoutePreferences,
         tripProgress: TripProgressStore,
         refreshDepartures: @escaping () -> Void,
         reloadWidgets: @escaping (String, Bool) -> Void,
         displayedDepartures: @escaping () -> [Departure],
         isActive: @escaping () -> Bool) {
        self.tripProgress = tripProgress
        self.refreshDepartures = refreshDepartures
        self.reloadWidgets = reloadWidgets
        self.displayedDepartures = displayedDepartures
        self.isActive = isActive
        self.schedule = schedule
        self.locationProvider = locationProvider
        self.savedRouteStore = savedRouteStore
        self.routePreferences = routePreferences
    }

    private var scheduleStore: PATCOScheduleStore { schedule.store }
    private var isViewingToday: Bool { schedule.isViewingToday }
    private var selectedScheduleDate: Date { schedule.selectedScheduleDate }
    private var departures: [Departure] { displayedDepartures() }
    private func requestWidgetReload(reason: String, force: Bool = false) { reloadWidgets(reason, force) }

    func selectedStation(_ id: Station.ID?) -> Station? {
        scheduleStore.stations.first { $0.id == id }
    }

    func applyDefaultsIfNeeded() {
        savedRouteStore.initializeDefaultRoutesIfNeeded(stations: scheduleStore.stations)
        if originId == nil {
            originId = savedOriginId()
                ?? station(named: "Lindenwold")?.id
                ?? scheduleStore.stations.first?.id
        }
        if destinationId == nil {
            destinationId = savedDestinationId()
                ?? scheduleStore.locust?.id
                ?? scheduleStore.stations.last?.id
        }
    }

    func applyNearestStation(_ location: CLLocation?) {
        // Planning a future day must not mutate the route based on today's location.
        guard isViewingToday else { return }
        publishAppRoute()
        guard let location else {
            stationEvidence.underground = UndergroundDepartureEvidence()
            clearExpiredStationSelection()
            if let revision = sharedRouteRevision {
                _ = SharedRouteCoordinator.checkArrival(expectedRevision: revision, location: nil, stations: scheduleStore.stations)
                _ = SharedRouteCoordinator.recoverReturnDirection(expectedRevision: revision, location: nil, stations: scheduleStore.stations)
            }
            currentStation = nil
            return
        }

        let nearbyStation = stationAtCurrentLocation(location)
        let station = stationEvidence.station(for: location, stations: scheduleStore.stations)
        if let nearbyStation, station == nil {
            ArrivalDiagnostics.record("Current station pending",
                detail: "\(nearbyStation.name): \(stationEvidence.precise.diagnosticDescription(for: location))")
        }
        SharedRouteCoordinator.observeDeparture(location: location, stations: scheduleStore.stations)
        // Arrival confirmation has its own uncertainty policy, independent of travel guidance.
        if completeDestinationArrivalIfNeeded(station: station, location: location) {
            return
        }
        if let revision = sharedRouteRevision,
           let recovered = SharedRouteCoordinator.recoverReturnDirection(expectedRevision: revision,
                location: location, stations: scheduleStore.stations),
           recovered.revision == revision + 1 {
            publishAppRoute()
            routePreferences.clearTemporary()
            routePreferences.clearManualStationSelection()
            routePreferences.saveJourneyDirection(destinationId: recovered.destinationId)
            locationProvider.endJourneyTracking()
            refreshDepartures()
            ArrivalDiagnostics.record("Return direction recovered", detail: "Reliable endpoint-side travel evidence; station arrival not confirmed or announced")
            requestWidgetReload(reason: "Return direction recovered", force: true)
            return
        }
        // Keep inferred departures separate from the strict destination-arrival path above.
        let journeyOrigin = temporaryRoute?.originId ?? originId
        let inferred = stationEvidence.inferredStation(for: location, stations: scheduleStore.stations,
            origin: journeyOrigin, destination: destinationId, reliableStation: station,
            journeyActive: locationProvider.journeyTrackingDeadline.map { $0 > Date() } == true)
        if let inferred, let inferredStation = selectedStation(inferred),
               routePreferences.manuallySelectedAtStationId() == nil {
                if inferred != originId {
                    useCurrentStationAsTemporaryOrigin(inferred, destinationId: destinationId, automatic: true)
                    if originId == inferred {
                        ArrivalDiagnostics.record("Temporary station estimated", detail: "\(inferredStation.name): repeated underground readings; destination arrival not confirmed",
                            context: .init(component: "app.station", journeyID: tripProgress.session?.key,
                                routeRevision: sharedRouteRevision, observationTimestamp: location.timestamp,
                                confidence: .estimated, decision: .accepted))
                    }
                }
                if originId == inferred {
                    estimatedStationAt = location.timestamp
                    currentStation = inferredStation
                    nearestRouteStationName = inferredStation.name
                    return
                }
        }
        // Duplicate callbacks must not dismiss a still-fresh inferred station.
        if station == nil, let estimatedStationAt,
           (0...15).contains(Date().timeIntervalSince(estimatedStationAt)),
           location.timestamp <= estimatedStationAt,
           let origin = selectedStation(originId),
           location.distance(from: origin.location) <= LocationGuidancePolicy.stationRadiusMeters {
            return
        }
        if station == nil { clearExpiredStationSelection() }
        estimatedStationAt = nil
        guard LocationGuidancePolicy.isUsable(location, maxAge: 30) else {
            let age = Date().timeIntervalSince(location.timestamp)
            let accuracy = String(format: "%.0f", location.horizontalAccuracy)
            ArrivalDiagnostics.record("GPS station guidance rejected", detail: "Age \(Int(age)) sec; accuracy \(accuracy) m; guidance requires age 0...30 sec and valid accuracy <=150 m. Strict station presence requires age <=15 sec and accuracy <=50 m. Underground station and destination estimates are evaluated separately.",
                context: .init(component: "app.station", journeyID: tripProgress.session?.key,
                    routeRevision: sharedRouteRevision, observationTimestamp: location.timestamp,
                    decision: .rejected, rejectionReason: "Reading outside station guidance age/accuracy limits"))
            currentStation = nil
            nearestRouteStationName = nil
            return
        }
        var departedArrivalStation = false
        if let completed = completedArrivalLocation,
           location.horizontalAccuracy > 0, location.horizontalAccuracy <= 150,
           location.distance(from: completed) - location.horizontalAccuracy > LocationGuidancePolicy.stationRadiusMeters {
            completedArrivalLocation = nil
            departedArrivalStation = true
        }
        let explicitTrip = selectedStation(destinationId).map {
            PATCOLiveActivityStarter.hasCurrentTrip(to: $0.name)
        } == true
        if isViewingToday, isActive(),
           SharedRouteCoordinator.current()?.journey?.suppressesAutomaticTracking(originId: originId, destinationId: destinationId) != true,
           originId != destinationId, originId != nil, destinationId != nil,
           JourneyTrackingPolicy.shouldBegin(atOrigin: nearbyStation?.id == originId,
               arrivalSuppressed: completedArrivalLocation != nil,
               departedArrivalStation: departedArrivalStation, explicitTrip: explicitTrip),
           (0...30).contains(Date().timeIntervalSince(location.timestamp)),
           location.horizontalAccuracy > 0, location.horizontalAccuracy <= 150 {
            locationProvider.beginJourneyTracking(stations: scheduleStore.stations)
        }
        if let station, currentStationId != station.id {
            ArrivalDiagnostics.record("Current station confirmed", detail: "\(station.name); inside station boundary, no stop required. Destination arrival is evaluated separately.",
                context: .init(component: "app.station", journeyID: tripProgress.session?.key,
                    routeRevision: sharedRouteRevision, observationTimestamp: location.timestamp,
                    confidence: .precise, decision: .accepted))
        }
        currentStation = station
        if let manuallySelectedAtStationId = routePreferences.manuallySelectedAtStationId() {
            if let selectedStation = selectedStation(manuallySelectedAtStationId),
               location.distance(from: selectedStation.location)
                <= StationTravelMode.atStationMeters + max(150, location.horizontalAccuracy) {
                currentStation = station
                nearestRouteStationName = selectedStation.name
                return
            }
            routePreferences.clearManualStationSelection()
        }

        if isUsingTemporaryStationRoute {
            if let temporaryOrigin = selectedStation(originId),
               LocationGuidancePolicy.hasLeftStation(location, station: temporaryOrigin.location) {
                restoreRouteAfterLeavingStation(departureLocation: location)
            } else {
                nearestRouteStationName = selectedStation(originId)?.name
                return
            }
        }

        if let station {
            nearestRouteStationName = station.name

            if station.id == originId, let destinationId {
                routePreferences.saveJourneyDirection(destinationId: destinationId)
            } else if station.id != destinationId {
                useCurrentStationAsTemporaryOrigin(
                    station.id,
                    destinationId: destinationId ?? routePreferences.journeyDestinationId(),
                    automatic: true
                )
            }
            return
        }

        // Nearest-station presentation must not change direction, including after automatic arrival.
        guard let routeEndpoints = savedRouteEndpoints(),
              routeEndpoints.origin != routeEndpoints.destination else {
            nearestRouteStationName = nil
            return
        }

        let routeStations = stationsBetween(routeEndpoints.origin, routeEndpoints.destination)
        let nearest = routeStations.min {
            $0.location.distance(from: location) < $1.location.distance(from: location)
        } ?? routeEndpoints.origin
        nearestRouteStationName = nearest.name
    }

    @discardableResult
    func completeDestinationArrivalIfNeeded(
        station: Station? = nil,
        location: CLLocation? = nil,
        expectedDestinationId: Station.ID? = nil
    ) -> Bool {
        guard isViewingToday,
              let location = location ?? locationProvider.currentLocation else {
            return false
        }
        let destinationId = expectedDestinationId
            ?? self.destinationId
            ?? routePreferences.journeyDestinationId()
        let session = tripProgress.session
        let expectedArrival = session?.isActive() == true
            && session?.destinationName == selectedStation(destinationId)?.name ? session?.arrival : nil
        guard self.destinationId == destinationId,
              let completion = journeyArrivals.evaluate(location: location, stations: scheduleStore.stations,
                station: station, destinationId: destinationId, revision: sharedRouteRevision,
                expectedArrival: expectedArrival, isViewingToday: isViewingToday) else { return false }
        presentDestinationArrival(completion)
        return true
    }

    private func presentDestinationArrival(_ completion: JourneyArrivalController.Completion) {
        let arrivalStation = completion.station
        let returnStation = completion.returnStation
        sharedRouteRevision = completion.route.revision

        if isUsingTemporaryStationRoute {
            temporaryRoute = nil
            routePreferences.clearTemporary()
        }
        routePreferences.clearManualStationSelection()
        originId = arrivalStation.id
        locationProvider.endJourneyTracking(reloadWidgets: false)
        completedArrivalLocation = arrivalStation.location
        self.destinationId = returnStation.id
        ArrivalDiagnostics.record("Arrival completed", detail: "\(arrivalStation.name); return route to \(returnStation.name)")
        routePreferences.saveJourneyDirection(destinationId: returnStation.id)
        nearestRouteStationName = arrivalStation.name
        refreshDepartures()
        requestWidgetReload(reason: "Journey arrived; return route ready", force: true)
        Task { await PATCOLiveActivityStarter.endActivities(arrivingAt: arrivalStation.name, tripProgress: tripProgress) }
        showArrivalAnnouncement(at: arrivalStation, returningTo: returnStation, inferredArrival: completion.inferred)
    }

    func confirmTripArrival(_ departure: Departure) {
        guard TripTrackingController.confirmArrival(departure: departure, locationProvider: locationProvider, tripProgress: tripProgress) != nil else { return }
        routePreferences.clearTemporary()
        routePreferences.clearManualStationSelection()
        routePreferences.saveJourneyDirection(destinationId: departure.origin.id)
        completedArrivalLocation = departure.destination.location
        publishAppRoute()
        refreshDepartures()
        requestWidgetReload(reason: "User confirmed trip arrival", force: true)
        showArrivalAnnouncement(at: departure.destination, returningTo: departure.origin)
    }

    func showArrivalAnnouncement(at arrivalStation: Station, returningTo returnStation: Station, inferredArrival: Bool = false) {
        let announcement = ArrivalAnnouncement(
            stationName: arrivalStation.name,
            returnStationName: returnStation.name,
            inferredArrival: inferredArrival
        )
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
            arrivalAnnouncement = announcement
        }

        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, arrivalAnnouncement?.id == announcement.id else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                arrivalAnnouncement = nil
            }
        }
    }

    private func savedRouteEndpoints() -> (origin: Station, destination: Station)? {
        if let savedRoute = routePreferences.savedRoute(),
           let savedOrigin = selectedStation(savedRoute.originId),
           let savedDestination = selectedStation(savedRoute.destinationId),
           savedOrigin != savedDestination {
            return (savedOrigin, savedDestination)
        }

        guard let currentOrigin = selectedStation(originId),
              let currentDestination = selectedStation(destinationId),
              currentOrigin != currentDestination else {
            return nil
        }

        return (currentOrigin, currentDestination)
    }

    private func stationsBetween(_ origin: Station, _ destination: Station) -> [Station] {
        guard let originIndex = scheduleStore.stations.firstIndex(of: origin),
              let destinationIndex = scheduleStore.stations.firstIndex(of: destination) else {
            return [origin, destination]
        }

        let bounds = min(originIndex, destinationIndex)...max(originIndex, destinationIndex)
        return Array(scheduleStore.stations[bounds])
    }

    func publishAppRoute() {
        tripProgress.synchronize()
        guard isViewingToday, let originId, let destinationId else { return }
        guard let route = SharedRouteCoordinator.routeForApp(defaultOriginId: originId,
                                                             defaultDestinationId: destinationId) else { return }
        locationProvider.reconcileSharedRoute(route, previousRevision: sharedRouteRevision)
        temporaryRoute = route.temporaryRoute
        if route.originId != originId || route.destinationId != destinationId {
            self.originId = route.originId
            self.destinationId = route.destinationId
        }
        let changed = sharedRouteRevision != route.revision
        if changed {
            if route.completesJourney {
                completedArrivalLocation = selectedStation(route.originId)?.location
                if let station = selectedStation(route.originId) {
                    tripProgress.complete(arrivingAt: station.name)
                    Task { await PATCOLiveActivityStarter.endActivities(arrivingAt: station.name, tripProgress: tripProgress) }
                }
            }
            if !route.event.isTemporary {
                stationEvidence.underground = UndergroundDepartureEvidence()
            }
            estimatedStationAt = nil
            stationEvidence.precise = CurrentStationEvidence()
            currentStation = nil
        }
        sharedRouteRevision = route.revision
        let diagnosticSpecialSchedule = scheduleStore.specialSchedule(on: departures.first?.serviceDate ?? selectedScheduleDate)
        SharedDiagnosticState.record(.app, origin: selectedStation(route.originId),
                                     destination: selectedStation(route.destinationId), revision: route.revision,
                                     location: locationProvider.currentLocation,
                                     appliedSpecialSchedules: diagnosticSpecialSchedule.map {
                                         ["\($0.title) (\($0.serviceDate.formatted(date: .abbreviated, time: .omitted)))"]
                                     } ?? [])
        if changed {
            SharedWidgetDiagnostics.record("App shared route", detail: "Revision \(route.revision): \(route.originId) to \(route.destinationId); \(route.reason)")
            requestWidgetReload(reason: "App route synchronized", force: true)
        }
    }

    func selectRoute(originId: Station.ID?, destinationId: Station.ID?, destinationOnly: Bool = false) {
        self.originId = originId
        self.destinationId = destinationId
        routeSelectionChanged(saveRoute: true, destinationOnly: destinationOnly)
    }

    func resetArrivalSuppression() { completedArrivalLocation = nil }

    private func routeSelectionChanged(saveRoute: Bool = false, destinationOnly: Bool = false) {
        if saveRoute {
            nearestStationMessage = nil
            if destinationOnly, let originalOrigin = temporaryRoute?.originId {
                originId = originalOrigin
            }
            clearTemporaryStationRoute()
            saveSelectedRoute()
            if let destinationId, originId != destinationId {
                routePreferences.saveJourneyDirection(destinationId: destinationId)
                if let location = locationProvider.currentLocation ?? SharedCurrentLocationCache.location(),
                   let station = stationAtCurrentLocation(location) {
                    routePreferences.saveManualStationSelection(stationId: station.id)
                } else {
                    routePreferences.clearManualStationSelection()
                }
            }
        }
        applyNearestStation(
            locationProvider.currentLocation ?? SharedCurrentLocationCache.location()
        )
    }

    var isUsingTemporaryStationRoute: Bool {
        temporaryRoute != nil
    }

    var savedStartingStationName: String {
        selectedStation(temporaryRoute?.originId)?.name ?? "saved starting location"
    }

    func useCurrentStationAsTemporaryOrigin(
        _ stationId: Station.ID,
        destinationId preferredDestinationId: Station.ID? = nil,
        automatic: Bool = false
    ) {
        publishAppRoute()
        guard let originId,
              let destinationId else {
            return
        }
        let temporaryDestinationId = preferredDestinationId ?? destinationId
        guard stationId != temporaryDestinationId else { return }

        if isViewingToday {
            guard let revision = sharedRouteRevision,
                  let route = SharedRouteCoordinator.selectStationDepartures(
                    expectedRevision: revision, originId: stationId, destinationId: temporaryDestinationId,
                    stations: scheduleStore.stations, selectionLocation: locationProvider.currentLocation,
                    automatic: automatic),
                  route.revision == revision + 1 else {
                refreshDepartures()
                return
            }
            sharedRouteRevision = route.revision
        }

        temporaryRoute = .init(originId: originId, destinationId: destinationId, manual: !automatic)
        self.originId = stationId
        self.destinationId = temporaryDestinationId
        routePreferences.saveTemporary(originId: stationId, destinationId: temporaryDestinationId)
        refreshDepartures()
        requestWidgetReload(reason: "Temporary station route changed", force: true)
        isRouteExpanded = false
    }

    func restoreRouteAfterLeavingStation(departureLocation: CLLocation? = nil) {
        guard let originalOriginId = temporaryRoute?.originId,
              let originalDestinationId = temporaryRoute?.destinationId else {
            return
        }

        if isViewingToday {
            guard let revision = sharedRouteRevision,
                  let route = SharedRouteCoordinator.restoreStationRoute(expectedRevision: revision,
                    departureLocation: departureLocation, requireDeparture: departureLocation != nil,
                    stations: scheduleStore.stations),
                  route.revision == revision + 1 else {
                publishAppRoute()
                return
            }
            sharedRouteRevision = route.revision
        }

        clearTemporaryStationRoute()
        originId = originalOriginId
        destinationId = originalDestinationId
        refreshDepartures()
    }

    func clearExpiredStationSelection() {
        estimatedStationAt = nil
        currentStation = nil
        nearestRouteStationName = nil
        stationEvidence.precise = CurrentStationEvidence()
        // Expiring a temporary selection is not evidence of physical departure or arrival.
        // Use the revision-checked restoration path to preserve saved endpoints and newer choices.
        if isViewingToday, isUsingTemporaryStationRoute {
            restoreRouteAfterLeavingStation()
        }
    }

    func clearTemporaryStationRoute() {
        let hadTemporaryRoute = isUsingTemporaryStationRoute || routePreferences.temporaryRoute() != nil
        temporaryRoute = nil
        routePreferences.clearTemporary()
        if hadTemporaryRoute {
            requestWidgetReload(reason: "Temporary station route cleared", force: true)
        }
    }

    func stationAtCurrentLocation(_ location: CLLocation) -> Station? {
        LocationGuidancePolicy.detectedStation(location, stations: scheduleStore.stations)
    }

    private func saveSelectedRoute() {
        guard let originId, let destinationId, originId != destinationId else {
            return
        }

        let previousRevision = SharedRouteCoordinator.current()?.revision
        routePreferences.clearJourneyDirection()
        routePreferences.save(originId: originId, destinationId: destinationId,
                                 selectionLocation: locationProvider.currentLocation ?? SharedCurrentLocationCache.location(),
                                 destinationLocation: selectedStation(destinationId)?.location)
        if let route = SharedRouteCoordinator.current() {
            locationProvider.reconcileSharedRoute(route, previousRevision: previousRevision)
            sharedRouteRevision = route.revision
        }
        tripProgress.synchronize()
        Task { await PATCOLiveActivityStarter.endExpiredActivities(tripProgress: tripProgress) }
        requestWidgetReload(reason: "Saved route changed", force: true)
    }

    private func savedOriginId() -> Station.ID? {
        guard let originId = routePreferences.savedRoute()?.originId,
              selectedStation(originId) != nil else {
            return nil
        }

        return originId
    }

    private func savedDestinationId() -> Station.ID? {
        guard let destinationId = routePreferences.savedRoute()?.destinationId,
              selectedStation(destinationId) != nil else {
            return nil
        }

        return destinationId
    }

    private func station(named name: String) -> Station? {
        scheduleStore.stations.first { $0.name == name }
    }

    func swapStations(saveRoute: Bool = false) {
        let oldOrigin = originId
        originId = destinationId
        destinationId = oldOrigin
        routeSelectionChanged(saveRoute: saveRoute)
    }
}
