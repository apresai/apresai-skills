---
name: release-testflight
description: Quick TestFlight upload - archive and upload app to App Store Connect without infrastructure deployment. Use when user just wants to push a new build to TestFlight.
---

# Release to TestFlight

Build, archive, and upload app to TestFlight (skips infrastructure deployment).

## Step 1: Validate Requirements

Before proceeding, check all requirements. Stop and ask the user to provide any missing values.

### 1.1 Check for Makefile

```bash
test -f Makefile && echo "Makefile found" || echo "Makefile NOT found"
```

If Makefile is missing, ask:
> "No Makefile found. This skill requires a Makefile with `upload` and `info` targets. Would you like me to help create one?"

### 1.2 Check Makefile Targets

```bash
grep -q "^upload:" Makefile && echo "upload target found" || echo "upload target NOT found"
grep -q "^info:" Makefile && echo "info target found" || echo "info target NOT found"
```

If any target is missing, inform the user which targets are needed. Some projects split `upload` into `archive-upload` (increment + archive) and `upload-only` (export + upload) — both are valid; the skill works with either pattern.

### 1.3 Check App Store Connect API Key Configuration

**Key storage convention**: All ASC API keys live in `~/dev/certs/api-keys/` as `AuthKey_<KEY_ID>.p8`, with symlinks mirrored in `~/private_keys/`. Each project's `.env` (gitignored) defines `ASC_KEY_ID` and `ASC_ISSUER_ID`; the Makefile constructs `ASC_KEY_PATH` from those variables. Keys are never hardcoded in the Makefile.

```bash
# The correct source is .env, not the Makefile
grep -E "^ASC_KEY_ID|^ASC_ISSUER_ID" .env 2>/dev/null

# Verify the Makefile loads .env
grep -E "include .env|-include .env" Makefile 2>/dev/null
```

Required variables (from `.env`):
- `ASC_KEY_ID` — must be `WT7YRT8J32` for uploads (cloud signing enabled)
- `ASC_ISSUER_ID` — `69a6de8d-e64d-47e3-e053-5b8c7c11a4d1`
- `ASC_KEY_PATH` — constructed as `$(HOME)/dev/certs/api-keys/AuthKey_$(ASC_KEY_ID).p8`

**Key `62T8FXA8J7` cannot upload** — it is for API queries only. If the project's `.env` uses this key, the upload will fail with a permissions error.

If any are missing or set to placeholder values, ask the user:
> "Missing App Store Connect configuration. Your `.env` should define:
> - `ASC_KEY_ID=WT7YRT8J32` (the key with cloud signing enabled)
> - `ASC_ISSUER_ID=69a6de8d-e64d-47e3-e053-5b8c7c11a4d1`
> The key file lives at `~/dev/certs/api-keys/AuthKey_WT7YRT8J32.p8`."

The API key must have at least the **App Manager** role. A Developer-only key fails at the upload or cloud-signing step with a permissions error. Verify under App Store Connect → Users and Access → Keys.

### 1.4 Verify API Key File Exists

```bash
KEY_ID=$(grep "^ASC_KEY_ID" .env 2>/dev/null | cut -d= -f2 | tr -d ' ')
KEY_PATH="$HOME/dev/certs/api-keys/AuthKey_${KEY_ID}.p8"
test -f "$KEY_PATH" && echo "Key file found: $KEY_PATH" || echo "Key file NOT found at $KEY_PATH"
```

If the key file doesn't exist at `~/dev/certs/api-keys/`, also check `~/private_keys/` (some projects symlink there):
```bash
test -f "$HOME/private_keys/AuthKey_${KEY_ID}.p8" && echo "Found in ~/private_keys/" || echo "Not found"
```

### 1.5 Check Signing Setup

Projects use one of two signing styles:

**Cloud signing** (automatic, via API key): The Makefile passes `-authenticationKeyPath`, `-authenticationKeyID`, and `-authenticationKeyIssuerID` directly to `xcodebuild -exportArchive`. `ExportOptions.plist` sets `signingStyle = automatic`. No local certificates or provisioning profiles are needed. This is the simpler path — for-the-win and regist use this.

