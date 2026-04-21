(** Antagonistic regression tests for Critical Review 47.

    Focus: pack-operator semantics, proof transport, and legacy surface syntax.

    R47_01  Canonical single-proof pack compiles
    R47_02  Canonical conjunction pack compiles
    R47_03  Canonical pack with cargo proof compiles
    R47_04  Canonical pack with missing predicate is rejected
    R47_05  Canonical pack cargo subject mismatch is rejected
    R47_06  Legacy prefix pack syntax is rejected
    R47_07  Legacy prefix pack without proof is rejected
    R47_08  Legacy prefix pack with parenthesized type is rejected
    R47_09  List ForAll return pack compiles
    R47_10  Set ForAll return pack compiles
    R47_11  ForAll on non-collection is rejected
    R47_12  ForAllValues on non-dict is rejected
    R47_13  attachFact retargeting is rejected
    R47_14  forgetFact strips proofs and preserves value usability
    R47_15  Free-floating proof fabrication in fn is rejected
    R47_16  Qualified single-arg paren call compiles
    R47_17  Zero-arg paren call compiles
    R47_18  Multi-arg paren call is rejected
    R47_19  check keyword accepts single-arg paren call
    R47_20  Calling a check function without the check keyword is rejected
    R47_21  Canonical pack with return-line detached proof compiles
    R47_22  Legacy prefix pack with cargo proof is rejected
    R47_23  Canonical conjunction pack with cargo proof compiles
    R47_24  attachFact with the original subject compiles
    R47_25  Cargo proof subject mismatch is rejected
    R47_26  Unbound entity-side subject is rejected
    R47_27  Over-arity entity-side subject is rejected
    R47_28  Fabricated conjunction is rejected
    R47_29  Nested pack Maybe (Int ? ValidScore) compiles
    R47_30  Canonical unary entity pack compiles
    R47_31  Entity pack with check function compiles
    R47_32  Entity pack with establish and cargo compiles
    R47_33  Missing entity proof is rejected
    R47_34  Missing cargo proof is rejected
    R47_35  Entity pack alias through let compiles
    R47_36  Entity pack if branches compile
    R47_37  Entity pack if branch missing proof rejected
    R47_38  Binary fact entity pack with zero explicit args
    R47_39  Entity pack handler compiles
    R47_40  Conjunction with check function compiles
    R47_41  Partial conjunction rejected
    R47_42  Nested pack in List erased compiles
    R47_43  Legacy prefix inside exists rejected
    R47_44  Entity pack with case compiles
    R47_45  Entity pack with empty proof valid
    R47_46  forgetFact direct return rejected
    R47_47  forgetFact chain rejected
    R47_48  Let alias to unproven rejected
    R47_49  Binary fact passthrough compiles
    R47_50  Binary fact wrong explicit rejected
    R47_51  Fabricate via let naming rejected
    R47_52  Nested Maybe pack compiles
    R47_53  Entity undeclared fact rejected
    R47_54  Cargo undeclared fact rejected
    R47_55  Ternary entity passthrough compiles
    R47_56  Proof from wrong var rejected
    R47_57  Compound check conjunction compiles
    R47_58  Entity+cargo establish+detachFact compiles
    R47_59  Handler with fail case compiles
    R47_60  Exists named pack compiles
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

let with_temp_file prefix suffix content f =
  let path = Filename.temp_file prefix suffix in
  write_file path content;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () -> f path)

let should_pass_src src =
  with_temp_file "tesl-r47" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let should_fail_src pattern src =
  with_temp_file "tesl-r47" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

let test_r47_01_canonical_pack_single_pass () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fn f(n: Int ::: Positive n) -> Int ? Positive =
  n
|}

let test_r47_02_canonical_pack_conj_pass () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fact Small (n: Int)
fn f(n: Int ::: Positive n && Small n) -> Int ? Positive && Small =
  n
|}

let test_r47_03_canonical_pack_cargo_pass () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, detachFact]
fact Positive (n: Int)
fact Admin (user: String)
fn f(n: Int ::: Positive n, user: String ::: Admin user) -> Int ? Positive ::: Admin user =
  n ::: detachFact user
|}

let test_r47_04_canonical_pack_missing_predicate_rejected () =
  should_fail_src "proof predicate 'Missing' is not in scope" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fn f(n: Int) -> Int ? Missing =
  n
