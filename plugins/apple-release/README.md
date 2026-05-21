# Apple Release Plugin

Automate iOS and macOS app releases to TestFlight and App Store Connect using Claude Code.

## Skills

### `/release`

Full release workflow:
1. Check for uncommitted changes and commit if needed
2. Deploy infrastructure (`make deploy` or `make deploy-infra`)
3. Build, archive, and upload to TestFlight (`make upload`)
4. Verify upload success
5. Poll until build is `VALID` in App Store Connect
6. Create App Store version with auto-release on approval
7. Submit for App Review via the `reviewSubmissions` API

### `/release-testflight`

Quick TestFlight upload (no infrastructure deployment):
1. Validate API key, signing setup, and Xcode version
2. Show current version (`make info`)
3. Build and upload to TestFlight (`make upload`)
4. Verify upload success
5. Report results

### `/release-xcodecloud`

Tag-triggered Xcode Cloud build:
1. Validate Xcode Cloud configuration (`ci_scripts/`)
2. Bump build number and commit
3. Create annotated `v*` tag and push
4. Xcode Cloud builds and uploads to TestFlight automatically

### `/app-store-audit`

Pre-submission risk audit against the full Apple App Store Review Guidelines (saved at `resources/app-store-review-guidelines.md`):

1. Detects missing/empty/placeholder Info.plist usage descriptions (5.1.1)
2. Checks Privacy Manifest (`PrivacyInfo.xcprivacy`) completeness and Required Reason API coverage (5.1.1.v)
3. Cross-references third-party SDK dependencies against tracking/analytics SDK lists (5.1.2)
4. Flags non-StoreKit payment SDKs in apps that sell digital content (3.1.1)
5. Detects web-view-only apps that risk 4.2 rejection
6. Audits App Transport Security exceptions (5.1.6)
7. Catches placeholder metadata (2.3)
8. Checks UGC apps for the four required moderation features (1.2)
9. Validates VPN/NetworkExtension and HealthKit declarations
10. Produces CRITICAL / HIGH / MEDIUM / LOW findings each citing the exact guideline ID and quoted rule text

The saved guidelines were fetched 2026-05-21. The audit's pre-flight detects staleness (>90 days) and offers to refresh before running.

## Requirements

Your Xcode project needs a `Makefile` with these targets:

| Target | Purpose |
|--------|---------|
| `make info` | Display current version and build number |
| `make upload` | Increment build, archive, and upload to App Store Connect |
| `make deploy` | Deploy backend infrastructure (for `/release` only) |
| `make release` | Tag + push for Xcode Cloud trigger (for `/release-xcodecloud` only) |

## ASC API Key Setup

All App Store Connect API keys are stored in `~/dev/certs/api-keys/` as `AuthKey_<KEY_ID>.p8`, with symlinks in `~/private_keys/`. **Never hardcode a key ID in the Makefile.** Instead, load it from `.env`:

```makefile
# Correct pattern — read from .env, never hardcode
-include .env
export

ASC_KEY_ID    ?= WT7YRT8J32
ASC_ISSUER_ID ?= 69a6de8d-e64d-47e3-e053-5b8c7c11a4d1
ASC_KEY_PATH  ?= $(HOME)/dev/certs/api-keys/AuthKey_$(ASC_KEY_ID).p8
```

**`.env` (gitignored) for each project:**
```bash
# App Store Connect API Key
# WT7YRT8J32 = cloud signing enabled — USE THIS for uploads
# 62T8FXA8J7 = API queries only — cannot upload
ASC_KEY_ID=WT7YRT8J32
ASC_ISSUER_ID=69a6de8d-e64d-47e3-e053-5b8c7c11a4d1
```

Clipz is the canonical reference implementation for this `.env` pattern.

### Key Inventory

| Key ID | Cloud Signing | Use For |
|--------|--------------|---------|
| `WT7YRT8J32` | **Yes** | `make upload`, archive, TestFlight, App Store submission |
| `62T8FXA8J7` | **No** | API queries only (build status, listing) |

The API key must have at least the **App Manager** role in App Store Connect. Developer-only keys fail at upload or cloud-signing with a permissions error.

