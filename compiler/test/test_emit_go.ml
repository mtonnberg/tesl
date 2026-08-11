open Alcotest

let source = {|module GoSmoke exposing [add, choose, nestedChoice, boundary, withUnused, map, teslMap, describe, describeComputed, Positive, checkPositive, checkPositiveNested, alwaysReject, rejectEither, requirePositive, doublePositive]
import Tesl.Prelude exposing [Bool(..), Int, String]

fn add(left: Int, right: Int) -> Int = left + right

fn choose(useLeft: Bool, left: Int, right: Int) -> Int =
  if useLeft then
    left
  else
    right

fn nestedChoice(useLeft: Bool, left: Int, right: Int) -> Int =
  let selected = if useLeft then
    let branchValue = left
    branchValue
  else
    let branchValue = right
    branchValue
  selected + 1

fn boundary() -> Int = 9223372036854775807 + 1

fn withUnused(value: Int) -> Int =
  let unused = value + 1
  value

fn map(value: Int) -> Int = value
fn teslMap(value: Int) -> Int = value + 1

fn describe(label: String, count: Int, ready: Bool) -> String =
  "${label}: ${count}, ready=${ready}"

fn describeComputed(prefix: String, count: Int, ready: Bool) -> String =
  "\"${prefix}\\${count + 1}:${not ready}:~:$:雪:😀"

fact Positive (n: Int)

check checkPositive(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 422 "not positive"

check checkPositiveNested(n: Int) -> n: Int ::: Positive n =
  let outcome = if n > 0 then
    ok n ::: Positive n
  else
    let rejected = n
    fail 422 "not positive: ${rejected}"
  outcome

check alwaysReject(n: Int) -> n: Int ::: Positive n =
  let outcome = fail 422 "always rejected"
  outcome

check rejectEither(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    fail 422 "positive rejected"
  else
    fail 422 "non-positive rejected"

fn requirePositive(n: Int) -> Int =
  let positive = check checkPositive n
  positive

fn doublePositive(n: Int ::: Positive n) -> Int = n * 2

test "pure Go backend" {
  expect add 40 2 == 42
  expect add 10 -3 == 7
  expect choose True 7 9 == 7
  expect choose False 7 9 == 9
  expect nestedChoice True 7 9 == 8
  expect nestedChoice False 7 9 == 10
  expect boundary() == 9223372036854775808
  expect withUnused 7 == 7
  expect map 4 == 4
  expect teslMap 4 == 5
  expect describe "jobs" 9223372036854775808 True == "jobs: 9223372036854775808, ready=true"
  expect describeComputed "" -2 True == "\"\\-1:false:~:$:雪:😀"
  expect describeComputed "x" -9223372036854775809 False == "\"x\\-9223372036854775808:true:~:$:雪:😀"
  let teslT = 1
  expect teslT == 1
  let one = 1
  expect check checkPositive one == 1
  let zero = 0
  expectFail check checkPositive zero
  expect requirePositive one == 1
  expectFail requirePositive zero
  expect check checkPositiveNested one == 1
  expectFail check checkPositiveNested zero
  expectFail check alwaysReject one
  expectFail check rejectEither one
  expectFail check rejectEither zero
  let two = 2
  let positive = check checkPositive two
  expect doublePositive positive == 4
}
|}

let contains haystack needle =
  let n = String.length needle and m = String.length haystack in
  let rec loop i = i + n <= m && (String.sub haystack i n = needle || loop (i + 1)) in
  n = 0 || loop 0

let artifacts () =
  match Compile.compile_go_source "<go-test>" source with
  | Compile.GoSuccess artifacts -> artifacts
  | Compile.GoFailure diagnostics ->
    failf "Go compilation failed: %s"
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))

let artifact path artifacts =
  match List.find_opt (fun (a : Emit_go.artifact) -> a.path = path) artifacts with
  | Some artifact -> artifact.contents
  | None -> failf "missing Go artifact %s" path