**Manual signing** (local certs + profiles): The Makefile requires `CODE_SIGN_CERT_SHA1` (SHA1 of the "Apple Distribution" cert in your keychain) and provisioning profile names in `.env`. `ExportOptions.plist` sets `signingStyle = manual` with explicit `provisioningProfiles` per bundle ID. eleven9s uses this pattern. Clipz uses a Fastlane Match-managed profile (`match AppStore dev.apresai.clipz macos`).

Check which style the project uses:
```bash
grep -E "signingStyle|manual|automatic" ExportOptions.plist 2>/dev/null
```

For manual signing, run `make check-signing` (if the target exists) to preflight certificates and profiles before archiving.

### 1.6 Check Xcode Version

```bash
xcodebuild -version 2>/dev/null || echo "Xcode CLI tools not installed"
```

If not installed, inform the user:
> "Xcode command line tools required. Install with: `xcode-select --install`"

Parse the major version from the output. Apple requires Xcode 14 or later for all uploads (enforced 2026). Starting April 2026, new App Store submissions must be built with Xcode 26 and the iOS 26 SDK. Warn the user if their Xcode version does not meet the current requirement.

## Step 2: Check Current Version

Only proceed here after all requirements are validated.

```bash
make info
```

Note the current version and build number before upload. The build number comes from the `BUILD_NUMBER` file on disk. If it differs from what ASC shows, check ASC before proceeding to avoid a build number conflict.

## Step 3: Build and Upload

```bash
make upload 2>&1 | tee /tmp/upload_output.txt
```

This command:
1. Increments build number in `BUILD_NUMBER` and syncs `project.yml`
2. Runs `xcodegen generate` to refresh the `.xcodeproj`
3. Creates release archive with `xcodebuild archive`
4. Verifies archive version via `PlistBuddy` (projects that follow the Clipz pattern)
5. Runs `xcodebuild -exportArchive` with `ExportOptions.plist` to sign and upload directly to App Store Connect

If the project splits these into `make archive-upload` + `make upload-only`, run them in sequence. The split allows retrying the upload without re-archiving on transient network failures.

**Build number commit**: eleven9s commits the `BUILD_NUMBER` and `project.yml` bump *after* a successful upload (via `make commit-bump`), not before. If the upload fails, run `make reset-bump` to restore the files to HEAD before retrying.

## Step 4: Verify Upload

```bash
grep -E "Upload succeeded|EXPORT SUCCEEDED" /tmp/upload_output.txt
grep -E "ERROR|errors returned by the App Store" /tmp/upload_output.txt
```

Look for:
- `EXPORT SUCCEEDED` in the xcodebuild output
- Absence of any `ERROR` lines

