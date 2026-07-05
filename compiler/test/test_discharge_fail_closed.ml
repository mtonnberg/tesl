(** DISCHARGE-FAIL-CLOSED — the invariant the unified discharge judgment must hold.

    A forgery-restricted function (fn/handler/worker) that DECLARES a proof-carrying
    return but whose body does NOT establish that proof for the returned value MUST
    be rejected — across every return form (RetAttached, RetNamedPack, RetMaybe*,
    RetExists) and every "not-carrying" body shape (literal, arithmetic on an
    unproven value, an attached foreign fact, a bare constructor).

    This is a black-box characterization test over {!Compile.check_module}: it pins
    the current (already-hardened) accept/reject behaviour so the in-flight refactor
    that collapses the ~9 discharge walkers into one fail-closed judgment cannot
    silently regress any of these into acceptance.  It is the dual of the positive
    corpus (which the ci.sh Validate phase pins): here every program must REJECT.

    Each module's header matches the parse file name so the reject is attributable
    to the discharge gate, never to the module-header/file-name lint. *)

open Alcotest

let error_diags (ds : Compile.diagnostic list) =
  List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") ds

(* A program that must be REJECTED for a proof reason (>=1 error diagnostic whose
   message is NOT merely the module-header/file-name mismatch lint). *)
let must_reject label src =
  match Parser.parse_module "forge.tesl" src with
  | Err e -> failf "%s: expected a parseable program, got parse error: %s" label e.Parser.msg
  | Ok m ->
    let errs = error_diags (Compile.check_module src m) in
    let non_filename =
      List.filter (fun (d : Compile.diagnostic) ->
        let re = Str.regexp_case_fold "module header" in
        (try ignore (Str.search_forward re d.message 0); false with Not_found -> true))
        errs
    in
    if non_filename = [] then
      failf "%s: expected the checker to REJECT this forged proof return, but it \
             was accepted (no non-lint error diagnostic).\nProgram:\n%s" label src

(* Shared preamble: a fact and a consumer that trusts it, so an accepted forgery
   would be exploitable.  `Forge` matches the parse file name `forge.tesl`. *)
let prog body_decls =
  "#lang tesl\n\
   module Forge exposing []\n\
   import Tesl.Prelude exposing [Int, String, Bool(..)]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n\
   fact IsPositive (n: Int)\n\
   check mkPos(n: Int) -> n: Int ::: IsPositive n =\n\
  \  if n > 0 then\n\
  \    ok n ::: IsPositive n\n\
  \  else\n\
  \    fail 400 \"no\"\n\
   fn needPositive(p: Int ::: IsPositive p) -> Int =\n\
  \  p\n" ^ body_decls

(* ── RetAttached ─────────────────────────────────────────────────────────── *)

let t_attached_literal_no_scope () =
  must_reject "RetAttached literal, no in-scope proof"
    (prog "fn forge(n: Int) -> r: Int ::: IsPositive r =\n  42\n")

let t_attached_arith_wrong_subject () =
  must_reject "RetAttached returns unproven arithmetic (binder != param)"
    (prog "fn forge(x: Int ::: IsPositive x) -> r: Int ::: IsPositive r =\n  0 - 5\n")

let t_attached_binder_collision () =
  (* The C1 forgery class: return binder collides with a proof-carrying param,
     body returns a different unproven value. *)
  must_reject "RetAttached binder-collision launder"
    (prog "fn forge(x: Int ::: IsPositive x) -> x: Int ::: IsPositive x =\n  0 - 999\n")

(* ── RetNamedPack (`? P`) ────────────────────────────────────────────────── *)

let t_pack_literal () =
  must_reject "RetNamedPack literal"
    (prog "fn forge(n: Int) -> Int ? IsPositive =\n  42\n")

let t_pack_foreign_fact_launder () =
  (* The C2 forgery class: attach a fact about a sibling onto the returned value. *)
  must_reject "RetNamedPack foreign-fact launder"
    (prog "fn forge(dummy: Int, p: Int ::: IsPositive p) -> Int ? IsPositive =\n  dummy ::: detachFact p\n")

(* ── RetMaybeAttached (`Maybe (v: T ::: P v)`) ───────────────────────────── *)

let t_maybe_unproven_success () =
  must_reject "RetMaybeAttached unproven success payload"
    (prog "fn forge(n: Int) -> Maybe (v: Int ::: IsPositive v) =\n  Something 42\n")

(* ── RetExists (`exists w => …`) ─────────────────────────────────────────── *)

let t_exists_literal_pack () =
  must_reject "RetExists literal packed body"
    (prog "fn forge(n: Int) -> exists wit: String => Int ? IsPositive =\n  let wit = \"w-1\"\n  exists wit =>\n    42\n")

let () =
  run "Discharge-Fail-Closed" [
    "return-forms must reject a non-carrying body", [
      test_case "RetAttached literal (no scope)" `Quick t_attached_literal_no_scope;
      test_case "RetAttached unproven arithmetic" `Quick t_attached_arith_wrong_subject;
      test_case "RetAttached binder-collision (C1)" `Quick t_attached_binder_collision;
      test_case "RetNamedPack literal" `Quick t_pack_literal;
      test_case "RetNamedPack foreign-fact launder (C2)" `Quick t_pack_foreign_fact_launder;
      test_case "RetMaybeAttached unproven success" `Quick t_maybe_unproven_success;
      test_case "RetExists literal pack" `Quick t_exists_literal_pack;
    ];
  ]
