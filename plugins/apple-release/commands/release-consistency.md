---
name: release-consistency
description: Audit and standardize Apple code-signing, release tooling, and docs across all apresai apps so /release-testflight works identically everywhere. Drives one provable, durable signing model and scrubs cert/signing/Fastlane doc drift. Use to verify a portfolio is uniform, or to converge a deviating app.
---

# Release Consistency: drive one provable, durable signing model

Standardize Apple code-signing, release tooling, and documentation across every app in the
**apresai** Apple Developer account (team `CNRU7L924E`) so each app ships through ONE provable,
durable model and `/release-testflight` behaves identically everywhere.

**This is a consistency + documentation pass, NOT a release**. Never upload to TestFlight unless
explicitly told. Use `/release-testflight` for actual uploads.

## How to run

Per app (the user names one), or sweep the portfolio one app at a time. App Store apps in scope:
`eleven9s`, `clipz`, `sophie`, `for-the-win`, `regist`, `prd`. **`codexbar` is out of scope**:
it's a Developer ID / Sparkle macOS app signed with an upstream author identity, not the apresai
distribution cert; it has no App Store / TestFlight path.

## The canonical model: the target every App Store app converges to

1. **One distribution cert:** `KZ4VK235YL`, *Apple Distribution: Apres AI LLC*
   (SHA-1 `CB21C90D8D095AA6B6002C1A6F7FC20019819AFD`, exp 2027-06-03). **One installer cert:**
   `HAM2CK8249` (clipz `.pkg` only). Team `CNRU7L924E`, org "Apres AI LLC".
2. **Archive AND export are Manual.** `CODE_SIGN_STYLE=Manual`, `DEVELOPMENT_TEAM=CNRU7L924E`, and
   **no `-allowProvisioningUpdates` on the archive step** (keep it only on export). Automatic +
   `-allowProvisioningUpdates` lets xcodebuild silently mint/modify profiles at build time, so the
   embedded profile isn't a thing you declared or can prove. Manual at both ends = provable.
3. **Cert reference: generic `"Apple Distribution"`** at both archive (`CODE_SIGN_IDENTITY`) and
   export (`signingCertificate`), **conditional on the keychain single-instance invariant** (see
   §invariants). Until exactly one "Apple Distribution" identity exists in the keychain, an app may
   keep a SHA-1 pin (`CODE_SIGN_CERT_SHA1`) for disambiguation. eleven9s does this today and it is
   correct, not a defect, until the keychain is de-duped.
4. **Profiles referenced by STABLE NAME, never by UUID.** UUIDs are server-assigned and change on
   every re-mint, so pinning a UUID would force an ExportOptions edit + PR in every repo on every
   annual rotation. Reference by Name; the Name survives rotation.
5. **Profile naming: `"<App> App Store"`.** The rule is *stable + unique + ends in "App Store"*.
   Structural second targets append a role (`"<App> Share App Store"`, `"<App> Watch App Store"`).
   **Do not police the exact `<App>` token or churn conforming names**: e.g. `"FTW App Store"` is
   fine; only genuinely non-conforming names (a Fastlane-legacy `"match AppStore …"`, a
   bundle-id-derived `"dev.apresai.x-prd"`) get renamed.
6. **No Fastlane. No `match`. Anywhere.** All signing is ASC-direct via `xcodebuild` (or
   `flutter build ipa` for Flutter apps) + the ASC API key `WT7YRT8J32`.
