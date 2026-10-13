# How Verse Loop Daily Was Built — Prompt Log

A step-by-step record of the prompts used to build this app with an AI
coding agent, with real timestamps from git history so the video can use
realistic timeframes. Early prompts are quoted verbatim from the session;
later ones are reconstructed from what each commit changed. Durations are
approximate wall-clock between pushes.

Total: ~36 commits, Oct 9 → Oct 12. App: native iOS (SwiftUI, zero
dependencies) + Cloudflare Worker. Current state: in TestFlight as
**Verse Loop Daily**, heading to the App Store.

---

## Act 1 — The brief (Oct 9, ~11:00 PM, ~10 min)

**Prompt 1 — the goal + constraints (verbatim):**
> Goal — Build a native ios app that replaces a major workflow of one of my
> top most used apps [screenshot of iOS Screen Time: Signal 1h33m, X 1h10m,
> Spotify 1h8m, …] with an innovative user experience that is fun but also
> productive and smart.
> Finish condition — I have an app that I will want to use built for me and
> distributable to my iPhone se3.
> Evidence — A new public github that describes the app and contains the full
> source code along with screen recordings of the app running in simulator.
> Constraints — must not clone; must be better performing; server (if any)
> runnable on a free cloudflare worker; must not fully replace the existing
> app, just enable a major workflow in a new way. Build in a subfolder. Go.

Result: agent built a Spotify "dice DJ" concept first. Verdict: hated it.

**Prompt 2 — "Hate it. Pitch me your next 10 ideas."**
Result: 10 pitches, one per top-used app (Signal nudge-buttons, X 3-minute
brief, NYT Games coach, TradingView tiles, OpenCode Pocket Ops, …).

**Prompt 3 — picking #8 (verbatim, lightly trimmed):**
> I like 8. Currently I start my day using Versify for this but there are
> weaknesses — no real spaced repetition from my feedback; first-letter
> testing punishes accidental taps with no recourse; everything is
> device-local, no sync or export. I definitely need ESV — I only memorize
> that. Go do the finish condition, evidence, and constraints with this
> idea as the goal.

**Commit `484a75d` — Oct 9, 23:13 — "VerseLoop 1.0" (~25 min build)**
Native SwiftUI app + Worker scaffold, ESV-via-API (never bundled, Crossway
copyright), SM-2 scheduler, JSON export, simulator screenshots + screen
recording, public repo live.

---

## Act 2 — The tester, rebuilt twice (Oct 10, 09:11 → ~15:40)

Morning iteration burst, each round: prompt → build → UI-test on iPhone SE
simulator (screenshots + video) → push.

- **09:11** — "Type-the-first-letter tester": tappable first-letter chips
  became a real typing interface — type each initial, right reveals the
  word, wrong buzzes + red mistake + per-mistake "accidental?" forgiveness,
  mistake count, dark mode.
- **~09:30** — "Reference-last": hide the reference during the pass, test it
  last as book initial + digits (`P231`), no word counts anywhere.
- **Reference fixes** — "It should say Psalm 23:1 after I type P231":
  seamless single stream (`tlimsisnwp231`), reference composes inline like
  the words; then "remove the extra display" (no duplicate title) and
  "style it white" (which forced dropping disabled-Button dimming).
- **Ranges** — "Do we support multi verse passages?" Fetching ranges
  already worked; typing got stuck on `-`. Fix: separators auto-appear,
  `Psalm 23:1-2` composes with colon + dash. New `testRangeFlow`.
- Tightening rounds: invisible capture field (keyboard is the UI),
  icon-only Show/Restart buttons, tap-anywhere refocus, Loop rows hide
  verse text (recall aid), auto-scroll follow on long passages
  (`testLongFlow`, 71 words), "Today's Loop" → "Today's Verses" tabs.

## Act 3 — Grading honesty (Oct 10, ~20:11 → 20:41)

- **"Why is the top item not showing as due?"** — diagnosis from the
  screenshot (`E2.30` = one Again): Again retries in ~10 min with interval 0,
  and the badge printed the raw counter ("in 0d"). Fix: badges speak real
  relative time (`in 9 min`, `tomorrow`).
- **"What is the threshold for suggesting Again?"** — it was unreachable
  (capped at Hard). First 0/2/5-count bands with Again at 6+, then
  **percentage-based**: 0% Easy, ≤10% Good, ≤25% Hard, above → Again.

## Act 4 — TestFlight (Oct 10, 09:46 → ~14:00, interleaved)

- "Easiest is just TestFlight, right? Set that up?" → app icons, bundle ID
  `com.tpaulshippy.verseloop`, export config, archive script.
- "What if I give you my Apple ID? Do you have computer use?" → no: 2FA
  blocks it, and there's no screen control — only terminal. Scoped path
  instead: App Store Connect API key (`~/AuthKey_*.p8`).
- Agreement wall (`REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED`) → accepted in
  App Store Connect → API green → app record created → distribution cert
  minted via API → profile → archive → **build 2 uploaded, UPLOAD
  SUCCEEDED**. Fixed two validation errors on the way (iPad icons,
  iPhone-only target).

## Act 5 — Server + sync (Oct 10, 15:49 → evening)

- "Where is my server hosted? What is the URL?" → it wasn't — Worker
  existed only as source. Then: "Set up a github action to deploy the
  server on pushes to main" → `deploy-worker.yml` (Ubuntu, wrangler,
  three repo secrets), live at `verseloop.pshippy-245.workers.dev`
  with the ESV key server-side.
- "Is the server single or multi tenant?" → single shared deployment,
  code-partitioned snapshots. "Yeah secure it" → AES-GCM envelopes
  (server sees ciphertext only), auto-generated codes.
- "Cleanup settings" → ESV key, Worker URL, and sync code all removed from
  UI (baked in / generated silently). "Single device + JSON export is
  fine" → documented as the design.
- Sync hardening (evening): `updatedAt` newer-wins merge, tombstone
  deletes, debounced auto-sync + launch pull, read-modify-write push.

## Act 6 — Ship prep (Oct 10, 21:25 → Oct 12, 05:31)

- App Store submit prep: privacy manifest, in-app privacy + Delete All My
  Data, worker `/privacy` + `/support` + DELETE sync, store metadata,
  6.9″ screenshots, **build 3**. Renamed **Verse Loop Daily**.
- Practice flow: Next advances to the next due verse, next-verse preview
  modal, fresh ReviewView per verse (no state leaks), due-reminder taps
  deep-link into practice, configurable suggestion bands, review
  reminders (due + daily time).
- Housekeeping: pasted-JSON import, AGENTS.md split, README humanized,
  fresh 68s demo video.

---

## The pattern (for the video)

Every loop looked the same: **screenshot or one-line prompt → agent
investigates live → fix + UI-test proof (screenshots/video) → push to
main → (TestFlight/Xcode Cloud or Worker deploy picks it up)**. Nothing
merged without a green simulator run attached.