let test_artifact_layout () =
  let emitted = artifacts () in
  let paths = List.map (fun (a : Emit_go.artifact) -> a.path) emitted in
  List.iter (fun path -> check bool ("contains " ^ path) true (List.mem path paths)) [
    "go.mod";
    "internal/teslmodgosmoke/module.go";
    "internal/teslmodgosmoke/module_test.go";
    "internal/teslrt/int.go";
  ];
  let module_go = artifact "internal/teslmodgosmoke/module.go" emitted in
  check bool "Int arithmetic uses runtime helper" true
    (contains module_go "teslrt.Add(tesl_left, tesl_right)");
  check bool "huge Int crosses boundary exactly" true
    (contains module_go
       "teslrt.Add(teslrt.MustParseDecimal(\"9223372036854775807\"), teslrt.FromInt64(1))");
  check bool "Tesl source mapping is 1-based" true
    (contains module_go "//line <go-test>:4");
  check bool "check result is explicit" true (contains module_go "teslrt.Check[teslrt.Int]");
  check bool "check accept emitted" true (contains module_go "teslrt.Accept(tesl_n)");
  check bool "check reject emitted" true (contains module_go "teslrt.Reject[teslrt.Int](422");
  check bool "Int interpolation is exact" true (contains module_go "tesl_count.String()");
  check bool "Bool interpolation uses Tesl spelling" true
    (contains module_go "strconv.FormatBool(tesl_ready)");
  check bool "computed interpolation emits exact Int arithmetic" true
    (contains module_go "teslrt.Add(tesl_count, teslrt.FromInt64(1)).String()");
  check bool "computed interpolation emits Bool expression" true
    (contains module_go "strconv.FormatBool(!(tesl_ready))");
  check bool "expression-position if stays lazy" true
    (contains module_go "teslrt.If(tesl_useLeft, func() teslrt.Int");
  check bool "expression-position let keeps lexical scope" true
    (contains module_go "return (func() teslrt.Int {\n"
     && contains module_go "tesl_branchValue := tesl_left"
     && contains module_go "_ = tesl_branchValue");
  check bool "proof-consuming parameter erases to scalar" true
    (contains module_go "func Tesl_doublePositive(tesl_n teslrt.Int) teslrt.Int");
  check bool "release has no debugger import" false (contains module_go "teslrt/debug");
  let go_mod = artifact "go.mod" emitted in
  check bool "no third-party requirement" false (contains go_mod "require")

let test_named_expect_fail_emission () =
  let emitted = artifacts () in
  let module_go = artifact "internal/teslmodgosmoke/module.go" emitted in
  let test_go = artifact "internal/teslmodgosmoke/module_test.go" emitted in
  check bool "plain wrapper uses test-only recovery" true
    (contains test_go "teslExpectFailure(teslT, func()"
     && contains test_go "_ = Tesl_requirePositive(tesl_zero)");
  check bool "recovery helper stays out of release module" false
    (contains module_go "teslExpectFailure")

let test_named_expect_fail_requires_full_application () =
  let unsupported = {|module PartialExpectFail exposing [add]
import Tesl.Prelude exposing [Int]
fn add(left: Int, right: Int) -> Int = left + right
test "partial expectFail" { expectFail add 1 }
|} in
  match Compile.compile_go_source "<go-partial-expect-fail>" unsupported with
  | Compile.GoSuccess _ -> fail "partial expectFail emitted Go artifacts"
  | Compile.GoFailure diagnostics ->
    check bool "partial named call rejected by Go emitter" true
      (List.exists (fun (d : Compile.diagnostic) ->
         d.source = "go-emitter" && contains d.message "fully-applied call") diagnostics)

let test_racket_default_unchanged () =
  match Compile.compile_source "<go-test>" source with
  | Compile.Success racket ->
    check bool "default remains Racket" true (contains racket "#lang racket")
  | Compile.Failure diagnostics ->
    failf "default Racket compile failed: %s"
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))

let test_racket_go_behavior_oracle () =
  if Sys.command "raco help >/dev/null 2>&1" <> 0 then
    Printf.printf "SKIP: raco not on PATH\n%!"
  else
    match Compile.compile_source "<go-test>" source with
    | Compile.Failure diagnostics ->
      failf "Racket oracle compile failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
    | Compile.Success racket ->
      let path = Filename.temp_file "tesl-go-racket-oracle" ".rkt" in
      Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
        Out_channel.with_open_bin path (fun channel -> output_string channel racket);
        let command = Printf.sprintf "TESL_REPO_ROOT=%s raco test %s 2>&1"
          (Filename.quote (Compile.default_root_path ())) (Filename.quote path) in
        let channel = Unix.open_process_in command in
        let output = In_channel.input_all channel in
        match Unix.close_process_in channel with
        | Unix.WEXITED 0 -> ()
        | Unix.WEXITED code -> failf "Racket oracle exited %d:\n%s" code output
        | Unix.WSIGNALED signal -> failf "Racket oracle signaled %d:\n%s" signal output
        | Unix.WSTOPPED signal -> failf "Racket oracle stopped %d:\n%s" signal output)

let test_unsupported_fails_closed () =
  let unsupported = {|module Unsupported exposing []
import Tesl.Prelude exposing [Int]
secret Count = Int
|} in
  match Compile.compile_go_source "<go-unsupported>" unsupported with
  | Compile.GoSuccess _ -> fail "secret newtype emitted instead of failing closed"
  | Compile.GoFailure diagnostics ->
    check bool "go emitter diagnostic" true
      (List.exists (fun (d : Compile.diagnostic) ->
         d.source = "go-emitter" && contains d.message "secret newtype") diagnostics)

let test_string_cannot_trigger_runtime_import () =
  let source = {|module Go exposing [literal]
import Tesl.Prelude exposing [String]
fn literal() -> String = "teslrt."
test "literal" { expect literal() == "teslrt." }
|} in
  match Compile.compile_go_source "<go-string>" source with
  | Compile.GoFailure diagnostics ->
    failf "string-only Go compile failed: %s"
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  | Compile.GoSuccess artifacts ->
    let module_go = artifact "internal/teslmodgo/module.go" artifacts in
    check bool "package keyword escaped" true (contains module_go "package teslmodgo");
    check bool "literal preserved" true (contains module_go "\"teslrt.\"");
    check bool "no false runtime import" false (contains module_go "/internal/teslrt");
    check bool "runtime not copied" false
      (List.exists (fun (a : Emit_go.artifact) -> contains a.path "internal/teslrt") artifacts)

