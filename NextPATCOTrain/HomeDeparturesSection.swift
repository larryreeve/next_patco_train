import SwiftUI

struct HomeDeparturesSection: View {
    @Bindable var model: HomeScreenModel

    private func departuresHeader(at now: Date) -> some View {
        HomeDeparturesHeader(scheduleFeedLastCheckedAt: model.schedule.store.scheduleFeedLastCheckedAt,
            currentReachabilityMode: model.reachability.currentReachabilityMode(at: now),
            reachabilityGuidance: model.reachability.reachabilityGuidance(at: now),
            isUsingTemporaryStationRoute: model.route.isUsingTemporaryStationRoute,
            isAtDepartureStation: model.reachability.isAtDepartureStation(at: now),
            locationTimestamp: model.reachabilityLocation?.timestamp,
            locationFreshness: model.reachabilityLocation.map { model.locationFreshnessText(for: $0.timestamp) },
            isRefreshInProgress: model.isRefreshInProgress,
            canOpenDirections: model.locationProvider.currentLocation != nil && model.route.selectedStation(model.route.originId) != nil,
            isManualMode: model.route.originId.map { SharedReachabilityModeStore.isManual(originId: $0) } ?? false,
            openDirections: {
                if let origin = model.route.selectedStation(model.route.originId) {
                    model.openDirections(to: origin, mode: model.reachability.currentReachabilityMode ?? .walking)
                }
            },
            refresh: { Task { await model.refreshAll(forceSpecialScheduleRefresh: true) } },
            selectMode: model.setReachabilityMode,
            useAutomaticMode: {
                guard let originId = model.route.originId else { return }
                SharedReachabilityModeStore.useAutomatic(originId: originId)
                model.refreshReachabilityModeSelection()
            })
    }

    var body: some View {
        let now = Date()
        let departures = model.reachability.visibleDepartures(at: now)
        let reachabilityGuidance = model.reachability.reachabilityGuidance(at: now)
        let currentReachabilityMode = model.reachability.currentReachabilityMode(at: now)
        return VStack(alignment: .leading, spacing: 8) {
            departuresHeader(at: now)

            if !model.schedule.isViewingToday {
                Text(model.schedule.isCheckingFutureSpecialSchedule
                     ? "Checking for a special schedule..."
                     : model.schedule.futureSpecialScheduleCheckFailed
                        ? "Could not check for a special schedule. Check PATCO before traveling."
                        : "Future times may change. Check PATCO before traveling.")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.52))
            }

