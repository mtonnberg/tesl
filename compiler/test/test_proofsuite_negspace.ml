(** ProofSuite family P — NEGATIVE-SPACE umbrella ("forgot to validate" /
    proof laundering).  The BULK family.

    Proves the STATIC checker closes every "forgot to validate" / laundering
    hole with NO runtime net.  Combinatorial matrix built with [List.concat_map]:

        laundering mistake  ×  caller context  ×  predicate template

    plus a separate raw-arg sweep across every CONSUMER kind.

    predicate templates : 6 single-/two-arg predicates (uniform Int shape)
    caller contexts     : fn / handler / worker body
    consumer kinds       : fn / handler / worker / record-field
                          (entity-field is NOT statically enforced — see family
                           O — and server endpoints fail structurally, not via
                           V001 — so those are covered by targeted cases)
    mistakes            : raw-arg / wrong-proof / forgotten-check (inline check)
                          / alias-launder / partial-app-launder
                          / lambda-callback-launder

    Hardening: [should_fail] additionally fails on any runtime-leak marker —
    every laundering attempt must be rejected STATICALLY.

    Verified error strings (all `error[V001]:`):
      raw-arg / wrong-proof  → "does not statically satisfy declared proof `<P> <subj>`"
      forgotten-check        → "requires proof `<P> n`, but the argument is an expression with no trackable subject"
      alias / partial-app    → "alias `f` of proof-requiring function `<fn>` cannot be passed around — …"
      lambda-callback        → "function `<fn>` requires proof annotations on its parameters and cannot be passed as a plain callback; …" *)

open Alcotest

(* ── Harness (self-contained, kebab-case filenames, runtime-leak hardening) ── *)

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

let file_name_of_src content =
  let re = Str.regexp "\\(module\\|library\\)[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
  try
    ignore (Str.search_forward re content 0);
    let mname = Str.matched_group 2 content in
    let buf = Buffer.create (String.length mname + 4) in
    String.iteri (fun i c ->
      if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
      else if c >= 'A' && c <= 'Z' then
        (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
      else Buffer.add_char buf c) mname;
    Buffer.contents buf ^ ".tesl"
  with Not_found -> "test.tesl"

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-psP" "" in
  let path = Filename.concat dir (file_name_of_src content) in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let leak_markers = [
  "raise-user-error"; "check-fail"; "context...:"; "context ...:";
  ".rkt:"; "racket/"; "/collects/"; "errortrace"; "uncaught exception";
]

let assert_no_runtime_leak pat out =
  List.iter (fun m ->
    let re = Str.regexp_string m in
    if (try ignore (Str.search_forward re out 0); true with Not_found -> false)
    then failf "STATIC-REJECTION VIOLATED for %S: output contains runtime-leak \
                marker %S:\n%s" pat m out)
    leak_markers

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected static failure matching %S, but compiled \
                            cleanly:\n%s" pat out;
    assert_no_runtime_leak pat out;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    let has_err =
      let re = Str.regexp "error\\[" in
      try ignore (Str.search_forward re out 0); true with Not_found -> false in
    if code <> 0 || has_err then
      failf "expected clean compile, got (exit %d):\n%s" code out)

(* ── Predicate templates ──────────────────────────────────────────────────── *)
(* Each defines a fact + producer `check` + names, all over Int so the matrix
   bodies share a uniform shape. *)

type predicate = {
  p_id    : string;   (* unique infix for module names *)
  p_fact  : string;   (* fact predicate name *)
  p_check : string;   (* the check function name *)
  p_decls : string;   (* fact + check decl block *)
}

let mk_pred id fact check cond = {
  p_id = id; p_fact = fact; p_check = check;
  p_decls = Printf.sprintf {|
fact %s (n: Int)
check %s(n: Int) -> n: Int ::: %s n =
  if %s then
    ok n ::: %s n
  else
    fail 400 "%s"
|} fact check fact cond fact (String.lowercase_ascii fact);
}

let predicates = [
  mk_pred "Pos" "Positive"  "checkPositive"  "n > 0";
  mk_pred "Bnd" "Bounded"   "checkBounded"   "n < 100";
  mk_pred "Evn" "Evenish"   "checkEvenish"   "n % 2 == 0 || n % 2 == 1";
  mk_pred "Nat" "Natural"   "checkNatural"   "n >= 0";
  mk_pred "Big" "Largeish"  "checkLargeish"  "n > 1000";
  mk_pred "Tin" "Tinyish"   "checkTinyish"   "n < 10";
  mk_pred "Nz"  "Nonzeroish" "checkNonzeroish" "n != 0";
  mk_pred "Rng" "InRangeish" "checkInRangeish" "n >= 0 && n <= 255";
  mk_pred "Odd" "Oddish"    "checkOddish"    "n % 2 == 1 || n % 2 == 0";
]