let test_bool_interpolation_imports_only_strconv () =
  let source = {|module BoolInterpolation exposing [render]
import Tesl.Prelude exposing [Bool, String]
fn render(value: Bool) -> String = "${value}"
test "Bool interpolation" { expect render False == "false" }
|} in
  match Compile.compile_go_source "<go-bool-interpolation>" source with
  | Compile.GoFailure diagnostics ->
    failf "Bool interpolation compile failed: %s"
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  | Compile.GoSuccess artifacts ->
    let module_go = artifact "internal/teslmodboolinterpolation/module.go" artifacts in
    check bool "Bool-only module imports strconv" true (contains module_go "import \"strconv\"");
    check bool "Bool-only module has no runtime import" false (contains module_go "teslrt");
    check bool "Bool-only module omits runtime files" false
      (List.exists (fun (a : Emit_go.artifact) -> contains a.path "internal/teslrt") artifacts)

let test_recursion_fails_closed () =
  let recursive = {|module Recursive exposing [loop]
import Tesl.Prelude exposing [Int]
fn loop(n: Int) -> Int = loop n
|} in
  match Compile.compile_go_source "<go-recursive>" recursive with
  | Compile.GoSuccess _ -> fail "recursive function emitted without TCO"
  | Compile.GoFailure diagnostics ->
    check bool "recursion diagnostic" true
      (List.exists (fun (d : Compile.diagnostic) -> contains d.message "no tail-call optimization") diagnostics)

let test_unproven_call_never_reaches_emitter () =
  let invalid = {|module InvalidProof exposing [Positive, requiresPositive, bypass]
import Tesl.Prelude exposing [Int, String]
fact Positive (n: Int)
fn requiresPositive(n: Int ::: Positive n) -> Int = n
fn bypass(n: Int) -> String = "value=${requiresPositive n}"
|} in
  match Compile.compile_go_source "<go-invalid-proof>" invalid with
  | Compile.GoSuccess _ -> fail "unproven call emitted Go artifacts"
  | Compile.GoFailure diagnostics ->
    check bool "proof checker rejected call before Go emission" true
      (List.exists (fun (d : Compile.diagnostic) ->
         d.source <> "go-emitter") diagnostics)

let test_unsupported_interpolation_fails_closed () =
  let unsupported = {|module UnsupportedInterpolation exposing [render]
import Tesl.Prelude exposing [String]
fn render() -> String = "value=${1.5}"
|} in
  match Compile.compile_go_source "<go-unsupported-interpolation>" unsupported with
  | Compile.GoSuccess _ -> fail "unsupported interpolation emitted Go artifacts"
  | Compile.GoFailure diagnostics ->
    check bool "non-scalar interpolation rejected by Go emitter" true
      (List.exists (fun (d : Compile.diagnostic) ->
         d.source = "go-emitter" && contains d.message "Float") diagnostics)

let test_cross_subject_mismatch_never_reaches_emitter () =
  let invalid = {|module InvalidCrossProof exposing [Matches, checkMatches, consume, bypass]
import Tesl.Prelude exposing [String]
fact Matches (left: String, right: String)
check checkMatches(left: String, right: String) -> left: String ::: Matches left right =
  if left == right then ok left ::: Matches left right else fail 400 "different"
fn consume(left: String ::: Matches left right, right: String) -> String = left
fn bypass(left: String, right: String, other: String) -> String =
  let matched = check checkMatches left right
  consume matched other
|} in
  match Compile.compile_go_source "<go-invalid-cross-proof>" invalid with
  | Compile.GoSuccess _ -> fail "cross-subject proof mismatch emitted Go artifacts"
  | Compile.GoFailure diagnostics ->
    check bool "cross-subject mismatch rejected before Go emission" true
      (List.exists (fun (d : Compile.diagnostic) -> d.source <> "go-emitter") diagnostics)

