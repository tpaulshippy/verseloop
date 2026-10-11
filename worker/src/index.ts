// VerseLoop Worker — free-tier Cloudflare Worker.
// Two jobs: (1) ESV passage proxy w/ cache (keeps API key server-side),
// (2) tiny sync store for library JSON (KV when bound, memory otherwise).
// Sync payloads are end-to-end encrypted by the app (AES-GCM, key derived
// from the user's sync code): this worker only ever sees opaque v2
// ciphertext and cannot read verses, reviews, or schedules.
//
// Free-tier notes: Cache API + subrequests are free. KV is optional —
// if no KV binding exists we fall back to in-memory (single isolate).
// Payloads capped at 256KB.

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (request.method === "GET" && (path === "/" || path === "/health")) {
      return json({ ok: true, service: "verseloop", ts: new Date().toISOString() });
    }

    if (request.method === "GET" && path === "/privacy") {
      return html(PRIVACY_HTML);
    }

    if (request.method === "GET" && path === "/support") {
      return html(SUPPORT_HTML);
    }

    if (path === "/v1/esv") {
      return handleESV(request, env, url);
    }

    const m = path.match(/^\/v1\/sync\/([A-Za-z0-9_-]{1,64})$/);
    if (m) {
      return handleSync(request, env, m[1]);
    }

    return json({ error: "not found" }, 404);
  },
};

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      "content-type": "application/json",
      "access-control-allow-origin": "*",
      "cache-control": "no-store",
    },
  });
}

function html(body, status = 200) {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "public, max-age=3600",
    },
  });
}

// ---- ESV proxy -------------------------------------------------------
async function handleESV(request, env, url) {
  const q = (url.searchParams.get("q") || "").trim();
  if (!q) return json({ error: "missing ?q= reference" }, 400);
  const token = env.ESV_API_TOKEN;
  if (!token) return json({ error: "server missing ESV_API_TOKEN secret" }, 500);

  const cache = caches.default;
  const cacheKey = new Request(`https://verseloop/esv?q=${encodeURIComponent(q)}`);
  const cached = await cache.match(cacheKey);
  if (cached) return cached;

  const api = new URL("https://api.esv.org/v3/passage/text/");
  api.searchParams.set("q", q);
  api.searchParams.set("include-footnotes", "false");
  api.searchParams.set("include-verse-numbers", "false");
  api.searchParams.set("include-short-copyright", "false");
  api.searchParams.set("include-passage-references", "false");
  api.searchParams.set("include-headings", "false");

  const r = await fetch(api.toString(), { headers: { Authorization: `Token ${token}` } });
  if (!r.ok) return json({ error: `esv api ${r.status}` }, 502);
  const data = await r.json();
  const text = (data.passages || []).join("\n").trim();
  if (!text) return json({ error: "empty passage" }, 404);

  const resp = json({ text });
  resp.headers.set("cache-control", "public, max-age=86400");
  // Cache a clone; Cache API requires GET. Store for 24h.
  await cache.put(cacheKey, resp.clone());
  return resp;
}

// ---- Sync store ------------------------------------------------------
async function handleSync(request, env, code) {
  const key = `verseloop:${code}`;
  if (request.method === "DELETE") {
    if (env.SYNC_KV) {
      await env.SYNC_KV.delete(key);
    } else {
      MEM.delete(key);
    }
    return json({ ok: true, deleted: true });
  }
  if (request.method === "PUT") {
    const body = await request.text();
    if (body.length > 256 * 1024) return json({ error: "payload > 256KB" }, 413);
    // Validate envelope shape lightly. v2 is opaque ciphertext (end-to-end
    // encrypted); the server never sees verses. v1 plaintext still accepted
    // for old snapshots.
    try {
      const p = JSON.parse(body);
      if (p.version === 2) {
        if (typeof p.ciphertext !== "string" || p.ciphertext.length === 0) {
          return json({ error: "bad v2 envelope" }, 400);
        }
      } else if (!Array.isArray(p.verses) || !Array.isArray(p.reviews)) {
        return json({ error: "bad envelope" }, 400);
      }
    } catch {
      return json({ error: "invalid json" }, 400);
    }
    if (env.SYNC_KV) {
      await env.SYNC_KV.put(key, body);
    } else {
      MEM.set(key, body);
    }
    return json({ ok: true });
  }
  if (request.method === "GET") {
    let body = null;
    if (env.SYNC_KV) {
      body = await env.SYNC_KV.get(key);
    } else {
      body = MEM.get(key) || null;
    }
    if (!body) return json({ error: "no snapshot for this code yet (push first)" }, 404);
    return new Response(body, {
      headers: { "content-type": "application/json", "access-control-allow-origin": "*" },
    });
  }
  if (request.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "access-control-allow-origin": "*",
        "access-control-allow-methods": "GET, PUT, DELETE, OPTIONS",
        "access-control-allow-headers": "content-type",
      },
    });
  }
  return json({ error: "method not allowed" }, 405);
}

