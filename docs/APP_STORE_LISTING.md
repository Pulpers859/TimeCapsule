# App Store listing — draft

Written to be read aloud. If a line sounds like a brochure, cut it.

Rewritten for the two-year free tier, and around what Attic does that the
apps it is compared with do not. See **Where Attic stands** at the bottom for
the evidence, including the places it is behind.

---

## App name (30 char limit)

```
Attic: On This Day Photos
```
Indexed for search, so the words after the colon are doing real work.

---

## Subtitle (30 char limit)

```
Every photo from that date
```
Indexed. Kept, even though every direct rival makes the same promise: it is
the thing people search for, and the comparison most buyers are making is
against Apple Photos, which does *not* do it. The differences go in the
promotional text and the first lines of the description, where they are read.
No price and no competitor names — both are rejections under 2.3.7.

---

## Promotional text (170 char limit, sits above the description, editable without a new build)

```
Every photo from this date, not a highlight reel. Pro is one payment: every year, recap videos, nearby days, and late nights kept with the evening they began.
```
158 characters.

---

## Description (4000 char limit)

The first sentence is the only part most people read.

```
Attic shows you every photo and video you took on this date in past years. Not
a highlight reel someone picked for you. All of them, on the exact date.

I built this because my phone kept showing me the same handful of "best" photos
and hiding the rest. The boring ones are the ones I actually want. A photo of a
receipt on the counter tells me more about that day than another sunset.

WHAT MAKES IT DIFFERENT

Late nights stay together. A party that runs past midnight belongs to the
evening it started, not the next morning. Tell Attic when your day starts and
the photos from 1 AM stay with the night before. (Pro)

Nearby days, not just the date. Some dates have almost nothing on them. Pull in
a day or three either side and a trip or a birthday weekend still finds you.
(Pro)

Recap videos. A day's photos across the years turned into a short video, with
a slow push in and framing that keeps faces in shot. (Pro)

Hide a photo, an album, or a whole place. If somewhere keeps coming back that
you would rather not see, a hospital, an old address, tell Attic once and
nothing taken there shows up again. Change your mind any time in Settings.

A widget that changes through the day. Up to twelve photos from today, a new
one every half hour, on your home screen. The lock screen shows how many
memories are waiting.

A reminder that tells the truth. It says how many memories are waiting, and on
a day with none, it says so instead of sending you in for nothing.

ALSO

See the rest of that day. Tap through from a memory and you get everything
else you shot that day.

Live Photos move. Press and hold one, or tap LIVE, and it plays with its
sound, the way it does in Photos. Videos and Live Photos stay quiet when your
phone is on silent.

Map and camera details. Where the photo was taken, and the camera, lens,
aperture, shutter and ISO. The location comes out of the photo itself. Attic
never asks for yours.

Share without giving away where you live. Sharing strips the location out of
the copy you send.

Delete or pin from anywhere. Deleting puts things in Recently Deleted, same as
the Photos app. Pinning puts a photo in an Attic album so you can find it in
Photos later.

WHAT YOU PAY FOR

The free version doesn't expire. It shows the last two years, plus the widget,
the reminder, hiding, maps and everything above that isn't marked Pro. Older
years show up as a count, so you can see how many memories are waiting before
you pay anything.

Attic Pro is one payment. No subscription. It adds every year you have photos
from, recap videos, nearby days, and a day that starts when you say it does.

PRIVACY

Attic has no server. There's no account and nothing to sign up for.

Your photos are read off your phone and shown to you. No upload, no tracking,
no analytics, no ads.

Two things leave the app and both of them go to Apple. A photo's coordinates go
to Apple Maps to get turned into a place name, and Apple handles the payment if
you buy Pro.
```

---

## Keywords (100 char limit, comma separated, no spaces after commas)

```
memories,years ago,throwback,nostalgia,camera roll,anniversary,flashback,recap,widget,slideshow
```
95 characters.

No competitor brand names — putting one here is the textbook 2.3.7 rejection.
Nothing repeated from the name or subtitle, because duplication adds no weight
and wastes the allowance. "slideshow" replaces "past": it is what people call a
recap video when they search for one, and "past" is too vague to rank for.

---

## In-app purchase display name (30 char limit)

This field **is** indexed for search, so "Pro" on its own wastes it. It now
leads with the full history, because that is what Pro mainly sells since the
free version was limited to two years.

```
Attic Pro: All Years & Recaps
```

---

## Screenshot captions

2.3.2: a screenshot showing a Pro feature has to say so, or the listing gets
rejected. Every year past the last two, recap videos, nearby days and the
day-start hour are all Pro.

Ordered by what a rival cannot show, after the one promise people search for.

1. Every photo from this date, not a highlight reel
2. Late nights stay with the evening — Attic Pro
3. Recap videos — Attic Pro
4. Hide a photo, an album or a whole place
5. A widget that changes through the day
6. Every year you have photos from — Attic Pro
7. No account. Nothing uploaded.

---

## Notes on claims

- **No price anywhere** in the name, subtitle, keywords or screenshots. Guideline 2.3.7.
  "One payment" is a model, not a number, and is safe in the promotional text and body.
