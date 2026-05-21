---
name: release
description: Full Apple app release workflow - commit changes, deploy infrastructure, archive, upload to TestFlight, and submit for App Review with auto-release. Use when user wants to do a complete release of their iOS or macOS app.
---

# Full Release to App Store

Execute a complete release: commit, deploy infrastructure, build, upload to TestFlight, and submit for App Store Review with auto-release after approval.

## Step 1: Validate Requirements

Before proceeding, check all requirements. Stop and ask the user to provide any missing values.

### 1.1 Check for Makefile

```bash
test -f Makefile && echo "Makefile found" || echo "Makefile NOT found"
```

### 1.2 Check Makefile Targets

```bash
grep -q "^upload:" Makefile && echo "upload target found" || echo "upload target NOT found"
grep -q "^deploy:" Makefile && echo "deploy target found" || echo "deploy target NOT found"
grep -q "^info:" Makefile && echo "info target found" || echo "info target NOT found"
```

Also check for `deploy-infra:` as a fallback if `deploy:` is not found.

### 1.3 Check App Store Connect API Key Configuration

Look for these variables in the project's Makefile (check root Makefile, then ios/Makefile):

```bash
grep -rE "^ASC_KEY_ID|^ASC_ISSUER_ID|^ASC_KEY_PATH" Makefile ios/Makefile 2>/dev/null
```

Required variables:
- `ASC_KEY_ID` - App Store Connect API Key ID
- `ASC_ISSUER_ID` - App Store Connect Issuer ID
- `ASC_KEY_PATH` - Path to the .p8 key file

The API key must have at least the **App Manager** role in App Store Connect. Developer-only keys can fail at the upload or cloud-signing step with a permissions error. If the upload fails with a cloud signing or permission-denied message, check the key's role under App Store Connect → Users and Access → Keys.

### 1.4 Verify API Key File Exists

```bash
ASC_KEY_PATH=$(grep "^ASC_KEY_PATH" ios/Makefile Makefile 2>/dev/null | head -1 | sed 's/.*= *//' | sed "s|\$(HOME)|$HOME|g")
test -f "$ASC_KEY_PATH" && echo "API key file found" || echo "API key file NOT found at $ASC_KEY_PATH"
```

### 1.5 Check PyJWT for ASC API

```bash
python3 -c "import jwt" 2>/dev/null && echo "PyJWT available" || echo "PyJWT required: pip3 install PyJWT"
```

### 1.6 Discover App Store App ID

Look for the App Store app ID in CLAUDE.md or project configuration:

```bash
grep -oE 'apps/[0-9]+' CLAUDE.md | head -1 | grep -oE '[0-9]+'
```

If not found, ask the user for their App Store Connect app ID.

### 1.7 Check Xcode Version

```bash
xcodebuild -version 2>/dev/null || echo "Xcode CLI tools not installed"
```

Parse the major version from the output. Apple requires Xcode 14 or later for all uploads (enforced 2026). Starting April 2026, new App Store submissions must be built with Xcode 26 and the iOS 26 SDK. If the Xcode version is below 14, stop and ask the user to upgrade before continuing. If the version is below 26 and today's date is after April 2026, warn the user that Apple may reject the submission.

## Step 2: Pre-flight Checks

```bash
git status
make info
```

- Check for uncommitted changes
- Note current version
- Ask the user for "What's New" release notes, or generate from recent commits

## Step 3: Commit & Push (if changes exist)

If there are uncommitted changes, use the /commit skill or create a commit. Skip if working tree is clean.

## Step 4: Deploy Infrastructure

```bash
make deploy
```

If `make deploy` is not available, try `make deploy-infra`. Wait for deployment to complete. Verify with a health check if the project has one.

## Step 5: Build & Upload to TestFlight

```bash
make upload 2>&1 | tee /tmp/upload_output.txt
```

This command:
1. Increments build number automatically
2. Creates release archive with xcodebuild
3. Signs with App Store distribution profile
4. Uploads to App Store Connect

### Verify Upload

Check for `Upload succeeded` and `EXPORT SUCCEEDED` in the output:

```bash
grep -E "Upload succeeded|EXPORT SUCCEEDED" /tmp/upload_output.txt
grep -E "ERROR|errors returned by the App Store" /tmp/upload_output.txt
```