With Xcode 26, `altool` may exit 0 while the upload silently failed (fastlane issue #29743). If the success strings are absent or any error strings appear, treat the upload as failed rather than relying on the exit code. Verify the build appears in App Store Connect → TestFlight within a few minutes as a secondary check.

**Direct TestFlight link**: If the project's Makefile defines `ASC_APP_ID`, the upload output will print a direct link like `https://appstoreconnect.apple.com/apps/{ASC_APP_ID}/testflight/ios`.

## Step 5: Report Results

After completion, report:
- Version and build number uploaded (run `make info` to confirm)
- Upload success/failure
- Any build warnings
- TestFlight link: `https://appstoreconnect.apple.com/apps` (or the direct link if available)

## Notes

- TestFlight processing by Apple takes 10-30 minutes after upload
- Email notification arrives when build is ready for testing
- Internal testers can install immediately; external testers require a review (usually fast)

## Common Failure Modes

**Wrong API key**: Upload fails with a cloud signing or permission-denied error. Confirm `.env` has `ASC_KEY_ID=WT7YRT8J32` — `62T8FXA8J7` cannot upload.

**Stale `.xcodeproj`**: Archive picks up old `MARKETING_VERSION` because `xcodegen generate` wasn't run after bumping `project.yml`. The `make archive` target in Clipz runs `make generate` first to guard against this.

**Provisioning profile expired**: Manual-signing projects fail at export with "No certificate for team". Run `make renew-profile` or `make renew-all-profiles` (eleven9s), then retry.

**Build number already exists**: ASC rejects with "CFBundleVersion already exists." Manually set `BUILD_NUMBER` to one above the highest build in ASC and re-run.

**`EXPORT SUCCEEDED` absent, exit 0**: Xcode 26 altool silent failure. Check `/tmp/upload_output.txt` for error strings. Retry with `make upload-only` if the archive is still present; otherwise `make archive-upload` + `make upload-only`.

**Extension targets missing profiles**: Multi-extension apps (Share, iMessage, Widget) need one provisioning profile per bundle ID. eleven9s uses `PROVISIONING_PROFILE_NAME`, `PROVISIONING_PROFILE_NAME_SHARE`, and `PROVISIONING_PROFILE_NAME_MESSAGES` in `.env`, all rendered into `ExportOptions.plist` via template substitution.

## Makefile Template

A minimal working Makefile for a single-target iOS app (based on for-the-win's pattern):

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

# .env must define ASC_KEY_ID and ASC_ISSUER_ID
ASC_KEY_ID    ?= WT7YRT8J32
ASC_ISSUER_ID ?= 69a6de8d-e64d-47e3-e053-5b8c7c11a4d1
ASC_KEY_PATH  ?= $(HOME)/dev/certs/api-keys/AuthKey_$(ASC_KEY_ID).p8

info:
	@echo "$(APP_NAME) v$(VERSION) (build $(BUILD))"
	@echo "  ASC Key ID: $(ASC_KEY_ID)"
	@if [ -f "$(ASC_KEY_PATH)" ]; then echo "  Key file: OK"; else echo "  Key file: MISSING"; fi

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
	    echo "$$OUTPUT" | tail -10; echo "Upload complete."; \
	else \
	    echo "$$OUTPUT"; echo "Upload failed."; exit 1; \
	fi
```

**`ExportOptions.plist` for cloud signing (automatic)**:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>teamID</key><string>CNRU7L924E</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
    <key>destination</key><string>upload</string>
</dict>
</plist>
```

**`ExportOptions.plist` for manual signing** (use when you have specific provisioning profiles in the keychain — see eleven9s):
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

## Fastlane Match for Certificate Storage

Some projects (Clipz) use Fastlane Match to store certificates and provisioning profiles in an encrypted private Git repository (`~/dev/sophie-fastlane-match/`). Match manages the cert lifecycle: it generates, encrypts, and syncs certificates across machines.

When a project uses Match, the provisioning profile name in `ExportOptions.plist` follows the Match naming convention:
```
match AppStore dev.apresai.clipz macos     # macOS App Store profile
match Development dev.apresai.clipz macos  # macOS development profile
match AppStore dev.apresai.myapp           # iOS App Store profile
```

Most projects in this portfolio use **manual signing without Match** (directly managing `.mobileprovision` files via the ASC API and `make renew-profile`). Match is only relevant if the project explicitly references it in `project.yml` or `ExportOptions.plist`.

## macOS Notarization (Non-App-Store Distribution)

For macOS apps distributed **outside** the App Store (Developer ID signing), notarization uses `xcrun notarytool`, not altool. Per Apple TN3147, `altool --notarize-app` was retired in November 2023.

```bash
xcrun notarytool submit MyApp.zip \
    --key ~/dev/certs/api-keys/AuthKey_WT7YRT8J32.p8 \
    --key-id WT7YRT8J32 \
    --issuer 69a6de8d-e64d-47e3-e053-5b8c7c11a4d1 \
    --wait
```

This is **not** needed for App Store uploads — `xcodebuild -exportArchive` with `method = app-store-connect` handles everything. The Sparkle auto-update pattern (used by codexbar) is an entirely separate distribution path.
