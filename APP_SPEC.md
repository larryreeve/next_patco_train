# Next PATCO Train App Specification

## Purpose

Next PATCO Train is an unofficial iOS schedule app for PATCO riders. It helps a rider quickly see scheduled departures for a preferred route, understand whether they can likely reach the origin station in time, view special schedule information, and optionally track a selected scheduled trip on the Lock Screen.

The app is schedule-based. It does not claim to show real-time train operations.

## Required Disclaimer

Include this disclaimer off the main screen, preferably in an About sheet:

> Next PATCO Train is an unofficial schedule application and is not affiliated with or endorsed by PATCO or the Delaware River Port Authority. Schedule information may change without notice and does not reflect real-time train operations. Confirm service changes through PATCO's official website before traveling.

The About sheet should include links to:

- Official PATCO website
- PATCO X account, `@ridepatco`, as an external reference for alerts

Open these links inside the app using `SFSafariViewController`.

The About sheet should also clarify:

- `Departures, widgets, and Lock Screen views show scheduled times only. They do not reflect real-time train movement.`
- Driving reachability estimates include an additional parking-lot-to-platform access buffer.
- Users can add a Siri phrase through Shortcuts for actions like asking for the next PATCO trains.

## Platform

- iOS app built with SwiftUI
- WidgetKit widgets
- ActivityKit Live Activity
- MapKit for walking/driving estimates and route map
- CoreLocation for current location
- App Group storage for sharing selected route/schedule cache with widgets

Current bundle identifier target:

- App: `com.rhome.patconext`
- Widget extension bundle identifier should be prefixed with the app bundle identifier.

Shared App Group:

- `group.com.rhome.patconext`

## App Name

Visible app name:

- `Next PATCO Train`

Current marketing version:

- `1.1.0`
- Show the marketing version in the About sheet as `Version 1.1.0`; do not expose the internal build number in that label.

Main screen title:

- `Next PATCO Train`

Widget display name:

- `Next PATCO Train`

## Core User Flow

1. App launches to a schedule-first main screen.
2. User sees active route pair, direction, ride duration, and scheduled departures.
3. App uses current location to orient the saved route:
   - The user chooses a route pair, for example Ashland and 15/16th and Locust.
   - If the user is closer to one endpoint, that endpoint becomes the origin and the other becomes destination.
   - If no saved route exists, default to Lindenwold and 15/16th and Locust.
   - Location may orient the direction, but must not override the route pair selected by the user.
4. User can expand the route card to change stations, swap direction, and refresh location.
5. When the rider is within the at-station threshold of a PATCO station, show a separate current-station card below the saved route card:
   - The saved route remains unchanged.
   - If the current station is not the saved origin or destination, offer `Show departures from [current station]`.
   - After activation, temporarily use the current station as origin while retaining the saved destination.
   - Change the same button to `Show departures from [saved origin]` so the rider can restore the saved route.
   - Automatically restore the saved route after the rider leaves the station threshold.
6. User can tap a departure row to view scheduled departure details.
7. User can start a Live Activity from the departure detail sheet or directly from a departure row.

## Main Screen Layout

Use a dark PATCO-inspired visual theme:

- Wine/maroon top gradient
- Charcoal lower background
- Gold accents
- Cream scheduled-departures card
- White departure row cards

Top toolbar:

- Center title: `Next PATCO Train`
- Current date under the title, formatted like `Thu, Aug 20`
- Info button opens About sheet

Top route card:

- Prominent route pair, for example `Ashland to 15/16th and Locust`
- Direction and ride duration under route pair, for example `Westbound to Philadelphia • 26 min ride`
- Small `Change` button in the route card
- Default collapsed state should focus on the active route and not show location/nearest station text to avoid clutter
- Keep the route pair on one line. Dynamically size it between the defined minimum and maximum font sizes so long station names use the available width without wrapping.

Current-station card:

- Show only while the rider is within 150 meters of a PATCO station.
- Place it directly below the saved route card, not inside the expanded route controls.
- Match the route card's translucent background, border, and compact visual treatment.
- Show `Current station` and the station's actual name.
- Include a location refresh icon.
- Use one reversible, full-width capsule action rather than duplicate controls:
  - `Show departures from Woodcrest` when the saved route is active.
  - `Show departures from Ashland` when Woodcrest is temporarily active and Ashland is the saved origin.
- The action label must stay on one line and dynamically scale down to fit the button.

Expanded route controls:

- Location refresh button
- Location status is omitted from the expanded controls while the separate current-station card is visible.
- If location is unavailable, show `Location is off. Pick a station manually.` or similar friendly text.
- From station picker
- To station picker
- Swap direction button

