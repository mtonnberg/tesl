/* Presentation only. Query parsing, ranking and types live in Builtin_search. */
(() => {
  "use strict";
  const byId = id => document.getElementById(id);
  const node = (tag, text, className) => {
    const result = document.createElement(tag);
    if (text !== undefined) result.textContent = text;
    if (className) result.className = className;
    return result;
  };
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
  let compilerReady = false;
  function compiler() {
    return loadScript("tesl_playground.js").then(() => {
      if (typeof window.teslCheck !== "function") throw Error("Compiler export is missing.");
      if (!compilerReady) {
        compilerReady = true;
        window.dispatchEvent(new Event("tesl:ready"));
      }
    });
  }
  const compilerRetry = byId("compiler-retry");
  const loadCompiler = () => compiler().then(() => { compilerRetry.hidden = true; }).catch(error => {
    byId("status").textContent = error.message;
    compilerRetry.hidden = false;
  });
  compilerRetry.addEventListener("click", loadCompiler);
  loadCompiler();

  const dialog = byId("search-dialog"), input = byId("search-query");
  const results = byId("search-results"), status = byId("search-status"), retry = byId("search-retry");
  let examplesPromise = null, requestId = 0, composing = false, timer = null;
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
  async function copy(text, message) {
    const fallback = byId("search-copy-value");
    try {
      await navigator.clipboard.writeText(text);
      fallback.hidden = true;
      status.textContent = message;
    } catch (_) {
      fallback.hidden = false;
      fallback.value = text;
      fallback.focus(); fallback.select();
      status.textContent = "Select and copy the text below.";
    }
  }
  function resultCard(entry, examples) {
    const card = node("li", undefined, "search-card");
    card.tabIndex = -1;
    card.append(node("h3", entry.name), node("p", (entry.module || "Always available") + " · " + entry.kind, "search-meta"));
    card.append(node("pre", entry.signature), node("p", entry.doc));
    const requirements = entry.requirements;
    const caps = requirements.capabilities.length ? requirements.capabilities.join(", ") : "none listed";
    card.append(node("p", "Direct capabilities: " + caps + (requirements.capabilities_status === "unavailable" ? " (metadata incomplete; see signature)" : "") +
      ". Proof requirements: not indexed.", "search-requirements"));
    if (entry.structural_status === "text-only") card.append(node("p",
      "Signature sketch. Available through text lookup; no structured type scheme yet.", "search-meta"));
    if (entry.structural_status === "incomplete-scheme") card.append(node("p",
      "Available through text lookup. This compiler scheme has incomplete generic-variable metadata, so type matching is unavailable.", "search-meta"));
    const actions = node("div", undefined, "search-actions");
    if (entry.import) {
      card.append(node("pre", entry.import, "search-import"));
      const button = node("button", "Copy import", "btn");
      button.addEventListener("click", () => copy(entry.import, "Import copied."));
      actions.append(button);
    } else {
      card.append(node("p", entry.module ? "Import recipe unavailable; consult the signature and lessons." : "No import required.", "search-meta"));
    }
    for (const example of examples.filter(example => example.symbols.includes(entry.name))) {
      const link = node("a", example.title + " ↗", "search-example");
      const url = new URL("index.html", location.href);
      url.hash = example.fragment;
      link.href = url.href;
      link.target = "_blank"; link.rel = "noopener";
      link.title = "Open checked source in a new tab. Source SHA-256: " + example.source_sha256;
      actions.append(link);
    }
    if (!examples.some(example => example.symbols.includes(entry.name))) {
      const link = node("a", "Browse lessons ↗");
      link.href = "lessons.html"; link.target = "_blank"; link.rel = "noopener";
      actions.append(link);
    }
    card.append(actions);
    return card;
  }
  async function search() {
    const request = ++requestId;
    const query = input.value.trim();
    retry.hidden = true;
    results.replaceChildren();
    byId("search-copy-value").hidden = true;
    if (!query) { status.textContent = "Search by name, description, module or type. Try an example below."; return; }
    status.textContent = "Searching…";
    try {
      const examples = await loadSearch();
      if (request !== requestId) return;
      const response = JSON.parse(window.teslSearch(query));
      if (response.version !== 1 || response.catalog_id !== build().catalog_id) throw Error("Search version mismatch. Save your source, then reload the page.");
      if (response.error) { status.textContent = response.error; return; }
      if (/^[A-Z][0-9]{3}$/.test(query)) {
        await compiler();
        if (request !== requestId) return;
        const explanation = window.teslExplain(query);
        if (explanation) {
          const card = node("li", undefined, "search-card"); card.tabIndex = -1;
          card.append(node("h3", query), node("pre", explanation)); results.append(card);
          status.textContent = "Diagnostic explanation from this compiler.";
          return;
        }
      }
      results.replaceChildren(...response.results.map(entry => resultCard(entry, examples)));
      status.textContent = response.total ?
        `${response.total} result${response.total === 1 ? "" : "s"}${response.total > response.limit ? `; showing the first ${response.limit}. Add a name or description to narrow the query` : ""}. ${response.mode === "type" ? "Exact type shapes; requirements still apply." : "Name and text lookup."}` :
        "No results. Try a shorter name, a description, or a type with the same argument order. Text-only entries cannot match a type query.";
      const identity = build();
      byId("search-version").textContent = `Source ${identity.source_revision.slice(0, 12)}${identity.source_dirty ? " + local changes" : ""} · catalog ${identity.catalog_id.slice(0, 12)}`;
    } catch (error) {
      if (request !== requestId) return;
      status.textContent = error.message;
      retry.hidden = false;
    }
  }
  const schedule = () => {
    clearTimeout(timer); ++requestId;
    if (!composing) timer = setTimeout(search, 100);
  };
  input.addEventListener("input", schedule);
  input.addEventListener("compositionstart", () => { composing = true; clearTimeout(timer); ++requestId; });
  input.addEventListener("compositionend", () => { composing = false; schedule(); });
  retry.addEventListener("click", search);
  function open() { if (!dialog.open) dialog.showModal(); input.focus(); search(); }
  byId("search-open").addEventListener("click", open);
  byId("search-close").addEventListener("click", () => dialog.close());
  dialog.addEventListener("close", () => { ++requestId; clearTimeout(timer); });
  document.addEventListener("keydown", event => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k" && !event.isComposing) {
      event.preventDefault(); open();
    }
  });
  dialog.addEventListener("keydown", event => {
    if (event.isComposing || !["ArrowDown", "ArrowUp"].includes(event.key)) return;
    const cards = [...results.children];
    if (!cards.length) return;
    const index = cards.indexOf(document.activeElement.closest(".search-card"));
    const next = event.key === "ArrowDown" ? Math.min(index + 1, cards.length - 1) : index - 1;
    event.preventDefault();
    if (next < 0) input.focus(); else cards[next].focus();
  });
  for (const button of dialog.querySelectorAll("[data-query]")) {
    button.addEventListener("click", () => { input.value = button.dataset.query; input.focus(); search(); });
  }
  byId("search-share").addEventListener("click", () => {
    const url = new URL(location.href);
    url.searchParams.set("q", input.value);
    copy(url.href, "Search link copied. The query is in ?q=; the current source fragment is preserved.");
  });
  const linkedQuery = new URL(location.href).searchParams.get("q");
  if (linkedQuery !== null) { input.value = linkedQuery; open(); }
})();
