# Operational Reference

## State Ownership

| State | Authority | Readers and boundaries |
| --- | --- | --- |
| Selected route, revision, saved endpoints, temporary station route | `SharedRouteCoordinator.Route`, committed through its locked transaction and `SharedRoutePersistence` | App and widgets reread the committed revision. Temporary browsing must not replace the active journey. A cached view is not a route authority. |
| Journey lifecycle | `JourneyCoordinator`, persisted as `Route.journey` | `TripTrackingController` handles app commands. Arrival, cancellation and expiry reconcile in the shared transaction; a late callback cannot resurrect a terminal journey. |
| Observed/inferred passed stations and position | `Route.journeyProgress`; `TripProgressStore` is the app-side projection | `TripLocationProgress` evaluates evidence. Backfilled passed stops are not new observations. The map cannot regress behind accepted progress in the journey direction. |
| Location observations | `LocationProvider` in the app; `WidgetLocationProvider` in the extension | `SharedCurrentLocationCache` transfers timestamped observations. A cached fix retains its original timestamp; reading it is not a new observation. |
| Reachability mode and travel time | `SharedReachabilityModeStore`; `SharedTravelTimeEstimateCache` | `TravelEstimateController` and `WidgetTravelTimeEstimator` request Maps results. They reject obsolete route/location responses and protect newer cache writes from older failures. Reachability is travel to the departure station, not the train's destination ETA. |
| Published departures and reachability | `SharedTripState.Snapshot`, associated with its route revision | A delivery snapshot, not a source of journey transitions. App/widget displays must reject mismatched revisions and expire old guidance. |
| Displayed destination/stop ETA | Derived by `TripLocationProgress.arrivalEstimate`; not independent persisted truth | `DepartureDetailView` requires an active tracked journey and a valid departure. Scheduled times remain distinct and are never overwritten by an estimate. |
| Widget delivery | `WidgetReloadCoordinator` publishes before requesting a reload; WidgetKit controls delivery | A reload request or prepared timeline does not prove an on-screen redraw. Live Activities are presentation, not journey ownership. |

When diagnosing disagreement, compare route revisions first, then journey ID and
the observation timestamp. Do not reconcile by whichever screen refreshed most
recently. Terminal journey state and committed route data outrank stale UI caches.

## App Boundaries

`JourneyStationEvidence` owns strict presence and underground station evidence.
`JourneyArrivalController` evaluates destination evidence and commits the return
route using an injected route reader, evidence check, commit operation and logger.
It returns a completion only after the commit succeeds. `HomeRouteController` applies that
result to presentation, location tracking and announcements; it no longer keeps
a second destination-arrival gate. The shared transaction remains authoritative.

`ContentView` retains one observable `HomeScreenModel` and wires lifecycle events.
The model composes route and schedule controllers and a reachability value snapshot;
views do not own duplicate route state. Schedule, location, alerts, saved routes,
refresh and travel estimates use property-level Observation directly. There is no
broad service-change counter or Combine forwarding subscription. Route-controller callbacks and
location callbacks capture the screen model weakly. The schedule controller does
not own or cancel the active journey when the user browses another day.

Home sections read their route, schedule and reachability owners directly instead
of forwarding every property through the screen model. The screen model accepts
its trip-progress, location, alerts, saved-route, refresh, travel-estimate and reload services at
initialization. Required route effects are supplied at construction, not attached
later with no-op defaults. The same trip-progress instance flows to route handling
and the departure sheet; the live shared instance is selected at composition boundaries.

`JourneyLocationWorkflow` owns recording and route reconciliation on location callbacks.
When browsing another date, it still resolves the active journey, ends tracking on
committed arrival, publishes the matching snapshot, and only then requests a widget
reload. A small progress-recording contract, isolated route directory, clock, and
explicit output effects allow behavioral tests without GPS, ActivityKit or user storage.
Today-only station presentation remains in the route controller.

`TripDetailPresentation` validates trip identity and derives scheduled labels,
remaining stops and estimates from one immutable snapshot. Summary and stop-list
rendering share those rules. `TripRouteMap` owns only camera state; user panning
pauses following until the follow action is selected. Tracking commands and
confirmation prompts stay in the sheet, with transitions delegated to the existing
tracking controller.

`RoutePreferences` owns legacy saved-route fallback and temporary/manual selection
preferences outside the screen. Preferences, clock and route operations can be
replaced per instance. App Intents use the same production adapter.

`PATCOGTFSUpdateService` receives network transport, archive extraction, preferences
and feed-cache operations at initialization. `PATCOGTFSAdapters.swift` is the
production wiring for URLSession, ZIPFoundation and shared cache storage. Tests
exercise the real parsing/validation pipeline without network or shared writes.
An in-flight update cannot overlap another update on the same service instance.
These boundaries do not make every app service injectable: ActivityKit command
helpers and the shared trip-progress projection remain platform-facing adapters.

