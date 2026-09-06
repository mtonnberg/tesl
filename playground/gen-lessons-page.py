#!/usr/bin/env python3
"""Generate lessons.html and a checked random-lesson page.

Requires Node.js and the built tesl_playground.js beside out.html; build.sh
supplies both. Lessons open in the browser checker, which does not run programs.

WHY A SEPARATE PAGE RATHER THAN A PICKER INSIDE THE PLAYGROUND
--------------------------------------------------------------
The obvious design is a dropdown in index.html backed by a bundled lessons.json.
This is better on three counts:

  * it costs the playground page NOTHING. The lesson corpus is 750 KB raw / 190 KB
    gzipped — comparable to the entire compiler bundle (1.07 MB / 351 KB). The
    embedded-manual measurement already taught this lesson: keep large content
    out of the thing that has to load fast.
  * every lesson gets a STABLE PERMALINK, which is what
    roadmap/next/revised_onboarding.md Phase 3 actually asked for ("lessons
    rendered with ... a stable permalink each"). A dropdown selection is not a
    URL you can send someone.
  * it reuses the EXISTING share-hash mechanism instead of inventing a second
    content path. There is one way source reaches the playground, and it is the
    same one the Share button produces.

THE ORDER AND THE PROSE ARE NOT WRITTEN HERE
--------------------------------------------
Both come from the `# lesson:` / `# summary:` headers in each lesson, the same
single source `scripts/gen-lesson-index.sh` reads to generate `manual/lessons.md`.
So this page cannot disagree with the manual's catalog, and adding a lesson needs
no edit here.

Usage:  playground/gen-lessons-page.py <repo-root> <out.html> [playground-href]
"""

import base64
import html
import json
import subprocess
import re
import sys
import zlib
from pathlib import Path

# Mirrors playground/index.html's `encodeShare`:
#   #z<base64url(raw deflate)>, falling back to #s<base64url(utf-8)>,
#   with an OPTIONAL trailing position: `.L42` (caret on line 42) or `.L42-45`
#   (select lines 42 through 45), 1-based, `.` being impossible inside base64url.
# Raw deflate (wbits=-15) is what the browser's CompressionStream("deflate-raw")
# produces and DecompressionStream consumes — a zlib or gzip wrapper would NOT
# decode. It buys ~4x: the largest lesson is 34 KB, so ~9 KB of fragment.
#
# This page emits NO position: a lesson link means "open the whole lesson", and
# an index that guessed at an interesting line would be guessing. The parameter
# exists so a future caller (a manual cross-reference, a forum answer) can point
# at a line without a second encoder, and so index.html's decoder and this
# encoder cannot drift apart about the format.
def share_fragment(source: str, line: int = None, end_line: int = None) -> str:
    raw = source.encode("utf-8")
    co = zlib.compressobj(9, zlib.DEFLATED, -15)
    packed = co.compress(raw) + co.flush()
    if len(packed) >= len(raw):          # incompressible: don't pay the wrapper
        frag = "s" + b64url(raw)
    else:
        frag = "z" + b64url(packed)
    if line:
        frag += ".L%d" % line
        if end_line and end_line > line:
            frag += "-%d" % end_line
    return frag


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


# Track display order and titles — deliberately identical to
# scripts/gen-lesson-index.sh's, so the two catalogs read the same way.
TRACKS = [
    ("basics",  "Basics — the language itself"),
    ("proofs",  "Proofs — the reason Tesl exists"),
    ("api",     "APIs — handlers, auth, capabilities"),
    ("data",    "Data — typed SQL and entities"),
    ("async",   "Async — queues, workers, streaming"),
    ("testing", "Testing and debugging"),
    ("stdlib",  "Standard library"),
    ("ai",      "AI-era surfaces"),
]

META_RE = re.compile(r"^# lesson:\s*track=(\w+)\s+order=(\d+)\s+needs=([\w,-]+)", re.M)
SUMMARY_RE = re.compile(r"^# summary:\s*(.+)$", re.M)


