> **DONE 2026-07-02 (`stability_wave`).** D6 (dead reserved keywords `deadWorkers`/`inject`
> removed) and D8 (idiom-transfer diagnostics: `return`, `+`→`++`, single-line `if`) landed with
> `test_b5_diagnostics.ml`. D11 was **discarded** (`roadmap/discarded/spec_citation_named_anchors.md`).
> D9 (structured machine-applicable fixes) and D12 (proof-free bindings-hash suppression) were
> **deferred** to `roadmap/later/docs_diagnostics_fixes.md` (each needs more than a message tweak;
> lower value than the wave's soundness work).

# Docs & small-features backlog

## D6 — remove dead reserved keywords / back-compat aliases

Review §8.1. Effort **S/M**. The reservation set is inconsistent
(`email`/`test`/`main` usable as fn names; `cache`/`schema` not). Remove dead reserved
keywords and back-compat aliases; make the reservation set consistent.

## D8 — idiom-transfer diagnostics

Review §8.1. Effort **M**. Diagnostics for *idiom-transfer* failures are weak. Add hints:
single-line `if` (currently a bare hard error), a `++` hint on `+`-of-strings (today three
cascading "unify String with Int" errors), and a `return x` hint (today "unknown name:
return").

## D9 — structured machine-applicable fixes beyond `Boolean→Bool`

Review §8.3. Effort **M**. The advertised "machine-applicable fix" is prose-only
(`fix:null`) for essentially every AI-relevant diagnostic; structured fixes exist only for
the `Boolean→Bool` migration. Extend structured (machine-applicable) fixes to the key
diagnostics AI agents actually hit.

> D11 (migrate spec `§`-citations to named anchors) was **discarded** — see
> `roadmap/discarded/spec_citation_named_anchors.md` (drift already guarded by
> `test_spec_anchors.ml`; full migration is L-effort doc churn with no surface reduction).

## D12 — don't emit an all-parameters bindings hash for proof-free fns

Effort **S**. A proof-free function should not emit an all-parameters bindings hash;
suppress it when the function carries no proof obligation.

---

## Refs

- Review: §8.1, §8.2, §8.3, §8.4.
- Backlog: `documentation_deferred_backlog.md` (D2-full → D1, D7-full → D10, D9-full → D11),
  `stability_deferred_backlog.md` (String-ordering follow-up → D13).
- Source (per item): fence-extractor + `compile-examples.sh` (D1); telemetry runtime
  (D2-OTLP); benchmark harness (D4); `lexer.mll` reservation set (D6); checker diagnostics
  (D8); `error_codes.ml` / fix emission (D9); `manual/examples.md` generator +
  `embedded_docs.ml` (D10); `test_spec_anchors.ml` / `manual/anchors.md` (D11);
  `emit_racket.ml` bindings-hash (D12); `is_orderable` / `orderable_bases` + emitter (D13).