Special schedule banner:

- Show only when a special schedule is active
- Text:
  - `Special schedule applied`
  - Date/title, for example `Friday, August 14, 2026`
  - `View PDF`
- Opens source PDF in-app

Scheduled departures card:

- Title: `Scheduled Departures`
- Refresh button at far right of title row
- Single map/directions icon near the refresh button; do not repeat the map icon on every departure row
- Current refresh timestamp: `Current as of 7:40 PM`
- Optional reachability hint:
  - `Reachability uses your current location and accounts for the time needed to walk from the parking lot to the station.`
- Scrollable list of scheduled departures

If PATCO website alerts are available, show an alerts card. If no alerts are available, hide the card entirely.

## Departure Rows

Each row should show:

- Departure time
- Time until scheduled departure as `in Xm` or `in X hr Ym`
- Arrival time line: `Arrives 8:28 PM`
- Reachability badge when relevant
- Special schedule adjustment badge when relevant:
  - `Adjusted from 7:52 PM`
- Small row-level Live Activity button near the departure countdown

Row tap behavior:

- Tapping the row opens the departure detail sheet.
- Tapping the Live Activity button starts schedule tracking directly and should not open the detail sheet.

Live Activity row button:

- Use a compact icon button
- Use `lock.iphone` with accessibility label `Show scheduled trip on Lock Screen` when the departure is not active.
- Use `lock.slash` with accessibility label `Remove scheduled trip from Lock Screen` when that departure is active.
- Tapping the active state immediately removes the matching Live Activity without opening departure details.
- Disable starting when the departure time is already in the past or Live Activities are disabled, but keep removal enabled for an existing activity.
- Synchronize visible row states when an activity starts or ends so only the matching departure presents the remove control.

## Reachability Logic

Reachability is a confidence estimate for reaching the origin station before scheduled departure.

If the user is far outside the PATCO region, do not show reachability at all. Current cutoff: hide reachability when the user is more than 150 miles from the origin station. This prevents confusing multi-hour or international estimates for first-time downloads and out-of-area users.

Modes:

- At station
- Walking
- Driving/car

Mode inference:

- If user is within station threshold, show `At station`.
- App and widget use one shared sticky mode record in the App Group, keyed by origin station. Inferred modes expire after three hours; explicit user selections remain active until arrival at the station.
- When no valid mode exists for the origin, infer the initial mode:
  - Within 0.75 miles, use walking.
  - Beyond 1.25 miles, use driving.
  - Between those distances, choose walking only if walking time still allows the user to catch the train.
- Once driving is selected, approaching within 0.75 miles must not automatically switch the mode to walking or change which departure is considered reachable.
- Driving transitions directly to `At station` inside the 150-meter station threshold.
- A sticky walking mode may promote to driving after the rider moves beyond 1.25 miles.
- An explicit car or walk choice from either the app or widget remains authoritative until the rider enters the 150-meter at-station boundary and must not be replaced by distance-based inference while approaching.
- Entering the at-station boundary clears the explicit choice. Hide the mode control while at the station; after the rider leaves, infer a fresh mode from distance and catchability.
- Selecting another origin causes that origin to establish its own mode rather than reusing a mode associated with the previous station.
- Provide a compact car/walk toggle beside the departures map and refresh controls. Its icon reflects the active transportation mode; tapping it immediately switches to the other mode, updates the shared state, recalculates reachability, and requests a widget timeline reload.

Walking estimate:

- Prefer `MKDirections` walking route ETA.
- Do not add extra station-access buffer to walking. Walking route already accounts for walking to the station area.
- Fallback to straight-line estimate only if MapKit walking directions fail.

Driving estimate:

- Prefer `MKDirections` automobile route ETA.
- Add station-access buffer for driving to account for parking and walking from the parking lot to the station platform.
- Continue requesting the automobile ETA while sticky driving mode is active, down to the 150-meter at-station boundary.

Reachability status labels:

- At station: `At station now`
- Positive: `Reachable • arrive by walking 7:28 AM` or `Reachable • arrive by car 7:28 AM`
- Tight: `Tight • arrive by walking 7:28 AM` or `Tight • arrive by car 7:28 AM`
- Miss under 5 minutes late: `May miss • arrive by walking 7:28 AM` or `May miss • arrive by car 7:28 AM`
- Miss more than 5 minutes late: `Too late • arrive by walking 7:28 AM` or `Too late • arrive by car 7:28 AM`

