---
name: app-store-audit
description: Pre-submission audit of an iOS/macOS Xcode project against the Apple App Store Review Guidelines. Use before submitting to App Review (or as a sanity check during development) to surface guideline violations and rejection risks. Detects empty/missing usage descriptions, Privacy Manifest gaps, tracking-SDK declaration mismatches, IAP avoidance, web-view-only apps, App Transport Security exceptions, placeholder metadata, and more. Reports findings rated CRITICAL / HIGH / MEDIUM / LOW with the exact guideline ID and quoted rule text.
---

# App Store Audit — Pre-submission Risk Assessment

Audits an iOS / macOS / visionOS / watchOS Xcode project against the full App Store Review Guidelines (`resources/app-store-review-guidelines.md`). Read-only — never edits source.

The output is a severity-rated report. CRITICAL findings will almost certainly cause rejection. HIGH findings are very likely to be flagged by App Review. MEDIUM are common ask-backs. LOW are best practices.

## Pre-flight

1. **Confirm the guidelines asset is current.**
   - Read the metadata header of `<skill_root>/resources/app-store-review-guidelines.md` (line 1-12) — it has the `Fetched:` date.
   - If the fetch date is **older than 90 days**, tell the user:
     > "The App Store Review Guidelines on file were fetched on `<date>` (`<N>` days ago). Apple updates these without warning, often around WWDC. Want me to refresh before auditing? (y/n)"
   - If they say yes, run the refresh sequence below before continuing.

2. **Locate the target project.**
   - If the user provided a path, use it.
   - Otherwise, look in the current working directory for `*.xcodeproj`, `*.xcworkspace`, or `Package.swift`. If there are multiple, ask which one to audit.
   - Extract: bundle ID (from `project.pbxproj` `PRODUCT_BUNDLE_IDENTIFIER`), product name, deployment target (`IPHONEOS_DEPLOYMENT_TARGET` / `MACOSX_DEPLOYMENT_TARGET`), supported platforms.
   - If `project.yml` (XcodeGen) exists, prefer reading that — it's more parseable than `project.pbxproj`.

3. **Announce the target** to the user in one line, e.g.:
   - `App Store Audit — auditing ios/ForTheWin.xcodeproj (bundle ID com.apresai.forthewin, iOS 17.0+)`

## Audit passes

Run the passes below in order. Each is independent — failures in one don't block the others. If a pass finds nothing, report "<Pass name>: Clean."

### Pass A — Info.plist usage descriptions (Guideline 5.1.1)

**Rule (quoted from 5.1.1):** "Apps that collect data using these technologies must clearly disclose their use, provide users with control over the data, and obtain user consent for the collection."

