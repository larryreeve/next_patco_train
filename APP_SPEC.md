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

- Center title: a compact `Next PATCO Train` wordmark with a gold tram mark, a semibold `Next`, bold `PATCO Train`, and a thin gold underline.
- Current date under the title, formatted like `Thu, Aug 20`, with clear separation from the title.
- Info button opens the Information sheet

Top route card:

- Prominent route pair, for example `Ashland to 15/16th and Locust`
- Compact direction and explicitly labeled ride duration under the route pair, for example `Westbound • 26 min ride`, so it cannot be mistaken for time until the next departure.
- Small `Change` button in the route card
- Keep the collapsed card visually compact so the navigation title and date picker remain distinct. Use tight vertical spacing and padding while preserving the one-line route pair and summary.
- Leave deliberate space between the date picker and the route card so the navigation identity and trip context read as separate groups.
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
  - A concise event description from the schedule listing when one fits; otherwise omit the subtitle for today and show the affected date for a future selection.
  - `View PDF`
- Opens source PDF in-app

Scheduled departures card:

- Title: `Scheduled Departures`
- Use a clear two-row header: title and subdued update timestamp with compact labeled Map and Refresh actions on the first row; Car/Walk segmented control on the left and the selected station plan on the right on the second row. Preserve the controls' intrinsic widths and dynamically scale the title rather than truncating text.
- Present `Car` and `Walk` as a compact segmented control with an unambiguous wine-colored selected state.
- Use compact, vertically stacked icon-and-label Map and Refresh actions with 38-point circular icon targets and legible 9-point labels; do not repeat the map action on every departure row. While refreshing, retain the Refresh control's footprint and label, replacing only its arrow with an hourglass.
- Show a subtly indented timestamp beneath the title, such as `Departures updated 7:40 PM`.
- Contextual reachability guidance:
  - At station: `Showing departures from [station] based on your location.` Show this once in a prominent green status strip above the list rather than repeating `At station` on every departure.
- Driving and walking: place a subtle vertical divider after the left-aligned mode selector, then left-align the station plan as a concise labeled line followed by a larger, high-contrast arrival estimate, for example `Drive to Ashland` then `Arrive about 8:56 PM if leaving now`. Use `&` in this compact plan only when a station name contains `and`.
  - When location is not fresh, show a subdued secondary line such as `Location updated 3 mins ago`.
- Scrollable list of scheduled departures
- Let the card end near the final row for short schedules. Render a content-sized list when it fits; fall back to a scrollable list only when the departure rows exceed the available height.

Unavailable-state recovery actions:

- If the schedule is unavailable or expired, offer `Refresh Schedule`, show progress while refreshing, and prevent duplicate taps.
- If no upcoming departures are available for the selected direction, offer `Reverse Route`.
- If location is unavailable, explain that reachability requires location and provide the appropriate permission or Settings action.

If PATCO website alerts are available, show an alerts card. If no alerts are available, hide the card entirely.

## Departure Rows

Each row should show:

- Departure time as the dominant value, followed by a smaller muted arrival label on the same line: `Arrives 8:28 PM`
- Time until scheduled departure, right aligned as `in Xm` or `in X hr Ym`
- When an upcoming departure is on a later service day, place its `Tomorrow` or weekday marker on a compact line beneath the timing row rather than compressing the departure, arrival, and countdown values.
- Reachability badge when relevant for departures within the next hour; do not repeat an `At station` badge on every row because that state is presented once above the list. Every `Likely to make this train` or `Timing is tight` departure in that decision window includes leave-by guidance, for example `Likely to make this train · Leave by 8:45 PM`, so riders can compare their options. Later departures show schedule information only because travel conditions may change.
- When a departure cannot be caught, use a concrete timing explanation such as `You'd miss this train by about 4 mins` instead of a generic unavailable or too-late label.
- For today's route, retain the rest of the service-day schedule. Separate departures more than one hour away with a `Later departures` divider. Reachability and leave-by guidance are limited to the next hour because travel conditions may change; later rows show schedule information only. Keep missed-train badges visually quieter than reachable green and yellow guidance. Give the first likely-to-make-this-train badge the strongest green treatment, with later likely options shown in a lighter green.
- Show no per-row special-schedule note when the departure matches the base feed; the schedule-level banner already identifies the applied special schedule.
- For departures that differ from the base feed, show a muted note distinct from reachability badges:
  - `Adjusted from 7:52 PM` for a nearby, one-to-one match with a base-feed departure
  - `Departure added by special schedule` when there is no nearby unmatched base-feed departure
