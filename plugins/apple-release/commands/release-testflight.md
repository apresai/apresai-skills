---
name: release-testflight
description: Quick TestFlight upload - archive and upload app to App Store Connect without infrastructure deployment. Use when user just wants to push a new build to TestFlight. Project-detecting driver over a standardized Makefile interface; signing-agnostic.
---

# Release to TestFlight

Build, archive, and upload an app to TestFlight (skips infrastructure deployment).

This skill is a **thin, project-detecting driver over a standardized `make upload` / `make info`
interface**. It does not prescribe a signing style or a build-number policy — it reads each from the
project and delegates the mechanics to the project's Makefile. Every apresai App Store app signs
ASC-direct (no Fastlane); the shipped artifact is signed by the shared distribution cert
`KZ4VK235YL` (*Apple Distribution: Apres AI LLC*, team `CNRU7L924E`).

## Step 0: Detect the project type (route correctly)

Not every app is a TestFlight target, and the entrypoint differs per repo. Detect before doing anything.

```bash
# Non-App-Store (Developer ID / Sparkle) — e.g. codexbar: NOT a TestFlight target.
# Signs with an upstream Developer ID identity, ships via notarize + appcast, not ASC.
ls *.xcodeproj >/dev/null 2>&1 && grep -rql "SUFeedURL\|Sparkle" . 2>/dev/null \
  && ! ls ExportOptions*.plist ios/ExportOptions*.plist >/dev/null 2>&1 \
  && echo "SPARKLE/Developer-ID app — STOP: use notarytool, not TestFlight"

# Flutter — e.g. sophie: build via the Flutter toolchain, not xcodebuild directly.
test -f pubspec.yaml && echo "FLUTTER app — use the Flutter upload target (e.g. make mobile)"
```

- **Sparkle / Developer ID app** (no `app-store-connect` ExportOptions): **stop** — it has no
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
  echo "No upload/ios-upload target found — ask the user which target builds+uploads this app."
fi
echo "upload target: $UP   info target: $INFO"
```

Use the detected `$UP` / `$INFO` in every step below. (Standardizing every repo on bare
`make upload` / `make info` is the goal — until then, detect.)

## Step 1: Validate requirements

### 1.1 App Store Connect API key

**Convention:** ASC keys live in `~/dev/certs/api-keys/AuthKey_<KEY_ID>.p8` (symlinked in
`~/private_keys/`). Each project's `.env` (gitignored) defines `ASC_KEY_ID` + `ASC_ISSUER_ID`; the
Makefile constructs `ASC_KEY_PATH`. Never hardcode key IDs.

```bash
grep -E "^ASC_KEY_ID|^ASC_ISSUER_ID" .env 2>/dev/null
```

- `ASC_KEY_ID` **must be `WT7YRT8J32`** (cloud-signing-enabled, App Manager role). `62T8FXA8J7` is
  query-only and **cannot upload**.
- `ASC_ISSUER_ID` = `69a6de8d-e64d-47e3-e053-5b8c7c11a4d1`.

```bash
KEY_ID=$(grep "^ASC_KEY_ID" .env 2>/dev/null | cut -d= -f2 | tr -d ' ')
test -f "$HOME/dev/certs/api-keys/AuthKey_${KEY_ID}.p8" \
  || test -f "$HOME/private_keys/AuthKey_${KEY_ID}.p8" \
  && echo "Key file OK" || echo "Key file NOT found for $KEY_ID"
