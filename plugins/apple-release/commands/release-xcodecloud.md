---
name: release-xcodecloud
description: Release via Xcode Cloud - bump version, tag, and push to trigger Xcode Cloud TestFlight build. Use when the project uses Xcode Cloud CI/CD with tag-based triggers.
---

# Release via Xcode Cloud

Bump version, create annotated tag, and push to trigger Xcode Cloud TestFlight build. No local archive or upload: the build happens entirely on Xcode Cloud with cloud-managed signing.

## Step 1: Validate Requirements

Before proceeding, check all requirements. Stop and ask the user to provide any missing values.

### 1.1 Check for Makefile

```bash
test -f Makefile && echo "Makefile found" || echo "Makefile NOT found"
```

If Makefile is missing, ask:
> "No Makefile found. This skill requires a Makefile with `release` and `info` targets. Would you like me to help create one?"

### 1.2 Check Makefile Targets

```bash
grep -q "^release:" Makefile && echo "release target found" || echo "release target NOT found"
grep -q "^info:" Makefile && echo "info target found" || echo "info target NOT found"
```

If any target is missing, inform the user which targets are needed.

### 1.3 Check Xcode Cloud Configuration

Xcode Cloud projects store CI scripts in a `ci_scripts/` directory inside the Xcode project bundle (or at the repo root). The presence of this directory and its scripts confirms Xcode Cloud is configured.

```bash
find . -type d -name "ci_scripts" -maxdepth 3 | head -5
find . -name "ci_post_clone.sh" -maxdepth 5 | head -5
```

The most common script is `ci_post_clone.sh`, which runs after Xcode Cloud clones the repo. It typically installs tools (xcodegen, homebrew packages) and generates the Xcode project:

```bash
#!/bin/sh
# ci_scripts/ci_post_clone.sh: canonical Xcode Cloud setup script
set -e
brew install xcodegen
cd "$CI_WORKSPACE"   # Xcode Cloud sets this env var to the repo root
xcodegen generate
```

If no `ci_scripts/` directory is found, ask:
> "No `ci_scripts/` directory found. This skill is for projects using Xcode Cloud CI/CD. Did you mean to use `/release-testflight` instead?"

### 1.4 Verify Tag Trigger Configuration

Xcode Cloud workflows are configured in App Store Connect under the app's Xcode Cloud tab. The tag trigger is set in the workflow's "Start Conditions" section. It cannot be verified locally. Confirm with the user that their Xcode Cloud workflow is configured to trigger on tags matching `v*`.

To check recently pushed tags:
```bash
git tag -l 'v*' | tail -5
```

### 1.5 Check Xcode Command Line Tools

```bash
xcodebuild -version 2>/dev/null || echo "Xcode CLI tools not installed"
```

If not installed, inform the user:
> "Xcode command line tools required. Install with: `xcode-select --install`"

## Step 2: Validate OpenAPI Spec

Only proceed here after all requirements are validated. Run the full spec validation to ensure the API contract is consistent before releasing.

```bash
grep -q "^spec-test:" Makefile && echo "spec-test target found" || echo "spec-test target NOT found"
```

If the `spec-test` target exists, run it:

```bash
make spec-test
```

This runs:
1. `lint-api`: Redocly lint on `api.yaml`
2. `test-api-spec`: Go route parity test (routes in `main.go` match spec paths)
3. `generate-types`: Regenerate TypeScript types and verify they're up to date

If any check fails, fix the issue before proceeding. Do NOT skip this step.

If the project has no `spec-test` target, skip this step silently.

## Step 3: Check Current Version

```bash
make info
```

Note the current version and build number before release. For Xcode Cloud projects, the build number in the `BUILD_NUMBER` file is what gets committed with the tag; Xcode Cloud reads this value during the build.

## Step 4: Release

```bash
make release
```

