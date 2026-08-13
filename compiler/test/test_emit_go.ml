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
    ".golangci.yml";
    "internal/teslmodgosmoke/module.go";
    "internal/teslmodgosmoke/module_test.go";
    "internal/teslrt/int.go";
  ];
  let module_go = artifact "internal/teslmodgosmoke/module.go" emitted in
  check bool "Int arithmetic uses runtime helper" true
    (contains module_go "teslrt.Add(left, right)");
  check bool "huge Int crosses boundary exactly" true
    (contains module_go
       "teslrt.Add(teslrt.MustParseDecimal(\"9223372036854775807\"), teslrt.FromInt64(1))");
  check bool "Tesl source mapping is 1-based" true
    (contains module_go "//line <go-test>:4");
  check bool "check result is explicit" true (contains module_go "teslrt.Check[teslrt.Int]");
  check bool "check accept emitted" true (contains module_go "teslrt.Accept(n)");
  check bool "check reject emitted" true (contains module_go "teslrt.Reject[teslrt.Int](422");
  check bool "Int interpolation is exact" true (contains module_go "count.String()");
  check bool "Bool interpolation uses Tesl spelling" true
    (contains module_go "strconv.FormatBool(ready)");
  check bool "computed interpolation emits exact Int arithmetic" true
    (contains module_go "teslrt.Add(count, teslrt.FromInt64(1)).String()");
  check bool "computed interpolation emits Bool expression" true
    (contains module_go "strconv.FormatBool(!(ready))");
  check bool "expression-position if stays lazy" true
    (contains module_go "teslrt.If(useLeft, func() teslrt.Int");
  check bool "expression-position let keeps lexical scope" true
    (contains module_go "return (func() teslrt.Int {\n"
     && contains module_go "branchValue := left"
     && contains module_go "_ = branchValue");
  check bool "proof-consuming parameter erases to scalar" true
    (contains module_go "func DoublePositive(n teslrt.Int) teslrt.Int");
  check bool "release has no debugger import" false (contains module_go "teslrt/debug");
  let go_mod = artifact "go.mod" emitted in
  check bool "no third-party requirement" false (contains go_mod "require")

let test_named_expect_fail_emission () =
  let emitted = artifacts () in
  let module_go = artifact "internal/teslmodgosmoke/module.go" emitted in
  let test_go = artifact "internal/teslmodgosmoke/module_test.go" emitted in
  check bool "plain wrapper uses test-only recovery" true
    (contains test_go "teslExpectFailure(teslT, func()"
     && contains test_go "_ = RequirePositive(zero)");
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

(* The same Tesl source must pass its own `test` blocks on BOTH backends: the Go
   side runs them as Go tests, this runs them under Racket. *)
let racket_behavior_oracle label source () =
  if Sys.command "raco help >/dev/null 2>&1" <> 0 then
    Printf.printf "SKIP: raco not on PATH\n%!"
  else
    match Compile.compile_source label source with
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

let test_racket_go_behavior_oracle = racket_behavior_oracle "<go-test>" source

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

(* The emitted-code gates are MANDATORY, matching ci.sh phase 2a for the
   hand-written runtime.  Skipping an absent linter here was a fail-open
   asymmetry: a lint finding on emitted code is an emitter bug by contract, so a
   missing linter has to be a failure rather than a silent pass. *)
let required_go_gates = [
  "staticcheck", "staticcheck ./...";
  "golangci-lint", "golangci-lint run ./...";
  "gosec", "gosec -quiet ./...";
  "govulncheck", "govulncheck ./...";
  "nilaway", "nilaway ./...";
]

let run_go_gates root =
  List.iter (fun (tool, command) ->
    if not (command_available tool) then
      failf "required Go gate tool not found: %s (ci.sh phase 2a requires it too)" tool;
    ignore (run_command root command)) required_go_gates

let recursion_source = {|module GoRecursion exposing [factorial, isEven, isOdd, sumTo, sumToLet, drain, countdown, Small, checkSmall]
import Tesl.Prelude exposing [Bool(..), Int]

fn factorial(n: Int) -> Int =
  if n <= 1 then
    1
  else
    n * factorial (n - 1)

fn isEven(n: Int) -> Bool =
  if n <= 0 then
    True
  else
    isOdd (n - 1)

fn isOdd(n: Int) -> Bool =
  if n <= 0 then
    False
  else
    isEven (n - 1)

fn sumTo(n: Int, acc: Int) -> Int =
  if n <= 0 then
    acc
  else
    sumTo (n - 1) (acc + n)

fn sumToLet(n: Int, acc: Int) -> Int =
  if n <= 0 then
    acc
  else
    let next = acc + n
    sumToLet (n - 1) next

fn drain(n: Int, k: Int) -> Int =
  if n <= 0 then
    k
  else
    drain (n - 1) k

fact Small (n: Int)

check checkSmall(n: Int) -> n: Int ::: Small n =
  if n < 10 then
    ok n ::: Small n
  else
    fail 400 "too big"

fn countdown(n: Int) -> Int =
  if n <= 0 then
    0
  else
    countdown (n - 1)

test "recursion" {
  expect factorial 5 == 120
  expect factorial 1 == 1
  expect isEven 10 == True
  expect isOdd 10 == False
  expect isEven 7 == False
  expect sumTo 100 0 == 5050
  expect sumToLet 100 0 == 5050
  expect drain 1000 42 == 42
  expect countdown 100000 == 0
  expect check checkSmall 3 == 3
  expectFail check checkSmall 30
}
|}

