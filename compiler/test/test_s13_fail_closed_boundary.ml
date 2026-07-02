(** S13 — fail-closed runtime boundary type checks.

    The runtime function [runtime-type-satisfied?] (dsl/types.rkt) used to fail
    OPEN when a type had no registered runtime predicate: every unregistered
    concrete type-key (`Bogus`, an unregistered record, …) was silently
    accepted at a retained §7.10 boundary position (param / return / payload).
    S13 registers the residual reachable types and flips the default to
    fail-closed:

      - Surface aliases Int/Bool/Float (passed as bare symbols by hand-written
        stdlib .rkt files) map to integer?/boolean?/real?.
      - Genuinely-unconstrained Unit/Fact register an explicit always-true
        predicate (fail-open by intent: `-> Unit` returns (void)/DB results;
        Fact carries an erased proof).
      - Type VARIABLES (lowercase-initial names) keep fail-open by construction.
      - Every other concrete type with no predicate now fails CLOSED.

    S13-full ADDS the root fix that made the flip safe: [runtime-type-predicate]
    now resolves a `type-ref` STRUCT to its bare NAME before the registry
    lookups.  Previously a type-ref (every user record/ADT/newtype, plus the
    built-in ADTs like DeleteResult) missed the registry — its owner differs from
    the registration site — so every type-ref reached the no-predicate default
    with the checks DORMANT, and closing there would have rejected valid returns.
    With resolution on, the registered record/ADT/newtype/built-in predicate IS
    found, so a mismatched value against a KNOWN type is rejected by the
    predicate, and only a genuinely UNKNOWN concrete type falls through to the
    now-closed default.

    The POSITIVE half below confirms the flip does not break the two constructs
    the naive flip broke — side-effecting `-> Unit` handlers and polymorphic
    (type-variable) returns — and that the emitter still annotates them
    (`#:returns Unit` / `#:returns a`).  The NEGATIVE half ([fail_closed]
    section) drives the runtime directly: it runs a Racket snippet against
    dsl/types.rkt asserting that (a) a mismatched value vs a registered
    record/ADT/newtype type-ref is REJECTED, (b) a legit record/ADT/newtype/Unit/
    DeleteResult value PASSES, (c) a type variable PASSES, and (d) an unknown
    concrete type-ref fails CLOSED. *)

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

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-s13" "" in
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

let contains ~needle haystack =
  let re = Str.regexp_string needle in
  try ignore (Str.search_forward re haystack 0); true with Not_found -> false

(* --check exits 0. *)
let should_check src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected --check success, got:\n%s" out)

(* --check exits 0 AND compiling to Racket emits [needle] in the output. *)
let should_check_and_emit needle src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected --check success, got:\n%s" out;
    let ecode, emitted = run_compiler [path] in
    if ecode <> 0 then failf "expected emit success, got:\n%s" emitted;
    if not (contains ~needle emitted) then
      failf "expected emitted Racket to contain %S, got:\n%s" needle emitted)

(* ── Fail-closed runtime proof: drive dsl/types.rkt directly via racket ─────── *)

(* Locate the repo root so we can [require] dsl/types.rkt from the racket snippet. *)
let repo_root =
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some p when p <> "" -> p
  | _ ->
    let rec find dir =
      let candidate = Filename.concat dir "dsl" in
      if (try Sys.is_directory candidate with _ -> false) then dir
      else
        let parent = Filename.dirname dir in
        if parent = dir then Filename.current_dir_name else find parent
    in
    find (Filename.dirname Sys.argv.(0))

let racket_available =
  let code, _ = run_command "command -v racket >/dev/null 2>&1; echo $?" in
  code = 0

(* The runtime proof.  Each [chk] asserts a concrete runtime-type-satisfied?
   verdict.  A type-ref carrying a FOREIGN owner (as an emitted handler-return
   type would) is constructed with make-prefab-struct, exactly the shape the
   compiler emits, so this exercises the cross-module resolution path directly. *)