            if let reachabilityGuidance {
                if model.route.isUsingTemporaryStationRoute {
                    Label(reachabilityGuidance.title, systemImage: reachabilityGuidance.systemImage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(red: 0.05, green: 0.38, blue: 0.20))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 0.72, green: 0.92, blue: 0.78).opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                } else if currentReachabilityMode == nil {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(reachabilityGuidance.title, systemImage: reachabilityGuidance.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.patcoCharcoal.opacity(0.74))

                        if let detail = reachabilityGuidance.detail {
                            Text(detail)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.70))
                        }

                        if let reachabilityLocation = model.reachabilityLocation,
                           Date().timeIntervalSince(reachabilityLocation.timestamp) > 2 * 60 {
                            Text(model.locationFreshnessText(for: reachabilityLocation.timestamp))
                                .font(.caption2)
                                .foregroundStyle(Color.patcoCharcoal.opacity(0.58))
                        }
                    }
                }
            } else if let reachabilityUnavailableMessage = model.reachability.reachabilityUnavailableMessage {
                VStack(alignment: .leading, spacing: 7) {
                    Label(reachabilityUnavailableMessage, systemImage: "location")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.patcoCharcoal.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)

                    if model.locationProvider.authorizationStatus != .authorizedAlways
                        && model.locationProvider.authorizationStatus != .authorizedWhenInUse {
                        Button(model.reachability.reachabilityLocationActionTitle) {
                            model.performReachabilityLocationAction()
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(Color.patcoWine)
                    }
                }
            }

            if let error = model.schedule.store.loadError {
                ContentUnavailableView {
                    Label("Schedule unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    scheduleRefreshButton
                }
            } else if model.schedule.store.feed?.isExpired() == true {
                ContentUnavailableView {
                    Label("Schedule update needed", systemImage: "calendar.badge.exclamationmark")
                } description: {
                    Text("The current PATCO schedule has expired and an updated schedule could not be downloaded.")
                } actions: {
                    scheduleRefreshButton
                }
            } else if departures.isEmpty {
                ContentUnavailableView {
                    Label("No departures found", systemImage: "tram")
                } description: {
                    Text(model.schedule.isViewingToday
                         ? "Try the opposite direction or choose a different station pair."
                         : "No scheduled service for this date and route. Try another date or reverse the route.")
                } actions: {
                    Button("Reverse Route") {
                        model.route.swapStations(saveRoute: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.patcoWine)
                }
            } else {
                departureRows(at: now)
            }
        }
        .padding(16)
        .background(Color.patcoCream.opacity(0.95), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.patcoGold.opacity(0.5), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func departureRows(at now: Date) -> some View {
        // The cached list can outlive a departure between its 30-second refreshes.
        let departures = model.reachability.visibleDepartures(at: now)
        let statuses = departures.map { model.reachability.listCatchStatus(for: $0, at: now) }
        let earlierCount = EarlierDeparturesPolicy.collapsibleCount(
            unreachable: statuses.map { status -> Bool? in
                guard let status else { return nil }
                switch status {
                case .probablyMissed, .tooLate: return true
                case .atStation, .comfortable, .tight: return false
                }
            },
            hasReliableEstimate: model.reachability.hasReliableDepartureEstimate(at: now)
        )
        let lastGuidedIndex = statuses.lastIndex { $0 != nil }
        let laterStartIndex = departures.indices.first { index in
            departures[index].departureDate.timeIntervalSince(now) > 60 * 60
                && index > (lastGuidedIndex ?? -1)
        }
        let firstLikelyDepartureID = departures.indices.first {
            statuses[$0]?.isLikelyToCatch == true
        }.map { departures[$0].id }

        return LazyVStack(spacing: 7) {
            if earlierCount > 0 {
                Rectangle()
                    .fill(Color.patcoCharcoal.opacity(0.16))
                    .frame(height: 1)
                    .accessibilityHidden(true)
                Button {
                    model.showsEarlierDepartures.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text(earlierCount == 1 ? "1 earlier train · unlikely to catch" : "\(earlierCount) earlier trains · unlikely to catch")
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                        Image(systemName: model.showsEarlierDepartures ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.58))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(model.showsEarlierDepartures ? "Expanded" : "Collapsed")
                .accessibilityHint(model.showsEarlierDepartures ? "Hide earlier trains you likely can't catch" : "Show earlier trains you likely can't catch")
            }
            ForEach(departures.indices, id: \.self) { index in
                if index >= earlierCount || model.showsEarlierDepartures {
                    let departure = departures[index]
                    if index == laterStartIndex, index > 0 {
                        laterDeparturesDivider
                    }
                    let catchStatus = statuses[index]
                    DepartureRow(
                        departure: departure,
                        catchStatus: catchStatus,
                        hidesDayLabel: model.hidesPromotionalDates || !model.schedule.isViewingToday,
                        showsCountdown: model.schedule.isViewingToday,
                        showsLeaveCountdown: catchStatus?.leaveByText != nil,
                        isPrimaryLikelyDeparture: departure.id == firstLikelyDepartureID,
                        onSelect: {
                            model.selectedDeparture = departure
                        }
                    )
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var laterDeparturesDivider: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.patcoCharcoal.opacity(0.14))
                .frame(height: 1)
            Text("Later departures")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.patcoCharcoal.opacity(0.58))
                .lineLimit(1)
            Rectangle()
                .fill(Color.patcoCharcoal.opacity(0.14))
                .frame(height: 1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Later departures")
    }

    private var scheduleRefreshButton: some View {
        VStack(spacing: 8) {
            Button {
                Task {
                    model.schedule.isScheduleRecoveryRefreshing = true
                    model.schedule.scheduleRecoveryMessage = await model.forceGTFSUpdate { _ in }
                    model.schedule.isScheduleRecoveryRefreshing = false
                }
            } label: {
                if model.schedule.isScheduleRecoveryRefreshing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Refreshing Schedule...")
                    }
                } else {
                    Text("Refresh Schedule")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.patcoWine)
            .disabled(model.schedule.isScheduleRecoveryRefreshing)

            if let scheduleRecoveryMessage = model.schedule.scheduleRecoveryMessage {
                Text(scheduleRecoveryMessage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.patcoCharcoal.opacity(0.66))
                    .multilineTextAlignment(.center)
            }
        }
    }

}