(* Racket has TCO and Go does not, and a Go stack overflow is FATAL (unrecoverable
   by `recover`), so a self tail call must become a loop rather than a stack frame —
   otherwise a program that merely runs on Racket kills the Go process. *)
let test_recursion_with_go () =
  let emitted = match Compile.compile_go_source "<go-recursion>" recursion_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "recursion compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgorecursion/module.go" emitted in
  check bool "self tail call becomes a labelled loop" true
    (contains module_go "func SumTo(n teslrt.Int, acc teslrt.Int) teslrt.Int {\nteslLoop:\n\tfor {");
  check bool "each argument lands in its own temporary" true
    (contains module_go "n, acc = teslArg3_0, teslArg3_1");
  check bool "a pass-through argument is never self-assigned" false
    (contains module_go "k = k");
  check bool "self tail call after a let still loops" true
    (contains module_go "next := teslrt.Add(acc, n)"
     && contains module_go "continue teslLoop");
  check bool "non-tail recursion stays plain Go recursion" true
    (contains module_go "teslrt.Mul(n, Factorial(teslrt.Sub(n, teslrt.FromInt64(1))))");
  check bool "a non-looping function carries no unused label" true
    (contains module_go "func Factorial(n teslrt.Int) teslrt.Int {\n//line");
  check bool "mutual recursion emits two plain functions" true
    (contains module_go "return IsOdd(teslrt.Sub(n, teslrt.FromInt64(1)))"
     && contains module_go "return IsEven(teslrt.Sub(n, teslrt.FromInt64(1)))");
  check bool "a recursive check keeps its explicit result" true
    (contains module_go "teslrt.Check[teslrt.Int]");
  if Sys.command "go version >/dev/null 2>&1" = 0 then
    let root = Filename.temp_dir "tesl-go-recursion" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted recursion source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)

(* The loop rewrite only fires when the called name is not shadowed by a local.  That
   guard is containment rather than a reachable case: the frontend rejects shadowing
   outright, which this pins so the guard is not deleted as dead code. *)
let test_self_name_cannot_be_shadowed () =
  let shadowing = {|module ShadowSelf exposing [pick]
import Tesl.Prelude exposing [Int]
fn pick(n: Int) -> Int =
  let pick = n + 1
  pick
|} in
  match Compile.compile_go_source "<go-shadow-self>" shadowing with
  | Compile.GoSuccess _ -> fail "a let shadowing the enclosing function compiled"
  | Compile.GoFailure diagnostics ->
    check bool "the frontend rejects shadowing the enclosing function name" true
      (List.exists (fun (d : Compile.diagnostic) -> contains d.message "shadows") diagnostics)

let generic_source = {|module GoGenerics exposing [Labeled, describeInt, describeText, tagOf]
import Tesl.Prelude exposing [Int, String]

type Labeled a
  = Label tag: String value: a
  | Empty

fn describeInt(x: Labeled Int) -> String =
  case x of
    Label tag value where value > 50 -> "${tag} high ${value}"
    Label tag value -> "${tag} low ${value}"
    Empty -> "empty"

fn describeText(x: Labeled String) -> String =
  case x of
    Label tag value -> "${tag}=${value}"
    Empty -> "empty"

fn tagOf(x: Labeled Int) -> String =
  case x of
    Label tag _ -> tag
    _ -> ""

test "generic ADTs instantiate per use" {
  expect describeInt (Label "a" 99) == "a high 99"
  expect describeInt (Label "a" 1) == "a low 1"
  expect describeInt Empty == "empty"
  expect describeText (Label "k" "v") == "k=v"
  expect describeText Empty == "empty"
  expect tagOf (Label "z" 3) == "z"
  expect tagOf Empty == ""
}
|}

(* Go infers type parameters for calls but never for a composite literal, so every
   emitted constructor of a generic ADT has to name its type arguments. *)
let test_generics_with_go () =
  let emitted = match Compile.compile_go_source "<go-generics>" generic_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "generic ADT compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgogenerics/module.go" emitted in
  let test_go = artifact "internal/teslmodgogenerics/module_test.go" emitted in
  check bool "generic ADT carries Go type parameters" true
    (contains module_go
       "type Labeled[A any] struct {\n\tTag        LabeledTag\n\tLabelTag   string\n\tLabelValue A\n}");
  check bool "constructor names its type arguments" true
    (contains test_go "Labeled[teslrt.Int]{Tag: LabeledLabel, LabelTag: \"a\", LabelValue: teslrt.FromInt64(99)}");
  check bool "a nullary constructor is instantiated by the expected type" true
    (contains test_go "Labeled[teslrt.Int]{Tag: LabeledEmpty}"
     && contains test_go "Labeled[string]{Tag: LabeledEmpty}");
  check bool "payload binds at the instantiated type" true
    (contains module_go "value := teslScrut1.LabelValue");
  check bool "a generic ADT gets no equality method" false (contains module_go "func (teslLeft Labeled");
  if Sys.command "go version >/dev/null 2>&1" = 0 then
    let root = Filename.temp_dir "tesl-go-generics" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted generic source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)