const MEM = new Map();

// ---- Public pages (App Store Connect: Privacy Policy URL + Support URL) --
// Canonical sources live in appstore/privacy-policy.html and appstore/support.html;
// these inline copies are what the Worker serves so the URLs stay live.

const PRIVACY_HTML = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Verse Loop Daily — Privacy Policy</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;max-width:44rem;margin:2rem auto;padding:0 1rem;line-height:1.6;color:#111}h1{font-size:1.6rem}h2{font-size:1.15rem;margin-top:1.8rem}.muted{color:#666;font-size:.9rem}ul{padding-left:1.3rem}</style>
</head><body>
<h1>Verse Loop Daily — Privacy Policy</h1>
<p class="muted">Effective: October 11, 2026 · Verse Loop Daily v1.0 (iOS) · Bundle com.tpaulshippy.verseloop</p>
<p>Verse Loop Daily helps you memorize English Standard Version (ESV) Bible verses with spaced repetition. There are <strong>no accounts, no analytics, no ads, no third-party SDKs, and no tracking</strong>.</p>
<h2>Summary: data not collected</h2>
<p>We do not collect, sell, or share personal data. Your verses and review history stay on your device unless you turn on the optional encrypted backup — which we cannot read (see below).</p>
<h2>What is stored, and where</h2>
<ul>
<li><strong>On your device only (by default):</strong> the verse references and texts you add, your SM-2 review schedule (ease, intervals, due dates), grades, mistake counts, and app settings (auto-sync preference). Stored in the app's local JSON file and UserDefaults. Deleted when you delete the app or use <em>Settings → Delete All My Data</em>.</li>
<li><strong>Optional encrypted cloud backup:</strong> if auto-sync/backup runs, the app encrypts your full library on-device with AES-GCM (key derived from your random sync code via HKDF-SHA256) and uploads only the opaque ciphertext to our Cloudflare Worker. The server never sees verse text, references, or schedules and has no way to decrypt them.</li>
<li><strong>ESV passage fetch:</strong> when you tap "Fetch ESV text", the app sends only the Bible reference you typed (e.g. "John 1:1") to our Worker, which forwards it to api.esv.org and returns the passage text. No identifiers are attached; responses are cached 24h to stay inside ESV quotas.</li>
</ul>
<h2>What we do NOT collect</h2>
<ul>
<li>No name, email, contacts, location, photos, identifiers for advertising, usage analytics, diagnostics, crash SDKs, or health data.</li>
<li>No tracking across apps or websites.</li>
</ul>
<h2>Third parties</h2>
<ul>
<li><strong>Cloudflare (hosting):</strong> serves the Worker proxy/backup. It necessarily sees network metadata (IP address, TLS) per Cloudflare's privacy policy, but verse content is end-to-end encrypted ciphertext it cannot read.</li>
<li><strong>Crossway / api.esv.org (scripture):</strong> receives only the passage reference you request, to return ESV text under Crossway's terms.</li>
<li>No analytics, ad networks, or other SDKs. Any future third party would be listed here and must provide equal or greater protection.</li>
</ul>
<h2>Data retention and deletion</h2>
<ul>
<li>On-device data is kept until you delete it. Cloud ciphertext snapshots persist until overwritten by a newer push or deleted.</li>
<li><strong>In-app deletion (full equivalent of account deletion — there are no accounts):</strong> <em>Settings → Delete All My Data → Delete everything</em> removes all verses, reviews, and history on the device, deletes the encrypted cloud backup for that sync code, and rotates the sync code so the old bucket can never be re-linked.</li>
<li><strong>Revoke consent / stop backup:</strong> turn off <em>Settings → Auto-sync after changes</em> to stop all uploads; use <em>Export</em> first if you want a copy of your data.</li>
<li>Deleting the iOS app removes on-device data; run Delete All My Data first if you also want the cloud ciphertext erased.</li>
</ul>
<h2>Data portability</h2>
<p><em>Settings → Prepare JSON export</em> gives you your full library (verses + schedule + tombstones, v2 JSON) at any time.</p>
<h2>Children</h2>
<p>Verse Loop Daily collects no personal data from anyone, including children, and is rated 4+.</p>
<h2>Contact / data requests</h2>
<p>Questions or deletion help: see <a href="/support">Support</a> or open an issue at <a href="https://github.com/tpaulshippy/verseloop/issues">github.com/tpaulshippy/verseloop/issues</a>.</p>
<h2>Changes</h2>
<p>If this policy changes materially we will update this page and note it in the app release notes.</p>
<p class="muted">Scripture quotations are from the ESV Bible (The Holy Bible, English Standard Version), © 2001 by Crossway. Used by permission via the ESV API. All rights reserved.</p>
</body></html>`;

const SUPPORT_HTML = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Verse Loop Daily — Support</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;max-width:44rem;margin:2rem auto;padding:0 1rem;line-height:1.6;color:#111}h1{font-size:1.6rem}h2{font-size:1.15rem;margin-top:1.8rem}.muted{color:#666;font-size:.9rem}code{background:#f2f2f2;padding:.1rem .3rem;border-radius:.3rem}ol,ul{padding-left:1.3rem}</style>
</head><body>
<h1>Verse Loop Daily — Support</h1>
<p class="muted">Verse Loop Daily v1.0 for iPhone (iOS 17+) · ESV-only memorization with real spaced repetition.</p>
<h2>Quick start</h2>
<ol>
<li>Open <strong>Verses → +</strong>, type a reference (e.g. <code>John 1:1</code> or <code>Psalm 23:1-6</code>), tap <strong>Fetch ESV text</strong>, then Save.</li>
<li>Open <strong>Today</strong>, tap a due verse, and type the first letter of each word — then the book initial and numbers for the reference.</li>
<li>Grade yourself: Again / Hard / Good / Easy. That grade drives the SM-2 schedule. Every grade has an 8-second Undo.</li>
</ol>
<h2>Backup, export, and moving devices</h2>
<ul>
<li><strong>Encrypted backup:</strong> Settings → Synchronize Backup pushes an end-to-end encrypted snapshot. Auto-sync after changes is on by default.</li>
<li><strong>Moving to a new phone:</strong> Settings → Prepare JSON export → Share, then Import JSON on the new device.</li>
</ul>
<h2 id="delete-my-data">Delete My Data</h2>
<p>There are <strong>no accounts</strong> — deleting your data is one tap and needs no email:</p>
<ol>
<li>In the app: <strong>Settings → Delete All My Data → Delete everything</strong>.</li>
<li>This erases all verses, reviews, and history on the device, deletes the encrypted cloud backup for your sync code, and rotates the code.</li>
<li>To stop future uploads without deleting: turn off <em>Auto-sync after changes</em>.</li>
</ol>
<h2>ESV &amp; offline</h2>
<p>The app ships with two public-domain KJV demo verses so it works offline. Real ESV text is fetched at runtime and cached on-device. ESV text © Crossway.</p>
<h2>Contact</h2>
<ul>
<li><strong>Issues / feature requests:</strong> <a href="https://github.com/tpaulshippy/verseloop/issues">github.com/tpaulshippy/verseloop/issues</a></li>
<li><strong>Privacy:</strong> <a href="/privacy">Privacy Policy</a></li>
<li><strong>Health endpoint:</strong> <a href="/health">/health</a></li>
</ul>
<p class="muted">Include your app version (Settings → About), iOS version, and steps to reproduce — never send your full sync code publicly.</p>
</body></html>`;