Use concise badges:

- Green for reachable
- Gold/yellow for tight
- Red/pink for may-miss or too-late states

List-level consistency:

- Use one inferred travel mode for the entire departure list refresh. Do not mix car and walking badges across rows from the same refresh.
- Continue evaluating future departures until at least one reachable/tight/at-station departure is included, even if that means looking beyond the initially visible list.

## Departure Detail Sheet

Title:

- `Departure Details` so it fits compact iPhone widths.

Visual priority:

1. Scheduled departure
2. Scheduled arrival
3. Route pair
4. Direction and ride duration
5. Lock Screen tracking action
6. Fare
7. Extras
8. Scheduled stops
9. Route map

Include:

- Hero area with departure, arrival, and direction
- Button state is derived from ActivityKit's active activities for the selected departure:
  - `Show on Lock Screen` when no matching activity exists.
  - `Remove from Lock Screen` when that departure is currently active.
- Removing ends the matching activity with immediate dismissal and returns the button to its show state.
- A matching activity is identified by the departure deep-link URL stored in its attributes, not by a local UI-only flag.
- After starting or removing the Live Activity, center the confirmation message under the button.
- If Live Activities are disabled in Settings, show that status and disable starting; an existing matching activity may still be removed even after its scheduled departure time.
- Direction label using headsign:
  - `Westbound to Philadelphia`
  - `Eastbound to Lindenwold`
- Route pair as a single line:
  - `Ashland -> 15/16th and Locust`
- Fare:
  - One-way
  - Round-trip
- Bikes/accessibility icons without verbose labels where possible
- Special schedule adjustment if present:
  - `Adjusted from [original time]`
- Scheduled stops section:
  - Title format: `[n] scheduled stops`
  - Do not include the starting station
- Each scheduled stop includes an external-link icon to that station's official PATCO information URL from the GTFS feed.
- Route map below scheduled stops
- Route map title: `Route map`
- Below the route map, show `Destination station information` and embed the destination station's official PATCO page in an in-app web view.

## Schedules

The app should include a built-in PATCO schedule model.

Departure filtering:

- Show all upcoming scheduled departures for the current service day.
- Near midnight, if the current day has too few remaining departures, include the next day’s first few departures.
- If a special schedule exists for the next day, use it for next-day departures.

Special schedules:

- Detect active PATCO special schedules from PATCO website/PDF source.
- Download the special schedule PDF.
- Parse/extract the special schedule.
- Override built-in schedule for the affected service date.
- Compare special schedule against built-in schedule where possible.
- Mark adjusted departures and show original scheduled departure:
  - `Adjusted from 7:52 PM`

Offline/cache behavior:

- Cache parsed special schedule data.
- If special schedule refresh fails but cached active schedule exists, show:
  - `Using cached schedule.`
- Do not show this warning after a successful refresh.

Manual refresh:

- Pull-to-refresh should refresh:
  - Location
  - Departures
  - Alerts
  - Special schedule data
  - Reachability estimate
- Foregrounding the app should refresh location and departures.

## Alerts

Website alerts:

- Pull active PATCO website alerts.
- Hide alerts box entirely when there are no relevant alerts.
- Avoid showing unrelated informational links such as service animals.
- Preserve alert/advisory dates because the effective date is user-critical.
- Filter out stale date-specific advisories once their date has passed.
- Advisory text must wrap fully; do not truncate service-advisory content.

X/Twitter:

- PATCO posts some alerts on X at `@ridepatco`.
- Without a hosted backend/API token, do not scrape or pull tweets directly in the app.
- Provide an About-sheet link to the X account instead.

## Widgets

Supported widget sizes:

- Small
- Medium
- Large

Widget behavior:

- Widgets should use the same saved route pair as the app via App Group defaults.
- Widgets should orient the route based on the nearest endpoint when location is available.
- Widgets must request and validate their own current location so reachability does not depend on the app being open.
- Use nearest-ten-meters desired accuracy, reject invalid fixes or fixes older than two minutes, allow up to five seconds for a request, and fall back to a shared location no older than 15 minutes.
- At timeline generation, use MapKit to refresh the walking or driving ETA for the independently selected widget route. Fall back to the distance-based estimate when no matching fresh MapKit estimate is available.
- If the app has explicitly activated a temporary at-station route, the widget may use it only while its own current location remains within 150 meters of that temporary origin. Otherwise, use and independently orient the saved route pair.
- Widgets should show scheduled departures and use special schedule cache where available.
- Widgets should avoid overcrowding:
  - Small: up to 3 compact departures when space allows
  - Medium: about 3 departures
  - Large: can show more, for example up to 10
