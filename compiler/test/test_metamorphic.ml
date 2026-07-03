(** VER-METAMORPHIC — systematic soundness hunting via fuzz + metamorphic invariance.

    Two oracle-free techniques that surface NEW checker defects automatically,
    complementing the generative NEGATIVE corpus ({!test_s7_generative}, the
    breaking direction) with the dual — a PRESERVING direction:

      Sub-part 1 — grammar-valid fuzz over `--check`.  Feed the frontend many
      grammar-valid programs (the accepted + rejected corpora, plus structural
      mutants of the proof/capability TCB via {!Mutate.generate_mutants}) and
      assert the checker never CRASHES or hangs.  It may accept or reject — but an
      uncaught OCaml exception / `failwith` / internal-invariant assertion is
      ALWAYS a bug.  Runs in-process on {!Compile.check_module}, so a crash is a
      catchable exception attributed to its input, not a lost subprocess exit code.

      Sub-part 2 — metamorphic invariance.  Apply a SEMANTICS-PRESERVING rewrite
      and assert the accept/reject verdict is UNCHANGED.  No known-good oracle
      needed: a verdict FLIP in either direction (accepted program rejected after
      the rewrite, or a rejected program laundered into acceptance) is a checker
      inconsistency.  Two rewrites, each sound *by construction* so a flip is a
      checker defect, never a transform artefact:

        (i)  insert an inert `let _ = 0` at a function body's head — references no
             identifier, binds a discard to a constant, so it cannot change
             meaning (roadmap: "insert an unused let");
        (ii) reorder two top-level function declarations — Tesl resolves
             signatures before bodies, so declaration order must not matter.

      Both are asserted over the accepted corpus AND a set of rejected fixtures
      (the inverse direction): a preserving rewrite must not flip a rejection
      either.  (α-rename — the classic third rewrite — is deliberately NOT used:
      Tesl proofs carry variable names by string in return-spec/`:::`/FromDb
      positions outside the ordinary expression tree, so a partial rename is not
      meaning-preserving and would manufacture false flips.  A proof-aware rename
      is future work; see roadmap.)

    Sub-part 3 (the retain-mode runtime proof-witness oracle) is deliberately NOT
    built here — it re-opens the erasure (S8/G7) architectural decision and needs
    an explicit go-ahead; see roadmap/next/metamorphic_testing.md.

    Coverage is LOGGED (programs fuzzed, transforms applied) and floored by an
    assertion, so a green run cannot silently mean "explored nothing". *)

open Alcotest
open Ast

(* ── In-process parse + check (mirrors test_s7_generative) ───────────────────*)

let error_diags (ds : Compile.diagnostic list) =
  List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") ds

