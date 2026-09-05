/* Browser effects only. Elm owns application state and rendering; compiler
   parsing, ranking and diagnostics remain in the shared OCaml implementation. */
(async () => {
  "use strict";
  const assets = new Map();
  function build() {
    const value = window.TESL_BUILD;
    if (!value || value.version !== 1 || typeof value.catalog_id !== "string") {
      throw Error("This page and its build manifest do not match. Save your source, then reload the page.");
    }
    return value;
  }
  function assetURL(name) {
    const asset = build().assets[name];
    if (!asset || !/^sha256-[A-Za-z0-9+/]+=*$/.test(asset.integrity)) throw Error("Missing asset identity: " + name);
    return { url: name + "?v=" + asset.sha256, integrity: asset.integrity };
  }
  function loadScript(name) {
    if (!assets.has(name)) {
      const promise = new Promise((resolve, reject) => {
        const asset = assetURL(name);
        const script = document.createElement("script");
        script.src = asset.url;
        script.integrity = asset.integrity;
        script.crossOrigin = "anonymous";
        const timer = setTimeout(() => { script.remove(); reject(Error("Loading timed out: " + name)); }, 20000);
        script.onload = () => { clearTimeout(timer); resolve(); };
        script.onerror = () => { clearTimeout(timer); script.remove(); reject(Error("Could not load a matching " + name + ". Check your connection or deployment, then retry.")); };
        document.head.append(script);
      }).catch(error => { assets.delete(name); throw error; });
      assets.set(name, promise);
    }
    return assets.get(name);
  }

  function loadStyle(name) {
    if (!assets.has(name)) {
      assets.set(name, new Promise((resolve, reject) => {
        const asset = assetURL(name), link = document.createElement("link");
        link.rel = "stylesheet"; link.href = asset.url; link.integrity = asset.integrity; link.crossOrigin = "anonymous";
        const timer = setTimeout(() => { link.remove(); reject(Error("Loading timed out: " + name)); }, 20000);
        link.onload = () => { clearTimeout(timer); resolve(); };
        link.onerror = () => { clearTimeout(timer); link.remove(); reject(Error("Could not load " + name + ". Retry IDE editor.")); };
        document.head.append(link);
      }).catch(error => { assets.delete(name); throw error; }));
    }
    return assets.get(name);
  }
  let examplesPromise = null;
  async function loadSearch() {
    await loadScript("tesl_search.js");
    if (typeof window.teslSearch !== "function") throw Error("Search export is missing.");
    const probe = JSON.parse(window.teslSearch("String.length"));
    if (probe.version !== 1 || probe.catalog_id !== build().catalog_id) {
      throw Error("Search catalog and checker build do not match. Save your source, then reload the page.");
    }
    if (!examplesPromise) {
      examplesPromise = (async () => {
        const asset = assetURL("search-examples.json");
        const response = await fetch(asset.url, { integrity: asset.integrity });
        if (!response.ok) throw Error("Could not load checked examples.");
        const data = await response.json();
        if (data.version !== 1 || data.catalog_id !== build().catalog_id || !Array.isArray(data.examples)) {
          throw Error("Examples and search catalog do not match.");
        }
        return data.examples;
      })().catch(error => { examplesPromise = null; throw error; });
    }
    return examplesPromise;
  }

function substantive(kind, text) {
  if (!text) return false;
  let t = text.replace(/\{-[\s\S]*?-\}/g, "");      // elm block comment (banner)
  const drop = {
    ts:  l => /^\s*(\/\/|\/\*|\*)/.test(l) || /^\s*import\b/.test(l) || /^\s*(export\s+)?type\s*\{/.test(l),
    elm: l => /^\s*--/.test(l) || /^\s*module\b/.test(l) || /^\s*import\b/.test(l),
  }[kind];
  return t.split("\n").some(l => l.trim() !== "" && !drop(l));
}


  // Observation hook only: no network, cookies, storage or user content.
  // A future consent-aware adapter may subscribe to these aggregate milestones.
  const milestone = name => window.dispatchEvent(new CustomEvent("tesl:adoption", { detail: { version: 1, event: name } }));
  const byId = id => document.getElementById(id);
  const timers = new Map(), newest = new Map();
  const shared = await TeslShare.decode(location.hash.slice(1));
  let theme = "system", introHidden = false;
  try { introHidden = localStorage.getItem("tesl-playground-intro-hidden") === "true"; } catch (_) {}
  try { theme = localStorage.getItem("tesl-playground-theme") || theme; } catch (_) { /* private mode */ }
  if (!["system", "light", "dark"].includes(theme)) theme = "system";
  const linkedQuery = new URL(location.href).searchParams.get("q");
  const progressKey = "tesl-playground-stars-v1";
  const exerciseIds = [0, 1, 2, 4, 5, 6];
  const starPrefix = "tesl-playground-star-v2:";
  const progressFormat = "tesl-playground-progress-format";
  const validStars = value => Array.isArray(value) ? exerciseIds.filter(id => value.includes(id)) : [];
  let journeyDone = [];
  try { journeyDone = validStars(JSON.parse(localStorage.getItem(progressKey))); } catch (_) {}
  try {
    // One key per earned star prevents tabs from replacing each other's awards.
    // Import existing stars once; keep the old array as a compatibility snapshot.
    if (localStorage.getItem(progressFormat) !== "2") {
      journeyDone.forEach(id => localStorage.setItem(starPrefix + id, "1"));
      localStorage.setItem(progressFormat, "2");
    }
    journeyDone = exerciseIds.filter(id => localStorage.getItem(starPrefix + id) === "1");
  } catch (_) { /* unavailable storage: keep the session's progress */ }
  const guideLinks = {
    api: [0, "hello-server"], compiler: [1, "missing-import"],
    workspace: [2, "workspace-invoice-unchecked"], capabilities: [4, "capability-chain"],
    money: [5, "money-check"], dimensions: [6, "units-check"], runtime: [3, "hello-server"]
  };
  const guide = shared ? null : guideLinks[new URL(location.href).searchParams.get("guide")];
  const guideExample = guide ? TESL_EXAMPLES.findIndex(example => example.id === guide[1]) : -1;
  const initialExample = guideExample >= 0 ? guideExample : TESL_DEFAULT_EXAMPLE;
  const identity = window.TESL_BUILD;
  const app = Elm.Main.init({ node: byId("app"), flags: {
    source: shared ? shared.text : TESL_EXAMPLES[initialExample].src, examples: TESL_EXAMPLES, defaultExample: initialExample,
    theme, introHidden, journeyDone, guideStep: guideExample >= 0 ? guide[0] : null, query: linkedQuery || "", linkedQuery: linkedQuery !== null, shared: shared !== null,
    highlight: shared?.highlightFrom ? { from: shared.highlightFrom, to: shared.highlightTo } : null,
    identity: identity ? `Source ${identity.source_revision.slice(0, 12)}${identity.source_dirty ? " + local changes" : ""} · catalog ${identity.catalog_id.slice(0, 12)}` : "Build identity unavailable"
  } });
  // Public port surface also lets the browser contract tests inject late replies.
  window.TeslPlayground = app;
  const syncProgress = () => {
    try {
      journeyDone = exerciseIds.filter(id => localStorage.getItem(starPrefix + id) === "1");
      localStorage.setItem(progressKey, JSON.stringify(journeyDone));
    } catch (_) {}
    const snapshot = journeyDone.slice();
    queueMicrotask(() => app.ports.progress.send(snapshot));
  };
  window.addEventListener("storage", event => {
    if (event.key === null || event.key.startsWith(starPrefix)) syncProgress();
  });
  const frame = callback => requestAnimationFrame(() => requestAnimationFrame(callback));
  const cancel = operation => { clearTimeout(timers.get(operation)); newest.delete(operation); };
  const isCurrent = message => newest.get(message.operation) === message.request_id;
  const reply = (message, payload, error = null) => {
    if (isCurrent(message)) app.ports.response.send({ ...message, payload, error });
  };
  app.ports.request.subscribe(message => {
    if (message.version !== 1 || !Number.isSafeInteger(message.request_id) || !Number.isSafeInteger(message.source_revision) ||
        !( ["check", "search", "share", "fix", "copy", "editor", "learn"].includes(message.operation) || message.operation.startsWith("explain:"))) {
      app.ports.response.send({ ...message, version: 0, error: "Invalid request envelope.", payload: null }); return;
    }
    cancel(message.operation); newest.set(message.operation, message.request_id);
    timers.set(message.operation, setTimeout(async () => {
      try {
        const p = message.payload;
        if (message.operation === "check") {
          await loadScript("tesl_playground.js");
          if (!isCurrent(message)) return;
          const start = performance.now(), result = JSON.parse(teslCheck(p.source));
          result.timing = (performance.now() - start).toFixed(1) + " ms";
          result.artifacts = [["ts", "TypeScript(Zod)"], ["elm", "Elm"]].filter(([kind]) => substantive(kind, result[kind]))
            .map(([kind, label]) => ({ kind, label, content: result[kind] }));
          if (Array.isArray(result.go_files) && result.go_files.length) {
            const files = result.go_files.slice().sort((a, b) => {
              const priority = file => file.path.endsWith('.go') && /internal\/teslmod[^/]+\//.test(file.path) ? 0 : file.path === 'cmd/app/main.go' ? 1 : 2;
              return priority(a) - priority(b) || a.path.localeCompare(b.path);
            });
            result.artifacts.push({ kind: "go", label: "Go project", content: "", files });
          }
          reply(message, result);
        } else if (message.operation === "learn") {
          reply(message, TeslLearning.explain(p, document.querySelector("tesl-editor").selection()));
        } else if (message.operation === "search") {
          const examples = await loadSearch();
          if (!isCurrent(message)) return;
          const result = JSON.parse(teslSearch(p.trim()));
          if (result.version !== 1 || result.catalog_id !== build().catalog_id) throw Error("Search catalog and checker build do not match.");
          result.examples = examples; result.explanation = null;
          if (/^[A-Z][0-9]{3}$/.test(p.trim())) {
            await loadScript("tesl_playground.js");
            if (!isCurrent(message)) return;
            result.explanation = teslExplain(p.trim()) || null;
          }
          reply(message, result);
        } else if (message.operation === "editor") {
          if (p) {
            await loadStyle("monaco.css");
            await loadScript("monaco.js");
          }
          if (!isCurrent(message)) return;
          document.querySelector("tesl-editor").setMode(p, async query => {
            await loadSearch(); return JSON.parse(teslSearch(query));
          });
          reply(message, p);
        } else if (message.operation === "fix") {
          reply(message, TeslApplyFix(p.source, p.fix));
        } else if (message.operation.startsWith("explain:")) {
          await loadScript("tesl_playground.js");
          reply(message, teslExplain(p) || `No stored explanation for ${p}.`);
        } else if (message.operation === "share") {
          const src = byId("src");
          const line = offset => p.source.slice(0, offset).split("\n").length;
          const selected = document.querySelector("tesl-editor").selection();
          const selection = selected.end > selected.start ? line(selected.start) + "-" + line(selected.end - 1) : null;
          const highlight = p.highlight ? p.highlight.from + "-" + p.highlight.to : null;
          const fragment = await TeslShare.encode(p.source, selection, highlight);
          if (!isCurrent(message) || src.value !== p.source) return;
          const url = new URL(location.href); url.hash = fragment;
          history.replaceState(null, "", url);
          let status = "Copied!";
          try { await navigator.clipboard.writeText(url.href); } catch (_) { status = "URL updated — copy from the address bar"; }
          if (status === "Copied!") milestone("source_share_copied");
          reply(message, status);
        } else if (message.operation === "copy") {
          let value = p.text, status = p.message;
          if (typeof p.query === "string") {
            const url = new URL(location.href); url.searchParams.set("q", p.query);
            value = url.href; status = "Search link copied. The current source fragment is preserved.";
          }
          let fallback = "";
          try { await navigator.clipboard.writeText(value); } catch (_) { fallback = value; status = "Select and copy the text below."; }
          if (fallback === "" && typeof p.query === "string") milestone("search_share_copied");
          reply(message, { message: status, fallback });
        }
      } catch (error) { reply(message, null, error.message || String(error)); }
    }, message.operation === "check" ? (message.payload.immediate ? 0 : 300) : message.operation === "search" ? 100 : 0));
  });
  app.ports.ui.subscribe(({ operation, payload }) => {
    if (operation === "milestone" && payload === "install_intent") milestone(payload);
    if (operation === "download") {
      milestone("source_download");
      const module = /^\s*module\s+([A-Za-z0-9_]+)/m.exec(payload);
      const blob = new Blob([payload], { type: "text/plain;charset=utf-8" });
      const url = URL.createObjectURL(blob), link = document.createElement("a");
      link.href = url; link.download = (module ? module[1] : "source") + ".tesl";
      link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
    }
    if (operation === "journey-progress") {
      const earned = validStars(payload);
      journeyDone = validStars([...journeyDone, ...earned]);
      try { earned.forEach(id => localStorage.setItem(starPrefix + id, "1")); } catch (_) {}
      syncProgress();
    }
    if (operation === "journey-reset") {
      journeyDone = [];
      try { exerciseIds.forEach(id => localStorage.removeItem(starPrefix + id)); } catch (_) {}
      syncProgress();
    }
    if (operation === "welcome") {
      try { localStorage.setItem("tesl-playground-intro-hidden", String(!payload)); } catch (_) {}
    }
    if (operation === "cancel-search") cancel("search");
    if (operation === "cancel-check") cancel("check");
    if (operation === "clear-fragment") {
      const url = new URL(location.href); url.hash = ""; url.searchParams.delete("guide");
      history.replaceState(null, "", url.pathname + url.search);
    }
    if (operation === "theme") {
      if (payload === "system") document.documentElement.removeAttribute("data-theme");
      else document.documentElement.setAttribute("data-theme", payload);
      try { localStorage.setItem("tesl-playground-theme", payload); } catch (_) { /* private mode */ }
    }
    if (operation === "dialog") frame(() => {
      const dialog = byId("search-dialog");
      if (payload) { if (!dialog.open) dialog.showModal(); byId("search-query").focus(); }
      else if (dialog.open) dialog.close();
    });
    if (operation === "jump") document.querySelector("tesl-editor").jump(payload);
    if (operation === "focus") frame(() => byId(payload)?.focus());
    if (operation === "select-copy") frame(() => { byId("search-copy-value").focus(); byId("search-copy-value").select(); });
  });
  document.addEventListener("click", event => {
    if (event.target.closest('#tools button, #tools a')) byId('tools').open = false;
    else if (!event.target.closest('#tools')) byId('tools').open = false;
  });
  document.addEventListener("keydown", event => {
    if (event.key === 'Escape' && byId('tools').open) { byId('tools').open = false; byId('tools').querySelector('summary').focus(); }
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k" && !event.isComposing) {
      event.preventDefault(); app.ports.action.send("search");
    }
  });
  const dialog = byId("search-dialog");
  dialog.addEventListener("close", () => app.ports.action.send("close-search"));
  dialog.addEventListener("keydown", event => {
    if (event.key === "Escape" && !event.isComposing) {
      event.preventDefault(); app.ports.action.send("close-search"); return;
    }
    if (event.isComposing || !["ArrowDown", "ArrowUp"].includes(event.key)) return;
    const cards = [...byId("search-results").children];
    if (!cards.length) return;
    const index = cards.indexOf(document.activeElement.closest(".search-card"));
    const next = event.key === "ArrowDown" ? Math.min(index + 1, cards.length - 1) : index - 1;
    event.preventDefault(); if (next < 0) byId("search-query").focus(); else cards[next].focus();
  });
  if (shared?.from) frame(() => document.querySelector("tesl-editor").jump({ start: { line: shared.from - 1, col: 0 }, end: { line: shared.to, col: 0 } }));
  else if (shared?.highlightFrom) frame(() => {
    const src = byId("src"), height = parseFloat(getComputedStyle(src).lineHeight) || 20;
    src.scrollTop = Math.max(0, (shared.highlightFrom - 4) * height); src.dispatchEvent(new Event("scroll"));
  });
})().catch(error => { document.getElementById("app").textContent = "Playground could not start: " + error.message; });
