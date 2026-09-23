# Build an iPhone app from GitHub and install it, using only your phone

No Mac. No Xcode. No Apple Developer account. No cable.

You push code. GitHub builds it on a Mac it rents you for free. You tap a link in
Safari on the phone, hand the file to Signulous, and it installs.

This is a working recipe, not a theory. It has been used for a real SwiftUI app
with a widget extension. Everything marked **gotcha** below is something that
actually went wrong and cost a build cycle.

---

## What you need

- A **GitHub repository** with your Xcode project in it.
- **The repo must be public.** This is the one hard requirement and it is not
  negotiable for the phone-only route. See "Why public" below.
- A **Signulous** subscription (or any re-signing service that accepts an `.ipa`).
- An iPhone.

## What you do NOT need

- A Mac. GitHub's `macos-latest` runner is a real Mac with Xcode installed.
- Xcode. You never open it.
- An Apple Developer account ($99/yr). The build is unsigned; Signulous does the
  signing with its own certificate.
- A cable, TestFlight, or AltStore.

## Why public

Two reasons, both about the phone:

1. **A GitHub Release asset on a public repo has a plain direct URL** that Safari
   can open with no login. On a private repo that URL requires an authorization
   header, which you cannot add by tapping a link.
2. **macOS runner minutes are free on public repos.** On private repos they bill
   at 10x the Linux rate, and a build like this takes 6–8 minutes each time.

If your code cannot be public, this route does not work from the phone alone. You
would need a computer to download an artifact, or a separate host for the file.

---

## Step 1 — Add the workflow file

Create `.github/workflows/build-sideload-ipa.yml` in your repo.

Replace the five `<<< >>>` placeholders. Everything else works as written.

```yaml
name: Build Sideload IPA

on:
  workflow_dispatch:

permissions:
  # write, not read. The job creates a Release, and that needs write.
  contents: write

concurrency:
  group: sideload-${{ github.ref }}
  cancel-in-progress: true

jobs:
  ipa:
    runs-on: macos-latest
    timeout-minutes: 40
    steps:
      - uses: actions/checkout@v4

      - name: Select and verify toolchain
        shell: bash
        run: |
          # Runners carry several Xcodes, sometimes including a beta. Pick the
          # newest non-beta rather than trusting the default.
          newest=$(ls -d /Applications/Xcode*.app 2>/dev/null \
            | grep -viE 'beta|release[_-]?candidate|_rc[0-9]*(\.app)?$' \
            | sort -V | tail -1)
          if [[ -z "$newest" ]]; then
            echo 'No Xcode found on the runner.' >&2
            exit 1
          fi
          echo "DEVELOPER_DIR=$newest/Contents/Developer" >> "$GITHUB_ENV"
          export DEVELOPER_DIR="$newest/Contents/Developer"
          xcodebuild -version

      - name: Archive
        shell: bash
        run: |
          set -o pipefail
          xcodebuild archive \
            -project '<<<YourProject>>>.xcodeproj' \
            -scheme '<<<YourScheme>>>' \
            -configuration 'Release' \
            -destination 'generic/platform=iOS' \
            -archivePath 'build/App.xcarchive' \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGN_IDENTITY="" \
            2>&1 | tee archive.log
          status=${PIPESTATUS[0]}
          if [[ "$status" -ne 0 ]]; then exit "$status"; fi

      # OPTIONAL — only if your app has entitlements (App Groups, HealthKit,
      # push, Keychain sharing...). Delete this whole step if it does not.
      - name: Ad-hoc sign so entitlements are embedded
        shell: bash
        run: |
          set -euo pipefail
          app="build/App.xcarchive/Products/Applications/<<<YourApp>>>.app"

          # Nested code FIRST. Signing a bundle seals its contents, so signing
          # the app before its extension invalidates the app's own seal.
          codesign --force --sign - --timestamp=none \
            --entitlements '<<<path/to/Extension.entitlements>>>' \
            "$app/PlugIns/<<<YourExtension>>>.appex"

          codesign --force --sign - --timestamp=none \
            --entitlements '<<<path/to/App.entitlements>>>' \
            "$app"

          codesign -d --entitlements :- "$app" 2>/dev/null || true

      - name: Package IPA
        shell: bash
        run: |
          set -euo pipefail
          app="build/App.xcarchive/Products/Applications/<<<YourApp>>>.app"
          if [[ ! -d "$app" ]]; then
            echo "No .app in the archive at $app" >&2
            ls -R build/App.xcarchive/Products >&2 || true
            exit 1
          fi

          # An .ipa is just a zip with the .app inside a folder named Payload.
          # That is the entire format. No Apple tooling is involved.
          mkdir -p out/Payload
          cp -R "$app" out/Payload/
          (cd out && zip -qry "App.ipa" Payload)
          rm -rf out/Payload
          echo "Built out/App.ipa ($(du -h out/App.ipa | cut -f1))"

      - name: Publish as a release
        shell: bash
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          tag="sideload-${{ github.run_number }}"
          gh release delete "$tag" --yes --cleanup-tag 2>/dev/null || true
          gh release create "$tag" 'out/App.ipa' \
            --title "Sideload build ${{ github.run_number }}" \
            --notes "Unsigned build of ${{ github.sha }} for re-signing." \
            --prerelease
          echo "Direct link: ${{ github.server_url }}/${{ github.repository }}/releases/download/$tag/App.ipa"

      - name: Upload archive log on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: archive-log
          path: 'archive.log'
          if-no-files-found: warn
```