let test_nested_expressions_receive_frontend_validation () =
  let expect_error label needle source =
    let diagnostics = Compile.check_source ("<" ^ label ^ ">") source in
    if not (List.exists (fun (d : Compile.diagnostic) -> contains d.message needle) diagnostics) then
      failf "%s: expected diagnostic containing %S, got: %s" label needle
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let expect_clean label source =
    match Compile.check_source ("<" ^ label ^ ">") source with
    | [] -> ()
    | diagnostics ->
      failf "%s: expected no diagnostics, got: %s" label
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  expect_error "proof call in failure interpolation" "proof" {|module FailHole exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fn requiresPositive(n: Int ::: Positive n) -> Int = n
check bad(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "bad ${requiresPositive n}"
|};
  expect_error "proof alias call in interpolation" "proof" {|module AliasHole exposing []
import Tesl.Prelude exposing [Int, String]
fact Positive (n: Int)
fn requiresPositive(n: Int ::: Positive n) -> Int = n
fn bad(n: Int) -> String =
  let alias = requiresPositive
  "${alias n}"
|};
  expect_error "filterCheck callback in interpolation" "not a `check` function" {|module FilterHole exposing []
import Tesl.Prelude exposing [Bool, Int, List, String]
import Tesl.List exposing [List.filterCheck, List.length]
fn plain(n: Int) -> Bool = n > 0
fn bad(xs: List Int) -> String = "${List.length (List.filterCheck plain xs)}"
|};
  expect_error "proof call in case guard" "proof" {|module GuardProof exposing []
import Tesl.Prelude exposing [Int, Maybe(..)]
fact Positive (n: Int)
fn requiresPositive(n: Int ::: Positive n) -> Int = n
fn bad(value: Maybe Int) -> Int =
  case value of
    Something n where requiresPositive n > 0 -> n
    Something n -> n
    Nothing -> 0
|};
  expect_error "filterCheck callback in case guard" "not a `check` function" {|module GuardFilter exposing []
import Tesl.Prelude exposing [Bool, Int, List, Maybe(..)]
import Tesl.List exposing [List.filterCheck, List.length]
fn plain(n: Int) -> Bool = n > 0
fn bad(value: Maybe (List Int)) -> Int =
  case value of
    Something xs where List.length (List.filterCheck plain xs) > 0 -> 1
    Something _ -> 0
    Nothing -> 0
|};
  expect_error "existential pack nested in interpolation" "top-level `exists` pack" {|module NestedExists exposing [IsToken, forge]
import Tesl.Prelude exposing [String]
fact IsToken (token: String)
fn forge(raw: String) -> exists token: String => token: String ::: IsToken token =
  "${exists token => raw}"
|};
  expect_error "returned alias cannot hide unproven pack" "must carry the proof" {|module AliasExists exposing [Tagged, forge]
import Tesl.Prelude exposing [String]
fact Tagged (tag: String, value: String)
fn forge(raw: String) -> exists token: String => token: String ::: Tagged raw token =
  let packed = exists raw => raw
  packed
|};
  expect_error "existential binder proof annotation" "proof annotations on an `exists` witness binder" {|module BinderProof exposing [Positive, forge]
import Tesl.Prelude exposing [Int]
fact Positive (value: Int)
fn forge(raw: Int) -> exists witness: Int ::: Positive witness => Int =
  exists raw => raw
|};
  expect_error "existential witness type mismatch" "type mismatch" {|module WitnessType exposing [forge]
import Tesl.Prelude exposing [Int, String]
fn forge(raw: String) -> exists witness: Int => String =
  exists raw => raw
|};
  expect_error "existential forwarding witness type mismatch" "does not return the same `exists` type" {|module ForwardType exposing [source, forge]
import Tesl.Prelude exposing [Int, String]
fn source(raw: String) -> exists witness: String => String =
  exists raw => raw
fn forge(raw: String) -> exists witness: Int => String =
  source raw
|};
  expect_error "nested existential return rejected" "nested `exists` return types are not supported" {|module MissingPack exposing [forge]
import Tesl.Prelude exposing [Int, String]
fn forge(first: Int, second: String) -> exists a: Int => exists b: String => Int =
  exists first => first
|};
  expect_error "extra nested existential pack" "exactly 1 nested `exists` pack" {|module ExtraPack exposing [forge]
import Tesl.Prelude exposing [Int]
fn forge(value: Int) -> exists a: Int => Int =
  exists value =>
    exists value => value
|};
  expect_error "mixed nested existential paths" "nested `exists` return types are not supported" {|module MixedPack exposing [forge]
import Tesl.Prelude exposing [Bool, Int, String]
fn forge(flag: Bool, first: Int, second: String) -> exists a: Int => exists b: String => Int =
  if flag then
    exists first =>
      exists second => first
  else
    exists first => first
|};
  expect_error "generic existential forwarding fails closed" "does not return the same `exists` type" {|module GenericForward exposing [core, wrapper]
import Tesl.Prelude exposing [String]
fn core(value: a) -> exists witness: a => a =
  exists value => value
fn wrapper(value: String) -> exists witness: String => String =
  core value
|};
  expect_error "alpha-renamed forwarding fails closed" "does not return the same `exists` type" {|module RenamedForward exposing [source, wrapper]
import Tesl.Prelude exposing [String]
fn source(value: String) -> exists original: String => String =
  exists value => value
fn wrapper(value: String) -> exists renamed: String => String =
  source value
|};
  expect_error "forwarding alias cannot cross shadowing" "shadows" {|module ShadowedForward exposing [core, wrapper]
import Tesl.Prelude exposing [String]
fn core(tag: String, value: String) -> exists witness: String => String =
  exists value => value
fn wrapper(expected: String, actual: String) -> exists witness: String => String =
  let alias = actual
  let actual = expected
  core alias actual
|};
  expect_error "failure cannot be packed as body data" "with a value body" {|module PackedFailure exposing [pack]
import Tesl.Prelude exposing [Int]
fn pack(value: Int) -> exists witness: Int => Int =
  exists value =>
    fail 500 "not a packed value"
|};
  expect_error "existential call cannot be packed as body data" "with a value body" {|module PackedExistentialCall exposing [inner, outer]
import Tesl.Prelude exposing [Int]
fn inner(value: Int) -> exists witness: Int => Int =
  exists value => value
fn outer(value: Int) -> exists witness: Int => Int =
  exists value => inner value
|};
  expect_error "failure cannot hide in packed condition" "with a value body" {|module PackedFailureCondition exposing [pack]
import Tesl.Prelude exposing [Int]
fn pack(value: Int) -> exists witness: Int => Int =
  exists value =>
    let condition = fail 500 "bad condition"
    if condition then
      value
    else
      value
|};
  expect_error "nested pack cannot hide in packed argument" "with a value body" {|module PackedArgument exposing [pack]
import Tesl.Prelude exposing [Int]
fn identity(value: Int) -> Int = value
fn pack(value: Int) -> exists witness: Int => Int =
  exists value => identity (exists value => value)
|};
  expect_clean "discarded pack has no return witness contract" {|module DiscardedPack exposing [pack]
import Tesl.Prelude exposing [Int, String]
fn pack(raw: String, value: Int) -> exists witness: Int => Int =
  let discarded = exists raw => raw
  exists value => value
|};
  expect_clean "nested pattern proof in case guard" {|module NestedPatternGuard exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fact Positive (value: Int)
type PositiveBox
  = MkPositiveBox (value: Int ::: Positive value)
fn requiresPositive(value: Int ::: Positive value) -> Int = value
fn valid(box: Maybe PositiveBox) -> Int =
  case box of
    Something (MkPositiveBox value) where requiresPositive value > 0 -> value
    Something (MkPositiveBox value) -> value
    Nothing -> 0
|};
  expect_error "nested cross-field proof uses actual sibling" "proof" {|module NestedCrossFieldBad exposing []
import Tesl.Prelude exposing [String]
fact TaggedWith (tag: String, value: String)
type TaggedPair
  = MkTaggedPair (tag: String) (value: String ::: TaggedWith tag value)
type WrappedPair
  = MkWrappedPair (pair: TaggedPair)
fn need(tag: String, value: String ::: TaggedWith tag value) -> String = value
fn bad(claimed: String, wrapped: WrappedPair) -> String =
  case wrapped of
    MkWrappedPair (MkTaggedPair actual value) where need claimed value == value -> actual
    MkWrappedPair (MkTaggedPair actual _) -> actual
|};
  expect_clean "nested cross-field proof substitutes sibling" {|module NestedCrossFieldGood exposing []
import Tesl.Prelude exposing [String]
fact TaggedWith (tag: String, value: String)
type TaggedPair
  = MkTaggedPair (tag: String) (value: String ::: TaggedWith tag value)
type WrappedPair
  = MkWrappedPair (pair: TaggedPair)
fn need(tag: String, value: String ::: TaggedWith tag value) -> String = value
fn good(wrapped: WrappedPair) -> String =
  case wrapped of
    MkWrappedPair (MkTaggedPair actual value) where need actual value == value -> actual
    MkWrappedPair (MkTaggedPair actual _) -> actual
|};
  expect_error "compound cross-field proof needs sibling binder" "proof" {|module CompoundCrossFieldBad exposing []
import Tesl.Prelude exposing [Bool, String]
fact Related (same: Bool, value: String)
type RelatedPair
  = MkRelatedPair (tag: String) (value: String ::: Related (tag == value) value)
type WrappedRelatedPair
  = MkWrappedRelatedPair (pair: RelatedPair)
fn need(tag: String, value: String ::: Related (tag == value) value) -> String = value
fn bad(tag: String, wrapped: WrappedRelatedPair) -> String =
  case wrapped of
    MkWrappedRelatedPair (MkRelatedPair _ value) where need tag value == value -> value
    MkWrappedRelatedPair (MkRelatedPair _ value) -> value
|}

let test_unreachable_private_function_fails_closed () =
  let unsupported = {|module DeadPrivate exposing [live]
import Tesl.Prelude exposing [Int]
fn live(n: Int) -> Int = n
fn dead(n: Int) -> Int = n + 1
|} in
  match Compile.compile_go_source "<go-dead-private>" unsupported with
  | Compile.GoSuccess _ -> fail "unreachable private function bypassed lint-clean gate"
  | Compile.GoFailure diagnostics ->
    check bool "unreachable private function rejected explicitly" true
      (List.exists (fun (d : Compile.diagnostic) ->
         d.source = "go-emitter" && contains d.message "unreachable private function") diagnostics)

let test_special_package_names_are_prefixed () =
  List.iter (fun (module_name, package) ->
    let source = Printf.sprintf
      "module %s exposing [identity]\nimport Tesl.Prelude exposing [Int]\nfn identity(n: Int) -> Int = n\n"
      module_name in
    match Compile.compile_go_source "<go-package>" source with
    | Compile.GoFailure diagnostics ->
      failf "%s package compile failed: %s" module_name
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
    | Compile.GoSuccess artifacts ->
      check bool (module_name ^ " package path") true
        (List.exists (fun (a : Emit_go.artifact) ->
           a.path = "internal/" ^ package ^ "/module.go") artifacts)) [
    "Main", "teslmodmain";
    "Teslrt", "teslmodteslrt";
    "Testdata", "teslmodtestdata";
    "Vendor", "teslmodvendor";
  ]

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end else Sys.remove path

let rec mkdir_p path =
  if path = "" || path = Filename.current_dir_name then ()
  else if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let write_artifacts root artifacts =
  List.iter (fun (artifact : Emit_go.artifact) ->
    let path = Filename.concat root artifact.path in
    mkdir_p (Filename.dirname path);
    Out_channel.with_open_bin path (fun channel -> output_string channel artifact.contents)) artifacts

let compiler =
  let dir = Filename.dirname Sys.argv.(0) in
  let candidates = [
    Filename.concat (Filename.dirname dir) "bin/main.exe";
    Filename.concat dir "../bin/main.exe";
    "../bin/main.exe";
  ] in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> "tesl"

let test_cli_backend_flag () =
  let root = Filename.temp_dir "tesl-go-cli" "" in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
    let input = Filename.concat root "go-smoke.tesl" in
    let output = Filename.concat root "generated" in
    Out_channel.with_open_bin input (fun channel -> output_string channel source);
    let command = Printf.sprintf "%s --backend go %s --out %s 2>&1"
      (Filename.quote compiler) (Filename.quote input) (Filename.quote output) in
    let channel = Unix.open_process_in command in
    let process_output = In_channel.input_all channel in
    (match Unix.close_process_in channel with
     | Unix.WEXITED 0 -> ()
     | Unix.WEXITED code -> failf "CLI exited %d:\n%s" code process_output
     | Unix.WSIGNALED signal -> failf "CLI signaled %d:\n%s" signal process_output
     | Unix.WSTOPPED signal -> failf "CLI stopped %d:\n%s" signal process_output);
    check bool "CLI emitted go.mod" true (Sys.file_exists (Filename.concat output "go.mod")))