let fail_closed_proof_snippet = {|#lang racket
(require "dsl/types.rkt")
(define (mk-ref owner name) (make-prefab-struct 'type-ref owner name))
(define ok #t)
(define (chk label got want)
  (unless (equal? got want)
    (set! ok #f)
    (eprintf "MISMATCH ~a => ~s (want ~s)\n" label got want))
  (printf "  ~a => ~s (want ~s) ~a\n" label got want (if (equal? got want) "OK" "MISMATCH")))
(define-record Widget [id : Integer] [name : String])
(define-adt Color [Red] [Green] [Blue])
(define-newtype Score Integer)
(define w (Widget #:id 1 #:name "hi"))
(define c Green)
(define sc (Score 10))
;; (a) mismatched value vs a REGISTERED record/ADT/newtype type-ref => #f
(chk "mismatch 42 vs record Widget"   (runtime-type-satisfied? (mk-ref 'foreign 'Widget) 42) #f)
(chk "mismatch str vs ADT Color"      (runtime-type-satisfied? (mk-ref 'foreign 'Color) "s") #f)
(chk "mismatch 99 vs newtype Score"   (runtime-type-satisfied? (mk-ref 'foreign 'Score) 99) #f)
;; (b) legit record/ADT/newtype/Unit/DeleteResult value => #t (no over-rejection)
(chk "legit record Widget"            (runtime-type-satisfied? (mk-ref 'foreign 'Widget) w) #t)
(chk "legit ADT Color"                (runtime-type-satisfied? (mk-ref 'foreign 'Color) c) #t)
(chk "legit newtype Score"            (runtime-type-satisfied? (mk-ref 'foreign 'Score) sc) #t)
(chk "legit Unit (void)"              (runtime-type-satisfied? (mk-ref 'foreign 'Unit) (void)) #t)
(chk "legit DeleteResult NoRow"       (runtime-type-satisfied? (mk-ref 'foreign 'DeleteResult) NoRowDeleted) #t)
(chk "legit DeleteResult Rows"        (runtime-type-satisfied? (mk-ref 'foreign 'DeleteResult) (RowsDeleted 3)) #t)
;; (c) type VARIABLE (lowercase-initial) => #t (fail-open by construction)
(chk "type-var a vs 42"               (runtime-type-satisfied? 'a 42) #t)
(chk "type-var ref b vs str"          (runtime-type-satisfied? (mk-ref 'foreign 'b) "x") #t)
;; (d) UNKNOWN concrete type with no predicate => #f (the newly-closed hole)
(chk "unknown concrete Bogus ref"     (runtime-type-satisfied? (mk-ref 'foreign 'Bogus) 42) #f)
(chk "unknown concrete Bogus sym"     (runtime-type-satisfied? 'Bogus 42) #f)
(printf "FAIL-CLOSED PROOF: ~a\n" (if ok "ALL PASS" "FAILED"))
(exit (if ok 0 1))
|}

let test_S13_fail_closed_runtime_proof () =
  if not racket_available then
    (* The gate always has racket; a bare dune-test box may not.  Skip cleanly
       there rather than fail — the gate step still enforces this. *)
    ()
  else begin
    let path = Filename.concat repo_root "tesl-s13-fail-closed-proof.rkt" in
    let oc = open_out path in
    output_string oc fail_closed_proof_snippet; close_out oc;
    Fun.protect
      ~finally:(fun () -> try Sys.remove path with _ -> ())
      (fun () ->
        let cmd =
          Printf.sprintf "cd %s && racket %s 2>&1"
            (Filename.quote repo_root) (Filename.quote (Filename.basename path))
        in
        let code, out = run_command cmd in
        if code <> 0 || not (contains ~needle:"FAIL-CLOSED PROOF: ALL PASS" out) then
          failf "runtime fail-closed proof failed (exit %d):\n%s" code out)
  end

(* ── Unit return: side-effecting handler stays green under the flip ─────────── *)

let test_S13_unit_return_compiles () =
  (* A `-> Unit` function returns a runtime (void)/side-effect value, never the
     'Unit symbol.  With Unit registered as always-true it fails OPEN by intent;
     the naive flip (no registration) would have rejected this. *)
  should_check_and_emit "#:returns Unit" {|
module DesignS13Unit exposing [logIt]
import Tesl.Prelude exposing [String, Unit]

fn logIt(msg: String) -> Unit =
  print msg
|}

(* ── Polymorphic return: type-variable stays green under the flip ──────────── *)

let test_S13_polymorphic_return_compiles () =
  (* `-> a` is a type VARIABLE (lowercase-initial); type-variable-key? keeps it
     fail-open.  These are the stdlib return heads (maximum/minimum/foldr) that
     the naive flip broke with 4 `returned a value that does not satisfy
     declared return type … a|b` errors. *)
  should_check_and_emit "#:returns a" {|
module DesignS13Poly exposing [firstOr]
import Tesl.Prelude exposing [List]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.List exposing [List.head]

fn firstOr(xs: List a, dflt: a) -> a =
  case List.head xs of
    Something v -> v
    Nothing -> dflt
|}

let test_S13_polymorphic_param_emits_typevar () =
  (* The polymorphic parameter is emitted as `[dflt : a]` — a bare type var at a
     boundary position; confirms the param path also carries the type var
     through so the runtime sees the unconstrained key, not a concrete one. *)
  should_check_and_emit "[dflt : a]" {|
module DesignS13Poly2 exposing [firstOr]
import Tesl.Prelude exposing [List]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.List exposing [List.head]

fn firstOr(xs: List a, dflt: a) -> a =
  case List.head xs of
    Something v -> v
    Nothing -> dflt
|}

(* ── Concrete registered return still compiles (no over-rejection) ─────────── *)

let test_S13_concrete_return_still_compiles () =
  should_check {|
module DesignS13Concrete exposing [ident]
import Tesl.Prelude exposing [Int]

fn ident(x: Int) -> Int =
  x
|}

let () =
  run "s13-fail-closed-boundary" [
    "positive", [
      test_case "-> Unit compiles and emits #:returns Unit" `Quick test_S13_unit_return_compiles;
      test_case "polymorphic fn compiles and emits #:returns a" `Quick test_S13_polymorphic_return_compiles;
      test_case "polymorphic param emits [dflt : a]" `Quick test_S13_polymorphic_param_emits_typevar;
      test_case "concrete registered return still compiles" `Quick test_S13_concrete_return_still_compiles;
    ];
    "fail_closed", [
      test_case "runtime rejects mismatch, accepts legit record/ADT/newtype/Unit/DeleteResult, accepts type-var, closes unknown"
        `Quick test_S13_fail_closed_runtime_proof;
    ];
  ]