## Signing Styles

### Cloud Signing (Automatic) — Simpler

Xcode manages signing via the API key. No local certificates or provisioning profiles needed. Used by for-the-win and regist.

`ExportOptions.plist`:
```xml
<plist version="1.0"><dict>
    <key>method</key><string>app-store-connect</string>
    <key>teamID</key><string>CNRU7L924E</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
    <key>destination</key><string>upload</string>
</dict></plist>
```

### Manual Signing — More Control

You manage certificates and provisioning profiles. Required when you need extension targets (Share, iMessage, Widget) with separate bundle IDs, each needing its own profile. Used by eleven9s and Clipz.

`ExportOptions.plist` (eleven9s multi-extension pattern, rendered from template by Makefile):
```xml
<plist version="1.0"><dict>
    <key>method</key><string>app-store-connect</string>
    <key>teamID</key><string>CNRU7L924E</string>
    <key>signingStyle</key><string>manual</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>dev.apresai.eleven9s</key><string>Eleven9s App Store</string>
        <key>dev.apresai.eleven9s.share</key><string>Eleven9s Share App Store</string>
        <key>dev.apresai.eleven9s.messages</key><string>Eleven9s Messages App Store</string>
    </dict>
    <key>signingCertificate</key><string>Apple Distribution</string>
    <key>uploadSymbols</key><true/>
    <key>destination</key><string>upload</string>
</dict></plist>
```

Clipz uses **Fastlane Match** for certificate storage. Match keeps encrypted certs in a private git repo (`~/dev/sophie-fastlane-match/`). Profile names follow the Match convention: `match AppStore dev.apresai.clipz macos`.

## Build Number Pattern

All projects use a plain text `BUILD_NUMBER` file as the authoritative build counter:

```
ios/BUILD_NUMBER    # single integer, e.g. "60"
```

The `increment-build` Makefile target reads the file, adds 1, writes it back, updates `project.yml`, and re-runs `xcodegen generate`. The build number is passed to `xcodebuild` via `CURRENT_PROJECT_VERSION`. **The commit of `BUILD_NUMBER` and `project.yml` happens only after a successful upload**, not before — so a failed upload doesn't burn a build number.

```makefile
# Canonical pattern (eleven9s): bump after archive succeeds, commit after upload succeeds
upload: archive upload-only commit-bump
commit-bump:
    @NEW=$$(cat BUILD_NUMBER); \
    git add BUILD_NUMBER project.yml && \
    git commit -m "ios: bump to $(MAJOR).$(MINOR).$$NEW (build $$NEW) for TestFlight"
```

If an upload fails mid-way: run `make reset-bump` to restore `BUILD_NUMBER` and `project.yml` to HEAD, then retry.

**Never guess the build number.** Run `make info` to read from the file, and cross-check with App Store Connect before releasing.

## Makefile Example (iOS, Cloud Signing)

Based on for-the-win's Makefile — the simplest production-ready pattern:

