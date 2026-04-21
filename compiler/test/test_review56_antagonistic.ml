(** Antagonistic regression tests for Critical Review 56.

    This review audits the fixes from reviews 54 and 55:
    1. Integer/string literal proof subjects tracked correctly
    2. Ghost witness validation: Fact-type guard for fact_param_map
    3. fn field access proof passthrough works with AND conjunction
    4. Lambda in Set.filterCheck correctly rejected (parallel to List)
    5. W041 linter: no false positives on fn/check/handler declarations
    6. ForAll with literal-parametrized predicates (known limitation)
    7. Wrong literal bounds caught in proof satisfaction
    8. Establish with literal in return Fact type
    9. Mixed literal/variable subjects in multi-param proofs
    10. fn body passthrough via case expression
*)

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
  let code =
    match status with
    | Unix.WEXITED c -> c
    | Unix.WSIGNALED n -> 128 + n
    | Unix.WSTOPPED n -> 128 + n
  in
  (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file _prefix _suffix content f =
  let dir = Filename.temp_dir "tesl-r56" "" in
  let name =
    let re = Str.regexp "module[ \\t\\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 1 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then begin
          Buffer.add_char buf '-';
          Buffer.add_char buf (Char.lowercase_ascii c)
        end else
          Buffer.add_char buf c
      ) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  write_file path content;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_pass_src src =
  with_temp_file "tesl-r56" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let should_fail_src pattern src =
  with_temp_file "tesl-r56" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

let should_pass_lint src =
  with_temp_file "tesl-r56" ".tesl" src (fun path ->
    let code, out = run_compiler ["--lint"; path] in
    if code <> 0 then failf "expected lint success, got:\n%s" out)

let should_warn_lint pattern src =
  with_temp_file "tesl-r56" ".tesl" src (fun path ->
    let _code, out = run_compiler ["--lint"; path] in
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected lint warning matching %S, got:\n%s" pattern out)

let base_header = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Bool(..), List, Fact, forgetFact, attachFact, detachFact, introAnd]
import Tesl.Maybe exposing [Maybe(..)]
|}

(* ═══════════════════════════════════════════════════════════════════════════
   R56_LI — Literal proof subjects: correctness and safety
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R56_LI01 -- Wrong literal bounds correctly rejected *)
let r56_li01_wrong_literal_bounds_rejected () =
  should_fail_src "does not.*satisfy.*HasMin 10\\|HasMin 10.*raw" (
    base_header ^ {|
fact HasMin (lo: Int) (n: Int)

check checkAbove20(n: Int) -> n: Int ::: HasMin 20 n =
  if n >= 20 then
    ok n ::: HasMin 20 n
  else
    fail 400 "bad"

fn need10(n: Int ::: HasMin 10 n) -> Int = n

fn confuse(raw: Int) -> Int =
  let v = check checkAbove20 raw
  need10 v
|})

(* R56_LI02 -- Correct literal bounds accepted *)
let r56_li02_correct_literal_bounds_ok () =
  should_pass_src (base_header ^ {|
fact HasMin (lo: Int) (n: Int)

check checkAbove10(n: Int) -> n: Int ::: HasMin 10 n =
  if n >= 10 then
    ok n ::: HasMin 10 n
  else
    fail 400 "bad"

fn need10(n: Int ::: HasMin 10 n) -> Int = n

fn test(raw: Int) -> Int =
  let v = check checkAbove10 raw
  need10 v
|})

(* R56_LI03 -- String literal proof subjects work correctly *)
let r56_li03_string_literal_subjects () =
  should_pass_src (base_header ^ {|
fact Named (name: String) (port: Int)

establish proveHttp(port: Int) -> Fact (Named "http" port) =
  Named "http" port

fn needHttp(port: Int ::: Named "http" port) -> Int = port

fn test(raw: Int) -> Int =
  let pf = proveHttp raw
  needHttp <| raw ::: pf
|})

(* R56_LI04 -- Wrong string literal bound correctly rejected *)
let r56_li04_wrong_string_literal_rejected () =
  should_fail_src "does not.*satisfy.*Named.*https\\|Named.*https.*raw" (
    base_header ^ {|
fact Named (name: String) (port: Int)

establish proveHttp(port: Int) -> Fact (Named "http" port) =
  Named "http" port

fn needHttps(port: Int ::: Named "https" port) -> Int = port

fn test(raw: Int) -> Int =
  let pf = proveHttp raw
  needHttps <| raw ::: pf
|})

