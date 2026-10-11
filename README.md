# VerseLoop — ESV-only memorization with real spaced repetition

A native iOS app (SwiftUI, zero dependencies) for one workflow: **starting the day by memorizing ESV verses word-by-word from first letters, with the reference tested last** — without being punished for fat-finger slips, and without your verses being trapped on one device.

Built as an alternative to Versify for that single workflow. It is deliberately **not** a Versify clone: no game arcade, no multi-translation library, no account system. One daily Loop, one tester, one scheduler.

## The UX difference (why it's not a clone)

| Versify | VerseLoop |
|---|---|
| Game list + auto-scored taps | Single due-sorted **Loop**: one verse at a time |
| Type mode with no per-error recourse | Wrong letter **buzzes + marks a red mistake** — tap any red word to forgive it as **accidental** |
| No SM-2 from your feedback (per user report) | Every rep ends in an explicit **Again / Hard / Good / Easy** → real SM-2 ease + intervals |
| Progress bar, no mistake accounting | No progress bar — a **mistake count** in the header, net of forgiven slips, plus a suggested grade |
| Library stuck on-device | **JSON export/import + optional Worker sync code** — same code on two devices, push/pull |

Tester: the reference stays **hidden** and no word counts are shown. **Type the first letter** of each word, one at a time — then, without breaking stride, the **reference: book initial, then numbers** (colon skipped). `tlimsisnwp231` flows in as one session, the reference composing inline as **Psalm 23:1**, styled just like the words. Multi-verse passages work too (`Psalm 23:1-6` types `…p2316`, separators appearing on their own). Right character → it appears; wrong → haptic buzz, red mistake, move on. Every mistake carries its own "accidental?" toggle (shake forgives the latest too). No instruction chrome — just due state and mistake count. Then see mistakes + a suggested grade, and grade. Grades get an **8-second Undo** too. Full dark-mode support throughout.

## ESV-only, legally

**Only the English Standard Version.** ESV text is © Crossway and is **never bundled in this repo** — not in code, seeds, tests, or recordings fixtures. The app ships with two short public-domain KJV demo verses so the simulator build works offline; real ESV passages are fetched at runtime through your own Worker, which holds the free api.esv.org key server-side (set once as `ESV_API_TOKEN`, auto-deployed by CI). No key ever lives on-device.

1. Get a free key at https://api.esv.org (an "API Application").
2. Set it once as the `ESV_API_TOKEN` repo secret (Settings → Secrets and variables → Actions). The deploy workflow puts it server-side on every deploy. The Worker caches passages 24h (free Cache API) to stay inside ESV quotas.

> Scripture quotations are from the ESV® Bible (The Holy Bible, English Standard Version®), © 2001 by Crossway, a publishing ministry of Good News Publishers. Used by permission via the ESV API. All rights reserved.

## Performance (vs Versify 36.7 MB)