- Give every special-schedule change a subtle treatment so it is scannable independently of catch guidance: a normal card surface with a slim wine edge and struck-through time for removed departures, a normal card surface with a slim plum edge for adjusted times, and a normal card surface with a slim blue edge for added departures. Keep these colors distinct from green/yellow/red reachability badges.
- In the main departure list only, retain a standard-schedule departure that a special schedule removes. Render its departure and arrival times with a strikethrough and show `Departure removed by special schedule`; do not show a countdown, reachability, leave-by time, disclosure indicator, or departure details for that canceled row. Widgets, Siri, and Lock Screen views list active departures only.
- When GTFS contains duplicate service candidates for the same canceled departure minute, render one canceled row for that schedule slot.
- When a special departure is matched as an adjustment, do not also show any canceled row at its original departure time, including duplicate regular GTFS candidates for that same physical departure.
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
  - For Philadelphia PATCO stations, default to walking only while the user is within the automatic walking range; an explicit car selection still remains authoritative until arrival.
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
- In departure details, pair a reachable train's leave-by guidance with its station-arrival deadline: `Leave by about 8:15 AM to arrive at the station by 8:37 AM`. The station-arrival deadline reserves the mode-specific access buffer for reaching the platform.
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
  - `Show on Lock Screen` when no matching activity exists and the app has not determined that the rider will miss the departure. Keep it available when reachability is unknown.
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
  - Title format: `[n] stops` (or `1 stop`)
  - Do not include the starting station
- Each scheduled stop links to that station's official PATCO information URL from the GTFS feed and opens it in an in-app web view.
- Route map above scheduled stops, expanded by default and not collapsible.
- Route map title: `Route map`
- Use a gold circular train marker for the origin, small white circles with wine outlines for intermediate stops, and a wine circular flag marker for the destination. Pad the map framing so endpoint markers are not crowded against its edges.
- Present the Lock Screen action as a secondary bordered control rather than the dominant primary action.
- Below the catch guidance, show shared travel context first as a car/walk icon and `Drive to [station]`. Then use two compact, left-aligned groups with matching paired-time presentation. `If you leave now` compares the current `Leave current location` time with `Arrive at station about [time]`.
- A restrained divider introduces `To make this train`, with paired `Leave current location by` and `Arrive at station by` deadlines. Qualify the station-arrival time with `about`, because it combines travel-time estimation with a fixed platform-access buffer.
- Keep metadata labels (`Direction`, `Ride time`, `Scheduled Departure`, and `Scheduled Arrival`) quieter than their values, and provide generous vertical separation between fares and the bike/accessibility row.
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
- Check PATCO's source for a replacement once per day whenever the app is active, regardless of the feed's valid-through date. Use a fresh network request and compare the complete validated feed so corrected schedules and new feed versions with the same end date can replace the cache. After expiration, retry no more than hourly.
- Use ZIPFoundation for ZIP extraction. Pin the resolved Swift package version and provide its MIT attribution in the app.
- If the active feed is expired and no replacement can be loaded, show `Schedule update needed` rather than presenting stale departures as current.

Departure filtering:

