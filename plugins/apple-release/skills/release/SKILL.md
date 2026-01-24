---
name: release
description: Full Apple app release workflow - commit changes, deploy infrastructure, archive and upload to TestFlight. Use when user wants to do a complete release of their iOS or macOS app.
---

# Full Release

Execute a complete release including git commit, infrastructure deployment, and TestFlight upload.

## Step 1: Validate Requirements

Before proceeding, check all requirements. Stop and ask the user to provide any missing values.

### 1.1 Check for Makefile

```bash
test -f Makefile && echo "Makefile found" || echo "Makefile NOT found"
```

If Makefile is missing, ask:
> "No Makefile found. This skill requires a Makefile with `upload`, `deploy-infra`, and `info` targets. Would you like me to help create one?"

### 1.2 Check Makefile Targets

```bash
grep -q "^upload:" Makefile && echo "upload target found" || echo "upload target NOT found"
grep -q "^deploy-infra:" Makefile && echo "deploy-infra target found" || echo "deploy-infra target NOT found"
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

## Step 2: Pre-flight Checks

Only proceed here after all requirements are validated.

```bash
git status
make info
```

- Check for uncommitted changes
- Note current version

## Step 3: Commit & Push (if changes exist)

If there are uncommitted changes:

```bash
git add -A
git commit -m "release: deploy $(date +%Y-%m-%d)"
git push origin main
```

Skip if working tree is clean.

## Step 4: Deploy Infrastructure

```bash
make deploy-infra
```

Wait for deployment to complete.

## Step 5: Build & Upload to TestFlight

```bash
make upload
```

This command typically:
1. Increments the build number
2. Creates a release archive
3. Signs with distribution profile
4. Uploads to App Store Connect

## Step 6: Verify Upload

```bash
tail -30 /tmp/upload_output.txt
```

Look for success indicators:
- `Upload succeeded`
- `EXPORT SUCCEEDED`

## Step 7: Report Results

After completion, summarize:
- Infrastructure deployment status
- Version uploaded to TestFlight
- Any warnings from build
- Link: https://appstoreconnect.apple.com/apps

## Notes

- TestFlight processing takes 10-30 minutes after upload
- Email notification arrives when build is ready for testing