|}

let test_r47_05_canonical_pack_cargo_unknown_subject_rejected () =
  should_fail_src "cargo proof subject mismatch" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, detachFact]
fact Positive (n: Int)
fact Admin (user: String)
fn f(n: Int ::: Positive n, user: String ::: Admin user) -> Int ? Positive ::: Admin missing =
  n ::: detachFact user
|}

let test_r47_06_legacy_prefix_pack_rejected () =
  should_fail_src "legacy return-pack syntax" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fn f(n: Int ::: Positive n) -> ?Int ::: Positive n =
  n
|}

let test_r47_07_legacy_prefix_pack_no_proof_rejected () =
  should_fail_src "legacy return-pack syntax" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fn f(n: Int) -> ?Int =
  n
|}

let test_r47_08_legacy_prefix_pack_paren_type_rejected () =
  should_fail_src "legacy return-pack syntax" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fn f(n: Int ::: Positive n) -> ?(Int) ::: Positive n =
  n
|}

let test_r47_09_forall_list_pack_pass () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, List]
fact Positive (n: Int)
fn f(xs: List Int ::: ForAll Positive xs) -> List Int ? ForAll Positive =
  xs
|}

let test_r47_10_forall_set_pack_pass () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Set exposing [Set]
fact Positive (n: Int)
fn f(xs: Set Int ::: ForAll Positive xs) -> Set Int ? ForAll Positive =
  xs
|}

let test_r47_11_forall_non_collection_rejected () =
  should_fail_src "only valid for `List` or `Set`" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fn f(n: Int ::: Positive n) -> Int ? ForAll Positive =
  n
|}

let test_r47_12_forallvalues_non_dict_rejected () =
  should_fail_src "only valid for `Dict`" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fn f(n: Int ::: Positive n) -> Int ? ForAllValues Positive =
  n
|}

let test_r47_13_attach_wrong_subject_rejected () =
  should_fail_src "proof subject mismatch" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, Fact, attachFact]
fact Positive (n: Int)
establish prove(n: Int) -> Fact (Positive n) =
  Positive n
fn f(a: Int, b: Int) -> Int ::: Positive b =
  let p = prove a
  attachFact b p
|}

let test_r47_14_forget_fact_pass () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, forgetFact]
fact Positive (n: Int)
fn f(n: Int ::: Positive n) -> Int =
  let plain = forgetFact n
  plain
|}

let test_r47_15_free_floating_proof_fabrication_rejected () =
  should_fail_src "proof construction is not allowed in `fn`" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fn f(n: Int) -> Int ::: Positive n =
  n ::: Positive n
|}

let test_r47_16_qualified_single_arg_paren_call_pass () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.String exposing [String.length]
fn f(s: String) -> Int =
  String.length(s)
|}

let test_r47_17_zero_arg_paren_call_pass () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fn g() -> Int = 1
fn f() -> Int =
  g()
|}

let test_r47_18_multi_arg_paren_call_rejected () =
  should_fail_src "expected .* but got ," {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fn add(x: Int, y: Int) -> Int = x + y
fn f() -> Int =
  add(1, 2)
|}

let test_r47_19_check_single_arg_paren_pass () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
check checkPositive(n: Int) -> n: Int ::: Positive n =
  ok n ::: Positive n
fn f(n: Int) -> Int =
  let checked = check checkPositive(n)
  checked
|}

let test_r47_20_plain_call_to_check_without_keyword_rejected () =
  should_fail_src "must be called with the `check` keyword" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
check checkPositive(n: Int) -> n: Int ::: Positive n =
  ok n ::: Positive n
fn f(n: Int) -> Int =
  let checked = checkPositive(n)
  checked
|}

let test_r47_21_canonical_pack_returnline_detached_pass () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Fact, detachFact]
fact Positive (n: Int)
fact Admin (user: String)
establish provePositive(n: Int) -> Fact (Positive n) =
  Positive n
fn f(n: Int, user: String ::: Admin user) -> Int ? Positive ::: Admin user =
  let p = provePositive n
  n ::: p && detachFact user
|}

let test_r47_22_legacy_prefix_pack_with_cargo_rejected () =
  should_fail_src "legacy return-pack syntax" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, detachFact]
