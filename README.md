# Verse Loop Daily

Start the day by memorizing ESV verses word-by-word — from first letters, with the reference tested last.

A native iOS app (SwiftUI, zero dependencies, offline-first) built for one workflow: a single due-sorted **Loop**, one verse at a time, with real spaced repetition behind it. One daily Loop, one tester, one scheduler.

## How a rep feels

The reference stays hidden and no word counts are shown. **Type the first letter** of each word, one at a time — then, without breaking stride, the **reference: book initial, then numbers** (the colon is skipped). `tlimsisnwp231` flows in as one session while the reference composes inline as **Psalm 23:1**, styled just like the words. Multi-verse passages work too (`Psalm 23:1-6` ends `…p2316`, separators appearing on their own).

Right character → it appears. Wrong → a haptic buzz, a red mistake, and you move on. Every mistake carries its own "accidental?" toggle — tap any red word to forgive a fat-finger slip (shaking forgives the latest too). The header shows a **mistake count**, net of forgiven slips, instead of a progress bar. Then you see your mistakes plus a suggested grade, and you grade **Again / Hard / Good / Easy**. Grades get an 8-second Undo. Full dark-mode support throughout.

## What you get

- Single due-sorted **Loop**: one verse at a time
- Wrong letter **buzzes + marks a red mistake** — forgive any as **accidental**
- Every rep ends in **Again / Hard / Good / Easy** → real SM-2 ease + intervals
- **Mistake count** in the header, net of forgiven slips, plus a suggested grade
- **JSON export/import + optional encrypted sync** — same verses on two devices

## Getting it

The app is distributed via **TestFlight** for iPhone (iOS 17+, iPhone SE 3 supported). Install Apple's TestFlight app, accept the invite, and you're in — the two built-in demo verses work with zero setup.

To add real verses, just type a reference like `John 1:1` or `Psalm 23:1-6`. ESV text is fetched automatically through the app's built-in service; nothing to configure on-device.

## Your verses are yours

- **Works offline.** Reviews are pure on-device computation; one network call per verse add, cached forever locally.
- **Backup however you like.** Export/import your library as JSON from Settings, or use the optional sync as encrypted backup. Sync is end-to-end encrypted — the server only ever sees ciphertext it can't read.
- **Tiny and private.** No web views, no media, no analytics SDKs. Cold start to an interactive Loop in under a second; the app bundle is ~1.4 MB.

## ESV, legally

The app is **ESV-only**. ESV text is © Crossway and is never bundled in this repo or the app download — the two demo verses are public-domain KJV so the app works offline out of the box. Real ESV passages arrive at runtime via the ESV API, with the key held server-side.

> Scripture quotations are from the ESV® Bible (The Holy Bible, English Standard Version®), © 2001 by Crossway, a publishing ministry of Good News Publishers. Used by permission via the ESV API. All rights reserved.

## How releases work

Pushing to `main` is all it takes:

- **App → TestFlight** via **Xcode Cloud**, which builds the iPhone app and ships it to testers.
- **Server** via a **GitHub Action** that redeploys the small Cloudflare Worker (ESV proxy + encrypted sync store) automatically.

## For developers and agents

See **[AGENTS.md](AGENTS.md)** for project layout, how to run the simulator and UI tests, and the guardrails (no ESV text in git, zero dependencies, opaque sync, SE3 target).

`recordings/` holds simulator screen recordings and screenshots of the full flow on iPhone SE (3rd generation), dark mode.
