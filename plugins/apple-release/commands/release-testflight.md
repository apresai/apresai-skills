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

If any target is missing, inform the user which targets are needed.

### 1.3 Check App Store Connect API Key Configuration

Look for these variables in the Makefile:

```bash
grep -E "^ASC_KEY_ID|^ASC_ISSUER_ID|^ASC_KEY_PATH" Makefile
```

Required variables:
- `ASC_KEY_ID` - App Store Connect API Key ID
- `ASC_ISSUER_ID` - App Store Connect Issuer ID
- `ASC_KEY_PATH` - Path to the .p8 key file

If any are missing or set to placeholder values, ask the user:
> "Missing App Store Connect configuration. Please provide:
> - ASC_KEY_ID: (from App Store Connect → Users and Access → Keys)
> - ASC_ISSUER_ID: (from App Store Connect → Users and Access → Keys)
> - ASC_KEY_PATH: (path to your AuthKey_XXXXX.p8 file)"

### 1.4 Verify API Key File Exists

Extract the key path from Makefile and verify it exists:

```bash
ASC_KEY_PATH=$(grep "^ASC_KEY_PATH" Makefile | sed 's/.*= *//' | sed "s|\$(HOME)|$HOME|g")
test -f "$ASC_KEY_PATH" && echo "API key file found" || echo "API key file NOT found at $ASC_KEY_PATH"
```

If the key file doesn't exist, ask:
> "API key file not found at [path]. Please verify the path or download the key from App Store Connect."

### 1.5 Check Xcode Command Line Tools

```bash
xcodebuild -version 2>/dev/null || echo "Xcode CLI tools not installed"
```

If not installed, inform the user:
> "Xcode command line tools required. Install with: `xcode-select --install`"

## Step 2: Check Current Version

Only proceed here after all requirements are validated.

```bash
make info
```

Note the current version before upload.

## Step 3: Build and Upload

```bash
make upload
```

This command:
1. Increments build number automatically
2. Creates release archive with xcodebuild
3. Signs with App Store distribution profile
4. Uploads directly to App Store Connect

## Step 4: Verify Upload

```bash
tail -30 /tmp/upload_output.txt
```

Look for:
- `Upload succeeded`
- `EXPORT SUCCEEDED`

## Step 5: Report Results

After completion, report:
- Version uploaded (run `make info` to confirm)
- Upload success/failure
- Any build warnings
- Link: https://appstoreconnect.apple.com/apps

## Notes

- TestFlight processing by Apple takes 10-30 minutes
- Email notification when build is ready for testing

## Troubleshooting

If build fails:
- Check compilation errors in output
- Verify provisioning profile is valid and not expired
- Ensure API key file exists at configured path
- Run `make clean` and retry