- Small and medium widgets should show the first unreachable departure followed by the next reachable departures, so users can see when the first catchable train is.
- If several immediate departures are unreachable, skip extra unreachable departures after the first one in compact widgets.
- Widget reachability should use the same saved/inferred mode and same status thresholds as the main app as much as WidgetKit allows.
- Widget reachability resolves the same App Group sticky mode as the app for the selected origin, including manual car/walk choices that remain active until station arrival.
- If the user is outside the far-away cutoff, widgets should omit reachability coloring/status and simply show scheduled departures.

Widget departure styling:

- Use reachability colors on departure times where possible.
- Widget reachability is approximate and can only update when the widget timeline/location snapshot updates.
- Do not show widget countdown/time-until-departure labels because WidgetKit cannot keep them precisely current without battery-heavy timeline churn.
- Show scheduled departure time and arrival details instead.
- Small widgets should show the arrival time without the `Arrives` label to avoid clipped destination text.
- Do not show route duration in widgets.

Widget limitations:

- Widgets are not scrollable.
- iOS controls widget refresh cadence; the app can request timeline reloads, but cannot force constant updates.
- Prefer battery-conscious timelines. Generate minute-offset display entries for the next 15 minutes from one location and ETA snapshot; these entries advance departures without repeatedly waking the extension. Request the next timeline after that 15-minute window so the widget independently obtains a new location and ETA.
- While the app is active and receiving meaningful location updates, request a widget timeline reload at most once every two minutes. Route changes, mode changes, and arrival-mode clearing may request immediate reloads.
- App and widget may refresh independently, but both must resolve the same shared route, temporary station route, explicit/inferred transportation mode, reachability thresholds, and cached ETA rules so refreshing either surface does not produce a different logical result from the same inputs.
- Recalculate the nearest station within the selected route immediately whenever either route endpoint changes; do not wait for another Core Location callback. While route controls are expanded, update the nearest-route display without overriding the endpoints the user is editing.
- Include an interactive refresh button on supported widget systems. It requests a timeline reload for departures, location, and reachability, but final scheduling remains controlled by iOS.
- Include an interactive car/walk button that displays the current reachability mode. Tapping it switches the shared, origin-specific mode and reloads widget timelines so the app and widgets remain synchronized without requiring the app to open.
- Do not include a decorative train icon in the Home Screen widget header; reserve that space for the route and the interactive mode and refresh controls.
- Tapping the widget should open the app through `patconext://widget`; the app should refresh location, departures, alerts, special schedules, and reachability when foregrounded from the widget.

## Live Activity

Purpose:

- Track a selected scheduled trip on the Lock Screen and Dynamic Island.
- Be explicit that information is scheduled, not live train telemetry.

Start points:

- Departure detail sheet: `Track on Lock Screen`
- Departure row: compact icon button

Before scheduled departure:

- Show:
  - Route title
  - Scheduled departure time
  - Scheduled arrival time
- Show route direction, for example `Westbound to Philadelphia`
- Show a special schedule badge if the departure comes from a special schedule
- Show `Adjusted from 8:22 PM` if the special schedule departure differs from the standard schedule
- Do not duplicate the scheduled departure time in the bottom status row.
- Do not show a running countdown timer; it proved confusing and cannot be reliably stopped by app code after suspension.
- Bottom status area can remain blank before scheduled departure except for special schedule/adjusted/direction context.
- Do not show `On train`, `Departed`, or `Trip in progress` before scheduled departure.

After scheduled departure:

- Show `Scheduled departure passed`.
- Do not show a countdown that continues increasing after the scheduled departure time.
- Do not claim the train actually departed or is in progress.
- A next scheduled stop can only be shown if explicit state updates are available. Without guaranteed background execution or server push, do not depend on scheduled stop advancement being reliable.

After all scheduled stops have passed:

- Use schedule-safe fallback:
  - `Scheduled arrival pending`
  - `Trip complete` after scheduled arrival

Implementation detail:

- Live Activity state includes:
  - departure date
  - arrival date
  - scheduled stops excluding origin
  - optional current scheduled stop index
  - last updated
- Existing activities should be ended before starting a new one.
- Live Activity should support deep linking into the selected departure detail using a custom URL like `patconext://departure?...`.
- Lock Screen, Dynamic Island, and Apple Watch compact views should include the selected departure time where the system layout has room.
- Set the Live Activity stale date to scheduled arrival plus a short grace period, currently 10 minutes.
- Clear expired activities on app launch and foreground refresh.

