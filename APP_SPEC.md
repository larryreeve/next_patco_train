# Next PATCO Train App Specification

## Purpose

Next PATCO Train is an unofficial iOS schedule app for PATCO riders. It helps a rider quickly see scheduled departures for a preferred route, understand whether they can likely reach the origin station in time, view special schedule information, and optionally track a selected scheduled trip on the Lock Screen.

The app is schedule-based. It does not claim to show real-time train operations.

## Required Disclaimer

Include this disclaimer in its own untitled card directly below the app identity and version in the Information sheet:

> Next PATCO Train is an unofficial PATCO schedule app and is not affiliated with or endorsed by PATCO or the Delaware River Port Authority.

The Information sheet should include links to:

- Official PATCO website
- PATCO X account, `@ridepatco`, as an external reference for alerts

Open the official PATCO website inside the app using `SFSafariViewController`. Open the PATCO X account externally to avoid X's blocking web-app promotion modal.

The Information sheet should also clarify:

- `Departures, widgets, and Lock Screen views show scheduled times only. They do not reflect real-time train movement.`
- Driving reachability estimates include an additional parking-lot-to-platform access buffer.
- Users can add a Siri phrase through Shortcuts for actions like asking for the next PATCO trains.
- The active base GTFS feed's final valid service date.
- The app's privacy behavior and a link to the privacy policy.
- Third-party open-source software attribution and full license text.

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
- Show the marketing version in the Information sheet as `Version 1.1.0`; do not expose the internal build number in that label.

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
   - Change the same button to `Return to [saved origin] departures` so the rider can restore the saved route.
   - Automatically restore the saved route after the rider leaves the station threshold.
6. User can tap a departure row to view scheduled departure details.
7. User can start or remove a Live Activity from the departure detail sheet.

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
- Info button opens the Information sheet

Top route card:

- Prominent route pair, for example `Ashland to 15/16th and Locust`
- Compact direction and ride duration under the route pair, for example `Westbound • 26 min`
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
  - `Return to Ashland departures` when Woodcrest is temporarily active and Ashland is the saved origin.
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
- Keep the title, controls, and labels on one row at compact iPhone widths. Preserve the controls' intrinsic widths and dynamically scale the title rather than truncating any text.
- Compact car/walk mode toggle, labeled `Car` or `Walk`, near the map and refresh controls.
- Single map/directions button labeled `Map`; do not repeat the map action on every departure row.
- Refresh button at the far right.
- Current refresh timestamp: `Schedule checked 7:40 PM`
- Contextual reachability guidance:
  - At station: `You're at [station] station. Departures below leave from here.` Show this once in a prominent green status strip above the list rather than repeating `At station` on every departure.
  - Driving: `Reachability includes driving time plus time to park and walk to the platform.`
  - Walking: `Reachability uses your estimated walking time to [station] station.`
- Scrollable list of scheduled departures

Unavailable-state recovery actions:

- If the schedule is unavailable or expired, offer `Refresh Schedule`, show progress while refreshing, and prevent duplicate taps.
- If no upcoming departures are available for the selected direction, offer `Reverse Route`.
- If location is unavailable, explain that reachability requires location and provide the appropriate permission or Settings action.

If PATCO website alerts are available, show an alerts card. If no alerts are available, hide the card entirely.

## Departure Rows

Each row should show:

- Departure time
- Time until scheduled departure as `in Xm` or `in X hr Ym`
- Arrival time line: `Arrives 8:28 PM`
- Reachability badge when relevant; do not repeat an `At station` badge on every row because that state is presented once above the list
- Special schedule adjustment badge when relevant:
  - `Adjusted from 7:52 PM`
- Disclosure indicator showing that the row opens details

Row tap behavior:

- Tapping the row opens the departure detail sheet.
- Lock Screen tracking is intentionally omitted from list rows to reduce visual weight and avoid an unclear icon-only action. Users manage it from departure details.

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
- Keep the title and circular close control pinned above the scrolling content so dismissal is always available.

Visual priority:

1. Route pair
2. Direction and ride duration
3. Scheduled departure
4. Scheduled arrival
5. Lock Screen tracking action
6. Fare
7. Extras
8. Route map
9. Scheduled stops

Include:

- Route pair above the times, kept on one line with dynamic text sizing.
- Direction and ride duration directly under the route pair rather than in a separate card.
- Labels `Scheduled Departure` and `Scheduled Arrival`; keep their time values prominent without overwhelming the rest of the card.
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
  - Title format: `[n] remaining stops`
  - Do not include the starting station
- Each scheduled stop links to that station's official PATCO information URL from the GTFS feed and opens it in an in-app web view.
- Route map above scheduled stops, expanded by default and not collapsible.
- Route map title: `Route map`
- Use a gold circular train marker for the origin, small white circles with wine outlines for intermediate stops, and a wine circular flag marker for the destination. Pad the map framing so endpoint markers are not crowded against its edges.
- Present the Lock Screen action as a secondary bordered control rather than the dominant primary action.
- After the scheduled departure time passes, slightly dim the scheduled time values and make the solid-wine `Scheduled departure time has passed` badge the primary status signal.
- Do not show a separate destination-station information section below the stops. It is redundant because the destination is the final scheduled stop and already includes its station-information action.
- Prevent swipe-to-dismiss on in-app schedule PDF and official PATCO web views; require the visible close control.

## Schedules

The app includes a bundled PATCO GTFS schedule as an offline fallback and can replace it with a validated, downloaded feed without requiring an App Store release.

GTFS feed updates:

