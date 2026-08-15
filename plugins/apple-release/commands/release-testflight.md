---
name: release-testflight
description: Quick TestFlight upload - archive and upload app to App Store Connect without infrastructure deployment. Use when user just wants to push a new build to TestFlight. Project-detecting driver over a standardized Makefile interface; signing-agnostic.
---

# Release to TestFlight

Build, archive, and upload an app to TestFlight (skips infrastructure deployment).

This skill is a **thin, project-detecting driver over a standardized `make upload` / `make info`
interface**. It does not prescribe a signing style or a build-number policy: it reads each from the
project and delegates the mechanics to the project's Makefile. Every apresai App Store app signs
ASC-direct (no Fastlane); the shipped artifact is signed by the shared distribution cert
`KZ4VK235YL` (*Apple Distribution: Apres AI LLC*, team `CNRU7L924E`).

## Step 0: Detect the project type (route correctly)

Not every app is a TestFlight target, and the entrypoint differs per repo. Detect before doing anything.

```bash
# Non-App-Store (Developer ID / Sparkle), e.g. codexbar: NOT a TestFlight target.
# Signs with an upstream Developer ID identity, ships via notarize + appcast, not ASC.
ls *.xcodeproj >/dev/null 2>&1 && grep -rql "SUFeedURL\|Sparkle" . 2>/dev/null \
  && ! ls ExportOptions*.plist ios/ExportOptions*.plist >/dev/null 2>&1 \
  && echo "SPARKLE/Developer-ID app. STOP: use notarytool, not TestFlight"

# Flutter, e.g. sophie: build via the Flutter toolchain, not xcodebuild directly.
test -f pubspec.yaml && echo "FLUTTER app: use the Flutter upload target (e.g. make mobile)"
```

- **Sparkle / Developer ID app** (no `app-store-connect` ExportOptions): **stop**. It has no
  TestFlight path. Route to `xcrun notarytool` + appcast, out of scope for this skill.
- **Flutter app**: the repo wraps `flutter build ipa` + upload behind a Makefile target (e.g.
  `make mobile`). Use that target wherever the steps below say `make upload`.

### Find the upload + info targets (they are not always at the repo root)

```bash
# Prefer a root target; fall back to an ios/ subdirectory Makefile.
if grep -qE '^(upload|ios-upload):' Makefile 2>/dev/null; then
  grep -qE '^upload:'     Makefile && UP="make upload"      || UP="make ios-upload"
  grep -qE '^info:'       Makefile && INFO="make info"      || INFO="make ios-info"
elif test -f ios/Makefile && grep -qE '^upload:' ios/Makefile; then
  UP="make -C ios upload"; INFO="make -C ios info"
else
  echo "No upload/ios-upload target found: ask the user which target builds+uploads this app."
fi

# Optional: an ASC status target, used by the Step 2 snapshot and the Step 5 check.
# DETECT it here rather than discovering it by running it, so that later a non-zero
# exit means the command FAILED rather than "no such target". Conflating those two
# is how a real auth or network error gets reported as "nothing to check".
STATUS=""
if grep -qE '^asc-status:' Makefile 2>/dev/null; then
  STATUS="make asc-status"
elif test -f ios/Makefile && grep -qE '^asc-status:' ios/Makefile; then
  STATUS="make -C ios asc-status"
fi
echo "upload target: $UP   info target: $INFO   status target: ${STATUS:-none}"
```

Use the detected `$UP` / `$INFO` in every step below. (Standardizing every repo on bare
`make upload` / `make info` is the goal; until then, detect.) `$STATUS` is optional: an empty
`$STATUS` means this project exposes no ASC status target, which is a skip, not a failure.

## Step 1: Validate requirements

### 1.1 App Store Connect API key

**Convention:** ASC keys live in `~/dev/certs/api-keys/AuthKey_<KEY_ID>.p8` (symlinked in
`~/private_keys/`). Where the key ID is DECLARED varies by project, so read it, do not assume `.env`:
some define it there, others (regist) set it directly in the Makefile. Both are fine; a key ID is not
a secret, and the `.p8` it names never leaves `~/dev/certs`.