Important Live Activity limitation:

- iOS may throttle or stop app execution. Native timer text can keep ticking, but arbitrary SwiftUI state calculations may not refresh exactly at stop boundaries unless the Live Activity receives an explicit state update.
- Since this app has no real-time feed, never use live-operation wording such as `Departed` or `On train`.
- Without a hosted backend/push service, the app cannot guarantee automatic dismissal or stop-by-stop updates if the app is not launched again.

## Location Behavior

Location permission:

- Request when-in-use location permission.
- Desired accuracy should be close enough for transit use, around nearest-ten-meters where practical.

When location is unavailable:

- Show friendly text.
- Allow manual station selection.
- Use saved/default route pair rather than failing.
- If location cannot be determined, the selected station should come from the saved route/default route, not an arbitrary nearest station guess.

Station orientation:

- The selected route pair is the user’s default.
- Location should choose eastbound vs westbound direction based on the nearest route endpoint.
- If the user is near another PATCO station that is not part of the route pair, show it only as helpful context, not as route origin.
- Foreground location updates should run while the app is open and refresh the `You're at [station] station` message as CoreLocation provides new updates.
- Reachability should use a stabilized location snapshot, not every raw GPS update. Passive location movement should update reachability only after a meaningful movement threshold or short debounce interval to avoid badges flickering while the user is traveling by car or train.
- At-station detection uses a 150-meter threshold. A station outside the saved pair may be offered as a temporary origin but must not overwrite the saved route.
- Temporary station routes are shared with the widget, expire after 12 hours, and are cleared when the rider leaves the temporary origin or manually saves another route.

## Route Defaults

Default route if none saved:

- `Lindenwold` to `15/16th and Locust`

Saved route:

- Save origin/destination station IDs to App Group defaults.
- Widgets use the same saved route.
- Keep temporary at-station origin/destination IDs separate from saved route IDs so using a nearby station never changes the user's preference.

## Siri / App Intents

- Provide App Intents for next departures and reachable departures.
- Expose these actions to Shortcuts so users can create phrases such as:
  - `What are the next PATCO trains?`
  - `When is the next reachable PATCO train?`
- Do not require the spoken phrase to include the app name, but users may need to create or run the Shortcut once before Siri recognizes the phrase.
- Without App Shortcuts adoption/learning or a user-created Shortcut phrase, Siri may treat `Next PATCO` as a contact/search term instead of invoking the app.

## CarPlay

- CarPlay support is intentionally removed.
- Do not include CarPlay scene declarations, CarPlay Swift files, or CarPlay entitlements.
- Do not include invalid entitlements such as `com.apple.developer.carplay-maps`.
- Revisit CarPlay only if Apple grants an appropriate CarPlay entitlement for the developer account and the app has a review-safe in-car use case.

## Visual Style

General:

- Use compact, transit-focused UI.
- Avoid making route controls dominate the main screen.
- Keep route controls collapsed by default.
- Use 8px-style corner radius for cards.
- Avoid large decorative content.

Important visual details:

- Main route title should be prominent but not oversized.
- Change button should be small and secondary.
- Scheduled departures should be readable and scrollable.
- Avoid excessive white space in departure rows.
- About sheet should feel polished, with icon, important disclaimer card, and official links.

## Data Model Expectations

Station:

- ID
- name
- coordinate
- sequence/order

Trip:

- direction/headsign
- stop times
- bikes allowed
- wheelchair accessible

Departure:

- origin
- destination
- trip
- origin stop time
- destination stop time
- departure date
- arrival date
- service date
- travel minutes
- optional schedule adjustment

Schedule adjustment:

- adjusted departure date
- original departure date
- source special schedule

## Build/Development

- App and widget targets must use the same marketing version.
- Both Info.plists should resolve `CFBundleShortVersionString` from `$(MARKETING_VERSION)` and `CFBundleVersion` from `$(CURRENT_PROJECT_VERSION)`.

Typical build command:

```sh
xcodebuild -quiet -project NextPATCOTrain.xcodeproj -scheme NextPATCOTrain -destination 'generic/platform=iOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

The warning below has appeared during development and can be harmless if the build succeeds:

```text
IDERunDestination: Supported platforms for the buildables in the current scheme is empty.
```

## Non-Goals

- Do not claim real-time train location.
- Do not scrape X/Twitter directly from the app without an approved API/backend.
- Do not show alerts box when empty.
- Do not show route/location controls expanded by default.
- Do not make widgets scrollable; iOS widgets do not support this for the intended layout.