let test_generic_limits_fail_closed () =
  let expect_go_error label needle source =
    match Compile.compile_go_source ("<" ^ label ^ ">") source with
    | Compile.GoSuccess _ -> failf "%s emitted unsupported Go artifacts" label
    | Compile.GoFailure diagnostics ->
      check bool label true
        (List.exists (fun (d : Compile.diagnostic) ->
           d.source = "go-emitter" && contains d.message needle) diagnostics)
  in
  (* Equality would need `TeslEqual` to dispatch `teslrt.Equal` for whatever the
     parameter was instantiated with, which Go generics cannot express. *)
  expect_go_error "equality on a generic ADT" "equality on this type" {|module GenericEq exposing [Boxed, same]
import Tesl.Prelude exposing [Bool, Int]
type Boxed a
  = Box value: a
fn same(left: Boxed Int, right: Boxed Int) -> Bool = left == right
|};
  (* An unapplied generic name never reaches the Go emitter: the frontend already
     requires the type arguments. *)
  (match Compile.compile_go_source "<bare-generic>" {|module BareGeneric exposing [Boxed, unbox]
import Tesl.Prelude exposing [Int]
type Boxed a
  = Box value: a
fn unbox(b: Boxed) -> Int = 0
|} with
   | Compile.GoSuccess _ -> fail "an unapplied generic type emitted Go artifacts"
   | Compile.GoFailure diagnostics ->
     check bool "unapplied generic type rejected before emission" true
       (List.exists (fun (d : Compile.diagnostic) ->
          d.source <> "go-emitter" && contains d.message "type argument") diagnostics));
  (* A nullary constructor outside an expected-type position has nothing to
     instantiate it. *)
  expect_go_error "uninstantiated nullary constructor" "cannot infer type argument"
    {|module LooseNullary exposing [Boxed, make]
import Tesl.Prelude exposing [Int]
type Boxed a
  = Box value: a
  | None_
fn make() -> Int =
  let b = None_
  0
|}

let maybe_source = {|module GoMaybe exposing [Slot, describe, orZero, wrap, none, emptySlot, slotValue]
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]

record Slot {
  label: String
  held: Maybe Int
}

fn describe(m: Maybe Int) -> String =
  case m of
    Something value where value > 10 -> "big ${value}"
    Something value -> "small ${value}"
    Nothing -> "none"

fn orZero(m: Maybe Int) -> Int =
  case m of
    Something value -> value
    Nothing -> 0

fn wrap(value: Int) -> Maybe Int = Something value

fn none() -> Maybe Int = Nothing

fn emptySlot(label: String) -> Slot = Slot { label: label, held: Nothing }

fn slotValue(s: Slot) -> Int =
  case s.held of
    Something value -> value
    Nothing -> 0

test "Maybe comes from the runtime" {
  expect describe (Something 42) == "big 42"
  expect describe (Something 3) == "small 3"
  expect describe Nothing == "none"
  expect orZero (Something 7) == 7
  expect orZero Nothing == 0
  expect orZero (wrap 5) == 5
  expect orZero (none()) == 0
  expect slotValue (emptySlot "a") == 0
  expect slotValue (Slot { label: "b", held: Something 9 }) == 9
}
|}

(* `Maybe` is a RUNTIME type, not an emitted one: a Maybe crosses module boundaries,
   so two emitted packages declaring their own would be incompatible Go types. *)
let test_maybe_with_go () =
  let emitted = match Compile.compile_go_source "<go-maybe>" maybe_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "Maybe compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgomaybe/module.go" emitted in
  check bool "Maybe is referenced from the runtime package" true
    (contains module_go "func Describe(m teslrt.Maybe[teslrt.Int]) string");
  check bool "the runtime type ships with the project" true
    (List.exists (fun (a : Emit_go.artifact) -> a.path = "internal/teslrt/maybe.go") emitted);
  check bool "no Maybe type is emitted per module" false
    (contains module_go "type Maybe" || contains module_go "type MaybeTag");
  check bool "matching reads the exported tag" true
    (contains module_go "teslScrut1.Tag == teslrt.MaybeSomething");
  check bool "payload reads the runtime field name" true
    (contains module_go "value := teslScrut1.SomethingValue");
  check bool "a record field of Maybe type takes a bare Nothing" true
    (contains module_go
       "Slot{Label: label, Held: teslrt.Maybe[teslrt.Int]{Tag: teslrt.MaybeNothing}}");
  check bool "a bare Nothing return is instantiated by the return type" true
    (contains module_go "func None() teslrt.Maybe[teslrt.Int] {"
     && contains module_go "\treturn teslrt.Maybe[teslrt.Int]{Tag: teslrt.MaybeNothing}\n");
  if Sys.command "go version >/dev/null 2>&1" = 0 then
    let root = Filename.temp_dir "tesl-go-maybe" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted Maybe source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)

(* `Tesl.Maybe` exports exactly `Maybe`, `Something`, and `Nothing`
   (type_system.ml), so its whole surface is supported and there is no function left
   to reject there.  What must stay closed is the generalisation: `Maybe` is
   whitelisted by name, not "any generic stdlib ADT". *)
