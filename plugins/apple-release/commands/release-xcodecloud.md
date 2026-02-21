---
name: release-xcodecloud
description: Release via Xcode Cloud - bump version, tag, and push to trigger Xcode Cloud TestFlight build. Use when the project uses Xcode Cloud CI/CD with tag-based triggers.
---

# Release via Xcode Cloud

Bump version, create annotated tag, and push to trigger Xcode Cloud TestFlight build. No local archive or upload — the build happens entirely on Xcode Cloud with cloud-managed signing.

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

```bash
find . -type d -name "ci_scripts" -maxdepth 3 | head -5
```

The presence of a `ci_scripts/` directory confirms Xcode Cloud is configured for this project. If not found, ask:
> "No `ci_scripts/` directory found. This skill is for projects using Xcode Cloud CI/CD. Did you mean to use `/release-testflight` instead?"

### 1.4 Check Xcode Command Line Tools

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
1. `lint-api` — Redocly lint on `api.yaml`
2. `test-api-spec` — Go route parity test (routes in `main.go` match spec paths)
3. `generate-types` — Regenerate TypeScript types and verify they're up to date

If any check fails, fix the issue before proceeding. Do NOT skip this step.

If the project has no `spec-test` target, skip this step silently.

## Step 3: Check Current Version

```bash
make info
```

Note the current version before release.

## Step 4: Release

```bash
make release
```

This command:
1. Bumps the build number
2. Commits the version bump
3. Creates an annotated `v*` tag
4. Pushes the commit and tag to origin

Xcode Cloud detects the `v*` tag and starts the build remotely. No local archive or upload happens.

## Step 5: Verify Tag

Confirm the tag was created and pushed:

```bash
git tag -l 'v*' | tail -1
git log --oneline -1
```

## Step 6: Report Results

After completion, report:
- Version released (run `make info` to confirm)
- Tag name created
- Note: Xcode Cloud build is async — takes ~10-15 minutes
- Link to monitor: https://appstoreconnect.apple.com/apps

## Notes

- No local xcodebuild, archive, or upload — Xcode Cloud handles everything
- Cloud-managed code signing — no local provisioning profiles needed
- TestFlight processing by Apple takes an additional 10-30 minutes after build
- Email notification arrives when build is ready for testing

## Troubleshooting

If `make release` fails:
- Check for uncommitted changes: `git status`
- Ensure you're on `main` branch: `git branch --show-current`
- Verify remote is reachable: `git remote -v`
- Check if tag already exists: `git tag -l 'v*' | tail -5`

If Xcode Cloud build fails:
- Monitor at: https://appstoreconnect.apple.com/apps
- Check `ci_scripts/ci_post_clone.sh` for setup issues
- Verify the Xcode Cloud workflow is configured with a `v*` tag trigger
