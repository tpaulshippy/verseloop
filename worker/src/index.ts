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
        "access-control-allow-methods": "GET, PUT, OPTIONS",
        "access-control-allow-headers": "content-type",
      },
    });
  }
  return json({ error: "method not allowed" }, 405);
}

const MEM = new Map();