```bash
# .env first, then the Makefile. An empty result from the first is not an answer.
KEY_ID=$(grep -hE "^ASC_KEY_ID" .env 2>/dev/null | cut -d= -f2 | tr -d ' "')
[ -z "$KEY_ID" ] && KEY_ID=$(grep -hE "^ASC_KEY_ID[[:space:]]*:?=" Makefile 2>/dev/null | head -1 | sed 's/.*[:=]=*//' | tr -d ' "')
echo "ASC_KEY_ID=${KEY_ID:-NOT FOUND}"
```

Checking only `.env` in a project that hardcodes it yields an empty `KEY_ID` and the useless report
"Key file NOT found for " with nothing after the "for".

- `ASC_KEY_ID` **must be `WT7YRT8J32`** (cloud-signing-enabled, App Manager role). `62T8FXA8J7` is
  query-only and **cannot upload**.
- `ASC_ISSUER_ID` = `69a6de8d-e64d-47e3-e053-5b8c7c11a4d1`.

```bash
KEY_ID=$(grep "^ASC_KEY_ID" .env 2>/dev/null | cut -d= -f2 | tr -d ' ')
test -f "$HOME/dev/certs/api-keys/AuthKey_${KEY_ID}.p8" \
  || test -f "$HOME/private_keys/AuthKey_${KEY_ID}.p8" \
  && echo "Key file OK" || echo "Key file NOT found for $KEY_ID"
```

### 1.2 Signing: stay agnostic; read it, don't assume it

Apps differ, and the export step is what signs the shipped artifact. **Do not assume a signing
style and do not assert "no profiles needed."** Read the actual style from the project's
ExportOptions (it may be `ExportOptions.plist`, `ExportOptionsRelease.plist`, or `ios/ExportOptions.plist`):

```bash
for f in ExportOptions.plist ExportOptionsRelease.plist ios/ExportOptions*.plist; do
  [ -f "$f" ] && echo "$f:" && /usr/libexec/PlistBuddy -c 'Print :signingStyle' "$f" 2>/dev/null \
    && /usr/libexec/PlistBuddy -c 'Print :provisioningProfiles' "$f" 2>/dev/null
done
```

The portfolio standard is **manual export + generic `"Apple Distribution"` + provisioning profiles
referenced by stable Name** (e.g. `dev.apresai.myapp = "MyApp App Store"`). Multi-target apps carry
one profile per bundle ID (e.g. a Share extension → `"<App> Share App Store"`). If a project still
has a SHA-1-pinned cert (`CODE_SIGN_CERT_SHA1` in `.env`, e.g. eleven9s), that is valid: it
disambiguates among multiple keychain identities. If the project exposes `make check-signing`
(or `make -C ios check-signing`), run it to preflight certs + profiles before archiving.

**A MIXED model is also valid, and is not a finding.** regist archives with
`CODE_SIGN_STYLE: Automatic` (in `ios/project.yml`) and exports with `signingStyle: manual` plus a
named profile. Only the EXPORT signs the artifact that ships, so the export half is what has to be
pinned; the archive half only has to produce something signable. Do not "fix" this by forcing the
archive to manual: that trades a working configuration for a second set of provisioning requirements
at archive time, for no change to the shipped binary.

### 1.3 Xcode version

```bash
xcodebuild -version 2>/dev/null || echo "Xcode CLI tools not installed"
```

Apple requires **Xcode 14+** for all uploads (enforced 2026); **Xcode 26 + iOS 26 SDK** for new App
Store submissions from April 2026. Warn if below requirement.

## Step 2: Check current version

```bash
$INFO   # e.g. make info / make ios-info / make -C ios info
```

Note the current version + build number. The build number comes from the `BUILD_NUMBER` file. If it
differs from what ASC shows, check ASC first to avoid a build-number conflict.

**No `$INFO` target?** Read the build number directly from the project instead of assuming: for
xcodegen projects, `grep CURRENT_PROJECT_VERSION project.yml`; otherwise
`grep -m1 CURRENT_PROJECT_VERSION <project>.xcodeproj/project.pbxproj`. Always verify against the
actual project config, never against memory of the last release.

### Snapshot the ASC state, BEFORE the upload

Only when Step 0 found a `$STATUS` target. Step 5 checks that the upload did not disturb an
in-flight review, and that check is a comparison: without a before-value there is nothing to
compare against, and "attachedBuild is 161" on its own proves nothing.

```bash
[ -n "$STATUS" ] && $STATUS   # record attachedBuild, and any in-flight submission's id + state + timestamp
```

Write those values down in the session before moving on. If `$STATUS` exits non-zero here,
say so and carry on: a status probe is not a gate on uploading a build, but Step 5 must then report
that it had no baseline rather than implying the comparison passed.