## ETA Contract

The estimator is schedule-based, not a constant-current-speed extrapolation and
not a live rail-dispatch prediction. It assumes the observed schedule offset will
persist through the remaining journey. It cannot predict future holds, dwell time
changes, dispatch decisions, skipped stops or recovery of a delay.

1. Use the selected trip's service-date schedule, including applicable special
   schedules. Intermediate ETA anchors use scheduled **arrival** times; the origin
   uses departure and the destination uses arrival. The intermediate row's retained
   scheduled label is its **departure**, so it is not necessarily the same event as
   that row's estimated arrival.
2. For usable GPS, project the displayed train position onto route geometry. It
   must be within 150 m of the route. Between adjacent stations A and B, interpolate
   their scheduled times by along-track distance:
   `scheduledPosition = A.time + fraction * (B.time - A.time)`.
3. Compute `offset = observationTime - scheduledPosition`, then
   `destinationETA = scheduledDestinationArrival + offset`. This uses the fix's
   timestamp, not the callback time or the UI refresh time. GPS is fresh through
   15 seconds, inclusive; future timestamps are not fresh.
4. If GPS cannot support an estimate, a directly observed station anchor can supply
   `offset = anchorObservationTime - scheduledStationArrival`. Accepted underground
   station estimates may also supply an anchor and retain their estimated label.
   Backfilled stops never create anchors. Anchor freshness is 120 seconds inclusive.
5. Remaining-stop ETAs use the same offset against each stop's scheduled arrival.
   Do not display an ETA that is already in the past or one beyond the destination's
   scheduled position. Do not estimate before scheduled departure or after the
   destination is completed. Missing required endpoints/geometry/evidence yields no
   estimate rather than an invented position.
6. When evidence expires, keep the schedule visible and fall back to last-known
   map progress. Do not advance the observation clock on redraw or cache reuse.
   Freshness limits are named in `TripArrivalEstimatePolicy`.
7. Delay labels compare the displayed minute buckets. For example, scheduled 6:04
   and estimated 6:07 is three minutes late even when seconds differ. The underlying
   ETA retains full precision. Schedule parsing uses the PATCO service timezone and
   handles service times beyond midnight; it does not use the device's timezone as
   the timetable timezone.

`TripArrivalEstimateCheck` validates interpolation in both directions, exact GPS
and anchor expiry boundaries, future fixes, missing geometry/schedules, persisted
anchor age, completed trips, remaining-stop offsets, and minute-level delay labels.
`DSTScheduleCheck`, `TripBackfillCheck`, the ride replay and UI tests cover related
contracts. Reconstructed ride fixtures are not ground-truth accuracy measurements.

## Diagnostic Events

Shared and app logs retain their readable title/detail. New events include a typed
`context` object; old events without context still decode. Sharing diagnostics emits
one JSON object per line with millisecond-precision ISO-8601 dates. Embedded newlines in details are escaped.
The event's `date` is recording time; `observationTimestamp` is the original fix time.

Context schema version 1 contains:

| Field | Meaning |
| --- | --- |
| `component` | Source/evaluation path, such as `app.arrival`, `shared.arrival`, `shared.route`, or `widget.reload`. |
| `journeyID` | Existing journey key, when known; not a newly generated identifier on each refresh. |
| `routeRevision` | Revision evaluated, or newly committed revision for a route-change event. |
| `observationTimestamp` | Observation supporting the decision, when applicable. |
| `confidence` | `precise`, `estimated`, or `unknown`; an evidence classification, not a probability. Precise station presence does not necessarily establish that the train stopped. |
| `decision` | `accepted`, `pending`, `rejected`, `committed`, `observed`, or `informational`. |
| `rejectionReason` | Why arrival was not confirmed, including waiting for more evidence. Not present for an accepted arrival. |

Arrival decision context is captured inside the route transaction from the route
actually evaluated, before reversal. Route commit logs preserve the preceding
journey key when needed for correlation. Generic informational messages explicitly
use unknown confidence and omit unavailable context; they must not fabricate IDs,
observation times or acceptance. A pending arrival is not proof of a failed sensor.
Widget timeline acceptance means preparation succeeded, not that iOS displayed it.
Arrival acceptance means the evidence gate accepted the observation; confirm a
subsequent committed-route event before concluding that persistence/reversal succeeded.
Storage failure messages take precedence over an uncommitted evidence decision.

Structured context does not add raw coordinates. Existing details may disclose
station names, distances, trip times and travel patterns; review exports before
sharing. Logs are bounded local diagnostic history, not a durable audit trail or
telemetry service. Existing cross-process preference logs may lose competing entries;
the locked route store remains authoritative. Absence of a diagnostic is not proof
that a transition did not occur.

## Release Evidence

Use [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) for every candidate. Record the
commit, version/build, test artifacts, device observations and unresolved limitations.
A simulator build or installation alone must not check off physical-ride or widget
delivery verification.