```makefile
-include .env
export

APP_NAME      := MyApp
SCHEME        := MyApp
PROJECT       := MyApp.xcodeproj
BUILD_DIR     := build
ARCHIVE_PATH  := $(BUILD_DIR)/MyApp.xcarchive
EXPORT_PATH   := $(BUILD_DIR)/export
BUILD_NUMBER_FILE := BUILD_NUMBER
TEAM_ID       := CNRU7L924E

MAJOR         := 1
MINOR         := 0
BUILD         := $(shell cat $(BUILD_NUMBER_FILE) 2>/dev/null || echo "0")
VERSION       := $(MAJOR).$(MINOR).$(BUILD)

ASC_KEY_ID    ?= WT7YRT8J32
ASC_ISSUER_ID ?= 69a6de8d-e64d-47e3-e053-5b8c7c11a4d1
ASC_KEY_PATH  ?= $(HOME)/dev/certs/api-keys/AuthKey_$(ASC_KEY_ID).p8

info:
	@echo "$(APP_NAME) v$(VERSION) (build $(BUILD))"

increment-build:
	@OLD=$$(cat $(BUILD_NUMBER_FILE) 2>/dev/null || echo "0"); NEW=$$((OLD + 1)); \
	echo $$NEW > $(BUILD_NUMBER_FILE); \
	sed -i '' "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$$NEW\"/g" project.yml; \
	sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$(MAJOR).$(MINOR).$$NEW\"/g" project.yml; \
	xcodegen generate > /dev/null; \
	echo "Build: $$OLD -> $$NEW"

archive: increment-build
	@rm -rf $(ARCHIVE_PATH) && mkdir -p $(BUILD_DIR)
	xcodebuild -scheme $(SCHEME) -project $(PROJECT) \
	    -configuration Release -destination 'generic/platform=iOS' \
	    -archivePath $(ARCHIVE_PATH) \
	    -allowProvisioningUpdates \
	    -authenticationKeyPath $(ASC_KEY_PATH) \
	    -authenticationKeyID $(ASC_KEY_ID) \
	    -authenticationKeyIssuerID $(ASC_ISSUER_ID) \
	    archive

upload: archive
	@mkdir -p $(EXPORT_PATH)
	@OUTPUT=$$(xcodebuild -exportArchive \
	    -archivePath $(ARCHIVE_PATH) \
	    -exportOptionsPlist ExportOptions.plist \
	    -exportPath $(EXPORT_PATH) \
	    -allowProvisioningUpdates \
	    -authenticationKeyPath $(ASC_KEY_PATH) \
	    -authenticationKeyID $(ASC_KEY_ID) \
	    -authenticationKeyIssuerID $(ASC_ISSUER_ID) \
	    2>&1); \
	echo "$$OUTPUT" > /tmp/upload_output.txt; \
	if echo "$$OUTPUT" | grep -q "EXPORT SUCCEEDED"; then \
	    echo "Upload complete. v$(VERSION)"; \
	else \
	    echo "$$OUTPUT"; echo "Upload failed."; exit 1; \
	fi
```

Note: `-exportArchive` produces the `.ipa` but does not upload it. The upload happens because `ExportOptions.plist` sets `destination = upload`. `xcrun altool --upload-package` is the older explicit form and still accepted, but the `-exportArchive` path is simpler and is what all projects here use.

**Xcode 26 / altool silent-failure warning**: With Xcode 26, `altool` may exit 0 even when the upload did not complete (fastlane issue #29743). Always verify that the build appears in App Store Connect within a few minutes; do not rely on exit code alone. Grep the upload output for `EXPORT SUCCEEDED` as the positive signal and `ERROR` or `errors returned by the App Store` as failure signals.

## App Store Connect Submission

For full App Store submission, use the `reviewSubmissions` three-step API flow (the legacy `appStoreVersionSubmissions` endpoint is removed):

1. `POST /v1/reviewSubmissions` — create submission
2. `POST /v1/reviewSubmissionItems` — attach the version
3. `PATCH /v1/reviewSubmissions/{ID}` with `"submitted": true` — confirm

See `/release` for the full flow with polling and "What's New" text.

## 2026 Xcode Requirements

Apple has raised the minimum Xcode version required to upload builds:

- **Xcode 14 or later** is required for all uploads (enforced 2026).
- **Xcode 26 + iOS 26 SDK** is required for new App Store submissions starting April 2026.

Run `xcodebuild -version` before releasing and confirm you are on a supported version. The skills do this automatically in Step 1.

## A note on altool vs. notarytool

`xcodebuild -exportArchive` with `destination = upload` (which internally uses altool) is the correct tool for uploading iOS and macOS App Store builds. It is **not** deprecated for this purpose.

`xcrun notarytool` is for macOS **Developer ID** notarization — distributing outside the App Store. Per Apple TN3147, `altool --notarize-app` was retired in November 2023, but App Store/TestFlight uploads remain supported.

For macOS apps distributed via Sparkle (auto-update, outside App Store), use Developer ID signing + `xcrun notarytool`. This is a separate distribution path not covered by these skills.

## Usage

```
/release              # Full release with infrastructure deploy + App Store submission
/release-testflight   # Quick TestFlight upload only
/release-xcodecloud   # Tag-triggered Xcode Cloud build
```