### The five placeholders

| Placeholder | Where to find it |
|---|---|
| `<<<YourProject>>>.xcodeproj` | The `.xcodeproj` folder at your repo root. Use `-workspace X.xcworkspace` instead if you use CocoaPods or SPM workspaces. |
| `<<<YourScheme>>>` | Usually the same as the project name. It is the scheme that builds the app. |
| `<<<YourApp>>>.app` | The **product name**, which is not always the scheme name. If the build fails at "No .app in the archive", the step prints the actual contents — read it and use the real name. |
| `<<<YourExtension>>>.appex` | Only if you have a widget, share extension, etc. |
| `<<<path/to/*.entitlements>>>` | Only if you have entitlements. |

---

## Step 2 — Run it from your phone

1. Safari → `github.com/<you>/<repo>`
2. **Actions** tab
3. **Build Sideload IPA** in the left list
4. **Run workflow** → **Run workflow**
5. Wait 6–8 minutes. Pull to refresh.

If you would rather an AI agent trigger it for you, this is the API call:

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  -X POST \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/<OWNER>/<REPO>/actions/workflows/build-sideload-ipa.yml/dispatches" \
  -d '{"ref":"main"}'
```

`204` means it started. **`415` means the `Content-Type` header was left off** —
that one wastes a few minutes every time someone writes this from memory.

---

## Step 3 — Install it

The finished run prints a **Direct link**, and the same link appears under the
**Releases** section of the repo. It looks like:

```
https://github.com/<OWNER>/<REPO>/releases/download/sideload-<N>/App.ipa
```

On the phone:

1. Open that link in Safari. It downloads the `.ipa`.
2. Open Signulous, sign the `.ipa`.
3. Install from Signulous.

Installing a new build over an old one keeps your data, as long as the bundle
identifier has not changed.

---

## Gotchas — every one of these actually happened

### Do not use "Artifacts". Use a Release.
GitHub Actions artifacts **cannot be downloaded on a phone.** They need a
signed-in desktop browser, and on mobile the artifact name is not even a link.
This is the single most common wrong turn. The Release asset exists precisely to
dodge it.

### `415 Unsupported Media Type` when triggering via the API
You left off `-H "Content-Type: application/json"`. GitHub requires it even
though the body is tiny.

### "No .app in the archive"
The product name differs from the scheme name. The step above deliberately prints
`ls -R` of the archive when this happens. Read it, take the real name.

### Entitlements vanish, and nothing tells you
**Symptom:** the app runs, but a widget or extension behaves as though it has
different settings from the app. No error, no crash, no log.

**Cause:** `CODE_SIGNING_ALLOWED=NO` does not merely skip the signature. It skips
the step that *generates* the entitlements blob, so the bundle declares no
entitlements at all, however correct your `.entitlements` files are. A re-signing
service cannot preserve something that was never in the bundle.

**Fix:** the ad-hoc signing step. `codesign --sign -` needs no certificate, no
provisioning profile, no Apple account, and it *does* embed entitlements. The
signature is discarded when Signulous re-signs — the point is to hand the
re-signer a bundle that declares what it wants.

**Also:** do not blank `CODE_SIGN_ENTITLEMENTS` in the archive step. It looks
harmless because codesign is not running, and it silently removes your
entitlements from the whole pipeline.

### An extension can go missing and still produce a valid `.ipa`
A widget that failed to embed does not break the build. You find out when it is
not on your home screen. Add an explicit check:

```bash
if [[ ! -d "$app/PlugIns/<<<YourExtension>>>.appex" ]]; then
  echo 'Extension is not embedded.' >&2
  ls -R "$app/PlugIns" >&2 || true
  exit 1