(* A distinct "other" predicate used only for the wrong-proof mistake. *)
let other_pred_decls = {|
fact OtherPred (n: Int)
check checkOther(n: Int) -> n: Int ::: OtherPred n =
  if n > 0 then
    ok n ::: OtherPred n
  else
    fail 400 "other"
|}

(* ── Caller contexts ──────────────────────────────────────────────────────── *)
(* The offending caller body wraps the mistake in fn / handler / worker.  Each
   carrier takes the offending statements (a body with `_result` bound to the
   bad expression) and produces the enclosing declaration. *)

type caller = {
  k_id      : string;
  k_extra   : string;                 (* extra decls needed (e.g. JobRec) *)
  (* [k_wrap lets last] : enclose [lets] (let-lines) + a final value [last]. *)
  k_wrap    : string -> string -> string;
}

(* fn: returns Int. *)
let caller_fn = {
  k_id = "fn"; k_extra = "";
  k_wrap = (fun lets last ->
    Printf.sprintf "fn caller(raw: Int, xs: List Int) -> Int =\n%s  %s" lets last);
}

let caller_handler = {
  k_id = "handler"; k_extra = "";
  k_wrap = (fun lets last ->
    Printf.sprintf "handler caller(raw: Int, xs: List Int) -> Int requires [] =\n%s  %s" lets last);
}

let caller_worker = {
  k_id = "worker"; k_extra = "record JobRec { raw: Int }";
  (* worker must return its job; we compute the bad expr into a discarded let. *)
  k_wrap = (fun lets last ->
    Printf.sprintf
      "worker caller(j: JobRec) requires [] =\n  let raw = j.raw\n  let xs = [j.raw]\n%s  let _result = %s\n  j"
      lets last);
}

let callers = [ caller_fn; caller_handler; caller_worker ]

(* ── Mistakes ─────────────────────────────────────────────────────────────── *)
(* Each mistake is (extra top-level decls, let-lines, final-bad-expr, regex,
   extra-imports), all parameterised by the predicate. *)

type mistake = {
  m_id    : string;
  m_pat   : string;
  m_imp   : string;
  (* given predicate -> (extra top-level decls, let-lines, bad-final-expr) *)
  m_parts : predicate -> (string * string * string);
}

let m_raw_arg = {
  m_id = "raw-arg"; m_pat = "does not statically satisfy declared proof";
  m_imp = "";
  m_parts = (fun p ->
    Printf.sprintf "fn requires%s(n: Int ::: %s n) -> Int = n" p.p_fact p.p_fact,
    "",
    Printf.sprintf "requires%s raw" p.p_fact);
}

let m_wrong_proof = {
  m_id = "wrong-proof"; m_pat = "does not statically satisfy declared proof";
  m_imp = "";
  m_parts = (fun p ->
    Printf.sprintf "%s\nfn requires%s(n: Int ::: %s n) -> Int = n"
      other_pred_decls p.p_fact p.p_fact,
    "  let q = check checkOther raw\n",
    Printf.sprintf "requires%s q" p.p_fact);
}

let m_forgotten_check = {
  m_id = "forgotten-check";
  m_pat = "requires proof.*but the argument is an expression with no trackable subject";
  m_imp = "";
  m_parts = (fun p ->
    Printf.sprintf "fn requires%s(n: Int ::: %s n) -> Int = n" p.p_fact p.p_fact,
    "",
    Printf.sprintf "requires%s (check %s raw)" p.p_fact p.p_check);
}

let m_alias_launder = {
  m_id = "alias-launder"; m_pat = "cannot be passed around";
  m_imp = "";
  m_parts = (fun p ->
    Printf.sprintf "fn requires%s(n: Int ::: %s n) -> Int = n\nfn applyIt(g: Int -> Int, x: Int) -> Int = g x"
      p.p_fact p.p_fact,
    Printf.sprintf "  let f = requires%s\n" p.p_fact,
    "applyIt f raw");
}

let m_partial_app_launder = {
  m_id = "partial-app-launder"; m_pat = "cannot be passed around";
  m_imp = "";
  m_parts = (fun p ->
    Printf.sprintf "fn requiresSecond%s(a: Int, n: Int ::: %s n) -> Int = a + n\nfn applyIt(g: Int -> Int, x: Int) -> Int = g x"
      p.p_fact p.p_fact,
    Printf.sprintf "  let g = requiresSecond%s 10\n" p.p_fact,
    "applyIt g raw");
}

let m_lambda_callback_launder = {
  m_id = "lambda-callback-launder"; m_pat = "cannot be passed as a plain callback";
  m_imp = "\nimport Tesl.List exposing [List.map]";
  m_parts = (fun p ->
    Printf.sprintf "fn requires%s(n: Int ::: %s n) -> Int = n" p.p_fact p.p_fact,
    "",
    Printf.sprintf "List.map requires%s xs" p.p_fact);
}