The canonical `release` target for Xcode Cloud projects (based on for-the-win's Makefile):

```makefile
# Typical Xcode Cloud release target
release: upload submit-review
```

Or for tag-only trigger (no local upload):
```makefile
release: commit-version
    @NEW_BUILD=$$(cat BUILD_NUMBER); \
    TAG="v$(MAJOR).$(MINOR).$$NEW_BUILD"; \
    git tag -a "$$TAG" -m "Release $$TAG"; \
    git push origin HEAD "$$TAG"; \
    echo "Tag $$TAG pushed. Xcode Cloud will start the build."
```

This command:
1. Bumps the build number (writes to `BUILD_NUMBER`)
2. Updates `project.yml` with new `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`
3. Commits the version bump
4. Creates an annotated `v*` tag
5. Pushes the commit and tag to origin

Xcode Cloud detects the `v*` tag and starts the build remotely. No local archive or upload happens.

**Version numbering in Xcode Cloud projects**: for-the-win uses `MAJOR.MINOR.BUILD` where `BUILD` is the monotonically incrementing `BUILD_NUMBER`. All four plists (main app, Watch app, Watch widgets, iPhone widgets) are updated atomically in `increment-build`:

```makefile
# from for-the-win/ios/Makefile: syncs version across all targets
increment-build:
    @BUILD_NUM=$$(cat BUILD_NUMBER); NEW_BUILD=$$((BUILD_NUM + 1)); \
    echo $$NEW_BUILD > BUILD_NUMBER; \
    VERSION_STR="$(MAJOR).$(MINOR).$$NEW_BUILD"; \
    for PLIST in $(INFO_PLIST) $(WATCH_INFO_PLIST) $(WATCH_WIDGETS_INFO_PLIST) $(IPHONE_WIDGETS_INFO_PLIST); do \
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$NEW_BUILD" $$PLIST; \
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $$VERSION_STR" $$PLIST; \
    done; \
    sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$$VERSION_STR\"/g" project.yml; \
    sed -i '' "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$$NEW_BUILD\"/g" project.yml
```

**Build number conflict with Xcode Cloud**: If Xcode Cloud is configured to manage build numbers automatically (via "Increment Build Number" in the workflow), it will increment the build number independently from the local `BUILD_NUMBER` file. This causes conflicts: the local file and ASC diverge. To avoid this, either disable Xcode Cloud's auto-increment and rely entirely on the local `BUILD_NUMBER` file, or disable the local increment and let Xcode Cloud own the counter. Pick one; do not use both.

## Step 5: Verify Tag

Confirm the tag was created and pushed:

```bash
git tag -l 'v*' | tail -1
git log --oneline -1
```

Also verify the tag is visible on the remote:
```bash
git ls-remote origin 'refs/tags/v*' | tail -3
```

## Step 6: Monitor Xcode Cloud Build

Xcode Cloud builds are asynchronous. Monitor progress at:
```
https://appstoreconnect.apple.com/apps/{APP_ID}/xcode-cloud
```

The build typically takes 10-20 minutes. Once complete, the build appears in TestFlight automatically. No separate upload step.

**ci_scripts patterns**: The `ci_post_clone.sh` script is the most important. It runs in a clean environment without Homebrew packages pre-installed. Common setup:

```sh
#!/bin/sh
# ci_post_clone.sh
set -e

# Install xcodegen if the project uses it
brew install xcodegen

# Generate the Xcode project from project.yml
cd "$CI_WORKSPACE"
xcodegen generate

# If the project has a web package, install Node dependencies
# (needed for CDK synth or OpenNext builds that happen in pre-xcodebuild scripts)
# cd packages/web && npm ci
```

Environment variables available in Xcode Cloud scripts:
- `CI_WORKSPACE`: repository root
- `CI_BUILD_NUMBER`: Xcode Cloud's build number (if auto-increment is on)
- `CI_TAG`: the tag that triggered the workflow (for tag-triggered builds)
- `CI_BRANCH`: the branch (for branch-triggered builds)

## Step 7: Report Results

After completion, report:
- Version released (run `make info` to confirm)
- Tag name created and pushed
- Note: Xcode Cloud build is async (takes 10-20 minutes)
- Monitor at: `https://appstoreconnect.apple.com/apps/{APP_ID}/xcode-cloud`

## Notes

- No local xcodebuild, archive, or upload (Xcode Cloud handles everything)
- Cloud-managed code signing: no local provisioning profiles or certificates needed
- Xcode Cloud uses the API key configured in App Store Connect (not the local `.env`)
- TestFlight processing by Apple takes an additional 10-30 minutes after the Xcode Cloud build completes
- Email notification arrives when build is ready for testing

## Troubleshooting

If `make release` fails:
- Check for uncommitted changes: `git status`
- Ensure you're on `main` branch: `git branch --show-current`
- Verify remote is reachable: `git remote -v`
- Check if tag already exists: `git tag -l 'v*' | tail -5`
- If the tag exists but the build didn't trigger, check the workflow's start conditions in App Store Connect

If Xcode Cloud build fails:
- Monitor at: `https://appstoreconnect.apple.com/apps/{APP_ID}/xcode-cloud`
- Click the failed build to see logs
- Check `ci_scripts/ci_post_clone.sh` for setup issues: missing `brew install` calls are the most common cause
- Verify the Xcode Cloud workflow is configured with a `v*` tag trigger
- If `xcodegen generate` fails in CI, verify `project.yml` is committed (not gitignored)

If build number conflicts appear (Xcode Cloud incremented independently):
- Disable one of the two increment mechanisms (local `BUILD_NUMBER` file or Xcode Cloud's "Increment Build Number" setting)
- Manually set `BUILD_NUMBER` to one above the current highest in ASC
- Going forward, use only the local `BUILD_NUMBER` pattern (commit the bump, tag, push)
