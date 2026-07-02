(** A4 — literal proof-subject per-occurrence identity.

    A proof earned about ONE literal value must NOT be reusable for a SECOND,
    independently-authored identical literal (a provenance/taint forgery).  The
    fix gives every literal VALUE occurrence a fresh, user-unspellable subject
    keyed by source location (`lit#<basename>:line:col`), while recovering the
    literal's CONTENT for content-parameter positions so content facts (e.g.
    `Clamped 1 100 n`, `HasMin 10 n`, `Named "http" port`) still match.

    These tests assert the STATIC checker (`tesl --check`) rejects the leaks
    WITHOUT running the program (proofs are erased — no runtime backstop), and
    that the legitimate content-parameter patterns still compile. *)

open Alcotest

(* ── Compiler-path resolution (same discipline as test_proofsuite_attack) ───── *)

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

let check_subcmd =
  if Filename.basename compiler = "main.exe" then "--check" else "check"

let run_command cmd =
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  let code = match status with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n -> 128 + n | Unix.WSTOPPED n -> 128 + n
  in (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

(* Derive the on-disk file name from the `module <Name>` header so the compiler's
   file-name↔module resolution is satisfied (kebab-cases the PascalCase name). *)
let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-a4-lit" "" in
  let name =
    let re = Str.regexp "\\(module\\|library\\)[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 2 content in
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

(* Static-rejection leaked to runtime → test failure (the whole point is a
   compile-time reject, never a Racket execution). *)
let runtime_leak_markers =
  [ "raise-user-error"; "check-fail"; ".rkt:"; "/racket/"; "raco " ]

let assert_no_runtime_leak ~who out =
  List.iter (fun marker ->
    let re = Str.regexp_string marker in
    match Str.search_forward re out 0 with
    | _ -> failf "%s: rejection LEAKED TO RUNTIME (found %S).\nFull output:\n%s" who marker out
    | exception Not_found -> ()
  ) runtime_leak_markers

let should_fail ?(who = "should_fail") pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler [check_subcmd; path] in
    assert_no_runtime_leak ~who out;
    if code = 0 then failf "%s: expected failure matching %S, but compiled cleanly.\nOutput:\n%s" who pat out;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "%s: expected failure matching %S, got:\n%s" who pat out)

let should_pass ?(who = "should_pass") src =
  with_temp_file src (fun path ->
    let code, out = run_compiler [check_subcmd; path] in
    let has_error =
      let re = Str.regexp "error\\[" in
      try ignore (Str.search_forward re out 0); true with Not_found -> false
    in
    if has_error || code <> 0 then
      failf "%s: expected clean compile, got (exit %d):\n%s" who code out)

(* Shared diagnostic-family regexes. *)
let subject_mismatch =
  "does not statically satisfy\\|different.*subject\\|about a different\\|\
   describes a different\\|proof subject mismatch\\|requires proof"

(* ════════════════════════════════════════════════════════════════════════ *)
(* NEGATIVE — provenance/taint forgery via a re-used literal proof.           *)
(* ════════════════════════════════════════════════════════════════════════ *)

(* A proof about literal "admin" cannot be reused for a SECOND, independently
   written "admin" literal (the sharp `<| … ::: pf` leak). *)
let test_string_literal_reuse_rejected () =
  should_fail ~who:"lit-string-reuse" subject_mismatch {|
#lang tesl
module LitLeakStr exposing [attack]
import Tesl.Prelude exposing [String, Fact]
fact Audited (s: String)
establish audit(s: String) -> Fact (Audited s) = Audited s
fn runPrivileged(cmd: String ::: Audited cmd) -> String = cmd
fn attack() -> String =
  let pf = audit "admin"
  runPrivileged <| "admin" ::: pf
|}

(* attachFact variant: `attachFact "admin" proofAboutTheOtherAdmin` rejected. *)
let test_attachfact_string_literal_mismatch_rejected () =
  should_fail ~who:"lit-attachfact-str" subject_mismatch {|
#lang tesl
module LitLeakAttach exposing [attack]
import Tesl.Prelude exposing [String, Fact, attachFact]
fact Audited (s: String)
establish audit(s: String) -> Fact (Audited s) = Audited s
fn runPrivileged(cmd: String ::: Audited cmd) -> String = cmd
fn attack() -> String =
  let auditedOnce = audit "admin"
  runPrivileged (attachFact "admin" auditedOnce)
|}