- Show all upcoming scheduled departures for the current service day.
- Near midnight, if the current day has too few remaining departures, include the next day’s first few departures.
- If a special schedule exists for the next day, use it for next-day departures.
- When a rider selects a future departure date, show cached special schedules immediately, check PATCO for that service date, then rebuild the visible departure timeline with any newly available special schedule. Include the prior service date for trips crossing midnight.

Special schedules:

- Detect active PATCO special schedules from PATCO website/PDF source.
- Recognize schedule links whose date is followed by an event description, and preserve skipped-station markers in PDF timetable rows so early or limited-stop trips are not dropped or assigned to the wrong stations.
- Load cached special schedules immediately so departure rendering does not wait for PATCO's website or PDF processing.
- Coordinate the app, widget, and Siri through shared App Group last-check timestamps per service date and check PATCO at most once per hour for each selected date.
- Permit a new check immediately when the PATCO calendar day changes, regardless of the hourly limit.
- Fetch the schedule webpage once per check and use it to resolve special schedules for today and tomorrow.
- Download a special schedule PDF only when one applies to the requested service dates.
- Explicit departure refresh actions bypass the hourly limit; location-only refreshes do not.
- Run automatic special-schedule networking independently from the main departure and reachability refresh path.
- Parse/extract the special schedule.
- Override built-in schedule for the affected service date.
- Compare special schedule against built-in schedule where possible.
- Compare special and regular departures by their actual calendar departure date, not only their GTFS service date. PATCO can encode early-morning regular trains as `24:xx` on the prior service day while the PDF uses `12:xx AM` on the special-schedule date; display the special timetable once and do not also render that regular candidate as removed.
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
- In the schedule status block, identify PATCO as the schedule-data source and display the loaded base GTFS feed version when one is available. Also show the last check timestamp, the last actual schedule-update timestamp, and the prior feed version. A download that matches the existing schedule is a check, not an update; preserve the last-update fields until a changed feed replaces the persisted schedule. For the bundled schedule or migrated metadata without update history, state that the last update was included with the app and that the prior version is unavailable.
- Present the privacy policy as a native in-app page populated from the repository's raw `privacy.md` file. Show loading and retry states, preserve external links, and offer the GitHub page as a fallback when the raw policy cannot be loaded.
- On success, compare the validated downloaded schedule with the persisted base schedule, excluding source metadata. Reload departures and widget timelines only when schedule content changes. Use concise result text: `Schedule updated.` when data changes and `Current schedule is the latest.` when it does not.
- Always compare a downloaded GTFS feed with the persisted base GTFS feed, never with a temporary PDF-derived special-schedule feed that may currently be applied for display.
- Refreshing the base GTFS feed must not replace an applicable PDF-derived special schedule in the current experience. After loading an updated base feed, reapply cached special schedules before recalculating visible departures or reloading widgets.
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
- Keep the Information-sheet link to the X account.

## Widgets

Widget diagnostics:

- The Information screen links to a local-only Widget Diagnostics view with Widget, App, and All filters, defaulting to Widget. Hide the diagnostics card from the normal Information screen and reveal it only after a special five-tap gesture on the app identity header. Retain the last 100 widget events and last 100 app events independently in the shared App Group, with refresh and clear controls.
- Group each timeline-provider invocation into one diagnostic record with second-precision start time, location outcome and age, total duration, departure count, and next requested reload time. Record manual widget location checks separately, since a subsequent timeline run is controlled by iOS.
- Also record app opening, foregrounding, and app-initiated widget reload requests so a widget run can be distinguished from activity while the app is open. A reload request is not proof that iOS ran the widget immediately.
- Distinguish a new fix, a cached fix, a timeout, denied access, and a Core Location error. Never record coordinates, station IDs, or route history.
- Explain that iOS controls actual provider execution and that prebuilt departure entries can advance without another widget run.

Supported widget sizes:

- Small
- Medium
- Large

Widget behavior:

