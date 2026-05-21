# Apple Release Plugin

Automate iOS and macOS app releases to TestFlight and App Store Connect using Claude Code.

## Skills

### `/release`

Full release workflow:
1. Check for uncommitted changes and commit if needed
2. Deploy infrastructure (`make deploy-infra`)
3. Build, archive, and upload to TestFlight (`make upload`)
4. Verify upload success
5. Report results with App Store Connect link

### `/release-testflight`

Quick TestFlight upload (no infrastructure deployment):
1. Build and upload to TestFlight (`make upload`)
2. Verify upload success
3. Report results

## Requirements

Your Xcode project needs a `Makefile` with these targets:

| Target | Purpose |
|--------|---------|
| `make info` | Display current version |
| `make upload` | Archive and upload to App Store Connect |
| `make deploy-infra` | Deploy backend infrastructure (for `/release` only) |

### Makefile Example

```makefile
upload: archive
    xcodebuild -exportArchive \
        -archivePath $(ARCHIVE_PATH) \
        -exportOptionsPlist ExportOptions.plist \
        -exportPath $(EXPORT_PATH) \
        -authenticationKeyPath $(ASC_KEY_PATH) \
        -authenticationKeyID $(ASC_KEY_ID) \
        -authenticationKeyIssuerID $(ASC_ISSUER_ID)
    xcrun altool --upload-package "$(EXPORT_PATH)/$(APP_NAME).ipa" \
        --type ios \
        --apiKey $(ASC_KEY_ID) \
        --apiIssuer $(ASC_ISSUER_ID) \
        --apiKey-path $(ASC_KEY_PATH)

deploy-infra:
    cd infrastructure && npx cdk deploy --require-approval never
```

Note: `-exportArchive` produces the `.ipa` but does not upload it. The `xcrun altool --upload-package` step is required to actually deliver the build to App Store Connect. `xcrun altool --upload-app` is the older form and is still accepted, but `--upload-package` is the current preferred flag.

**Xcode 26 / altool silent-failure warning**: With Xcode 26, `altool` may exit 0 even when the upload did not complete (fastlane issue #29743). Always verify that the build appears in App Store Connect within a few minutes; do not rely on exit code alone. Grep the upload output for `ERROR` or `errors returned by the App Store` as additional failure signals.

## App Store Connect Setup

1. Create an API key in App Store Connect → Users and Access → Keys
2. The key must have at least the **App Manager** role to perform uploads and cloud signing. A Developer-only key can fail at upload or code-signing with a permissions error.
3. Download the `.p8` key file
4. Configure key path in your Makefile:
   ```makefile
   ASC_KEY_ID = YOUR_KEY_ID
   ASC_ISSUER_ID = YOUR_ISSUER_ID
   ASC_KEY_PATH = $(HOME)/path/to/AuthKey_XXXXX.p8
   ```

## 2026 Xcode Requirements

Apple has raised the minimum Xcode version required to upload builds:

- **Xcode 14 or later** is required for all uploads (enforced 2026).
- **Xcode 26 + iOS 26 SDK** is required for new App Store submissions starting April 2026.

Run `xcodebuild -version` before releasing and confirm you are on a supported version. The skills do this automatically in Step 1.

## A note on altool vs. notarytool

`xcrun altool --upload-app` (and `--upload-package`) is the correct tool for uploading iOS and macOS App Store builds to App Store Connect. It is **not** deprecated for this purpose. `xcrun notarytool` is for macOS Developer-ID notarization (distributing outside the App Store) — it does not handle App Store submissions. Per Apple TN3147, `altool --notarize-app` was retired in November 2023, but `altool --upload-app` for App Store/TestFlight uploads remains supported.

## Usage

```
/release              # Full release with infrastructure
/release-testflight   # Quick TestFlight upload only
```