let mistakes =
  [ m_raw_arg; m_wrong_proof; m_forgotten_check;
    m_alias_launder; m_partial_app_launder; m_lambda_callback_launder ]

(* sanitise an id into a CamelCase module fragment. *)
let camel s =
  String.split_on_char '-' s
  |> List.map String.capitalize_ascii
  |> String.concat ""

(* ── The 3-D matrix: mistake × caller × predicate ─────────────────────────── *)

let launder_matrix =
  List.concat_map (fun m ->
    List.concat_map (fun k ->
      List.map (fun p ->
        Printf.sprintf "P-%s/%s/%s" m.m_id k.k_id p.p_fact,
        (fun () ->
           let decls, lets, bad = m.m_parts p in
           let extra = if k.k_extra = "" then "" else k.k_extra ^ "\n" in
           should_fail m.m_pat
             (Printf.sprintf {|
#lang tesl
module P%s%s%s exposing []
import Tesl.Prelude exposing [Int, List]%s
%s
%s
%s%s
|} (camel m.m_id) (String.capitalize_ascii k.k_id) p.p_id
   m.m_imp p.p_decls decls extra (k.k_wrap lets bad))))
        predicates)
      callers)
    mistakes

(* ── Consumer-kind sweep: raw-arg into a record field (the consumer-kind
      dimension, distinct from caller-kind) ─────────────────────────────────── *)

(* record-field consumer: build from raw across each predicate. *)
let record_field_raw_sweep =
  List.map (fun p ->
    Printf.sprintf "P-record-field-raw/%s" p.p_fact,
    (fun () ->
       should_fail "does not statically satisfy declared proof"
         (Printf.sprintf {|
#lang tesl
module PRecField%s exposing []
import Tesl.Prelude exposing [Int]
%s
record Box {
  v: Int ::: %s v
}
fn caller(raw: Int) -> Box =
  Box { v: raw }
|} p.p_id p.p_decls p.p_fact)))
    predicates

(* ── Targeted laundering variants (beyond the matrix) ─────────────────────── *)

let base_p_block = {|
fact P (n: Int)
check checkP(n: Int) -> n: Int ::: P n =
  if n > 0 then
    ok n ::: P n
  else
    fail 400 "p"
fn requiresP(n: Int ::: P n) -> Int = n
|}

let test_P_lambda_wrap_does_not_launder () =
  should_fail "does not statically satisfy declared proof"
    (Printf.sprintf {|
#lang tesl
module PLamWrap exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.map]
%s
fn caller(xs: List Int) -> List Int =
  List.map (fn(x: Int) -> requiresP x) xs
|} base_p_block)

let test_P_inline_lambda_proof_param () =
  should_fail "does not statically satisfy declared proof\\|<lambda>"
    {|
#lang tesl
module PInlineLam exposing []
import Tesl.Prelude exposing [Int]
fact P (n: Int)
check checkP(n: Int) -> n: Int ::: P n =
  if n > 0 then
    ok n ::: P n
  else
    fail 400 "p"
fn caller(raw: Int) -> Int =
  (fn(n: Int ::: P n) -> n) raw
|}

let test_P_explicit_wrong_subject_attach () =
  should_fail "does not statically satisfy declared proof\\|different subject"
    (Printf.sprintf {|
#lang tesl
module PWrongSubj exposing []
import Tesl.Prelude exposing [Int]
%s
fn caller(raw: Int, other: Int) -> Int =
  let p = check checkP other
  requiresP raw
|} base_p_block)

let test_P_chain_drops_proof () =
  should_fail "does not statically satisfy declared proof"
    (Printf.sprintf {|
#lang tesl
module PChainDrop exposing []
import Tesl.Prelude exposing [Int]
%s
fn mid(n: Int ::: P n) -> Int = requiresP n
fn caller(raw: Int) -> Int =
  mid raw
|} base_p_block)

let test_P_alias_returned () =
  (* Returning the alias (passing it out of the fn) also launders. *)
  should_fail "cannot be passed around"
    (Printf.sprintf {|
#lang tesl
module PAliasRet exposing []
import Tesl.Prelude exposing [Int]
%s
fn leak() -> (Int -> Int) =
  let f = requiresP
  f
|} base_p_block)

let test_P_double_alias () =
  (* Aliasing the alias still gets caught. *)
  should_fail "cannot be passed around"
    (Printf.sprintf {|
#lang tesl
module PDoubleAlias exposing []
import Tesl.Prelude exposing [Int]
%s
fn applyIt(g: Int -> Int, x: Int) -> Int = g x
fn caller(raw: Int) -> Int =
  let f = requiresP
  let h = f
  applyIt h raw
|} base_p_block)

(* ── Positive companions ──────────────────────────────────────────────────── *)

