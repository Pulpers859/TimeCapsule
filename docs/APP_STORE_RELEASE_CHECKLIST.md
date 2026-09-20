# App Store Release Checklist

Everything between the current `main` and a submittable build. Code items that
are already done are listed under "Landed" so nothing gets redone.

The items under **Blocked on you** cannot be finished by an agent: they need a
decision, a hosted URL, or an App Store Connect account.

---

## Blocked on you

### 0. Naming — decided, and why

The app was called **Time Capsule** until this commit. That is a **registered
Apple trademark** — it appears twice on
[Apple's own trademark list](https://www.apple.com/legal/intellectual-property/trademark/appletmlist.html)
("Time Capsule®" and "AirPort Time Capsule®"), and App Review Guideline 5.2.1
forbids using a third party's trademark in an app name. Submitting a mark Apple
owns, to Apple's own store, was not a bet worth taking — and it also meant the
name could never be registered or defended.

Now **Attic**. Screened against Apple's trademark list (absent) and the App
Store (no consumer photo, memory or journaling app of that name). Around 30
other candidates were eliminated, most of them because the names that say what
the app does most obviously are exactly the names everyone else already took.

**This screening is not a clearance search.** It catches obvious collisions and
well-known brands. It does not catch pending USPTO applications, unregistered
common-law marks, or foreign registrations. Pay a trademark attorney for a real
Class 9 clearance before submitting.

Deliberately unchanged: the Xcode project, scheme, target, source directory and
internal type names are still `TimeCapsule`. The display name and the project
name do not need to match, and renaming those would touch the CI workflow
paths, `Package.swift` and the branch-policy hook for no user-visible gain.

The App Store **subtitle** is where "on this day" belongs — descriptive phrases
are useful there and can't be the mark. Something like
*"Attic — your photos, on this day, every year."*

### 1. Bundle identifier — permanent, decide before the first upload

`PRODUCT_BUNDLE_IDENTIFIER` is still `Patrick-App.TimeCapsule`.

This is **immutable once the app record exists**. Changing it later means
shipping a new app and abandoning every review, rating and rank the original
earned. Cost to change now: nothing. Cost to change after the first upload: the
product's identity.

It also isn't valid reverse-DNS and reads as a placeholder to anyone who
inspects the binary.

Set it to reverse-DNS of a domain you control, e.g. `com.yourdomain.attic`.
It appears four times in `TimeCapsule.xcodeproj/project.pbxproj`: twice for the
app and twice for the widget, whose identifier must stay a suffix of the app's
(`<app id>.AtticWidget`) or the extension will not be accepted. The App Group in
item 5 should be renamed to match at the same time.

Note the bundle ID should now derive from whatever domain you pick for Attic,
not the old name.

### 2. Privacy policy — a certain rejection without it

Guideline 5.1.1(i), verbatim:

> All apps must include a link to their privacy policy in the App Store Connect
> metadata field **and within the app in an easily accessible manner**.

This applies to every app, including one that collects nothing. There is
currently no privacy policy link anywhere in the app or the repo.

Needs: a hosted URL, then a row in `SettingsView` linking to it. The policy
itself is short for this app — photos never leave the device; a memory's
coordinates go to Apple Maps for place names; no analytics, no accounts, no
third-party SDKs.

### 3. Price

`TimeCapsule.storekit` carries **$4.99** as a placeholder. The real price is set
in App Store Connect; the config file only affects simulator testing.

### 4. App icon format

`Attic.jpg` is a valid 1024×1024 JPEG and Xcode's single-size mode is
supported, so this is insurance rather than a blocker. But rejection reports for
`ITMS-90704` consistently involve non-PNG icons, and Apple's docs don't state
the requirement either way.

Convert to a flat 1024×1024 PNG **in an image editor**, not a script — the JPEG
carries an EXIF orientation tag, and a blind re-encode can silently rotate it.

The `dark` and `tinted` entries in `Contents.json` have no file, so iOS
auto-derives them. Legal, but a paid app is shipping a system-generated icon
rather than a designed one.

### 5. App Group — the widget reads the wrong settings without it

The widget runs in its own process and cannot see the app's
`UserDefaults.standard`, so the memory range and day-start hour live in a
shared App Group suite: **`group.Patrick-App.TimeCapsule`**, declared in
`Config/Attic.entitlements` and `Config/AtticWidget.entitlements`.

Enable **App Groups** on both the app and the widget in the developer portal
and register that identifier. If the bundle identifier changes (item 1), change
the group with it — it is referenced in one constant,
`AtticDefaults.appGroupIdentifier`, plus the two entitlement files.

**This fails silently if skipped.** `UserDefaults(suiteName:)` returns nil when
the group is not provisioned, and the code falls back to `.standard` rather
than crashing. In the app everything keeps working; in the widget the memory
range silently reverts to the free-tier default. Nothing logs an error.

### 6. Account prerequisites

Signed Paid Applications Agreement, banking and tax forms completed, screenshots
at the required device sizes, and the IAP product created in App Store Connect
with product ID **`attic.pro.lifetime`** (must match
`AtticPro.productID` exactly).

---

## App Store Connect review notes — copy this in

The single highest-probability *review* rejection for this app is a reviewer
opening it and seeing an empty screen. The default memory range is the exact
day only, so unless the review device happens to hold a photo taken on today's
month and day in a previous year, the app correctly shows "No Memories Today" —
and that reads as broken.

Suggested notes:

> Attic shows photos and videos taken on today's date in previous years,
> read from the device's own photo library. Nothing is uploaded.
>
> **To see the app populated**, the test device needs photos whose capture date
> is today's month and day in an earlier year. If the library has none, the app
> correctly shows an empty state. You can widen the search from Settings →
> Memory range, which looks at nearby days as well. (Memory range is part of the
> paid Attic Pro unlock; see below.)
>
> **In-app purchase:** one non-consumable, `attic.pro.lifetime`, which
> unlocks recap videos, the widened memory range, and late-night grouping. The
> whole daily browsing experience is free. Restore Purchase is in Settings →
> Upgrade and is reachable without buying anything.
>
> **Photo library access** is read-write and used for three things, all
> user-initiated: showing memories, deleting a memory (which goes to Recently
> Deleted via the system confirmation sheet), and adding a memory to an
> "Attic Edits" album so it can be edited in Photos. Limited access is
> supported as a first-class state.
>
> **Location:** no location permission is requested and the device's current
> location is never read. When a photo already contains coordinates, those are
> sent to Apple Maps to name the place.

---

## Privacy nutrition label

No confirmed Apple source settles whether coordinates handed to a first-party
MapKit request count as developer collection — Apple's framework makes the
request and the app never receives or retains the result.

Two defensible answers:

- **Data Not Collected.** What most on-device photo apps declare, and arguably
  correct.
- **Location → Coarse Location**, purpose App Functionality, not linked to
  identity, not used for tracking. One extra row, and it removes any argument.

The second is the better trade for a paid app. Whichever you pick, keep
`NSPrivacyCollectedDataTypes` in `PrivacyInfo.xcprivacy` consistent with it.

`NSPrivacyTracking` stays `false`. There is no ATT, no IDFA, no third-party SDK
and no remote package dependency.

---

## Must be tested on hardware

None of this has run on a device or in a simulator. Every code change below was
verified only by the CI build.

- [ ] **iOS 18 appearance.** Liquid Glass is gated behind `if #available` with a
      material fallback. That fallback has never been rendered. It floats over
      photos, where contrast is the entire problem. Open it in an iOS 18
      simulator and look at the viewer chrome, the filter chips, and the delete
      button against both a bright and a dark photo.
- [ ] **Purchase flow** against the `.storekit` config: buy, restore, Ask to Buy
      (pending), and refund. The scheme already points at the config, so this
      works in the simulator before anything exists in App Store Connect.
- [ ] **Sandbox purchase** on a real device once the product exists.
- [ ] **Snapchat video share** — the original reason the share path was rewritten.
- [ ] **Recap export** with the screen locking mid-export, and with the app
      backgrounded mid-export. Both used to fail.
- [ ] **Audio:** videos now play with the ring switch silenced, and music resumes
      after leaving the viewer. Note that auto-play on swipe now takes over
      audio, matching Photos. If that feels wrong, the alternative is muted
      auto-play with tap-to-unmute — a product decision, not a technical one.
- [ ] **Widget, all four families** — small, medium, lock screen rectangular,
      lock screen circular — plus StandBy. None of this has been rendered.
      Check the label stays legible over a bright photo and a dark one, since
      the gradient scrim is the only thing separating them.
- [ ] **Widget with the App Group provisioned**, confirming a widened memory
      range in Settings actually changes what the widget shows. This is the
      silent-failure path described above.
- [ ] **Widget empty and no-access states**, the second by revoking photo
      access in Settings.
- [ ] **Widget freshness** — delete a memory in the app, background the app,
      confirm the widget drops it rather than waiting for tomorrow.
- [ ] **Recap export timing.** Motion took the encode from ~180 frames to
      ~1700. It should still finish in a reasonable time on the oldest device
      you intend to support, and must not be jetsammed partway.
- [ ] **Recap framing** — confirm the push lands on faces and that the
      crossfade between a portrait and a landscape photo has no visible pop.
- [ ] **Swipe performance** on a large library with the memory range widened.
- [ ] **Delete** from both the grid and the viewer, checking the gallery and the
      notification count stay in step.
- [ ] **Feb 29** behaviour, if you can set the device clock.
- [ ] **EXIF display** against a real camera photo (aperture/shutter/ISO/lens
      all present), a screenshot (section should not appear at all), and a
      photo saved from Messages or WhatsApp (usually stripped of EXIF —
      confirm that degrades to no section rather than a broken one).
- [ ] **Feature Less Often**, all three axes: exclude a photo and confirm it
      disappears from the grid, the pager, and tomorrow's notification count
      without a relaunch; exclude an album and confirm every member vanishes,
      including one added to that album after the exclusion; exclude a place
      and confirm nearby-but-not-identical coordinates (a second visit to the
      same café) are also caught. Then undo each from Settings → Featured
      Less Often and confirm the memory returns.
- [ ] **Merged grid view** — toggle to "All Together" on a day spanning many
      years, confirm the year badges read correctly and the tap order into
      the pager matches what "By Year" would have opened to for the same
      photo.
- [ ] **Recap crossfades**, specifically. The transitions were compositing
      the two slides so their weights summed to 0.75 at the midpoint — every
      transition dipped about 25% dark for half a second. It is now an
      additive blend. Watch a recap made from two similarly-framed photos,
      where the overlap is largest, and confirm the transitions hold their
      brightness instead of pulsing.
- [ ] **Widget with a large album excluded.** Exclude an album with
      thousands of photos, then confirm the widget still refreshes at the day
      boundary rather than freezing on a stale photo. This was a real
      jetsam risk before the album lookup was bounded to the queried dates.
- [ ] **Exclude a cloud SHARED album**, then open the gallery, let a
      notification schedule run, and let the widget refresh. PhotoKit raises
      an Objective-C exception — uncatchable from Swift, so the process dies
      — if a fetch inside a shared album carries a predicate, and bounding
      that lookup is exactly what introduced one. Shared albums are now
      fetched unbounded to avoid it; this confirms the guard is in the right
      place. Highest-value single test on this list.
- [ ] **Widget's first PhotoKit call on a clean install.** The extension
      reads the photo library and had no `NSPhotoLibraryUsageDescription` of
      its own; purpose strings are read from the accessing binary, so the
      extension was at risk of being terminated outright. One has been added
      to both widget configs — confirm the widget actually renders.
- [ ] **Widget on an iCloud-optimised library.** It never goes to the
      network, so an original with no local rendition yields no image.
      Confirm the placeholder glyph appears rather than a black tile
      captioned with a year, which reads as a broken widget.

---

## Landed

Config and submission
- Privacy manifest declares `NSPrivacyAccessedAPICategoryFileTimestamp` / C617.1
  (an undeclared required-reason API is refused at **upload**, not review)
- iPhone-only device family
- `ITSAppUsesNonExemptEncryption = NO`
- `CFBundleDisplayName = "Attic"`
- Photo library purpose string now describes delete and album-write, not just
  viewing
- Deployment target lowered from 26.1 to 18.0

Monetization
- StoreKit 2 non-consumable unlock, entitlement always from
  `Transaction.currentEntitlements`
- Paywall, Settings upgrade section, Restore control
- `.storekit` config wired into the scheme

Widget
- Home screen (two sizes), lock screen and StandBy, reading the photo library
  directly so it is correct without the app being opened
- Shares `MemoryLibrary` with the gallery, so widget and grid cannot disagree
- Reloads at the day boundary, and when the app is backgrounded
- Rotates through up to four memories, one per year first

Recap quality
- Eased pan and zoom on every slide, anchored on faces via on-device Vision
- Screenshots excluded from recaps; favourites can displace a neighbouring pick
- Slide staging moved off the main actor (it was blocking the UI before)

Viewer and browsing
- Camera EXIF (model, lens, aperture, shutter speed, ISO, focal length) shown
  in the memory info sheet alongside the existing date, dimensions, and map
- "Feature Less Often" — exclude a photo, an album (including anything added
  to it later), or a place (by proximity, not exact coordinates) from ever
  showing as a memory again; undoable from Settings → Featured Less Often.
  Not offered: excluding a *person*. PhotoKit does not expose named People to
  third-party apps at all, so there is no API this could be built against
  short of Attic shipping its own on-device face-identity system.
- Merged grid view — a toggle between the existing per-year sections and a
  single flat grid with a small year badge per tile, for a day whose photos
  span many years but are few in number

Correctness
- Recap slides no longer written with `.completeFileProtection` (failed whenever
  the screen locked mid-export)
- Recap timeouts count polls, not wall-clock (backgrounding no longer loses the
  export)
- No `cancelWriting()` after `finishWriting()` or on a failed writer (was an
  uncatchable crash where an error alert was intended)
- Leap day no longer drops 15 of 20 years when the memory range is widened
- Onboarding privacy copy now matches what the binary does

Performance
- `count(on:)` answers from `PHFetchResult.count` instead of materialising every
  `PHAsset` 60 times per schedule
- Full-screen pager builds three pages instead of every asset in every year
- Media loaders and the Photos edit handoff marked `@concurrent` so they
  actually leave the main actor (`nonisolated` alone does not, under this
  build's `NonisolatedNonsendingByDefault`)
- Settings no longer rebuilds 60 notifications just for being opened
- Exclusion context (excluded albums/places/photos) resolved once per
  60-day notification schedule, not once per day
- Library-change reschedules coalesced; external PhotoKit changes debounced
- Recap exports are swept instead of accumulating in `tmp`
- `AVAudioSession` configured for playback

---

## Known and deliberately not fixed

- **A delete still costs two gallery fetches.** The app's own post and PhotoKit's
  observer both fire. Collapsing them means tracking self-initiated changes,
  which risks missing a genuine external one.
- **No crash reporting.** Recommend MetricKit and Xcode Organizer rather than
  Firebase or Sentry — a third-party SDK would force
  `NSPrivacyCollectedDataTypes` off empty and break the promise on the app's own
  onboarding screen.
- **iCloud-only assets show a bare spinner** with no progress and no timeout.
  Real gap on a slow connection; not yet addressed.
- **A lapsed entitlement drops to free-tier behaviour on the next in-app
  refresh, and only then.** `MemoryWindow` gates the two Pro settings on
  `AtticDefaults.isProEntitled`, a cached answer written at launch, on every
  foreground, and on any StoreKit transaction update. This replaced resetting
  the stored values outright, which destroyed a paying user's preferences
  whenever a reading merely looked empty — a verification failure, or a
  device restored from backup mid-sync. The trade is deliberate: a cache that
  is briefly stale costs a refresh; a destructive reset cost the user their
  settings with no way back.

  The real limit is that only the app can write that flag. StoreKit is not
  reachable from a widget extension or from the notification scheduler, so
  someone who is refunded and then never opens Attic again keeps the widened
  memory range on their home screen and in their notification counts
  indefinitely. Closing that would need a server-side receipt check, which
  this app deliberately has no backend for.
- **Test coverage** is four pure-logic files. Everything touching PhotoKit, UI or
  StoreKit is untested and unreachable from the SwiftPM target.
