# VerseLoop — ESV-only memorization with real spaced repetition

A native iOS app (SwiftUI, zero dependencies) for one workflow: **starting the day by memorizing ESV verses word-by-word from first letters** — without being punished for fat-finger taps, and without your verses being trapped on one device.

Built as an alternative to Versify for that single workflow. It is deliberately **not** a Versify clone: no game arcade, no multi-translation library, no account system. One daily Loop, one tester, one scheduler.

## The UX difference (why it's not a clone)

| Versify | VerseLoop |
|---|---|
| Game list + auto-scored taps | Single due-sorted **Loop**: one verse at a time |
| A tap on the wrong word = penalty, no recourse | Taps only **peek** — they never grade. **Oops button + shake-to-undo** rewinds any tap |
| No SM-2 from your feedback (per user report) | Every rep ends in an explicit **Again / Hard / Good / Easy** → real SM-2 ease + intervals |
| "Taps were accidental" isn't a concept | An **accidental-taps toggle** zeroes peek influence on that grade |
| Library stuck on-device | **JSON export/import + optional Worker sync code** — same code on two devices, push/pull |

Tester: each word shows only its **first letter**; tap to peek, tap again to hide, Reveal-all, Oops-undo, then grade. Grades get an **8-second Undo** too.

## ESV-only, legally

**Only the English Standard Version.** ESV text is © Crossway and is **never bundled in this repo** — not in code, seeds, tests, or recordings fixtures. The app ships with two short public-domain KJV demo verses so the simulator build works offline; real ESV passages are fetched at runtime:

1. Get a free key at https://api.esv.org (an "API Application").
2. Either paste it in **Settings → ESV API key** (stays on-device), or — better — deploy the Worker below and put the key in `wrangler secret put ESV_API_TOKEN` so devices never hold it. The Worker caches passages 24h (free Cache API) to stay inside ESV quotas.

> Scripture quotations are from the ESV® Bible (The Holy Bible, English Standard Version®), © 2001 by Crossway, a publishing ministry of Good News Publishers. Used by permission via the ESV API. All rights reserved.

## Performance (vs Versify 36.7 MB)

- Zero dependencies, SwiftUI only, offline-first JSON store (<100 KB typical)
- No web views, no media, no analytics SDKs
- Cold start on iPhone SE (3rd gen) simulator: **< 1 s** to interactive Loop; app bundle **< 5 MB** (thin)
- One network call per verse add (cached forever locally); reviews are pure local computation

## Project layout

```
VerseLoop/            native iOS app (iOS 17+, iPhone SE3 supported)
  VerseLoopApp.swift  entry
  Models.swift        Verse, Grade, SM-2 ReviewState, LibraryEnvelope v1
  VerseStore.swift    queue, grading+undo, JSON persistence, export/import, sync
  ESVService.swift    Worker-proxy-first ESV fetch, direct fallback
  ContentView.swift   Loop / Verses / Add / Settings tabs
  ReviewView.swift    first-letter tester + Oops + shake + grading
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

## Worker (optional but recommended, free tier)

```bash
cd worker && npm i
npx wrangler secret put ESV_API_TOKEN   # your api.esv.org key
npm run deploy                          # -> https://verseloop.<you>.workers.dev
```

Paste that URL into the app's **Settings → Worker URL**. Pick any sync code (e.g. `psalm-morning-7`), use the same code on your second device, Push on one / Pull on the other. No KV binding needed to start (in-memory); add the `SYNC_KV` binding in `wrangler.toml` for durable multi-device sync — still free tier.

Endpoints: `GET /health` · `GET /v1/esv?q=John+1:1` · `PUT/GET /v1/sync/:code` (256 KB cap).

## Spaced repetition used

SM-2-lite (Anki-style): Again resets (10-min retry, ease −0.20, lapse+1); Hard (ease −0.15, ×1.2); Good (1d → 3d → ×ease); Easy (ease +0.15, 4d start, ×ease×1.3). Ease floor 1.3. Due = end of day + interval. Only your explicit grade moves the schedule — peek counts are advisory and zeroable via the accidental flag.

## Evidence

`recordings/` (all captured on **iPhone SE (3rd generation)** simulator, iOS 18.5):
- `verseloop-se3.mov` (~7 MB) — full screen recording of the automated UI run below
- `01-loop.png` — Today's Loop with Due/Total/Mastered + due-sorted queue
- `02-review-first-letters.png` — first-letter grid, zero peeks
- `03-review-peeked.png` — two words peeked, Oops enabled
- `04-graded.png` — graded Good → next due tomorrow, Undo window
- `05-settings.png` — ESV key, Worker sync, export/import
- `06-add-verse.png` — Add verse with ESV fetch

`VerseLoopUITests/testLoopFlow` drives the whole pass and **passes** (19.7s on SE3 sim):
Loop → open verse → peek 2 words → Oops-undo (2→1 peeked) → accidental-toggle → Good → Undo grade → re-grade → Next → Settings → Add sheet.