let test_Ppos_fn_checked () =
  should_pass (Printf.sprintf {|
#lang tesl
module PposFn exposing []
import Tesl.Prelude exposing [Int]
%s
fn caller(raw: Int) -> Int =
  let c = check checkP raw
  requiresP c
|} base_p_block)

let test_Ppos_fn_passthrough_param () =
  should_pass (Printf.sprintf {|
#lang tesl
module PposParam exposing []
import Tesl.Prelude exposing [Int]
%s
fn caller(n: Int ::: P n) -> Int =
  requiresP n
|} base_p_block)

let test_Ppos_handler_checked () =
  should_pass (Printf.sprintf {|
#lang tesl
module PposHandler exposing []
import Tesl.Prelude exposing [Int]
%s
handler h(raw: Int) -> Int requires [] =
  let c = check checkP raw
  requiresP c
|} base_p_block)

let test_Ppos_worker_checked () =
  should_pass (Printf.sprintf {|
#lang tesl
module PposWorker exposing []
import Tesl.Prelude exposing [Int]
%s
record JobRec { n: Int }
worker w(j: JobRec) requires [] =
  let c = check checkP j.n
  let _x = requiresP c
  j
|} base_p_block)

let test_Ppos_record_checked () =
  should_pass (Printf.sprintf {|
#lang tesl
module PposRecord exposing []
import Tesl.Prelude exposing [Int]
%s
record Box {
  v: Int ::: P v
}
fn caller(raw: Int) -> Box =
  let c = check checkP raw
  Box { v: c }
|} base_p_block)

let test_Ppos_callback_named_wrapper () =
  should_pass (Printf.sprintf {|
#lang tesl
module PposCallback exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.map]
%s
fn safeWrap(x: Int) -> Int =
  let c = check checkP x
  requiresP c
fn caller(xs: List Int) -> List Int =
  List.map safeWrap xs
|} base_p_block)

let test_Ppos_partial_app_nonproof_leading () =
  should_pass (Printf.sprintf {|
#lang tesl
module PposPartial exposing []
import Tesl.Prelude exposing [Int]
%s
fn withTag(tag: Int, n: Int ::: P n) -> Int = tag + n
fn caller(raw: Int) -> Int =
  let c = check checkP raw
  withTag 7 c
|} base_p_block)

let test_Ppos_filtercheck_partial_check () =
  should_pass {|
#lang tesl
module PposFilterCheck exposing []
import Tesl.Prelude exposing [Int, List, Bool(..)]
import Tesl.List exposing [List.filterCheck]
fact InRange (lo: Int, hi: Int, n: Int)
check checkInRange(lo: Int, hi: Int, n: Int) -> n: Int ::: InRange lo hi n =
  if n >= lo && n <= hi then
    ok n ::: InRange lo hi n
  else
    fail 400 "range"
fn caller(xs: List Int) -> List Int =
  List.filterCheck (checkInRange 0 100) xs
|}

let test_Ppos_chain_passthrough () =
  should_pass (Printf.sprintf {|
#lang tesl
module PposChain exposing []
import Tesl.Prelude exposing [Int]
%s
fn mid(n: Int ::: P n) -> Int = requiresP n
fn caller(raw: Int) -> Int =
  let c = check checkP raw
  mid c
|} base_p_block)

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let to_cases lst = List.map (fun (n, f) -> test_case n `Quick f) lst

let positive_cases = [
  "Ppos fn checked", test_Ppos_fn_checked;
  "Ppos fn passthrough param", test_Ppos_fn_passthrough_param;
  "Ppos handler checked", test_Ppos_handler_checked;
  "Ppos worker checked", test_Ppos_worker_checked;
  "Ppos record checked", test_Ppos_record_checked;
  "Ppos callback named wrapper", test_Ppos_callback_named_wrapper;
  "Ppos partial-app non-proof leading", test_Ppos_partial_app_nonproof_leading;
  "Ppos filterCheck partial check", test_Ppos_filtercheck_partial_check;
  "Ppos chain passthrough", test_Ppos_chain_passthrough;
]

let targeted_cases = [
  "P lambda-wrap does not launder", test_P_lambda_wrap_does_not_launder;
  "P inline lambda proof param", test_P_inline_lambda_proof_param;
  "P explicit wrong-subject attach", test_P_explicit_wrong_subject_attach;
  "P chain drops proof at final hop", test_P_chain_drops_proof;
  "P alias returned out of fn", test_P_alias_returned;
  "P double alias", test_P_double_alias;
]

let () =
  run "ProofSuite-P-NegSpace" [
    "P-launder-matrix-mistake-x-caller-x-predicate", to_cases launder_matrix;
    "P-record-field-raw-sweep", to_cases record_field_raw_sweep;
    "P-targeted-laundering-variants", to_cases targeted_cases;
    "P-positive-companions", to_cases positive_cases;
  ]
