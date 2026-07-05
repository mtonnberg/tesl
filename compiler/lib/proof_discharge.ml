(** Unified proof-obligation discharge — the obligation model (foundation).

    This module is the front half of the discharge-unification refactor
    (~/.claude/plans/synthetic-watching-thunder.md).  Return-side proof checking is
    currently spread across ~9 divergent return-leaf walkers (in validation_advanced
    / validation_proof / validation_capabilities) plus a second pipeline
    (proof_checker.ml).  Several of those copies historically FAILED OPEN, which is
    where the 2026-07-05 forgery class lived.

    [normalize] is the SINGLE, exhaustive translation from a function's declared
    [return_spec] to the list of proof OBLIGATIONS its body must discharge.  Every
    return-side check will route through obligations produced here, so there is one
    place that knows all return forms and one fail-closed default.  Because the match
    over [return_spec] is total (the whole compiler builds with `-warn-error +8`),
    adding a new return form without deciding its obligation is a BUILD error, not a
    silent discharge-to-nothing — fail-closed by construction.

    The verifiers that CONSUME these obligations (the single Carry/Mint/Framework
    leaf judgment, and the dispatched ForAll/Existential sub-judgments) land in
    subsequent phases; this phase fixes the vocabulary and the exhaustive front door. *)

open Ast
open Location

(** Which direction an obligation is checked in.  The same return form yields a
    different judgment depending on the function KIND — this axis is orthogonal to
    the return shape, which is why it is a field of its own. *)
type judgment =
  | Carry
      (** a forgery-restricted kind (fn / handler / worker / deadWorker / main): the
          returned value must CONTENT-CARRY the declared proof; it may not mint one. *)
  | Mint
      (** a boundary kind (check / auth / establish): the body MINTS the proof; the
          obligation is that the minted [ok v ::: P] matches the declared spec. *)

(** What value the obligation is about. *)
type target =
  | ReturnedValue      (** the single returned value (RetAttached / RetNamedPack / RetPlain-Fact) *)
  | MaybeSuccess       (** the success payload of a Maybe/Either wrapper (RetMaybeAttached) *)
  | ExistsPacked       (** the value packed under an existential witness (RetExists) *)
  | Elements           (** every element of a returned collection (RetForAll / RetSetForAll) *)
  | DictValues         (** every value of a returned Dict (RetForAllDictValues) *)
  | DictKeys           (** every key of a returned Dict (RetForAllDictKeys) *)

(** How the obligation is discharged.  [Framework] provenance
    (FromDb/FromQueue/FromDeadQueue) is established by a real DB/queue producing
    site, not by an ordinary carried proof. *)
type mode = Carried | Framework

(** Which returning leaves the obligation applies to.  RetMaybeAttached obliges only
    the success-constructor payload (not the [Nothing]/[Left] side); everything else
    obliges every returning leaf. *)
type leaf_scope = AllReturning | SuccessCtorPayloadOnly

type obligation = {
  judgment      : judgment;
  target        : target;
  required      : proof_expr;    (** the proof that must hold; binder / [_entity] unresolved *)
  binder        : string option; (** the return binder naming the subject, when present *)
  entity_group  : bool;          (** a `? P` entity group ([_entity]-appended): enables the
                                     sound arg-order reorder in the verifier *)
  leaves        : leaf_scope;
  mode          : mode;
  loc           : loc;
}

let judgment_of_kind : func_kind -> judgment = function
  | CheckKind | AuthKind | EstablishKind -> Mint
  | FnKind | HandlerKind | WorkerKind | DeadWorkerKind | MainKind -> Carry

let is_framework_pred = function
  | "FromDb" | "FromQueue" | "FromDeadQueue" -> true
  | _ -> false

let rec leaf_preds (p : proof_expr) : string list =
  match p with
  | PredApp { pred; _ } -> [pred]
  | PredAnd { left; right; _ } -> leaf_preds left @ leaf_preds right

let mode_of_proof (p : proof_expr) : mode =
  if List.exists is_framework_pred (leaf_preds p) then Framework else Carried

(** The single, exhaustive [return_spec -> obligation list] front door.  A form with
    no proof content (a bare `-> T`, or a `check`/`auth` without an annotation) yields
    the empty list; every proof-bearing form yields one obligation per declared proof.
    Total over [return_spec] — a new constructor forces a decision here. *)
let rec normalize (kind : func_kind) (rs : return_spec) : obligation list =
  let j = judgment_of_kind kind in
  let mk ?(entity_group = false) ?(leaves = AllReturning) ~target ~required ~binder ~loc () =
    { judgment = j; target; required; binder; entity_group; leaves;
      mode = mode_of_proof required; loc }
  in
  match rs with
  | RetPlain { ty; loc } ->
    (* `-> T` carries a proof only when T is a `Fact (…)` type; otherwise no proof. *)
    (match Validation_common.proof_of_fact_type ty with
     | Some p -> [ mk ~target:ReturnedValue ~required:p ~binder:None ~loc () ]
     | None -> [])
  | RetAttached { binding = b; loc } ->
    (match b.proof_ann with
     | Some p -> [ mk ~target:ReturnedValue ~required:p ~binder:(Some b.name) ~loc () ]
     | None -> [])
  | RetNamedPack { entity_proof; other_proof; loc; _ } ->
    (match entity_proof with
     | Some p -> [ mk ~target:ReturnedValue ~required:p ~binder:None ~entity_group:true ~loc () ]
     | None -> [])
    @ (match other_proof with
       | Some p -> [ mk ~target:ReturnedValue ~required:p ~binder:None ~loc () ]
       | None -> [])
  | RetMaybeAttached { binding = b; loc; _ } ->
    (match b.proof_ann with
     | Some p -> [ mk ~target:MaybeSuccess ~required:p ~binder:(Some b.name)
                     ~leaves:SuccessCtorPayloadOnly ~loc () ]
     | None -> [])
  | RetForAll { proof; loc; _ } | RetSetForAll { proof; loc; _ } ->
    [ mk ~target:Elements ~required:proof ~binder:None ~loc () ]
  | RetMaybeForAll { proof; loc; _ } | RetMaybeSetForAll { proof; loc; _ } ->
    [ mk ~target:Elements ~required:proof ~binder:None ~loc () ]
  | RetForAllDictValues { proof; loc; _ } ->
    [ mk ~target:DictValues ~required:proof ~binder:None ~loc () ]
  | RetForAllDictKeys { proof; loc; _ } ->
    [ mk ~target:DictKeys ~required:proof ~binder:None ~loc () ]
  | RetExists { body; loc; _ } ->
    (* The packed value must discharge the inner return spec's proofs, retargeted to
       the existentially-packed value. *)
    List.map (fun o -> { o with target = ExistsPacked; loc }) (normalize kind body)
