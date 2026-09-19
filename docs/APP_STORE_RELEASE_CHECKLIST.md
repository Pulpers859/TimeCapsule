# App Store Release Checklist

Everything between the current `main` and a submittable build. Code items that
are already done are listed under "Landed" so nothing gets redone.

The items under **Blocked on you** cannot be finished by an agent: they need a
decision, a hosted URL, or an App Store Connect account.

---

## Blocked on you

### 1. Bundle identifier — permanent, decide before the first upload

`PRODUCT_BUNDLE_IDENTIFIER` is still `Patrick-App.TimeCapsule`.

This is **immutable once the app record exists**. Changing it later means
shipping a new app and abandoning every review, rating and rank the original
earned. Cost to change now: nothing. Cost to change after the first upload: the
product's identity.

It also isn't valid reverse-DNS and reads as a placeholder to anyone who
inspects the binary.

Set it to reverse-DNS of a domain you control, e.g. `com.yourdomain.timecapsule`.
It appears twice in `TimeCapsule.xcodeproj/project.pbxproj`.

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

`Time Capsule.jpg` is a valid 1024×1024 JPEG and Xcode's single-size mode is
supported, so this is insurance rather than a blocker. But rejection reports for
`ITMS-90704` consistently involve non-PNG icons, and Apple's docs don't state
the requirement either way.

Convert to a flat 1024×1024 PNG **in an image editor**, not a script — the JPEG
carries an EXIF orientation tag, and a blind re-encode can silently rotate it.

The `dark` and `tinted` entries in `Contents.json` have no file, so iOS
auto-derives them. Legal, but a paid app is shipping a system-generated icon
rather than a designed one.

### 5. Account prerequisites

Signed Paid Applications Agreement, banking and tax forms completed, screenshots
at the required device sizes, and the IAP product created in App Store Connect
with product ID **`timecapsule.pro.lifetime`** (must match
`TimeCapsulePro.productID` exactly).

---

## App Store Connect review notes — copy this in

The single highest-probability *review* rejection for this app is a reviewer
opening it and seeing an empty screen. The default memory range is the exact
day only, so unless the review device happens to hold a photo taken on today's
month and day in a previous year, the app correctly shows "No Memories Today" —
and that reads as broken.

Suggested notes:

> Time Capsule shows photos and videos taken on today's date in previous years,
> read from the device's own photo library. Nothing is uploaded.
>
> **To see the app populated**, the test device needs photos whose capture date
> is today's month and day in an earlier year. If the library has none, the app
> correctly shows an empty state. You can widen the search from Settings →
> Memory range, which looks at nearby days as well. (Memory range is part of the
> paid Time Capsule Pro unlock; see below.)
>
> **In-app purchase:** one non-consumable, `timecapsule.pro.lifetime`, which
> unlocks recap videos, the widened memory range, and late-night grouping. The
> whole daily browsing experience is free. Restore Purchase is in Settings →
> Upgrade and is reachable without buying anything.
>
> **Photo library access** is read-write and used for three things, all
> user-initiated: showing memories, deleting a memory (which goes to Recently
> Deleted via the system confirmation sheet), and adding a memory to a
> "Time Capsule Edits" album so it can be edited in Photos. Limited access is
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
- [ ] **Swipe performance** on a large library with the memory range widened.
- [ ] **Delete** from both the grid and the viewer, checking the gallery and the
      notification count stay in step.
- [ ] **Feb 29** behaviour, if you can set the device clock.

---

## Landed

Config and submission
- Privacy manifest declares `NSPrivacyAccessedAPICategoryFileTimestamp` / C617.1
  (an undeclared required-reason API is refused at **upload**, not review)
- iPhone-only device family
- `ITSAppUsesNonExemptEncryption = NO`
- `CFBundleDisplayName = "Time Capsule"`
- Photo library purpose string now describes delete and album-write, not just
  viewing
- Deployment target lowered from 26.1 to 18.0

Monetization
- StoreKit 2 non-consumable unlock, entitlement always from
  `Transaction.currentEntitlements`
- Paywall, Settings upgrade section, Restore control
- `.storekit` config wired into the scheme

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
- **Pro settings are gated in the UI only.** Someone who buys, changes the memory
  range, and is then refunded keeps the stored value. Enforcing it in
  `MemoryWindow` would couple core logic to purchase state.
- **Test coverage** is four pure-logic files. Everything touching PhotoKit, UI or
  StoreKit is untested and unreachable from the SwiftPM target.