With Xcode 26, `altool` may exit 0 even when the upload silently failed (fastlane issue #29743). Do not rely on the exit code alone. If the success strings are absent, or if any error strings appear, treat the upload as failed.

Note: `xcrun altool --upload-app` (and its newer form `--upload-package`) is the correct tool for App Store and TestFlight uploads — it is not deprecated for this use. Only `altool --notarize-app` was retired (per Apple TN3147, November 2023); App Store uploads via altool remain supported.

```bash
make info
```

Note the new version and build number.

## Step 6: Wait for Build Processing

Poll the ASC API until the build state is `VALID`. Use a Python script with PyJWT to authenticate.

**Authentication pattern** (reuse across all ASC API calls):

```python
import jwt, datetime
now = datetime.datetime.now(datetime.timezone.utc)
token = jwt.encode(
    {"iss": ISSUER_ID, "iat": int(now.timestamp()),
     "exp": int((now + datetime.timedelta(minutes=20)).timestamp()),
     "aud": "appstoreconnect-v1"},
    private_key, algorithm="ES256", headers={"kid": KEY_ID}
)
```

**Poll for build VALID state:**
- `GET /v1/builds?filter[app]={APP_ID}&sort=-uploadedDate&limit=1`
- Check `attributes.processingState == "VALID"`
- Poll every 30 seconds, timeout after 10 minutes
- If build is still PROCESSING after timeout, inform the user and stop

## Step 7: Create App Store Version

Once the build is VALID:

1. **Create a new App Store version** with `releaseType: AFTER_APPROVAL` (auto-release):
   ```
   POST /v1/appStoreVersions
   {
     "data": {
       "type": "appStoreVersions",
       "attributes": {
         "platform": "IOS",
         "versionString": "<version from make info>",
         "releaseType": "AFTER_APPROVAL"
       },
       "relationships": {
         "app": {"data": {"type": "apps", "id": APP_ID}},
         "build": {"data": {"type": "builds", "id": BUILD_ID}}
       }
     }
   }
   ```

2. **Set "What's New" text** on the version localization:
   ```
   GET /v1/appStoreVersions/{VERSION_ID}/appStoreVersionLocalizations
   PATCH /v1/appStoreVersionLocalizations/{LOC_ID}
   {"data": {"type": "appStoreVersionLocalizations", "id": LOC_ID,
     "attributes": {"whatsNew": "<release notes>"}}}
   ```

## Step 8: Submit for App Review

Use the `reviewSubmissions` API (the legacy `appStoreVersionSubmissions` endpoint has been removed from Apple's documentation with no announced sunset date — do not use it):

1. **Create review submission:**
   ```
   POST /v1/reviewSubmissions
   {"data": {"type": "reviewSubmissions",
     "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}}
   ```

2. **Add the version to the submission:**
   ```
   POST /v1/reviewSubmissionItems
   {"data": {"type": "reviewSubmissionItems",
     "relationships": {
       "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": SUBMISSION_ID}},
       "appStoreVersion": {"data": {"type": "appStoreVersions", "id": VERSION_ID}}
     }}}
   ```

3. **Confirm submission:**
   ```
   PATCH /v1/reviewSubmissions/{SUBMISSION_ID}
   {"data": {"type": "reviewSubmissions", "id": SUBMISSION_ID,
     "attributes": {"submitted": true}}}
   ```

The response state should be `WAITING_FOR_REVIEW`.

## Step 9: Report Results

After completion, summarize:
- Infrastructure deployment status
- Version and build number uploaded
- App Store version created with auto-release
- Submission state (should be WAITING_FOR_REVIEW)
- "What's New" text that was set
- Link to App Store Connect

## Notes

- **Auto-release**: With `AFTER_APPROVAL`, the app goes live automatically once Apple approves it. No manual release step needed.
- **Review time**: Apple typically reviews within 24-48 hours.
- **If submission fails**: Check that the version has all required metadata (What's New text, screenshots, description). The most common failure is missing "What's New" text.
- **Build processing**: Takes 5-15 minutes after upload. The skill polls automatically.

## Troubleshooting

- **Build upload fails**: Check compilation errors, verify provisioning profile, ensure API key file exists. Run `make clean` and retry.
- **403 on submission**: The `appStoreVersionSubmissions` endpoint has been removed. Use the `reviewSubmissions` three-step flow described in Step 8.
- **409 "not in valid state"**: The version is missing required metadata (usually "What's New"). Ensure Step 7.2 completed successfully.
- **Build not VALID**: Wait longer — Apple's processing can take up to 30 minutes for large binaries.