let test_cli_rejects_empty_output_path () =
  let root = Filename.temp_dir "tesl-go-empty-output" "" in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
    let input = Filename.concat root "go-smoke.tesl" in
    Out_channel.with_open_bin input (fun channel -> output_string channel source);
    let compiler =
      if Filename.is_relative compiler then Filename.concat (Sys.getcwd ()) compiler else compiler
    in
    let command = Printf.sprintf "cd %s && %s --backend go %s --out '' 2>&1"
      (Filename.quote root) (Filename.quote compiler) (Filename.quote input) in
    let channel = Unix.open_process_in command in
    let process_output = In_channel.input_all channel in
    (match Unix.close_process_in channel with
     | Unix.WEXITED 0 -> failf "CLI accepted an empty Go output path:\n%s" process_output
     | Unix.WEXITED _ -> ()
     | Unix.WSIGNALED signal -> failf "CLI signaled %d:\n%s" signal process_output
     | Unix.WSTOPPED signal -> failf "CLI stopped %d:\n%s" signal process_output);
    check bool "empty path did not write into cwd" false
      (Sys.file_exists (Filename.concat root "go.mod")))

let run_command root command =
  let command = Printf.sprintf "cd %s && %s 2>&1" (Filename.quote root) command in
  let channel = Unix.open_process_in command in
  let output = In_channel.input_all channel in
  let status = Unix.close_process_in channel in
  match status with
  | Unix.WEXITED 0 -> output
  | Unix.WEXITED code -> failf "%s exited %d:\n%s" command code output
  | Unix.WSIGNALED signal -> failf "%s received signal %d:\n%s" command signal output
  | Unix.WSTOPPED signal -> failf "%s stopped by signal %d:\n%s" command signal output