- **No competitor names or "only app" claims.** The comparison is left implicit ("not a
  highlight reel"). We cannot check every app on the store, and "the only app that…" is
  an unverifiable claim.
- **"No subscription" is permanent.** A buyer can check it on the product page. If a
  subscription is ever added, every one of these surfaces changes first. Verified against
  Apple's own text: guideline **2.3.1(a)** says promoting a false price "whether within
  or outside of the App Store, is grounds for removal of your app from the App Store...
  and termination of your developer account."
- **"The last two years" has to match `MemoryWindow.freeLookbackYears`.** If the free
  tier changes, the description, the promotional text and caption 6 change with it.
- **"Up to twelve photos, a new one every half hour"** is `WidgetRotation.slotCount` and
  `slotInterval`. "Up to" is load-bearing: a quiet day has fewer, and the widget stops
  early if memory runs short.
- **"The lock screen shows how many memories are waiting"** — the lock screen widgets
  show a count and "N years ago", not a photo. Do not caption a screenshot as a lock
  screen photo.
- **"Nothing taken there shows up again"** — a hidden place covers 400 m around it
  (`MemoryExclusions.placeRadiusMeters`), and photos with no location are not affected.
  If anyone asks, that is the answer; the listing does not need the number.
- **"On a day with none, it says so"** — `NotificationPlan.body` for a zero count.
- **"No upload, no analytics" must stay literally true.** One crash reporter or one
  analytics SDK added later turns this from a selling point into a removal risk, and the
  App Privacy label has to move with it.
- **"Sharing strips the location"** — verified in code on all three routes, and worth
  recording so nobody undoes it by accident:
  - Stills go to the share sheet as a `UIImage`, so there is no metadata container to
    leak (`FullScreenPhotoView.swift`).
  - Shared videos are exported with `AVMetadataItemFilter.forSharing()`
    (`MediaAssetLoading.swift`).
  - Recap videos are composed frame by frame with `AVAssetWriter`
    (`MemoryRecapExporter.swift`), so nothing from the source file is carried at all.
    **If that is ever rewritten to use `AVAssetExportSession`, this claim breaks
    silently.**
- **"Live Photos move"** — only when asked: the LIVE button or press and hold
  (`LivePhotoPlayback`). Nothing plays on its own, so do not caption a screenshot as if
  it does. **"Quiet when your phone is on silent"** is the `.ambient` audio session in
  `VideoAudioSession.swift`; switching it back to `.playback` breaks this claim.
- **"No ads"** rather than "no ads ever". A forward-looking promise is the kind of
  unverifiable claim 2.3.7 bars from a subtitle, and it is weak positioning regardless:
  Apple Photos, Google Photos and most of the small apps in this category show no ads
  either. It earns one line in the body and nothing more.
- **"Short video", not "short film."** It is a slideshow with crossfades and a slow push
  in. The paywall copy already says "music-video style crossfades"; the listing should
  not outrun it.

---

## Where Attic stands

Checked against the App Store listings in September 2026. Re-check before launch;
these apps update often.

**The big players.**
- *Apple Photos* picks a few "best" photos and builds Memories that are often "some time
  in September", not the date. No way to see everything from the exact date. Attic's
  core promise is the answer to this, and it is the comparison most buyers make.
- *Timehop* shows ads, needs an account, tracks you across apps (per its privacy label)
  and charges a subscription (Timehop+) to remove the ads. Attic: none of those.

**The direct rivals** — small apps with the same core promise. This is where the
listing has to earn the sale, and where "every photo from this date" is *not* a
difference.
- *On This Day Rewind* (reviewed by MacStories; 5.0 from 24 ratings): free for the last
  **three** years, then $4.99 once. Map and camera details, widgets up to Extra Large, a
  daily reminder, hiding whole albums (Pro), date captions on shared photos, Live Photos.
  (Attic plays Live Photos too, since sideload-41.)
  Requires iOS 26.
- *PhotoSift*: 7-day trial, then £2.99 once. Best-shot scoring and duplicate finding.
- *On This Day Photos*, *Photos On This Day*: free, basic, a widget, few features.
- *On This Day – Daily Memories*: only yesterday, today and tomorrow free; $5.99 once.

**Where Attic is ahead** — none of these listings mention any of it:
- Late nights kept with the evening they began (the day-start hour).
- Nearby days (±1 or ±3).
- Recap videos with face-aware framing. (One rival makes memory videos, but it collects
  advertising data.)
- Hiding a *place* or a single photo, not only an album, and free rather than Pro.
- A widget that rotates through up to twelve photos, and lock screen widgets.
- A reminder that states the count and is honest on empty days.
- Location stripped from shared copies.
- Runs on iOS 18, where the strongest rival needs iOS 26.

**Where Attic is behind — say none of this in the listing, but know it:**
- **The free tier is smaller than the strongest rival's**: two years against Rewind's
  three, at the same $4.99. Someone comparing the two free versions side by side sees
  less from Attic. That was a deliberate choice (the locked years show up sooner), but it
  is the one line of this comparison Attic loses outright.
- No Large or Extra Large widget; small and medium only.
- No date caption or watermark option on shared photos.
- No ratings yet, and no press. Rewind has both.
