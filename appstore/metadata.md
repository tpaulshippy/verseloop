# Verse Loop Daily — App Store Connect metadata (en-US, v1.0)
# Canonical copy-paste source. All fields verified Oct 2026.
# Bundle: com.tpaulshippy.verseloop · v1.0 · iPhone-only · iOS 17+

## URLs (live, served by Cloudflare Worker)
- Privacy Policy URL: https://verseloop.pshippy-245.workers.dev/privacy
- Support URL: https://verseloop.pshippy-245.workers.dev/support
- Marketing URL (optional): https://github.com/tpaulshippy/verseloop
- Data deletion info: https://verseloop.pshippy-245.workers.dev/support#delete-my-data
  (in-app: Settings → Delete All My Data — one tap, no account, deletes local + cloud + rotates sync code)
- In-app privacy link: Settings → Privacy & Support → Privacy Policy (same URL as above, reachable with no login)

## App Information
- Name (30 chars max): Verse Loop Daily
- Subtitle (30 chars max): Memorize ESV word by word
- Primary Category: Education
- Secondary Category: Reference
- Content Rights: Contains third-party content (ESV Bible text via api.esv.org under Crossway license; fetched at runtime, never bundled). App holds a valid ESV API key server-side; attribution is in-app (Settings → About) and on the store description.

## Pricing & Availability
- Price: Free
- Availability: All territories where ESV API terms allow (default: all). No in-app purchases.

## Version 1.0 — App Store Listing (en-US)

### Promotional Text (170 chars, editable without review)
ESV-only memorization with real spaced repetition. Type first letters, forgive slips, grade honestly — your loop stays due-sorted and yours.

### Description (4000 chars)
Start the day by memorizing ESV verses word-by-word — from first letters, with the reference tested last.

Verse Loop Daily is a native, offline-first iOS app with zero dependencies for one workflow: a daily Loop of due verses, a forgiving first-letter tester, and real SM-2 spaced repetition driven by your own Again / Hard / Good / Easy grades.

HOW IT WORKS
• Today tab shows your due-sorted Loop: Due / Total / Mastered at a glance.
• Tap a verse to practice. Type the first letter of each word, one at a time — then the book initial and numbers for the reference, in one flow. The reference composes inline (Psalm 23:1), styled like the words.
• Right character appears; wrong character buzzes, marks a red mistake, and moves on. Tap any red word to forgive it as accidental — including Shake to forgive the latest. A mistake count (not a progress bar) keeps you honest.
• When done, see mistakes plus a suggested grade. Your grade decides the schedule — mistakes never auto-grade. Every grade has an 8-second Undo.

REAL SPACED REPETITION
Every rep ends in an explicit grade → SM-2 ease + intervals (Again resets with 10-min retry; Hard ×1.2; Good 1d → 3d → ×ease; Easy 4d start with ease bonus). Due means end-of-day + interval. Only your grade moves the schedule.

ESV-ONLY, LEGALLY
Only the English Standard Version. ESV text © Crossway is never bundled — the app ships with two short public-domain sample verses so it works offline, and fetches real ESV passages at runtime through the built-in secure service (cached for offline review). No setup needed, no key ever lives on-device.

YOUR DATA IS YOURS
• Offline-first JSON store (<100 KB typical). No account, no analytics, no ads, no tracking.
• JSON export/import anytime (Settings → Prepare JSON export).
• Optional end-to-end encrypted backup: AES-GCM with a key derived from your auto-generated sync code (HKDF-SHA256). The server stores only ciphertext it cannot read.
• Delete everything anytime: Settings → Delete All My Data removes local verses + history, deletes the cloud backup, and rotates the code. Full equivalent of account deletion — there are no accounts.

BUILT FOR FOCUS
Zero dependencies, SwiftUI only, no web views, no media. Cold start <1s. Full dark-mode support. iPhone SE to Pro Max.