7. **Provability = verify the EXPORTED artifact, not the `.xcarchive`.** An app may *archive* with
   an auto-picked cert and *re-sign at export*; the archive can show the wrong cert while the export
   is correct. Verify the shipped `.ipa`/`.pkg`: `codesign -dvv` → `Apple Distribution: Apres AI LLC`
   / team `CNRU7L924E` (`pkgutil --check-signature` for clipz's `.pkg`).

### The two single-instance invariants (what makes generic references provable)

Generic references are only deterministic when exactly one candidate exists. Both invariants are
enforced by the rotation tooling so they hold without operator vigilance:

1. **One profile per Name installed locally**: `renew-profile.sh` self-cleans on re-mint: after
   installing the new profile it deletes every OTHER local file decoding to the same `:Name`
   (matching the decoded Name across BOTH `*.mobileprovision` and `*.provisionprofile`, never on
   filename/UUID). Makes by-name profile resolution deterministic.
2. **One "Apple Distribution" identity in the keychain**: `rotate-dist-cert.sh` deletes the
   superseded identities after importing the new cert. Makes the generic `"Apple Distribution"`
   reference deterministic, and is the prerequisite for any app dropping its SHA-1 pin.

The rotation tooling lives in `~/dev/eleven9s/ios/scripts/` (`renew-profile.sh`,
`rotate-dist-cert.sh`, `renew-portfolio-profiles.sh`). The annual chore is
`make -C ~/dev/eleven9s/ios rotate-dist-cert && make -C ~/dev/eleven9s/ios renew-portfolio-profiles`.
No per-repo edits.

## Per-app procedure

### 1. Preflight (READ-ONLY): classify before touching anything
Inspect and cite `file:line`:
- Xcode signing: `project.yml` (xcodegen) / `.pbxproj` / Flutter `ios/`, **archive** style
  (`CODE_SIGN_STYLE`, `-allowProvisioningUpdates`).
- Every `ExportOptions*.plist`: `signingStyle`, `signingCertificate`, the full
  `provisioningProfiles` map (note **name vs UUID** per entry), `installerSigningCertificate`.
- Cert reference: generic name vs specific CN vs SHA-1 pin (`CODE_SIGN_CERT_SHA1`).
- Release path: `Makefile` / `scripts/`, any `fastlane/` dir (should be **none**), repo-local
  `.claude/commands/*release*`.
- Installed profiles for the app's bundle IDs in `~/Library/MobileDevice/Provisioning Profiles/`:
  `security cms -D -i <file>`; check for **duplicate Names** (stale-cert dupes are the nondeterminism
  hazard).

Assign a verdict (rubric below). A 🟢 app needs no tooling change, only a docs check.

### 2. Run `/release-testflight` in its SAFEST verifying mode
Its preflight / dry-run / `check-signing` path: do **not** upload. Confirm it resolves to exactly
one valid profile and (would) produce a `KZ4VK235YL`-signed export. Note any per-repo command drift.

### 3. Fix TOOLING (one PR per repo)
Only what preflight flagged:
- Set **Manual archive** + drop `-allowProvisioningUpdates` from the archive step (keep on export).
- Converge a non-conforming profile **Name** to `"<App> App Store"` (re-mint + update ExportOptions
  + add the Name to `renew-portfolio-profiles.sh`). Leave conforming names alone.
- Standardize `ExportOptions` to `{ manual, generic cert, by-name }`. Strip specific-CN identities.
- Remove every Fastlane/`match` remnant.
- Durability footguns: ensure `ExportOptions.plist` is committed (not gitignored), and that no
  generator target rewrites it to `signingStyle=automatic`.

### 4. Audit DOCS (same PR): make every doc reflect the consolidation
Grep the whole repo (READMEs, `CLAUDE.md`, `AGENTS.md`, `docs/**`, `SKILL.md`,
`.claude/commands/**`, runbooks, Makefile/script comments, `.env.example`) and fix the drift:
checklist below.

### 5. Verify + ship
Build-verify the **exported** artifact is `KZ4VK235YL`-signed (when a build is in scope). Run
`/chad-review`; fix ALL findings at every severity in the same PR (MEDIUM/LOW are never
backlogged), then `receipt.sh verify --pr <n>` must pass before the squash-merge.

## Doc-drift checklist (certs, signing, Fastlane removal)

| Stale pattern | Correct to |
|---|---|
| `fastlane`, `match`, `Fastfile`, `Matchfile`, `MATCH_PASSWORD`, "managed by Fastlane Match", `sophie-fastlane-match` | ASC-direct `xcodebuild`/`flutter` flow; delete the relic. **Keep** legit "fastlane issue #29743" altool-bug citations. |
| `Chad Neal` as signing identity / cert `O=` / "Team Name" | **Apres AI LLC** (team ID `CNRU7L924E` unchanged) |
| Old cert IDs/SHA-1s: `SRQ4AH6PDP`, `2AS43G464J`, `GK7FQXQH9X`, `3755USWA8U` | `KZ4VK235YL` / `CB21C90D…`; installer → `HAM2CK8249` |
| Hardcoded profile **UUIDs** / "pin by UUID" guidance | reference by **stable Name** `<App> App Store` |
| "for-the-win / regist use cloud signing", "no profiles needed" | they are **manual + named**; stay signing-agnostic, read `signingStyle` from each ExportOptions |
| `eleven9s.messages` / iMessage-extension profile (`PROVISIONING_PROFILE_NAME_MESSAGES`) | dropped for v1, remove |
| "2-cert cap" stories; pre-consolidation single-cert rotation runbooks | account-wide **`renew-portfolio-profiles`** self-cleaning flow (NB: `renew-all-profiles`, eleven9s main+Share re-mint, is a *live, distinct* target, not stale) |

## Verdict rubric

- **🟢 GREEN**: conforms AND `/release-testflight` resolves to one valid `KZ4VK235YL`-signed export.
  Docs check only.
- **🟡 YELLOW**: ships today but deviates (Automatic archive, non-conforming profile name, stale
  docs, gitignored/footgun ExportOptions). Tooling + docs PR; no breakage.
- **🔴 RED**: won't produce a valid signed export today. Fix first; it blocks release.

## Output contract

**Per app:** `app | verdict | /release-testflight result | tooling fixes (PR#) | doc fixes (files) | residual risk`.
**Cross-app summary:** separate **where it's already working** (🟢, untouched) from **where tooling
and/or docs were fixed** (🟡/🔴, with PR links).

## Guardrails

- Verify read-only first; change only what preflight justifies.
- One PR per repo via worktree branch → push → `gh pr create` → `/chad-review` →
  `receipt.sh verify --pr <n>` → squash-merge.
  Never commit to `main` directly; never `--no-verify`.
- **Do NOT pin by UUID. Do NOT re-introduce Fastlane. Do NOT upload** unless explicitly instructed.
- Don't churn conforming profile names or drop an app's SHA-1 pin before the keychain single-instance
  invariant holds.
- One-env testing rules. Update `docs/backlog.md` + memory in the same PR that closes a task.