fact Positive (n: Int)
fact Admin (user: String)
fn f(n: Int ::: Positive n, user: String ::: Admin user) -> ?Int ::: Positive n && Admin user =
  n ::: detachFact user
|}

let test_r47_23_canonical_pack_conj_with_cargo_pass () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, detachFact]
fact Positive (n: Int)
fact Small (n: Int)
fact Admin (user: String)
fn f(n: Int ::: Positive n && Small n, user: String ::: Admin user) -> Int ? Positive && Small ::: Admin user =
  n ::: detachFact user
|}

let test_r47_24_attach_same_subject_pass () =
  (* fn with RetAttached (n: T ::: P) return spec is now banned; only check/establish/auth may
     declare proof-carrying return types. The correct alternative for fn is RetNamedPack (T ? P). *)
  should_fail_src "plain.*`fn`\\|fn.*cannot\\|proof-carrying" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, Fact, attachFact]
fact Positive (n: Int)
establish prove(n: Int) -> Fact (Positive n) =
  Positive n
fn f(n: Int) -> Int ::: Positive n =
  let p = prove n
  attachFact n p
|}

let test_r47_25_cargo_subject_mismatch_rejected () =
  should_fail_src "cargo proof subject mismatch" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, detachFact]
fact Positive (n: Int)
fact Admin (user: String)
fn f(n: Int ::: Positive n, user: String ::: Admin user, other: String) -> Int ? Positive ::: Admin other =
  n ::: detachFact user
|}

(* ── NEW REGRESSION TESTS: entity-side ? soundness, nested packs, proof transport ── *)

let test_r47_26_unbound_entity_subject_rejected () =
  should_fail_src "argument count mismatch" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact ValidScore (n: Int)
check checkScore(n: Int) -> n: Int ::: ValidScore n =
  ok n ::: ValidScore n
fn foo() -> Int ? ValidScore foo3 =
  check checkScore 3
|}

let test_r47_27_over_arity_entity_subject_rejected () =
  should_fail_src "argument count mismatch" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact ValidScore (n: Int)
check checkScore(n: Int) -> n: Int ::: ValidScore n =
  ok n ::: ValidScore n
fn foo(extra: Int) -> Int ? ValidScore extra =
  check checkScore 3
|}

let test_r47_28_fabricated_conjunction_rejected () =
  should_fail_src "named pack claiming entity proof" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fact Small (n: Int)
fn fabricate(n: Int ::: Positive n) -> Int ? Positive && Small =
  n
|}

let test_r47_29_nested_pack_maybe_compiles () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe]
fact ValidScore (n: Int)
fn f() -> Maybe (Int ? ValidScore) =
  Nothing
|}

let test_r47_30_canonical_unary_entity_pack_compiles () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fn f(n: Int ::: Positive n) -> Int ? Positive =
  n
|}

let test_r47_31_canonical_entity_pack_with_check_compiles () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
check checkPositive(n: Int) -> n: Int ::: Positive n =
  ok n ::: Positive n
fn f(n: Int) -> Int ? Positive =
  check checkPositive n
|}

let test_r47_32_entity_pack_with_establish_and_cargo_compiles () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Fact, detachFact]
fact IsPositive (n: Int)
fact IsAdmin (user: String)
establish provePositive(n: Int) -> Fact (IsPositive n) =
  IsPositive n
fn f(n: Int, user: String ::: IsAdmin user) -> Int ? IsPositive ::: IsAdmin user =
  let p = provePositive n
  n ::: p && detachFact user
|}

let test_r47_33_missing_entity_proof_rejected () =
  should_fail_src "named pack claiming entity proof" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fn f(n: Int) -> Int ? Positive =
  n
|}

let test_r47_34_missing_cargo_proof_rejected () =
  should_fail_src "named pack claiming cargo proof" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, detachFact]
fact Positive (n: Int)
fact Admin (user: String)
fn f(n: Int ::: Positive n, user: String) -> Int ? Positive ::: Admin user =
  n ::: detachFact user
|}

let test_r47_35_entity_pack_alias_through_let_compiles () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fn f(n: Int ::: Positive n) -> Int ? Positive =
  let x = n
  x
|}

let test_r47_36_entity_pack_if_branches_compiles () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, Bool]
fact Positive (n: Int)
fn f(n: Int ::: Positive n, flag: Bool) -> Int ? Positive =
  if flag then
    n
  else
    n