let test_other_stdlib_adts_fail_closed () =
  let unsupported = {|module ResultUser exposing [firstOr]
import Tesl.Prelude exposing [Int]
import Tesl.Result exposing [Result(..)]
fn firstOr(r: Result Int Int) -> Int = 0
|} in
  match Compile.compile_go_source "<go-result>" unsupported with
  | Compile.GoSuccess _ -> fail "an unsupported stdlib ADT emitted Go artifacts"
  | Compile.GoFailure diagnostics ->
    check bool "only Maybe is whitelisted" true
      (List.exists (fun (d : Compile.diagnostic) ->
         d.source = "go-emitter" && contains d.message "import `Tesl.Result`") diagnostics)

let string_source = {|module GoStrings exposing [size, shout, initial, parsed, found, label, checked]
import Tesl.Prelude exposing [Bool, Int, String]
import Tesl.String exposing [String.length, String.isEmpty, String.startsWith, String.contains, String.concat, String.slice, String.toUpper, String.trim, String.fromInt, String.toInt, String.indexOf, String.padLeft, String.requireNonEmpty, IsNonEmpty]
import Tesl.Maybe exposing [Maybe(..)]

fn size(s: String) -> Int = String.length s

fn shout(s: String) -> String = String.toUpper (String.trim s)

fn initial(s: String) -> String = String.slice s 0 1

fn parsed(s: String) -> Int =
  case String.toInt s of
    Something n -> n
    Nothing -> 0

fn found(s: String, needle: String) -> Int =
  case String.indexOf s needle of
    Something at -> at
    Nothing -> 0 - 1

fn label(n: Int) -> String = String.concat "n=" (String.padLeft (String.fromInt n) 3 "0")

fn checked(raw: String) -> String =
  let value = check String.requireNonEmpty raw
  value

test "Tesl.String leaves" {
  expect size "abc" == 3
  expect size "雪だるま" == 4
  expect String.isEmpty "" == True
  expect String.startsWith "abc" "ab" == True
  expect String.contains "abc" "z" == False
  expect shout "  hi  " == "HI"
  expect initial "abc" == "a"
  expect initial "" == ""
  expect parsed "42" == 42
  expect parsed "x" == 0
  expect found "雪だるま" "だ" == 1
  expect found "abc" "z" == 0 - 1
  expect label 7 == "n=007"
  expect checked "ok" == "ok"
  expectFail checked ""
}
|}

(* A `Tesl.String` function is an ordinary signature whose Go name is a runtime
   leaf, so the existing call path emits it.  The interesting parts are that the
   qualified name has to be recognised at all (`String.length s` parses as a field
   access over the module name) and that a leaf returning `Maybe Int` pulls in the
   runtime Maybe without the module naming Maybe. *)
let test_string_stdlib_with_go () =
  let emitted = match Compile.compile_go_source "<go-strings>" string_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "Tesl.String compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgostrings/module.go" emitted in
  check bool "the runtime string leaves ship with the project" true
    (List.exists (fun (a : Emit_go.artifact) -> a.path = "internal/teslrt/string.go") emitted);
  check bool "a qualified stdlib call resolves" true
    (contains module_go "return teslrt.StringLength(s)");
  check bool "nested stdlib calls compose" true
    (contains module_go "return teslrt.StringToUpper(teslrt.StringTrim(s))");
  check bool "a Maybe-returning leaf is matched on the runtime tag" true
    (contains module_go "teslScrut1 := teslrt.StringIndexOf(s, needle)"
     && contains module_go "case teslrt.MaybeSomething:");
  check bool "a stdlib check keeps the explicit result" true
    (contains module_go "teslrt.MustCheck(teslrt.StringRequireNonEmpty(raw))");
  if Sys.command "go version >/dev/null 2>&1" = 0 then
    let root = Filename.temp_dir "tesl-go-strings" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted Tesl.String source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)

let test_unsupported_string_exports_fail_closed () =
  (* `String.split` is supported now that lists are, so the boundary this pins moved:
     `trimLeft`/`trimRight` are still unimplemented leaves of a supported module. *)
  let unsupported = {|module StringTrimLeft exposing [tidy]
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.trimLeft]
fn tidy(s: String) -> String = String.trimLeft s
|} in
  match Compile.compile_go_source "<go-string-trimleft>" unsupported with
  | Compile.GoSuccess _ -> fail "an unsupported Tesl.String export emitted Go artifacts"
  | Compile.GoFailure diagnostics ->
    check bool "an unimplemented leaf of a supported module fails closed" true
      (List.exists (fun (d : Compile.diagnostic) ->
         d.source = "go-emitter" && contains d.message "`String.trimLeft`") diagnostics)

