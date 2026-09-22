# App Store listing — draft

Written to be read aloud. If a line sounds like a brochure, cut it.

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
Indexed. No price and no competitor names — both are rejections under 2.3.7.

---

## Promotional text (170 char limit, sits above the description, editable without a new build)

```
Every photo you took on this date, every year, free. Pro is one payment: recap videos, nearby dates, and a day that starts when you say it does.
```

---

## Description (4000 char limit)

The first sentence is the only part most people read.

```
Attic shows you every photo and video you took on this date in past years. Not a
highlight reel someone picked for you. All of them, oldest to newest.

I built this because my phone kept showing me the same handful of "best" photos and
hiding the rest. I feel like the boring ones are the ones I actually want. A photo of a
receipt on the counter tells me more about that day than another sunset.

WHAT IT DOES

Opens straight to today. Every year you had a phone, in one list.

See the rest of any day. Tap through from a memory and you get everything else you shot
that day, not just what Attic pulled out.

Map and camera info. Where the photo was taken, plus the camera, lens, aperture, shutter
and ISO. The coordinates come out of the photo itself. Attic never asks for your
location.

A widget for your home or lock screen, and one reminder a day if you want it.

Share or delete from anywhere. Sharing strips the location out of the copy you send.
Deleting puts things in Recently Deleted, same as the Photos app.

Feature less often. If a photo or a place or a whole album keeps coming back, you can
tell Attic to stop showing it.

WHAT YOU PAY FOR

The free version is not a trial. Your whole history, every year of it, no time limit.

Attic Pro is a one-time payment. It adds:

Recap videos. A day's photos turned into a short video, with a slow push in and framing
that keeps faces in shot.

Nearby days. Some dates just don't have much on them. Pull in the days either side and
you get more to look at.

When your day starts. If a night out runs past midnight those photos should sit with the
night before, not the next morning. Set the hour your day starts and Attic groups them
that way.

PRIVACY

Attic has no server. There's no account and nothing to sign up for.

Your photos are read off your phone and shown to you. No upload, no tracking, no
analytics, no ads.

Two things leave the app and both of them go to Apple. A photo's coordinates go to Apple
Maps to get turned into a place name, and Apple handles the payment if you buy Pro.
```

---

## Keywords (100 char limit, comma separated, no spaces after commas)

```
memories,years ago,throwback,nostalgia,camera roll,anniversary,flashback,recap,widget,past
```

No competitor brand names — putting one here is the textbook 2.3.7 rejection. Nothing
repeated from the name or subtitle, because duplication adds no weight and wastes the
allowance.

---

## In-app purchase display name (30 char limit)

This field **is** indexed for search, so "Pro" on its own wastes it.

```
Attic Pro: Recaps & More Days
```

---

## Screenshot captions

2.3.2: a screenshot showing a Pro feature has to say so, or the listing gets rejected.
Recap videos, nearby days and the day-start hour are all Pro.

1. Every photo from this date, every year
2. See everything else from that day
3. The map and the camera settings
4. Recap videos — Attic Pro
5. Pull in nearby days — Attic Pro
6. Nothing leaves your phone

---

## Notes on claims

- **No price anywhere** in the name, subtitle, keywords or screenshots. Guideline 2.3.7.
  "One payment" is a model, not a number, and is safe in the promotional text and body.
- **"No subscription" is permanent.** A buyer can check it on the product page. If a
  subscription is ever added, every one of these surfaces changes first. Verified against
  Apple's own text: guideline **2.3.1(a)** says promoting a false price "whether within
  or outside of the App Store, is grounds for removal of your app from the App Store...
  and termination of your developer account."
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
- **"No ads"** rather than "no ads ever". A forward-looking promise is the kind of
  unverifiable claim 2.3.7 bars from a subtitle, and it is weak positioning regardless:
  Apple Photos, Google Photos and most of the small apps in this category show no ads
  either. It earns one line in the body and nothing more.
- **"Short video", not "short film."** It is a slideshow with crossfades and a slow push
  in. The paywall copy already says "music-video style crossfades"; the listing should
  not outrun it.
