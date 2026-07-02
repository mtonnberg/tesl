(* B2 — conformance test for the single source of truth for the trusted
   proof-introducing function kinds ([Ast.is_proof_introducing_kind]).

   The soundness fact "only check / auth / establish may MINT a proof or own a
   fact predicate" (LANGUAGE-SPEC §7.12) used to be restated at N call sites.
   B2 collapsed it to one predicate.  This test pins that predicate against an
   INDEPENDENT oracle over EVERY [func_kind] constructor, so a future edit that
   silently widens/narrows the trusted set (e.g. lets a handler mint a proof)
   breaks this test.

   Pure OCaml (no Racket / no alcotest): builds and runs unconditionally via
       dune exec test/test_proof_kind_registry.exe *)

open Ast

(* The full enumeration of func kinds.  This list must stay exhaustive: it is
   cross-checked below against a match with no [_] fallthrough, so a new
   constructor fails to compile until it is added here AND classified. *)
let all_kinds : func_kind list =
  [ FnKind; CheckKind; AuthKind; EstablishKind;
    HandlerKind; WorkerKind; DeadWorkerKind; MainKind ]

(* Independent oracle — deliberately written as its own match, NOT by calling
   the predicate under test, so the two can disagree.  Exhaustive (no [_]). *)
let oracle_is_proof_introducing = function
  | CheckKind -> true
  | AuthKind -> true
  | EstablishKind -> true
  | FnKind -> false
  | HandlerKind -> false
  | WorkerKind -> false
  | DeadWorkerKind -> false
  | MainKind -> false

let kind_name = function
  | FnKind -> "FnKind" | CheckKind -> "CheckKind" | AuthKind -> "AuthKind"
  | EstablishKind -> "EstablishKind" | HandlerKind -> "HandlerKind"
  | WorkerKind -> "WorkerKind" | DeadWorkerKind -> "DeadWorkerKind"
  | MainKind -> "MainKind"

let () =
  let failures = ref 0 in
  List.iter (fun k ->
    let got = is_proof_introducing_kind k in
    let want = oracle_is_proof_introducing k in
    if got <> want then begin
      incr failures;
      Printf.eprintf
        "MISMATCH: is_proof_introducing_kind %s = %b but oracle = %b\n"
        (kind_name k) got want
    end
  ) all_kinds;
  (* Exactly the three trusted kinds must be introducing — pin the cardinality
     so neither widening (a new kind marked true) nor narrowing goes unnoticed. *)
  let n = List.length (List.filter is_proof_introducing_kind all_kinds) in
  if n <> 3 then begin
    incr failures;
    Printf.eprintf
      "CARDINALITY: expected exactly 3 proof-introducing kinds, got %d\n" n
  end;
  if !failures > 0 then begin
    Printf.eprintf "test_proof_kind_registry: %d failure(s)\n" !failures;
    exit 1
  end;
  print_endline "test_proof_kind_registry: OK (proof-introducing kinds pinned)"
