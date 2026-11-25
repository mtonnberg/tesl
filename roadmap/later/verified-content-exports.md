# Verified content exports for adoption

Status: first slice built; not yet used for publishing (checked 2026-11-25).
Moved to `later/` 2026-11-25.

## The problem

Tutorials, blog posts and the website will be written in a separate repository,
`tesl-adoption`. If code samples are copied there by hand, they drift: a sample
stops compiling, or an article claims "the compiler rejects this" when it no
longer does. Nobody notices until a reader does.

## The idea

Code samples live in **this** repository and are checked by CI like any other
code. A script packages each sample, together with proof that it was checked,
into one JSON file. The adoption repository only uses samples from that file and
records the file's hash, so it can never publish a sample this repository did not
verify.

## What exists today

- **One sample:** [`example/adoption/validation-title.tesl`](../../example/adoption/validation-title.tesl),
  a title-length validation. It has four tests, plus a deliberately broken
  variant (validation removed) that must fail with one exact error code on one
  exact line.
- **A catalog:** [`content/catalog.json`](../../content/catalog.json) lists the
  samples, the manual pages and reference entries articles may quote, and what
  each sample is allowed to claim.
- **A script:** `scripts/content.py verify` builds the compiler, checks the broken
  and fixed versions, runs the tests, and fails on any skipped or unexpected
  result. `scripts/content.py export` writes the JSON file (the "bundle") with the
  source, the results and hashes of both source and compiler.
- **CI:** `./ci.sh` runs `verify`; GitHub CI uploads the bundle as a build
  artifact after the gate passes.

How to add a sample and what the hashes do and don't prove:
[`content/README.md`](../../content/README.md).

## What is missing

1. **More samples.** One sample cannot support a tutorial series. Each new article
   needs its samples added here first.
2. **Fix the contradictions found by the adoption audit.** An audit in
   `tesl-adoption` found places where the docs contradict each other about the
   runtime/backend. Fix them in this repo so articles don't repeat them. The list
   lives in that repository; it has not been reviewed here.
3. **Stable links.** Articles should link to a sample and the compiler version it
   was checked with, and open it in the playground. That needs published releases
   ([`mainstream_installation.md`](../next/mainstream_installation.md) M3) and pinned
   playground versions ([`later/builtin-discovery.md`](builtin-discovery.md)).
4. **A real release export.** So far bundles come from CI artifacts. Run one export
   from a clean `main` commit, use it in `tesl-adoption`, and write down how a
   bundle is promoted to "used for publishing" and later retired.

Done since the first slice: the compiler-owned builtin catalog for search
(`tesl --catalog-json`, `tesl search`), built by the builtin-discovery work.

## Not in scope

Writing articles, generating prose and the website itself belong to
`tesl-adoption`. Installation and Windows support have their own roadmap files.
