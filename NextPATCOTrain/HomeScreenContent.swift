import ActivityKit
import CoreLocation
import SwiftUI

struct HomeScreenContent: View {
    @Bindable var model: HomeScreenModel

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color.patcoWine, Color.patcoCharcoal, Color.patcoRail], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                ScrollView {
                  VStack(spacing: 10) {
                    header
                        .padding(.top, 2)
                    liveTripShortcut
                    if model.route.currentStationName != nil {
                        currentStationPanel
                    }
                    if let arrivalAnnouncement = model.route.arrivalAnnouncement {
                        arrivalAnnouncementBanner(arrivalAnnouncement)
                            .transition(.opacity)
                    }
                    statusBanners
                    if !model.visibleAlerts.isEmpty {
                        alertBox
                    }
                    HomeDeparturesSection(model: model)
                }
                .padding()
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollIndicators(.visible)
                .refreshable {
                    await model.refreshAll(forceSpecialScheduleRefresh: true)
                }

            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        VStack(spacing: 2) {
                            HStack(spacing: 4) {
                                Image(systemName: "tram.fill")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.patcoGold)

                                Text("Next")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.white)

                                Text("PATCO Train")
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)

                            Capsule()
                                .fill(Color.patcoGold.opacity(0.82))
                                .frame(height: 1)
                        }
                        .frame(width: 220)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Next PATCO Train")
                        .accessibilityAddTraits(.isHeader)

                        if !model.hidesPromotionalDates {
                            Button {
                                model.schedule.draftScheduleDate = model.schedule.selectedScheduleDate
                                model.isShowingScheduleDatePicker = true
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "calendar")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.patcoGold)

                                    Text(model.schedule.selectedScheduleDateHeaderText)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)

                                    Image(systemName: "chevron.down")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white.opacity(0.78))
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 34)
                                .background(.white.opacity(0.15), in: Capsule())
                                .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .frame(minHeight: 44)
                            .accessibilityLabel("Choose departure date, \(model.schedule.selectedScheduleDateHeaderText)")
                        }
                    }
                    .offset(y: 2)
                }

                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarTrailing) {
                        informationButton
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        informationButton
                    }
                }
            }
            .sheet(item: $model.selectedDeparture) { departure in
                TripDetailView(departure: departure, stops: model.tripStops(for: departure),
                    locationProvider: model.locationProvider, tripProgress: model.tripProgress,
                    catchStatusAt: { date in
                    model.reachability.catchStatus(for: departure, at: date)
                }, onArrived: { model.route.confirmTripArrival(departure) }) {
                    model.selectedDeparture = nil
                }
                .presentationDetents([.large])
            }
            .sheet(isPresented: $model.isShowingScheduleDatePicker) {
                scheduleDatePickerSheet
            }
            .sheet(isPresented: $model.isShowingAbout) {
                AboutView(
                    savedRouteStore: model.savedRouteStore,
                    stations: model.schedule.store.stations,
                    locationAuthorizationStatus: model.locationProvider.authorizationStatus,
                    scheduleFeedEndDate: model.schedule.store.scheduleFeedEndDate,
                    scheduleFeedVersion: model.schedule.store.scheduleFeedVersion,
                    scheduleFeedLastCheckedAt: model.schedule.store.scheduleFeedLastCheckedAt,
                    scheduleFeedLastUpdatedAt: model.schedule.store.scheduleFeedLastUpdatedAt,
                    scheduleFeedPreviousVersion: model.schedule.store.scheduleFeedPreviousVersion,
                    onRequestLocation: model.requestLocationAccess,
                    onReloadSchedule: model.forceGTFSUpdate,
                    onOpenURL: { url in
                        model.isShowingAbout = false
                        model.inAppBrowserURL = BrowserURL(url: url)
                    }
                )
                    .presentationDetents([.fraction(0.75)])
            }
            .sheet(item: $model.inAppBrowserURL) { browserURL in
                SafariView(url: browserURL.url)
                    .ignoresSafeArea()
                    .interactiveDismissDisabled()
                    .presentationDragIndicator(.hidden)
            }
        }
    }

    private var header: some View {
        HomeRouteHeader(savedRouteStore: model.savedRouteStore, stations: model.schedule.store.stations,
            originId: model.route.originId, destinationId: model.route.destinationId, isRouteExpanded: $model.route.isRouteExpanded,
            routeSummary: model.routeSummary, routeDetailSummary: model.routeDetailSummary,
            currentStationName: model.route.currentStationName,
            reverseRoute: { model.route.swapStations(saveRoute: true) },
            selectRoute: { model.route.selectRoute(originId: $0, destinationId: $1, destinationOnly: $2) }) {
                locationControl
            }
    }

    private var informationButton: some View {
        Button {
            model.isShowingAbout = true
        } label: {
            Image(systemName: "info.circle")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.patcoGold)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.14), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Information about Next PATCO Train")
    }

    @ViewBuilder
    private var currentStationPanel: some View {
        // Retain temporary station departures even when a poor fix clears confirmation.
        if let station = model.route.selectedStation(model.route.isUsingTemporaryStationRoute ? model.route.originId : model.route.currentStationId),
           model.route.isUsingTemporaryStationRoute || station.id != model.route.originId {
            HomeStationPanel(station: station, isEstimated: model.route.estimatedStationAt != nil,
                isUsingTemporaryStationRoute: model.route.isUsingTemporaryStationRoute,
                originId: model.route.originId, destinationId: model.route.destinationId,
                originStation: model.route.selectedStation(model.route.originId), savedStartingStationName: model.route.savedStartingStationName,
                refresh: { Task { await model.refreshAll() } },
                restoreSavedRoute: {
                    model.routePreferences.saveManualStationSelection(stationId: station.id)
                    model.route.restoreRouteAfterLeavingStation()
                },
                showStationDepartures: {
                    model.route.useCurrentStationAsTemporaryOrigin(station.id, destinationId: $0)
                })
        }
    }

    private var locationControl: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    await model.findNearestStation()
                }
            } label: {
                Group {
                    if model.isFindingNearestStation { ProgressView().tint(Color.patcoCharcoal) }
                    else { Image(systemName: "location.fill").font(.subheadline) }
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.patcoGold)
            .foregroundStyle(Color.patcoCharcoal)
            .accessibilityLabel("Find nearest station")
            .disabled(model.isFindingNearestStation || !model.schedule.isViewingToday)

            locationSummary

            Spacer(minLength: 8)
        }
    }

    @ViewBuilder
    private var locationSummary: some View {
        if let nearestStationMessage = model.route.nearestStationMessage {
            Text(nearestStationMessage)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.78))
        } else if let nearestRouteStationName = model.route.nearestRouteStationName {
            VStack(alignment: .leading, spacing: 2) {
                Label("Nearest route station: \(nearestRouteStationName)", systemImage: "mappin.and.ellipse")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)

                Text("Route direction is based on nearest route station")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
            }
        } else if let currentStationName = model.route.currentStationName {
            VStack(alignment: .leading, spacing: 2) {
                Label("Current station: \(currentStationName)", systemImage: "mappin.and.ellipse")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)

                Text("Pick a route to orient departures")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
            }
        } else if let message = model.locationProvider.errorMessage {
            Label(message, systemImage: "location.slash")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
        } else {
            Text("Use current location")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var statusBanners: some View {
        if let selectedSpecialSchedule = model.schedule.store.specialSchedule(on: model.departures.first?.serviceDate ?? model.schedule.selectedScheduleDate) {
            specialScheduleBanner(selectedSpecialSchedule)
        }
    }

    private func specialScheduleBanner(_ schedule: ActiveSpecialSchedule) -> some View {
        HomeSpecialScheduleBanner(schedule: schedule, patcoCalendar: model.schedule.patcoCalendar) {
            model.inAppBrowserURL = BrowserURL(url: $0)
        }
    }

    private var alertBox: some View {
        HomeAlertsView(visibleAlerts: model.visibleAlerts, isLoading: model.alertProvider.isLoading,
            lastUpdated: model.alertProvider.lastUpdated, refresh: { model.alertProvider.refresh(force: true) })
    }

    private var scheduleDatePickerSheet: some View {
        @Bindable var schedule = model.schedule
        return HomeScheduleDatePicker(selectedScheduleDate: $schedule.selectedScheduleDate,
            draftScheduleDate: $schedule.draftScheduleDate, patcoCalendar: schedule.patcoCalendar,
            lastSelectableScheduleDate: schedule.lastSelectableScheduleDate)
    }

    private func arrivalAnnouncementBanner(_ announcement: ArrivalAnnouncement) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.uturn.backward")
                .font(.title3.weight(.heavy))
                .foregroundStyle(Color.patcoCharcoal)
                .frame(width: 40, height: 40)
                .background(Color.patcoGold, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("\(announcement.inferredArrival ? "Estimated arrival at" : "At") \(announcement.stationName)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text("Return departures to \(announcement.returnStationName) shown.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.80))
                    .lineLimit(2)
            }

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    model.route.arrivalAnnouncement = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.80))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss arrival confirmation")
        }
        .padding(12)
        .background(Color.patcoCharcoal.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.patcoGold.opacity(0.58), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.24), radius: 10, y: 5)
        .accessibilityElement(children: .combine)
    }

    private var liveTripShortcut: some View {
        let _ = model.liveTripRevision
        return LiveTimeline(interval: 30) { now in
            let activity = PATCOLiveActivityStarter.currentTripActivity(now: now)
            let session = SharedRouteCoordinator.current()?.journey.flatMap { $0.isActive(at: now) ? $0 : nil }
            if let arrival = session?.arrival ?? activity?.content.state.arrivalDate,
               let url = URL(string: session?.deepLink ?? activity?.attributes.deepLinkURLString ?? "") {
                    Button {
                        model.handleDeepLink(url)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "tram.fill")
                                .foregroundStyle(Color.patcoGold)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Your trip").font(.headline)
                                Text(session.map { "\($0.originName) to \($0.destinationName)" } ?? activity?.attributes.routeTitle ?? "Your trip")
                                    .font(.subheadline)
                                    .multilineTextAlignment(.leading)
                                Text("Scheduled arrival \(PATCOClock.timeText(arrival, relativeTo: now))")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                        }
                        .foregroundStyle(.white)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                .task(id: activity?.id) {
                    guard let activity else { return }
                    for await _ in activity.activityStateUpdates {
                        guard !Task.isCancelled else { return }
                        model.liveTripRevision += 1
                    }
                }
            }
        }
    }

}
