#lang racket

;; proof-utils.rkt — GDP proof helpers that are byte-for-byte behavior-identical
;; across dsl/private/check-runtime.rkt and dsl/web.rkt.
;;
;; SCOPE (reduce_language_size Phase 4, DSL runtime dedup):
;; This module holds ONLY helpers that are provably identical in both files —
;; same source AND same transitive behavior — and that depend on nothing but
;; Racket builtins (no GDP struct accessors, no current-*-env parameters, no
;; check-runtime/web internals).  That dependency-freedom is what makes the
;; extraction safe and circular-import-free: check-runtime.rkt and web.rkt both
;; `require` this module without it requiring them back.
;;
;; A differential review of the five name-collision candidates found only ONE
;; truly safe to share.  The other four were deliberately LEFT duplicated; see
;; the per-helper notes below for exactly why each diverges.  Do NOT add a
;; helper here unless it is byte-identical in both files AND has no dependency
;; on bindings that live in check-runtime/web (which would create an import
;; cycle, since check-runtime defines those bindings).
;;
;; ── proof-infix-operands  →  EXTRACTED (safe) ────────────────────────────────
;;   Byte-identical in both files; pure (list?/length/odd?/list-ref/eq? only).
;;   Recognizes a GDP infix conjunction datum (a op b op c ...) and returns the
;;   operand list, or #f.
;;
;; ── flatten-proof-conjunction-facts  →  NOT extracted (DIVERGES) ─────────────
;;   check-runtime wraps the result in (remove-duplicates ... equal?); web.rkt
;;   does NOT de-duplicate.  De-duplicating in web's accumulated-fact path would
;;   change which/how-many facts a returned proof carries — a soundness-relevant
;;   behavior change in return validation.  Keep both copies.
;;
;; ── proof-fact-matches?  →  NOT extracted (DIVERGES) ─────────────────────────
;;   check-runtime carries extra match clauses that web.rkt intentionally lacks:
;;     • uninterned-template-symbol vs interned-fact-symbol wildcard
;;       (accept/value with an interned placeholder subject), and
;;     • literal-in-template vs gensym-in-fact in BOTH directions
;;       (e.g. (Clamped 1 100 n) literal bounds vs lo/hi gensyms).
;;   These widen what counts as a proof match.  Unifying would either loosen
;;   web's matcher (unsound for handler/return checks) or tighten check-runtime's
;;   (breaks checker/establish proof transport).  Keep both copies.
;;
;; ── proof-satisfied?  →  NOT extracted (body identical, BEHAVIOR diverges) ───
;;   The body text matches, but proof-satisfied? calls proof-fact-matches? and
;;   flatten-proof-conjunction-facts — both of which diverge (above).  Sharing
;;   proof-satisfied? would force it onto ONE copy of those callees, silently
;;   changing the other file's proof-matching behavior.  Keep both copies.
;;
;; ── normalize-typecheck-value  →  NOT extracted (would create import cycle) ──
;;   Body identical, but it depends on raw-value, current-evidence-env, and the
;;   named-value/check-ok/runtime-binding struct accessors — all defined in (or
;;   re-provided from) check-runtime.rkt.  A shared module containing it would
;;   have to require check-runtime, while check-runtime requires this module:
;;   a cycle.  Safe extraction would require first lifting raw-value + the
;;   evidence env down into a lower layer; out of scope for this conservative
;;   pass.  Keep both copies.

(provide proof-infix-operands)

(define (proof-infix-operands datum op)
  (and (list? datum)
       (>= (length datum) 3)
       (odd? (length datum))
       (for/and ([index (in-range 1 (length datum) 2)])
         (eq? (list-ref datum index) op))
       (for/list ([index (in-range 0 (length datum) 2)])
         (list-ref datum index))))