|}

let test_r47_37_entity_pack_if_missing_branch_rejected () =
  should_fail_src "named pack claiming entity proof" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, Bool]
fact Positive (n: Int)
fn f(n: Int, proven: Int ::: Positive proven, flag: Bool) -> Int ? Positive =
  if flag then
    proven
  else
    n
|}

let test_r47_38_binary_fact_entity_pack_zero_explicit_args () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fn f(n: Int ::: Positive n) -> Int ? Positive =
  n
|}

let test_r47_39_entity_pack_handler_compiles () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
check checkPositive(n: Int) -> n: Int ::: Positive n =
  ok n ::: Positive n
handler h(n: Int) -> Int ? Positive =
  check checkPositive n
|}

let test_r47_40_canonical_pack_conjunction_with_check_compiles () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fact Small (n: Int)
check checkBoth(n: Int) -> n: Int ::: Positive n && Small n =
  ok n ::: Positive n && Small n
fn f(n: Int) -> Int ? Positive && Small =
  check checkBoth n
|}

let test_r47_41_partial_conjunction_rejected () =
  should_fail_src "named pack claiming entity proof" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fact Small (n: Int)
check checkPositive(n: Int) -> n: Int ::: Positive n =
  ok n ::: Positive n
fn f(n: Int) -> Int ? Positive && Small =
  check checkPositive n
|}

let test_r47_42_nested_pack_in_list_erased_compiles () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, List]
fact Positive (n: Int)
fn f() -> List (Int ? Positive) =
  []
|}

let test_r47_43_legacy_prefix_inside_exists_rejected () =
  should_fail_src "legacy return-pack syntax" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fn f(n: Int ::: Positive n) -> exists x: Int => ?Int ::: Positive n =
  n
|}

let test_r47_44_entity_pack_with_case_compiles () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fn f(a: Int ::: Positive a) -> Int ? Positive =
  let x = a
  x
|}

let test_r47_45_entity_pack_empty_proof_still_valid () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fn f(n: Int) -> Int ? =
  n
|}

(* ── PHASE 2: Deep adversarial probes from audit (H21-H30) ─────────────────── *)

let test_r47_46_forgetFact_direct_return_rejected () =
  should_fail_src "named pack claiming" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, forgetFact]
fact Positive (n: Int)
fn f(n: Int ::: Positive n) -> Int ? Positive =
  forgetFact n
|}

let test_r47_47_forgetFact_chain_rejected () =
  should_fail_src "named pack claiming" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, forgetFact]
fact Positive (n: Int)
fn f(n: Int ::: Positive n) -> Int ? Positive =
  let a = forgetFact n
  let b = a
  b
|}

let test_r47_48_let_alias_to_unproven_rejected () =
  should_fail_src "named pack claiming" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fn f(n: Int) -> Int ? Positive =
  let x = n
  x
|}

let test_r47_49_binary_fact_passthrough_compiles () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact BoundedBy (n: Int, limit: Int)
fn f(n: Int ::: BoundedBy n lim, lim: Int) -> Int ? BoundedBy lim =
  n
|}

let test_r47_50_binary_fact_wrong_explicit_rejected () =
  should_fail_src "named pack claiming" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact BoundedBy (n: Int, limit: Int)
fn f(n: Int, lim: Int) -> Int ? BoundedBy lim =
  n
|}

let test_r47_51_fabricate_via_let_naming_rejected () =
  should_fail_src "named pack claiming" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fn f(n: Int) -> Int ? Positive =
  let proven = n
  proven
|}

let test_r47_52_nested_maybe_pack_compiles () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe]
fact Positive (n: Int)
fn f() -> Maybe (Int ? Positive) =
  Nothing
|}

let test_r47_53_entity_proof_undeclared_fact_rejected () =
  should_fail_src "not in scope" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fn f(n: Int) -> Int ? Nonexistent =
  n
|}

let test_r47_54_cargo_proof_undeclared_fact_rejected () =
  should_fail_src "not in scope" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fn f(n: Int ::: Positive n) -> Int ? Positive ::: Nonexistent n =
  n
|}

let test_r47_55_ternary_entity_passthrough_compiles () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact InRange (n: Int, lo: Int, hi: Int)
check cr(n: Int, lo: Int, hi: Int) -> n: Int ::: InRange n lo hi =
  ok n ::: InRange n lo hi