let list_source = {|module GoLists exposing [size, empty, firstOr, rest, joined, parts, top, dedup, ordered, hasTwo, both, prefix]
import Tesl.Prelude exposing [Bool, Int, List, String]
import Tesl.List exposing [List.length, List.isEmpty, List.head, List.tail, List.append, List.take, List.drop, List.reverse, List.sum, List.member, List.unique, List.sort]
import Tesl.String exposing [String.split, String.join]
import Tesl.Int exposing [Int.nonNegative, IsNonNegative]
import Tesl.Maybe exposing [Maybe(..)]

fn size(xs: List Int) -> Int = List.length xs

fn empty(xs: List Int) -> Bool = List.isEmpty xs

fn firstOr(xs: List Int) -> Int =
  case List.head xs of
    Something value -> value
    Nothing -> 0

fn rest(xs: List Int) -> Int =
  case List.tail xs of
    Something more -> List.sum more
    Nothing -> 0

fn joined(pieces: List String) -> String = String.join pieces ","

fn parts(s: String) -> List String = String.split s ","

fn top(xs: List Int) -> List Int =
  let count = check Int.nonNegative 2
  List.take count (List.reverse xs)

fn dedup(xs: List Int) -> List Int = List.unique xs

fn ordered(xs: List String) -> List String = List.sort xs

fn hasTwo(xs: List Int) -> Bool = List.member 2 xs

fn both(xs: List Int, ys: List Int) -> Int = List.sum (List.append xs ys)

fn prefix(xs: List Int) -> List Int =
  let count = check Int.nonNegative 1
  List.drop count xs

test "Tesl.List leaves" {
  let xs = [3, 1, 2]
  expect size xs == 3
  expect size [] == 0
  expect empty [] == True
  expect empty xs == False
  expect firstOr xs == 3
  expect firstOr [] == 0
  expect rest xs == 3
  expect joined ["a", "b"] == "a,b"
  expect parts "a,b" == ["a", "b"]
  expect top xs == [2, 1]
  expect dedup [1, 1, 2, 1] == [1, 2]
  expect ordered ["b", "a"] == ["a", "b"]
  expect hasTwo xs == True
  expect hasTwo [5] == False
  expect both [1] [2, 3] == 6
  expect prefix xs == [1, 2]
  expect [1, 2] != [2, 1]
}
|}

(* A Tesl list is a Go slice, which keeps emitted code idiomatic but makes immutability
   the runtime's job (see internal/teslrt/list.go).  The emitter's part is supplying
   the element comparison a generic Go function cannot express. *)
let test_lists_with_go () =
  let emitted = match Compile.compile_go_source "<go-lists>" list_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "list compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgolists/module.go" emitted in
  let test_go = artifact "internal/teslmodgolists/module_test.go" emitted in
  check bool "the runtime list leaves ship with the project" true
    (List.exists (fun (a : Emit_go.artifact) -> a.path = "internal/teslrt/list.go") emitted);
  check bool "List a is a Go slice" true
    (contains module_go "func Size(xs []teslrt.Int) teslrt.Int");
  check bool "a list literal names its element type" true
    (contains test_go "[]teslrt.Int{teslrt.FromInt64(3), teslrt.FromInt64(1), teslrt.FromInt64(2)}");
  check bool "an empty list literal is typed by the expectation" true
    (contains test_go "Size([]teslrt.Int{})");
  check bool "equality passes an element comparison" true
    (contains module_go
       "teslrt.ListMemberBy(teslrt.FromInt64(2), xs, func(teslX, teslY teslrt.Int) bool { return teslrt.Equal(teslX, teslY) })");
  check bool "sorting passes an element ordering" true
    (contains module_go
       "teslrt.ListSortBy(xs, func(teslX, teslY string) bool { return (teslX < teslY) })");
  check bool "list equality is element-wise through the runtime" true
    (contains test_go "teslrt.ListEqualBy(");
  check bool "a proof-total count goes through its check" true
    (contains module_go "teslrt.MustCheck(teslrt.IntNonNegative(teslrt.FromInt64(2)))");
  if Sys.command "go version >/dev/null 2>&1" = 0 then
    let root = Filename.temp_dir "tesl-go-lists" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted list source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)