- Zero dependencies, SwiftUI only, offline-first JSON store (<100 KB typical)
- No web views, no media, no analytics SDKs
- Cold start on iPhone SE (3rd gen) simulator: **< 1 s** to interactive Loop; app bundle **1.4 MB** (vs Versify's 36.7 MB download)
- One network call per verse add (cached forever locally); reviews are pure local computation

## Project layout

```
VerseLoop/            native iOS app (iOS 17+, iPhone SE3 supported)
  VerseLoopApp.swift  entry
  Models.swift        Verse, Grade, SM-2 ReviewState, LibraryEnvelope v1
  VerseStore.swift    queue, grading+undo, JSON persistence, export/import, sync
  ESVService.swift    Worker-proxy-first ESV fetch, direct fallback
  ContentView.swift   Loop / Verses / Add / Settings tabs
  ReviewView.swift    type-the-first-letter tester + mistakes + per-word forgive + grading
worker/               Cloudflare Worker (free tier): ESV proxy + sync store
recordings/           simulator screen recordings (.mov) + screenshots
```

## Run it (simulator, iPhone SE 3rd gen)

```bash
# build + install + launch on the SE3 simulator
./scripts/run-sim.sh
# or manually:
xcodebuild -project VerseLoop.xcodeproj -target VerseLoop -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' build
```

No signing team needed for simulator. For your physical SE3: open `VerseLoop.xcodeproj` in Xcode, select the VerseLoop target → Signing, add your Apple ID team, connect the phone, Run. Deployment target is iOS 17.0 so SE3 is fully supported.

## TestFlight (onto your iPhone SE3)

Prereqs: paid Apple Developer membership + the app's bundle ID (`com.tpaulshippy.verseloop`) registered to your team (Xcode automatic signing does this).

1. **App Store Connect**: [apps](https://appstoreconnect.apple.com/apps) → **+** → New App → name `VerseLoop`, bundle ID `com.tpaulshippy.verseloop`, SKU `verseloop`.
2. **Archive**: in Xcode set the VerseLoop target's team, then Product → Archive (Release). Or run `./scripts/archive-testflight.sh` after putting your Team ID in `scripts/ExportOptions.plist`.
3. **Distribute**: Organizer → Distribute App → TestFlight & App Store → upload. Wait for processing (~10–60 min; you'll get an email).
4. **Testers**: App Store Connect → your app → TestFlight → add yourself as an **internal tester** (no beta review needed). Install Apple's **TestFlight** app on the SE3, accept the invite.
5. **First launch on device**: just add verses (ESV fetches through your Worker; the two KJV demo verses work with zero setup).

Every re-upload needs a new build number: bump `CURRENT_PROJECT_VERSION` in the project (1 → 2 → 3…). External testers (other people) require passing Beta App Review first — internal testing does not.

## Worker (optional but recommended, free tier)

```bash
cd worker && npm i
npx wrangler secret put ESV_API_TOKEN   # your api.esv.org key
npm run deploy                          # -> https://verseloop.<you>.workers.dev
```

The app points at your Worker URL (baked in at build time) and generates its own sync code on first launch — nothing to configure on-device. Sync is deliberately single-device: the code is never shown, so each install has its own encrypted bucket, and Push/Pull acts as encrypted backup for that device. To move data between devices, use Settings → JSON export/import. Libraries are end-to-end encrypted (AES-GCM, key derived from the code via HKDF-SHA256), so the Worker only ever stores ciphertext it cannot read. No KV binding needed to start (in-memory); add the `SYNC_KV` binding in `wrangler.toml` for durable snapshots — still free tier.

Endpoints: `GET /health` · `GET /v1/esv?q=John+1:1` · `PUT/GET /v1/sync/:code` (256 KB cap).

## Spaced repetition used

SM-2-lite (Anki-style): Again resets (10-min retry, ease −0.20, lapse+1); Hard (ease −0.15, ×1.2); Good (1d → 3d → ×ease); Easy (ease +0.15, 4d start, ×ease×1.3). Ease floor 1.3. Due = end of day + interval. Only your explicit grade moves the schedule — mistake counts are advisory, net of per-word accidental forgiveness.

## Evidence

`recordings/` (all captured on **iPhone SE (3rd generation)** simulator, iOS 18.5, **dark mode**):
- `verseloop-se3.mov` — full screen recording of the automated UI run below
- `01-loop.png` — Today's Loop with Due/Total/Mastered + due-sorted queue
- `02-review-mistake.png` — wrong first letter → red mistake word + "1 mistake"
- `03-review-forgiven.png` — mistake forgiven as accidental → "0 mistakes"
- `04-graded.png` — graded Good → next due date, Undo window
- `05-settings.png` — sync, export/import, about
- `06-add-verse.png` — Add verse with ESV fetch (ranges like `Psalm 23:1-6` accepted)
- `07-range-ref.png` — multi-verse range composed inline with colon + dash
- `08-long-scroll.png` — 71-word passage auto-followed to the grade card

`VerseLoopUITests` drives all passes and **passes** on the SE3 sim:
`testLoopFlow`: Loop → tap verse → tester appears → type wrong letter → "1 mistake" → forgive it → "0 mistakes" → type the rest → reference `P231` → suggested grade → Good → Undo grade → re-grade → Next → Settings → Add sheet.
`testRangeFlow`: Psalm 23:1-2 straight through (25 initials + `P2312`) → composed reference → grade.
`testLongFlow`: Psalm 23:1-4 (71 words + `P2314`) with auto-scroll follow → ends at the grade card → grade.
