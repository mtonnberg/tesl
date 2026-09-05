/* Optional experiment: Elm owns state; this adapter owns compiler, clipboard,
   source-link codec and selection. The message envelope is reusable with a worker. */
(async () => {
  "use strict";
  const fallback = "module Sample exposing [answer]\nimport Tesl.Prelude exposing [Int]\nfn answer() -> Int = 42\n";
  const root = document.getElementById("elm-root");
  try {
    if (window.TESL_BUILD?.version !== 1) throw Error("Build manifest version mismatch.");
    await Promise.all(["tesl_playground.js", "tesl_search.js"].map(name => new Promise((resolve, reject) => {
      const script = document.createElement("script"), asset = TESL_BUILD.assets[name];
      script.src = name + "?v=" + asset.sha256; script.integrity = asset.integrity; script.crossOrigin = "anonymous";
      script.onload = resolve; script.onerror = () => reject(Error("Could not load " + name));
      document.head.append(script);
    })));
    if (JSON.parse(teslSearch("String.length")).catalog_id !== TESL_BUILD.catalog_id) throw Error("Catalog version mismatch.");
    const shared = await TeslShare.decode(location.hash.slice(1));
    const app = Elm.Main.init({ node: root, flags: { source: shared?.text || fallback } });
    window.TeslElmSpike = app;
    const timers = new Map();
    app.ports.request.subscribe(message => {
      // Reject malformed requests before invoking any compiler or clipboard API.
      if (message.version !== 1 || !Number.isSafeInteger(message.request_id) || !Number.isSafeInteger(message.source_revision) ||
          !["check", "search", "share"].includes(message.operation) || typeof message.payload !== "string") {
        app.ports.response.send({ ...message, version: 0, payload: { error: "Invalid request envelope." } });
        return;
      }
      clearTimeout(timers.get(message.operation));
      timers.set(message.operation, setTimeout(async () => {
        let payload;
        try {
          if (message.operation === "check") payload = JSON.parse(teslCheck(message.payload));
          if (message.operation === "search") payload = JSON.parse(teslSearch(message.payload));
          if (message.operation === "share") {
            const editor = document.getElementById("spike-source");
            const line = offset => message.payload.slice(0, offset).split("\n").length;
            const pos = editor.selectionEnd > editor.selectionStart ? line(editor.selectionStart) + "-" + line(editor.selectionEnd - 1) : null;
            const highlight = shared?.text === message.payload && shared.highlightFrom ? shared.highlightFrom + "-" + shared.highlightTo : null;
            const fragment = await TeslShare.encode(message.payload, pos, highlight);
            const url = new URL(location.href); url.pathname = url.pathname.replace(/elm-spike\.html$/, "index.html"); url.hash = fragment;
            payload = url.href;
            try { await navigator.clipboard.writeText(payload); } catch (_) { /* Elm shows a copyable URL. */ }
          }
        } catch (error) { payload = { error: error.message }; }
        app.ports.response.send({ ...message, payload });
      }, message.operation === "share" ? 0 : 100));
    });
    if (shared?.from) requestAnimationFrame(() => {
      const editor = document.getElementById("spike-source"), lines = shared.text.split("\n");
      const offset = line => lines.slice(0, line - 1).reduce((n, value) => n + value.length + 1, 0);
      editor.focus(); editor.setSelectionRange(offset(shared.from), offset(shared.to + 1));
    });
  } catch (error) { root.textContent = error.message + " Open the regular playground to continue."; }
})();