def main() -> int:
    repo = Path(sys.argv[1]).resolve()
    out = Path(sys.argv[2])
    href = sys.argv[3] if len(sys.argv) > 3 else "index.html"

    learn = repo / "example" / "learn"
    lessons = []
    skipped = []

    for path in sorted(learn.glob("*.tesl")):
        source = path.read_text(encoding="utf-8")
        head = "\n".join(source.split("\n")[:40])
        m = META_RE.search(head)
        s = SUMMARY_RE.search(head)
        if not m or not s:
            # Loud, not silent: a lesson without metadata is a bug that
            # scripts/gen-lesson-index.sh already fails the gate on, and this
            # page must not quietly omit it.
            skipped.append(path.name)
            continue
        track, order, needs = m.group(1), int(m.group(2)), m.group(3)
        # The browser checker handles ONE buffer, so a lesson that imports a
        # sibling module cannot resolve it. Flag it rather than serve a link that
        # produces a confusing error — the failure is loud, but a reader should
        # know before clicking.
        cross_module = bool(re.search(r"^import Lesson", source, re.M))
        lessons.append({
            "slug": path.stem,
            "track": track,
            "order": order,
            "needs": [] if needs == "none" else needs.split(","),
            "summary": s.group(1).strip(),
            "frag": share_fragment(source),
            "bytes": len(source.encode("utf-8")),
            "cross_module": cross_module,
        })

    if skipped:
        print("gen-lessons-page: ERROR: lessons with no `# lesson:`/`# summary:` "
              "header: " + ", ".join(skipped), file=sys.stderr)
        return 1
    if not lessons:
        print("gen-lessons-page: ERROR: no lessons found under %s" % learn, file=sys.stderr)
        return 1

    by_slug = {l["slug"]: l for l in lessons}
    rows = []
    for track, title in TRACKS:
        group = sorted((l for l in lessons if l["track"] == track),
                       key=lambda l: l["order"])
        if not group:
            continue
        rows.append('<h2>%s</h2>' % html.escape(title))
        rows.append("<ul class=lessons>")
        for l in group:
            assumes = ""
            if l["needs"]:
                parts = []
                for n in l["needs"]:
                    dep = by_slug.get(n)
                    if dep:
                        parts.append('<a href="%s#%s">%s</a>'
                                     % (html.escape(href), dep["frag"], html.escape(n)))
                    else:
                        parts.append(html.escape(n))
                assumes = ('<div class=assumes>Assumes %s</div>'
                           % ", ".join(parts))
            note = ('<div class=note>Imports a sibling module — the browser '
                    'checker works on one file at a time, so this one will '
                    'report the missing import.</div>') if l["cross_module"] else ""
            rows.append(
                '<li><a class=lesson href="%s#%s"><code>%s</code></a>'
                '<div class=summary>%s</div>%s%s</li>'
                % (html.escape(href), l["frag"], html.escape(l["slug"]),
                   html.escape(l["summary"]), assumes, note))
        rows.append("</ul>")

    page = PAGE.replace("%%COUNT%%", str(len(lessons))) \
               .replace("%%ROWS%%", "\n".join(rows)) \
               .replace("%%HREF%%", html.escape(href))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(page, encoding="utf-8")
    # A random first lesson should neither require prior lessons nor open with
    # an unresolved import/error. Check the actual browser artifact, not a guess.
    candidates = [l for l in lessons if not l["needs"] and not l["cross_module"]]
    probe = """const fs = require('fs'); require(process.argv[1]);
const sources = JSON.parse(fs.readFileSync(0, 'utf8'));
process.stdout.write(JSON.stringify(sources.map(s => !JSON.parse(teslCheck(s)).diagnostics.some(d => d.severity === 'error'))));"""
    checked = subprocess.run(["node", "-e", probe, str((out.parent / "tesl_playground.js").resolve())],
        input=json.dumps([(learn / (l["slug"] + ".tesl")).read_text() for l in candidates]), text=True, capture_output=True, check=True)
    eligible = [l for l, clean in zip(candidates, json.loads(checked.stdout)) if clean]
    if not eligible:
        raise ValueError("No self-contained, clean random lessons")
    pool = [{"title": l["slug"], "summary": l["summary"], "href": href + "#" + l["frag"]} for l in eligible]
    random_page = RANDOM_PAGE.replace("%%POOL%%", json.dumps(pool).replace("<", "\\u003c"))
    (out.parent / "random.html").write_text(random_page, encoding="utf-8")
    print("gen-lessons-page: random pool has %d self-contained checked lessons" % len(pool))
    total = sum(len(l["frag"]) for l in lessons)
    print("gen-lessons-page: wrote %s (%d lessons, %d bytes of fragments, "
          "largest %d)" % (out, len(lessons), total,
                           max(len(l["frag"]) for l in lessons)))
    return 0