- Widgets should use the same saved route pair as the app via App Group defaults.
- Widgets should orient the route based on the nearest endpoint when location is available.
- Widgets must request and validate their own current location so reachability does not depend on the app being open.
- Use nearest-ten-meters desired accuracy and prefer a valid fix no older than two minutes. Allow up to five seconds for a request and retain a valid system or shared fallback no older than 15 minutes when iOS cannot provide a fresh fix. Label fallback location age rather than presenting it as current.
- Treat widget location as fresh for 0-3 minutes, recent for 3-15 minutes, and unavailable after 15 minutes. Fresh location may show confidence-colored reachability. Recent location may orient the route and explain its age, but should not show green/yellow/red reachability confidence. Unavailable location should show scheduled departures only and prompt the user to open the app for precise reachability.
- Recalculate reachability for each timeline entry using the retained location snapshot only while the snapshot is fresh, and stop calculating and displaying reachability once that snapshot is more than three minutes old.
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
- Prefer battery-conscious timelines. Generate minute-offset display entries for the next hour from one location and ETA snapshot; these entries advance departures without repeatedly waking the extension if iOS delays a reload. When upcoming service exists, request the next timeline after 10 minutes so the widget independently attempts to obtain a new location and ETA. Back off to 30 minutes when no upcoming service is available. These are requested times; WidgetKit controls actual execution.
- While the app is active and receiving meaningful location updates, request a widget timeline reload at most once every two minutes. Route changes, mode changes, and arrival-mode clearing may request immediate reloads.
- App-side widget reload requests must go through one throttled helper so foreground refresh, location updates, special schedule changes, and schedule checks do not trigger overlapping widget runs. Routine app reload requests are throttled for about one minute. Forced route/mode/arrival reloads are allowed immediately but deduped within a couple seconds. Diagnostics should record both executed and skipped app reload requests.
- App and widget may refresh independently, but both must resolve the same shared route, temporary station route, explicit/inferred transportation mode, reachability thresholds, and cached ETA rules so refreshing either surface does not produce a different logical result from the same inputs.
- Recalculate the nearest station within the selected route immediately whenever either route endpoint changes; do not wait for another Core Location callback. While route controls are expanded, update the nearest-route display without overriding the endpoints the user is editing.
- Include an interactive refresh button on supported widget systems. A manual refresh must request a new location and must not use either the shared location cache or `CLLocationManager.location` as a fallback. Allow up to eight seconds for a new fix. If none arrives, show the refresh failure without deleting the previously saved location; that snapshot remains eligible only for a later automatic refresh while it is under 15 minutes old. Final timeline scheduling remains controlled by iOS.
- Implement manual widget refresh as an App Intent-backed `Toggle` with a custom button-like style. Use the toggle's immediate optimistic state to replace the refresh arrow with a stable hourglass symbol while the intent runs, then reset it with the refreshed timeline. Do not rely on an indeterminate `ProgressView`, which may render as an empty circle in an optimistic widget snapshot. Do not invalidate the departure rows or freshness status because redacting and restoring the full content creates a distracting double flash. Ignore duplicate refresh requests and clear stale in-progress state automatically if WidgetKit interrupts the refresh.
- On medium and large widgets, show one concise freshness message. Show `Updated` for a fresh location, and show `Open app to check if you'll make it` when location is recent or unavailable. On small widgets, show the equivalent `location.slash` status icon with accessible wording when location is unavailable.
- Rely on WidgetKit's automatic timeline reload when the refresh App Intent returns; do not also request an explicit reload from that intent because it can cause two visible widget updates.
- Include an interactive car/walk button that displays the current reachability mode. Tapping it switches the shared, origin-specific mode and reloads widget timelines so the app and widgets remain synchronized without requiring the app to open.
- Implement the widget car/walk control as an optimistic App Intent-backed toggle. Replace the current mode icon with the same stable hourglass used by manual refresh while the mode change is processing, then show the new car or walking icon when the updated timeline arrives.
- Keep widget header controls in fixed 30-point footprints and give the title stack layout priority so switching between car, walking, and hourglass symbols cannot resize the `Next PATCO Train` title.
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
- Show a native countdown labeled `Scheduled departure in` in the Lock Screen and expanded Dynamic Island presentations.
- Build the active countdown from one system-managed bounded interval ending at the scheduled departure, showing minutes and seconds. When `isLuminanceReduced` is true, switch to the system-managed relative-date presentation at minute precision, such as `in 4 min`, so Always-On display never shows a partial clock value such as `4:--`. Label the reduced-luminance value `Scheduled departure`; label the active value `Scheduled departure in`. Both variants derive from the system clock; do not use a separately scheduled reduced-luminance timeline.
- Do not put the countdown in compact Dynamic Island regions because native timer text reserves excessive horizontal width there.
- Do not show `On train`, `Departed`, or `Trip in progress` before scheduled departure.