let test_unsupported_list_exports_fail_closed () =
  let expect_go_error label needle source =
    match Compile.compile_go_source ("<" ^ label ^ ">") source with
    | Compile.GoSuccess _ -> failf "%s emitted unsupported Go artifacts" label
    | Compile.GoFailure diagnostics ->
      check bool label true
        (List.exists (fun (d : Compile.diagnostic) ->
           d.source = "go-emitter" && contains d.message needle) diagnostics)
  in
  (* The higher-order leaves need function VALUES, which the backend does not have. *)
  expect_go_error "higher-order list leaf" "`List.map`" {|module ListMap exposing [double]
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.map]
fn twice(n: Int) -> Int = n * 2
fn double(xs: List Int) -> List Int = List.map twice xs
|};
  (* `List.sum` on a non-Int list never reaches the emitter — the frontend's own
     signature rejects it — so the emitter's guard is containment, and what this pins
     is that the program is refused SOMEWHERE rather than emitted. *)
  (match Compile.compile_go_source "<sum-strings>" {|module SumStrings exposing [total]
import Tesl.Prelude exposing [Int, List, String]
import Tesl.List exposing [List.sum]
fn total(xs: List String) -> Int = List.sum xs
|} with
   | Compile.GoSuccess _ -> fail "List.sum over strings emitted Go artifacts"
   | Compile.GoFailure diagnostics ->
     check bool "sum of a non-Int list rejected before emission" true
       (List.exists (fun (d : Compile.diagnostic) ->
          d.source <> "go-emitter" && contains d.message "cannot unify") diagnostics));
  (* Sorting IS fully polymorphic in the frontend, so the ordering requirement is the
     emitter's to enforce. *)
  expect_go_error "sort of an unordered element" "needs ordered elements"
    {|module SortBools exposing [ordered]
import Tesl.Prelude exposing [Bool, List]
import Tesl.List exposing [List.sort]
fn ordered(xs: List Bool) -> List Bool = List.sort xs
|}

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
    (contains module_go "type Count struct {\n\tteslValue teslrt.Int\n}");
  check bool "String newtype is nominal" true
    (contains module_go "type Label struct {\n\tteslValue string\n}");
  check bool "Bool newtype is nominal" true
    (contains module_go "type EnabledFlag struct {\n\tteslValue bool\n}");
  check bool "Unit newtype is nominal" true
    (contains module_go "type Marker struct {\n\tteslValue struct{}\n}");
  check bool "newtype Int equality uses runtime helper" true
    (contains module_go "teslrt.Equal(left.teslValue, right.teslValue)");
  check bool "newtype Int ordering uses runtime helper" true
    (contains module_go "teslrt.Compare(left.teslValue, right.teslValue)");
  check bool "newtype checks keep explicit result" true
    (contains module_go "teslrt.Check[Count]");
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

let record_source = {|module GoRecords exposing [Slug, Point, Line, makePoint, moveTo, retarget, sameSpot, slugOf, describeX]
import Tesl.Prelude exposing [Bool(..), Int, String]

type Slug = String

record Point {
  x: Int
  y: Int
}

record Line {
  from: Point
  to: Point
  label: Slug
}

fn makePoint(x: Int, y: Int) -> Point = Point { x: x, y: y }

fn moveTo(p: Point, x: Int) -> Point = { p | x = x }

fn retarget(l: Line, x: Int) -> Line =
  let target = l.to
  { l | to = { target | x = x } }

fn sameSpot(left: Point, right: Point) -> Bool = left == right

fn slugOf(l: Line) -> String = l.label.value

fn describeX(p: Point) -> String = "x=${p.x}"

test "records are nominal structs" {
  let a = makePoint 1 2
  let b = makePoint 1 2
  expect sameSpot a b == True
  expect sameSpot a (makePoint 3 2) == False
  expect a == b
  expect (moveTo a 9).x == 9
  expect (moveTo a 9).y == 2
  expect describeX a == "x=1"
  let chained = { b | y = 7 }
  let twice = { chained | x = 4 }
  expect twice.x == 4
  expect twice.y == 7
  expect b.y == 2
  let line = Line { from: a, to: b, label: Slug "edge" }
  let moved = retarget line 8
  expect moved.to.x == 8
  expect moved.to.y == 2
  expect moved.from.x == 1
  expect slugOf moved == "edge"
  expect moved != line
}
|}

let test_records_with_go () =
  let emitted = match Compile.compile_go_source "<go-records>" record_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "record compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgorecords/module.go" emitted in
  check bool "record is a nominal struct with gofmt-aligned fields" true
    (contains module_go "type Point struct {\n\tX teslrt.Int\n\tY teslrt.Int\n}");
  check bool "record fields may be records and newtypes" true
    (contains module_go
       "type Line struct {\n\tFrom  Point\n\tTo    Point\n\tLabel Slug\n}");
  check bool "record literal names every field" true
    (contains module_go "Point{X: x, Y: y}");
  check bool "record update copies the preserved fields" true
    (contains module_go "Point{X: x, Y: p.Y}");
  check bool "record equality is field-wise, never Go ==" true
    (contains module_go
       "(teslrt.Equal(left.X, right.X) && teslrt.Equal(left.Y, right.Y))");
  check bool "record never compares with Go ==" false (contains module_go "left == right");
  check bool "record field read is direct" true (contains module_go "l.Label");
  let test_go = artifact "internal/teslmodgorecords/module_test.go" emitted in
  check bool "chained update reads the previous copy" true
    (contains test_go "Point{X: teslrt.FromInt64(4), Y: chained.Y}");
  check bool "no double negation in emitted conditions" false (contains test_go "!(!(");
  if Sys.command "go version >/dev/null 2>&1" = 0 then
    let root = Filename.temp_dir "tesl-go-records" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted record source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)

let test_unsupported_records_fail_closed () =
  let expect_go_error label needle source =
    match Compile.compile_go_source ("<" ^ label ^ ">") source with
    | Compile.GoSuccess _ -> failf "%s emitted unsupported Go artifacts" label
    | Compile.GoFailure diagnostics ->
      check bool label true
        (List.exists (fun (d : Compile.diagnostic) ->
           d.source = "go-emitter" && contains d.message needle) diagnostics)
  in
  (* A recursive record is an infinitely sized Go struct. *)
  expect_go_error "recursive record" "recursive record" {|module RecursiveRecord exposing [Node, valueOf]
import Tesl.Prelude exposing [Int]
record Node {
  value: Int
  next: Node
}
fn valueOf(n: Node) -> Int = n.value
|};
  expect_go_error "mutually recursive records" "recursive record" {|module MutualRecord exposing [Left, Right, valueOf]
import Tesl.Prelude exposing [Int]
record Left {
  value: Int
  right: Right
}
record Right {
  left: Left
}
fn valueOf(l: Left) -> Int = l.value
|};
  expect_go_error "record invariant" "record invariants" {|module InvariantRecord exposing [Span, width]
import Tesl.Prelude exposing [Int]
fact Ordered (lo: Int, hi: Int)
record Span {
  lo: Int
  hi: Int
} ::: Ordered lo hi
fn width(s: Span) -> Int = s.hi - s.lo
|};
  expect_go_error "proof-carrying record field" "proof-carrying record field" {|module ProofFieldRecord exposing [Positive, Box, valueOf]
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
record Box {
  value: Int ::: Positive value
}
fn valueOf(b: Box) -> Int = b.value
|};
  expect_go_error "unsupported record field type" "import `Tesl.Float`"
    {|module FloatFieldRecord exposing [Reading, valueOf]
import Tesl.Prelude exposing [Int]
import Tesl.Float exposing [Float]
record Reading {
  celsius: Float
}
fn valueOf(r: Reading) -> Int = 0
|}