- Discover the current ZIP download from PATCO's developer page over HTTPS.
- Download, safely extract, and parse the required GTFS text files on-device.
- Support quoted CSV fields, UTF-8 byte-order marks, and LF, CRLF, or CR line endings.
- Normalize known PATCO station-name formatting differences before validation.
- Validate the publisher, PATCO route, station coverage, calendars, trips, stop times, and schedule dates before replacing the current feed.
- Persist the parsed feed and metadata in App Group storage so the app and widgets share the same schedule.
- Prefer a valid cached feed at launch and fall back to the bundled feed when no cache is available.
- Check for a replacement once per day when the feed is within seven days of expiration. After expiration, retry no more than hourly.
- Use ZIPFoundation for ZIP extraction. Pin the resolved Swift package version and provide its MIT attribution in the app.
- If the active feed is expired and no replacement can be loaded, show `Schedule update needed` rather than presenting stale departures as current.

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
- The Information sheet includes `Refresh Schedule`, which forces a fresh GTFS download even when the current feed has not expired. Place the active feed's valid-through status directly above this button and explain that schedules update automatically while manual refresh checks immediately. Disable duplicate taps and show progress while refreshing.
- On success, reload departures and widget timelines and update the displayed valid-through date. Use concise result text: `Schedule refreshed.` when data changes and `Schedule is up to date.` when it does not.
- On failure, show `Unable to refresh the schedule. Try again.` If the current schedule cannot be loaded, explain that the refresh could not proceed for that reason.

## Alerts

Website alerts:

- Pull active PATCO website alerts.
- Hide alerts box entirely when there are no relevant alerts.
- Avoid showing unrelated informational links such as service animals.
- Preserve alert/advisory dates because the effective date is user-critical.
- Filter out stale date-specific advisories once their date has passed.
- Advisory text must wrap fully; do not truncate service-advisory content.
- When alerts exist, present a compact summary that can expand to show additional alerts. Keep the section hidden when there are none.

X/Twitter:

- PATCO posts some alerts on X at `@ridepatco`.
- Without a hosted backend/API token, do not scrape or pull tweets directly in the app.
- Provide an Information-sheet link to the X account instead.

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
- Keep each departure on a single compact row. Do not add `Tomorrow` or weekday labels beneath widget departure times because the extra line can overflow compact and medium widgets; widgets always list the next upcoming departures in chronological order.
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

- Departure detail sheet: `Show on Lock Screen`

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
- Before the first system permission prompt, show a one-time explanation that location enables reachability and at-station detection. `Not Now` dismisses it without repeated startup prompting.
- When permission is unavailable, show `Reachability unavailable - enable Location Services` with an appropriate `Enable Location`, `Open Settings`, or `Refresh Location` action.
- Include the same contextual location action in the Information sheet's Reachability section when permission is not available.
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
- Information sheet should use this order:
  - Compact app identity and marketing version
  - Untitled unofficial-app disclaimer card
  - Official PATCO website and `@ridepatco` links
  - Schedule Information, with the valid-through status directly above the high-contrast `Refresh Schedule` button
  - Reachability
  - Siri Shortcut
  - Privacy
  - Open Source Software as the final section
- Avoid excess space between the Information navigation title and app identity header.
- Keep the Information title and its 46-point circular close control pinned above the scrolling content, matching the Departure Details dismissal treatment.
- The Open Source Software section attributes ZIPFoundation 0.9.20 and links to a document-style screen containing the project URL and complete MIT license text.

## App Store Assets

### Screenshot Set and Order

Create fresh screenshots from the current release build. The recommended upload order is:

1. Main departure list showing upcoming trains and reachability guidance.
2. At Station experience showing the detected station and the option to view departures from that station.
3. Departure Details showing the route, scheduled departure and arrival, fares, accessibility, and route stops.
4. Medium Home Screen widget showing the saved route and upcoming scheduled departures.

Use numbered filename prefixes such as `01-`, `02-`, `03-`, and `04-` to preserve the intended upload order. Do not display sequence numbers within the screenshot artwork itself.

### Screenshot Content

- Use actual, current app UI rather than reusing screenshots from an earlier release.
- Screenshots may include concise promotional headlines and supporting text, provided all claims accurately describe the current app.
- Remove calendar dates, special-schedule dates, and relative day labels such as `Today`, `Tomorrow`, or weekday names from promotional screenshots.
- Scheduled departure and arrival times, trip durations, station names, and schedule status may remain visible.
- Do not display sequence numbers inside the images.
- Do not include personal information, private data, debug controls, placeholders, Simulator chrome, or unrelated Home Screen content.
- Keep the app UI legible and unobstructed. Copy must describe scheduled service accurately and must not imply that the app provides real-time train movement.
- The At Station screenshot should clearly show the current-station card, departures from the detected station, and the action for returning to the saved starting station.
- The widget screenshot should show the medium widget by itself in a horizontal composition.

### Technical Requirements

- App Store Connect accepts between 1 and 10 screenshots for each device size and localization.
- Screenshots must use JPEG, JPG, or PNG format and must not contain an alpha channel or transparency.
- Use `1242 x 2688` pixels for the three portrait app screenshots.
- Use `2688 x 1242` pixels for the horizontal medium-widget screenshot.
- Apple also accepts `1284 x 2778` portrait and `2778 x 1284` landscape screenshots for the same display class, but a submitted set should use consistent dimensions and orientation for comparable screens.
- Export final submission assets as RGB JPEG files and verify dimensions and alpha status before upload.

Current filename convention:

- `01-Know-Which-Train-You-Can-Catch.jpg`
- `02-At-Station-Departures.jpg`
- `03-See-The-Full-Trip.jpg`
- `04-Home-Screen-Widget.jpg`

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