(* A program's VERDICT: true = REJECTED (>=1 error diagnostic), false = accepted. *)
let is_rejected src (m : module_form) : bool =
  error_diags (Compile.check_module src m) <> []

(* Run the checker; report the exception if it CRASHED rather than returning a
   verdict.  The fuzzer's property: the checker is total on grammar-valid input. *)
let checker_crashed src (m : module_form) : exn option =
  match Compile.check_module src m with
  | _ -> None
  | exception e -> Some e

(* ── Semantics-preserving transforms (each sound by construction) ────────────*)

let synth_loc = Location.dummy_loc "tesl-metamorphic"

(* (i) Prepend an inert `let _ = 0` to the FIRST function's body.  A discard bound
   to a constant references nothing and changes no meaning. *)
let insert_noop_module (m : module_form) : (module_form * string) option =
  let noop body =
    ELet { name = "_"; declared_type = None; declared_proof = None;
           value = ELit { lit = LInt 0; loc = synth_loc };
           body; loc = synth_loc }
  in
  let rec go acc = function
    | [] -> None
    | DFunc fd :: rest ->
      Some ({ m with decls = List.rev_append acc (DFunc { fd with body = noop fd.body } :: rest) },
            fd.name)
    | d :: rest -> go (d :: acc) rest
  in
  go [] m.decls

(* (ii) Swap the first two top-level function declarations, leaving every other
   declaration in place.  Declaration order among functions must not affect the
   verdict (signatures are collected before bodies are checked). *)
let reorder_funcs_module (m : module_form) : (module_form * string) option =
  let func_idxs =
    List.mapi (fun i d -> (i, d)) m.decls
    |> List.filter_map (function (i, DFunc _) -> Some i | _ -> None)
  in
  match func_idxs with
  | i :: j :: _ ->
    let arr = Array.of_list m.decls in
    let tmp = arr.(i) in arr.(i) <- arr.(j); arr.(j) <- tmp;
    Some ({ m with decls = Array.to_list arr }, "reorder-funcs")
  | _ -> None

let transforms : (string * (module_form -> (module_form * string) option)) list =
  [ ("insert-unused-let", insert_noop_module);
    ("reorder-functions", reorder_funcs_module) ]

(* ── Corpus discovery (mirrors test_s7_generative) ───────────────────────────*)

let repo_root =
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some r -> Some r
  | None ->
    let rec up dir n =
      if n > 8 then None
      else if Sys.file_exists (Filename.concat dir "example") then Some dir
      else up (Filename.dirname dir) (n + 1)
    in
    up (Sys.getcwd ()) 0

let rec tesl_files dir : string list =
  match Sys.readdir dir with
  | exception _ -> []
  | entries ->
    Array.to_list entries
    |> List.concat_map (fun e ->
         let p = Filename.concat dir e in
         if (try Sys.is_directory p with _ -> false) then tesl_files p
         else if Filename.check_suffix p ".tesl" then [p]
         else [])

let corpus_files () : string list =
  match repo_root with
  | None -> []
  | Some root ->
    [ Filename.concat root "example"; Filename.concat root "tests" ]
    |> List.concat_map tesl_files
    |> List.sort_uniq String.compare

let read_file f = try In_channel.with_open_text f In_channel.input_all with _ -> ""

(* ── Rejected fixtures (for the inverse metamorphic direction) ────────────────
   Programs the checker MUST reject; each has >= 2 functions and a body statement,
   so both transforms have a site.  A preserving rewrite must keep them rejected. *)

let rejected_fixtures = [
  ("type-error", {|#lang tesl
module T exposing [f, g]
import Tesl.Prelude exposing [Int, String]
fn g(n: Int) -> Int = n
fn f(n: Int) -> String =
  let x = n
  x
|});
  ("unbound-use", {|#lang tesl
module T exposing [f, g]
import Tesl.Prelude exposing [Int]
fn g(n: Int) -> Int = n
fn f(n: Int) -> Int =
  let x = n
  x + missingVariable
|});
  ("capability-missing", {|#lang tesl
module T exposing [del, other]
import Tesl.Prelude exposing [String]
import Tesl.DB exposing [dbRead, dbWrite]
entity Row table "rows" primaryKey id { id: String }
fn other() -> String = "x"
fn del() -> String =
  let x = "ok"
  delete o from Row where o.id == "x"
  x
|});
]

(* ── Counters / assertions ───────────────────────────────────────────────────*)

let crash_counter = ref 0
let fuzz_counter = ref 0
let invariance_counter = ref 0

(* Fuzz one program (original + its structural mutants); assert no crash. *)
let fuzz_program name src (m : module_form) () =
  incr fuzz_counter;
  (match checker_crashed src m with
   | Some e -> incr crash_counter;
     failf "checker CRASHED on %s (original): %s" name (Printexc.to_string e)
   | None -> ());
  List.iter (fun (mut : Mutate.mutant) ->
    incr fuzz_counter;
    match checker_crashed src mut.module_ with
    | Some e -> incr crash_counter;
      failf "checker CRASHED on mutant of %s (%s): %s"
        name mut.description (Printexc.to_string e)
    | None -> ()
  ) (Mutate.generate_mutants m)

(* Metamorphic invariance for one (program, transform): verdict must not change. *)
let invariance name (transform_name, transform) src (m : module_form) () =
  match transform m with
  | None -> ()  (* transform has no site in this program *)
  | Some (m', _) ->
    let before = is_rejected src m in
    let after = is_rejected src m' in
    incr invariance_counter;
    if before <> after then
      failf "%s FLIPPED the verdict for %s: before=%s after=%s \
             (a semantics-preserving rewrite must not change accept/reject)"
        transform_name name
        (if before then "rejected" else "accepted")
        (if after then "rejected" else "accepted")

(* ── Test tree ───────────────────────────────────────────────────────────────*)

let () =
  let files = corpus_files () in
  let rel f = match repo_root with
    | Some root when String.length f > String.length root
                  && String.sub f 0 (String.length root) = root ->
      String.sub f (String.length root + 1) (String.length f - String.length root - 1)
    | _ -> f
  in
  let corpus_cases =
    List.filter_map (fun file ->
      match Compile.parse_module_file file with
      | None -> None
      | Some m ->
        let src = read_file file in
        let n = rel file in
        Some (n,
          test_case "fuzz: checker total (no crash)" `Quick (fuzz_program n src m)
          :: List.map (fun (tn, _ as t) ->
               test_case (Printf.sprintf "metamorphic: %s verdict-invariant" tn) `Quick
                 (invariance n t src m))
             transforms)
    ) files
  in
  let rejected_cases =
    List.map (fun (name, src) ->
      let m = match Parser.parse_module "tesl-metamorphic.tesl" src with
        | Ok m -> m
        | Err e -> failwith (Printf.sprintf "rejected fixture %s failed to parse: %s"
                               name e.Parser.msg)
      in
      (Printf.sprintf "rejected-%s" name,
        test_case "fixture is rejected (baseline)" `Quick
          (fun () -> check bool "rejected" true (is_rejected src m))
        :: test_case "fuzz: checker total (no crash)" `Quick (fuzz_program name src m)
        :: List.map (fun (tn, _ as t) ->
             test_case (Printf.sprintf "metamorphic: %s keeps it rejected" tn) `Quick
               (invariance name t src m))
           transforms)
    ) rejected_fixtures
  in
  let coverage_group =
    ("coverage", [
      test_case "harness exercised (fuzz + invariance)" `Quick (fun () ->
        Printf.printf
          "VER-METAMORPHIC: %d programs fuzzed (0 crashes), \
           %d metamorphic verdict-invariance checks\n%!"
          !fuzz_counter !invariance_counter;
        check bool "fuzzed >= 50 programs" true (!fuzz_counter >= 50);
        check bool "invariance checks >= 40" true (!invariance_counter >= 40);
        check int "zero checker crashes" 0 !crash_counter);
    ])
  in
  run "VER-Metamorphic" (corpus_cases @ rejected_cases @ [coverage_group])
