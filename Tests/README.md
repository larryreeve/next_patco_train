# Verification

Run `zsh Tests/run-checks.sh` for deterministic behavior checks and
`zsh Tests/run-ui-checks.sh [simulator-UDID]` for the actual departure-details UI.
The regression suite is a standard Swift package with a shared production target
(`PATCOLogic`) and an XCTest target. Existing check groups are registered in
`RegressionTests`; new focused tests use XCTest directly. Assertions report through
XCTest rather than terminating the test process. Four process-boundary checks retain
executable preconditions: a shared helper is built once, and XCTest checks its exit
status. Real child processes preserve the locking, race and killed-writer coverage.

The runner uses a reusable temporary build folder to avoid signing metadata inherited
from macOS Documents folders. Set `PATCO_CHECK_BUILD` to choose another location.
Pass standard Swift test options, for example:
`zsh Tests/run-checks.sh --filter JourneyWorkflowTests`.
Tests run serially because some legacy checks exercise process-wide caches.
Optional special-schedule fixtures use `PATCO_TEST_SCHEDULE_PDF` and
`PATCO_TEST_SCHEDULE_PAGE`, not XCTest command-line arguments.

The UI script chooses an installed iPhone simulator when no ID is supplied.
Xcode must have an iOS simulator runtime installed. The GitHub workflow runs both.

## Coverage

| Risk | Executable coverage |
| --- | --- |
| Home-screen launch redraw loop | JourneyUITests launches the real ContentView, opens/closes a departure and repeats after relaunch; SavedRoutesCheck verifies preference reads and unchanged writes do not publish updates |
| Extracted home-screen controls | JourneyUITests reverses/restores the route, expands/collapses the route editor, dismisses the date picker and selects Today through the normal app entry point |
| Home reachability presentation | HomeReachabilityCheck executes the production snapshot model with fixed observation times, future-date browsing, denied permission, stale guidance, station presence, one-hour list limits and temporary station routes |
| Journey handling while browsing | JourneyWorkflowTests executes the real workflow, arrival gate and isolated route persistence; verifies completion, duplicate suppression, signal loss and publish-before-reload effects |
| Targeted screen observation | ServiceObservationTests verifies location changes do not invalidate permission readers and shortcut settings do not invalidate saved-route readers |
| Trip-detail snapshot | TripDetailPresentationCheck executes both directions, pre-trip hiding, retained scheduled times, next-stop progress, three-minute delay, expired evidence, mismatched trip keys and destination completion |
| Route selection and secondary details | JourneyUITests changes both route endpoints through the real station menus and expands fares to verify separate departure/destination information |
| Startup and foreground GPS blocked by networking | StartupJourneyIntegrationCheck uses the real location provider and refresh coordinator with an OS-manager double and a suspended network lane |
| Tracking without a Live Activity, restart, cancel, manual arrival | JourneyUITests taps the real screen/controller and relaunches the app with the same persisted journey |
| Signal loss and scheduled versus estimated times | MorningRideReplayCheck, TripArrivalEstimateCheck, and JourneyUITests |
| Competing app/widget updates | LocationRaceCheck launches 96 process actions, including stale revisions; RouteProcessRecoveryCheck kills a lock-holding writer before and after commit |
| Corrupt state and failed writes | RoutePersistenceCheck verifies backup recovery, preserved damaged bytes and rejected writes |
| Map follow/pan and large text | JourneyUITests tests the real map control and largest accessibility text category; TripMapFocusCheck tests station framing in both directions |
| Presentation services | PresentationControllersCheck injects Maps results, a clock, an isolated cache, a suspended timer and a reload spy; verifies stale-response rejection, cache expiry, failure ordering and coalesced reloads |
| Diagnostic context | StructuredDiagnosticsCheck verifies legacy decoding, correlation fields, original observation time, confidence and JSON-lines sharing; EstimatedArrivalCheck verifies inferred-arrival confidence |
| ETA assumptions | TripArrivalEstimateCheck checks both directions, exact 15-second GPS and 120-second anchor expiry, future timestamps, missing geometry/schedules, persisted evidence and displayed-minute delay labels |

JourneyLifecycleCheck, AppLocationIntegrationCheck, TripProgressCheck,
TripMapFocusCheck, TripSpeedCheck, TripArrivalEstimateCheck and EstimatedArrivalCheck no longer inspect
Swift source text. Their journey behavior is covered by model, integration and
UI assertions. Other legacy source checks remain supplemental lint; they are not
evidence that an interaction works.

PresentationControllersCheck also verifies property-level Observation: publishing
a driving estimate notifies its readers without invalidating walking-only readers.

## Ride Fixtures

`Fixtures/morning-2026-10-22.json` is reconstructed from the user-provided morning
ride logs, not a raw GPS recording. It preserves relative timing, named stops,
reported distance, accuracy and speed. Because coordinates were absent, each
point is placed north of the named station at its reported distance. Expected
progress follows the observed accepted stops. No home/work coordinates or device
identifiers are stored. It is not evidence of physical arrival accuracy.

The replay runs with and without decoding persisted progress after every reading.
It verifies duplicate rejection, delayed destination detection, station-position
floors and a separately labeled synthetic five-minute blackout. Existing
`location-trip-replays.json` scenarios cover additional route and relaunch cases.
Add recordings as separate fixtures with provenance and expected outcomes; do not
rewrite expectations merely to make a regression pass.

## UI Isolation and Limits

UI fixtures are compiled only in Debug simulator builds. Each test has its own
route directory and preferences suite; relaunch within one test reuses that
directory. A denied-permission location-manager double prevents GPS variability.
The screen, controller, persistence and map are production code.
No fixture switches ship in the device Release build.

The suite does not verify WidgetKit's on-screen refresh delivery, real ActivityKit
presentation, physical GPS quality or all VoiceOver gestures. Those still require
device checks. Large-text tests verify control reachability, not every possible
layout. The UI report includes screenshots and is retained as a CI artifact.

## Controller and Dependency Regression Checks

- `JourneyLocationControllerCheck`: real arrival evidence with isolated route
  persistence; future-date planning, station quality, committed completion,
  duplicate callbacks and obsolete route revisions.
- `GTFSUpdateServiceCheck`: injected transport/archive/cache/preferences with real
  parsing and validation; successful and unchanged updates, throttling, network,
  extraction and save failures, and retry recovery.
- `RoutePreferencesCheck`: isolated preference storage, route-selection delegation,
  transient-state expiry and cleanup without losing the saved route.