## Step 2.5: Pre-upload gates

Run these before any archive/upload; they exist to prevent stale-build-number uploads and
accidental churn:

1. **Stale-build hygiene**: if the previous archive for this project failed or behaved oddly,
   clear derived data first: `rm -rf ~/Library/Developer/Xcode/DerivedData/<project>*`. Skip when
   the last build was clean (a full rebuild costs minutes).
2. **State what you're uploading, then proceed**: when the user has asked to push a build, name
   the app, version, and build number and go (if the Makefile bumps inside the upload target, say
   so: "current build N, upload carries N+1"). Do NOT block for an explicit yes on a push the user
   already requested, and do NOT push back on a repeat upload: deliberate, repeated TestFlight
   pushes are normal in a dev cycle, and a monotonic bump-on-success pipeline already prevents
   build-number collisions. Only stop if something is actually wrong (a real blocker), not for
   ceremony. Ask first only when the user did NOT clearly ask to upload (e.g. an ambiguous "ship it"
   mid-task).

## Step 3: Build and upload

```bash
set -o pipefail; $UP 2>&1 | tee /tmp/upload_output.txt   # e.g. make upload / make ios-upload / make mobile
```

`pipefail` is load-bearing: without it the pipeline's exit code is `tee`'s
(always 0), and a failed upload reports success to whoever launched it.
Reproduced live 2026-08-12: an ASC 504 mid-upload exited the make with
Error 2, and the un-guarded pipe reported exit 0.