After scheduled departure:

- Set the Live Activity `staleDate` to the scheduled departure and show the countdown only while `context.isStale` is false. This uses ActivityKit's system-managed state transition to remove the complete countdown row at departure without requiring app execution.
- Never use an unbounded relative or timer-style date that begins counting upward after scheduled departure.
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
- Set the Live Activity stale date to scheduled departure so the countdown can clear reliably. Continue clearing expired activities after scheduled arrival plus a short grace period, currently 10 minutes, when the app next receives execution time.
- Clear expired activities on app launch and foreground refresh.

Important Live Activity limitation:

- iOS may throttle or stop app execution. Native bounded timer text can reliably count down and freeze at zero, but arbitrary SwiftUI state calculations may not transition to different content exactly at stop boundaries unless the Live Activity receives an explicit state update.
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
- Location should choose eastbound vs westbound direction based on the nearest route endpoint when the user is not in an active station-to-station journey.
- Detecting the user at the active origin locks the current destination for up to four hours. While locked, crossing the route midpoint or arriving at an intermediate station must not reverse direction; intermediate stations become temporary origins toward the locked destination.
- A fresh, accurate fix inside the active destination-station boundary immediately persists the reversed route and shows return-direction departures. This also completes a journey that temporarily showed departures from an intermediate station. Explicitly saving a route clears the previous journey lock.
- If the user is near another PATCO station that is not part of the route pair, show it only as helpful context, not as route origin.
- Foreground location updates should run while the app is open and request a fresh location at a controlled two-minute interval in addition to CoreLocation's normal updates. Refresh the `Current station: [station]` summary as location changes.
- Route and station state changes should refresh the station summary and departures together, without issuing duplicate departure refreshes from both callbacks and change handlers.
- Destination arrival requires a location fix no older than 30 seconds, reported accuracy within 75 meters, and a position-plus-accuracy radius contained within the 150-meter station boundary. Do not use a fixed dwell timer. On confirmation, update the route and departures together, refresh widgets, end the outbound Live Activity, and show a brief dismissible `Near [station]` confirmation explaining that return departures are shown. Do not wait for the rider to leave the destination geofence. An explicit route selection at the station remains authoritative.
- Reachability should use a stabilized location snapshot, not every raw GPS update. Passive location movement should update reachability only after a meaningful movement threshold or short debounce interval to avoid badges flickering while the user is traveling by car or train.
- Entering or leaving a station is an immediate location boundary event: update the current-station panel, stabilized reachability location, route, and departures in one nonanimated UI transaction rather than waiting for the normal movement or debounce threshold.
- At-station detection uses a 150-meter threshold. Any detected PATCO station automatically becomes the temporary origin when it is not already a route endpoint, while the current destination is retained and the saved route remains unchanged.
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
  - Schedule Information, with valid-through status, current and prior feed-version details, last check/update timestamps, and the high-contrast `Refresh Schedule` button
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
5. Lock Screen Live Activity showing the selected scheduled departure and arrival.
6. Lock Screen widget showing the next three scheduled departures.

