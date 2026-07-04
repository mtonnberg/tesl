(* LCF-style proof kernel — see proof_kernel.mli for the contract.

   [proven_fact] is a transparent alias for [proof_expr] HERE, but the .mli makes it
   abstract, so no other module can pattern-match it into existence or build one with
   a raw [PredApp]/[PredAnd].  The only ways to obtain a [proven_fact] are the
   admission rules below.  Keep this module dependency-free (opens only [Ast]) so the
   trusted surface stays auditable in one sitting. *)

open Ast

type proven_fact = proof_expr

let proof_loc = function
  | PredApp { loc; _ } | PredAnd { loc; _ } -> loc

let mint_at_boundary (kind : func_kind) (p : proof_expr) : proven_fact option =
  match kind with
  | CheckKind | AuthKind | EstablishKind -> Some p
  (* Every non-minting kind is refused — fail-closed.  Enumerated (not `_`) so a
     future func_kind forces an explicit admit/refuse decision here. *)
  | FnKind | HandlerKind | WorkerKind | DeadWorkerKind | MainKind -> None

let framework_provenance (p : proof_expr) : proven_fact = p

let assume_param (p : proof_expr) : proven_fact = p

let pass_through (subst : proof_expr -> proof_expr) (pf : proven_fact) : proven_fact =
  subst pf

let conj_intro (a : proven_fact) (b : proven_fact) : proven_fact =
  PredAnd { left = a; right = b; loc = proof_loc a }

let fact_of (pf : proven_fact) : proof_expr = pf