```

### 1.2 Signing — stay agnostic; read it, don't assume it

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
has a SHA-1-pinned cert (`CODE_SIGN_CERT_SHA1` in `.env`, e.g. eleven9s), that is valid — it
disambiguates among multiple keychain identities. If the project exposes `make check-signing`
(or `make -C ios check-signing`), run it to preflight certs + profiles before archiving.

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

## Step 3: Build and upload

```bash
$UP 2>&1 | tee /tmp/upload_output.txt   # e.g. make upload / make ios-upload / make mobile
```

**The Makefile owns the mechanics** — increment + `xcodegen generate` + `xcodebuild archive` +
`xcodebuild -exportArchive` (signing per the project's ExportOptions) + ASC upload. It also owns the
**build-number / commit policy**: some repos commit the bump *after* a successful upload, some bump
before archive, some inside the upload target. Do not impose a generic bump/commit narrative — let
each Makefile do what it does. If a repo splits into `archive-upload` + `upload-only` (or
`archive-only` + `upload-only`), run them in sequence so a transient upload failure can retry without
re-archiving.

## Step 4: Verify upload

```bash
grep -E "EXPORT SUCCEEDED|Upload succeeded" /tmp/upload_output.txt
grep -E "ERROR|errors returned by the App Store" /tmp/upload_output.txt
```

Treat the build as uploaded only if `EXPORT SUCCEEDED` is present and no `ERROR` lines appear.

**Xcode 26 altool silent-failure:** `altool` may exit 0 while the upload silently failed (fastlane
issue #29743 — a tracked altool bug report, *not* a Fastlane dependency). Do not trust the exit code
alone; rely on the success/error strings and confirm the build appears in App Store Connect →
TestFlight within a few minutes.

## Step 5: Report

- Version + build number uploaded (`$INFO` to confirm)
- Upload success/failure + any warnings
- TestFlight link: `https://appstoreconnect.apple.com/apps` (or the direct
  `…/apps/{ASC_APP_ID}/testflight/ios` if the Makefile defines `ASC_APP_ID`)

## Notes

- Apple processes TestFlight builds 10–30 min after upload; email arrives when ready.
- Internal testers install immediately; external testers need a (usually fast) review.

## Common failure modes

**Wrong API key** — upload fails with a cloud-signing / permission error. Confirm
`ASC_KEY_ID=WT7YRT8J32`; `62T8FXA8J7` cannot upload.

**Stale `.xcodeproj`** — archive picks up an old `MARKETING_VERSION` because `xcodegen generate`
wasn't run after bumping `project.yml`. Well-formed `archive` targets run `generate` first.

**Build number already exists** — ASC rejects "CFBundleVersion already exists." Set `BUILD_NUMBER`
to one above the highest build in ASC and re-run.

**`EXPORT SUCCEEDED` absent, exit 0** — the Xcode 26 altool silent failure above. Check
`/tmp/upload_output.txt` for error strings; retry the `upload-only` half if the archive is still
present, else re-archive + upload.

**Export resolves the wrong / an expired provisioning profile** — happens when two installed
profiles share the same Name (a stale cert dupe next to the current one). The rotation tooling
(`renew-profile.sh`) self-cleans to one-profile-per-Name; if you hit this, decode
`~/Library/MobileDevice/Provisioning Profiles/*` by `:Name` and remove the stale duplicate.

**"No certificate for team" at export** — the named profile's cert isn't in the keychain, or the
profile expired. For projects with rotation tooling (eleven9s: `make -C ios renew-profile` /
`renew-portfolio-profiles`), re-mint and retry. For others, re-mint the profile via the ASC API.

**Extension targets missing profiles** — multi-target apps (Share, Widget, Watch) need one
provisioning profile per bundle ID, each referenced by Name in `ExportOptions.plist`.

## Reference: standard Makefile shape (manual signing, by-name profile)

The portfolio standard — manual export, generic `"Apple Distribution"`, profile by stable Name:

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

`ExportOptions.plist` (commit it — never gitignore the manual config):

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
> one-profile-per-Name — so this `ExportOptions.plist` never changes across rotations (the Name is
> stable; only the UUID + cert underneath rotate). See `/release-consistency` for the model and the
> rotation runbook.

## App Store submission

This skill stops at TestFlight. For full submission (review), use `/release` (the `reviewSubmissions`
three-step API flow with polling + "What's New").
