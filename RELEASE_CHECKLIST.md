# Release Candidate Checklist

Copy this checklist into the release PR and fill in evidence for that exact candidate.
Unchecked items are pending, not implicitly covered by an earlier build.

## Candidate Identity

- [ ] Record commit SHA, branch, marketing version and build number.
- [ ] Verify app and extension versions match and the upload build number is unused.
- [ ] Record Xcode version, iOS versions, device models and test date.
- [ ] Record known limitations and an owner for each unresolved release risk.

## Automated Gates

- [ ] Run `zsh Tests/run-checks.sh`; attach the complete log and passing check count.
- [ ] Build app and widget together with the release candidate's configuration.
- [ ] Run `zsh Tests/run-ui-checks.sh`; attach the `.xcresult`, screenshots and test count.
- [ ] Verify journey lifecycle, stale responses, persistence/cross-process recovery,
  ride replays, ETA freshness, special schedules, overnight service and DST tests pass.
- [ ] Verify old diagnostic events still decode and new shared exports contain
  route/journey context and observation times where available.
- [ ] Confirm CI ran on the candidate commit; do not assume a local pass or an
  unpushed workflow has enforced PR checks. Verify required-check branch rules.
- [ ] Review the diff and confirm no test fixtures or simulator switches run in Release.

## Physical Device and Permissions

- [ ] Cold launch and foreground return request location independently of slow or
  failed schedule/alert requests; reachability updates once usable evidence arrives.
- [ ] Exercise not-determined, granted, denied and revoked location permissions;
  include approximate location and changing permission while the app is closed.
- [ ] Verify no-location/offline states retain schedules and do not invent reachability.
- [ ] Start tracking without a Live Activity, lock the phone, relaunch, cancel,
  and restart deliberately. Confirm cancelled/expired trips do not resume themselves.
- [ ] Check manual arrival confirmation and automatic destination arrival; confirm
  return-route selection and retained completion state agree across surfaces.
- [ ] During a real ride, verify map following, manual pan/resume, passed-station
  floor, underground estimates, long signal gaps and signal recovery in both directions.
- [ ] Compare scheduled and estimated times; after evidence expiry, verify schedules
  remain and stale ETAs disappear. Confirm delay labels match displayed minutes.
- [ ] Check largest accessibility text, VoiceOver labels/order, tap targets and dark mode.

## Widgets and Live Activities

- [ ] Test Home Screen and Lock Screen widgets independently, including Lock Screen-only installation.
- [ ] Exercise refresh, route reversal and travel-mode changes repeatedly; compare
  committed route revisions, reachability and displayed departures with the app.
- [ ] Confirm stale guidance expires without requiring a fresh GPS response.
- [ ] Test delayed redraw, overnight rollover, route changes while locked and poor connectivity.
- [ ] Verify Live Activity start, update, arrival, cancellation and expiration.
- [ ] Record actual observed redraw behavior and timestamps. "Timeline prepared" or
  "reload requested" is not evidence of on-screen delivery.

## Archive and Release

- [ ] Archive the reviewed candidate in Release, validate signing/entitlements and
  install the processed distribution build through the intended testing channel.
- [ ] Recheck launch, widgets, permissions and upgrade preservation on that build.
- [ ] Review store metadata, screenshots, privacy disclosures and release notes
  against the actual candidate; retain known limitations in the release record.
- [ ] Record the chosen release/rollback approach and retain the previous source tag.
- [ ] After approval/release, verify the published version and update the app spec,
  GitHub tag and release notes to the exact released commit.

## Evidence Record

| Evidence | Result / artifact / reviewer |
| --- | --- |
| Commit and version/build | Pending |
| Automated regression log | Pending |
| Build and UI result bundle | Pending |
| Device and permission checks | Pending |
| Real-ride observations | Pending |
| Widget/Live Activity observations | Pending |
| Upgrade and distribution-build check | Pending |
| Known limitations and release decision | Pending |

Simulator fixtures do not establish physical GPS accuracy, WidgetKit delivery,
ActivityKit presentation, energy use, or every accessibility interaction. Reconstructed
ride logs lack ground-truth coordinates. Sign off those limits explicitly; do not
substitute a successful deploy for device QA.