Scripture quotations are from the ESV® Bible (The Holy Bible, English Standard Version®), © 2001 by Crossway, a publishing ministry of Good News Publishers. Used by permission via the ESV API. All rights reserved.

### Keywords (100 chars, comma-separated, no spaces needed)
bible,esv,scripture,memory,memorize,verses,spaced,repetition

### Screenshots (iPhone-only app, TARGETED_DEVICE_FAMILY=1)
- Required set: iPhone 6.9" class — 1290×2796 portrait PNG (accepted: 1320×2868 / 1290×2796 / 1260×2736). Apple auto-scales to 6.5"/6.3"/6.1".
- iPad: NOT required (iPhone-only). No iPad screenshots needed.
- Files: appstore/screenshots/01–06-1290x2796.png (6 framed shots from real SE3 UI, exact pixels, RGB, no transparency)
  1. Today's Loop — due-sorted queue
  2. Type-the-first-letter tester
  3. Forgive accidental slips
  4. Grade with SM-2 + 8s Undo
  5. Add verse with ESV fetch
  6. Settings — encrypted backup, export, Delete My Data
- App Preview video: optional, skipped for v1.0.

### Age Rating (4+)
- No objectionable content, no cartoon/fantasy violence beyond selectable Bible text, no gambling, no contests, no messaging, no user-generated sharing, no location, no health data.
- Questionnaire answers: Violence: None. Sexual content: None. Profanity: None (scripture text may include standard Bible wording). Gambling: No. User communication: No. Personal info: No collection.

### App Privacy (Nutrition Label)
- Data Collection: Data Not Collected.
- Tracking: No (NSPrivacyTracking=false, no IDFA, no ATT prompt).
- Privacy manifest: VerseLoop/PrivacyInfo.xcprivacy ships in bundle — NSPrivacyTracking=false, NSPrivacyCollectedDataTypes=[], NSPrivacyAccessedAPICategoryUserDefaults/CA92.1 (app-only settings + sync code + auto-sync flag).
- Required-reason APIs used: UserDefaults only (CA92.1). No file-timestamp / boot-time / disk-space / keyboard APIs.

### Export Compliance
- ITSAppUsesNonExemptEncryption=false (Info.plist). App uses only iOS-standard exempt encryption: HTTPS (URLSession) + Apple CryptoKit AES-GCM for end-to-end backup. No proprietary crypto, no CCATS required.

## App Review Notes (for reviewer)
- No login needed — app opens directly to Today's Verses with two KJV demo verses. No demo account required.
- To test ESV fetch: Verses → + → type "John 1:1" → Fetch ESV text (uses production Worker + server-side key; no setup needed by reviewer).
- Sync code is auto-generated per install and never shown; Push/Pull is an encrypted backup for that device. To test multi-device move, use Settings → JSON export/import.
- Delete My Data: Settings → Delete All My Data → Delete everything (confirmation dialog). Clears local + DELETEs cloud snapshot + rotates code.
- Privacy Policy is in-app: Settings → Privacy & Support → Privacy Policy (https://verseloop.pshippy-245.workers.dev/privacy), reachable with no login.
- ESV rights: text is fetched at runtime via licensed api.esv.org key (server-side), never bundled; attribution in Settings → About and store description. Demo seeds are public-domain KJV.
- Contact: https://github.com/tpaulshippy/verseloop/issues

## Version / Build
- Marketing version: 1.0.1 (CFBundleShortVersionString, via `$(MARKETING_VERSION)` — 1.0 train is closed/approved, so all new uploads must be > 1.0)
- Build: stamped by Xcode Cloud from `CI_BUILD_NUMBER` (`ci_pre_xcodebuild.sh` writes `CURRENT_PROJECT_VERSION`; `Info.plist` reads `$(CURRENT_PROJECT_VERSION)` — do not hand-bump for cloud builds)
- Deployment target: iOS 17.0. Devices: iPhone only.

## Release
- Release type: Manual release (hold for developer release after approval) — recommended for v1.0.
- Phased release: off for v1.0.