(* R56_LI05 -- Literal and variable subjects mixed in same proof *)
let r56_li05_mixed_literal_variable () =
  should_pass_src (base_header ^ {|
fact Clamped (lo: Int) (hi: Int) (n: Int)

check clampedDyn(lo: Int, hi: Int, n: Int) -> n: Int ::: Clamped lo hi n =
  if lo <= n && n <= hi then
    ok n ::: Clamped lo hi n
  else
    fail 400 "out of range"

fn needClamped1to100(n: Int ::: Clamped 1 100 n) -> Int = n

fn test(raw: Int) -> Int =
  let lo = 1
  let hi = 100
  let v = check clampedDyn lo hi raw
  needClamped1to100 v
|})

(* R56_LI06 -- Negative integer literal in proof works *)
let r56_li06_negative_literal () =
  should_pass_src (base_header ^ {|
fact AboveNeg100 (n: Int)

check checkAboveNeg100(n: Int) -> n: Int ::: AboveNeg100 n =
  if n >= -100 then
    ok n ::: AboveNeg100 n
  else
    fail 400 "too low"

fn needAboveNeg100(n: Int ::: AboveNeg100 n) -> Int = n

fn test(raw: Int) -> Int =
  let v = check checkAboveNeg100 raw
  needAboveNeg100 v
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R56_GW — Ghost witness: post-fix validation
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R56_GW01 -- Ghost witness happy path still works (regression) *)
let r56_gw01_ghost_witness_happy_path () =
  should_pass_src (base_header ^ {|
fact IsPositive (n: Int)
fact PriceExceedsQuantity (price: Int, quantity: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

check checkPQ(price: Int, quantity: Int) -> price: Int ::: PriceExceedsQuantity price quantity =
  if price > quantity then
    ok price ::: PriceExceedsQuantity price quantity
  else
    fail 422 "price must exceed quantity"

record OrderLine {
  price: Int ::: IsPositive price
  quantity: Int ::: IsPositive quantity
} ::: PriceExceedsQuantity price quantity

fn makeGood(p: Int ::: IsPositive p, q: Int ::: IsPositive q,
            pq: Int ::: PriceExceedsQuantity p q) -> OrderLine =
  OrderLine { price: p, quantity: q } ::: (detachFact pq)
|})

(* R56_GW02 -- Wrong ghost witness predicate correctly rejected (regression) *)
let r56_gw02_ghost_witness_wrong_predicate_rejected () =
  should_fail_src "ghost witness.*predicate.*mismatch\\|invariant requires.*PriceExceedsQuantity" (
    base_header ^ {|
fact IsPositive (n: Int)
fact PriceExceedsQuantity (price: Int, quantity: Int)
fact OtherFact (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

establish proveOther(n: Int) -> Fact (OtherFact n) = OtherFact n

record OrderLine {
  price: Int ::: IsPositive price
  quantity: Int ::: IsPositive quantity
} ::: PriceExceedsQuantity price quantity

fn makeBad(p: Int ::: IsPositive p, q: Int ::: IsPositive q) -> OrderLine =
  let wrong = proveOther p
  OrderLine { price: p, quantity: q } ::: (detachFact wrong)
|})

(* R56_GW03 -- Plain Int param does NOT contaminate ghost witness map (the bug we fixed) *)
let r56_gw03_int_param_no_ghost_contamination () =
  should_pass_src (base_header ^ {|
fact IsPositive (n: Int)
fact PriceExceedsQuantity (price: Int, quantity: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

check checkPQ(price: Int, quantity: Int) -> price: Int ::: PriceExceedsQuantity price quantity =
  if price > quantity then
    ok price ::: PriceExceedsQuantity price quantity
  else
    fail 422 "must exceed"

record OrderLine {
  price: Int ::: IsPositive price
  quantity: Int ::: IsPositive quantity
} ::: PriceExceedsQuantity price quantity

fn makeGood(p: Int ::: IsPositive p, q: Int ::: IsPositive q,
            pq: Int ::: PriceExceedsQuantity p q) -> OrderLine =
  OrderLine { price: p, quantity: q } ::: (detachFact pq)
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R56_FP — fn field access proof passthrough
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R56_FP01 -- Field access passthrough with simple proof works *)
let r56_fp01_field_passthrough_simple () =
  should_pass_src (base_header ^ {|
fact Positive (serial: Int)

record PositivePayload { serial: Int ::: Positive serial }

fn extractSerial(payload: PositivePayload) -> serial: Int ::: Positive serial =
  payload.serial
|})

(* R56_FP02 -- Field access passthrough with AND conjunction works *)
let r56_fp02_field_passthrough_and () =
  should_pass_src (base_header ^ {|
fact IsPositive (n: Int)
fact IsSmall    (n: Int)

record ValidItem { value: Int ::: IsPositive value && IsSmall value }

fn extractValue(item: ValidItem) -> value: Int ::: IsPositive value && IsSmall value =
  item.value
|})

(* R56_FP03 -- fn without field access still rejected for proof return *)
let r56_fp03_fn_no_field_no_proof_return () =
  should_fail_src "plain.*fn.*cannot.*declare.*proof\\|fn.*proof.*return" (
    base_header ^ {|
fact IsPositive (n: Int)

fn fakeProof(n: Int) -> n: Int ::: IsPositive n =
  n + 1
|})

(* R56_FP04 -- fn with FromDb return is allowed (infrastructure proof) *)
let r56_fp04_fn_fromdb_return_allowed () =
  should_pass_src (base_header ^ {|
import Tesl.DB exposing [dbRead]
entity Item table "items" primaryKey id { id: String }
fn getItem(i: String) -> item: Item ::: FromDb (Id == i) item
  requires [dbRead] =
  let existing = selectOne item from Item where item.id == i
  case existing of
    Nothing -> fail 404 "not found"
    Something item -> item
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R56_LA — Lambda filterCheck (Set and List) — both correctly rejected
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R56_LA01 -- Lambda in List.filterCheck rejected *)
let r56_la01_lambda_filtercheck_list_rejected () =
  should_fail_src "anonymous lambda.*filterCheck\\|lambda.*check.*kind\\|proof-carrying" (
    base_header ^ {|
import Tesl.List exposing [List.filterCheck, List.length]

fn test(xs: List Int) -> Int =
  let pos = List.filterCheck (fn(n: Int) -> n) xs
  List.length pos
|})

(* R56_LA02 -- Lambda in Set.filterCheck rejected *)
let r56_la02_lambda_filtercheck_set_rejected () =
  should_fail_src "anonymous lambda.*filterCheck\\|lambda.*check.*kind" (
    base_header ^ {|
import Tesl.Set exposing [Set, Set.filterCheck, Set.size]

fn test(xs: Set Int) -> Int =
  let pos = Set.filterCheck (fn(n: Int) -> n) xs
  Set.size pos
|})

(* R56_LA03 -- Named check function in filterCheck still works *)
let r56_la03_check_filtercheck_ok () =
  should_pass_src (base_header ^ {|
import Tesl.List exposing [List.filterCheck, List.length]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"

fn test(xs: List Int) -> Int =
  let pos = List.filterCheck checkPos xs
  List.length pos
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R56_LW — W041 linter: lambda in argument position
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R56_LW01 -- W041 fires for lambda in application arg position *)
let r56_lw01_w041_fires_on_lambda_arg () =
  should_warn_lint "W041\\|unparenthesized.*lambda" (
    base_header ^ {|
import Tesl.List exposing [List.map]
fn test(xs: List Int) -> List Int =
  List.map fn(n: Int) -> n + 1 xs
|})

(* R56_LW02 -- W041 does NOT fire on fn/check/handler declarations *)
let r56_lw02_w041_no_false_positive_decl () =
  should_pass_lint (base_header ^ {|
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn process(n: Int) -> Int = n + 1
fn nested(x: Int, y: Int) -> Int = x + y
|})

(* R56_LW03 -- W041 does NOT fire on lambda in let binding position *)
let r56_lw03_w041_no_false_positive_let () =
  should_pass_lint (base_header ^ {|
fn test() -> Int -> Int =
  let f = fn(n: Int) -> n + 1
  f
|})

(* R56_LW04 -- Parenthesized lambda in arg position: no warning *)
let r56_lw04_parens_lambda_no_warning () =
  should_pass_lint (base_header ^ {|
import Tesl.List exposing [List.map]
fn test(xs: List Int) -> List Int =
  List.map (fn(n: Int) -> n + 1) xs
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R56_FA — ForAll with literal predicate args (known limitation)
   ForAll predicates with literal arguments don't propagate correctly through
   filterCheck because normalize_carried_forall strips literal args to just
   the predicate name.
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R56_FA01 -- ForAll with no literal args works (baseline) *)
let r56_fa01_forall_no_literal_args () =
  should_pass_src (base_header ^ {|
import Tesl.List exposing [List.filterCheck, List.length]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn needAll(xs: List Int ::: ForAll IsPositive xs) -> Int = List.length xs
fn test(raw: List Int) -> Int =
  let pos = List.filterCheck checkPos raw
  needAll pos
|})

(* R56_FA02 -- ForAll with literal-parametrized predicate: now FIXED
   normalize_carried_forall and pred_str_from_check_chain now include literal
   args (e.g. "InRange 1 100") in the ForAll proof key, so the filterCheck
   result matches the declared ForAll (InRange 1 100) parameter annotation. *)
let r56_fa02_forall_literal_predicate_limitation () =
  should_pass_src (
    base_header ^ {|
import Tesl.List exposing [List.filterCheck, List.length]
fact InRange (lo: Int) (hi: Int) (n: Int)
check checkRange1to100(n: Int) -> n: Int ::: InRange 1 100 n =
  if 1 <= n && n <= 100 then
    ok n ::: InRange 1 100 n
  else
    fail 400 "out"
fn needAllSingle(x: Int ::: InRange 1 100 x) -> Int = x
fn needAll(xs: List Int ::: ForAll (InRange 1 100) xs) -> List Int = List.map (fn(x: Int ::: InRange 1 100 x) -> needAllSingle x)  xs
fn test(raw: List Int) -> List Int =
  let pos = List.filterCheck checkRange1to100 raw
  needAll pos
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R56_ES — Establish with literal in Fact return type
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R56_ES01 -- establish returning Fact with literal works *)
let r56_es01_establish_literal_fact () =
  should_pass_src (base_header ^ {|
fact Capped (max: Int) (n: Int)

establish proveAlwaysCapped(n: Int) -> Fact (Capped 9999 n) =
  Capped 9999 n

fn needCapped(n: Int ::: Capped 9999 n) -> Int = n

fn test(raw: Int) -> Int =
  let pf = proveAlwaysCapped raw
  needCapped <| raw ::: pf
|})

(* R56_ES02 -- establish returning wrong literal Fact rejected *)
let r56_es02_establish_wrong_literal_fact () =
  should_fail_src "does not.*satisfy.*Capped 100\\|Capped 100.*raw" (
    base_header ^ {|
fact Capped (max: Int) (n: Int)

establish prove9999(n: Int) -> Fact (Capped 9999 n) =
  Capped 9999 n

fn need100(n: Int ::: Capped 100 n) -> Int = n

fn test(raw: Int) -> Int =
  let pf = prove9999 raw
  need100 <| raw ::: pf
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R56_CA — fn body passthrough via case expression
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R56_CA01 -- case passthrough for FromDb (infrastructure proof) works *)
let r56_ca01_case_passthrough_fromdb () =
  should_pass_src (base_header ^ {|
import Tesl.DB exposing [dbRead]
entity Item table "items" primaryKey id { id: String }

fn getItem(i: String) -> item: Item ::: FromDb (Id == i) item
  requires [dbRead] =
  let existing = selectOne item from Item where item.id == i
  case existing of
    Nothing -> fail 404 "not found"
    Something item -> item
|})

(* R56_CA02 -- fn with case expression returning named variable works *)
let r56_ca02_case_field_access () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.DB exposing [dbRead]
entity Product table "products" primaryKey id { id: String }

fn getProduct(i: String) -> item: Product ::: FromDb (Id == i) item
  requires [dbRead] =
  let existing = selectOne item from Product where item.id == i
  case existing of
    Nothing -> fail 404 "not found"
    Something item -> item
|}

(* ═══════════════════════════════════════════════════════════════════════════
   R56_CH -- Combined check && with literal proof args
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R56_CH01 -- Combined check && with literal-param checks *)
let r56_ch01_combined_check_literal_preds () =
  should_pass_src (base_header ^ {|
import Tesl.List exposing [List.filterCheck, List.length]
fact HasMin (lo: Int) (n: Int)
fact HasMax (hi: Int) (n: Int)

check checkMin10(n: Int) -> n: Int ::: HasMin 10 n =
  if n >= 10 then
    ok n ::: HasMin 10 n
  else
    fail 400 "too low"

check checkMax100(n: Int) -> n: Int ::: HasMax 100 n =
  if n <= 100 then
    ok n ::: HasMax 100 n
  else
    fail 400 "too high"

fn needBothBounds(n: Int ::: HasMin 10 n && HasMax 100 n) -> Int = n

fn test(raw: Int) -> Int =
  let a = check checkMin10 raw
  let b = check checkMax100 a
  needBothBounds b
|})

(* ═══════════════════════════════════════════════════════════════════════════
   Test runner
   ═══════════════════════════════════════════════════════════════════════════ *)

let () =
  run "Review56-Antagonistic" [
    "literal-proof-subjects", [
      test_case "R56_LI01 wrong literal bounds rejected" `Quick r56_li01_wrong_literal_bounds_rejected;
      test_case "R56_LI02 correct literal bounds ok" `Quick r56_li02_correct_literal_bounds_ok;
      test_case "R56_LI03 string literal subjects" `Quick r56_li03_string_literal_subjects;
      test_case "R56_LI04 wrong string literal rejected" `Quick r56_li04_wrong_string_literal_rejected;
      test_case "R56_LI05 mixed literal and variable" `Quick r56_li05_mixed_literal_variable;
      test_case "R56_LI06 negative integer literal" `Quick r56_li06_negative_literal;
    ];
    "ghost-witness-regression", [
      test_case "R56_GW01 happy path still works" `Quick r56_gw01_ghost_witness_happy_path;
      test_case "R56_GW02 wrong predicate rejected" `Quick r56_gw02_ghost_witness_wrong_predicate_rejected;
      test_case "R56_GW03 int param no contamination" `Quick r56_gw03_int_param_no_ghost_contamination;
    ];
    "field-proof-passthrough", [
      test_case "R56_FP01 simple field passthrough" `Quick r56_fp01_field_passthrough_simple;
      test_case "R56_FP02 AND conjunction field passthrough" `Quick r56_fp02_field_passthrough_and;
      test_case "R56_FP03 no field access still rejected" `Quick r56_fp03_fn_no_field_no_proof_return;
      test_case "R56_FP04 FromDb return allowed" `Quick r56_fp04_fn_fromdb_return_allowed;
    ];
    "lambda-filtercheck-regression", [
      test_case "R56_LA01 lambda in List.filterCheck rejected" `Quick r56_la01_lambda_filtercheck_list_rejected;
      test_case "R56_LA02 lambda in Set.filterCheck rejected" `Quick r56_la02_lambda_filtercheck_set_rejected;
      test_case "R56_LA03 named check in filterCheck ok" `Quick r56_la03_check_filtercheck_ok;
    ];
    "w041-linter", [
      test_case "R56_LW01 W041 fires on lambda in arg" `Quick r56_lw01_w041_fires_on_lambda_arg;
      test_case "R56_LW02 W041 no false positive on decl" `Quick r56_lw02_w041_no_false_positive_decl;
      test_case "R56_LW03 W041 no false positive in let" `Quick r56_lw03_w041_no_false_positive_let;
      test_case "R56_LW04 parens lambda no warning" `Quick r56_lw04_parens_lambda_no_warning;
    ];
    "forall-literal-limitation", [
      test_case "R56_FA01 ForAll no literals works" `Quick r56_fa01_forall_no_literal_args;
      test_case "R56_FA02 ForAll literal pred now works (FIXED)" `Quick r56_fa02_forall_literal_predicate_limitation;
    ];
    "establish-literal-fact", [
      test_case "R56_ES01 establish literal Fact ok" `Quick r56_es01_establish_literal_fact;
      test_case "R56_ES02 establish wrong literal rejected" `Quick r56_es02_establish_wrong_literal_fact;
    ];
    "case-passthrough", [
      test_case "R56_CA01 case passthrough FromDb" `Quick r56_ca01_case_passthrough_fromdb;
      test_case "R56_CA02 case field access passthrough" `Quick r56_ca02_case_field_access;
    ];
    "combined-check-literals", [
      test_case "R56_CH01 combined check with literal preds" `Quick r56_ch01_combined_check_literal_preds;
    ];
  ]
