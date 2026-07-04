(** LCF-style proof kernel — close_fail_open Option B (the TCB-shrink capstone).

    This is the ONLY module that can construct a {!proven_fact}.  Every other module
    in the checker consumes [proven_fact]s (through {!fact_of}) but cannot fabricate
    one, because the type is abstract and there is no [proof_expr -> proven_fact]
    escape hatch.  Consequently a bug ANYWHERE outside this kernel can only cause
    OVER-rejection (loud and fixable), never a forged proof — which collapses the
    trusted surface for the decision "is a proof admitted here?" from the ~40k-line
    checker down to this file.  This mirrors how LCF/Isabelle keep a tiny trusted
    kernel behind a large untrusted elaborator, and how Haskell-GDP gets a ~5-LOC TCB
    — but here the friendly, domain-aware diagnostics live in the (untrusted)
    elaborator, so shrinking the TCB costs nothing in error quality.

    The admission rules mirror Tesl's soundness model exactly:

    - {!mint_at_boundary} — a [check]/[auth]/[establish] body is TRUSTED to establish
      its declared return proof (the GDP smart-constructor boundary).  It returns
      [None] for every other {!Ast.func_kind}, so "a plain [fn]/[handler] mints a
      proof" is unrepresentable (fail-closed by default).
    - {!framework_provenance} — FromDb/FromQueue/FromDeadQueue provenance, minted by
      the framework at a real DB/queue site (the caller verifies the site).
    - {!assume_param} — a proof-carrying PARAMETER's declared proof is assumed inside
      the body; sound because every call site must discharge it (via proof_matches).
    - {!pass_through} / {!conj_intro} — structural rules that DERIVE a fact from
      facts that already exist (re-subject a binding; introduce a conjunction).  They
      take [proven_fact]s as input, so they cannot conjure a fact from nothing.

    {!fact_of} projects a [proven_fact] back to its concrete {!Ast.proof_expr} for
    matching and rendering.  It is deliberately one-way. *)

open Ast

(** A fact that has been admitted through one of the kernel's rules.  Abstract: no
    public constructor, so only this module can produce one. *)
type proven_fact

(** Mint the declared return proof of a TRUSTED minting kind.  [Some] only for
    [CheckKind]/[AuthKind]/[EstablishKind]; [None] for every other kind. *)
val mint_at_boundary : func_kind -> proof_expr -> proven_fact option

(** Framework-established provenance (FromDb/FromQueue/FromDeadQueue).  The caller
    must have verified that a real DB/queue site produces the value. *)
val framework_provenance : proof_expr -> proven_fact

(** Assume a proof-carrying parameter's declared proof inside the function body.
    Sound because the parameter's proof is discharged at every call site. *)
val assume_param : proof_expr -> proven_fact

(** Structural rule: re-subject a fact through a binding rename.  [subst] is the
    caller's substitution over the concrete proof (e.g.
    [Validation_common.subst_proof mapping]); the kernel applies it and re-wraps, so
    the result is still a [proven_fact] derived from an existing one. *)
val pass_through : (proof_expr -> proof_expr) -> proven_fact -> proven_fact

(** Structural rule: introduce a conjunction from two established facts (introAnd). *)
val conj_intro : proven_fact -> proven_fact -> proven_fact

(** Read-only projection to the concrete proof, for matching / rendering.  There is
    intentionally no inverse — you cannot turn a [proof_expr] back into a
    [proven_fact] except through the admission rules above. *)
val fact_of : proven_fact -> proof_expr
