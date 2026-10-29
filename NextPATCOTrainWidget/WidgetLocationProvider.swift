import ActivityKit
import CoreLocation
import MapKit
import SwiftUI
import WidgetKit
import AppIntents

@MainActor
final class WidgetLocationProvider: NSObject, CLLocationManagerDelegate {
    private static var pendingLocations: [Bool: Task<CLLocation?, Never>] = [:]
    private let manager = CLLocationManager()
    private let allowsCachedFallback: Bool
    private let requestStartedAt = Date()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var fallbackLocation: CLLocation?
    private var failureReason = "No usable fix"

    init(allowsCachedFallback: Bool) {
        self.allowsCachedFallback = allowsCachedFallback
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    static func currentLocation(
        allowsCachedFallback: Bool = true,
        diagnosticRunID: UUID? = nil
    ) async -> CLLocation? {
        guard WidgetReachabilitySettings.isEnabled else { return nil }
        let allowsFallback = allowsCachedFallback && !SharedCurrentLocationCache.freshLocationRequired
        if let pending = pendingLocations[allowsFallback] { return await pending.value }
        let task = Task { @MainActor in
            await requestSharedLocation(allowsCachedFallback: allowsFallback,
                manual: !allowsCachedFallback, diagnosticRunID: diagnosticRunID)
        }
        pendingLocations[allowsFallback] = task
        defer { pendingLocations[allowsFallback] = nil }
        return await task.value
    }

    private static func requestSharedLocation(allowsCachedFallback: Bool,
                                              manual: Bool,
                                              diagnosticRunID: UUID?) async -> CLLocation? {
        guard WidgetReachabilitySettings.isEnabled else { return nil }
        let startedAt = Date()
        let effectiveAllowsCachedFallback = allowsCachedFallback
            && !SharedCurrentLocationCache.freshLocationRequired
        let cachedLocation = effectiveAllowsCachedFallback
            ? SharedCurrentLocationCache.location(maxAge: 15 * 60)
            : nil
        let provider = WidgetLocationProvider(allowsCachedFallback: effectiveAllowsCachedFallback)
        guard provider.manager.authorizationStatus == .authorizedAlways
                || provider.manager.authorizationStatus == .authorizedWhenInUse else {
            SharedCurrentLocationCache.clear()
            WidgetRefreshState.recordLocationOutcome(available: false)
            return nil
        }
        if let cachedLocation, LocationGuidancePolicy.isUsable(cachedLocation, now: startedAt) {
            WidgetRefreshState.recordLocationOutcome(available: true)
            if let diagnosticRunID {
                let age = Int(startedAt.timeIntervalSince(cachedLocation.timestamp))
                SharedWidgetDiagnostics.recordLocation(
                    "Reused recent shared location (\(age) sec old)",
                    duration: Date().timeIntervalSince(startedAt),
                    for: diagnosticRunID
                )
            }
            return cachedLocation
        }
        let attemptDefaults = UserDefaults(suiteName: "group.com.rhome.patconext")
        let attemptKey = "widgetLocationLastAttemptAt"
        let lastAttempt = attemptDefaults?.object(forKey: attemptKey) as? Date
        let lastSuccessfulLocation = cachedLocation.flatMap {
            LocationGuidancePolicy.isUsable($0, now: $0.timestamp) ? $0.timestamp : nil
        }
        guard WidgetTimelinePolicy.shouldAttemptLocation(lastAttempt: lastAttempt, now: startedAt,
                                                        manual: manual, lastSuccessfulLocation: lastSuccessfulLocation) else {
            WidgetRefreshState.recordLocationOutcome(available: false)
            if let diagnosticRunID {
                SharedWidgetDiagnostics.recordLocation("Automatic GPS retry deferred; using cached location",
                    duration: Date().timeIntervalSince(startedAt), for: diagnosticRunID)
            }
            return cachedLocation
        }
        attemptDefaults?.set(startedAt, forKey: attemptKey)
        let requestedLocation = await provider.requestLocation()
        WidgetRefreshState.recordLocationOutcome(available: requestedLocation.map {
            LocationGuidancePolicy.isUsable($0, maxAge: 180)
        } ?? false)
        guard provider.manager.authorizationStatus == .authorizedAlways
                || provider.manager.authorizationStatus == .authorizedWhenInUse else {
            SharedCurrentLocationCache.clear()
            return nil
        }
        let bestLocation = [requestedLocation, cachedLocation]
            .compactMap { $0 }
            .max { $0.timestamp < $1.timestamp }
        if let bestLocation {
            SharedCurrentLocationCache.save(bestLocation)
        }
        if let diagnosticRunID {
            let outcome: String
            if let bestLocation {
                let age = max(0, Int(Date().timeIntervalSince(bestLocation.timestamp)))
                outcome = age <= 2 && bestLocation.timestamp >= startedAt.addingTimeInterval(-1)
                    ? "Fresh location"
                    : "Older location (\(age) sec old)"
            } else {
                outcome = provider.failureReason
            }
            SharedWidgetDiagnostics.recordLocation(
                outcome,
                duration: Date().timeIntervalSince(startedAt),
                for: diagnosticRunID
            )
        }
        return bestLocation
    }

    private func requestLocation() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.fallbackLocation = self.allowsCachedFallback
                ? usableFallback(from: manager.location)
                : nil
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await MainActor.run {
                    self?.failureReason = "Timed out"
                    self?.finish(with: self?.fallbackLocation)
                }
            }

            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                manager.startUpdatingLocation()
            case .denied, .restricted:
                failureReason = "Location access denied"
                finish(with: nil)
            @unknown default:
                failureReason = "Location access unavailable"
                finish(with: nil)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            switch self.manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                if self.continuation != nil { self.manager.startUpdatingLocation() }
            case .denied, .restricted:
                failureReason = "Location access denied"
                finish(with: nil)
            case .notDetermined:
                break
            @unknown default:
                failureReason = "Location access unavailable"
                finish(with: nil)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard continuation != nil else { return }
            let freshLocation = locations
                .filter { location in
                    LocationGuidancePolicy.isUsable(location)
                        && (allowsCachedFallback || location.timestamp >= requestStartedAt.addingTimeInterval(-1))
                }
                .max { $0.timestamp < $1.timestamp }
            if let freshLocation {
                finish(with: freshLocation)
                return
            }

            // A manual request may retain a new imprecise fix, but never an old cached one.
            let candidates = locations.filter {
                $0.horizontalAccuracy > 0 && $0.horizontalAccuracy <= 1_000
                    && (0...120).contains(Date().timeIntervalSince($0.timestamp))
                    && (allowsCachedFallback || $0.timestamp >= requestStartedAt.addingTimeInterval(-1))
            }
            fallbackLocation = ([fallbackLocation].compactMap { $0 } + candidates)
                .max { $0.timestamp < $1.timestamp }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            guard continuation != nil else { return }
            if (error as? CLError)?.code == .locationUnknown {
                failureReason = "Location temporarily unavailable"
                return
            }
            failureReason = "Core Location error"
            finish(with: fallbackLocation)
        }
    }

    private func usableFallback(from location: CLLocation?) -> CLLocation? {
        guard allowsCachedFallback,
              let location,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 1_000,
              abs(location.timestamp.timeIntervalSinceNow) <= 15 * 60 else {
            return nil
        }
        return location
    }

    private func finish(with location: CLLocation?) {
        guard let continuation else { return }

        timeoutTask?.cancel()
        timeoutTask = nil
        self.continuation = nil
        manager.stopUpdatingLocation()
        continuation.resume(returning: location)
    }
}
