// Shared source-link codec. Historical #s/#z and .L/.H forms stay compatible.
(() => {
const b64u = {
  enc(bytes) {
    let s = "";
    for (const b of bytes) s += String.fromCharCode(b);
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  },
  dec(str) {
    const s = atob(str.replace(/-/g, "+").replace(/_/g, "/"));
    const out = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
    return out;
  }
};

async function encodeShare(text, pos, highlight) {
  const raw = new TextEncoder().encode(text);
  let payload = null;
  if (typeof CompressionStream === "function") {
    try {
      const cs = new CompressionStream("deflate-raw");
      const w = cs.writable.getWriter();
      w.write(raw); w.close();
      const buf = await new Response(cs.readable).arrayBuffer();
      payload = "z" + b64u.enc(new Uint8Array(buf));
    } catch (e) { /* fall through */ }
  }
  if (payload === null) payload = "s" + b64u.enc(raw);
  if (pos) payload += ".L" + pos;
  if (highlight) payload += ".H" + highlight;
  return payload;
}

// → { text, from, to, highlightFrom, highlightTo } | null.
// `from`/`to` are 1-based line numbers or null (for caret/selection).
// `highlightFrom`/`highlightTo` are 1-based line numbers or null (for line highlighting).
async function decodeShare(frag) {
  if (!frag) return null;
  // Match the base payload and optional .L and .H sections
  // The regex matches: kind, body, then optionally .Lstart-end and/or .Hstart-end
  const m = /^([sz])([A-Za-z0-9_-]*)(?:\.L(\d+)(?:-(\d+))?)?(?:\.H(\d+)(?:-(\d+))?)?$/.exec(frag);
  if (!m) return null;
  const [, kind, body, a, b, h1, h2] = m;
  const pos = a ? { from: Number(a), to: b ? Number(b) : Number(a) } : { from: null, to: null };
  const highlight = h1 ? { highlightFrom: Number(h1), highlightTo: h2 ? Number(h2) : Number(h1) } : { highlightFrom: null, highlightTo: null };
  try {
    if (kind === "s") return { text: new TextDecoder().decode(b64u.dec(body)), ...pos, ...highlight };
    const ds = new DecompressionStream("deflate-raw");
    const w = ds.writable.getWriter();
    w.write(b64u.dec(body)); w.close();
    const buf = await new Response(ds.readable).arrayBuffer();
    return { text: new TextDecoder().decode(new Uint8Array(buf)), ...pos, ...highlight };
  } catch (e) { return null; }
}

window.TeslShare = { encode: encodeShare, decode: decodeShare };
})();
