(** A6 — remove the `body_returns_named` spelling carve-out from checker.ml's
    T001 forgery gate; content-based V001 is the SOLE proof-return forgery decider.

    The former checker.ml gate admitted a fn/handler/worker proof-carrying return
    whenever the body syntactically returned a variable/field whose NAME matched
    the return binder (`body_returns_named`).  That is decide-by-spelling: a body
    could bind `let n = raw; n` (or `attachFact x <unrelated>; y`) and forge an
    arbitrary return proof.  It was sound only because the content-based V001 gate
    (Validation_advanced.check_fn_return_proof_annotations) also ran and rejected.

    After A6 the carve-out is gone.  These tests pin the two properties that must
    hold with V001 as the single source of truth:

      1. Forgeries are STILL rejected (by V001, decided over proof CONTENT):
         (a) spelling forgery `let n = raw; n`
         (b) attachFact-of-unrelated-fact `attachFact x w` where `w` carries a
             different predicate than the return claims.

      2. The one rule T001 uniquely enforced is PRESERVED — an UNNAMED
         proof-carrying return (`-> Type ::: Pred`, parsed with the synthetic
         `_entity` binder) is still rejected even when its body legitimately
         carries the proof (V001 alone ACCEPTS this, so deleting the block
         blindly would regress — the review47 shape):
         (c) unnamed proof-carrying return whose body carries the proof.

    And the two legitimate patterns must STILL compile (no over-rejection —
    field-access passthrough empirically depended on the deleted carve-out):
      (d) NAMED body-introduced proof via establish + attachFact (PC04 shape)
      (e) field-access passthrough. *)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    (match Sys.getenv_opt "TESL_BIN" with
     | Some v when Filename.basename v = "main.exe" && Sys.file_exists v -> v
     | _ ->
       let dir = Filename.dirname Sys.argv.(0) in
       let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
       let candidate2 = Filename.concat dir "../bin/main.exe" in
       if Sys.file_exists candidate then candidate
       else if Sys.file_exists candidate2 then candidate2
       else "tesl")

let run_command cmd =
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  let code = match status with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n -> 128+n | Unix.WSTOPPED n -> 128+n
  in (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

(* The compiler resolves a module by its file name, so the temp file must be
   named after the `module X` header (kebab-cased) or a spurious V001
   name-mismatch error masks the property under test. *)
let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-a6" "" in
  let name =
    let re = Str.regexp "module[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 1 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
        else Buffer.add_char buf c
      ) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected success, got:\n%s" out)

(* [pat] is a (case-insensitive) regexp; keep patterns free of regexp specials so
   they read as the literal guarantee. *)
let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but succeeded" pat;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

(* ── (a) spelling forgery — STILL rejected by content-based V001 ──────────── *)

(* `let n = raw; n` binds a fresh value to the return binder's NAME and returns
   it; the old carve-out admitted it by name equality.  V001 decides by content:
   `n` carries no `Positive` proof, so it stays rejected. *)
let test_a6_spelling_forgery_still_rejected () =
  should_fail "cannot declare a proof return type" {|
#lang tesl
module A6ForgeSpelling exposing [forge]
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fn forge(raw: Int) -> n: Int ::: Positive n =
  let n = raw
  n
|}

(* ── (b) attachFact-of-unrelated-fact — STILL rejected by content-based V001 ─ *)

(* The body attaches `Whatever` but the return claims `IsPositive`.  The old gate
   admitted the return because the body returned a variable named `y`; V001
   resolves `attachFact x w` to `w`'s actual predicate (`Whatever`), which does
   not match the declared `IsPositive`, so it stays rejected. *)
let test_a6_attachfact_unrelated_still_rejected () =
  should_fail "cannot declare a proof return type" {|
#lang tesl
module A6ForgeAttach exposing [forge]
import Tesl.Prelude exposing [Int, Fact, attachFact]
fact Whatever (n: Int)
fact IsPositive (n: Int)
establish makeWhatever(n: Int) -> Fact (Whatever n) =
  Whatever n
fn forge(x: Int) -> y: Int ::: IsPositive y =
  let w = makeWhatever x
  let y = attachFact x w
  y
|}

(* ── (c) unnamed proof-carrying return — the PRESERVED well-formedness rule ── *)

(* review47 shape: the body legitimately carries the proof (V001 ACCEPTS it),
   but the return is UNNAMED (`-> Int ::: Positive n`, parsed with the synthetic
   `_entity` binder).  This is the one rule the old T001 block uniquely enforced;
   A6 preserves it as a spelling-free binder-identity check.  Blind deletion of
   the block would make this COMPILE — the regression guard. *)
let test_a6_unnamed_proof_return_still_rejected () =
  should_fail "proof-carrying return type must name its binding" {|
#lang tesl
module A6Unnamed exposing [f]
import Tesl.Prelude exposing [Int, Fact, attachFact]
fact Positive (n: Int)
establish prove(n: Int) -> Fact (Positive n) =
  Positive n
fn f(n: Int) -> Int ::: Positive n =
  let p = prove n
  attachFact n p
|}

(* ── (d) NAMED body-introduced proof (PC04) — must STILL compile ──────────── *)

(* A named return `y` whose body builds the proof via establish + attachFact is
   legitimate: `attachFact x p` carries `IsPositive` and V001 accepts it.  The
   body-local `y` is not in scope at gate time, so any content-aware tightening
   of the checker gate would over-reject — the fix relies on V001 instead. *)
let test_a6_named_body_introduced_proof_compiles () =
  should_pass {|
#lang tesl
module A6NamedOk exposing [good]
import Tesl.Prelude exposing [Int, Fact, attachFact]
fact IsPositive (n: Int)
establish makeIsPositive(n: Int) -> Fact (IsPositive n) =
  IsPositive n
fn good(x: Int) -> y: Int ::: IsPositive y =
  let p = makeIsPositive x
  let y = attachFact x p
  y
|}

(* ── (e) field-access passthrough — must STILL compile ────────────────────── *)

(* This pattern EMPIRICALLY depended on the deleted `body_returns_named` carve-out
   (short-circuiting that term made T001 fire).  V001 accepts it via the record
   field's proof annotation, so removing the carve-out must not over-reject it.
   The critical over-rejection guard. *)
let test_a6_field_access_passthrough_compiles () =
  should_pass {|
#lang tesl
module A6Field exposing [getAmount]
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
record R {
  amount: Int ::: Positive amount
}
fn getAmount(r: R) -> amount: Int ::: Positive amount =
  r.amount
|}

let () =
  run "A6 unnamed-proof-return / spelling-carve-out-removal" [
    "forgery-still-rejected", [
      test_case "spelling forgery rejected by V001" `Quick
        test_a6_spelling_forgery_still_rejected;
      test_case "attachFact-of-unrelated-fact rejected by V001" `Quick
        test_a6_attachfact_unrelated_still_rejected;
    ];
    "unnamed-well-formedness-preserved", [
      test_case "unnamed proof-carrying return rejected even when body carries proof" `Quick
        test_a6_unnamed_proof_return_still_rejected;
    ];
    "legitimate-still-compiles", [
      test_case "named body-introduced proof (PC04) compiles" `Quick
        test_a6_named_body_introduced_proof_compiles;
      test_case "field-access passthrough compiles" `Quick
        test_a6_field_access_passthrough_compiles;
    ];
  ]