let command_available command =
  Sys.command ("command -v " ^ Filename.quote command ^ " >/dev/null 2>&1") = 0

let run_optional_go_gates root =
  if command_available "staticcheck" then ignore (run_command root "staticcheck ./...");
  if command_available "golangci-lint" then ignore (run_command root "golangci-lint run ./...");
  if command_available "gosec" then ignore (run_command root "gosec -quiet ./...");
  if command_available "govulncheck" then ignore (run_command root "govulncheck ./...");
  if command_available "nilaway" then ignore (run_command root "nilaway ./...")

let proof_scalar_source = {|module GoProofScalars exposing [NonEmpty, Enabled, checkNonEmpty, checkEnabled, label, invert]
import Tesl.Prelude exposing [Bool(..), String]

fact NonEmpty (value: String)
fact Enabled (value: Bool)

check checkNonEmpty(value: String) -> value: String ::: NonEmpty value =
  if value != "" then
    ok value ::: NonEmpty value
  else
    fail 400 "empty"

check checkEnabled(value: Bool) -> value: Bool ::: Enabled value =
  if value then
    ok value ::: Enabled value
  else
    fail 400 "disabled"

fn label(value: String ::: NonEmpty value) -> String = "label=${value}"
fn invert(value: Bool ::: Enabled value) -> Bool = not value

test "String and Bool proof consumers" {
  let text = "ready"
  let checkedText = check checkNonEmpty text
  expect label checkedText == "label=ready"
  let enabled = True
  let checkedEnabled = check checkEnabled enabled
  expect invert checkedEnabled == False
  let empty = ""
  expectFail check checkNonEmpty empty
  let disabled = False
  expectFail check checkEnabled disabled
}
|}

