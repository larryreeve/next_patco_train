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

- `Next PATCO`

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
5. User can tap a departure row to view scheduled departure details.
6. User can start a Live Activity from the departure detail sheet or directly from a departure row.

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
- If the user is at or very near a PATCO station, show concise context such as `You're at Woodcrest station` where it adds confidence without cluttering the route card

Expanded route controls:

- Location refresh button
- Location status:
  - `Nearest route station: Ashland`
  - If near any PATCO station: `You're near [station] station`
  - If unavailable: `Location is off. Pick a station manually.` or similar friendly text
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
- Accessibility label: `Show scheduled trip on Lock Screen`
- Disable when departure time is already in the past

## Reachability Logic

Reachability is a confidence estimate for reaching the origin station before scheduled departure.

If the user is far outside the PATCO region, do not show reachability at all. Current cutoff: hide reachability when the user is more than 150 miles from the origin station. This prevents confusing multi-hour or international estimates for first-time downloads and out-of-area users.

Modes:

- At station
- Walking
- Driving/car

Mode inference:

- If user is within station threshold, show `At station`.
- If close enough to walk, use walking.
- If far enough away, use driving.
- In between, choose walking only if walking time still allows the user to catch the train.

Walking estimate:

- Prefer `MKDirections` walking route ETA.
- Do not add extra station-access buffer to walking. Walking route already accounts for walking to the station area.
- Fallback to straight-line estimate only if MapKit walking directions fail.

Driving estimate:

- Prefer `MKDirections` automobile route ETA.
- Add station-access buffer for driving to account for parking and walking from the parking lot to the station platform.

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

- `Scheduled Departure Details`

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
- Button: `Track on Lock Screen`
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
- Route map below scheduled stops
- Route map title: `Route map`

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
- Widgets should show scheduled departures and use special schedule cache where available.
- Widgets should avoid overcrowding:
  - Small: up to 3 compact departures when space allows
  - Medium: about 3 departures
  - Large: can show more, for example up to 10
- Small and medium widgets should show the first unreachable departure followed by the next reachable departures, so users can see when the first catchable train is.
- If several immediate departures are unreachable, skip extra unreachable departures after the first one in compact widgets.
- Widget reachability should use the same saved/inferred mode and same status thresholds as the main app as much as WidgetKit allows.
- If the user is outside the far-away cutoff, widgets should omit reachability coloring/status and simply show scheduled departures.

Widget departure styling:

- Use reachability colors on departure times where possible.
- Widget reachability is approximate and can only update when the widget timeline/location snapshot updates.
- Widget time-until-departure format:
- Do not show widget countdown/time-until-departure labels because WidgetKit cannot keep them precisely current without battery-heavy timeline churn.
- Show scheduled departure time and arrival details instead.
- Small widgets should show the arrival time without the `Arrives` label to avoid clipped destination text.
- Do not show route duration in widgets.

Widget limitations:

- Widgets are not scrollable.
- iOS controls widget refresh cadence; the app can request timeline reloads, but cannot force constant updates.
- Prefer battery-conscious timelines. Do not generate minute-by-minute entries for long windows; use a coarser cadence such as 5-minute entries and avoid duplicate timeline reload requests.
- Use a recent cached app location before requesting widget location, so widgets do less background location work.
- Use denser timeline entries only for imminent trains, currently 1-minute entries for the next 20 minutes and 5-minute entries after that.
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

## Route Defaults

Default route if none saved:

- `Lindenwold` to `15/16th and Locust`

Saved route:

- Save origin/destination station IDs to App Group defaults.
- Widgets use the same saved route.

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