(* Int-literal provenance leak: prove Sanitized about one `42`, attach to a
   second `42`, feed a consumer requiring Sanitized on that value. *)
let test_int_literal_leak_rejected () =
  should_fail ~who:"lit-int-leak" subject_mismatch {|
#lang tesl
module LitLeakInt exposing [attack]
import Tesl.Prelude exposing [Int, Fact, attachFact]
fact Sanitized (n: Int)
establish san(n: Int) -> Fact (Sanitized n) = Sanitized n
fn need(n: Int ::: Sanitized n) -> Int = n
fn attack() -> Int =
  let pf = san 42
  need (attachFact 42 pf)
|}

(* ════════════════════════════════════════════════════════════════════════ *)
(* PROPERTY — occurrence, not value, is identity.                             *)
(* ════════════════════════════════════════════════════════════════════════ *)

(* Value-EQUAL but occurrence-DISTINCT: a proof about the literal 42 written at
   one site cannot satisfy a requirement whose subject is a literal 42 written
   at another site.  (Guards against reverting to the old text key.) *)
let test_value_equal_occurrence_distinct_rejected () =
  should_fail ~who:"prop-occ-distinct" subject_mismatch {|
#lang tesl
module PropOccDistinct exposing [attack]
import Tesl.Prelude exposing [Int, Fact, attachFact]
fact Sanitized (n: Int)
establish san(n: Int) -> Fact (Sanitized n) = Sanitized n
fn need42(n: Int ::: Sanitized 42) -> Int = n
fn attack() -> Int =
  let pf = san 42
  need42 (attachFact 42 pf)
|}

(* Value-DISTINCT: prove about 41, require about 42 → reject. *)
let test_value_distinct_rejected () =
  should_fail ~who:"prop-value-distinct" subject_mismatch {|
#lang tesl
module PropValueDistinct exposing [attack]
import Tesl.Prelude exposing [Int, Fact, attachFact]
fact Sanitized (n: Int)
establish san(n: Int) -> Fact (Sanitized n) = Sanitized n
fn need42(n: Int ::: Sanitized 42) -> Int = n
fn attack() -> Int =
  let pf = san 41
  need42 (attachFact 42 pf)
|}

(* ════════════════════════════════════════════════════════════════════════ *)
(* POSITIVE — content-parameter facts (literal in a LEADING position, variable *)
(* subject) still compile.  Rejection must be specificity, not blanket refusal. *)
(* ════════════════════════════════════════════════════════════════════════ *)

(* HasMin 10 n: literal `10` as content param, checked value is the subject. *)
let test_content_fact_hasmin_ok () =
  should_pass ~who:"content-hasmin" {|
#lang tesl
module ContentHasMin exposing [t]
import Tesl.Prelude exposing [Int, Bool(..), Fact]
fact HasMin (lo: Int) (n: Int)
check checkMin10(n: Int) -> n: Int ::: HasMin 10 n =
  if n >= 10 then
    ok n ::: HasMin 10 n
  else
    fail 400 "no"
fn needAbove10(n: Int ::: HasMin 10 n) -> Int = n
fn t(raw: Int) -> Int =
  let v = check checkMin10 raw
  needAbove10 v
|}

(* `let lo = 1` content-param alignment: Clamped 1 100 n accepts when lo=1. *)
let test_let_lo_1_clamped_ok () =
  should_pass ~who:"clamped-lo1-ok" {|
#lang tesl
module ClampedLo1Ok exposing [ok1]
import Tesl.Prelude exposing [Int, Bool(..), Fact]
fact Clamped (lo: Int) (hi: Int) (n: Int)
check checkClamped(lo: Int, hi: Int, n: Int) -> n: Int ::: Clamped lo hi n =
  if lo <= n && n <= hi then
    ok n ::: Clamped lo hi n
  else
    fail 400 "no"
fn needC(n: Int ::: Clamped 1 100 n) -> Int = n
fn ok1(raw: Int) -> Int =
  let lo = 1
  let hi = 100
  let v = check checkClamped lo hi raw
  needC v
|}