let newtype_source = {|module GoNewtypes exposing [Count, Label, EnabledFlag, Marker, PositiveCount, makeCount, countValue, sameCount, countBefore, makeLabel, labelValue, makeEnabled, enabledValue, makeMarker, markerValue, checkPositiveCount, usePositiveCount]
import Tesl.Prelude exposing [Bool(..), Int, String, Unit(..)]

type Count = Int
type Label = String
type EnabledFlag = Bool
type Marker = Unit

fact PositiveCount (value: Count)

fn makeCount(raw: Int) -> Count = Count raw
fn countValue(value: Count) -> Int = value.value
fn sameCount(left: Count, right: Count) -> Bool = left == right
fn countBefore(left: Count, right: Count) -> Bool = left < right
fn makeLabel(raw: String) -> Label = Label raw
fn labelValue(value: Label) -> String = value.value
fn makeEnabled(raw: Bool) -> EnabledFlag = EnabledFlag raw
fn enabledValue(value: EnabledFlag) -> Bool = value.value
fn makeMarker(raw: Unit) -> Marker = Marker raw
fn markerValue(value: Marker) -> Unit = value.value

check checkPositiveCount(value: Count) -> value: Count ::: PositiveCount value =
  if value.value > 0 then
    ok value ::: PositiveCount value
  else
    fail 400 "not positive"

fn usePositiveCount(value: Count ::: PositiveCount value) -> Int = value.value

test "scalar newtypes stay nominal" {
  let one = makeCount 1
  let two = makeCount 2
  expect countValue one == 1
  expect sameCount one (makeCount 1) == True
  expect countBefore one two == True
  expect labelValue (makeLabel "ready") == "ready"
  expect enabledValue (makeEnabled True) == True
  expect markerValue (makeMarker Unit) == Unit
  let positive = check checkPositiveCount one
  expect usePositiveCount positive == 1
  let zero = makeCount 0
  expectFail check checkPositiveCount zero
}
|}

let test_scalar_newtypes_with_go () =
  let emitted = match Compile.compile_go_source "<go-newtypes>" newtype_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "scalar newtype compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgonewtypes/module.go" emitted in
  check bool "Int newtype is nominal" true
    (contains module_go "type Tesl_Count struct {\n\tteslValue teslrt.Int\n}");
  check bool "String newtype is nominal" true
    (contains module_go "type Tesl_Label struct {\n\tteslValue string\n}");
  check bool "Bool newtype is nominal" true
    (contains module_go "type Tesl_EnabledFlag struct {\n\tteslValue bool\n}");
  check bool "Unit newtype is nominal" true
    (contains module_go "type Tesl_Marker struct {\n\tteslValue struct{}\n}");
  check bool "newtype Int equality uses runtime helper" true
    (contains module_go "teslrt.Equal((tesl_left).teslValue, (tesl_right).teslValue)");
  check bool "newtype Int ordering uses runtime helper" true
    (contains module_go "teslrt.Compare((tesl_left).teslValue, (tesl_right).teslValue)");
  check bool "newtype checks keep explicit result" true
    (contains module_go "teslrt.Check[Tesl_Count]");
  if Sys.command "go version >/dev/null 2>&1" = 0 then
    let root = Filename.temp_dir "tesl-go-newtypes" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./..."))

let test_unsupported_newtypes_fail_closed () =
  let expect_go_error label needle source =
    match Compile.compile_go_source ("<" ^ label ^ ">") source with
    | Compile.GoSuccess _ -> failf "%s emitted unsupported Go artifacts" label
    | Compile.GoFailure diagnostics ->
      check bool label true
        (List.exists (fun (d : Compile.diagnostic) ->
           d.source = "go-emitter" && contains d.message needle) diagnostics)
  in
  expect_go_error "applied newtype base" "applied types" {|module AppliedNewtype exposing [Counts]
import Tesl.Prelude exposing [Int, List]
type Counts = (List Int)
|};
  expect_go_error "transitive newtype base" "not a direct scalar type" {|module TransitiveNewtype exposing [UserId, WrappedUserId]
import Tesl.Prelude exposing [String]
type UserId = String
type WrappedUserId = UserId
|}

