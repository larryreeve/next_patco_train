import MapKit
import SwiftUI

struct TripRouteMap: View {
    let presentation: TripDetailPresentation
    let location: CLLocation?
    @State private var cameraPosition: MapCameraPosition
    private var departure: Departure { presentation.departure }
    private var stops: [TripDetailStop] { presentation.stops }

    init(presentation: TripDetailPresentation, location: CLLocation?) {
        self.presentation = presentation
        self.location = location
        _cameraPosition = State(initialValue: .region(Self.region(for: presentation.stops.map(\.station.coordinate))))
    }

    private var estimatedSpeed: some View {
        LiveTimeline(interval: 5) { now in
            if presentation.hasTripProgress, presentation.session?.isActive(at: now) == true,
                TripSpeedPresentation.isDuringTrip(
                    departure: departure.departureDate,
                    arrival: departure.arrivalDate, now: now),
                !departure.isRemovedBySpecialSchedule
            {
                let position = presentation.progress.mapPosition(
                    stations: stops.map(\.station), geometry: PATCOTrackGeometry.bundled, now: now)
                let freshLocation = position?.isFreshGPS == true
                Group {
                    if !freshLocation {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Live location unavailable")
                                Text(
                                    position == nil ? "Waiting for a reliable location" : "Showing last known position"
                                )
                                .font(.caption)
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.65))
                            }
                        } icon: {
                            Image(systemName: "location.slash")
                        }
                    } else if let location = location,
                        let speed = TripSpeedPresentation.milesPerHour(location, now: now),
                        PATCOTrackGeometry.bundled?.isNearTrack(location) == true
                    {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Route map")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.patcoCharcoal)
                Spacer()
                if isTrackingMap {
                    Button {
                        updateTrackingCamera(force: true)
                    } label: {
                        Image(systemName: cameraPosition.positionedByUser ? "location" : "location.fill")
                            .frame(width: 44, height: 44)
                    }
                    .tint(Color.patcoWine)
                    .accessibilityLabel("Follow train")
                    .accessibilityIdentifier("trip.follow")
                    .accessibilityValue(cameraPosition.positionedByUser ? "Paused" : "Following")
                    .help("Follow train")
                }
            }

            estimatedSpeed

            LiveTimeline(interval: 5) { now in
                Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                    if routeCoordinates.count > 1 {
                        MapPolyline(coordinates: routeCoordinates)
                            .stroke(Color.patcoWine, lineWidth: 4)
                    }

                    ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                        Annotation(
                            isTrackingMap && trackingStationIndices.contains(index)
                                ? stop.station.name
                                : index == 0 ? "Start" : index == stops.count - 1 ? "Destination" : "",
                            coordinate: stop.station.coordinate,
                            anchor: index == 0 || index == stops.count - 1 ? .bottom : .center
                        ) {
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
                                    .fill(
                                        presentation.detectedStationIds.contains(stop.station.id)
                                            ? Color.patcoWine
                                            : presentation.completedStationIds.contains(stop.station.id)
                                                ? Color.patcoWine.opacity(0.25) : Color.white
                                    )
                                    .frame(width: isTrackingMap ? 12 : 7, height: isTrackingMap ? 12 : 7)
                                    .overlay(
                                        Circle().stroke(
                                            Color.patcoWine,
                                            style: StrokeStyle(
                                                lineWidth: 1.5,
                                                dash: presentation.completedStationIds.contains(stop.station.id)
                                                    && !presentation.detectedStationIds.contains(stop.station.id)
                                                    ? [2, 2] : []))
                                    )
                                    .accessibilityLabel(
                                        "\(stop.station.name), \(presentation.detectedStationIds.contains(stop.station.id) ? "detected" : presentation.completedStationIds.contains(stop.station.id) ? "passed, inferred from route position" : "not detected")"
                                    )
                            }
                        }
                    }
                    if presentation.hasTripProgress, presentation.session?.isActive(at: now) == true,
                        let position = presentation.progress.mapPosition(
                            stations: stops.map(\.station), geometry: PATCOTrackGeometry.bundled, now: now)
                    {
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
                .onAppear { updateTrackingCamera() }
                .onChange(of: presentation.progress) { _, _ in updateTrackingCamera() }
                .onChange(of: presentation.session) { _, _ in updateTrackingCamera() }
            }
        }
    }

    private var isTrackingMap: Bool {
        presentation.hasTripProgress && presentation.session?.isActive() == true
    }

    private var trackingStationIndices: [Int] {
        TripMapFocus.stationIndices(
            stations: stops.map(\.station), completedIds: presentation.completedStationIds,
            position: presentation.progress.mapPosition(
                stations: stops.map(\.station),
                geometry: PATCOTrackGeometry.bundled)?.coordinate)
    }

    private func updateTrackingCamera(force: Bool = false) {
        guard force || !cameraPosition.positionedByUser else { return }
        guard isTrackingMap else {
            cameraPosition = .region(Self.region(for: stops.map(\.station.coordinate)))
            return
        }
        var coordinates = trackingStationIndices.map { stops[$0].station.coordinate }
        if let position = presentation.progress.mapPosition(
            stations: stops.map(\.station), geometry: PATCOTrackGeometry.bundled)
        {
            coordinates.append(position.coordinate)
        }
        cameraPosition = .region(Self.region(for: coordinates, tracking: true))
    }

    private var routeCoordinates: [CLLocationCoordinate2D] {
        let track =
            PATCOTrackGeometry.bundled?.route(from: departure.origin.location, to: departure.destination.location) ?? []
        return track.isEmpty ? stops.map(\.station.coordinate) : track
    }

    private static func region(for coordinates: [CLLocationCoordinate2D], tracking: Bool = false) -> MKCoordinateRegion
    {
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
        let latitudeDelta = max(tracking ? 0.006 : 0.025, (maxLatitude - minLatitude) * 1.65)
        let longitudeDelta = max(tracking ? 0.008 : 0.025, (maxLongitude - minLongitude) * 1.65)

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }
}
