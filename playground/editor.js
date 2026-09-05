/* Native editing island. Elm owns source and diagnostic state. This adapter
   retains one textarea so view updates preserve native undo, IME and selection.
   Token coloring is cosmetic; the compiler is the authority for diagnostics. */
(() => {
class TeslEditor extends HTMLElement {
  connectedCallback() {
    if (this.initialized) return;
    this.initialized = true;
    this.innerHTML = `<div class="editor" id="editor"><div id="gutter" aria-hidden="true"></div><div id="codebox"><pre id="underlay" aria-hidden="true"></pre><textarea id="src" spellcheck="false" autocomplete="off" autocapitalize="off" autocorrect="off" wrap="off" aria-label="Tesl source" aria-describedby="editor-hint"></textarea></div></div>`;
    const $ = id => this.querySelector('#' + id);
// ─── Tokenizer ───────────────────────────────────────────────────────────────
// Hand-written because there is no Tesl mode for any editor library, and the
// page ships no dependencies. The keyword set below is transcribed from the
// authoritative table in compiler/lib/lexer.mll — NOT guessed.
//
// DELIBERATE APPROXIMATIONS, all of them cosmetic:
//  * one line at a time, with no carried state. Tesl comments (`#`) end at the
//    newline and string literals are single-line, so the only thing this can get
//    wrong is an unterminated `"` — highlighted to end of line, which is what a
//    reader wants anyway.
//  * SQL and route words (`select`, `where`, `insert`, `get`, …) are CONTEXTUAL
//    identifiers in the real grammar, not reserved words (see parser.ml's
//    `IDENT "where"` cases). They get their own colour wherever they appear, so
//    a variable named `body` or `set` is coloured as if it were the keyword.
//    Harmless; the alternative is a parser.
//  * no semantic distinction between a call and a binding: a lower-case
//    identifier is plain text, an upper-case one is a type/constructor.
//  * `${…}` inside a string is coloured as interpolation without checking that
//    the expression inside it is well-formed.
const KEYWORDS = new Set([
  // compiler/lib/lexer.mll `keywords`, minus the ones listed as PROOFWORDS below
  "module", "exposing", "import", "fn", "handler", "auth", "capture", "capturer",
  "type", "record", "entity", "table", "primaryKey", "codec", "database",
  "backend", "schema", "api", "server", "for", "queue", "channel", "sseChannel",
  "cache", "email", "smtp", "workers", "capability", "implies", "case", "of",
  "let", "if", "then", "else", "using", "const", "main", "worker", "deadWorker",
  "test", "property", "expect", "expectFail", "expectHasProof", "seed",
  "with_codec", "via", "toJson", "fromJson", "toJson_forbidden",
  "fromJson_forbidden", "adtJson", "subscribe", "publish", "sse", "telemetry",
  "null", "true", "false", "tesl", "api-test", "load-test"
]);
// The proof machinery gets its own colour: it is the reason the language exists.
const PROOFWORDS = new Set([
  "fact", "check", "establish", "requires", "ok", "fail", "forgetFact",
  "detachFact", "extractFact", "attachFact", "exists"
]);
// Contextual (non-reserved) words — the SQL forms, the route verbs, the shapes.
const SOFTWORDS = new Set([
  "select", "selectOne", "selectCount", "selectSum", "selectMax", "selectMin",
  "insert", "update", "delete", "from", "where", "set", "returning", "one",
  "order", "limit", "offset", "groupBy", "innerJoin", "transaction", "enqueue",
  "secret", "assert", "body", "response", "get", "post", "put", "patch",
  "serve", "with", "default", "env", "envInt", "envBool", "startWorkers",
  "startDeadWorkers", "startEmailWorker", "humanActions", "serverTools", "asTool"
]);
const OPS = [":::", "::", "->", "=>", "<-", "==", "!=", "<=", ">=", "++", "&&",
             "||", "|>", "<|", "..", "=", "<", ">", "+", "-", "*", "/", "%",
             "!", "&", "|", "?", ":", "."];
const isIdent = c => /[A-Za-z0-9_]/.test(c);

// → [{s, e, cls}, …] covering [0, line.length) contiguously.
function tokenize(line) {
  const out = [], n = line.length;
  let i = 0;
  const push = (s, e, cls) => { if (e > s) out.push({ s, e, cls }); };
  while (i < n) {
    const c = line[i];
    if (c === " " || c === "\t") { const s = i; while (i < n && /[ \t]/.test(line[i])) i++; push(s, i, "t-txt"); continue; }
    if (c === "#") { push(i, n, "t-com"); i = n; continue; }
    if (c === '"') {
      let seg = i;                     // start of the current plain-string run
      i++;                             // the opening quote
      while (i < n) {
        if (line[i] === "\\") { i += 2; continue; }
        if (line[i] === '"') { i++; break; }
        if (line[i] === "$" && line[i + 1] === "{") {          // interpolation
          push(seg, i, "t-str");
          const is = i; i += 2;
          while (i < n && line[i] !== "}") i++;
          if (i < n) i++;              // the closing brace
          push(is, i, "t-interp");
          seg = i;
          continue;
        }
        i++;
      }
      push(seg, i, "t-str");           // …and an unterminated string runs to EOL
      continue;
    }
    if (c === "@" && isIdent(line[i + 1] || "")) {
      const s = i++; while (i < n && isIdent(line[i])) i++; push(s, i, "t-ann"); continue;
    }
    if (/[0-9]/.test(c)) {
      const s = i; while (i < n && /[0-9_]/.test(line[i])) i++;
      if (line[i] === "." && /[0-9]/.test(line[i + 1] || "")) { i++; while (i < n && /[0-9]/.test(line[i])) i++; }
      push(s, i, "t-num"); continue;
    }
    if (/[A-Za-z_]/.test(c)) {
      const s = i; while (i < n && isIdent(line[i])) i++;
      let w = line.slice(s, i);
      // `api-test` / `load-test` are single tokens in the lexer.
      if ((w === "api" || w === "load") && line.slice(i, i + 5) === "-test") { i += 5; w += "-test"; }
      const cls = KEYWORDS.has(w) ? "t-kw"
        : PROOFWORDS.has(w) ? "t-proof"
        : SOFTWORDS.has(w) ? "t-kw2"
        : /^[A-Z]/.test(w) ? "t-type"
        : "t-txt";
      push(s, i, cls); continue;
    }
    const op = OPS.find(o => line.startsWith(o, i));
    if (op) { push(i, i + op.length, op === ":::" ? "t-proof" : "t-op"); i += op.length; continue; }
    push(i, i + 1, "t-op"); i++;
  }
  return finish(out, line);
}
function finish(out, line) {
  // Guarantee full coverage even if a branch above bailed early.
  const last = out.length ? out[out.length - 1].e : 0;
  if (last < line.length) out.push({ s: last, e: line.length, cls: "t-txt" });
  return out;
}

// ─── The highlighted underlay, with the diagnostic ranges on top ─────────────
const SEV_RANK = { error: 3, warning: 2, info: 1 };
const esc = s => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// Per line, the diagnostic slices that touch it. A multi-line range contributes
// [start.col, EOL] on its first line, whole lines in between, [0, end.col] on
// its last — i.e. the EXACT span, not the lines it happens to touch.
function diagSlices(lines, diags) {
  const per = lines.map(() => []);
  diags.forEach((d, i) => {
    const s = d.start, e = d.end;
    for (let L = s.line; L <= e.line; L++) {
      if (L < 0 || L >= lines.length) continue;
      const len = lines[L].length;
      let a = L === s.line ? s.col : 0;
      let b = L === e.line ? e.col : len;
      a = Math.max(0, Math.min(a, len));
      b = Math.max(a, Math.min(b, len));
      if (b === a) b = Math.min(len, a + 1);          // zero-width: show 1 char
      per[L].push({ a, b, i, sev: d.severity || "info" });
    }
  });
  return per;
}

function renderEditorLayers(text, diags, highlightFrom, highlightTo) {
  const lines = text.split("\n");
  const slices = diagSlices(lines, diags);
  // Rows are JOINED with "\n", never terminated with it: one extra "\n" would
  // give the underlay one more line box than the textarea has lines, and every
  // squiggle below the fold would sit one line too low.
  const rows = [];
  const gut = [];
  for (let L = 0; L < lines.length; L++) {
    let html = "";
    const line = lines[L], len = line.length;
    const lineNum = L + 1;  // 1-based line number
    const isHighlighted = highlightFrom && highlightTo && lineNum >= highlightFrom && lineNum <= highlightTo;
    const toks = tokenize(line);
    const cls = new Array(len), mark = new Array(len);
    for (const t of toks) for (let k = t.s; k < t.e; k++) cls[k] = t.cls;
    let worst = null;
    slices[L].forEach((m, mi) => {
      if (!worst || SEV_RANK[m.sev] > SEV_RANK[worst.sev]) worst = m;
      for (let k = m.a; k < m.b; k++) {
        const cur = mark[k];
        // Overlapping ranges: the more severe one owns the character.
        if (cur === undefined || SEV_RANK[m.sev] > SEV_RANK[slices[L][cur].sev]) mark[k] = mi;
      }
    });
    let k = 0;
    while (k < len) {
      const c = cls[k] || "t-txt", mi = mark[k];
      let j = k + 1;
      while (j < len && (cls[j] || "t-txt") === c && mark[j] === mi) j++;
      const piece = esc(line.slice(k, j));
      if (mi === undefined) html += `<span class="${c}">${piece}</span>`;
      else {
        const m = slices[L][mi], d = diags[m.i];
        html += `<span class="${c} sq ${m.sev}" data-d="${m.i}" title="${esc(diagTitle(d))}">${piece}</span>`;
      }
      k = j;
    }
    // A diagnostic whose whole range sits at the end of an empty/short line has
    // no character to underline. Emit a zero-width marker instead of nothing.
    if (len === 0 && slices[L].length) {
      const m = slices[L][0];
      html += `<span class="sq empty ${m.sev}" data-d="${m.i}" title="${esc(diagTitle(diags[m.i]))}"></span>`;
    }
    // Wrap in line-highlight if this line is in the highlight range
    if (isHighlighted) {
      html = `<span class="line-highlight">${html}</span>`;
    }
    rows.push(html);
    const sev = worst ? worst.sev : "";
    const isGutterHighlighted = highlightFrom && highlightTo && (L + 1) >= highlightFrom && (L + 1) <= highlightTo;
    const gutterClass = isGutterHighlighted ? "gl selected" : "gl";
    gut.push(`<div class="${gutterClass}" data-line="${L + 1}"><span class="gm ${sev}">${sev ? "●" : ""}</span><span class="gn">${L + 1}</span></div>`);
  }
  // Two zero-width spaces, each earning its keep:
  //  * leading: the HTML parser drops a newline that immediately follows <pre>,
  //    which would shift every line up by one whenever line 1 is blank;
  //  * trailing: a buffer ending in "\n" has a real last (empty) line the
  //    textarea puts a caret on, but a <pre> gives no line box to a trailing
  //    newline. Needed only in that case, or the underlay grows a phantom line.
  const tailPad = lines[lines.length - 1] === "" ? "\u200b" : "";
  $("underlay").innerHTML = "\u200b" + rows.join("\n") + tailPad;
  $("gutter").innerHTML = gut.join("");
  syncScroll();
}

function diagTitle(d) {
  let t = `${d.severity} ${d.code}: ${d.message}`;
  if (d.fix && d.fix.title) t += `\nFix available: ${d.fix.title}`;
  return t;
}

function syncScroll() {
  const src = $("src");
  $("underlay").scrollTop = src.scrollTop;
  $("underlay").scrollLeft = src.scrollLeft;
  $("gutter").scrollTop = src.scrollTop;
}

// ─── Jump to a position in the editor ───────────────────────────────────────
function lineOffsets(text) {
  const offs = [0];
  for (let i = 0; i < text.length; i++) if (text[i] === "\n") offs.push(i + 1);
  return offs;
}
// 0-based line/col in, caret + scroll out.
function gotoRange(sl, sc, el, ec) {
  const src = $("src"), offs = lineOffsets(src.value);
  const clampL = L => Math.max(0, Math.min(L, offs.length - 1));
  const at = (L, C) => offs[clampL(L)] + Math.max(0, C || 0);
  src.focus();
  src.setSelectionRange(at(sl, sc), at(el === undefined ? sl : el, ec === undefined ? sc : ec));
  // Put the target line roughly a third of the way down the viewport.
  const lh = parseFloat(getComputedStyle(src).lineHeight) || 20;
  src.scrollTop = Math.max(0, sl * lh - src.clientHeight / 3);
  syncScroll();
}
function flashDiag(i) {
  for (const n of document.querySelectorAll("#underlay .flash")) n.classList.remove("flash");
  const nodes = document.querySelectorAll(`#underlay [data-d="${i}"]`);
  for (const n of nodes) n.classList.add("flash");
  setTimeout(() => { for (const n of nodes) n.classList.remove("flash"); }, 1200);
}

// ─── UI plumbing ────────────────────────────────────────────────────────────

    const src = $('src');
    let composing = false, drag = null;
    const emit = (name, detail) => this.dispatchEvent(new CustomEvent(name, { detail }));
    this.paint = () => {
      if (!this.current) return;
      const h = this.current.highlight;
      renderEditorLayers(src.value, this.current.diagnostics, h?.from, h?.to);
    };
    this.project = state => {
      // Never assign the value when Elm echoes a native input event.
      if (src.value !== state.source) src.value = state.source;
      this.current = state;
      this.paint();
      this.ide?.update(state);
    };
    src.addEventListener('input', event => { this.paint(); emit('source-edit', { source: src.value, composing: composing || event.isComposing === true }); });
    src.addEventListener('compositionstart', () => { composing = true; emit('source-edit', { source: src.value, composing: true }); });
    src.addEventListener('compositionend', () => { composing = false; emit('source-edit', { source: src.value, composing: false }); });
    src.addEventListener('scroll', syncScroll);
    src.addEventListener('keydown', event => {
      if (event.isComposing) return;
      if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') { event.preventDefault(); emit('check-now', null); }
      if ((event.ctrlKey || event.metaKey) && event.shiftKey && event.key.toLowerCase() === 'h') {
        event.preventDefault();
        const line = offset => src.value.slice(0, offset).split('\n').length;
        emit('highlight-lines', src.selectionEnd > src.selectionStart ? { from: line(src.selectionStart), to: line(src.selectionEnd - 1) } : null);
      }
    });
    $('gutter').addEventListener('mousedown', event => {
      const line = event.target.closest('.gl');
      if (!line) return;
      event.preventDefault();
      drag = { start: Number(line.dataset.line), end: Number(line.dataset.line) };
    });
    $('gutter').addEventListener('mousemove', event => {
      const line = event.target.closest('.gl');
      if (!drag || !line) return;
      drag.end = Number(line.dataset.line);
      emit('highlight-lines', { from: Math.min(drag.start, drag.end), to: Math.max(drag.start, drag.end) });
    });
    this.release = () => {
      if (!drag) return;
      const h = { from: Math.min(drag.start, drag.end), to: Math.max(drag.start, drag.end) };
      const previous = this.current?.highlight;
      emit('highlight-lines', drag.start === drag.end && previous?.from === h.from && previous?.to === h.to ? null : h);
      drag = null;
    };
    document.addEventListener('mouseup', this.release);
    this.jump = ({ start, end, index }) => { if (this.ide) { this.ide.jump({start, end}); return; } gotoRange(start.line, start.col, end.line, end.col); if (index !== undefined) flashDiag(index); };
    this.selection = () => this.ide ? this.ide.selection() : { start: src.selectionStart, end: src.selectionEnd };
    this.setMode = (enabled, lookup) => {
      if (enabled === Boolean(this.ide)) return;
      const selection = this.selection();
      if (enabled) {
        const host = document.createElement('div'); host.id = 'ide-editor'; this.append(host);
        try {
          this.ide = window.TeslMonaco.mount(host, this.current, {
            edit: (source, composing) => { src.value = source; emit('source-edit', { source, composing }); },
            learn: () => emit('learn-this', null), check: () => emit('check-now', null), search: () => window.TeslPlayground.ports.action.send('search'),
            highlight: value => emit('highlight-lines', value), fix: fix => emit('apply-fix', fix), lookup
          });
          $('editor').hidden = true;
          this.ide.select(selection.start, selection.end); this.ide.editor.focus();
        } catch (error) { host.remove(); throw error; }
      } else {
        this.ide.dispose(); this.ide = null; this.querySelector('#ide-editor').remove();
        $('editor').hidden = false; src.setSelectionRange(selection.start, selection.end); src.focus(); this.paint();
      }
    };
    $('gutter').title = 'Right-click a line number to explain its language features';
    $('gutter').addEventListener('contextmenu', event => {
      const row = event.target.closest('.gl');
      if (!row) return;
      event.preventDefault();
      const index = [...$('gutter').children].indexOf(row);
      const start = src.value.split('\n').slice(0, index).reduce((n, line) => n + line.length + 1, 0);
      src.setSelectionRange(start, start);
      emit('learn-this', null);
    });
    if (this.pending) this.project(this.pending);
  }
  set state(state) { this.pending = state; if (this.project) this.project(state); }
  disconnectedCallback() { this.ide?.dispose(); document.removeEventListener('mouseup', this.release); }
}
customElements.define('tesl-editor', TeslEditor);
})();