let test_missing_record_field_never_reaches_emitter () =
  let invalid = {|module MissingField exposing [Point, make]
import Tesl.Prelude exposing [Int]
record Point {
  x: Int
  y: Int
}
fn make(x: Int) -> Point = Point { x: x }
|} in
  match Compile.compile_go_source "<go-missing-record-field>" invalid with
  | Compile.GoSuccess _ -> fail "partial record literal emitted Go artifacts"
  | Compile.GoFailure diagnostics ->
    check bool "partial record literal rejected before emission" true
      (List.exists (fun (d : Compile.diagnostic) ->
         contains d.message "missing required field") diagnostics)

let adt_source = {|module GoAdts exposing [Status, describe, isOpen, classify, sameStatus, priority]
import Tesl.Prelude exposing [Bool(..), Int, String]

type Status
  = Open
  | Closed
  | Pending (reason: String) (attempts: Int)

fn describe(s: Status) -> String =
  case s of
    Open -> "open"
    Closed -> "closed"
    Pending reason attempts -> "pending ${reason} after ${attempts}"

fn isOpen(s: Status) -> Bool =
  case s of
    Open -> True
    _ -> False

fn classify(s: Status) -> String =
  case s of
    Pending reason attempts where attempts > 3 -> "stuck ${reason}"
    Pending reason _ -> "waiting ${reason}"
    other -> describe other

fn sameStatus(left: Status, right: Status) -> Bool = left == right

fn priority(s: Status) -> Int =
  let base = case s of
    Open -> 1
    Closed -> 0
    Pending _ attempts -> attempts
  base + 1

test "ADTs and case" {
  expect describe Open == "open"
  expect describe Closed == "closed"
  expect describe (Pending "retry" 2) == "pending retry after 2"
  expect isOpen Open == True
  expect isOpen Closed == False
  expect classify (Pending "net" 5) == "stuck net"
  expect classify (Pending "net" 1) == "waiting net"
  expect classify Closed == "closed"
  expect sameStatus Open Open == True
  expect sameStatus Open Closed == False
  expect sameStatus (Pending "a" 1) (Pending "a" 1) == True
  expect sameStatus (Pending "a" 1) (Pending "b" 1) == False
  expect priority (Pending "x" 4) == 5
  expect priority Open == 2
}
|}

let test_adts_with_go () =
  let emitted = match Compile.compile_go_source "<go-adts>" adt_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "ADT compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgoadts/module.go" emitted in
  check bool "ADT tag is an enum type" true
    (contains module_go "type StatusTag int"
     && contains module_go "StatusOpen StatusTag = iota");
  check bool "ADT is one flat value struct" true
    (contains module_go
       "type Status struct {\n\tTag             StatusTag\n\tPendingReason   string\n\tPendingAttempts teslrt.Int\n}");
  let adt_test_go = artifact "internal/teslmodgoadts/module_test.go" emitted in
  check bool "constructor names the tag" true
    (contains adt_test_go "Status{Tag: StatusPending, PendingReason:");
  check bool "guard-free case emits a tag switch" true
    (contains module_go "switch teslScrut1.Tag {\n\t\tcase StatusOpen:");
  check bool "unmatched tag is contained, not silently accepted" true
    (contains module_go "panic(\"unreachable: checker guarantees case exhaustiveness\")");
  check bool "catch-all names the tags it covers, so `exhaustive` can verify it" true
    (contains module_go "case StatusClosed, StatusPending:");
  check bool "TeslEqual lists the payload-free tags too" true
    (contains module_go "case StatusOpen, StatusClosed:\n\t\treturn true");
  let lint_config = artifact ".golangci.yml" emitted in
  check bool "emitted project enables the exhaustive linter" true
    (contains lint_config "- exhaustive"
     && contains lint_config "default-signifies-exhaustive: false");
  check bool "guarded case falls through in order" true
    (contains module_go "if teslScrut1.Tag == StatusPending {");
  check bool "payload binds positionally" true
    (contains module_go "attempts := teslScrut1.PendingAttempts");
  check bool "ADT equality routes through the generated method" true
    (contains module_go "left.TeslEqual(right)"
     && contains module_go "func (teslLeft Status) TeslEqual(teslRight Status) bool");
  check bool "ADT equality never uses Go == on the struct" false
    (contains module_go "left == right");
  if Sys.command "go version >/dev/null 2>&1" = 0 then
    let root = Filename.temp_dir "tesl-go-adts" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted ADT source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)

