# AGENTS.md — instructions for coding agents

This repo is **Verse Loop Daily**: a native iOS app (SwiftUI, zero dependencies) + a Cloudflare Worker backend. Read this file before changing code. `README.md` is the human description; this file is the operating manual.

## Repo map

```
VerseLoop/              native iOS app (iOS 17+, iPhone SE 3 supported)
  VerseLoopApp.swift    entry
  Models.swift          Verse, Grade, SM-2 ReviewState, LibraryEnvelope v1
  VerseStore.swift      queue, grading + undo, JSON persistence, export/import, sync
  ESVService.swift      Worker-proxy-first ESV fetch, direct fallback
  ContentView.swift     Loop / Verses / Add / Settings tabs
  ReviewView.swift      first-letter tester + mistakes + per-word forgive + grading
VerseLoopUITests/       UI tests (testLoopFlow, testRangeFlow, testLongFlow)
worker/                 Cloudflare Worker: ESV proxy + sync store (free tier)
  src/index.ts          all routes; KV optional, in-memory fallback
  wrangler.toml         Worker config (no secrets committed)
ci_scripts/             Xcode Cloud scripts (run in the cloud, not locally)
  ci_pre_xcodebuild.sh  stamps CURRENT_PROJECT_VERSION from CI_BUILD_NUMBER
scripts/                local helpers: run-sim.sh, archive-testflight.sh, screenshots
recordings/             simulator evidence (.mov + .png, SE3 sim, dark mode)
appstore/               store metadata, privacy policy, support page
.github/workflows/      CI dispatch (see below — not the build itself)
```

## Build / test locally

```bash
# Build + install + launch on the iPhone SE (3rd gen) simulator:
./scripts/run-sim.sh

# UI tests (must pass on the SE3 sim before submitting app changes):
xcodebuild test -project VerseLoop.xcodeproj -scheme VerseLoop \
  -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' \
  CODE_SIGNING_ALLOWED=NO -only-testing:VerseLoopUITests
```

- No signing team needed for simulator (`CODE_SIGNING_ALLOWED=NO`).
- Physical device / archive requires Xcode automatic signing with the owner's Apple ID team — agents should not attempt this; leave it to humans / Xcode Cloud.
- Worker: `cd worker && npm i && npx wrangler dev`. Deploy is CI-only (see below).

## CI/CD — the split you must respect

**Frontend (iOS app) builds in Xcode Cloud. Backend (Worker) deploys via GitHub Actions. Neither builds in Actions directly.**

- Frontend: `.github/workflows/trigger-xcodecloud.yml` — on push/PR to `main` touching `VerseLoop/**`, `VerseLoop.xcodeproj/**`, `VerseLoopUITests/**`, `ci_scripts/**`, `scripts/**`, it dispatches the Xcode Cloud workflow via App Store Connect API (secrets: `ASC_ISSUER_ID`, `ASC_KEY_ID`, `ASC_PRIVATE_KEY`, `XCODE_CLOUD_WORKFLOW_ID`). The Xcode Cloud workflow itself must stay on **Manual/off** start conditions (with a dummy "any branch" condition, which Xcode requires) — the GitHub workflow is the real gate.
- Backend: `.github/workflows/deploy-worker.yml` — on push to `main` touching `worker/**`, it runs `npm ci`, re-puts the `ESV_API_TOKEN` secret server-side, and `wrangler deploy`. Requires secrets: `ESV_API_TOKEN`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`.
- `ci_scripts/ci_pre_xcodebuild.sh` stamps a unique `CURRENT_PROJECT_VERSION` from `CI_BUILD_NUMBER` on every cloud build (Apple rejects re-uploaded build numbers). **Do not bump build numbers by hand** for cloud builds; only bump manually for local `archive-testflight.sh` uploads.

Path filters are load-bearing: app-only changes must not trigger worker deploys and vice versa. Keep new files under the existing filter roots, or update both workflow `paths:` lists.

## Guardrails

1. **Zero dependencies, SwiftUI only.** Do not add packages, web views, media, or analytics SDKs. Offline-first; reviews are pure local computation.
2. **ESV text is never committed.** ESV © Crossway — no ESV passages in code, seeds, tests, or fixtures. The app ships with two short public-domain KJV demo verses so the simulator works offline; real ESV text is fetched at runtime through the Worker. Test fixtures must use KJV/short invented strings only.
3. **No secrets in git.** `ESV_API_TOKEN` lives as a repo secret + Wrangler secret, never in `wrangler.toml` or code. No API key on-device.
4. **Sync is opaque.** Libraries are AES-GCM encrypted client-side (key from sync code via HKDF-SHA256); the Worker only stores ciphertext, capped at 256 KB. Endpoints: `GET /health`, `GET /v1/esv?q=`, `PUT/GET /v1/sync/:code`. KV binding `SYNC_KV` is optional (free tier); code must keep working without it.
5. **Tester behavior is the product.** Reference stays hidden, no word counts. Input is first letters flowing as one session, reference composed inline last (book initial, then numbers; colon/dash separators appear on their own). Wrong letter → haptic + red mistake, move on; every mistake has an "accidental?" forgive toggle; grades (Again/Hard/Good/Easy) drive real SM-2 (ease floor 1.3) with an 8-second Undo. Do not add progress bars, scoring games, or multi-translation UI without explicit instruction.
6. **Target the SE3.** iOS 17.0 deployment target, iPhone SE (3rd gen) supported. Verify layouts in dark mode; evidence in `recordings/` is SE3-sim dark-mode captures.
