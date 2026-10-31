# Next PATCO Train

Next PATCO Train is an iOS app which shows upcoming scheduled departures for your saved route and helps you decide which train you can catch. See scheduled arrival times, complete stop details, and leave-by guidance when walking or driving to the station.

Use your location to find a nearby PATCO station. When you are at a station, view departures from that station without losing your saved route. Choose a future date to plan ahead, including special schedules and their adjusted, added, or removed departures.

Keep your commute close at hand with Home Screen widgets, or follow a selected scheduled trip with a Lock Screen Live Activity.

Features:
- Upcoming scheduled PATCO departures
- Scheduled arrival times and complete stop details
- Walking and driving catch train and leave-by guidance
- Nearby-station detection and at-station departures
- Future-date schedule planning
- Special schedule notices, changes, and PDF access
- Home Screen widgets
- Lock Screen Live Activities
- Links to official PATCO service information
- Siri Shortcuts support
- Automatic schedule updates

Next PATCO Train is an unofficial schedule app and is not affiliated with or endorsed by PATCO or the Delaware River Port Authority.

Train times are based on published schedules and do not reflect real-time train operations. Schedules may change without notice. Check PATCO’s official website for service changes before traveling.


The bundled schedule was generated from PATCO's GTFS feed:

`https://rapid.nationalrtap.org/GTFSFileManagement/UserUploadFiles/13562/PATCO_GTFS.zip`

## Run

Open `NextPATCOTrain.xcodeproj` in Xcode, choose the `NextPATCOTrain` scheme, and run on a simulator or device.

The default commute is Lindenwold to 15/16th and Locust. Tap the location button to select the nearest station, or use the station menus and swap button manually.

## Documentation

See [APP_SPEC.md](APP_SPEC.md) for the app's product behavior, user experience, data handling, widget behavior, and App Store asset requirements.

## Verification

Run `zsh Tests/run-checks.sh` on macOS with Xcode installed. The script runs the Swift package's XCTest suite, compiling shared production logic once. It covers lifecycle migration, independent refresh lanes, persistence recovery, observation, journey workflows and location replays. Use `--filter JourneyWorkflowTests` to run a focused group. `PATCO_CHECK_BUILD` overrides the reusable temporary build folder.

Build both app and widget without signing:

```sh
xcodebuild -project NextPATCOTrain.xcodeproj -scheme NextPATCOTrain -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/PATCOCheck CODE_SIGNING_ALLOWED=NO build
```

Run `zsh Tests/run-ui-checks.sh` to test journey controls, relaunch, cancellation, arrival, ETA presentation, map following and accessibility text sizes in an installed iPhone simulator. An optional simulator UDID selects a specific device. See [Tests/README.md](Tests/README.md) for coverage, ride-fixture provenance and remaining device checks.

The `App checks` GitHub Actions workflow runs all three steps on pull requests and preserves UI reports/screenshots. After the workflow is pushed and has run, configure the branch rule to require `Regression checks and simulator build` before merging. CI uses the macOS 26 runner's default Xcode and records its version at the start of each run.
## Code Ownership

See [OPERATIONS.md](OPERATIONS.md) for authoritative state ownership, ETA assumptions
and diagnostic event semantics. Use [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) to
record automated results, physical-device evidence and known limitations per release.