let test_unsupported_adts_fail_closed () =
  let expect_go_error label needle source =
    match Compile.compile_go_source ("<" ^ label ^ ">") source with
    | Compile.GoSuccess _ -> failf "%s emitted unsupported Go artifacts" label
    | Compile.GoFailure diagnostics ->
      check bool label true
        (List.exists (fun (d : Compile.diagnostic) ->
           d.source = "go-emitter" && contains d.message needle) diagnostics)
  in
  (* Generic ADTs themselves are supported (see the generic-ADT cases); a type
     parameter the emitter cannot resolve to a Go type still fails closed. *)
  expect_go_error "generic function signature" "type variable" {|module GenericFn exposing [identity]
import Tesl.Prelude exposing []
fn identity(value: a) -> a = value
|};
  expect_go_error "recursive ADT" "recursive type" {|module RecursiveAdt exposing [Chain, depth]
import Tesl.Prelude exposing [Int]
type Chain
  = Stop
  | Link (next: Chain)
fn depth(c: Chain) -> Int = 0
|};
  expect_go_error "case over a non-ADT" "case` over a module ADT" {|module CaseOverInt exposing [classify]
import Tesl.Prelude exposing [Int, String]
fn classify(n: Int) -> String =
  case n of
    0 -> "zero"
    _ -> "other"
|};
  expect_go_error "proof-carrying constructor field" "proof-carrying constructor field"
    {|module ProofVariant exposing [Positive, Wrapped, unwrap]
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
type Wrapped
  = Wrap (value: Int ::: Positive value)
fn unwrap(w: Wrapped) -> Int =
  case w of
    Wrap value -> value
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
    (contains module_go "func Label(value string) string");
  check bool "Bool proof parameter erases to Bool" true
    (contains module_go "func Invert(value bool) bool");
  if Sys.command "go version >/dev/null 2>&1" = 0 then
    let root = Filename.temp_dir "tesl-go-proof-scalars" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      ignore (run_command root "go test -count=1 ./..."))

let go_corpus = [
  "example/learn/lesson00-hello-world.tesl";
  "example/learn/lesson03-records.tesl";
  "example/learn/lesson04-newtypes.tesl";
  "example/learn/lesson05-intro-to-proofs.tesl";
  "example/learn/lesson07-home.tesl";
  "example/learn/lesson39-case-where-guards.tesl";
  "example/learn/lesson65-pipe-operators.tesl";
  "example/learn/lesson10-cross-parameter-proofs.tesl";
  "example/learn/lesson40-implicit-value-unwrapping.tesl";
  "example/learn/lesson44-multi-param-proofs.tesl";
  "tests/multiparam_test.tesl";
]

let test_go_corpus_with_go () =
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
        run_go_gates root)) go_corpus

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
      run_go_gates marker)
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
      test_case "recursion" `Slow test_recursion_with_go;
      test_case "recursion behaves the same on Racket" `Slow (racket_behavior_oracle "<go-recursion>" recursion_source);
      test_case "self name cannot be shadowed" `Quick test_self_name_cannot_be_shadowed;
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
      test_case "records" `Slow test_records_with_go;
      test_case "records behave the same on Racket" `Slow (racket_behavior_oracle "<go-records>" record_source);
      test_case "ADTs and case" `Slow test_adts_with_go;
      test_case "generic ADTs" `Slow test_generics_with_go;
      test_case "Maybe from the runtime" `Slow test_maybe_with_go;
      test_case "Tesl.String leaves" `Slow test_string_stdlib_with_go;
      test_case "Tesl.List leaves" `Slow test_lists_with_go;
      test_case "lists behave the same on Racket" `Slow (racket_behavior_oracle "<go-lists>" list_source);
      test_case "unsupported Tesl.List exports fail closed" `Quick test_unsupported_list_exports_fail_closed;
      test_case "Tesl.String behaves the same on Racket" `Slow (racket_behavior_oracle "<go-strings>" string_source);
      test_case "unsupported Tesl.String exports fail closed" `Quick test_unsupported_string_exports_fail_closed;
      test_case "Maybe behaves the same on Racket" `Slow (racket_behavior_oracle "<go-maybe>" maybe_source);
      test_case "other stdlib ADTs fail closed" `Quick test_other_stdlib_adts_fail_closed;
      test_case "generic ADTs behave the same on Racket" `Slow (racket_behavior_oracle "<go-generics>" generic_source);
      test_case "generic limits fail closed" `Quick test_generic_limits_fail_closed;
      test_case "ADTs behave the same on Racket" `Slow (racket_behavior_oracle "<go-adts>" adt_source);
      test_case "unsupported ADTs fail closed" `Quick test_unsupported_adts_fail_closed;
      test_case "unsupported records fail closed" `Quick test_unsupported_records_fail_closed;
      test_case "partial record literal fails before emission" `Quick test_missing_record_field_never_reaches_emitter;
      test_case "Go corpus runs with Go" `Slow test_go_corpus_with_go;
      test_case "fresh module passes Go gates" `Slow test_generated_module_with_go;
    ];
  ]
