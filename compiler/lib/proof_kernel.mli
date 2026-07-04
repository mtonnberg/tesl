(** LCF-style proof kernel — close_fail_open Option B (the TCB-shrink capstone).

    This is the ONLY module that can construct a {!proven_fact}.  Every other module
    in the checker consumes [proven_fact]s (through {!fact_of}) but cannot fabricate
    one, because the type is abstract and there is no [proof_expr -> proven_fact]
    escape hatch OUTSIDE the enumerated admission rules below.  Consequently every
    place a fact can enter the trusted proof environment is a NAMED, greppable call
    to one of these rules — the fact-introduction surface collapses from the ~40k-line
    checker to this file plus the enumerable call sites of its rules.  A bug in the
    elaborator that does not go through a rule can only cause OVER-rejection (loud and
    fixable), never a forged proof.  This mirrors how LCF/Isabelle keep a tiny trusted
    kernel behind a large untrusted elaborator, and how Haskell-GDP gets a ~5-LOC TCB
    — but here the friendly, domain-aware diagnostics live in the (untrusted)
    elaborator, so shrinking the TCB costs nothing in error quality.

    The admission rules mirror Tesl's soundness model exactly:

    - {!mint_at_boundary} — a [check]/[auth]/[establish] call is TRUSTED to establish
      its declared return proof (the GDP smart-constructor boundary).  It returns
      [None] for every other {!Ast.func_kind}, so "a plain [fn]/[handler] mints a
      fresh proof" is unrepresentable through this rule (fail-closed by default).
    - {!framework_provenance} — FromDb/FromQueue/FromDeadQueue provenance, minted by
      the framework at a real DB/queue site (the caller verifies the site).
    - {!assume_param} — a proof-carrying PARAMETER's declared proof is assumed inside
      the body; sound because every call site must discharge it (via proof_matches).
    - {!pass_through} / {!conj_intro} / {!conj_elim_left} / {!conj_elim_right} —
      structural rules that DERIVE a fact from facts that already exist (re-subject a
      binding; introduce or eliminate a conjunction).  They take [proven_fact]s as
      input, so they cannot conjure a fact from nothing.
    - {!elaborated} — the residual trusted surface: a fact the (untrusted) carried-proof
      elaborator has read off explicit program structure (a [:::] annotation, an
      [attachFact] evidence, a record field's declared proof, a framework collection
      op, or a forgery-restricted function's verified pass-through return).  Each use is
      tagged with a {!evidence_origin} so the origin is self-documenting and greppable.
      This is the next tightening target — the remaining raw [proof_expr -> proven_fact]
      admission — but it is fully enumerable, which is the property Option B buys.

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

(** Structural rule: eliminate a conjunction to its LEFTMOST leaf conjunct
    (andLeft P&&Q ⇒ P).  Derived from an existing fact, so still sound. *)
val conj_elim_left : proven_fact -> proven_fact

(** Structural rule: eliminate a conjunction to its RIGHTMOST leaf conjunct
    (andRight P&&Q ⇒ Q).  Derived from an existing fact, so still sound. *)
val conj_elim_right : proven_fact -> proven_fact

(** Structural rule: split a (possibly nested) conjunction fact into ALL its leaf
    conjuncts (P && (Q && R) ⇒ [P; Q; R]).  Each leaf is derivable from the input by
    repeated conjunction-elimination, so every element is a genuine [proven_fact].
    Used where an `&&`-decomposition binds each conjunct to its own name. *)
val conj_split : proven_fact -> proven_fact list

(** The distinct explicit-program-structure origins the elaborator may read a carried
    proof off of.  Tagging {!elaborated} with one of these keeps every such admission
    self-documenting and greppable by origin. *)
type evidence_origin =
  | FieldProof          (** a record field's declared proof, credited only when the
                            receiver's resolved type is the type that declares it *)
  | AttachedEvidence    (** an explicit [:::] / [attachFact] proof the elaborator
                            resolved from program text *)
  | RestrictedReturn    (** a forgery-restricted function's declared return proof,
                            which §7.12 ([is_forgery_restricted_kind]) has verified is a
                            pass-through of an input proof or a framework provenance *)
  | FrameworkCollection (** a framework collection operation's synthesized proof
                            (List/Set filterCheck/allCheck ⇒ ForAll) *)

(** Admit a fact the untrusted carried-proof elaborator read off explicit program
    structure, tagged with its {!evidence_origin}.  This is the residual raw admission
    surface (see the module doc); it is enumerable, which is the audit property Option
    B provides. *)
val elaborated : evidence_origin -> proof_expr -> proven_fact

(** Read-only projection to the concrete proof, for matching / rendering.  There is
    intentionally no inverse — you cannot turn a [proof_expr] back into a
    [proven_fact] except through the admission rules above. *)
val fact_of : proven_fact -> proof_expr