Use numbered filename prefixes such as `01-`, `02-`, `03-`, `04-`, and `05-` to preserve the intended upload order. Do not display sequence numbers within the screenshot artwork itself.

### Screenshot Content

- Use actual, current app UI rather than reusing screenshots from an earlier release.
- Screenshots may include concise promotional headlines and supporting text, provided all claims accurately describe the current app.
- Remove calendar dates, special-schedule dates, and relative day labels such as `Today`, `Tomorrow`, or weekday names from promotional screenshots.
- Scheduled departure and arrival times, trip durations, station names, and schedule status may remain visible.
- Do not display sequence numbers inside the images.
- Do not include personal information, private data, debug controls, placeholders, Simulator chrome, or unrelated Home Screen content.
- Keep the app UI legible and unobstructed. Copy must describe scheduled service accurately and must not imply that the app provides real-time train movement.
- The first screenshot caption is: `Know which train you can catch` with `Leave with confidence for your scheduled train.` Show the current Car/Walk selector, station-arrival estimate, missed-train guidance, and a likely departure with leave-by guidance.
- The At Station screenshot should clearly show the current-station card, departures from the detected station, and the action for returning to the saved starting station.
- The second screenshot caption is: `Departures at your station` with `See the next scheduled trains from where you are.`
- The third screenshot caption is: `See the full trip before you go` with `Review scheduled times, fares, the route, and every stop.` Show current Departure Details content, including the likely-to-catch status, shared car/walk travel context, paired `If you leave now` and `To make this train` timing guidance, plus the Lock Screen action.
- The widget and Lock Screen images should preserve their horizontal UI composition within a portrait promotional canvas. Do not upload either raw landscape image into a portrait screenshot set because App Store Connect can rotate it.
- The widget caption is: `Your next trains, at a glance` with `See your saved route and upcoming scheduled departures without opening the app.`
- The Lock Screen Live Activity caption is: `Keep your scheduled trip on the Lock Screen` with `Selected departure and arrival, right on your Lock Screen.`
- The Lock Screen widget caption is: `Your next 3 trains, on your Lock Screen` with `See upcoming scheduled departures without opening the app.` Show its rectangular widget with a compact route title and three scheduled departure times.

### Technical Requirements

- App Store Connect accepts between 1 and 10 screenshots for each device size and localization.
- Screenshots must use JPEG, JPG, or PNG format and must not contain an alpha channel or transparency.
- Use `1242 x 2688` pixels for all five portrait screenshots in this set, including the widget and Lock Screen promotional images.
- Apple also accepts `1284 x 2778` portrait and `2778 x 1284` landscape screenshots for the same display class, but a submitted set should use consistent dimensions and orientation for comparable screens.
- Export final submission assets as RGB JPEG files and verify dimensions and alpha status before upload.

Current filename convention:

- `01-Know-Which-Train-You-Can-Catch.jpg`
- `02-At-Station-Departures.jpg`
- `03-See-The-Full-Trip.jpg`
- `04-Home-Screen-Widget.jpg`
- `05-Lock-Screen.jpg`
- `06-Lock-Screen-Widget.jpg`

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

### Source Organization

- `ContentView.swift` owns app state, navigation, and top-level screen composition. Keep feature-specific presentation and reusable models out of this file.
- `DepartureListView.swift` owns departure-row rendering and special-schedule visual treatment.
- `Reachability.swift` owns travel-mode selection models, travel-time estimates, and catch-status formatting and deadlines.
- `DepartureDetailView.swift` owns the Departure Details sheet, trip stops, fares, station information browser, and Lock Screen Live Activity controls.
- `InformationViews.swift` owns the Information screen, diagnostics, privacy policy, and open-source license views.
- `AlertViews.swift` owns alert presentation helpers, and `PATCOColors.swift` owns the shared app color palette.
- Add every new app source file to the `NextPATCOTrain` target in `NextPATCOTrain.xcodeproj`.

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