1. Find the Info.plist (or the project's `INFOPLIST_FILE` / merged values from build settings). Be aware that some projects use `GENERATE_INFOPLIST_FILE = YES` and define keys in build settings instead — check both.
2. Check every key matching `NS*UsageDescription` and `NSPrivacyAccessedAPITypes`:
   - `NSCameraUsageDescription`
   - `NSPhotoLibraryUsageDescription` / `NSPhotoLibraryAddUsageDescription`
   - `NSMicrophoneUsageDescription`
   - `NSLocationWhenInUseUsageDescription` / `NSLocationAlwaysAndWhenInUseUsageDescription` / `NSLocationAlwaysUsageDescription`
   - `NSContactsUsageDescription`
   - `NSCalendarsUsageDescription` / `NSCalendarsFullAccessUsageDescription`
   - `NSRemindersUsageDescription` / `NSRemindersFullAccessUsageDescription`
   - `NSMotionUsageDescription`
   - `NSHealthShareUsageDescription` / `NSHealthUpdateUsageDescription`
   - `NSAppleMusicUsageDescription`
   - `NSHomeKitUsageDescription`
   - `NSSiriUsageDescription`
   - `NSSpeechRecognitionUsageDescription`
   - `NSBluetoothAlwaysUsageDescription` / `NSBluetoothPeripheralUsageDescription`
   - `NSLocalNetworkUsageDescription`
   - `NSNearbyInteractionUsageDescription`
   - `NSFaceIDUsageDescription`
   - `NSUserTrackingUsageDescription`
3. **Flag CRITICAL** for any of the above that:
   - is missing but the entitlements / capability / framework is used (e.g., `import HealthKit` but no `NSHealthShareUsageDescription`)
   - exists but is empty (`<string></string>`)
   - contains placeholder text ("TODO", "Fill in", "App uses your X", "We need access to X")
   - is < 20 characters (too short — Apple wants a real explanation)
4. **Flag HIGH** for usage descriptions that are present but vague — generic strings like "We need your camera" without explaining why or what for.
5. Cross-reference each declared usage description against actual API usage:
   - Grep the project for `AVCaptureDevice`, `PHPhotoLibrary`, `CLLocationManager`, `HKHealthStore`, `LAContext`, etc.
   - If the framework is used but the usage description is missing → CRITICAL.
   - If the usage description is declared but the framework is NOT used → MEDIUM (unused permission claim; remove it).

### Pass B — Privacy Manifest (Guideline 5.1.1)

**Rule (quoted from 5.1.1.v):** "Apps must include a privacy manifest file (PrivacyInfo.xcprivacy) that records the types of data collected, the required reason API categories used, and any tracking domains the app or any included third-party SDKs use."

1. Look for `PrivacyInfo.xcprivacy` in the project (any target, but especially the app target).
2. If **missing** for an iOS app targeting iOS 17+:
   - Flag CRITICAL if the app uses any "Required Reason API" category. Common categories to grep for:
     - File timestamp APIs (`creationDate`, `modificationDate`, `attributesOfItem`, `FileManager.default.contentsOfDirectory`)
     - System boot time (`systemUptime`, `mach_absolute_time` with kernel boot epoch)
     - Disk space (`URLResourceKey.volumeAvailableCapacityKey`, `attributesOfFileSystem`)
     - Active keyboard (`UITextInputMode.activeInputModes`)
     - User defaults (`UserDefaults` not via App Group)
   - Flag HIGH otherwise — even apps that don't use these APIs need the manifest as of Spring 2024 enforcement.
3. If **present**, validate structure:
   - Must have `NSPrivacyTracking`, `NSPrivacyTrackingDomains`, `NSPrivacyCollectedDataTypes`, `NSPrivacyAccessedAPITypes` keys.
   - If `NSPrivacyTracking = true` but `NSPrivacyTrackingDomains` is empty → CRITICAL.
   - If app uses any Required Reason API (per grep above) but `NSPrivacyAccessedAPITypes` doesn't declare it → CRITICAL.

### Pass C — Third-party SDK Privacy declarations (Guideline 5.1.2)

**Rule (quoted from 5.1.2):** "Apps that include third-party SDKs must use them in compliance with their terms and include their privacy disclosures in your own privacy nutrition labels."

1. Look at dependency manifests:
   - Swift Package Manager: `Package.swift`, `Package.resolved`
   - CocoaPods: `Podfile`, `Podfile.lock`
   - Carthage: `Cartfile`, `Cartfile.resolved`
2. For each declared dependency, check against known tracking/analytics SDK list:
   - **Tracking SDKs** (Apple's list — these MUST be declared in `NSPrivacyTracking`): Adjust, AppsFlyer, Branch, Singular, Kochava, Tenjin, Mixpanel, Amplitude, Sentry, Segment, mParticle
   - **Analytics SDKs**: Firebase Analytics, Google Analytics, Mixpanel, Amplitude, Heap, PostHog
   - **Ad SDKs**: Google AdMob, Meta Audience Network, AppLovin, Unity Ads, IronSource, AdColony
   - **Crash reporting**: Crashlytics (Firebase), Sentry, Bugsnag, Datadog RUM
3. For each detected SDK:
   - If it's a tracking SDK and `NSPrivacyTracking = true` is not set → CRITICAL.
   - If it's an analytics/ad/crash SDK and PrivacyInfo.xcprivacy doesn't include a corresponding `NSPrivacyCollectedDataType` entry → HIGH.
   - If the SDK's own `PrivacyInfo.xcprivacy` (bundled with the SDK) wasn't merged into the app's manifest → MEDIUM (Xcode usually merges automatically but worth flagging).

### Pass D — In-App Purchase enforcement (Guideline 3.1.1)

**Rule (quoted from 3.1.1):** "If you want to unlock features or functionality within your app, (by way of example: subscriptions, in-game currencies, game levels, access to premium content, or unlocking a full version), you must use in-app purchase."

1. Grep the project for non-Apple payment SDKs in code (NOT in dependencies — those alone aren't conclusive):
   - `Stripe`, `StripePaymentSheet`
   - `PayPal`, `PayPalCheckout`
   - `Square`, `SquarePOS`
   - `Adyen`
   - `BraintreeKit`
   - References to checkout URLs (search code for `checkout.stripe.com`, `paypal.com/checkout`)
2. Cross-reference with what the app sells:
   - Read the app description / `INFOPLIST_KEY_NSPrincipalClass` keywords if available.
   - If the app appears to sell **digital content/services** (subscriptions, premium features, in-app currency, unlocked levels, premium content access) → ANY non-Apple payment SDK is CRITICAL.
   - If the app appears to sell **physical goods/services** (food delivery, ride share, physical merch, e-commerce) → non-Apple payment SDK is OK (Apple Pay or other payment is fine).
3. Check for StoreKit usage:
   - Look for `import StoreKit` and `Product.products(for:)` / `Transaction.currentEntitlements`
   - If the app sells digital goods but doesn't use StoreKit → CRITICAL.

### Pass E — Web-view-only app detection (Guideline 4.2)

**Rule (quoted from 4.2):** "Your app should include features, content, and UI that elevate it beyond a repackaged website."

1. Grep all `.swift` and `.m`/`.mm` files for view types: `WKWebView`, `UIWebView` (deprecated), `WebKit`, `SFSafariViewController`.
2. Grep for actual native UI: `UIView`, `UIViewController`, `SwiftUI.View`, `NSWindow`.
3. Calculate the ratio. If the root content view is a `WKWebView` and there's no substantial native UI:
   - Flag HIGH — "App appears to be a repackaged website. App Review requires meaningful native functionality (4.2)."
4. Look for "web-app-like" red flags:
   - `URLRequest` to a single domain throughout the app
   - No native settings screen
   - No native onboarding
   - No platform-specific features (push notifications, share extension, widgets, etc.)
5. Whitelist: if the app provides a native shell over the web view AND also has native components (settings, share extension, widgets, native push handling), reduce to MEDIUM or LOW.

### Pass F — App Transport Security (Guideline 5.1.6 / Data Security)

**Rule (quoted from 5.1.6):** "Apps should implement appropriate security measures to ensure proper handling of user information collected pursuant to the Apple Developer Program License Agreement and these Guidelines."

1. Find `NSAppTransportSecurity` in Info.plist.
2. Flag findings:
   - `NSAllowsArbitraryLoads = true` (blanket allow HTTP) → CRITICAL unless there's clear `NSExceptionDomains` scoping. Even then, App Review requires a justification.
   - `NSAllowsArbitraryLoadsInWebContent = true` → HIGH (must justify in App Review notes).
   - Per-domain `NSExceptionAllowsInsecureHTTPLoads = true` → MEDIUM (review will ask why; needs justification).

### Pass G — Metadata sanity (Guideline 2.3)

**Rule (quoted from 2.3.1):** "Don't include any hidden, dormant, or undocumented features in your app; your app's functionality should be clear to end-users and App Review."

**Rule (quoted from 2.3.7):** "Choose a unique app name, assign keywords that accurately describe your app, and don't try to pack any of your metadata with trademarked terms..."

1. Look for placeholder text in app metadata locations:
   - `INFOPLIST_KEY_CFBundleDisplayName` containing "TODO", "Untitled", "MyApp", "Test"
   - `CFBundleName` with default Xcode names
   - Empty or default app icon (1024x1024 must exist for App Store; check `Assets.xcassets/AppIcon.appiconset/Contents.json`)
   - `LSApplicationCategoryType` empty or set to dev default
2. Flag MEDIUM for any of the above.

### Pass H — User-Generated Content moderation (Guideline 1.2)

**Rule (quoted from 1.2):** "Apps with user-generated content present particular challenges... Apps with UGC or social networking services must include: a method for filtering objectionable material; a mechanism to report offensive content and timely responses to concerns; the ability to block abusive users from the service; published contact information so users can easily reach you."

1. Heuristic: does the app have UGC? Look for:
   - Text input fields that submit to a backend (search for `URLSession` / `Alamofire` POST/PUT calls in code containing user-typed strings)
   - Comment / post / message features (search for naming patterns: `Comment`, `Post`, `Message`, `Review`, `Chat`)
   - Profile customization (avatars, usernames, bios)
2. If UGC detected, look for the four required moderation features:
   - **Filter**: profanity filter, content moderation API (Cohere, Perspective API, Apple Moderation API)
   - **Report**: a "Report" button or `MFMailComposeViewController` flow for reports
   - **Block**: a "Block user" button or similar
   - **Contact**: developer contact in the app (Settings screen, Privacy section)
3. For each missing feature: flag HIGH.

### Pass I — VPN / Network Extension (Guideline 5.4)

**Rule (quoted from 5.4):** "Apps offering VPN services must utilize the NEVPNManager API and may only be offered by developers enrolled as an organization."

1. Check the entitlements file for `com.apple.developer.networking.networkextension` or `com.apple.developer.networking.vpn.api`.
2. If present:
   - Confirm the developer account type is organization (note in report; can't auto-detect).
   - Confirm code uses `NEVPNManager` (not a third-party VPN library) → flag MEDIUM if third-party only.
   - Confirm a privacy policy URL is set.

### Pass J — Subscription terms (Guideline 3.1.2)

**Rule (quoted from 3.1.2):** "Subscriptions must work on all of the user's devices where the app is available."

Only run if the app uses subscriptions (StoreKit `Product.SubscriptionInfo` references detected):
1. Confirm subscription terms link in the app (look for URLs to `https://www.apple.com/legal/internet-services/itunes/dev/stdeula/` or custom EULA, plus a Privacy Policy URL).
2. Required disclosures on the purchase screen (this is hard to detect statically — flag as MEDIUM "needs human review").

### Pass K — Common rejection causes (catch-all)

Quick checks for things that frequently trip up submissions:
1. **Demo account credentials in App Review notes** — can't detect from code, but include as a reminder if the app has a login.
2. **Crash on launch** — can't run the app, but check `Info.plist` for `UIApplicationSceneManifest` consistency and required device capabilities.
3. **Background modes** — check `UIBackgroundModes` entries. Each must be justified by actual code usage. (e.g., `audio` requires playing audio in background; `location` requires `CLLocationManager.allowsBackgroundLocationUpdates = true`).
4. **Push notifications without entitlement** — if the app calls `UNUserNotificationCenter.current().requestAuthorization` but the entitlements file lacks `aps-environment`, flag CRITICAL.
5. **HealthKit** — if `HealthKit.framework` is linked or `import HealthKit` appears, verify both usage description AND `com.apple.developer.healthkit` entitlement.

## Final Report

After all passes, output a single consolidated report:

```
## App Store Audit — Report

**Target**: <project name> (<bundle ID>)
**Platform**: <iOS X.0+ / macOS X.0+>
**Guidelines version**: fetched <date> from developer.apple.com

### CRITICAL (will likely cause rejection — N findings)
- [<guideline ID>] <finding title>
  - Evidence: <file:line or code snippet>
  - Rule: "<verbatim quote from guidelines>"
  - Fix: <specific action>

### HIGH (likely flagged in review — N findings)
...

### MEDIUM (review may ask — N findings)
...

### LOW (informational — N findings)
...

### Verdict: [GO / NO-GO / NEEDS-FIXES]
[1-2 sentence summary. NO-GO if any CRITICAL findings; NEEDS-FIXES if HIGH findings; GO otherwise.]
```

Always quote the guideline text verbatim from `resources/app-store-review-guidelines.md` — never paraphrase, since paraphrasing loses Apple's exact language and could be misleading.

## After the Report — Fix Prompt

If the verdict is NO-GO or NEEDS-FIXES, offer to generate a **fix prompt** for the user to kick off a planning session:

1. List every CRITICAL and HIGH finding with file path and the specific guideline ID.
2. For each, describe what the fix should accomplish (the outcome, not the implementation).
3. Reference any patterns the project already has (e.g., "the existing `NSCameraUsageDescription` shows the right tone for permission strings").
4. End with: "After fixing, run `/app-store-audit` again to confirm all CRITICAL and HIGH issues are resolved."

Present as a copyable code block, then ask the user whether to enter plan mode with this prompt as the task.

## Refreshing the guidelines asset

If the audit runs against a stale guidelines file, refresh it:

```bash
# From the apple-release skill root:
cd plugins/apple-release  # adjust path as needed

# Fetch + convert
curl -s -L "https://developer.apple.com/app-store/review/guidelines/" \
  -H "User-Agent: Mozilla/5.0" -o /tmp/asrg-raw.html
pandoc -f html -t gfm-raw_html /tmp/asrg-raw.html -o /tmp/asrg-full.md

# Preserve the metadata header and prepend it. Update the Fetched: date in the header first.
# Then concatenate into resources/app-store-review-guidelines.md.
```

Update the `Fetched:` date in the metadata header to today's date when you refresh. The audit pre-flight uses this to detect staleness.

If `pandoc` is not installed: `brew install pandoc`.

## Rules

- NEVER edit project source files — read-only.
- NEVER suggest skipping App Review — the audit is to PASS review, not to circumvent it.
- ALWAYS quote guideline text verbatim from the saved asset; do not paraphrase Apple's rules.
- ALWAYS include the guideline ID (e.g., "5.1.1.ii") in findings so the user can cite it in App Review responses.
- If the saved guidelines are older than 90 days, offer to refresh BEFORE auditing.
- If a check is ambiguous (e.g., "does this app provide meaningful native functionality"), flag as MEDIUM with a "needs human judgment" note rather than guessing.
- The audit is one tool of several — also pair with manual review of: screenshots, app description, privacy questionnaire in App Store Connect, demo account access for review team.