**The Makefile owns the mechanics**: increment + `xcodegen generate` + `xcodebuild archive` +
`xcodebuild -exportArchive` (signing per the project's ExportOptions) + ASC upload. It also owns the
**build-number / commit policy**: some repos commit the bump *after* a successful upload, some bump
before archive, some inside the upload target. Do not impose a generic bump/commit narrative: let
each Makefile do what it does. If a repo splits into `archive-upload` + `upload-only` (or
`archive-only` + `upload-only`), run them in sequence so a transient upload failure can retry without
re-archiving.

## Step 4: Verify upload

**First establish WHICH transport this project uses, because the success string differs and
`EXPORT SUCCEEDED` does not prove an upload happened.**

```bash
grep -l "iTMSTransporter" scripts/*.sh Makefile 2>/dev/null   # Signiant path
grep -o "destination</key>[[:space:]]*<string>[a-z]*" ios/ExportOptions*.plist ExportOptions*.plist 2>/dev/null
```

- **`destination=upload`** (exportArchive uploads directly): `EXPORT SUCCEEDED` covers export AND
  upload, so the original check holds.
- **`destination=export` + `iTMSTransporter`** (regist, since its Aspera hangs): `EXPORT SUCCEEDED`
  means only that an IPA was written to disk. The upload is a SEPARATE process afterwards, and
  treating the export string as proof would report success on a failed upload. Verify the transporter
  itself, and trust the script's exit code, which is what actually observes it:

```bash
grep -E "EXPORT SUCCEEDED" /tmp/upload_output.txt                       # the export half
grep -E "Uploaded .* to TestFlight|Package Summary|1 package\(s\)" /tmp/upload_output.txt   # the upload half
grep -E "ERROR|errors returned by the App Store|exit 124" /tmp/upload_output.txt
```

Either way the build is uploaded only if the upload-half evidence is present and no `ERROR` lines
appear. A 20-minute timeout (`exit 124`) is the known Aspera/Signiant hang class, not a slow network:
investigate before retrying.

**Xcode 26 altool silent-failure:** `altool` may exit 0 while the upload silently failed (fastlane
issue #29743, a tracked altool bug report, *not* a Fastlane dependency). Do not trust the exit code
alone; rely on the success/error strings and confirm the build appears in App Store Connect →
TestFlight within a few minutes.

## Step 5: Submission-readiness check (report only, never a gate)

**Runs BEFORE the report, because its whole output is an input to the report.** A successful upload
is the cheapest moment to notice something that will block the NEXT App Store submission: nothing
here is on the critical path and the app is already at a known-good state.

```bash
if [ -n "$STATUS" ]; then
  $STATUS || echo "STATUS PROBE FAILED (see stderr above): report this, do NOT read it as 'nothing to check'"
else
  echo "no ASC status target in this project; skip (do not hand-roll one here)"
fi
```

Note what that does NOT do: it does not treat a non-zero exit as "no target". `$STATUS` was resolved
by detection in Step 0, so if it is set, the target exists, and a failure here is an auth, network,
or API error worth reporting. Never let stderr disappear into a "skip" line; that suppresses exactly
the signal this step exists to produce.

**The field that goes missing unnoticed is `whatsNew`.** It is not required for an app's FIRST
release, so it stays empty through the whole pre-launch period without ever failing anything, and
then blocks the first UPDATE submission. regist is the observation: version 1.1 went through two
complete App Review cycles (rejected 2026-07-13 and 2026-07-20) with `whatsNew` en-US MISSING, and
neither rejection cited it. So an empty `whatsNew` on a pre-launch app is not a bug to chase, and it
is also not a field anyone will be reminded about later.

**Report it. Do not fix it from this skill.** Two independent reasons:

1. A missing `whatsNew` cannot fail a TestFlight upload, so acting on it is outside this skill's
   scope, and this skill stops at TestFlight.
2. If a review submission is already in flight, version metadata is the wrong thing to touch. ASC
   has returned `409 "version is not editable"` for metadata writes in that state, and any write
   that does land changes what the reviewer receives.

While the status target is open, confirm the upload did NOT disturb an in-flight review by comparing
against **the Step 2 snapshot**: `attachedBuild` should be unchanged, and any in-flight submission
should keep its original state and timestamp. With no snapshot (no `$STATUS`, or the Step 2 probe
failed), report that the comparison could not be made; a lone after-value proves nothing.
**Uploading a build during review is safe** (it lands in TestFlight unattached, verified on regist
across builds 163 and 164 while submission `151cf8b2` sat in WAITING_FOR_REVIEW); **attaching a build
is what touches the submission.** Never attach as a side effect of a TestFlight push.

## Step 6: Report

- Version + build number uploaded (`$INFO` to confirm)
- Upload success/failure + any warnings
- TestFlight link: `https://appstoreconnect.apple.com/apps` (or the direct
  `…/apps/{ASC_APP_ID}/testflight/ios` if the Makefile defines `ASC_APP_ID`)
- Whatever Step 5 surfaced: a readiness gap stated as a future blocker rather than as work to do
  now, the before-and-after comparison result, and a failed or skipped status probe named as such

## Notes

- Apple processes TestFlight builds 10 to 30 min after upload; email arrives when ready.
- Internal testers install immediately; external testers need a (usually fast) review.

## Common failure modes

**Wrong API key**: upload fails with a cloud-signing / permission error. Confirm
`ASC_KEY_ID=WT7YRT8J32`; `62T8FXA8J7` cannot upload.

**Stale `.xcodeproj`**: archive picks up an old `MARKETING_VERSION` because `xcodegen generate`
wasn't run after bumping `project.yml`. Well-formed `archive` targets run `generate` first.

**Build number already exists**: ASC rejects "CFBundleVersion already exists." Set `BUILD_NUMBER`
to one above the highest build in ASC and re-run.

**`EXPORT SUCCEEDED` absent, exit 0**: the Xcode 26 altool silent failure above. Check
`/tmp/upload_output.txt` for error strings; retry the `upload-only` half if the archive is still
present, else re-archive + upload.

**Export resolves the wrong / an expired provisioning profile**: happens when two installed
profiles share the same Name (a stale cert dupe next to the current one). The rotation tooling
(`renew-profile.sh`) self-cleans to one-profile-per-Name; if you hit this, decode
`~/Library/MobileDevice/Provisioning Profiles/*` by `:Name` and remove the stale duplicate.

**"No certificate for team" at export**: the named profile's cert isn't in the keychain, or the
profile expired. For projects with rotation tooling (eleven9s: `make -C ios renew-profile` /
`renew-portfolio-profiles`), re-mint and retry. For others, re-mint the profile via the ASC API.

**Extension targets missing profiles**: multi-target apps (Share, Widget, Watch) need one
provisioning profile per bundle ID, each referenced by Name in `ExportOptions.plist`.

## Reference: standard Makefile shape (manual signing, by-name profile)

The portfolio standard (manual export, generic `"Apple Distribution"`, profile by stable Name):

```makefile
-include .env
export

APP_NAME      := MyApp
SCHEME        := MyApp
PROJECT       := MyApp.xcodeproj
BUILD_DIR     := build
ARCHIVE_PATH  := $(BUILD_DIR)/MyApp.xcarchive
EXPORT_PATH   := $(BUILD_DIR)/export
TEAM_ID       := CNRU7L924E
BUILD         := $(shell cat BUILD_NUMBER 2>/dev/null || echo "0")
VERSION       := 1.0.$(BUILD)

# .env defines ASC_KEY_ID (=WT7YRT8J32) + ASC_ISSUER_ID
ASC_KEY_ID    ?= WT7YRT8J32
ASC_ISSUER_ID ?= 69a6de8d-e64d-47e3-e053-5b8c7c11a4d1
ASC_KEY_PATH  ?= $(HOME)/dev/certs/api-keys/AuthKey_$(ASC_KEY_ID).p8

info:
	@echo "$(APP_NAME) v$(VERSION) (build $(BUILD))"

increment-build:
	@OLD=$$(cat BUILD_NUMBER 2>/dev/null || echo "0"); NEW=$$((OLD + 1)); \
	echo $$NEW > BUILD_NUMBER; \
	sed -i '' "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$$NEW\"/g" project.yml; \
	xcodegen generate > /dev/null; echo "Build: $$OLD -> $$NEW"

# Manual archive: pin the cert + team explicitly; NO -allowProvisioningUpdates here
# (it would let xcodebuild silently mint profiles, defeating provability).
archive: increment-build
	@rm -rf $(ARCHIVE_PATH) && mkdir -p $(BUILD_DIR)
	xcodebuild -scheme $(SCHEME) -project $(PROJECT) -configuration Release \
	    -destination 'generic/platform=iOS' -archivePath $(ARCHIVE_PATH) \
	    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" \
	    DEVELOPMENT_TEAM=$(TEAM_ID) archive

upload: archive
	@mkdir -p $(EXPORT_PATH)
	@OUTPUT=$$(xcodebuild -exportArchive -archivePath $(ARCHIVE_PATH) \
	    -exportOptionsPlist ExportOptions.plist -exportPath $(EXPORT_PATH) \
	    -allowProvisioningUpdates \
	    -authenticationKeyPath $(ASC_KEY_PATH) -authenticationKeyID $(ASC_KEY_ID) \
	    -authenticationKeyIssuerID $(ASC_ISSUER_ID) 2>&1); \
	echo "$$OUTPUT" > /tmp/upload_output.txt; \
	echo "$$OUTPUT" | grep -q "EXPORT SUCCEEDED" && echo "Upload complete. v$(VERSION)" \
	    || { echo "$$OUTPUT"; echo "Upload failed."; exit 1; }
```

`ExportOptions.plist` (commit it, never gitignore the manual config):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>teamID</key><string>CNRU7L924E</string>
    <key>signingStyle</key><string>manual</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>dev.apresai.myapp</key><string>MyApp App Store</string>
    </dict>
    <key>signingCertificate</key><string>Apple Distribution</string>
    <key>uploadSymbols</key><true/>
    <key>destination</key><string>upload</string>
</dict>
</plist>
```

> Annual cert rotation re-mints every named profile onto the new shared cert and self-cleans to
> one-profile-per-Name, so this `ExportOptions.plist` never changes across rotations (the Name is
> stable; only the UUID + cert underneath rotate). See `/release-consistency` for the model and the
> rotation runbook.

## App Store submission

This skill stops at TestFlight.

For the full submission, `/release` documents the `reviewSubmissions` three-step API flow with
polling and "What's New". Note it drives that flow in **Python + PyJWT**, which some environments
forbid for tooling; where that applies, prefer a project-local implementation. regist has one under
way in Go (`tools/asc-release`, on the shared `tools/ascclient`): today `make asc-status` reports
release readiness read-only, which is worth running BEFORE any submission because it answers the
questions that actually block one:

- which build is ATTACHED to the version, which is not necessarily the newest one uploaded
- whether `whatsNew` exists for every locale, whose absence is the most common submission failure
  for an UPDATE (a first release does not require it, which is exactly why it goes unnoticed; see
  Step 5)
- whether a review submission is already in flight, which blocks creating another
- the subscription and subscription-group version ids, since a submission that omits the
  subscription item is what caused this app's 2.1(b) rejection

**Submitting an app with an active subscription requires BOTH items in one review submission**: the
`appStoreVersion` AND the subscription. Submitting the app version alone reproduces that rejection.