fn f(n: Int ::: InRange n lo hi, lo: Int, hi: Int) -> Int ? InRange lo hi =
  n
|}

let test_r47_56_proof_from_wrong_var_rejected () =
  should_fail_src "named pack claiming" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fn f(a: Int ::: Positive a, b: Int) -> Int ? Positive =
  b
|}

let test_r47_57_compound_check_conjunction_compiles () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fact Small (n: Int)
check cp(n: Int) -> n: Int ::: Positive n =
  ok n ::: Positive n
check cs(n: Int) -> n: Int ::: Small n =
  ok n ::: Small n
fn f(n: Int) -> Int ? Positive && Small =
  check (cp && cs) n
|}

let test_r47_58_entity_cargo_establish_detachFact_compiles () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Fact, detachFact]
fact IsPositive (n: Int)
fact IsAdmin (user: String)
establish provePositive(n: Int) -> Fact (IsPositive n) =
  IsPositive n
fn f(n: Int, user: String ::: IsAdmin user) -> Int ? IsPositive ::: IsAdmin user =
  let p = provePositive n
  n ::: p && detachFact user
|}

let test_r47_59_handler_with_fail_case_compiles () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
fact Positive (n: Int)
check cp(n: Int) -> n: Int ::: Positive n =
  ok n ::: Positive n
handler f(n: Int, s: String) -> Int ? Positive =
  case s of
    "ok" -> check cp n
    _ -> fail 400 "bad"
|}

let test_r47_60_exists_named_pack_compiles () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Fact]
fact Positive (n: Int)
establish pp(n: Int) -> Fact (Positive n) =
  Positive n
fn f(n: Int) -> exists id: String => Int ? Positive =
  let id = "item-1"
  let p = pp n
  exists id =>
    n ::: p
|}