fi
```

Same principle for anything else that is silently optional. Fail the build rather
than shipping a bundle that will confuse you on the phone.

### App Groups cannot work on a sideloaded build
An App Group identifier belongs to a **developer team**. Signulous signs with its
own team, so iOS will not grant a group that is not in its provisioning profile.
The bundle can *declare* it — and should — but the entitlement will not be
granted.

**Consequence:** your app and its widget read separate `UserDefaults` stores and
appear to disagree. This is expected and it disappears the day you sign with your
own Apple Developer account.

**Detect it in code** rather than letting it confuse you:

```swift
// UserDefaults(suiteName:) is NOT a test for this — it returns a store for a
// suite the process has no entitlement to reach, so the nil check passes in
// exactly the case it was meant to catch.
let available = FileManager.default.containerURL(
    forSecurityApplicationGroupIdentifier: "group.your.identifier"
) != nil
```

### In-app purchases cannot work
There is no App Store product behind a sideloaded build, so the paywall can never
complete. If Pro features are gated, compile the gate open for sideload builds:

```swift
#if MYAPP_SIDELOAD
unlocked = true
#else
// real StoreKit check
#endif
```

Pass the flag from the workflow with a build setting your project maps into
`SWIFT_ACTIVE_COMPILATION_CONDITIONS`, and add a `workflow_dispatch` boolean
input so you can turn it off when you want to test the real paywall.

---

## What this route cannot do

- **App Groups** (above).
- **In-app purchases** (above).
- **Push notifications** — the APNs entitlement is team-bound like App Groups.
  Local notifications work fine.
- **iCloud / CloudKit** — same reason.
- **TestFlight or the App Store.** This is for you and your own device.
- **Certificate expiry.** Re-signed apps stop working when the service's
  certificate is revoked or expires. Re-sign and reinstall.

---

## Hand this to another AI agent

Paste this brief:

> I have an Xcode iOS project in a public GitHub repo. I have no Mac, no Xcode,
> and no Apple Developer account. I install builds by downloading an `.ipa` on my
> iPhone and re-signing it with Signulous.
>
> Set up a `workflow_dispatch` GitHub Actions workflow on `macos-latest` that:
> 1. picks the newest non-beta Xcode on the runner;
> 2. runs `xcodebuild archive` with `CODE_SIGNING_ALLOWED=NO`,
>    `CODE_SIGNING_REQUIRED=NO`, `CODE_SIGN_IDENTITY=""`, and **does not**
>    override `CODE_SIGN_ENTITLEMENTS`;
> 3. if the app has entitlements, ad-hoc signs it with `codesign --force --sign -`
>    and the `.entitlements` file — nested extensions first, then the app —
>    because `CODE_SIGNING_ALLOWED=NO` skips generating the entitlements blob
>    entirely and a re-signer cannot preserve what is not there;
> 4. verifies any extension is actually embedded and fails the build if not;
> 5. zips `Payload/<App>.app` into an `.ipa`;
> 6. publishes it as a **GitHub Release asset**, not an artifact, because
>    artifacts cannot be downloaded on a phone;
> 7. prints the direct download URL.
>
> The workflow needs `permissions: contents: write`. When you trigger it via the
> REST API, include `-H "Content-Type: application/json"` or you get a 415.
>
> Tell me the direct release URL when the run finishes. Do not tell me to open
> Xcode, connect a cable, or download an Actions artifact — none of those work
> for me.

---

*Written from a working setup, September 2026.*