(* `let lo = 2` variant: content 2 != required 1 → REJECTED (content precision
   preserved: the leading content-param position is still compared by CONTENT). *)
let test_let_lo_2_clamped_rejected () =
  should_fail ~who:"clamped-lo2-bad" "does not statically satisfy\\|Clamped 1 100"
    {|
#lang tesl
module ClampedLo2Bad exposing [bad2]
import Tesl.Prelude exposing [Int, Bool(..), Fact]
fact Clamped (lo: Int) (hi: Int) (n: Int)
check checkClamped(lo: Int, hi: Int, n: Int) -> n: Int ::: Clamped lo hi n =
  if lo <= n && n <= hi then
    ok n ::: Clamped lo hi n
  else
    fail 400 "no"
fn needC(n: Int ::: Clamped 1 100 n) -> Int = n
fn bad2(raw: Int) -> Int =
  let lo = 2
  let hi = 100
  let v = check checkClamped lo hi raw
  needC v
|}

(* String content-tag (lesson53 Part 2): Named "http" port with a VARIABLE
   subject compiles — the `"http"` is a leading content param, `port` the subject. *)
let test_string_content_tag_ok () =
  should_pass ~who:"content-strtag" {|
#lang tesl
module ContentStrTag exposing [testStringTag]
import Tesl.Prelude exposing [Int, String, Fact]
fact Named (name: String) (port: Int)
establish proveHttp(port: Int) -> Fact (Named "http" port) = Named "http" port
fn needHttp(port: Int ::: Named "http" port) -> Int = port
fn testStringTag(raw: Int) -> Int =
  let pf = proveHttp raw
  needHttp <| raw ::: pf
|}

(* Content-fact with a literal content param AND a variable subject established
   via `check` then consumed — a legitimate provenance chain that must compile. *)
let test_content_fact_variable_subject_ok () =
  should_pass ~who:"content-var-subject" {|
#lang tesl
module ContentVarSubject exposing [flow]
import Tesl.Prelude exposing [Int, Bool(..), Fact]
fact HasMin (lo: Int) (n: Int)
check checkMin10(n: Int) -> n: Int ::: HasMin 10 n =
  if n >= 10 then
    ok n ::: HasMin 10 n
  else
    fail 400 "no"
fn needAbove10(n: Int ::: HasMin 10 n) -> Int = n
fn flow(raw: Int) -> Int =
  let v = check checkMin10 raw
  let w = needAbove10 v
  w
|}

(* ── Suite registration ───────────────────────────────────────────────────── *)

let () =
  run "A4-LiteralSubjectIdentity" [
    "negative-leaks", [
      test_case "identical String literal proof reuse rejected" `Quick test_string_literal_reuse_rejected;
      test_case "attachFact String literal-subject mismatch rejected" `Quick test_attachfact_string_literal_mismatch_rejected;
      test_case "Int literal provenance leak rejected" `Quick test_int_literal_leak_rejected;
    ];
    "occurrence-not-value", [
      test_case "value-equal occurrence-distinct subject rejected" `Quick test_value_equal_occurrence_distinct_rejected;
      test_case "value-distinct subject rejected" `Quick test_value_distinct_rejected;
    ];
    "positive-content-facts", [
      test_case "HasMin 10 n content-fact ok" `Quick test_content_fact_hasmin_ok;
      test_case "let lo=1 Clamped 1 100 n ok" `Quick test_let_lo_1_clamped_ok;
      test_case "let lo=2 Clamped variant rejected (content 2!=1)" `Quick test_let_lo_2_clamped_rejected;
      test_case "Named \"http\" port string content-tag ok" `Quick test_string_content_tag_ok;
      test_case "content fact with variable subject flow ok" `Quick test_content_fact_variable_subject_ok;
    ];
  ]