let test_string_bool_proof_consumers_with_go () =
  let emitted = match Compile.compile_go_source "<go-proof-scalars>" proof_scalar_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "String/Bool proof consumer compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgoproofscalars/module.go" emitted in
  check bool "String proof parameter erases to String" true
    (contains module_go "func Tesl_label(tesl_value string) string");
  check bool "Bool proof parameter erases to Bool" true
    (contains module_go "func Tesl_invert(tesl_value bool) bool");
  if Sys.command "go version >/dev/null 2>&1" = 0 then
    let root = Filename.temp_dir "tesl-go-proof-scalars" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      ignore (run_command root "go test -count=1 ./..."))

let scalar_proof_corpus = [
  "example/learn/lesson00-hello-world.tesl";
  "example/learn/lesson04-newtypes.tesl";
  "example/learn/lesson05-intro-to-proofs.tesl";
  "example/learn/lesson10-cross-parameter-proofs.tesl";
  "example/learn/lesson40-implicit-value-unwrapping.tesl";
  "example/learn/lesson44-multi-param-proofs.tesl";
  "tests/multiparam_test.tesl";
]

let test_scalar_proof_corpus_with_go () =
  if Sys.command "go version >/dev/null 2>&1" <> 0 then
    Printf.printf "SKIP: Go not on PATH (CI/dev shell runs this case with Go)\n%!"
  else
    List.iter (fun relative ->
      let path = Filename.concat (Compile.default_root_path ()) relative in
      let emitted = match Compile.compile_go_file path with
        | Compile.GoSuccess artifacts -> artifacts
        | Compile.GoFailure diagnostics ->
          failf "%s Go compilation failed: %s" relative
            (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
      in
      let root = Filename.temp_dir "tesl-go-corpus" "" in
      Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
        write_artifacts root emitted;
        let unformatted = run_command root "gofmt -l ." |> String.trim in
        if unformatted <> "" then failf "%s emitted unformatted Go: %s" relative unformatted;
        ignore (run_command root "go test -count=1 ./...");
        ignore (run_command root "go vet ./...");
        ignore (run_command root "go test -race -count=1 ./...");
        ignore (run_command root "CGO_ENABLED=0 go build ./...");
        run_optional_go_gates root)) scalar_proof_corpus

let test_generated_module_with_go () =
  if Sys.command "go version >/dev/null 2>&1" <> 0 then
    Printf.printf "SKIP: Go not on PATH (CI/dev shell runs this case with Go)\n%!"
  else begin
    let marker = Filename.temp_file "tesl-go-emitted" ".tmp" in
    Sys.remove marker;
    Unix.mkdir marker 0o755;
    Fun.protect ~finally:(fun () -> remove_tree marker) (fun () ->
      write_artifacts marker (artifacts ());
      let unformatted = run_command marker "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command marker "gofmt -d .");
      ignore (run_command marker "go test -count=1 ./...");
      ignore (run_command marker "go vet ./...");
      ignore (run_command marker "go test -race -count=1 ./...");
      ignore (run_command marker "CGO_ENABLED=0 go build ./...");
      run_optional_go_gates marker)
  end

let () =
  run "emit_go" [
    "emission", [
      test_case "artifact layout and helpers" `Quick test_artifact_layout;
      test_case "named expectFail emission" `Quick test_named_expect_fail_emission;
      test_case "named expectFail requires full application" `Quick test_named_expect_fail_requires_full_application;
      test_case "Racket remains default" `Quick test_racket_default_unchanged;
      test_case "Racket behavior oracle" `Slow test_racket_go_behavior_oracle;
      test_case "unsupported forms fail closed" `Quick test_unsupported_fails_closed;
      test_case "strings cannot trigger imports" `Quick test_string_cannot_trigger_runtime_import;
      test_case "Bool interpolation imports strconv only" `Quick test_bool_interpolation_imports_only_strconv;
      test_case "recursion fails closed" `Quick test_recursion_fails_closed;
      test_case "unproven calls fail before emission" `Quick test_unproven_call_never_reaches_emitter;
      test_case "unsupported interpolation fails closed" `Quick test_unsupported_interpolation_fails_closed;
      test_case "cross-subject mismatch fails before emission" `Quick test_cross_subject_mismatch_never_reaches_emitter;
      test_case "nested expressions receive frontend validation" `Quick test_nested_expressions_receive_frontend_validation;
      test_case "unreachable private functions fail closed" `Quick test_unreachable_private_function_fails_closed;
      test_case "String and Bool proof consumers" `Slow test_string_bool_proof_consumers_with_go;
      test_case "scalar newtypes" `Slow test_scalar_newtypes_with_go;
      test_case "unsupported newtypes fail closed" `Quick test_unsupported_newtypes_fail_closed;
      test_case "special package names are prefixed" `Quick test_special_package_names_are_prefixed;
      test_case "CLI backend flag emits tree" `Quick test_cli_backend_flag;
      test_case "CLI rejects empty output path" `Quick test_cli_rejects_empty_output_path;
      test_case "scalar proof corpus runs with Go" `Slow test_scalar_proof_corpus_with_go;
      test_case "fresh module passes Go gates" `Slow test_generated_module_with_go;
    ];
  ]