let () =
  run "Review47" [
    ("pack-operator", [
      test_case "canonical single pack" `Quick test_r47_01_canonical_pack_single_pass;
      test_case "canonical conjunction pack" `Quick test_r47_02_canonical_pack_conj_pass;
      test_case "canonical pack with cargo" `Quick test_r47_03_canonical_pack_cargo_pass;
      test_case "missing predicate rejected" `Quick test_r47_04_canonical_pack_missing_predicate_rejected;
      test_case "cargo unknown subject rejected" `Quick test_r47_05_canonical_pack_cargo_unknown_subject_rejected;
      test_case "legacy prefix pack rejected" `Quick test_r47_06_legacy_prefix_pack_rejected;
      test_case "legacy prefix pack no proof rejected" `Quick test_r47_07_legacy_prefix_pack_no_proof_rejected;
      test_case "legacy prefix paren type rejected" `Quick test_r47_08_legacy_prefix_pack_paren_type_rejected;
      test_case "forall list pack" `Quick test_r47_09_forall_list_pack_pass;
      test_case "forall set pack" `Quick test_r47_10_forall_set_pack_pass;
      test_case "forall non-collection rejected" `Quick test_r47_11_forall_non_collection_rejected;
      test_case "forallvalues non-dict rejected" `Quick test_r47_12_forallvalues_non_dict_rejected;
      test_case "return-line detached proof pack" `Quick test_r47_21_canonical_pack_returnline_detached_pass;
      test_case "legacy prefix pack with cargo rejected" `Quick test_r47_22_legacy_prefix_pack_with_cargo_rejected;
      test_case "canonical conjunction pack with cargo" `Quick test_r47_23_canonical_pack_conj_with_cargo_pass;
    ]);
    ("proof-transport", [
      test_case "attach wrong subject rejected" `Quick test_r47_13_attach_wrong_subject_rejected;
      test_case "forgetFact pass" `Quick test_r47_14_forget_fact_pass;
      test_case "free-floating proof fabrication rejected" `Quick test_r47_15_free_floating_proof_fabrication_rejected;
      test_case "attach same subject pass" `Quick test_r47_24_attach_same_subject_pass;
      test_case "cargo subject mismatch rejected" `Quick test_r47_25_cargo_subject_mismatch_rejected;
    ]);
    ("legacy-surface", [
      test_case "qualified single-arg paren call" `Quick test_r47_16_qualified_single_arg_paren_call_pass;
      test_case "zero-arg paren call" `Quick test_r47_17_zero_arg_paren_call_pass;
      test_case "multi-arg paren call rejected" `Quick test_r47_18_multi_arg_paren_call_rejected;
      test_case "check single-arg paren" `Quick test_r47_19_check_single_arg_paren_pass;
      test_case "plain check call without keyword rejected" `Quick test_r47_20_plain_call_to_check_without_keyword_rejected;
    ]);
    ("entity-soundness", [
      test_case "unbound entity subject rejected" `Quick test_r47_26_unbound_entity_subject_rejected;
      test_case "over-arity entity subject rejected" `Quick test_r47_27_over_arity_entity_subject_rejected;
      test_case "fabricated conjunction rejected" `Quick test_r47_28_fabricated_conjunction_rejected;
      test_case "nested pack Maybe compiles" `Quick test_r47_29_nested_pack_maybe_compiles;
      test_case "canonical unary entity pack" `Quick test_r47_30_canonical_unary_entity_pack_compiles;
      test_case "entity pack with check" `Quick test_r47_31_canonical_entity_pack_with_check_compiles;
      test_case "entity pack with establish and cargo" `Quick test_r47_32_entity_pack_with_establish_and_cargo_compiles;
      test_case "missing entity proof rejected" `Quick test_r47_33_missing_entity_proof_rejected;
      test_case "missing cargo proof rejected" `Quick test_r47_34_missing_cargo_proof_rejected;
      test_case "entity pack alias through let" `Quick test_r47_35_entity_pack_alias_through_let_compiles;
      test_case "entity pack if branches" `Quick test_r47_36_entity_pack_if_branches_compiles;
      test_case "entity pack if missing branch" `Quick test_r47_37_entity_pack_if_missing_branch_rejected;
      test_case "binary fact entity pack zero explicit" `Quick test_r47_38_binary_fact_entity_pack_zero_explicit_args;
      test_case "entity pack handler" `Quick test_r47_39_entity_pack_handler_compiles;
      test_case "conjunction with check" `Quick test_r47_40_canonical_pack_conjunction_with_check_compiles;
      test_case "partial conjunction rejected" `Quick test_r47_41_partial_conjunction_rejected;
      test_case "nested pack in list erased" `Quick test_r47_42_nested_pack_in_list_erased_compiles;
      test_case "legacy prefix inside exists rejected" `Quick test_r47_43_legacy_prefix_inside_exists_rejected;
      test_case "entity pack with case" `Quick test_r47_44_entity_pack_with_case_compiles;
      test_case "entity pack empty proof valid" `Quick test_r47_45_entity_pack_empty_proof_still_valid;
    ]);
    ("deep-adversarial", [
      test_case "forgetFact direct return" `Quick test_r47_46_forgetFact_direct_return_rejected;
      test_case "forgetFact chain" `Quick test_r47_47_forgetFact_chain_rejected;
      test_case "let alias to unproven" `Quick test_r47_48_let_alias_to_unproven_rejected;
      test_case "binary fact passthrough" `Quick test_r47_49_binary_fact_passthrough_compiles;
      test_case "binary fact wrong explicit" `Quick test_r47_50_binary_fact_wrong_explicit_rejected;
      test_case "fabricate via let naming" `Quick test_r47_51_fabricate_via_let_naming_rejected;
      test_case "nested Maybe pack" `Quick test_r47_52_nested_maybe_pack_compiles;
      test_case "entity undeclared fact" `Quick test_r47_53_entity_proof_undeclared_fact_rejected;
      test_case "cargo undeclared fact" `Quick test_r47_54_cargo_proof_undeclared_fact_rejected;
      test_case "ternary entity passthrough" `Quick test_r47_55_ternary_entity_passthrough_compiles;
      test_case "proof from wrong var" `Quick test_r47_56_proof_from_wrong_var_rejected;
      test_case "compound check conjunction" `Quick test_r47_57_compound_check_conjunction_compiles;
      test_case "entity+cargo establish detachFact" `Quick test_r47_58_entity_cargo_establish_detachFact_compiles;
      test_case "handler with fail case" `Quick test_r47_59_handler_with_fail_case_compiles;
      test_case "exists named pack" `Quick test_r47_60_exists_named_pack_compiles;
    ]);
  ]
