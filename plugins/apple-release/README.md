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

deploy-infra:
    cd infrastructure && npx cdk deploy --require-approval never
```

## App Store Connect Setup

1. Create an API key in App Store Connect → Users and Access → Keys
2. Download the `.p8` key file
3. Configure key path in your Makefile:
   ```makefile
   ASC_KEY_ID = YOUR_KEY_ID
   ASC_ISSUER_ID = YOUR_ISSUER_ID
   ASC_KEY_PATH = $(HOME)/path/to/AuthKey_XXXXX.p8
   ```

## Usage

```
/release              # Full release with infrastructure
/release-testflight   # Quick TestFlight upload only
```