- `NextPATCOTrain/PATCOModels.swift`: schedule data structures only.
- `ContentView`: owns the screen model's lifetime and connects app lifecycle events.
  `HomeScreenModel` coordinates refresh, navigation, reachability and shared snapshots.
  `JourneyLocationWorkflow` records and reconciles active trips independently of schedule browsing,
  including completion effects and publishing the matching widget snapshot.
  `HomeRouteController` owns displayed route/station transitions and announcements;
  durable changes still go through the revision-checked shared coordinator.
  The home model, route controller and departure sheet share an injected trip-progress store.
  Home services use direct property-level Observation, with no broad refresh counter.
  Route endpoints are read-only to views; selection is one controller action.
  Current station identity comes from one station value, and temporary endpoints
  come from one temporary-route value rather than independently writable fields.
  `HomeScheduleController` owns browsing dates and schedule update/recovery state.
  `HomeReachabilityPresentation` calculates guidance from a value snapshot.
  `HomeScreenContent` and `HomeDeparturesSection` render the screen and list.
  `HomeRouteHeader`, `HomeDeparturesHeader`, `HomeStationPanel`,
  `HomeAlertsView`, `HomeSpecialScheduleBanner` and `HomeScheduleDatePicker`
  own their presentation. They receive values, bindings and explicit actions;
  they do not acquire location, commit routes or start network requests.
  Alert expansion stays local to the alerts view; route expansion remains in
  the route controller because automatic station selection also closes the editor.
- `NextPATCOTrain/Core/`: shared app/widget policies, station and arrival evidence,
  journey tracking, route transactions, schedule loading, caches and diagnostics,
  separated into named files. `JourneyCoordinator` remains the lifecycle authority;
  `SharedRoutePersistence` owns durable route storage.
- `TravelEstimateController`: asynchronous walking/driving estimates, request
  ordering and cache interaction. `HomeScreenModel` supplies current context; results
  are checked against that context after awaiting Maps.
- `WidgetReloadCoordinator`: throttling, trailing reloads and publish-before-reload
  ordering. `AppRefreshCoordinator` owns independent refresh lanes.
- `DepartureDetailView`: sheet lifecycle, tracking actions and confirmation prompts.
  `TripDetailPresentation` is the read-only trip snapshot shared by
  `TripJourneySummary`, `TripRouteMap` and `TripStopTimeline`. The map owns its
  camera; the components do not acquire location or change journeys.
  `TripFareSummary` renders the secondary disclosure. Tracking transitions still
  enter through `TripTrackingController`, which supplies platform effects to the
  testable `TrackingActions` workflow. `TrackingDisplayReplacement` preserves the
  old display until a replacement is accepted. The supplied progress store is
  carried through start, cancel, arrival, Lock Screen changes and expiration.
  Station browsing and fare calculation live
  in `StationInformationView` and `FarePresentation`.
- `LiveTimeline` (in `TripJourneySummary.swift`): shared live-screen refresh wrapper.
  It samples its injectable clock on each render, not the preceding timer tick.
  Trip summary, stops, map, tracking controls and home shortcut use this same rule;
  freshness policies continue rejecting expired and future-dated observations.
- `NextPATCOTrainWidget/`: timeline provider, location provider, travel estimator,
  route state, actions, reachability, Home Screen views, Lock Screen and Live
  Activity presentation have separate files. The bundle file only registers widgets.

### Dependency Conventions

Inject dependencies through initializers or explicit operation parameters, not a
mutable global service locator. Pure policies accept `now`; asynchronous controllers
accept a clock and service closures. The travel controller accepts a Maps calculation
closure and a cache configured with a preferences suite/directory. Reload scheduling
accepts a clock, sleeper and reload closure. Production defaults use the existing
platform services; tests supply isolated storage and deterministic doubles. Existing
location-manager, alert-loading and route-directory injection follow the same pattern.

### Location Thresholds

`Core/LocationPolicies.swift` names the shared thresholds. Guidance permits accuracy
up to 150 m; station presence requires a reading at most 15 seconds old and accuracy
within 50 m. Stopped arrival has stricter speed, duration and precise-fix rules.
Underground destination estimates accept 50-2000 m accuracy only with journey and
repeated-reading evidence; their maximum reading gap is 90 seconds, versus 45 seconds
for intermediate progress. Departure evidence has a distinct 3000 m ceiling. These
different confidence budgets are intentional and must not be merged into one global
"location accuracy" setting. This refactor preserves the existing threshold values.