PAGE = """<!doctype html>
<meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Tesl lessons — explore them in your browser</title>
<style>
  :root { color-scheme: light dark; --fg:#111; --dim:#666; --line:#d8d8d8; --accent:#0b5fff; }
  @media (prefers-color-scheme: dark) {
    :root { --fg:#e8e8e8; --dim:#9a9a9a; --line:#333; --accent:#7aa2ff; }
  }
  body { font: 15px/1.55 system-ui, -apple-system, Segoe UI, sans-serif;
         max-width: 46rem; margin: 0 auto; padding: 2rem 1.25rem 5rem;
         color: var(--fg); }
  h1 { font-size: 1.6rem; margin: 0 0 .35rem; }
  h2 { font-size: 1rem; text-transform: uppercase; letter-spacing: .06em;
       color: var(--dim); margin: 2.4rem 0 .6rem; font-weight: 600; }
  .lede { color: var(--dim); margin: 0 0 1.5rem; }
  a { color: var(--accent); }
  ul.lessons { list-style: none; padding: 0; margin: 0; }
  ul.lessons li { padding: .7rem 0; border-top: 1px solid var(--line); }
  a.lesson code { font-size: .95rem; }
  .summary { margin-top: .15rem; }
  .assumes, .note { color: var(--dim); font-size: .87rem; margin-top: .2rem; }
  .note { font-style: italic; }
  footer { margin-top: 3rem; padding-top: 1rem; border-top: 1px solid var(--line);
           color: var(--dim); font-size: .87rem; }
</style>

<h1>Tesl lessons</h1>
<p class=lede>
  All %%COUNT%% lessons, in reading order. Each one opens in the
  <a href="%%HREF%%">browser checker</a> with its source already loaded — the
  compiler runs in your tab, so you can edit any of them and watch the
  diagnostics change. Nothing is uploaded: the source travels in the URL
  fragment, which browsers never send to a server.
</p>
<p class=lede>
  The checker does not <em>run</em> programs — no HTTP, no database, no
  streaming. It parses, type-checks, <strong>proof-checks</strong>, lints, and
  shows you the generated Go, TypeScript and Elm.
</p>

%%ROWS%%

<footer>
  Generated from the <code>#&nbsp;lesson:</code> headers in each
  <code>example/learn/*.tesl</code> — the same source the manual's lesson
  catalog is generated from, so the two cannot disagree. Reading order is value
  order: the earlier a lesson appears, the more it matters.
</footer>
"""


RANDOM_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>A lesson to explore — Tesl</title><link rel="stylesheet" href="playground.css"></head>
<body><article class="start-guide"><nav><a href="lessons.html">All lessons</a> · <a href="index.html">Playground</a></nav>
<p class="eyebrow">Something to explore</p><h1 id="lesson-title">Pick a lesson</h1>
<p id="lesson-summary">Choose from the lesson collection.</p>
<p><a id="open-random-lesson" class="btn build-cta" href="lessons.html">Open this lesson</a> <button id="another-lesson" class="btn" hidden>Pick another</button></p>
<p>These lessons have no listed prerequisites and pass the browser compiler as one file. Their tests and programs still need to be run locally.</p>
<noscript><p><a href="lessons.html">Browse the complete lesson list</a>.</p></noscript>
</article><script>
const lessons = %%POOL%%;
let previous = -1;
function choose() {
  let index = Math.floor(Math.random() * lessons.length);
  if (lessons.length > 1 && index === previous) index = (index + 1) % lessons.length;
  previous = index;
  const lesson = lessons[index];
  document.getElementById('lesson-title').textContent = lesson.title;
  document.getElementById('lesson-summary').textContent = lesson.summary;
  document.getElementById('open-random-lesson').href = lesson.href;
}
document.getElementById('another-lesson').hidden = false;
document.getElementById('another-lesson').addEventListener('click', choose);
choose();
</script></body></html>"""


if __name__ == "__main__":
    sys.exit(main())
