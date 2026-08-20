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

let test_debug_emission_has_versioned_checkpoint () =
  let emitted =
    match Compile.compile_go_source ~debug:true "<go-debug>" source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "debug Go compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgosmoke/module.go" emitted in
  let test_go = artifact "internal/teslmodgosmoke/module_test.go" emitted in
  let emitted_again =
    match Compile.compile_go_source ~debug:true "<go-debug>" source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "second debug Go compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_again = artifact "internal/teslmodgosmoke/module.go" emitted_again in
  check bool "debug checkpoint call" true (contains module_go "teslrt.Checkpoint(teslrt.DebugFrame{");
  check bool "debug function scope" true (contains module_go "teslrt.DebugEnter(teslrt.DebugFrame{");
  check bool "debug ABI version" true (contains module_go "teslrt.DebugABIVersion");
  check bool "debug function locals" true (contains module_go "Accessor: func() teslrt.DebugValue");
  check bool "debug test identity" true (contains test_go "Test: ");
  check string "debug IDs are stable" module_go module_again;
  ignore (artifact "internal/teslrt/debug.go" emitted);
  ignore (artifact "internal/teslrt/debug_control.go" emitted);
  ignore (artifact "internal/teslrt/debug_state.go" emitted)

let test_release_emission_excludes_debug_runtime () =
  let emitted = artifacts () in
  let module_go = artifact "internal/teslmodgosmoke/module.go" emitted in
  check bool "release has no checkpoint call" false (contains module_go "teslrt.Checkpoint");
  check bool "release has no debug runtime" false
    (List.exists (fun (a : Emit_go.artifact) ->
       List.mem a.path ["internal/teslrt/debug.go"; "internal/teslrt/debug_control.go"; "internal/teslrt/debug_state.go"]) emitted)

let test_app_module_does_not_shadow_tesl_app () =
  let source = {|module App exposing [answer]
import Tesl.Prelude exposing [Int]
import Tesl.App exposing [App]

fn answer() -> Int = 42
|} in
  match Compile.compile_go_source "<app-module>" source with
  | Compile.GoSuccess _ -> ()
  | Compile.GoFailure diagnostics ->
    failf "module named App must not shadow Tesl.App: %s"
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))

let test_release_artifacts_have_no_debug_symbols () =
  let emitted = artifacts () in
  let forbidden = [
    "teslrt.Checkpoint"; "teslrt.DebugEnter"; "teslrt.DebugLeave";
    "teslrt.DebugABIVersion"; "teslrt.StartDebugControlFromEnvironment";
    "teslrt.RegisterDebugDomainProvider"; "teslrt.DebugPgSql";
  ] in
  List.iter (fun (artifact : Emit_go.artifact) ->
    if Filename.check_suffix artifact.path ".go" then
      List.iter (fun symbol ->
        check bool (artifact.path ^ " has no " ^ symbol) false
          (contains artifact.contents symbol))
        forbidden)
    emitted

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
let racket_behavior_oracle ?(env=[]) label source () =
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
        let command = Printf.sprintf "env %s TESL_REPO_ROOT=%s raco test %s 2>&1"
          (String.concat " " (List.map Filename.quote env))
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
  (* A `secret` over a String IS supported now (see the secret-newtype case below); an
     Int-backed one has no redacting carrier and still fails closed, which keeps this case
     doing what it was written for: proving an unsupported form produces a diagnostic from
     the go-emitter rather than artifacts. *)
  let unsupported = {|module Unsupported exposing []
import Tesl.Prelude exposing [Int]
secret Count = Int
|} in
  match Compile.compile_go_source "<go-unsupported>" unsupported with
  | Compile.GoSuccess _ -> fail "secret newtype emitted instead of failing closed"
  | Compile.GoFailure diagnostics ->
    check bool "go emitter diagnostic" true
      (List.exists (fun (d : Compile.diagnostic) ->
         d.source = "go-emitter" && contains d.message "newtype over String only")
         diagnostics)

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
  (* Float interpolation is supported now (it renders through teslrt.FormatFloat), so
     the boundary moved to a type with no rendering: a list has no interpolated form. *)
  let unsupported = {|module UnsupportedInterpolation exposing [render]
import Tesl.Prelude exposing [Int, List, String]
fn render(xs: List Int) -> String = "value=${xs}"
|} in
  match Compile.compile_go_source "<go-unsupported-interpolation>" unsupported with
  | Compile.GoSuccess _ -> fail "unsupported interpolation emitted Go artifacts"
  | Compile.GoFailure diagnostics ->
    check bool "a type with no interpolated form is rejected" true
      (List.exists (fun (d : Compile.diagnostic) ->
         contains d.message "interpolation") diagnostics)

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

(* Returns the exit code and output instead of failing, for a caller that must tell one
   kind of failure from another. *)
let run_command_status root command =
  let command = Printf.sprintf "cd %s && %s 2>&1" (Filename.quote root) command in
  let channel = Unix.open_process_in command in
  let output = In_channel.input_all channel in
  match Unix.close_process_in channel with
  | Unix.WEXITED code -> code, output
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal -> 128 + signal, output

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

(* `govulncheck` fetches its vulnerability database over the network, so a DNS or
   connectivity blip fails it with a message that reads like a finding on the emitted
   code.  That is a REAL flake: one outage mid-run failed 13 of these tests at once.  A
   fetch failure is reported and skipped; every other failure — including an actual
   vulnerability — still fails the gate, and the tool being absent still fails, since
   silently skipping a missing linter is the fail-open asymmetry noted above. *)
let unreachable_vulnerability_database output =
  let markers = ["dial tcp"; "no such host"; "i/o timeout"; "connection refused";
                 "TLS handshake timeout"; "proxy.golang.org"; "vuln.go.dev"] in
  let contains_marker marker =
    let n = String.length output and m = String.length marker in
    let rec scan i = i + m <= n && (String.sub output i m = marker || scan (i + 1)) in
    m > 0 && scan 0
  in
  List.exists contains_marker markers

(* A vulnerability reachable ONLY through the Go standard library is a TOOLCHAIN problem —
   the emitted code cannot avoid it, and the fix is to build with a newer Go.  Reporting it
   as an emitter bug would be wrong, and suppressing every govulncheck finding would be
   worse, so the two cases are separated: a finding that also implicates a module we
   require or code we emit still fails the gate. *)
let stdlib_only_vulnerability output =
  let contains needle =
    let n = String.length output and m = String.length needle in
    let rec scan index =
      index + m <= n && (String.sub output index m = needle || scan (index + 1)) in
    m > 0 && scan 0
  in
  contains "Your code is affected by"
  && contains "from the Go standard library"
  (* The affected-by sentence names every source it found, so a DEPENDENCY's vulnerability
     that the emitted code actually calls appears as "… and 1 from module github.com/…"
     alongside the standard library's.  Excluding only the "modules you require" wording
     would let that through, since govulncheck reserves that phrase for vulnerabilities it
     found but could NOT reach. *)
  && not (contains "from module ")
  && not (contains "vulnerability from modules you require")
  && not (contains "vulnerabilities from modules you require")

let run_go_gates root =
  List.iter (fun (tool, command) ->
    if not (command_available tool) then
      failf "required Go gate tool not found: %s (ci.sh phase 2a requires it too)" tool;
    match run_command_status root command with
    | 0, _ -> ()
    | _, output when tool = "govulncheck" && unreachable_vulnerability_database output ->
      Printf.printf
        "  SKIP %s: vulnerability database unreachable (network), not a finding\n%!" tool
    (* golangci-lint exits 3 on a RUNNER error (cache contention under a parallel suite),
       which is not the same as "issues found" — and it reported none.  Retried once; a
       second failure still fails the gate with the output. *)
    | 3, output when tool = "golangci-lint" && not (contains output "issues:") ->
      (match run_command_status root command with
       | 0, _ -> Printf.printf "  RETRY %s: runner error, clean on the second run\n%!" tool
       | code, retry_output -> failf "%s exited %d (retry after %d):\n%s" command code 3
           (if retry_output = "" then output else retry_output))
    | _, output when tool = "govulncheck" && stdlib_only_vulnerability output ->
      Printf.printf
        "  TOOLCHAIN %s: the Go standard library in use has a known vulnerability — \
         build with a newer Go.  Not an emitter finding:\n%s\n%!" tool output
    | code, output -> failf "%s exited %d:\n%s" command code output) required_go_gates

(* This case used to assert the emitter REFUSED a program containing an uncalled private
   function, on the grounds that an unused unexported Go function is a lint finding and a
   finding on emitted code is an emitter bug.  The conclusion was wrong: an unused private
   declaration is legal Tesl and the Racket backend emits it, so refusing made a legal
   program un-emittable — lesson35 declares `prependInt` to illustrate it and could not be
   compiled at all.  The function is emitted and referenced once at package level, which
   satisfies the linter without dropping code the author wrote.  The gate is what proves
   it: `run_go_gates` includes the `unused` linter that motivated the original refusal. *)
let test_unreachable_private_function_is_emitted () =
  let source = {|module DeadPrivate exposing [live]
import Tesl.Prelude exposing [Int]
fn live(n: Int) -> Int = n
fn dead(n: Int) -> Int = n + 1
fn alsoDead(n: Int) -> Int = n * 3
|} in
  let emitted = match Compile.compile_go_source "<go-dead-private>" source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "an uncalled private function must still emit: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmoddeadprivate/module.go" emitted in
  check bool "the uncalled function is emitted, not dropped" true
    (contains module_go "func dead(n teslrt.Int) teslrt.Int");
  (* Grouped and name-ordered, so the output is deterministic. *)
  check bool "each uncalled function is kept alive once" true
    (contains module_go "var (" && contains module_go "\t_ = alsoDead"
     && contains module_go "\t_ = dead");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-dead-private" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go vet ./...");
      run_go_gates root)
  end

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
  (* Equality on a generic ADT USED to be rejected — a `TeslEqual` method cannot
     dispatch `teslrt.Equal` for an unknown instantiation.  It is supported now,
     because a payload comparison needs no tag switch: "same tag, and for each variant
     either the tag differs or the payload matches" is an expression.  Pinned as a
     positive so the capability cannot regress into a rejection. *)
  (match Compile.compile_go_source "<generic-eq>" {|module GenericEq exposing [Boxed, same]
import Tesl.Prelude exposing [Bool, Int]
type Boxed a
  = Box value: a
  | Empty
fn same(left: Boxed Int, right: Boxed Int) -> Bool = left == right
|} with
   | Compile.GoFailure diagnostics ->
     failf "generic ADT equality regressed to a rejection: %s"
       (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
   | Compile.GoSuccess artifacts ->
     let module_go = artifact "internal/teslmodgenericeq/module.go" artifacts in
     check bool "generic multi-variant equality is inlined without a tag switch" true
       (contains module_go
          "(left.Tag == right.Tag && (left.Tag != BoxedBox || teslrt.Equal(left.BoxValue, right.BoxValue)))"));
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
  (* A nullary constructor outside an expected-type position has nothing to instantiate it,
     and that is no longer a refusal: the parameter has NO INHABITANTS there — the variant
     that would carry one is not the variant in hand — so it renders as the empty struct.
     It cannot widen a declared type; that is asserted separately ("an anonymous type
     argument does not widen a declared type"). *)
  (match Compile.compile_go_source "<loose-nullary>" {|module LooseNullary exposing [Boxed, make]
import Tesl.Prelude exposing [Int]
type Boxed a
  = Box value: a
  | None_
fn make() -> Int =
  let b = None_
  0
|} with
   | Compile.GoFailure diagnostics ->
     failf "an unconstrained nullary constructor was refused: %s"
       (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
   | Compile.GoSuccess artifacts ->
     let module_go = artifact "internal/teslmodloosenullary/module.go" artifacts in
     check bool "an unsettled type argument is the empty struct" true
       (contains module_go "Boxed[struct{}]{Tag: BoxedNone_}"))

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
  (* `Result` joined `Maybe` and `Either` as a runtime-provided ADT, so it compiles. *)
  let supported = {|module ResultUser exposing [firstOr]
import Tesl.Prelude exposing [Int]
import Tesl.Result exposing [Result(..)]
fn firstOr(r: Result Int Int) -> Int =
  case r of
    Ok value -> value
    Err other -> other
|} in
  (match Compile.compile_go_source "<go-result>" supported with
   | Compile.GoSuccess _ -> ()
   | Compile.GoFailure diagnostics ->
     failf "Result failed to compile: %s"
       (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics)));
  (* `DeleteResult` joined them when `deleteAndReturnResult` landed, so it compiles too. *)
  let delete_result = {|module DeleteResultUser exposing [count]
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [DeleteResult(..)]
fn count(r: DeleteResult) -> Int =
  case r of
    RowsDeleted n -> n
    _ -> 0
|} in
  (match Compile.compile_go_source "<go-delete-result>" delete_result with
   | Compile.GoSuccess _ -> ()
   | Compile.GoFailure diagnostics ->
     failf "DeleteResult failed to compile: %s"
       (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics)));
  (* The point of this case survives: the runtime ADTs are whitelisted BY NAME, not
     "any stdlib ADT".  One that has no runtime type behind it still fails closed.
     `TimeZone` used to be the example and is now BUILT (489 IANA constructors through the
     compiler's own catalogue), so the example is a type that still has nothing behind it —
     which is the point: the list is a list, and a name not on it is refused. *)
  let unsupported = {|module SpanUser exposing [spanName]
import Tesl.Prelude exposing [String]
import Tesl.Telemetry exposing [Span]
fn spanName(s: Span) -> String = "s"
|} in
  match Compile.compile_go_source "<go-span>" unsupported with
  | Compile.GoSuccess _ -> fail "an unsupported stdlib ADT emitted Go artifacts"
  | Compile.GoFailure diagnostics ->
    check bool "an unlisted stdlib ADT is refused" true
      (List.exists (fun (d : Compile.diagnostic) ->
         d.source = "go-emitter" && contains d.message "`Tesl.Telemetry` export `Span`")
        diagnostics)

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
       "teslrt.ListMemberBy(teslrt.FromInt64(2), xs, teslEqualTeslrtInt)");
  check bool "sorting passes an element ordering" true
    (contains module_go
       "teslrt.ListSortBy(xs, teslLessString)");
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
  (* `map`/`filter`/`foldl`/`foldr`/`any`/`all` are loops now, so this moved to the next
     unimplemented higher-order leaf: an unimplemented leaf of a SUPPORTED module must
     still fail closed rather than emit something plausible. *)
  expect_go_error "unimplemented higher-order leaf" "`List.partition`" {|module ListPartition exposing [split]
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.partition]
fn split(xs: List Int) -> List (List Int) = List.partition (fn(x: Int) -> x > 10) xs
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

let hof_source = {|module GoHof exposing [doubled, evens, total, anyBig, allSmall, named, byName, longest]
import Tesl.Prelude exposing [Bool(..), Int, List, String]
import Tesl.List exposing [List.map, List.filter, List.foldl, List.any, List.all, List.length]
import Tesl.String exposing [String.length, String.concat]

fn doubled(xs: List Int) -> List Int = List.map (fn(x: Int) -> x * 2) xs

fn evens(xs: List Int) -> List Int = List.filter (fn(x: Int) -> x % 2 == 0) xs

fn total(xs: List Int) -> Int = List.foldl (fn(acc: Int, x: Int) -> acc + x) 0 xs

fn anyBig(xs: List Int) -> Bool = List.any (fn(x: Int) -> x > 10) xs

fn allSmall(xs: List Int) -> Bool = List.all (fn(x: Int) -> x < 10) xs

fn triple(n: Int) -> Int = n * 3

fn named(xs: List Int) -> List Int = List.map triple xs

fn byName(names: List String) -> List Int = List.map (fn(n: String) -> String.length n) names

fn pickLonger(acc: String, n: String) -> String =
  if String.length n > String.length acc then
    n
  else
    acc

fn longest(names: List String) -> String = List.foldl pickLonger "" names

test "higher-order list leaves" {
  let xs = [1, 2, 3, 11]
  expect doubled xs == [2, 4, 6, 22]
  expect doubled [] == []
  expect evens xs == [2]
  expect total xs == 17
  expect total [] == 0
  expect anyBig xs == True
  expect anyBig [1] == False
  expect allSmall xs == False
  expect allSmall [1, 2] == True
  expect allSmall [] == True
  expect named [1, 2] == [3, 6]
  expect byName ["ab", "c"] == [2, 1]
  expect longest ["a", "bbb", "cc"] == "bbb"
}
|}

(* The higher-order leaves lower to LOOPS, not runtime helpers: a func value passed
   into a generic helper costs an indirect call per element and blocks inlining, and
   these are hot-path operations.  A lambda body is inlined outright. *)
let test_higher_order_lists_with_go () =
  let emitted = match Compile.compile_go_source "<go-hof>" hof_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "higher-order list compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgohof/module.go" emitted in
  check bool "map inlines the lambda body into a loop" true
    (contains module_go
       "teslOut1 := make([]teslrt.Int, len(xs))\n\t\tfor teslAt1, x := range xs {\n\t\t\tteslOut1[teslAt1] = teslrt.Mul(x, teslrt.FromInt64(2))");
  check bool "no closure is allocated for a lambda argument" false
    (contains module_go "func(x teslrt.Int)");
  (* map fills by index into an exact-length slice; filter is the one that appends,
     into a slice preallocated with capacity.  Asserting "no append anywhere" would
     match filter's loop, which reuses the same variable name at the same depth. *)
  check bool "map allocates at exact length and writes by index" true
    (contains module_go "make([]teslrt.Int, len(xs))\n\t\tfor teslAt1, x := range xs {");
  check bool "filter allocates with capacity and appends" true
    (contains module_go "make([]teslrt.Int, 0, len(xs))"
     && contains module_go "teslOut1 = append(teslOut1, x)");
  check bool "foldl threads an accumulator without a closure" true
    (contains module_go "teslState1 = teslrt.Add(acc, x)");
  check bool "all is a structurally negated early return" true
    (contains module_go "if teslrt.Compare(x, teslrt.FromInt64(10)) >= 0 {\n\t\t\t\treturn false");
  (* A named function argument becomes a direct call, and the loop variable falls back
     to a generated name because there is no lambda parameter to name it after.
     `triple` is unexported here because the module does not expose it. *)
  check bool "a named function argument is a direct call" true
    (contains module_go "teslOut1[teslAt1] = triple(Value1)");
  check bool "no runtime higher-order helper is used" false
    (contains module_go "teslrt.ListMap" || contains module_go "teslrt.ListFoldl");
  if Sys.command "go version >/dev/null 2>&1" = 0 then
    let root = Filename.temp_dir "tesl-go-hof" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted higher-order source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)

(* Function VALUES — a `let`-bound lambda, and a `let`-bound partial application — used to
   fail closed here for want of a calling convention. Both emit now: a lambda becomes a Go
   func literal and a partial application the runtime combinator that closes over what was
   given. What they do is tested where the feature lives ("function values and lambdas",
   with its Racket oracle), so this file no longer states the refusal. *)

let check_list_source = {|module GoCheckLists exposing [Small, checkSmall, checkBelow, kept, keptBelow, allKept, sizeOfKept]
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck, List.allCheck, List.length]
import Tesl.Maybe exposing [Maybe(..)]

fact Small (n: Int)

check checkSmall(n: Int) -> n: Int ::: Small n =
  if n < 10 then
    ok n ::: Small n
  else
    fail 400 "too big"

check checkBelow(limit: Int, n: Int) -> n: Int ::: Small n =
  if n < limit then
    ok n ::: Small n
  else
    fail 400 "too big"

fn kept(xs: List Int) -> List Int ::: ForAll (Small) =
  List.filterCheck checkSmall xs

fn keptBelow(limit: Int, xs: List Int) -> List Int ::: ForAll (Small) =
  List.filterCheck (checkBelow limit) xs

fn allKept(xs: List Int) -> Int =
  case List.allCheck checkSmall xs of
    Something values -> List.length values
    Nothing -> 0 - 1

fn sizeOfKept(xs: List Int) -> Int = List.length (kept xs)

test "check-driven list leaves" {
  expect sizeOfKept [1, 20, 3] == 2
  expect sizeOfKept [] == 0
  expect List.length (keptBelow 5 [1, 7, 3]) == 2
  expect allKept [1, 2] == 2
  expect allKept [1, 20] == 0 - 1
  expect allKept [] == 0
}
|}

(* `ForAll` is a TYPE-LEVEL contract with zero runtime structure (LANGUAGE-SPEC 16.9),
   so a `List T ::: ForAll P` return erases to the list — nothing is erased that the
   frontend has not already discharged. *)
let test_check_driven_lists_with_go () =
  let emitted = match Compile.compile_go_source "<go-check-lists>" check_list_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "check-driven list compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgochecklists/module.go" emitted in
  check bool "a ForAll return erases to the list itself" true
    (contains module_go "func Kept(xs []teslrt.Int) []teslrt.Int");
  check bool "filterCheck keeps the accepted value from the check" true
    (contains module_go
       "if teslKept1, teslOK1 := (CheckSmall(Value1)).Value(); teslOK1 {\n\t\t\t\tteslOut1 = append(teslOut1, teslKept1)");
  check bool "a partially applied check is emitted fully applied" true
    (contains module_go "(CheckBelow(limit, Value1)).Value()");
  (* The per-element ok is scoped to its `if`; a running flag sharing that name would
     assign to the shadow and allCheck could never report failure. *)
  check bool "allCheck's running flag is not shadowed by the per-element ok" true
    (contains module_go "teslAll2 := true" && contains module_go "teslAll2 = false");
  check bool "allCheck yields Nothing on any failure" true
    (contains module_go "return teslrt.Maybe[[]teslrt.Int]{Tag: teslrt.MaybeNothing}");
  if Sys.command "go version >/dev/null 2>&1" = 0 then
    let root = Filename.temp_dir "tesl-go-check-lists" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted check-driven source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)

let tuple_source = {|module GoTuples exposing [make, firstOf, secondOf, sumPair, describe, triple, thirdOf, samePair, paired, pairedSize]
import Tesl.Prelude exposing [Bool, Int, List, String]
import Tesl.Tuple exposing [Tuple2, Tuple3, Tuple2.first, Tuple2.second, Tuple3.third]
import Tesl.List exposing [List.zip, List.length]

fn make(a: Int, b: Int) -> Tuple2 Int Int = Tuple2 a b

fn firstOf(p: Tuple2 Int Int) -> Int = Tuple2.first p

fn secondOf(p: Tuple2 Int String) -> String = Tuple2.second p

fn sumPair(p: Tuple2 Int Int) -> Int =
  case p of
    Tuple2 x y -> x + y

fn describe(p: Tuple2 Int String) -> String =
  case p of
    Tuple2 count label -> "${label}=${count}"

fn triple(a: Int, b: String, c: Bool) -> Tuple3 Int String Bool = Tuple3 a b c

fn thirdOf(t: Tuple3 Int String Bool) -> Bool = Tuple3.third t

fn samePair(left: Tuple2 Int Int, right: Tuple2 Int Int) -> Bool = left == right

fn paired(xs: List Int, ys: List String) -> List (Tuple2 Int String) = List.zip xs ys

fn pairedSize(xs: List Int, ys: List String) -> Int = List.length (List.zip xs ys)

test "tuples" {
  expect firstOf (make 3 4) == 3
  expect sumPair (make 3 4) == 7
  expect secondOf (Tuple2 1 "x") == "x"
  expect describe (Tuple2 2 "hits") == "hits=2"
  expect thirdOf (triple 1 "a" True) == True
  expect samePair (make 1 2) (make 1 2) == True
  expect samePair (make 1 2) (make 2 1) == False
  expect make 1 2 == make 1 2
  expect pairedSize [1, 2, 3] ["a", "b"] == 2
  expect Tuple2.second (Tuple2 0 "z") == "z"
}
|}

(* A tuple is a single-variant generic ADT, so it needs no tag: matching binds the
   payload directly and equality is field-wise — which also makes a GENERIC type
   comparable, since the emitter knows the instantiation at the comparison site. *)
let test_tuples_with_go () =
  let emitted = match Compile.compile_go_source "<go-tuples>" tuple_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "tuple compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgotuples/module.go" emitted in
  check bool "the runtime tuple types ship with the project" true
    (List.exists (fun (a : Emit_go.artifact) -> a.path = "internal/teslrt/tuple.go") emitted);
  check bool "a tuple literal carries no tag" true
    (contains module_go
       "teslrt.Tuple2[teslrt.Int, teslrt.Int]{Tuple2First: a, Tuple2Second: b}");
  check bool "matching a tuple binds its payload without a switch" true
    (contains module_go "x := teslScrut1.Tuple2First"
     && contains module_go "y := teslScrut1.Tuple2Second");
  check bool "a single-variant match emits no tag switch" false
    (contains module_go "switch teslScrut1.Tag");
  check bool "an accessor is a field read" true
    (contains module_go "return p.Tuple2First");
  check bool "a generic single-variant type is still comparable" true
    (contains module_go
       "(teslrt.Equal(left.Tuple2First, right.Tuple2First) && teslrt.Equal(left.Tuple2Second, right.Tuple2Second))");
  check bool "zip truncates to the shorter list" true
    (contains module_go "teslLen1 := len(teslLeft1)"
     && contains module_go "if len(teslRight1) < teslLen1 {");
  check bool "zip builds tuples without a runtime helper" true
    (contains module_go "Tuple2First: teslLeft1[teslAt1], Tuple2Second: teslRight1[teslAt1]");
  (* `make` is predeclared in Go, so the collision rule must rename it. *)
  check bool "a name colliding with a Go predeclared identifier is renamed" true
    (contains module_go "func Make_(");
  if Sys.command "go version >/dev/null 2>&1" = 0 then
    let root = Filename.temp_dir "tesl-go-tuples" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted tuple source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)

let either_source = {|module GoEither exposing [parse, describe, orZero, sameOutcome, sameMaybe]
import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Either exposing [Either(..)]
import Tesl.Maybe exposing [Maybe(..)]

fn parse(raw: Int) -> Either String Int =
  if raw < 0 then
    Left "negative"
  else
    Right raw

fn describe(e: Either String Int) -> String =
  case e of
    Left reason -> "bad: ${reason}"
    Right value -> "ok: ${value}"

fn orZero(e: Either String Int) -> Int =
  case e of
    Left _ -> 0
    Right value -> value

fn sameOutcome(left: Either String Int, right: Either String Int) -> Bool = left == right

fn sameMaybe(left: Maybe Int, right: Maybe Int) -> Bool = left == right

test "Either from the runtime" {
  expect describe (parse 5) == "ok: 5"
  expect describe (parse -1) == "bad: negative"
  expect orZero (parse 5) == 5
  expect orZero (parse -1) == 0
  expect sameOutcome (parse 5) (parse 5) == True
  expect sameOutcome (parse 5) (parse 6) == False
  expect sameOutcome (parse -1) (parse 5) == False
  expect sameMaybe (Something 1) (Something 1) == True
  expect sameMaybe (Something 1) (Something 2) == False
  expect sameMaybe Nothing (Something 1) == False
  expect sameMaybe Nothing Nothing == True
}
|}

(* Either is the same runtime-provided shape as Maybe.  The interesting part is that
   `Left "x"` never mentions the Right type parameter, so its instantiation has to come
   from the expectation — including through an `if`, where each BRANCH is what carries
   the under-constrained constructor. *)
let test_either_with_go () =
  let emitted = match Compile.compile_go_source "<go-either>" either_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "Either compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgoeither/module.go" emitted in
  check bool "the runtime Either ships with the project" true
    (List.exists (fun (a : Emit_go.artifact) -> a.path = "internal/teslrt/either.go") emitted);
  check bool "a constructor mentioning one parameter is instantiated by the expectation" true
    (contains module_go
       "return teslrt.Either[string, teslrt.Int]{Tag: teslrt.EitherLeft, LeftValue: \"negative\"}");
  check bool "both branches of an if resolve against the return type" true
    (contains module_go
       "return teslrt.Either[string, teslrt.Int]{Tag: teslrt.EitherRight, RightValue: raw}");
  check bool "matching Either reads the runtime field names" true
    (contains module_go "reason := teslScrut1.LeftValue"
     && contains module_go "value := teslScrut1.RightValue");
  (* A runtime or generic ADT gets no `TeslEqual` method — a method needs a type the
     module declares — so its payload comparison is inlined instead. *)
  check bool "runtime ADT equality is inlined, not a method call" true
    (contains module_go
       "(left.Tag == right.Tag && (left.Tag != teslrt.MaybeSomething || teslrt.Equal(left.SomethingValue, right.SomethingValue)))");
  check bool "no TeslEqual method is expected on a runtime type" false
    (contains module_go "teslrt.Maybe" && contains module_go ".TeslEqual(");
  if Sys.command "go version >/dev/null 2>&1" = 0 then
    let root = Filename.temp_dir "tesl-go-either" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted Either source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)

let dict_source = {|module GoDicts exposing [build, get, has, size, without, names, sameDict, fromPairs]
import Tesl.Prelude exposing [Bool(..), Int, List, String]
import Tesl.Dict exposing [Dict, Dict.insert, Dict.lookup, Dict.member, Dict.remove, Dict.size, Dict.keys, Dict.values, Dict.toList, Dict.fromList]
import Tesl.Tuple exposing [Tuple2]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.List exposing [List.length, List.member]

fn build(d: Dict String Int, key: String, value: Int) -> Dict String Int =
  Dict.insert key value d

fn get(d: Dict String Int, key: String) -> Int =
  case Dict.lookup key d of
    Something value -> value
    Nothing -> 0

fn has(d: Dict String Int, key: String) -> Bool = Dict.member key d

fn size(d: Dict String Int) -> Int = Dict.size d

fn without(d: Dict String Int, key: String) -> Dict String Int = Dict.remove key d

fn names(d: Dict String Int) -> List String = Dict.keys d

fn sameDict(left: Dict String Int, right: Dict String Int) -> Bool = left == right

fn fromPairs(pairs: List (Tuple2 String Int)) -> Dict String Int = Dict.fromList pairs

test "Tesl.Dict leaves" {
  let base = fromPairs [Tuple2 "b" 2, Tuple2 "a" 1]
  expect size base == 2
  expect get base "a" == 1
  expect get base "zz" == 0
  expect has base "b" == True
  expect has base "zz" == False
  expect size (build base "c" 3) == 3
  expect get (build base "a" 9) "a" == 9
  expect size (without base "a") == 1
  # Dict iteration order is UNSPECIFIED in Tesl (tesl/dict.rkt iterates a hash), so a
  # test may only observe membership and size — never an order. The Go backend happens
  # to iterate sorted, and asserting that here would fail on Racket.
  expect List.length (names base) == 2
  expect List.member "a" (names base) == True
  expect List.member "b" (names base) == True
  expect List.member "zz" (names base) == False
  expect List.length (Dict.values base) == 2
  expect List.length (Dict.toList base) == 2
  expect sameDict base (fromPairs [Tuple2 "a" 1, Tuple2 "b" 2]) == True
  expect sameDict base (fromPairs [Tuple2 "a" 1]) == False
  expect fromPairs [Tuple2 "a" 1, Tuple2 "a" 2] == fromPairs [Tuple2 "a" 2]
}
|}

(* A Dict is entries kept sorted by key rather than a Go map.  Two reasons, both in
   internal/teslrt/dict.go: a Go map cannot be keyed by the non-comparable teslrt.Int
   at all, and Go randomises map iteration order PER RUN — which would make the same
   binary print different output on different runs, strictly worse than Racket's
   unspecified-but-stable hash order.  Sorted order costs nothing here: the insertion
   point is the binary search lookup already performs. *)
let test_dicts_with_go () =
  let emitted = match Compile.compile_go_source "<go-dicts>" dict_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "Dict compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgodicts/module.go" emitted in
  check bool "the runtime Dict ships with the project" true
    (List.exists (fun (a : Emit_go.artifact) -> a.path = "internal/teslrt/dict.go") emitted);
  check bool "a Dict type renders with both parameters" true
    (contains module_go "d teslrt.Dict[string, teslrt.Int]");
  (* Tesl puts the dict last; the runtime signatures put it first, so the emitter
     rotates rather than distorting the hand-written Go. *)
  check bool "the dict argument is rotated to the front" true
    (contains module_go "teslrt.DictInsert(d, key, value, teslKeyLessString)");
  check bool "a key-finding leaf carries the key ordering" true
    (contains module_go
       "teslrt.DictLookup(d, key, teslKeyLessString)");
  check bool "lookup yields a Maybe matched on the runtime tag" true
    (contains module_go "case teslrt.MaybeSomething:");
  check bool "dict equality is one pass with both comparisons supplied" true
    (contains module_go "teslrt.DictEqualBy(left, right, teslEqualString");
  if Sys.command "go version >/dev/null 2>&1" = 0 then
    let root = Filename.temp_dir "tesl-go-dicts" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted Dict source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)

let test_unordered_dict_keys_fail_closed () =
  (* The representation finds keys by ordering, so a key type with no ordering cannot
     be stored — better a rejection than a silently wrong lookup. *)
  let unsupported = {|module BoolKeys exposing [get]
import Tesl.Prelude exposing [Bool, Int]
import Tesl.Dict exposing [Dict, Dict.member]
fn get(d: Dict Bool Int) -> Bool = Dict.member True d
|} in
  match Compile.compile_go_source "<go-bool-dict>" unsupported with
  | Compile.GoSuccess _ -> fail "a dict with unordered keys emitted Go artifacts"
  | Compile.GoFailure diagnostics ->
    check bool "unordered dict keys fail closed" true
      (List.exists (fun (d : Compile.diagnostic) ->
         d.source = "go-emitter" && contains d.message "needs ordered keys") diagnostics)

let float_source = {|module GoFloats exposing [half, scale, average, describe, rounded, biggest, sameValue, ordered, parsed, safeSqrt]
import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Float exposing [Float, FloatNonNegative, Float.abs, Float.max, Float.round, Float.sqrt, Float.requireNonNegative, Float.toString, Float.parse]
import Tesl.Maybe exposing [Maybe(..)]

fn half(x: Float) -> Float = x / 2.0

fn scale(x: Float, factor: Float) -> Float = x * factor + 1.0

fn average(a: Float, b: Float) -> Float = (a + b) / 2.0

fn describe(x: Float) -> String = "value=${x}"

fn rounded(x: Float) -> Int = Float.round x

fn biggest(a: Float, b: Float) -> Float = Float.max a b

fn sameValue(a: Float, b: Float) -> Bool = a == b

fn ordered(a: Float, b: Float) -> Bool = a < b

fn safeSqrt(x: Float) -> Float =
  let nonNegative = check Float.requireNonNegative x
  Float.sqrt nonNegative

fn parsed(raw: String) -> Float =
  case Float.parse raw of
    Something value -> value
    Nothing -> 0.0

test "Float arithmetic and rendering" {
  expect half 5.0 == 2.5
  expect scale 2.0 3.0 == 7.0
  expect average 1.0 2.0 == 1.5
  expect describe 1.0 == "value=1.0"
  expect describe 0.5 == "value=0.5"
  expect rounded 2.5 == 2
  expect rounded 3.5 == 4
  expect biggest 1.0 2.0 == 2.0
  expect Float.abs -2.5 == 2.5
  expect safeSqrt 4.0 == 2.0
  expect safeSqrt 0.0 == 0.0
  expectFail safeSqrt -1.0
  expect Float.toString 100.0 == "100.0"
  expect sameValue 1.0 1.0 == True
  expect sameValue 1.0 2.0 == False
  expect ordered 1.0 2.0 == True
  expect parsed "1.5" == 1.5
  expect parsed "x" == 0.0
}
|}

(* Float is float64, but three things are NOT Go's defaults, and each is emitted
   deliberately: literals are TYPED (Go folds untyped constant arithmetic exactly, so
   `0.1 + 0.2` would become 0.3 where Racket gives 0.30000000000000004), equality is
   structural rather than IEEE, and rendering appends `.0` so a Float is never mistaken
   for an Int. *)
let test_floats_with_go () =
  let emitted = match Compile.compile_go_source "<go-floats>" float_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "Float compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgofloats/module.go" emitted in
  check bool "Float is float64" true (contains module_go "func Half(x float64) float64");
  check bool "arithmetic is native, not a runtime helper" true
    (contains module_go "return (x / float64(2))");
  check bool "a literal is typed, never an untyped constant" false
    (contains module_go "/ 2)" && contains module_go "* 3)");
  check bool "a literal reads as decimal, not a hex float" false (contains module_go "0x1p");
  check bool "equality is structural, never Go ==" true
    (contains module_go "teslrt.FloatEqual(a, b)");
  check bool "ordering is native IEEE" true (contains module_go "return (a < b)");
  check bool "interpolation renders through the runtime" true
    (contains module_go "teslrt.FormatFloat(x)");
  (* sqrt now carries a FloatNonNegative obligation, so the proof erases here but the
     check that discharged it is real code. *)
  check bool "a discharged sqrt proof erases to the plain call" true
    (contains module_go "teslrt.MustCheck(teslrt.FloatRequireNonNegative(x))"
     && contains module_go "return teslrt.FloatSqrt(nonNegative)");
  if Sys.command "go version >/dev/null 2>&1" = 0 then
    let root = Filename.temp_dir "tesl-go-floats" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted Float source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)

(* ── Float KEYS in Dict and Set ────────────────────────────────────────────────
   Dict and Set are sorted, so their binary search reads key equivalence off the
   comparator: "neither side is less" means "same key".  IEEE ordering therefore cannot
   be the key comparator, because its equivalence classes are not `FloatEqual`'s — every
   NaN comparison is false (so a NaN key matched whatever the search probed first, and
   `Set.member NaN {1,2,3}` returned TRUE) and -0.0 compares equal to +0.0 (while
   `FloatEqual` distinguishes them, so the two keys collapsed into one).  User-visible
   comparisons and `List.sort` keep plain IEEE; only the collection key path changes.
   Reported by the migration review; the runtime's own float_test.go carries the
   exhaustive comparator laws, including NaN payloads and signs. *)
let float_key_source = {|module GoFloatKeys exposing [Weight, zeroKeys, newtypeKeys, ieeeOrdering, noWeights]
import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Float exposing [Float]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Set exposing [Set, Set.insert, Set.singleton, Set.size]
import Tesl.Dict exposing [Dict, Dict.insert, Dict.lookup, Dict.size, Dict.empty]

type Weight = Float

# -0.0 and 0.0 are DISTINCT keys, because Float equality distinguishes them.
fn zeroKeys() -> Int =
  let s = Set.insert 0.0 (Set.singleton -0.0)
  Set.size s

# A Float-backed newtype inherits the key comparator.
fn newtypeKeys() -> Int =
  let s = Set.insert (Weight 0.0) (Set.singleton (Weight -0.0))
  Set.size s

# User-visible comparison stays plain IEEE: -0.0 is NOT less than 0.0.
fn ieeeOrdering() -> Bool = -0.0 < 0.0

fn noWeights() -> Dict Float String = Dict.empty

test "float keys are not IEEE-ordered" {
  expect zeroKeys() == 2
  expect newtypeKeys() == 2
  expect ieeeOrdering() == False
  expect (0.0 < 1.0) == True
  let d = Dict.insert 0.0 "pos" (Dict.insert -0.0 "neg" (noWeights()))
  expect Dict.size d == 2
  expect Dict.lookup -0.0 d == Something "neg"
  expect Dict.lookup 0.0 d == Something "pos"
}
|}

let test_float_keys_with_go () =
  let emitted = match Compile.compile_go_source "<go-float-keys>" float_key_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "float key compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgofloatkeys/module.go" emitted in
  check bool "a Float-keyed Set orders by the KEY comparator" true
    (contains module_go "func teslKeyLessFloat64(teslX, teslY float64) bool"
     && contains module_go "teslrt.FloatKeyLess(teslX, teslY)");
  (* The review asked for this explicitly: a Float-backed newtype must inherit it. *)
  check bool "a Float-backed newtype key inherits the key comparator" true
    (contains module_go "teslrt.FloatKeyLess(teslX.Value, teslY.Value)");
  check bool "user-visible ordering stays plain IEEE" true
    (contains module_go "(math.Copysign(0, -1) < float64(0))");
  (* `-0.0` has no Go literal: `-float64(0)` is POSITIVE zero (staticcheck SA4026), so
     negation folds into the literal.  That also means the module needs `math` imported —
     which it did not, because no earlier probe used a negative-zero, NaN or infinity
     literal. *)
  check bool "a negative zero literal is a real negative zero" true
    (contains module_go "math.Copysign(0, -1)"
     && not (contains module_go "-float64(0)"));
  check bool "a math literal pulls in the math import" true
    (contains module_go "\t\"math\"" || contains module_go "import \"math\"");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-floatkeys" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)
  end

(* ── `List.foldr` ─────────────────────────────────────────────────────────────
   Emitted as a BACKWARDS loop, not recursion: Go has no TCO and a Go stack overflow is
   a fatal error `recover` cannot catch, so recursing once per element would put a list
   length ceiling on a function Racket runs fine.  The list is bound once because it is
   an arbitrary expression and backwards iteration needs both its length and an index.
   The callback takes (element, accumulator) — the REVERSE of `foldl` — which was
   confirmed against `tesl/list-derived.rkt` (`(f *first (foldr f acc *rest))`) rather
   than read off a doc string, since lesson53 names its foldr parameters the other way
   round and would have misled the guess.

   What this does NOT fix: a callback that performs an immutable write on a growing
   accumulator.  `List.append [x] acc` copies Θ(k) at step k, so the canonical
   reconstruction fold below is Θ(n²) in the CALLBACK.  Lowering recognised builder folds
   to an allocate-once private builder is a tracked gate that needs an escape/linearity
   condition first — an arbitrary callback may retain an earlier accumulator inside its
   result, so uniqueness cannot be inferred from the call shape alone. *)
let foldr_source = {|module GoFoldr exposing [sumRight, joinRight, minusRight, reverseList, prependInt, countLong, bumpIfLong]
import Tesl.Prelude exposing [Bool(..), Int, List, String]
import Tesl.List exposing [List.foldr, List.append, List.length]
import Tesl.String exposing [String.length]

fn sumRight(ns: List Int) -> Int =
  List.foldr (fn(x: Int, acc: Int) -> x + acc) 0 ns

# Direction-sensitive: a left-to-right loop with this callback would give "cba".
fn joinRight(parts: List String) -> String =
  List.foldr (fn(x: String, acc: String) -> "${x}${acc}") "" parts

# Non-associative, so it pins the nesting: 1 - (2 - (3 - 0)) = 2.
fn minusRight(ns: List Int) -> Int =
  List.foldr (fn(x: Int, acc: Int) -> x - acc) 0 ns

# A NAMED callback, and the canonical list-reconstruction shape.
fn prependInt(x: Int, acc: List Int) -> List Int =
  List.append [x] acc

fn reverseList(ns: List Int) -> List Int =
  List.foldr prependInt [] ns

# The accumulator has a different type from the element.
fn bumpIfLong(w: String, acc: Int) -> Int =
  if String.length w > 3 then
    acc + 1
  else
    acc

fn countLong(words: List String) -> Int =
  List.foldr bumpIfLong 0 words

test "foldr folds from the right" {
  expect sumRight [1, 2, 3] == 6
  expect sumRight [] == 0
  expect joinRight ["a", "b", "c"] == "abc"
  expect minusRight [1, 2, 3] == 2
  expect reverseList [1, 2, 3] == [1, 2, 3]
  expect List.length (reverseList [4, 5]) == 2
  expect countLong ["hi", "there", "you", "friend"] == 2
}
|}

let test_foldr_with_go () =
  let emitted = match Compile.compile_go_source "<go-foldr>" foldr_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "foldr compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgofoldr/module.go" emitted in
  check bool "foldr walks the slice backwards in a plain loop" true
    (contains module_go "for teslAt1 := len(teslSource1) - 1; teslAt1 >= 0; teslAt1-- {");
  check bool "the list is bound once rather than re-evaluated" true
    (contains module_go "teslSource1 := ns");
  (* Argument order is the whole correctness question for foldr: `x - acc`, not
     `acc - x`. *)
  check bool "the callback receives (element, accumulator)" true
    (contains module_go "teslState1 = teslrt.Sub(x, acc)");
  check bool "a named callback is called directly" true
    (contains module_go "teslState1 = PrependInt(Value1, teslAcc1)");
  (* An empty list literal init has no element type of its own; the named callback's
     declared result type supplies it. *)
  check bool "an empty accumulator is typed from the callback's result" true
    (contains module_go "teslState1 := []teslrt.Int{}");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-foldr" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)
  end

(* A fold whose initial accumulator is a bare `[]` and whose callback is a LAMBDA — the
   idiomatic list-rebuilding fold, and what lesson35 writes.  Nothing about `[]` says what
   it holds, so the type comes from the lambda's own parameter annotation at the
   accumulator position; that needed the module's type table where only `signatures` was
   threaded, hence `current_types`.  This started life as a fail-closed test and became a
   positive one when the support landed: `foldl` had the same limitation, so both are
   pinned here. *)
let fold_empty_init_source = {|module GoFoldEmptyInit exposing [rebuild, reverseLeft]
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.foldr, List.foldl, List.append]

fn rebuild(xs: List Int) -> List Int =
  List.foldr (fn(x: Int, acc: List Int) -> List.append [x] acc) [] xs

# lesson35's idiomatic reverse: foldl with a lambda and a bare [] init.
fn reverseLeft(xs: List Int) -> List Int =
  List.foldl (fn(acc: List Int, x: Int) -> List.append [x] acc) [] xs

test "lambda folds with an empty init" {
  expect rebuild [1, 2, 3] == [1, 2, 3]
  expect reverseLeft [1, 2, 3] == [3, 2, 1]
  expect reverseLeft [] == []
}
|}

let test_fold_empty_init_with_go () =
  let emitted = match Compile.compile_go_source "<go-fold-empty-init>" fold_empty_init_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "empty-init fold compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgofoldemptyinit/module.go" emitted in
  check bool "the empty accumulator is typed from the lambda's annotation" true
    (contains module_go "teslState1 := []teslrt.Int{}");
  check bool "both fold directions accept it" true
    (contains module_go "func Rebuild(" && contains module_go "func ReverseLeft(");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-emptyinit" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)
  end

(* Five more `Tesl.List` leaves.  `range` and `repeat` CONSTRUCT a list rather than
   consuming one, so they carry no list argument for the leaf table to read an element
   type from and are resolved on their own: `range` is always `List Int`, `repeat` takes
   its element from its first argument.  Both counts carry an `IsNonNegative` proof that
   erases, so the runtime check is containment rather than the enforcement.  `concat` and
   `flatten` are the same leaf under two names (per the stdlib docs) and size the result
   before filling, so a list of n lists costs one allocation instead of n appends;
   `maximum`/`minimum` are `Nothing` for the empty list and take the ordering the emitter
   supplies, which is what lets them work on a non-Int element type. *)
let list_leaves_source = {|module GoListLeaves exposing [counts, copies, flat, biggest, smallest, biggestWord]
import Tesl.Prelude exposing [Int, List, String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.List exposing [List.range, List.repeat, List.concat, List.flatten, List.maximum, List.minimum, List.length]
import Tesl.Int exposing [Int.nonNegative]

fn counts(n: Int) -> List Int =
  let safeN = check Int.nonNegative n
  List.range 0 safeN

fn copies(word: String, n: Int) -> List String =
  let safeN = check Int.nonNegative n
  List.repeat word safeN

fn flat(xss: List (List Int)) -> List Int =
  List.concat xss

fn biggest(ns: List Int) -> Maybe Int =
  List.maximum ns

fn smallest(ns: List Int) -> Maybe Int =
  List.minimum ns

# Ordering on a non-Int element type.
fn biggestWord(words: List String) -> Maybe String =
  List.maximum words

test "constructing and reducing lists" {
  expect counts 4 == [0, 1, 2, 3]
  expect counts 0 == []
  expect copies "a" 3 == ["a", "a", "a"]
  expect copies "a" 0 == []
  expect flat [[1, 2], [], [3]] == [1, 2, 3]
  expect List.length (flat []) == 0
  expect biggest [3, 9, 2] == Something 9
  expect smallest [3, 9, 2] == Something 2
  expect biggest [] == Nothing
  expect biggestWord ["pear", "apple"] == Something "pear"
}
|}

let test_list_leaves_with_go () =
  let emitted = match Compile.compile_go_source "<go-list-leaves>" list_leaves_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "list leaf compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgolistleaves/module.go" emitted in
  check bool "range and repeat resolve without a list argument" true
    (contains module_go "teslrt.ListRange(" && contains module_go "teslrt.ListRepeat(");
  check bool "concat and flatten share one runtime leaf" true
    (contains module_go "teslrt.ListConcat(");
  check bool "maximum takes the ordering the emitter supplies" true
    (contains module_go "teslrt.ListMaximum(ns, teslLessTeslrtInt)");
  (* The element type is what makes the ordering closure work on a non-Int list. *)
  check bool "ordering follows the element type" true
    (contains module_go "teslrt.ListMaximum(words, teslLessString)");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-list-leaves" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)
  end

(* Four more higher-order leaves: `find`, `filterMap`, `concatMap`, `sortBy`.
   `find` is an early-return loop; `filterMap` and `concatMap` fill a fresh output.
   `sortBy` orders by a KEY function, and it needed two things the others did not.  A
   stdlib function passed as the callback (`List.sortBy String.length words`, which is what
   the corpus writes) parses as a field access over the module name, so the callable is
   normalised before anything treats it as one.  And a comparator needs the key on BOTH
   sides, which a lambda body inlined twice cannot supply — its parameter name is bound to
   neither side — so a lambda key is hoisted into a named function and each side becomes a
   direct call.  The comparator itself is hoisted too, for the same gofmt size-heuristic
   reason nested element comparators are.  Helpers are keyed by their own SOURCE rather
   than a counter: every function body is emitted twice (once assuming it loops, then flat),
   so a counter minted a second name per pass and left unused functions behind — which the
   `unused` linter caught. *)
let higher_order_leaves_source = {|module GoHigherOrder exposing [firstBig, byLength, byLengthLambda, allDigits, evens, keepEven, digitsOf, longest]
import Tesl.Prelude exposing [Bool(..), Int, List, String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.List exposing [List.find, List.filterMap, List.concatMap, List.sortBy, List.length, List.maximum]
import Tesl.String exposing [String.length, String.split]

fn firstBig(ns: List Int) -> Maybe Int =
  List.find (fn(n: Int) -> n > 10) ns

# A named key function, ordered by Int.
fn byLength(words: List String) -> List String =
  List.sortBy String.length words

# A lambda key, and a key type that is not the element type.
fn byLengthLambda(words: List String) -> List String =
  List.sortBy (fn(w: String) -> String.length w) words

# sortBy over a String key.
fn allDigits(words: List String) -> List String =
  List.sortBy (fn(w: String) -> w) words

fn keepEven(n: Int) -> Maybe Int =
  if n % 2 == 0 then
    Something n
  else
    Nothing

fn evens(ns: List Int) -> List Int =
  List.filterMap keepEven ns

fn digitsOf(word: String) -> List String =
  String.split word ","

fn longest(words: List String) -> List String =
  List.concatMap digitsOf words

test "higher-order list leaves" {
  expect firstBig [1, 20, 30] == Something 20
  expect firstBig [1, 2] == Nothing
  expect byLength ["ccc", "a", "bb"] == ["a", "bb", "ccc"]
  expect byLengthLambda ["ccc", "a", "bb"] == ["a", "bb", "ccc"]
  expect allDigits ["pear", "apple"] == ["apple", "pear"]
  expect evens [1, 2, 3, 4] == [2, 4]
  expect longest ["a,b", "c"] == ["a", "b", "c"]
  # A stable sort keeps equal keys in input order.
  expect byLength ["bb", "aa"] == ["bb", "aa"]
}
|}

let test_higher_order_leaves_with_go () =
  let emitted = match Compile.compile_go_source "<go-hof-leaves>" higher_order_leaves_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "higher-order leaf compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgohigherorder/module.go" emitted in
  check bool "find is an early-return loop, not a runtime call" true
    (contains module_go "return teslrt.Maybe[teslrt.Int]{Tag: teslrt.MaybeSomething");
  (* The whole point of the filterMap fix: the TAG decides, never the payload. *)
  check bool "filterMap keeps an element by its tag" true
    (contains module_go ".Tag == teslrt.MaybeSomething {");
  check bool "concatMap appends each result" true
    (contains module_go "append(teslOut1, ");
  check bool "a stdlib function works as a sortBy key" true
    (contains module_go "teslrt.StringLength(teslLeft)");
  check bool "the comparator is hoisted, not inlined" true
    (contains module_go "teslrt.ListSortBy(words, teslSortLess");
  check bool "a lambda key becomes a named function" true
    (contains module_go "func teslSortKey");
  (* Hoisted helpers live at package level, so their parameter names are FIXED — a
     depth-derived name differed between the two emission passes. *)
  check bool "hoisted helper parameters are not depth-derived" true
    (contains module_go "func teslSortLess1(teslLeft, teslRight string) bool");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-hof-leaves" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)
  end

(* `List.filterMap` over a `Maybe Bool`.  Racket's implementation fed the payload to
   `filter-map`, so `Something False` was silently DROPPED — `filterMap toFlag [0, 1, 2]`
   returned one element where all three mapped to Something.  Fixed in tesl/list.rkt; this
   runs on both backends, so it pins the agreement rather than just the Go side. *)
let filter_map_bool_source = {|module GoFilterMapBool exposing [flags, evens, toFlag, keepEven]
import Tesl.Prelude exposing [Bool(..), Int, List]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.List exposing [List.filterMap, List.length]

# Every element maps to Something, so the result must keep all three — including False.
fn toFlag(n: Int) -> Maybe Bool =
  if n > 1 then
    Something True
  else
    Something False

fn flags(ns: List Int) -> List Bool =
  List.filterMap toFlag ns

fn keepEven(n: Int) -> Maybe Int =
  if n % 2 == 0 then
    Something n
  else
    Nothing

fn evens(ns: List Int) -> List Int =
  List.filterMap keepEven ns

test "filterMap keeps every Something" {
  expect List.length (flags [0, 1, 2]) == 3
  expect flags [0, 1, 2] == [False, False, True]
  expect evens [1, 2, 3, 4] == [2, 4]
}
|}

(* A proof-bearing return (`-> List Int ? IsSorted`) erases to the value's own type: the
   frontend has discharged the proof, and a proof has no runtime structure in Go.  Racket
   keeps an `attach-proof-to` wrapper, but every read there goes through `raw-value`, so
   that wrapper is an implementation detail of that backend rather than part of the value.
   The parser puts the first `? P` in `entity_proof` whether or not it is provenance, so
   that field cannot distinguish a FromDb proof — it does not need to, because `entity`
   and `database` declarations are refused before this point.

   Also here: an `if` BRANCH that is under-constrained alone while the other settles the
   type (the `concatMap` lambda below), and the two cases where a leaf may take an empty
   list literal with nothing to infer from — `List.sum` has its element fixed by its own
   signature, and `List.length`/`List.isEmpty` return an Int/Bool, so the element type is
   unobservable.  `List.reverse []` is NOT in that set: its result mentions the element, so
   choosing one would be a guess, and it still fails closed. *)
let proof_return_source = {|module GoProofReturns exposing [sortInts, tagsOf, sizeOf, totalOf, emptyOf]
import Tesl.Prelude exposing [Bool(..), Int, List, String]
import Tesl.List exposing [List.sort, List.concatMap, List.sum, List.isEmpty, List.length, IsSorted]
import Tesl.String exposing [String.isEmpty]

# A proof-bearing return: the proof erases, so the Go type is the list itself.
fn sortInts(ns: List Int) -> List Int ? IsSorted =
  List.sort ns

# The `[]` branch is under-constrained alone; the other branch settles it.
fn tagsOf(tags: List String) -> List String =
  List.concatMap (fn(s: String) ->
    if String.isEmpty s then
      []
    else
      [s]
  ) tags

# The element type is unobservable here: the result is an Int or a Bool.
fn sizeOf() -> Int = List.length []
fn totalOf() -> Int = List.sum []
fn emptyOf() -> Bool = List.isEmpty []

test "proof-bearing returns and unobservable empties" {
  expect sortInts [3, 1, 2] == [1, 2, 3]
  expect tagsOf ["a", "", "b"] == ["a", "b"]
  expect sizeOf() == 0
  expect totalOf() == 0
  expect emptyOf() == True
}
|}

let test_proof_bearing_returns_with_go () =
  let emitted = match Compile.compile_go_source "<go-proof-returns>" proof_return_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "proof-bearing return compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgoproofreturns/module.go" emitted in
  check bool "the proof erases from the return type" true
    (contains module_go "func SortInts(ns []teslrt.Int) []teslrt.Int");
  check bool "an unobservable empty list still emits" true
    (contains module_go "teslrt.ListLength([]teslrt.Int{})");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-proof-returns" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      run_go_gates root)
  end

(* An empty list whose element type NOTHING determines — `List.reverse [] == []`, where
   both sides are empty.  This used to fail closed; it compiles now (maintainer,
   2026-08-13), because the program is legal Tesl that Racket runs and refusing the whole
   module over it is a divergence with no upside.  The element type is unobservable in
   this situation, and a wrong choice cannot ship silently: Go's own compiler rejects the
   emitted code if the context demanded a different type — which the gate below runs. *)
let test_unconstrained_empty_list_compiles () =
  let emitted = match Compile.compile_go_source "<go-empty-unconstrained>" {|module GoEmptyUnconstrained exposing [same, alsoSame]
import Tesl.Prelude exposing [Bool, List, String]
import Tesl.List exposing [List.reverse]
fn same() -> Bool = List.reverse [] == []
# A real type on either side still wins over the default.
fn alsoSame(words: List String) -> Bool = List.reverse words == []
|} with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "an unconstrained empty list must compile: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgoemptyunconstrained/module.go" emitted in
  check bool "a defaulted empty list picks one element type" true
    (contains module_go "teslrt.ListReverse([]teslrt.Int{})");
  (* The default must never outrank a real type. *)
  check bool "a constrained side still wins" true
    (contains module_go "teslrt.ListReverse(words)" && contains module_go "[]string{}");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-empty" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      ignore (run_command root "go build ./...");
      ignore (run_command root "go vet ./..."))
  end

(* Six more `Tesl.Int` leaves.  `clamp`, `pow`, `isEven` and `isOdd` already existed in the
   runtime; `sign`, `isEven`/`isOdd` and `toString` needed free-function wrappers because
   the emitter calls a leaf as `teslrt.Name(args)` while those were methods.  `Int.pow`
   REJECTS a negative exponent, matching tesl/int.rkt — there is no integer result, and
   `Float.pow` is the function for a fractional one.  `Int.clamp` keeps Racket's
   `(max lo (min hi n))` shape, so a `lo` above `hi` yields `lo` rather than being
   reported. *)
let int_leaves_source = {|module GoIntLeaves exposing [bounded, parity, oddity, powerOf, signOf, shown]
import Tesl.Prelude exposing [Bool, Int, String]
import Tesl.Int exposing [Int.clamp, Int.isEven, Int.isOdd, Int.pow, Int.sign, Int.toString]

fn bounded(n: Int) -> Int = Int.clamp n 0 10
fn parity(n: Int) -> Bool = Int.isEven n
fn oddity(n: Int) -> Bool = Int.isOdd n
fn powerOf(n: Int) -> Int = Int.pow n 3
fn signOf(n: Int) -> Int = Int.sign n
fn shown(n: Int) -> String = Int.toString n

test "Tesl.Int leaves" {
  expect bounded 42 == 10
  expect bounded (-5) == 0
  expect bounded 7 == 7
  expect parity (-4) == True
  expect oddity (-3) == True
  expect powerOf 2 == 8
  expect signOf (-9) == -1
  expect signOf 0 == 0
  expect shown (-12) == "-12"
}
|}

let test_int_leaves_with_go () =
  let emitted = match Compile.compile_go_source "<go-int-leaves>" int_leaves_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "Int leaf compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgointleaves/module.go" emitted in
  check bool "clamp keeps Racket's argument order" true
    (contains module_go "teslrt.Clamp(n, teslrt.FromInt64(0), teslrt.FromInt64(10))");
  check bool "pow raises on a negative exponent rather than returning an error" true
    (contains module_go "teslrt.MustPow(");
  check bool "method-only leaves get free-function wrappers" true
    (contains module_go "teslrt.IntSign(n)" && contains module_go "teslrt.IntToString(n)");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-int-leaves" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      run_go_gates root)
  end

(* `establish` and first-class proof values (`Fact P`).  An `establish` returns a DETACHED
   proof — a witness a caller can carry and attach later with `f <| value ::: pf`.  All of
   it erases: `dsl/private/check-runtime.rkt` states the rule outright ("the proof is
   asserted without re-checking — correctness is guaranteed by the compile-time type
   system"), and LANGUAGE-SPEC 16.9 gives a proof no runtime structure.  So `Fact P` is a
   zero-size value, an `establish` body (which builds a proof TERM, not a value) is not
   emitted at all, and the proof combinators reduce to their value operand.
   The parse detail that matters: `value ::: proof` in expression position produces the
   SAME node as a check's `ok value ::: P`.  They are told apart by what is expected — a
   check's tail wants a `Check`, an ordinary parameter wants the value. *)
let establish_source = {|module GoEstablish exposing [Named, proveHttp, needHttp, useProof]
import Tesl.Prelude exposing [Int, String, Fact]

fact Named (name: String) (port: Int)

establish proveHttp(port: Int) -> Fact (Named "http" port) =
  Named "http" port

fn needHttp(port: Int ::: Named "http" port) -> Int = port

fn useProof(raw: Int) -> Int =
  let pf = proveHttp raw
  needHttp <| raw ::: pf

test "detached proofs erase" {
  expect useProof 8080 == 8080
}
|}

let test_establish_with_go () =
  let emitted = match Compile.compile_go_source "<go-establish>" establish_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "establish compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgoestablish/module.go" emitted in
  check bool "a detached proof is a zero-size value" true
    (contains module_go "func ProveHttp(port teslrt.Int) struct{}");
  check bool "the proof term is not emitted" true
    (not (contains module_go "Named"));
  (* The attachment disappears: the callee takes the value alone. *)
  check bool "proof attachment erases at the call site" true
    (contains module_go "return NeedHttp(raw)");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-establish" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      run_go_gates root)
  end

(* ── HTTP: `api` + `server` + `handler` ───────────────────────────────────────
   An `api` declares endpoints; a `server` binds handlers to them POSITIONALLY in
   declaration order (the endpoint's own `name` is a parser placeholder).  Both emit as
   ordinary Go values, so someone who sheds Tesl can read the routing table, call a handler
   directly, or mount the server on any net/http mux.

   The per-request state a handler may write (cookies) is created by the dispatcher and
   passed in — no ambient state, and no goroutine-local substitute, because Tesl already
   says which functions need it via `requires [cookieCap]`.

   Request bodies decode through the codec the same module emits, so the accepted bytes are
   the ones the codec layer already agrees with Racket on, and the two failure strings
   ("Missing JSON payload" / "Malformed JSON payload") are the ones the Racket server
   sends. *)
let http_server_source = {|module GoHttpServer exposing [Greeting, NewGreeting, hello, greet, lookup]
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec]

record Greeting {
  message: String
}

record NewGreeting {
  name: String
}

codec Greeting {
  toJson {
    message -> "message" with_codec stringCodec
  }
  fromJson_forbidden
}

codec NewGreeting {
  toJson_forbidden
  fromJson [
    {
      name <- "name" with_codec stringCodec
    }
  ]
}

handler get hello() -> Greeting =
  Greeting { message: "hi" }

handler post greet(body: NewGreeting) -> Greeting =
  Greeting { message: "hello ${body.name}" }

handler get lookup(id: String) -> Greeting =
  Greeting { message: "id=${id}" }

api HelloApi {
  get "/hello"
    -> Greeting

  post "/greet"
    body body: NewGreeting
    -> Greeting

  get "/items/:id"
    capture id: String using stringCodec
    -> Greeting
}

server HelloServer for HelloApi {
  hello
  greet
  lookup
}
|}

(* Driven through the EMITTED server value: a real request in, JSON out. *)
let http_server_e2e_test = {|package teslmodgohttpserver

import (
	"io"
	"net/http/httptest"
	"strings"
	"testing"
)

// End to end through the EMITTED server value: a real request in, JSON out. Nothing here
// touches ambient state — the dispatcher creates the request scope and passes it in.
func do(t *testing.T, method, path, body string) (int, string) {
	t.Helper()
	return doTyped(t, method, path, body, "application/json")
}

// A body carries a content type, because a real client sends one: an endpoint that declares a
// payload refuses anything that does not say JSON, which is what `dsl/web.rkt` does too.
func doTyped(t *testing.T, method, path, body, contentType string) (int, string) {
	t.Helper()
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(method, path, strings.NewReader(body))
	if contentType != "" {
		request.Header.Set("Content-Type", contentType)
	}
	HelloServer.ServeHTTP(recorder, request)
	response := recorder.Result()
	out, _ := io.ReadAll(response.Body)
	return response.StatusCode, string(out)
}

func TestEmittedServer(t *testing.T) {
	if status, body := do(t, "GET", "/hello", ""); status != 200 || body != `{"message":"hi"}` {
		t.Errorf("GET /hello = %d %s", status, body)
	}
	// The request body decodes through the codec the same module emitted.
	if status, body := do(t, "POST", "/greet", `{"name":"ada"}`); status != 200 ||
		body != `{"message":"hello ada"}` {
		t.Errorf("POST /greet = %d %s", status, body)
	}
	// A `:id` segment reaches the handler.
	if status, body := do(t, "GET", "/items/42", ""); status != 200 ||
		body != `{"message":"id=42"}` {
		t.Errorf("GET /items/42 = %d %s", status, body)
	}
}

func TestEmittedServerRejections(t *testing.T) {
	// Malformed JSON and a missing required field are both 400, with the messages the
	// Racket server sends.
	if status, body := do(t, "POST", "/greet", `{"name":`); status != 400 ||
		!strings.Contains(body, "Malformed JSON payload") {
		t.Errorf("malformed = %d %s", status, body)
	}
	if status, body := do(t, "POST", "/greet", `{}`); status != 400 {
		t.Errorf("missing field = %d %s", status, body)
	}
	// A declared payload is CHECKED before it is parsed: the wrong content type is 415 and an
	// empty body is 400, both before the decoder sees anything. Same statuses as the Racket
	// server, and only reachable over a real request — an api-test on either backend hands the
	// dispatcher a body that is JSON by construction.
	if status, body := doTyped(t, "POST", "/greet", `{"name":"ada"}`, "text/plain"); status != 415 ||
		!strings.Contains(body, "Expected application/json payload") {
		t.Errorf("wrong content type = %d %s", status, body)
	}
	if status, body := doTyped(t, "POST", "/greet", "", "application/json"); status != 400 ||
		!strings.Contains(body, "Missing JSON payload") {
		t.Errorf("empty body = %d %s", status, body)
	}
	if status, _ := do(t, "GET", "/nope", ""); status != 404 {
		t.Errorf("unknown path status = %d", status)
	}
	if status, _ := do(t, "DELETE", "/hello", ""); status != 405 {
		t.Errorf("wrong method status = %d", status)
	}
}
|}

let test_http_server_with_go () =
  let emitted = match Compile.compile_go_source "<go-http-server>" http_server_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "HTTP server compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgohttpserver/module.go" emitted in
  check bool "the routing table is data" true
    (contains module_go "{Method: \"GET\", Path: \"/hello\", Endpoint: \"hello\"}");
  check bool "a handler is an ordinary function" true
    (contains module_go "func Hello() Greeting");
  check bool "the response goes through the type's codec" true
    (contains module_go "Body: EncodeGreetingJSON(Hello())");
  check bool "a request body decodes through the codec" true
    (contains module_go "teslDecoded := DecodeNewGreetingJSON(teslParsed)");
  check bool "a path capture reaches the handler" true
    (contains module_go "teslrt.PathParam(\"/items/:id\", teslRequest.URL.Path, \"id\")");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-http" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      (* The end-to-end test is written INTO the emitted tree, so it exercises the server
         value the emitter produced rather than a hand-written copy of it. *)
      let test_path =
        Filename.concat root "internal/teslmodgohttpserver/server_e2e_test.go" in
      Out_channel.with_open_bin test_path (fun channel ->
        output_string channel http_server_e2e_test);
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)
  end

(* ── The GDP trust boundary at the HTTP edge ──────────────────────────────────
   An endpoint's `auth … via cookieAuth` runs BEFORE captures and the body: a request that
   is not authenticated is rejected before anything else about it is examined.  An `auth`
   function is a check over the request, so it emits exactly like one — `Check[T]` carrying
   the proven value — and the proof itself erases, so the handler receives the value its
   proof-annotated parameter requires.

   `HttpRequest` is runtime-provided: a plain value the dispatcher builds per request with
   only the fields Tesl exposes, rather than handing an ejecting author all of net/http.
   Its cookie/header/query maps are `teslrt.Dict`, and they are built with plain string
   ordering — the same comparator the emitter passes at a `Dict.lookup` on String keys, so
   the lookup is correct by construction rather than by luck. *)
let http_auth_source = {|module GoHttpAuth exposing [Greeting, Authenticated, cookieAuth, whoami]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]

record Greeting {
  message: String
}

codec Greeting {
  toJson {
    message -> "message" with_codec stringCodec
  }
  fromJson_forbidden
}

fact Authenticated (user: String)

auth cookieAuth(request: HttpRequest) -> user: String ::: Authenticated user =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "not authenticated"
    Something userId -> ok userId ::: Authenticated user

handler get whoami(user: String ::: Authenticated user) -> Greeting =
  Greeting { message: "you are ${user}" }

api HelloApi {
  get "/whoami"
    auth user: String ::: Authenticated user via cookieAuth
    -> Greeting
}

server HelloServer for HelloApi {
  whoami
}
|}

let http_auth_e2e_test = {|package teslmodgohttpauth

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// The GDP trust boundary at the HTTP edge: the handler body runs only once `cookieAuth`
// has produced the proven value its parameter requires. Unauthenticated requests never
// reach it.
func TestAuthAtTheBoundary(t *testing.T) {
	call := func(cookie string) (int, string) {
		recorder := httptest.NewRecorder()
		request := httptest.NewRequest("GET", "/whoami", nil)
		if cookie != "" {
			request.AddCookie(&http.Cookie{Name: "user", Value: cookie})
		}
		HelloServer.ServeHTTP(recorder, request)
		response := recorder.Result()
		body, _ := io.ReadAll(response.Body)
		return response.StatusCode, string(body)
	}

	if status, body := call("ada"); status != 200 || body != `{"message":"you are ada"}` {
		t.Errorf("authenticated = %d %s", status, body)
	}
	// No cookie: 401 with the auth function's own message, and the handler never runs.
	status, body := call("")
	if status != 401 {
		t.Errorf("unauthenticated status = %d, want 401", status)
	}
	if !contains(body, "not authenticated") {
		t.Errorf("unauthenticated body = %s", body)
	}
}

func contains(haystack, needle string) bool {
	return len(haystack) >= len(needle) && (func() bool {
		for i := 0; i+len(needle) <= len(haystack); i++ {
			if haystack[i:i+len(needle)] == needle {
				return true
			}
		}
		return false
	})()
}
|}

let test_http_auth_with_go () =
  let emitted = match Compile.compile_go_source "<go-http-auth>" http_auth_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "HTTP auth compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgohttpauth/module.go" emitted in
  check bool "an auth function emits as a check over the request" true
    (contains module_go "func CookieAuth(request teslrt.HttpRequest) teslrt.Check[string]");
  (* The body is read ONCE, up front, and handed to the auth: an auth may verify a MAC over the
     raw bytes, and `teslRequest.Body` is a stream that can only be read once. *)
  check bool "auth runs before the handler body" true
    (contains module_go "teslAuth := CookieAuth(teslrt.NewHttpRequest(teslRequest, teslBodyText))");
  (* Through `teslrt.ReadRequestBody`, which applies the size cap `dsl/web.rkt` applies —
     the body is parsed whole in memory, so an uncapped read is a one-request exhaustion. *)
  check bool "and it sees the bytes that arrived, under the shared body cap" true
    (contains module_go
       "teslBodyBytes, teslBodyStatus, teslBodyMessage := teslrt.ReadRequestBody(teslRequest)");
  check bool "a failed auth returns its own status and message" true
    (contains module_go "return teslrt.Fail(teslAuth.Status(), teslAuth.Message())");
  (* The proof erases: what reaches the handler is the value. *)
  check bool "the proven value reaches the handler" true
    (contains module_go "EncodeGreetingJSON(Whoami(user))");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-http-auth" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let test_path = Filename.concat root "internal/teslmodgohttpauth/auth_e2e_test.go" in
      Out_channel.with_open_bin test_path (fun channel ->
        output_string channel http_auth_e2e_test);
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      run_go_gates root)
  end

(* A CHECKED path capture: the capturer names how the segment is parsed and a check that
   mints a proof on it — the same "prove before the body runs" rule auth follows, applied
   to a path segment.  A failing check returns its own status, so a bad segment never
   reaches the handler. *)
let http_capture_source = {|module GoHttpCapture exposing [Greeting, ValidId, checkId, item]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
import Tesl.String exposing [String.isEmpty]

record Greeting {
  message: String
}

codec Greeting {
  toJson {
    message -> "message" with_codec stringCodec
  }
  fromJson_forbidden
}

fact ValidId (id: String)

check checkId(id: String) -> id: String ::: ValidId id =
  if String.isEmpty id then
    fail 400 "id must not be empty"
  else
    ok id ::: ValidId id

capturer itemIdCapture: String ::: ValidId id using stringCodec via checkId

handler get item(id: String ::: ValidId id) -> Greeting =
  Greeting { message: "item ${id}" }

api HelloApi {
  get "/items/:id"
    capture id: String ::: ValidId id via itemIdCapture
    -> Greeting
}

server HelloServer for HelloApi {
  item
}
|}

(* Cookie writing, which is what settled the ambient-state question.  `wipe` is a plain
   `fn`, NOT a handler: it may write to the response because it declares
   `requires [cookieCap]`, and `logout` can pass it a scope because the checker forces the
   caller to declare the same capability.  The `requires` clause IS the marker — no
   ambient state, no goroutine-local substitute, and no call-graph analysis.  Every other
   function in the module keeps a plain signature. *)
let http_cookie_source = {|module GoHttpCookie exposing [Status, logout, wipe]
import Tesl.Prelude exposing [String, Unit]
import Tesl.Json exposing [stringCodec]
import Tesl.Http exposing [cookieCap, Http.clearSessionCookie]

record Status {
  state: String
}

codec Status {
  toJson {
    state -> "state" with_codec stringCodec
  }
  fromJson_forbidden
}

# A plain fn that writes a cookie: legal because it declares the capability, and the
# checker forces every caller to declare it too.
fn wipe() -> Unit requires [cookieCap] =
  Http.clearSessionCookie()

handler post logout() -> Status requires [cookieCap] =
  let _ = wipe()
  Status { state: "logged out" }

api HelloApi {
  post "/logout"
    -> Status
}

server HelloServer for HelloApi {
  logout
}
|}

(* Tesl `api-test` blocks driving the emitted server IN PROCESS — no socket, so they are
   ordinary `go test` cases.  Racket dispatches the same way, so both backends exercise the
   same layer.  The statements are the same `test_stmt` forms an ordinary `test` block
   uses, so only the request verbs needed emitting. *)
let go_api_test_source = {|module GoApiTest exposing [Greeting, hello]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
import Tesl.ApiTest exposing [HttpResponse, statusOk, statusClientError]

record Greeting {
  message: String
}

codec Greeting {
  toJson {
    message -> "message" with_codec stringCodec
  }
  fromJson_forbidden
}

handler get hello() -> Greeting =
  Greeting { message: "hi" }

api HelloApi {
  get "/hello"
    -> Greeting
}

server HelloServer for HelloApi {
  hello
}

api-test "GET /hello returns the greeting" for HelloServer requires [] {
  let r = get "/hello"
  expect statusOk r.status
  expect r.body.message == "hi"
}

api-test "an unknown path is a client error" for HelloServer requires [] {
  let r = get "/nope"
  expect statusClientError r.status
}
|}

let emit_ok label source =
  match Compile.compile_go_source label source with
  | Compile.GoSuccess artifacts -> artifacts
  | Compile.GoFailure diagnostics ->
    failf "%s failed to compile: %s" label
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))

let gate_emitted ?(env=[]) ?(short=false) prefix emitted =
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir prefix "" in
    (* A test body may read configuration the emitted program requires — a signing key, say —
       so the environment travels with the gate rather than being global to the suite. *)
    let with_env command =
      match env with
      | [] -> command
      (* Through `env`: a quoted `NAME=value` word is a COMMAND to the shell, not an
         assignment, so prefixing directly runs the assignment as a program. *)
      | bindings -> "env " ^ String.concat " " (List.map Filename.quote bindings) ^ " " ^ command
    in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      (* `-race` when the emitted program STARTS GOROUTINES, and only then.
         Emitted tests are sequential — no `t.Parallel` — so most trees have nothing to race,
         and the detector costs wall clock on every case.  What does start goroutines is
         `workers` (a queue's worker pool), an SSE channel's delivery, and `serve` itself, and
         those are exactly the trees where a data race in the runtime or in emitted state would
         hide.  Detected from the emitted source rather than declared per case, so a new test
         that happens to start workers cannot forget to ask for it. *)
      let starts_goroutines =
        List.exists (fun (artifact : Emit_go.artifact) ->
          Filename.check_suffix artifact.path ".go"
          && not (Filename.check_suffix artifact.path "_test.go")
          && (contains artifact.contents "teslrt.StartWorkers("
              || contains artifact.contents "teslrt.Serve("
              || contains artifact.contents "teslrt.Publish("))
          emitted
      in
      (* `-short` where the emitted tests include a LOAD test: it takes seconds by construction
         (a warm-up plus a measured window), and its value is in `bench/`, not in this suite. *)
      let test_command =
        (if short then "go test -short -count=1" else "go test -count=1")
        ^ (if starts_goroutines then " -race" else "") ^ " ./..."
      in
      ignore (run_command root (with_env test_command));
      ignore (run_command root "go vet ./...");
      run_go_gates root)
  end

let test_http_capture_with_go () =
  let emitted = emit_ok "<go-http-capture>" http_capture_source in
  let module_go = artifact "internal/teslmodgohttpcapture/module.go" emitted in
  check bool "the capturer's check runs on the segment" true
    (contains module_go "teslCapturedId := CheckId(id)");
  check bool "a failing capture returns the check's own status" true
    (contains module_go "return teslrt.Fail(teslCapturedId.Status(), teslCapturedId.Message())");
  gate_emitted "tesl-go-http-capture" emitted

(* Release and unattached debug builds must execute the same generated tests. The debug
   process still starts its inert control seam, but no listener/configuration is installed;
   this gate catches instrumentation that changes evaluation or test outcomes. *)
let test_release_debug_unattached_equivalence () =
  let release = artifacts () in
  let debug =
    match Compile.compile_go_source ~debug:true "<go-debug-equivalence>" source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "debug equivalence compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  gate_emitted ~short:true "tesl-go-release-equivalence" release;
  gate_emitted ~short:true "tesl-go-debug-equivalence" debug

let test_http_cookie_with_go () =
  let emitted = emit_ok "<go-http-cookie>" http_cookie_source in
  let module_go = artifact "internal/teslmodgohttpcookie/module.go" emitted in
  (* A plain `fn` gets the scope because it declares the capability. *)
  check bool "a cookieCap function takes the request scope" true
    (contains module_go "func Wipe(teslScope *teslrt.RequestScope) struct{}");
  check bool "the caller passes its own scope down" true
    (contains module_go "_ = Wipe(teslScope)");
  check bool "the cookie is written through the scope" true
    (contains module_go "teslrt.ClearSessionCookie(teslScope)");
  gate_emitted "tesl-go-http-cookie" emitted

let test_go_api_tests () =
  let emitted = emit_ok "<go-api-test>" go_api_test_source in
  let tests_go = artifact "internal/teslmodgoapitest/module_test.go" emitted in
  check bool "an api-test becomes a Go test" true
    (contains tests_go "func TestTeslApi0(teslT *testing.T)");
  check bool "the request drives the emitted server in process" true
    (contains tests_go "teslrt.ApiRequest(HelloServer, \"GET\", \"/hello\", \"\", nil, nil)");
  check bool "a status predicate becomes a runtime call" true
    (contains tests_go "teslrt.StatusOk(r.Status)");
  (* The response body is inspected WITHOUT types, exactly as on Racket: a field read is a
     dynamic read on the parsed body, not a string compare against serialised JSON. *)
  check bool "a body field read is a dynamic JSON read" true
    (contains tests_go "teslrt.JsonEqual(teslrt.JsonFieldOf(r.Body, \"message\"), \"hi\")");
  (* `go test` on the emitted tree RUNS these, so a wrong body or status fails here. *)
  gate_emitted "tesl-go-api-test" emitted


(* ─── Databases ───────────────────────────────────────────────────────────────
   The `backend: Memory` slice end to end: an entity's row struct and table, the write
   forms (insert / insertMany / update … set / delete), and the read forms (select,
   selectOne, selectCount, selectSum, selectMax/Min, where predicates including `like`,
   `order`, `limit`).  Racket runs the same source as the oracle. *)
let db_source = {|module GoDb exposing [orderedNames, titleOf]

import Tesl.Prelude exposing [Bool(..), Int, String, List, Unit]
import Tesl.Int exposing [Int.toString]
import Tesl.List exposing [List.length, List.map, List.head]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.DB exposing [dbRead, dbWrite, DeleteResult(..)]
import Tesl.Database exposing [Database, Memory]

type Sku = String

entity Item table "probe_items" primaryKey id {
  id: String
  sku: Sku
  name: String
  qty: Int
}

database ProbeDb = Database {
  entities: [Item]
  backend: Memory
}

fn titleOf(wanted: String) -> String
  requires [dbRead] =
  let found = selectOne i from Item where i.id == wanted
  case found of
    Nothing -> "none"
    Something i -> i.name

fn orderedNames() -> List String
  requires [dbRead] =
  let rows = select i from Item order i.qty desc
  List.map (fn(i: Item) -> i.name) rows

fn cheapestName() -> String
  requires [dbRead] =
  let rows = select i from Item order i.qty asc limit 1
  case List.head rows of
    Nothing -> "none"
    Something i -> i.name

fn countAbove(threshold: Int) -> Int
  requires [dbRead] =
  selectCount i from Item where i.qty > threshold

fn totalQty() -> Int
  requires [dbRead] =
  selectSum i.qty from Item

# selectMax/selectMin answer a Maybe: no matching row has no maximum.
fn biggestQty() -> Int
  requires [dbRead] =
  case selectMax i.qty from Item of
    Nothing -> 0
    Something qty -> qty

fn smallestQty() -> Int
  requires [dbRead] =
  case selectMin i.qty from Item of
    Nothing -> 0
    Something qty -> qty

# The empty answer itself, over a predicate nothing matches.
fn biggestQtyNamed(wanted: String) -> Maybe Int
  requires [dbRead] =
  selectMax i.qty from Item where i.name == wanted

fn namesLike(pattern: String) -> Int
  requires [dbRead] =
  selectCount i from Item where like i.name pattern

fn namesILike(pattern: String) -> Int
  requires [dbRead] =
  selectCount i from Item where ilike i.name pattern

fn bySku(raw: String) -> Int
  requires [dbRead] =
  selectCount i from Item where i.sku == Sku raw

fn eitherName(left: String, right: String) -> Int
  requires [dbRead] =
  selectCount i from Item where i.name == left || i.name == right

fn describeDelete(name: String) -> String
  requires [dbWrite] =
  let removed = deleteAndReturnResult i from Item where i.name == name
  case removed of
    RowsDeleted n -> Int.toString n
    _ -> "none"

fn seed() -> Unit
  requires [dbWrite] =
  let _ = insert Item { id: "i1", sku: Sku "S-1", name: "alpha", qty: 7 }
  let rest = [
    Item { id: "i2", sku: Sku "S-2", name: "beta", qty: 3 },
    Item { id: "i3", sku: Sku "S-3", name: "Gamma", qty: 5 }
  ]
  let _ = insertMany rest in Item
  Unit

test "queries read back what was written" requires [dbRead, dbWrite] {
  let _ = seed ()
  expect titleOf "i1" == "alpha"
  expect titleOf "nope" == "none"
  expect countAbove 4 == 2
  expect totalQty () == 15
  expect biggestQty () == 7
  expect smallestQty () == 3
  expect bySku "S-2" == 1
  expect eitherName "alpha" "beta" == 2
  expect List.length (orderedNames ()) == 3
  expect orderedNames () == ["alpha", "Gamma", "beta"]
  expect cheapestName () == "beta"
  expect namesLike "%a" == 3
  expect namesLike "gamma" == 0
  expect namesILike "gamma" == 1
  expect biggestQtyNamed "alpha" == Something 7
  expect biggestQtyNamed "no-such-name" == Nothing
}

# The Memory store is NOT reset between test blocks (it is one process-wide store on
# both backends), so this test owns its own rows rather than re-seeding the first one's.
test "update and delete change what queries see" requires [dbRead, dbWrite] {
  let _ = insert Item { id: "u1", sku: Sku "S-U1", name: "delta", qty: 20 }
  let _ = insert Item { id: "u2", sku: Sku "S-U2", name: "epsilon", qty: 30 }
  Unit
  update i in Item
    where i.id == "u1"
    set i.name = "renamed"
    set i.qty = 21
  expect titleOf "u1" == "renamed"
  expect biggestQty () == 30
  expect titleOf "u1" == "renamed"
  expect countAbove 19 == 2
  delete i from Item where i.qty > 25
  expect countAbove 19 == 1
  expect titleOf "u2" == "none"
  # `deleteAndReturnResult` says whether anything WENT, which is not the same as a count of
  # zero: the caller reads it as a case.
  expect describeDelete "no-such-name" == "none"
  expect describeDelete "renamed" == "1"
}
|}

let test_db_with_go () =
  let emitted = emit_ok "<go-db>" db_source in
  let module_go = artifact "internal/teslmodgodb/module.go" emitted in
  check bool "an entity becomes a row struct" true
    (contains module_go "type Item struct {");
  check bool "and one package-level table" true
    (contains module_go "var ItemTable = teslrt.NewTable[Item]()");
  (* The duplicate-primary-key check is what keeps the two backends answering the same
     question: Racket keys its store by the primary key and raises on a duplicate. *)
  check bool "insert carries the primary-key conflict test" true
    (contains module_go
       "teslrt.TableInsert(ItemTable, \"Item\", Item{Id: \"i1\", Sku: Sku{Value: \"S-1\"}, Name: \"alpha\", Qty: teslrt.FromInt64(7)}, func(teslRow, teslNew Item) bool { return (teslRow.Id == teslNew.Id) })");
  (* The predicate is emitted pre-split across lines: a one-liner survives gofmt only while
     go/printer judges the line short enough, so the emitter writes gofmt's own output at every
     size rather than at the small ones. *)
  check bool "a where clause becomes a predicate over the row" true
    (contains module_go "teslrt.TableSelectOne(ItemTable, func(i Item) bool {");
  check bool "and the clause itself is the predicate's body" true
    (contains module_go "return (i.Id == wanted)");
  (* The comparator is pre-split too, for the same reason the predicate is. *)
  check bool "`order … desc` swaps the comparison rather than sorting twice" true
    (contains module_go
       "return (teslrt.Compare(teslRight.Qty, teslLeft.Qty) < 0)\n\t\t}, 0, -1)");
  check bool "selectSum folds the column with its own addition" true
    (contains module_go "teslrt.TableFold(ItemTable,");
  check bool "`like` is a matcher, never a regular expression" true
    (contains module_go "teslrt.SqlLike(i.Name, pattern, false)");
  check bool "`ilike` folds case" true
    (contains module_go "teslrt.SqlLike(i.Name, pattern, true)");
  (* Every `set` value reads the row as it was, so the update applies to a copy.  The
     update in this probe lives in a `test` block, hence the test artifact. *)
  let tests_go = artifact "internal/teslmodgodb/module_test.go" emitted in
  check bool "update assigns into a copy of the row" true
    (contains tests_go "teslNext := i");
  check bool "and reports nothing back, because `update` is a statement" true
    (contains tests_go "_ = teslrt.TableUpdate(ItemTable,");
  (* `deleteAndReturnResult` answers a runtime-provided ADT rather than a count: "nothing
     matched" is an outcome, not the number zero. *)
  check bool "`deleteAndReturnResult` answers a DeleteResult" true
    (contains module_go "teslrt.TableDeleteResult(ItemTable,");
  (* `go test` RUNS the two test blocks, so a wrong answer fails here. *)
  gate_emitted "tesl-go-db" emitted

(* A Postgres-backed entity is emitted TWICE: as the Go predicate the in-memory table needs,
   and as the statement the server needs.  Which one runs is decided at RUN time by whether
   something has connected — Racket binds `current-database-runtime` in `call-with-database`
   and nowhere else, so a query outside one answers from the entity's own store even when its
   database names a server.  That is not a technicality: it is what lets the `test` block
   below run with no cluster anywhere, and it is what the corpus's Postgres files rely on
   (`example/learn/lesson41-load-tests.tesl` included).  The Racket oracle on this same source
   is what proves the two agree about the unbound half; `database_test.go` in the runtime
   proves the bound half against a live cluster. *)
let postgres_declaration_source = {|module GoPostgresDeclaration exposing [titleOf, countBooks]

import Tesl.Prelude exposing [Int, String, Unit]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [
  Database,
  DatabaseBackend,
  Postgres,
  Memory,
  PostgresConfig,
  TcpConnection,
  SocketConnection,
]

type BookStatus
  = Draft
  | Published

entity Book table "pg_books" primaryKey id {
  id: String
  title: String
  pages: Int
  status: BookStatus
}

database Shelf = Database {
  schema: "gopgdecl"
  entities: [Book]
  backend: Postgres (PostgresConfig {
    dbName: "shelf"
    user: "shelf"
    password: "shelf"
    connection: TcpConnection {
      host: "localhost"
      port: 5432
    }
  })
}

fn shelve(id: String, title: String, pages: Int, status: BookStatus) -> Book
  requires [dbWrite] =
  insert Book { id: id, title: title, pages: pages, status: status }

# An ADT column round-trips through the same wire shape a response body uses.
fn statusOf(wanted: String) -> String
  requires [dbRead] =
  case selectOne b from Book where b.id == wanted of
    Nothing -> "none"
    Something b ->
      case b.status of
        Draft -> "draft"
        Published -> "published"

fn titleOf(wanted: String) -> String
  requires [dbRead] =
  case selectOne b from Book where b.id == wanted of
    Nothing -> "none"
    Something b -> b.title

fn countBooks() -> Int
  requires [dbRead] =
  selectCount b from Book

test "a Postgres declaration leaves the store where it was" requires [dbRead, dbWrite] {
  let _ = shelve "b-1" "The Art of Tesl" 320 Published
  let _ = shelve "b-2" "Proofs in Practice" 210 Draft
  expect titleOf "b-1" == "The Art of Tesl"
  expect titleOf "b-404" == "none"
  expect countBooks () == 2
  expect statusOf "b-1" == "published"
  expect statusOf "b-2" == "draft"
}
|}

let test_postgres_declaration_with_go () =
  let emitted = emit_ok "<go-pg-decl>" postgres_declaration_source in
  let module_go = artifact "internal/teslmodgopostgresdeclaration/module.go" emitted in
  (* The entity keeps its in-memory table — that is the store a query answers from until
     something connects — and the declaration adds the connection beside it. *)
  check bool "the entity still keeps its in-memory table" true
    (contains module_go "var BookTable = teslrt.NewTable[Book]()");
  check bool "the declaration becomes one database value" true
    (contains module_go "var ShelfDatabase = teslrt.NewDatabase(");
  (* The COLUMN types are the Racket runtime's, because a table created by one backend has to
     be readable by the other: an unbounded `Int` is NUMERIC, never BIGINT. *)
  check bool "and the tables it bootstraps" true
    (contains module_go "teslrt.PostgresTableOf(\"pg_books\",");
  check bool "the primary key carries its constraint" true
    (contains module_go "teslrt.PostgresColumnOf(\"id\", \"TEXT\", true, false)");
  check bool "and an unbounded Int is NUMERIC, never BIGINT" true
    (contains module_go "teslrt.PostgresColumnOf(\"pages\", \"NUMERIC\", false, false)");
  (* An ADT column is JSONB holding the value's own wire shape, which is what `dsl/sql.rkt`
     writes — the two backends have to be able to read each other's rows. *)
  check bool "an ADT column is JSONB" true
    (contains module_go "teslrt.PostgresColumnOf(\"status\", \"JSONB\", false, false)");
  check bool "and reads back through a tag lookup" true
    (contains module_go "func teslColumnBookStatus(teslText []byte) BookStatus {");
  (* An unknown tag TRAPS: it means the column holds a value this build has no constructor
     for, and half-reading it would be worse than not reading it. *)
  check bool "an unknown tag traps rather than decoding to a default" true
    (contains module_go "column holds an unknown tag");
  (* Both forms of the query, at one call site. *)
  check bool "a select carries the predicate and the statement" true
    (contains module_go "teslrt.DbSelectOne(ShelfDatabase, BookTable, func(b Book) bool {");
  check bool "the statement names the schema-qualified table" true
    (contains module_go
       {|select \"id\", \"title\", \"pages\", \"status\" from \"gopgdecl\".\"pg_books\" where \"id\" = $1 limit 1|});
  (* No value is ever in the TEXT: an operand is a placeholder and its argument travels
     separately, so nothing a request sends can change what a statement says. *)
  check bool "and binds its operand rather than interpolating it" true
    (contains module_go "return []any{wanted}");
  (* The count aggregates in the DATABASE rather than shipping rows here to be counted. *)
  check bool "a count aggregates on the server" true
    (contains module_go {|select count(*) from \"gopgdecl\".\"pg_books\"|});
  (* One scanner per entity, so the column order a select asks for and the order the scanner
     reads can only be the same order. *)
  check bool "one scanner reads the rows back" true
    (contains module_go "func teslScanBook(teslRow pgx.CollectableRow) (Book, error) {");
  check bool "an Int column travels as a NUMERIC, not through int64" true
    (contains module_go "teslrt.PgIntOf(teslColumn2)");
  (* The driver ships with the program that needs it, and only with it. *)
  let go_mod = artifact "go.mod" emitted in
  check bool "the driver is required, pinned" true
    (contains go_mod "require github.com/jackc/pgx/v5 v5.10.0");
  check bool "and its checksums travel with it" true
    (contains (artifact "go.sum" emitted) "github.com/jackc/pgx/v5 v5.10.0/go.mod h1:");
  check bool "the Postgres runtime ships too" true
    (List.exists (fun (a : Emit_go.artifact) -> a.path = "internal/teslrt/dbquery.go") emitted);
  gate_emitted "tesl-go-pg-decl" emitted


(* ─── Against a live server ───────────────────────────────────────────────────
   Everything above ASSERTS the statements the emitter builds; this RUNS them.  A typo in a
   generated statement reads perfectly well in an assertion and fails only when PostgreSQL
   parses it, so the SQL half of this backend is not proven by text comparison — it is proven
   by a round trip.

   `test "…" with database D` is the header that BINDS D for the block, so the block's queries
   reach the server rather than the in-memory table.  The configuration reads the same
   environment ci.sh sets for the Racket Postgres tests, which is what lets ONE cluster serve
   both backends and the oracle compare them on the same rows.  With no cluster configured the
   case skips: a developer without a server still gets everything above. *)
let postgres_live_source = {|module GoPostgresLive exposing [titleOf, countBooks]

import Tesl.Prelude exposing [Bool(..), Int, List, String, Unit]
import Tesl.List exposing [List.length, List.map]
import Tesl.String exposing [String.fromInt]
import Tesl.Tuple exposing [Tuple2, Tuple2.first, Tuple2.second]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [
  Database,
  DatabaseBackend,
  Postgres,
  Memory,
  PostgresConfig,
  TcpConnection,
  SocketConnection,
]

type Shelf
  = Fiction
  | Reference

# A variant that CARRIES a payload. The column is JSONB holding `{"tag": …, "fields": {…}}`,
# which is the shape both backends write, so a row written by either is readable by both.
type Binding
  = Paperback
  | Hardcover pressing: Int
  | Special edition: String

entity LiveBook table "live_books" primaryKey id {
  id: String
  title: String
  pages: Int
  shelf: Shelf
  binding: Binding
  retired: Bool
  authorId: String
}

entity LiveAuthor table "live_authors" primaryKey id {
  id: String
  name: String
}

database LiveDb = Database {
  schema: "goliveprobe"
  entities: [LiveBook, LiveAuthor]
  backend: Postgres (PostgresConfig {
    dbName: env "TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE"
    user: env "TESL_TEST_POSTGRES_SHARED_USER"
    password: env "PGPASSWORD"
    connection: TcpConnection {
      host: env "TESL_TEST_POSTGRES_SHARED_HOST"
      port: envInt "TESL_TEST_POSTGRES_SHARED_PORT" 5432
    }
  })
}

fn store(id: String, title: String, pages: Int, shelf: Shelf, retired: Bool, authorId: String) -> LiveBook
  requires [dbWrite] =
  insert LiveBook {
    id: id, title: title, pages: pages, shelf: shelf, binding: Paperback,
    retired: retired, authorId: authorId
  }

fn storeBound(id: String, binding: Binding) -> LiveBook requires [dbWrite] =
  insert LiveBook {
    id: id, title: "Bound", pages: 1, shelf: Fiction, binding: binding,
    retired: False, authorId: "a-1"
  }

fn bindingOf(wanted: String) -> String requires [dbRead] =
  case selectOne b from LiveBook where b.id == wanted of
    Nothing -> "none"
    Something b ->
      case b.binding of
        Paperback -> "paperback"
        Hardcover pressing -> "hardcover-" ++ String.fromInt pressing
        Special edition -> "special-" ++ edition

fn storeAuthor(id: String, name: String) -> LiveAuthor
  requires [dbWrite] =
  insert LiveAuthor { id: id, name: name }

# NO `innerJoin` here, deliberately.  Racket's Postgres join builder qualifies the ON columns
# with the snake-cased ENTITY name rather than the declared TABLE name, so a join against a
# real server is broken there for every entity whose table is named anything else —
# `LiveBook`/`live_books` included (finding 13 in the roadmap).  The Go form is an
# `exists (…)` subquery and does run: it is exercised against the cluster by
# `TestBoundInnerJoinExists` in runtime/go/teslrt/database_test.go, where there is no Racket
# counterpart to disagree with, and its BEHAVIOUR is compared on both backends by
# example/learn/lesson48-sql-inner-join.tesl, whose database is Memory-backed.

fn titleOf(wanted: String) -> String
  requires [dbRead] =
  case selectOne b from LiveBook where b.id == wanted of
    Nothing -> "none"
    Something b -> b.title

fn countBooks() -> Int
  requires [dbRead] =
  selectCount b from LiveBook

fn countRetired() -> Int
  requires [dbRead] =
  selectCount b from LiveBook where b.retired == True

fn totalPages() -> Int
  requires [dbRead] =
  selectSum b.pages from LiveBook

fn longest() -> Int
  requires [dbRead] =
  case selectMax b.pages from LiveBook of
    Nothing -> 0
    Something pages -> pages

fn titlesByPages() -> Int
  requires [dbRead] =
  selectCount b from LiveBook where b.pages > 250

# `upsert` on the SERVER is one statement — `insert … on conflict (id) do update set …` —
# where the memory path finds, merges and stores. The two agree about the outcome, which is
# what a test that runs on either store asserts.
fn stash(id: String, title: String, pages: Int) -> Unit requires [dbWrite] =
  upsert LiveBook {
    id: id, title: title, pages: pages, shelf: Fiction, binding: Paperback,
    retired: False, authorId: "a-1"
  } onConflict [id] doUpdate [title, pages]

# A grouped aggregate GROUPS on the server: `select "authorId", coalesce(sum("pages"), 0) …
# group by 1 order by 1`, one row per bucket in ascending key order — the same order the
# memory fold answers in.
fn pagesByAuthor() -> List (Tuple2 String Int) requires [dbRead] =
  selectSumBy b.pages from LiveBook groupBy b.authorId

fn booksByAuthor() -> List (Tuple2 String Int) requires [dbRead] =
  selectCountBy b from LiveBook groupBy b.authorId

fn authorsSeen() -> List String requires [dbRead] = List.map firstOfPair (pagesByAuthor ())

fn firstOfPair(row: Tuple2 String Int) -> String = Tuple2.first row

fn pagesSeen() -> List Int requires [dbRead] = List.map secondOfPair (pagesByAuthor ())

fn secondOfPair(row: Tuple2 String Int) -> Int = Tuple2.second row

fn countsSeen() -> List Int requires [dbRead] = List.map secondOfPair (booksByAuthor ())

fn shelfOf(wanted: String) -> String
  requires [dbRead] =
  case selectOne b from LiveBook where b.id == wanted of
    Nothing -> "none"
    Something b ->
      case b.shelf of
        Fiction -> "fiction"
        Reference -> "reference"

test "a round trip through the server answers what it stored" with database LiveDb requires [dbRead, dbWrite] {
  delete b from LiveBook
  delete a from LiveAuthor
  let _ = storeAuthor "a-1" "Ada"
  let _ = store "l-1" "The Art of Tesl" 320 Fiction False "a-1"
  let _ = store "l-2" "Proofs in Practice" 210 Reference True "ghost"
  expect titleOf "l-1" == "The Art of Tesl"
  expect titleOf "l-404" == "none"
  expect countBooks () == 2
  expect countRetired () == 1
  expect totalPages () == 530
  expect longest () == 320
  expect titlesByPages () == 1
  # An ADT column round-trips through the same wire shape a response body uses.
  expect shelfOf "l-1" == "fiction"
  expect shelfOf "l-2" == "reference"
  update b in LiveBook
    where b.id == "l-2"
    set b.title = "Proofs, Revised"
    set b.pages = 240
  expect titleOf "l-2" == "Proofs, Revised"
  expect totalPages () == 560
  delete b from LiveBook where b.retired == True
  expect countBooks () == 1
  expect titleOf "l-2" == "none"
  # An aggregate over no rows: a sum is zero, a max is Nothing.
  delete b from LiveBook
  expect countBooks () == 0
  expect totalPages () == 0
  expect longest () == 0
  # `upsert`: the first call inserts, the second updates the columns it names and leaves the
  # rest — on the server that is ON CONFLICT DO UPDATE, and the row is read back to prove it.
  let _ = stash "u-1" "First" 100
  expect titleOf "u-1" == "First"
  expect totalPages () == 100
  let _ = stash "u-1" "Second" 250
  expect countBooks () == 1
  expect titleOf "u-1" == "Second"
  expect totalPages () == 250
  # A grouped aggregate: one row per author, ascending by key.
  let _ = store "g-1" "One" 10 Fiction False "zeta"
  let _ = store "g-2" "Two" 20 Fiction False "alpha"
  let _ = store "g-3" "Three" 30 Fiction False "alpha"
  expect authorsSeen () == ["a-1", "alpha", "zeta"]
  expect pagesSeen () == [250, 50, 10]
  expect countsSeen () == [1, 2, 1]
  # A payload-carrying ADT column: the stored `{"tag": …, "fields": {…}}` reads back as the
  # value it was written from, whatever the variant carries.
  delete b from LiveBook
  let _ = storeBound "b-1" Paperback
  let _ = storeBound "b-2" (Hardcover 3)
  let _ = storeBound "b-3" (Special "slipcase")
  expect bindingOf "b-1" == "paperback"
  expect bindingOf "b-2" == "hardcover-3"
  expect bindingOf "b-3" == "special-slipcase"
}
|}

(* The cluster ci.sh starts, as an environment for a subprocess.  Absent, the two cases below
   skip rather than fail — the same reading `runtime/go/teslrt/postgres_test.go` takes. *)
let live_postgres_env () =
  let read name = Option.map (fun value -> name ^ "=" ^ value) (Sys.getenv_opt name) in
  match read "TESL_TEST_POSTGRES_SHARED_HOST", read "TESL_TEST_POSTGRES_SHARED_PORT",
        read "TESL_TEST_POSTGRES_SHARED_USER" with
  | Some host, Some port, Some user ->
    Some ([host; port; user]
          @ [Option.value (read "TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE")
               ~default:"TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE=postgres"]
          @ (match read "PGPASSWORD" with Some binding -> [binding] | None -> []))
  | _ -> None

let test_postgres_live_with_go () =
  match live_postgres_env () with
  | None ->
    Printf.printf "SKIP: no shared PostgreSQL cluster configured (TESL_TEST_POSTGRES_SHARED_*)\n%!"
  | Some env ->
    let emitted = emit_ok "<go-pg-live>" postgres_live_source in
    let tests_go = artifact "internal/teslmodgopostgreslive/module_test.go" emitted in
    (* The header BINDS: without this the block would run against the in-memory table and pass
       while touching no server at all, which is the one way this case could lie. *)
    check bool "the test block binds the database for its whole body" true
      (contains tests_go "teslrt.WithDatabase(LiveDbDatabase, func() {");
    gate_emitted ~env "tesl-go-pg-live" emitted

let test_postgres_live_oracle () =
  match live_postgres_env () with
  | None ->
    Printf.printf "SKIP: no shared PostgreSQL cluster configured (TESL_TEST_POSTGRES_SHARED_*)\n%!"
  | Some env -> racket_behavior_oracle ~env "<go-pg-live-oracle>" postgres_live_source ()

(* The three column shapes a Postgres-backed entity can hold that a scalar column rule does not
   reach: a payload-carrying ADT, a `secret` newtype, and a nullable column asked about by
   `isNull`.

   The ADT column is where the two backends were measurably INCOMPATIBLE.  Both write the same
   document, but `dsl/sql.rkt` binds it as a string parameter, so a row it wrote holds a jsonb
   STRING whose contents are that document while a row this backend wrote holds the document.
   The Racket reader accepts either; this one refused the incumbent shape, so a service being
   ported could not read the rows it already had.  `teslrt.ParseColumnJSON` now unwraps that one
   layer, and this suite's live case covers the Racket-writes/Go-reads direction by running both
   backends against the same table in sequence.

   The nested `Maybe` in `Named` is what found a Racket bug underneath: `adt-field-spec-template`
   holds the field FORM `(label : type)`, and `jsexpr->typed-value` read it as a type, so every
   payload field decoded fail-open — a `Maybe` came back as the wire hash rather than `Nothing`,
   and `runtime-type-satisfied?` said nothing was wrong. *)
let pg_columns_source = {|module GoPgColumns exposing [labelOf, tokenMatches, unnamed]

import Tesl.Prelude exposing [Bool(..), Int, String, Unit]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.String exposing [String.fromInt]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [
  Database,
  Postgres,
  PostgresConfig,
  TcpConnection,
]

secret Token = String

# A payload-carrying variant whose payload is itself a `Maybe`: the stored JSON holds the
# TAGGED shape `{"tag": "Nothing"}`, never a JSON null, so a decoder that tests for null
# would read every absent note as present.
type Priority
  = Low
  | Numbered level: Int
  | Named label: String note: (Maybe String)

entity Ticket table "pg_column_tickets" primaryKey id {
  id: String
  priority: Priority
  token: Token
  assignee: Maybe String
}

database ColumnDb = Database {
  schema: "gocolumnprobe"
  entities: [Ticket]
  backend: Postgres (PostgresConfig {
    dbName: env "TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE"
    user: env "TESL_TEST_POSTGRES_SHARED_USER"
    password: env "PGPASSWORD"
    connection: TcpConnection {
      host: env "TESL_TEST_POSTGRES_SHARED_HOST"
      port: envInt "TESL_TEST_POSTGRES_SHARED_PORT" 5432
    }
  })
}

fn store(id: String, priority: Priority, token: Token, assignee: Maybe String) -> Ticket
  requires [dbWrite] =
  insert Ticket { id: id, priority: priority, token: token, assignee: assignee }

fn labelOf(wanted: String) -> String requires [dbRead] =
  case selectOne t from Ticket where t.id == wanted of
    Nothing -> "none"
    Something t ->
      case t.priority of
        Low -> "low"
        Numbered level -> "n" ++ String.fromInt level
        Named label note ->
          case note of
            Nothing -> label
            Something extra -> label ++ "/" ++ extra

# A `secret` column: the column stores the newtype's BASE value, and what comes back is the
# newtype again — so the only thing a caller can do with it is compare, which is the point.
fn tokenMatches(wanted: String, guess: Token) -> Bool requires [dbRead] =
  case selectOne t from Ticket where t.id == wanted of
    Nothing -> False
    Something t -> t.token == guess

# `isNull` is the only way to ask a nullable column about its emptiness in a WHERE clause:
# `t.assignee == Nothing` compares a column against a Tesl value, which the store cannot do.
fn unnamed() -> Int requires [dbRead] =
  selectCount t from Ticket where isNull t.assignee

test "a payload ADT, a secret and a nullable column all survive a round trip" with database ColumnDb requires [dbRead, dbWrite] {
  # A live table outlives a test process, so the block starts by clearing what an earlier run
  # left — the per-test freshening both backends do covers memory stores only.
  delete t from Ticket
  let _ = store "t-1" Low (Token "k-1") (Something "ada")
  let _ = store "t-2" (Numbered 3) (Token "k-2") Nothing
  let _ = store "t-3" (Named "urgent" Nothing) (Token "k-3") Nothing
  let _ = store "t-4" (Named "urgent" (Something "today")) (Token "k-4") (Something "grace")
  expect labelOf "t-1" == "low"
  expect labelOf "t-2" == "n3"
  expect labelOf "t-3" == "urgent"
  expect labelOf "t-4" == "urgent/today"
  expect labelOf "t-404" == "none"
  expect tokenMatches "t-1" (Token "k-1") == True
  expect tokenMatches "t-1" (Token "k-2") == False
  expect unnamed () == 2
}|}

let test_pg_columns_with_go () =
  match live_postgres_env () with
  | None ->
    Printf.printf "SKIP: no shared PostgreSQL cluster configured (TESL_TEST_POSTGRES_SHARED_*)\n%!"
  | Some env ->
    let emitted = emit_ok "<go-pg-columns>" pg_columns_source in
    let module_go = artifact "internal/teslmodgopgcolumns/module.go" emitted in
    (* The column decoder goes through the tolerant parse, not the strict one: this is the line
       that makes an existing Racket-written table readable. *)
    check bool "an ADT column parses through the tolerant column parse" true
      (contains module_go "teslrt.ParseColumnJSON(teslText)");
    (* A `secret` column stores the plaintext and reads back INTO the redacting carrier. *)
    check bool "a secret column binds its plaintext" true
      (contains module_go ".Value.Reveal()");
    check bool "a secret column scans back into a secret" true
      (contains module_go "Token{Value: teslrt.MakeSecret(");
    (* `isNull` asks the STORE, so it has to reach the statement rather than filtering rows
       here — a predicate evaluated in Go would answer the same on this data and the wrong
       thing on a table that does not fit in memory. *)
    check bool "isNull becomes a SQL predicate" true
      (contains module_go {|assignee\" is null|});
    gate_emitted ~env "tesl-go-pg-columns" emitted

let test_pg_columns_oracle () =
  match live_postgres_env () with
  | None ->
    Printf.printf "SKIP: no shared PostgreSQL cluster configured (TESL_TEST_POSTGRES_SHARED_*)\n%!"
  | Some env -> racket_behavior_oracle ~env "<go-pg-columns-oracle>" pg_columns_source ()

(* ─── The `server` clause surface ─────────────────────────────────────────────
   `Ast.server_form` carries 16 fields and `emit_racket.ml` honours all of them.  This backend
   read TEN.  The six it ignored were not refused — they were DROPPED, which is the one failure
   mode this migration exists to prevent:

     `sessionRevoked`         a revoked session went on renewing
     `sessionPreviousKey`     key rotation logged every user out
     `listenAddress Loopback` the server bound every interface
     `healthProbePath`        a load balancer's probe got 421
     `contentSecurityPolicy`  runtime-served HTML carried no CSP
     `trustedProxies`         a security declaration configured nothing

   Three of them are declared by corpus programs TODAY (`example/sso-demo.tesl`,
   `lesson78-sso.tesl`, `lesson79-authenticating-proxy.tesl`, `lesson80-testing-sso.tesl`,
   `tests/proxy-binding-http-tests.tesl`) and those programs PASSED — a green corpus over a real
   divergence, because no test asserted a clause.  So this case asserts the boot line for each,
   and then asserts the BEHAVIOUR of the one with teeth: `expectFail renewedLength banned` fails
   unless the revocation hook actually denies.  `trustedProxies` is refused rather than wired,
   because there is no `request.clientAddress` on this backend for it to scope. *)
let server_clauses_source = {|module GoServerClauses exposing [profile, renewedLength]

import Tesl.Prelude exposing [Bool(..), Int, String, Unit]
import Tesl.String exposing [String.length]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Dict exposing [Dict, Dict.singleton, Dict.lookup]
import Tesl.Time exposing [time, PosixMillis]
import Tesl.Env exposing [requireSecret, envRead]
import Tesl.Crypto exposing [Secret]
import Tesl.JWT exposing [jwt, JwtToken, JWT.sign, JWT.renew]
import Tesl.Http exposing [HttpRequest]
import Tesl.App exposing [App]
import Tesl.Database exposing [Database, Memory]

fact Authenticated(user: Profile)

record Profile { name: String }

fn sessionKey() -> Secret requires [envRead] =
  requireSecret "GOCLAUSES_SESSION_KEY"

# The `sessionRevoked` clause's own function: `(String, PosixMillis) -> Bool`, where True means
# "this session may no longer renew".  The runtime hook is handed `iat` in SECONDS, so the
# emitted adapter has to convert — a hook given milliseconds compares against the wrong epoch.
fn revoked(subject: String, _issuedAt: PosixMillis) -> Bool =
  subject == "banned"

auth sessionOwner(request: HttpRequest) -> user: Profile ::: Authenticated user
  requires [jwt, envRead] =
  ok (Profile { name: "anyone" }) ::: Authenticated user

handler get profile(user: Profile ::: Authenticated user) -> Profile = user

# A renewal, as a function, so a test can assert on the token it answers: the check's refusal
# routes to a 401 the same way `check JWT.verify` does.
fn renewedLength(token: JwtToken) -> Int requires [jwt, envRead, time] =
  let fresh = check JWT.renew token (sessionKey ())
  String.length fresh.value

api ClauseApi {
  get "/me"
    auth user: Profile ::: Authenticated user via sessionOwner
    -> Profile
}

server ClauseServer for ClauseApi {
  profile
  publicOrigin "https://app.example.test"
  sessionKey "GOCLAUSES_SESSION_KEY"
  sessionPolicy ShortSession
  sessionPreviousKey "GOCLAUSES_PREVIOUS_KEY"
  sessionRevoked revoked
  listenAddress Loopback
  healthProbePath "/healthz"
  contentSecurityPolicy "default-src 'self'"
}

database ClauseDb = Database {
  entities: []
  backend: Memory
}

main() -> App requires [jwt, envRead] =
  App {
    database: ClauseDb
    api: ClauseServer
    port: 8080
  }

test "a revoked session cannot renew, an ordinary one can" requires [jwt, envRead, time] {
  let token = JWT.sign (Dict.singleton "sub" "ada") (sessionKey ())
  let banned = JWT.sign (Dict.singleton "sub" "banned") (sessionKey ())
  # An ordinary session renews; the one the `sessionRevoked` fn names does not.
  expect renewedLength token > 20
  expectFail renewedLength banned
}|}

let test_server_clauses_with_go () =
  let emitted = emit_ok "<go-server-clauses>" server_clauses_source in
  let module_go = artifact "internal/teslmodgoserverclauses/module.go" emitted in
  List.iter (fun (what, expected) ->
    check bool ("the " ^ what ^ " clause reaches the boot init") true
      (contains module_go expected))
    [ "publicOrigin", "teslrt.SetPublicOriginValue(\"https://app.example.test\")";
      "sessionPolicy", "teslrt.SetSessionPolicy(teslrt.SessionPolicyTTL(\"ShortSession\"))";
      "sessionPreviousKey",
        "teslrt.SetPreviousSessionKey(teslrt.SecretPointer(teslrt.RequireSecret(\"GOCLAUSES_PREVIOUS_KEY\")))";
      "sessionRevoked", "teslrt.SetSessionRevokedHook(func(teslSubject string, teslIssuedAt int64) bool {";
      "healthProbePath", "teslrt.SetHealthProbePath(\"/healthz\")";
      "contentSecurityPolicy", "teslrt.SetContentSecurityPolicy(\"default-src 'self'\")" ];
  (* The hook is handed `iat` in SECONDS and the clause's fn takes a `PosixMillis`, so the
     adapter has to convert — a hook given milliseconds compares against the wrong epoch and
     never revokes anything. *)
  check bool "the revocation adapter converts seconds to an instant" true
    (contains module_go "teslrt.SecondsToPosix(teslrt.FromInt64(teslIssuedAt))");
  (* `listenAddress Loopback` is the difference between a service a reverse proxy reaches and
     one the whole network reaches, so it travels as the bind address rather than a boot call. *)
  check bool "listenAddress reaches the serve options" true
    (contains module_go "ListenAddress: \"127.0.0.1\"");
  gate_emitted ~env:["GOCLAUSES_SESSION_KEY=clauses-signing-key-0123456789";
                     "GOCLAUSES_PREVIOUS_KEY=clauses-previous-key-0123456789"]
    "tesl-go-server-clauses" emitted

(* `trustedProxies` scopes which forwarded-for header `request.clientAddress` may believe.  This
   backend has no `clientAddress`, so the clause would configure a reader that does not exist:
   refused, because accepting a security declaration that does nothing is worse than not
   compiling. *)
let test_trusted_proxies_fails_closed () =
  let source = {|module GoTrustedProxies exposing [ping]

import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

handler get ping() -> String = "pong"

api ProxyApi {
  get "/ping" -> String
}

server ProxyServer for ProxyApi {
  ping
  trustedProxies ["10.0.0.1"]
}

database ProxyDb = Database {
  entities: []
  backend: Memory
}

main() -> App =
  App {
    database: ProxyDb
    api: ProxyServer
    port: 8080
  }
|} in
  match Compile.compile_go_source "<go-trusted-proxies>" source with
  | Compile.GoSuccess _ -> fail "trustedProxies emitted instead of failing closed"
  | Compile.GoFailure diagnostics ->
    let message = String.concat "; "
      (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics) in
    check bool "the refusal says why there is nothing to configure" true
      (contains message "clientAddress")

(* ─── `List.unique`: the keyed path ───────────────────────────────────────────
   `ListUniqueBy` is a linear scan per element — quadratic — while Racket's `List.unique` is
   hash-based and linear.  The comment on the Go helper claimed the two matched; they did not.

   The emitter now takes a KEYED path whenever the element type has a comparable Go key whose
   equality is exactly the language's `==`.  Two types make that non-obvious and both are here:
   an unbounded `Int` is not a Go comparable at all (`noCompare`), so the key is its canonical
   decimal; and a `Float` keyed by its own value would make -0.0 and +0.0 one key (the language
   separates them) and every NaN its own (the language makes them equal), so it is keyed by
   `teslrt.FloatKey`.  A multi-variant ADT has no scalar to key on and keeps the closure path. *)
let list_unique_source = {|module GoUnique exposing [names, counts, prices, flags, skus, tags]

import Tesl.Prelude exposing [Bool(..), Int, List, String]
import Tesl.Float exposing [Float]
import Tesl.List exposing [List.unique, List.length]

type Sku = String

type Tag
  = Red
  | Blue

fn names(xs: List String) -> List String = List.unique xs

fn counts(xs: List Int) -> List Int = List.unique xs

fn prices(xs: List Float) -> List Float = List.unique xs

fn flags(xs: List Bool) -> List Bool = List.unique xs

fn skus(xs: List Sku) -> List Sku = List.unique xs

# A multi-variant ADT has no comparable key, so this one keeps the closure path.
fn tags(xs: List Tag) -> Int = List.length (List.unique xs)

test "unique keeps the first occurrence and preserves order, keyed or not" {
  expect names ["b", "a", "b", "c", "a"] == ["b", "a", "c"]
  expect counts [3, 1, 3, 1, 2] == [3, 1, 2]
  expect prices [1.5, 0.5, 1.5] == [1.5, 0.5]
  expect flags [True, False, True] == [True, False]
  expect skus [Sku "x", Sku "y", Sku "x"] == [Sku "x", Sku "y"]
  expect tags [Red, Blue, Red] == 2
}|}

let test_list_unique_with_go () =
  let emitted = emit_ok "<go-list-unique>" list_unique_source in
  let module_go = artifact "internal/teslmodgounique/module.go" emitted in
  List.iter (fun (what, expected) ->
    check bool (what ^ " takes the keyed path") true (contains module_go expected))
    [ "String", "teslrt.ListUniqueKeyed(xs, teslKeyString)";
      "Int", "teslrt.ListUniqueKeyed(xs, teslKeyTeslrtInt)";
      "Float", "teslrt.ListUniqueKeyed(xs, teslKeyFloat64)";
      "Bool", "teslrt.ListUniqueKeyed(xs, teslKeyBool)";
      "a scalar newtype", "teslrt.ListUniqueKeyed(xs, teslKeySku)" ];
  (* The two keys that are not the value itself. *)
  check bool "an Int is keyed by its canonical decimal, not by a Go comparison" true
    (contains module_go "func teslKeyTeslrtInt(teslX teslrt.Int) teslrt.IntKey {\n\treturn teslX.Key()");
  check bool "a Float is keyed by FloatKey, so NaN and signed zero keep the language's equality" true
    (contains module_go "func teslKeyFloat64(teslX float64) uint64 {\n\treturn teslrt.FloatKey(teslX)");
  (* And the fallback is unchanged: an ADT has no key, so it still compares. *)
  check bool "a multi-variant ADT keeps the comparison closure" true
    (contains module_go "teslrt.ListUniqueBy(xs, teslEqualTag)");
  gate_emitted "tesl-go-list-unique" emitted

(* ─── A declared JSON payload is CHECKED before it is parsed ──────────────────
   `dsl/web.rkt`'s `parse-json-body` refuses a body whose content type does not say JSON (415)
   and an empty one (400 "Missing JSON payload") before parsing anything, and applies both only
   where the endpoint DECLARES a payload — an `auth` that verifies a MAC over the raw bytes reads
   the body of a request that may not be JSON at all.  This backend parsed whatever arrived.

   NOT oracled, and the reason is a difference in the two HARNESSES rather than in the two
   servers.  Racket's `dispatch-api-test-request` hands the dispatcher an already-PARSED body, so
   "the body is JSON" is true there by construction and no api-test on that backend can reach the
   content-type check.  `teslrt.ApiRequest` builds a real `*http.Request` and calls the server, so
   here the check is on the path an api-test walks — which is why the assertion below is possible
   at all.  Over real HTTP both backends answer 415; only the test surfaces differ. *)
let json_payload_source = {|module GoJsonPayload exposing [echo]

import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec]
import Tesl.ApiTest exposing [statusOk]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

record Note { text: String }

codec Note {
  toJson {
    text -> "text" with_codec stringCodec
  }
  fromJson [
    {
      text <- "text" with_codec stringCodec
    }
  ]
}

handler post echo(note: Note) -> Note = note

api PayloadApi {
  post "/echo"
    body note: Note
    -> Note
}

server PayloadServer for PayloadApi {
  echo
}

database PayloadDb = Database {
  entities: []
  backend: Memory
}

main() -> App =
  App {
    database: PayloadDb
    api: PayloadServer
    port: 8080
  }

api-test "a declared JSON payload is checked before it is parsed" for PayloadServer {
  # The ordinary path: the harness sends application/json.
  let accepted = post "/echo" body { "text": "hello" }
  expect statusOk accepted.status
  expect accepted.body.text == "hello"

  # A body that is not JSON at all is refused with 415 rather than parsed: a JSON API that
  # accepted `text/plain` would be the surprising behaviour, and `dsl/web.rkt` answers 415 here.
  let wrongType = post "/echo" headers { "content-type": "text/plain" } body { "text": "hello" }
  expect wrongType.status == 415
}|}

let test_json_payload_with_go () =
  let emitted = emit_ok "<go-json-payload>" json_payload_source in
  let module_go = artifact "internal/teslmodgojsonpayload/module.go" emitted in
  (* Before the parse, and only on the endpoint that declares a body. *)
  let position text substring =
    let n = String.length text and m = String.length substring in
    let rec scan index =
      if index + m > n then None
      else if String.sub text index m = substring then Some index
      else scan (index + 1)
    in
    scan 0
  in
  check bool "the payload check runs BEFORE the parse it guards" true
    (match position module_go "teslrt.CheckJSONPayload(teslRequest, teslBodyBytes)",
           position module_go "teslrt.ParseJSON(teslBodyBytes)" with
     | Some check_at, Some parse_at -> check_at < parse_at
     | _ -> false);
  gate_emitted "tesl-go-json-payload" emitted

(* ─── Polymorphic equality, by DICTIONARY ─────────────────────────────────────
   `fn same(x: a, y: a) -> Bool = x == y` runs on Racket, which compares two `a` values
   structurally.  This backend refused it: an emitted Go generic cannot use `==` (that needs
   `comparable`, and Tesl's values include maps and slices), and `reflect.DeepEqual` would
   compare a `secret` byte by byte — throwing away the constant-time comparison the type exists
   for.

   So the comparison travels as an ARGUMENT.  A generic whose body compares two `A` values takes
   `teslEqualA func(A, A) bool`, and each call site passes the concrete type's own comparator —
   which for a `secret` IS the constant-time compare, so the property survives the indirection.
   A generic that hands its own `a` to one of these forwards the dictionary it was given. *)
let poly_equality_source = {|module GoPolyEq exposing [same, differs, firstIsSame, countMatches]

import Tesl.Prelude exposing [Bool(..), Int, List, String]
import Tesl.List exposing [List.length]
import Tesl.Maybe exposing [Maybe(..)]

# The canonical shape Racket supports: two values of a type variable, compared.
fn same(x: a, y: a) -> Bool =
  x == y

fn differs(x: a, y: a) -> Bool =
  x != y

# A second type variable that is NOT compared gets no dictionary.
fn firstIsSame(x: a, y: a, label: b) -> Bool =
  let _ = label
  x == y

# Comparison inside a nested position: the dictionary is in scope for the whole body.
fn countMatches(needle: a, xs: List a) -> Int =
  if same needle needle then
    List.length xs
  else
    0

test "polymorphic equality answers what the concrete type's own equality answers" {
  expect same 1 1 == True
  expect same 1 2 == False
  expect same "a" "a" == True
  expect same "a" "b" == False
  expect differs 1 2 == True
  expect differs "a" "a" == False
  expect same True True == True
  expect firstIsSame 3 3 "ignored" == True
  expect same (Something 4) (Something 4) == True
  expect same (Something 4) Nothing == False
  expect countMatches 1 [1, 2, 3] == 3
}|}

let test_poly_equality_with_go () =
  let emitted = emit_ok "<go-poly-equality>" poly_equality_source in
  let module_go = artifact "internal/teslmodgopolyeq/module.go" emitted in
  check bool "a comparing generic takes the comparison as a parameter" true
    (contains module_go "func Same[A any](x A, y A, teslEqualA func(A, A) bool) bool");
  check bool "and its body calls it" true (contains module_go "return teslEqualA(x, y)");
  (* A type parameter that is NOT compared gets no dictionary: the parameter list grows with
     what the body does, not with the number of type variables. *)
  check bool "an uncompared type parameter gets none" true
    (contains module_go
       "func FirstIsSame[A any, B any](x A, y A, label B, teslEqualA func(A, A) bool) bool");
  (* The transitive case: `countMatches` compares nothing itself and calls one that does. *)
  check bool "a generic that only PASSES its value forwards the dictionary" true
    (contains module_go "func CountMatches[A any](needle A, xs []A, teslEqualA func(A, A) bool)");
  (* Each call site resolves the dictionary to the concrete type's own comparator. *)
  let tests_go = artifact "internal/teslmodgopolyeq/module_test.go" emitted in
  check bool "a String call site passes String's comparator" true
    (contains tests_go "Same(\"a\", \"a\", teslEqualString)");
  gate_emitted "tesl-go-poly-equality" emitted

(* ─── A WIDE ADT is emitted BOXED ─────────────────────────────────────────────
   A Tesl ADT is a sum and Go has no sum type, so the default here is one flat struct holding
   every variant's fields beside a tag: no allocation, one memmove to copy, one offset to read.
   That is the right representation until the payloads add up — the struct is as large as their
   SUM, and past a few hundred bytes a value is copied whole on every call and assignment.

   Above the threshold the emitter switches by itself: one small struct per payload variant, and
   a pointer to it, so the value is a tag and a pointer whatever the payloads do.  Nothing in
   Tesl says which layout a type gets.  `example/chat/chat-backend.tesl` has the corpus's own
   example (three variants, nine strings, ~170 bytes) and is emitted boxed by this rule.

   The program below is deliberately exhaustive rather than minimal, because a layout change has
   to keep EVERY operation working: construction, a `case` that binds five fields, a nested
   `Maybe` payload, equality across variants, and a database column that goes out through the
   encoder and back through the decoder. *)
let wide_adt_source = {|module GoWideAdt exposing [label, same, roundTrip, storeEvent, labelOf]

import Tesl.Prelude exposing [Bool(..), Int, String, Unit]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.String exposing [String.fromInt]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, Memory]

# Nine string fields across three payload variants: ~170 bytes flat, which is over the
# threshold, so the emitter boxes it. Every operation below has to keep working through the
# indirection — construction, pattern matching, equality, the wire encoder and a column.
type WideEvent
  = Posted msgId: String userId: String username: String content: String room: String
  | Joined userId: String username: String
  | Failed senderName: String roomName: String note: (Maybe String)
  | Quiet

entity EventRow table "wide_events" primaryKey id {
  id: String
  event: WideEvent
}

database WideDb = Database {
  entities: [EventRow]
  backend: Memory
}

fn label(event: WideEvent) -> String =
  case event of
    Posted msgId userId username content room ->
      msgId ++ "/" ++ userId ++ "/" ++ username ++ "/" ++ content ++ "/" ++ room
    Joined userId username -> userId ++ "+" ++ username
    Failed senderName roomName note ->
      case note of
        Nothing -> senderName ++ "!" ++ roomName
        Something extra -> senderName ++ "!" ++ roomName ++ "!" ++ extra
    Quiet -> "quiet"

fn same(left: WideEvent, right: WideEvent) -> Bool =
  left == right

fn roundTrip(event: WideEvent) -> String =
  label event

fn storeEvent(id: String, event: WideEvent) -> EventRow requires [dbWrite] =
  insert EventRow { id: id, event: event }

fn labelOf(wanted: String) -> String requires [dbRead] =
  case selectOne row from EventRow where row.id == wanted of
    Nothing -> "none"
    Something row -> label row.event

test "a boxed ADT behaves exactly as a flat one does" requires [dbRead, dbWrite] {
  let posted = Posted "m1" "u1" "ada" "hello" "general"
  let joined = Joined "u2" "grace"
  let failed = Failed "ada" "general" Nothing
  let noted = Failed "ada" "general" (Something "retry")

  expect label posted == "m1/u1/ada/hello/general"
  expect label joined == "u2+grace"
  expect label failed == "ada!general"
  expect label noted == "ada!general!retry"
  expect label Quiet == "quiet"

  # Equality reaches every field of the active variant, and only that variant.
  expect same posted posted == True
  expect same posted (Posted "m1" "u1" "ada" "hello" "other") == False
  expect same joined joined == True
  expect same posted joined == False
  expect same failed noted == False
  expect same Quiet Quiet == True

  # A column: the value goes out through the encoder and comes back through the decoder.
  let _ = storeEvent "r1" posted
  let _ = storeEvent "r2" noted
  let _ = storeEvent "r3" Quiet
  expect labelOf "r1" == "m1/u1/ada/hello/general"
  expect labelOf "r2" == "ada!general!retry"
  expect labelOf "r3" == "quiet"
  expect labelOf "r404" == "none"

  expect roundTrip joined == "u2+grace"
}|}

let test_wide_adt_is_boxed () =
  let emitted = emit_ok "<go-wide-adt>" wide_adt_source in
  let module_go = artifact "internal/teslmodgowideadt/module.go" emitted in
  (* The outer struct is a tag and one pointer per payload variant — 32 bytes rather than the
     ~170 the flat form would be. *)
  check bool "the wide ADT is a tag plus payload pointers" true
    (contains module_go "Posted *WideEventPostedPayload");
  check bool "each payload variant gets its own struct" true
    (contains module_go "type WideEventJoinedPayload struct {");
  (* `Payload` is not decoration: the tag CONSTANT already owns `WideEventJoined`. *)
  check bool "the payload type cannot collide with the tag constant" true
    (contains module_go "WideEventJoinedPayload");
  (* Construction allocates the one variant's payload; reads go through the pointer. *)
  (* Construction allocates the one variant's payload.  It happens in the TEST block here, so
     the literal lands in the test artifact rather than in module.go. *)
  let tests_go = artifact "internal/teslmodgowideadt/module_test.go" emitted in
  check bool "construction fills the payload pointer" true
    (contains tests_go "&WideEventJoinedPayload{UserId: \"u2\", Username: \"grace\"}");
  (* And a read goes through the pointer — no copy of the payload to reach one field. *)
  check bool "and a read goes through it" true (contains module_go ".Joined.UserId");
  gate_emitted "tesl-go-wide-adt" emitted







(* A `unique index` is an INVARIANT, not a hint: the Racket memory backend raises on an insert
   that violates one, so accepting the declaration without enforcing it would let `tesl test`
   pass on data PostgreSQL rejects — the two backends would then run different programs, which
   is worse than one of them not compiling.  A Postgres-backed entity gets a real index from the
   bootstrap under the name `dsl/sql.rkt` derives, so a shared table does not end up with two
   indexes doing one job.  A plain index is a performance hint with no observable effect on
   either store and is carried nowhere. *)
let unique_index_source = {|module GoUniqueIndex exposing [add, rename]

import Tesl.Prelude exposing [Int, String, Unit]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, Memory]

entity Member table "members" primaryKey id {
  id: String
  email: String
  nickname: Maybe String

  unique index [email]
  unique index [nickname]
}

database Team = Database {
  entities: [Member]
  backend: Memory
}

fn add(id: String, email: String) -> Member requires [dbWrite] =
  insert Member { id: id, email: email, nickname: Nothing }

fn rename(id: String, email: String) -> Unit requires [dbWrite] =
  update m in Member
    where m.id == id
    set m.email = email

test "a unique index is enforced, and NULLs do not collide" requires [dbRead, dbWrite] {
  let _ = add "m1" "ada@example.com"
  let _ = add "m2" "grace@example.com"
  expectFail add "m3" "ada@example.com"
  # Two rows with a NULL nickname do not violate the index on it: two NULLs are not equal,
  # which is PostgreSQL's rule and Racket's.
  expect selectCount m from Member == 2
  # An UPDATE is checked too, and never against the row it is replacing.
  let _ = rename "m1" "ada@example.com"
  expectFail rename "m1" "grace@example.com"
}
|}

let test_unique_index_with_go () =
  let emitted = emit_ok "<go-unique-index>" unique_index_source in
  let module_go = artifact "internal/teslmodgouniqueindex/module.go" emitted in
  check bool "an insert carries the declared unique indexes" true
    (contains module_go "teslrt.UniqueIndexOf(");
  check bool "and names the columns the refusal will name" true
    (contains module_go "[]string{\"email\"}");
  (* A row with a NULL in an indexed column is UNCONSTRAINED, so a nullable column carries a
     guard and a non-nullable one carries none. *)
  check bool "a nullable column is unconstrained when it is NULL" true
    (contains module_go "return teslRow.Nickname.IsSomething()");
  (* `go test` RUNS it: the two `expectFail`s are the enforcement. *)
  gate_emitted "tesl-go-unique-index" emitted


(* `posixMillisCodec` puts an instant on the wire as its integer millis and nothing else — the
   agent boundary's `{epochMillis, iso}` enrichment is a different surface.  Only the ENCODE
   direction is supported: `tesl-decode-prim-posix-millis` answers the bare integer, which no
   `PosixMillis` field accepts, so a body carrying one is a 400 on Racket for a perfectly well
   formed payload (finding 11 in the roadmap).  Emitting the working Go form would accept a
   program the other backend rejects, so the decode direction fails closed. *)
let posix_codec_source = {|module GoPosixCodec exposing [PosixServer]

import Tesl.Prelude exposing [Int, String]
import Tesl.Time exposing [PosixMillis, Time.secondsToPosix]
import Tesl.Json exposing [stringCodec, posixMillisCodec]
import Tesl.ApiTest exposing [statusOk]

record Stamp {
  label: String
  at: PosixMillis
}

codec Stamp {
  toJson {
    label -> "label" with_codec stringCodec
    at -> "at" with_codec posixMillisCodec
  }
  fromJson_forbidden
}

handler get stamp(seconds: String) -> Stamp =
  Stamp { label: seconds, at: Time.secondsToPosix 1700000000 }

api StampApi {
  get "/stamp/:seconds"
    capture seconds: String using stringCodec
    -> Stamp
}

server PosixServer for StampApi {
  stamp
}

api-test "an instant crosses the wire as its millis" for PosixServer {
  let r = get "/stamp/now"
  expect statusOk r.status
  expect r.body.label == "now"
  expect r.body.at == 1700000000000
}
|}

let test_posix_codec_with_go () =
  let emitted = emit_ok "<go-posix-codec>" posix_codec_source in
  let module_go = artifact "internal/teslmodgoposixcodec/module.go" emitted in
  (* The instant is a newtype at run time, so the wire value is its payload rather than the
     struct — a struct there would marshal as an object no Racket client would read. *)
  check bool "an instant encodes as its integer millis" true
    (contains module_go "teslValue.At.Value,");
  (* The DECODE direction works here and does NOT on Racket: its
     `tesl-decode-prim-posix-millis` answers a bare integer that no `PosixMillis` field
     accepts, so the same body is a 400 there (finding 11 in the roadmap).  Go answers
     correctly rather than reproducing that — the same call taken for `selectCount`'s dropped
     joins and for `innerJoin` against a real server (maintainer, 2026-08-17). *)
  let decoding = {|module GoPosixDecode exposing [Stamp]
import Tesl.Prelude exposing [String]
import Tesl.Time exposing [PosixMillis]
import Tesl.Json exposing [stringCodec, posixMillisCodec]

record Stamp {
  label: String
  at: PosixMillis
}

codec Stamp {
  toJson_forbidden
  fromJson [
    {
      label <- "label" with_codec stringCodec
      at <- "at" with_codec posixMillisCodec
    }
  ]
}
|} in
  (match Compile.compile_go_source "<go-posix-decode>" decoding with
   | Compile.GoFailure diagnostics ->
     failf "decoding an instant failed to compile: %s"
       (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
   | Compile.GoSuccess artifacts ->
     let decoded = artifact "internal/teslmodgoposixdecode/module.go" artifacts in
     (* The millis arrive as an Int and the field's own newtype wraps them. *)
     check bool "an instant decodes from its integer millis" true
       (contains decoded "teslrt.DecodeIntField(teslJSON, \"at\")"));
  (* `go test` RUNS the api-test: the wire number is asserted there. *)
  gate_emitted "tesl-go-posix-codec" emitted


(* `Tesl.Int32` is NOMINAL for the checker and IS its integer at run time, which is what
   `tesl/int32.rkt` says — so the emitted type is `teslrt.Int` with no wrapper, and an Int32
   crossing into `Int` arithmetic costs nothing.  What the type buys is in the SIGNATURES: an
   operation that cannot leave [-2^31, 2^31) answers the value, one that can answers a `Maybe`,
   and that is a property of the operation rather than of the inputs. *)
let int32_source = {|module GoInt32 exposing [narrow, widen, saturate, half]

import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Int32 exposing [
  Int32,
  IsNonZero,
  Int32.fromInt,
  Int32.toInt,
  Int32.fromIntClamped,
  Int32.add,
  Int32.divide,
  Int32.negate,
  Int32.pow,
  Int32.digits,
  Int32.minValue,
  Int32.maxValue,
  Int32.nonZero,
]

fn narrow(n: Int) -> Maybe Int32 =
  Int32.fromInt n

fn widen(x: Int32) -> Int =
  Int32.toInt x

# Saturating narrowing is how a literal becomes an Int32: the type is NOMINAL, so an `Int`
# never is one by accident.
fn saturate(n: Int) -> Int32 =
  Int32.fromIntClamped n

fn half(n: Int32, divisor: Int32 ::: IsNonZero divisor) -> Maybe Int32 =
  Int32.divide n divisor

test "the range boundary is inclusive at both ends" {
  expect narrow 2147483647 == Something (saturate 2147483647)
  expect narrow 2147483648 == Nothing
  expect narrow (0 - 2147483648) == Something (saturate (0 - 2147483648))
  expect narrow (0 - 2147483649) == Nothing
  expect widen Int32.minValue == (0 - 2147483648)
  expect widen Int32.maxValue == 2147483647
}

test "an operation that can overflow answers a Maybe" {
  expect Int32.add Int32.maxValue (saturate 1) == Nothing
  expect Int32.add (saturate 1) (saturate 1) == Something (saturate 2)
  # -2^31 has no positive counterpart, so negating it leaves the range.
  expect Int32.negate Int32.minValue == Nothing
  # The exponent is bounded BEFORE the power is taken, so a huge one is Nothing rather than
  # a bignum the size of memory.
  expect Int32.pow (saturate 2) (saturate 31) == Nothing
  expect Int32.pow (saturate 2) (saturate 30) == Something (saturate 1073741824)
  expect Int32.pow (saturate 2) (saturate (0 - 1)) == Nothing
}

test "clamping saturates and never fails" {
  expect widen (saturate 99999999999) == 2147483647
  expect widen (saturate (0 - 99999999999)) == (0 - 2147483648)
  expect Int32.digits (saturate 0) == 1
  expect Int32.digits (saturate (0 - 1234)) == 4
}

test "division needs a non-zero divisor and can still overflow" {
  let two = saturate 2
  let d = check Int32.nonZero two
  expect half (saturate 7) d == Something (saturate 3)
  # Truncation is toward zero, so -7/2 is -3.
  expect half (saturate (0 - 7)) d == Something (saturate (0 - 3))
  let negativeOne = saturate (0 - 1)
  let minusOne = check Int32.nonZero negativeOne
  expect half Int32.minValue minusOne == Nothing
}
|}

let test_int32_with_go () =
  let emitted = emit_ok "<go-int32>" int32_source in
  let module_go = artifact "internal/teslmodgoint32/module.go" emitted in
  (* No wrapper: the nominal distinction is the checker's and does not survive here. *)
  check bool "an Int32 IS its integer" true
    (contains module_go "func Widen(x teslrt.Int) teslrt.Int {");
  (* The bounds are VALUES, not calls — they are written bare, so they land wherever they are
     used, which in this module is the test block. *)
  check bool "the bounds are values, not calls" true
    (contains (artifact "internal/teslmodgoint32/module_test.go" emitted) "teslrt.Int32MinValue");
  check bool "a narrowing answers a Maybe" true
    (contains module_go "teslrt.Int32FromInt(");
  (* `go test` RUNS the four blocks: every boundary above is asserted there. *)
  gate_emitted "tesl-go-int32" emitted

(* ─── Instants, and the effects with no state of their own ────────────────────
   `PosixMillis` is an exact-integer instant provided by the runtime (an instant crosses
   module boundaries, so it cannot be emitted per module), and `Tesl.Env`/`Tesl.Random`/
   `Tesl.Id` are one runtime call each behind a capability the checker enforces.  Racket
   runs the same sources as the oracle. *)
let time_source = {|module GoTime exposing [ageMs, roundTripSeconds]

import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Time exposing [
  PosixMillis,
  time,
  nowMillis,
  durationMs,
  addMs,
  subtractMs,
  diffMs,
  Time.posixToSeconds,
  Time.secondsToPosix,
]

fn roundTripSeconds(seconds: Int) -> Int =
  Time.posixToSeconds (Time.secondsToPosix seconds)

fn spanMs(fromSeconds: Int, toSeconds: Int) -> Int =
  diffMs (Time.secondsToPosix fromSeconds) (Time.secondsToPosix toSeconds)

fn shifted(seconds: Int, deltaMs: Int) -> Int =
  Time.posixToSeconds (addMs (Time.secondsToPosix seconds) deltaMs)

fn backShifted(seconds: Int, deltaMs: Int) -> Int =
  Time.posixToSeconds (subtractMs (Time.secondsToPosix seconds) deltaMs)

fn ageMs(past: PosixMillis) -> Int
  requires [time] =
  durationMs past

fn nowIsAfterEpoch() -> Bool
  requires [time] =
  diffMs (Time.secondsToPosix 0) (nowMillis ()) > 1700000000000

test "seconds and milliseconds convert both ways" {
  expect roundTripSeconds 7 == 7
  expect roundTripSeconds 0 == 0
  expect spanMs 10 12 == 2000
  expect spanMs 12 10 == -2000
  expect shifted 10 2500 == 12
  expect backShifted 10 2500 == 7
}

test "the clock is read through the time capability" requires [time] {
  expect nowIsAfterEpoch () == True
  expect ageMs (addMs (nowMillis ()) 60000) == 0
}
|}

let effects_source = {|module GoEffects exposing [portOrDefault, hostOrDefault, requiredName, diceInRange]

import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.String exposing [String.length, String.startsWith]
import Tesl.Float exposing [Float]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Env exposing [envRead, env, envInt, envString, requireEnv]
import Tesl.Random exposing [random, randomInt, randomFloat]
import Tesl.Id exposing [generateId, generatePrefixedId]

fn portOrDefault() -> Int
  requires [envRead] =
  envInt "TESL_PROBE_PORT" 8080

fn hostOrDefault() -> String
  requires [envRead] =
  envString "TESL_PROBE_HOST" "localhost"

fn requiredName() -> String
  requires [envRead] =
  requireEnv "TESL_PROBE_NAME"

fn describeEnv() -> String
  requires [envRead] =
  case env "TESL_PROBE_MISSING" of
    Nothing -> "unset"
    Something v -> v

fn diceInRange() -> Bool
  requires [random] =
  let roll = randomInt 1 7
  roll >= 1 && roll < 7

fn freshId() -> String
  requires [random] =
  generatePrefixedId "task"

fn idsDiffer() -> Bool
  requires [random] =
  freshId () != freshId ()

fn bareIdLength() -> Int
  requires [random] =
  String.length (generateId ())

fn unitFraction() -> Bool
  requires [random] =
  let drawn = randomFloat ()
  drawn >= 0.0 && drawn < 1.0

test "env reads fall back when a variable is unset" requires [envRead] {
  expect portOrDefault () == 8080
  expect hostOrDefault () == "localhost"
  expect describeEnv () == "unset"
}

test "randomness stays inside its range" requires [random] {
  expect diceInRange () == True
  expect unitFraction () == True
  expect idsDiffer () == True
  expect bareIdLength () == 33
  expect String.startsWith (freshId ()) "task-" == True
}
|}

let test_time_with_go () =
  let emitted = emit_ok "<go-time>" time_source in
  let module_go = artifact "internal/teslmodgotime/module.go" emitted in
  check bool "an instant is the runtime's own type" true
    (contains module_go "func RoundTripSeconds(seconds teslrt.Int) teslrt.Int");
  check bool "conversions are runtime calls" true
    (contains module_go "teslrt.PosixToSeconds(teslrt.SecondsToPosix(seconds))");
  (* The `time` capability is compile-time: nothing is threaded through the call. *)
  check bool "reading the clock takes no capability argument" true
    (contains module_go "teslrt.NowMillis()");
  gate_emitted "tesl-go-time" emitted

let test_effect_leaves_with_go () =
  let emitted = emit_ok "<go-effects>" effects_source in
  let module_go = artifact "internal/teslmodgoeffects/module.go" emitted in
  check bool "env reads are runtime calls with their fallback" true
    (contains module_go "teslrt.EnvInt(\"TESL_PROBE_PORT\", teslrt.FromInt64(8080))");
  check bool "`env` yields a Maybe" true
    (contains module_go "teslrt.EnvMaybe(\"TESL_PROBE_MISSING\")");
  check bool "randomness comes from the runtime" true
    (contains module_go "teslrt.RandomInt(teslrt.FromInt64(1), teslrt.FromInt64(7))");
  check bool "ids come from the runtime" true
    (contains module_go "teslrt.GeneratePrefixedId(\"task\")");
  (* Two calls of ONE effectful function are not "identical expressions" (staticcheck
     SA4000): each side is bound first, which also pins the evaluation order. *)
  check bool "comparing two calls binds each side" true
    (contains module_go "teslLeft := freshId()");
  gate_emitted "tesl-go-effects" emitted


(* ─── A rejected check must ANSWER, not crash the request ─────────────────────
   Three consumption sites, three different obligations, all measured against Racket:
     • inside another `check` — the rejection PROPAGATES as this check's result
       (Racket's `let/check`: `(if (check-fail? result) result …)`);
     • as a check's whole TAIL — the delegate's `Check` IS the result;
     • inside a HANDLER body — it becomes the response, carrying the check's own status,
       because `dsl/web.rkt` installs the raise-on-escaping-failure wrapper for every
       function kind EXCEPT `handler`.
   Before this, all three emitted `MustCheck`, which TRAPS: a request that should have
   answered 422 crashed instead. *)
let check_delegation_source = {|module GoCheckDelegate exposing [DelegateServer]

import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Int exposing [Int.parse]
import Tesl.Json exposing [stringCodec, intCodec]
import Tesl.ApiTest exposing [statusOk, statusClientError]

fact ValidAge(n: Int)

check checkAge(n: Int) -> n: Int ::: ValidAge n =
  if n > 0 then
    ok n ::: ValidAge n
  else
    fail 422 "age must be positive"

# A check that DELEGATES to another check via a let binding: on Racket the inner
# rejection PROPAGATES (let/check returns the failure), so a handler answers 422.
check checkTwice(raw: Int) -> n: Int ::: ValidAge n =
  let n = check checkAge raw
  ok n ::: ValidAge n

# TAIL delegation: the inner check's result IS this check's result — no unwrapping and
# no re-attaching, on either backend.
check parseAge(raw: String) -> n: Int ::: ValidAge n =
  case Int.parse raw of
    Nothing -> fail 400 "age must be a number"
    Something parsed ->
      check checkAge parsed

record Reply {
  age: Int
}

codec Reply {
  toJson {
    age -> "age" with_codec intCodec
  }
  fromJson_forbidden
}

handler get show(raw: String) -> Reply =
  let parsed = check parseAge raw
  let valid = check checkTwice parsed
  Reply { age: valid }

api DelegateApi {
  get "/show/:raw"
    capture raw: String using stringCodec
    -> Reply
}

server DelegateServer for DelegateApi {
  show
}

api-test "a delegated rejection answers, rather than crashing the request" for DelegateServer requires [] {
  let bad = get "/show/-1"
  expect statusClientError bad.status
  let unparseable = get "/show/abc"
  expect statusClientError unparseable.status
  let good = get "/show/7"
  expect statusOk good.status
}
|}

let test_check_delegation_with_go () =
  let emitted = emit_ok "<go-check-delegate>" check_delegation_source in
  let module_go = artifact "internal/teslmodgocheckdelegate/module.go" emitted in
  check bool "a check's tail delegates by handing back the delegate's own result" true
    (contains module_go "return checkAge(parsed)");
  check bool "a delegated rejection inside a check becomes this check's result" true
    (contains module_go "return teslrt.Reject[teslrt.Int](teslDelegated");
  (* In a handler the rejection travels to the router, which answers with its status. *)
  check bool "a handler consumes a check through the request-boundary form" true
    (contains module_go "teslrt.MustCheckRequest(parseAge(raw))");
  check bool "and a plain function still traps" true
    (not (contains module_go "teslrt.MustCheck(parseAge"));
  (* The api-test RUNS the three paths: 422 for a rejected age, 400 for an unparseable
     one, 200 with the body for the happy path. *)
  gate_emitted "tesl-go-check-delegate" emitted


(* ─── Queues ──────────────────────────────────────────────────────────────────
   The `backend: Memory` job store: `enqueue` from a handler, then the api-test verbs
   (`pendingJobCount`, `processNextJob`, `expectJobOk`) driving the queue's worker.  Racket
   runs the same source as the oracle. *)
let queue_source = {|module GoQueue exposing [QueueServer]

import Tesl.Prelude exposing [Bool(..), Int, String, Unit]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Json exposing [stringCodec, intCodec]
import Tesl.Database exposing [Database, Memory]
import Tesl.List exposing [List.head, List.length]
import Tesl.Queue exposing [
  FromQueue,
  FromDeadQueue,
  queueRead,
  queueWrite,
  Queue,
  QueueRetryStrategy,
  Fixed,
  deadJobs,
  DeadJob,
  requeue,
]
import Tesl.ApiTest exposing [
  statusOk,
  JobResult(..),
  processNextJob,
  pendingJobCount,
  expectJobOk,
  expectJobFailed,
]

database QueueDb = Database {
  schema: "queueprobe"
  entities: []
  backend: Memory
}

record SendJob {
  tag: String
}

queue SendQueue requires [queueRead] = Queue {
  database: QueueDb
  jobs: [Job SendJob handleSend Nothing]
  retry: QueueRetryStrategy {
    maxAttempts: 2
    backoff: Fixed
    initialDelay: 1
  }
}

worker handleSend(job: SendJob ::: FromQueue (Id == jobId) job)
  requires [queueRead] =
  job

record FlakyJob {
  tag: String
}

queue FlakyQueue requires [queueRead] = Queue {
  database: QueueDb
  jobs: [Job FlakyJob handleFlaky Nothing]
  retry: QueueRetryStrategy {
    maxAttempts: 1
    backoff: Fixed
    initialDelay: 1
  }
}

# A worker that always fails, so the job reaches the dead letter on its first attempt.
worker handleFlaky(job: FlakyJob ::: FromQueue (Id == jobId) job)
  requires [queueRead] =
  fail 500 "the upstream refused"

record TriggerRequest {
  tag: String
}

codec TriggerRequest {
  toJson {
    tag -> "tag" with_codec stringCodec
  }
  fromJson [
    {
      tag <- "tag" with_codec stringCodec
    }
  ]
}

record TriggerReply {
  queued: String
}

codec TriggerReply {
  toJson {
    queued -> "queued" with_codec stringCodec
  }
  fromJson_forbidden
}

handler post send(request: TriggerRequest) -> TriggerReply
  requires [queueWrite] =
  enqueue SendJob { tag: request.tag }
  TriggerReply { queued: request.tag }

handler post sendFlaky(request: TriggerRequest) -> TriggerReply
  requires [queueWrite] =
  enqueue FlakyJob { tag: request.tag }
  TriggerReply { queued: request.tag }

api QueueApi {
  post "/send"
    body request: TriggerRequest
    -> TriggerReply
  post "/flaky"
    body request: TriggerRequest
    -> TriggerReply
}

server QueueServer for QueueApi {
  send
  sendFlaky
}

api-test "the queue dequeues in enqueue order" for QueueServer requires [queueRead, queueWrite] {
  let r1 = post "/send" body { "tag": "one" }
  expect statusOk r1.status
  let r2 = post "/send" body { "tag": "two" }
  expect statusOk r2.status

  expect pendingJobCount SendQueue == 2

  let resA = processNextJob SendQueue
  let jobA = expectJobOk resA
  expect jobA.tag == "one"

  let resB = processNextJob SendQueue
  let jobB = expectJobOk resB
  expect jobB.tag == "two"

  expect pendingJobCount SendQueue == 0
}

# `requeue` takes a job OUT of the dead letter and back to pending, so the workers pick it up
# again.  The `FromDeadQueue` proof is what stops an arbitrary value being passed here; it
# erases, and what is left is the reset.
api-test "requeue takes a dead job back to pending" for QueueServer requires [queueRead, queueWrite] {
  let r1 = post "/flaky" body { "tag": "one" }
  expect statusOk r1.status
  let failed = processNextJob FlakyQueue
  let message = expectJobFailed failed
  expect pendingJobCount FlakyQueue == 0
  expect List.length (deadJobs FlakyQueue) == 1
  case List.head (deadJobs FlakyQueue) of
    Something job -> expect requeue job == True
    Nothing -> expect List.length (deadJobs FlakyQueue) == 99
  expect pendingJobCount FlakyQueue == 1
  expect List.length (deadJobs FlakyQueue) == 0
}
|}

let test_queue_with_go () =
  let emitted = emit_ok "<go-queue>" queue_source in
  let module_go = artifact "internal/teslmodgoqueue/module.go" emitted in
  check bool "a queue becomes one package-level store with its retry rule" true
    (contains module_go "var SendQueueQueue = teslrt.NewQueue(\"SendQueue\", 2)");
  check bool "`enqueue` names the job type and resolves to its queue" true
    (contains module_go "teslrt.EnqueueJob(SendQueueQueue, ");
  (* A record copied field-for-field into a structurally identical one is emitted as a
     CONVERSION: the struct literal is a staticcheck finding (S1016) on emitted code. *)
  check bool "a field-for-field record copy becomes a conversion" true
    (contains module_go "SendJob(request)");
  let tests_go = artifact "internal/teslmodgoqueue/module_test.go" emitted in
  check bool "an api-test drives the queue's own worker" true
    (contains tests_go "teslrt.ProcessNextJob(SendQueueQueue, func(teslPayload any) teslrt.JobOutcome {");
  check bool "and an empty queue traps with the Racket hint" true
    (contains tests_go "panic(teslrt.EmptyQueue(\"SendQueue\", \"processNextJob\"))");
  check bool "a JSON body template becomes constant JSON" true
    (contains tests_go "teslrt.ApiRequest(QueueServer, \"POST\", \"/send\", \"{\\\"tag\\\":\\\"one\\\"}\", nil, nil)");
  (* `requeue` takes a job OUT of the dead letter: the value carries the queue it came from,
     since the call names none. *)
  check bool "`requeue` resets a dead job to pending" true
    (contains tests_go "teslrt.Requeue(");
  check bool "and reads the dead letter from the queue it names" true
    (contains tests_go "teslrt.DeadJobs(FlakyQueueQueue)");
  (* `go test` RUNS the api-test: FIFO order and the pending count are asserted there. *)
  gate_emitted "tesl-go-queue" emitted


(* ─── `Tesl.Crypto`: message authentication, digests, tokens ──────────────────
   Every primitive is Go's standard library, and each is the same primitive the Racket runtime
   reaches for in libsodium — so a tag, a fingerprint or a session value produced by one backend
   verifies on the other (the runtime suite asserts the actual digests against Racket's).  What
   is REFUSED is password storage: Racket uses libsodium's Argon2id, Go's standard library has no
   Argon2, and a PBKDF2 substitute would mint hashes the other backend cannot verify — so it
   waits on a dependency decision rather than shipping a divergence. *)
let crypto_source = {|module GoCrypto exposing [signPayload, verifyPayload, contentTag, keyId]

import Tesl.Prelude exposing [Bool, String]
import Tesl.String exposing [String.length]
import Tesl.Env exposing [requireSecret, envRead]
import Tesl.Random exposing [random]
import Tesl.Crypto exposing [
  Secret,
  Signature,
  Crypto.signWith,
  Crypto.checkSignature,
  Crypto.signatureHex,
  Crypto.signatureFromHex,
  Crypto.signatureBase64,
  Crypto.signatureFromBase64,
  Crypto.fingerprint,
  Crypto.keyFingerprint,
  Crypto.sha256,
  Crypto.sha512,
  Crypto.randomToken,
]

capability signing implies envRead, random

fact Trusted (payload: String)

fn signingKey() -> Secret
  requires [signing] =
  requireSecret "GOCRYPTO_KEY"

fn signPayload(payload: String) -> String
  requires [signing] =
  Crypto.signatureHex (Crypto.signWith (signingKey()) payload)

fn base64Payload(payload: String) -> String
  requires [signing] =
  Crypto.signatureBase64 (Crypto.signWith (signingKey()) payload)

# A verification is a CHECK: it answers the verified payload or fails 401, and the
# constant-time compare lives inside it.
check verifyPayload(payload: String, tag: String) -> verified: String ::: Trusted verified
  requires [signing] =
  let verified = check Crypto.checkSignature (signingKey()) (Crypto.signatureFromHex tag) payload
  ok verified ::: Trusted verified

fn contentTag(content: String) -> String =
  Crypto.fingerprint content

fn keyId() -> String
  requires [signing] =
  Crypto.keyFingerprint (signingKey())

test "a tag verifies against the payload it was made for" requires [signing] {
  let payload = "{\"event\":\"ping\"}"
  let tag = signPayload payload
  # 32 bytes as hex.
  expect String.length tag == 64
  let verified = check verifyPayload payload tag
  expect verified == payload
}

test "a tampered payload does not verify" requires [signing] {
  let tag = signPayload "{\"event\":\"ping\"}"
  expectFail check verifyPayload "{\"event\":\"pong\"}" tag
}

test "the base64 transport carries the same tag" requires [signing] {
  let payload = "p"
  let hex = signPayload payload
  let b64 = base64Payload payload
  expect hex != b64
  expect Crypto.signatureHex (Crypto.signatureFromBase64 b64) == hex
  expect String.length b64 < String.length hex
}

test "digests are stable, and a key fingerprint is short and domain-separated" requires [signing] {
  expect contentTag "hello" == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
  expect Crypto.sha256 "hello" == contentTag "hello"
  expect String.length (Crypto.sha512 "hello") == 128
  expect String.length (keyId()) == 16
  expect keyId() != contentTag "hello"
}

test "a random token is 256 bits of URL-safe text" requires [signing] {
  let token = Crypto.randomToken()
  expect String.length token == 43
  expect token != Crypto.randomToken()
}
|}

let test_crypto_with_go () =
  let emitted = emit_ok "<go-crypto>" crypto_source in
  let module_go = artifact "internal/teslmodgocrypto/module.go" emitted in
  check bool "a Secret is the runtime's own secret newtype" true
    (contains module_go "func signingKey() teslrt.Secret");
  check bool "signing is one runtime call over the key" true
    (contains module_go "teslrt.SignatureHex(teslrt.SignWith(signingKey(), payload))");
  (* The important one: a verification rejected inside a `check` must PROPAGATE, not panic.
     `Crypto.checkSignature` parses as a field read on a constructor rather than as one
     identifier, which is how it slipped past the delegation path and emitted `MustCheck` — a
     panic where the request should have answered 401. *)
  check bool "a rejected verification propagates rather than panicking" true
    (contains module_go "return teslrt.Reject[string](teslDelegated1.Status(), teslDelegated1.Message())");
  check bool "and the verification itself is the runtime's constant-time one" true
    (contains module_go "teslrt.CheckSignature(signingKey(), teslrt.SignatureFromHex(tag), payload)");
  gate_emitted ~env:[ "GOCRYPTO_KEY=test-signing-key" ] "tesl-go-crypto" emitted

(* ─── The check-driven container leaves, and seeded blocks ─────────────────────
   `List.filterCheck` had a Set counterpart and an empty-list constructor that were refused, and
   an api-test or load-test could not SEED its store — three gaps that each stopped a whole file
   on one line. *)
let check_leaf_source = {|module GoCheckLeaves exposing [positives, uniquePositives, noneYet]

import Tesl.Prelude exposing [Int, List, Bool(..)]
import Tesl.List exposing [List.filterCheck, List.emptyForAll, List.length]
import Tesl.Set exposing [Set, Set.filterCheck, Set.fromList, Set.size]

fact Positive (n: Int)

check checkPos(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "not positive"

fn positives(ns: List Int) -> List Int ::: ForAll (Positive) =
  List.filterCheck checkPos ns

fn uniquePositives(s: Set Int) -> Set Int ::: ForAll (Positive) =
  Set.filterCheck checkPos s

# The EMPTY list carrying the proof the check would have made of every element — vacuously true.
fn noneYet() -> List Int ::: ForAll (Positive) =
  List.emptyForAll checkPos

test "filterCheck keeps what the check accepts, in both containers" {
  expect List.length (positives [1, 0 - 2, 3]) == 2
  expect Set.size (uniquePositives (Set.fromList [1, 0 - 2, 3, 3])) == 2
  expect List.length (noneYet()) == 0
}
|}

let test_check_leaves_with_go () =
  let emitted = emit_ok "<go-check-leaves>" check_leaf_source in
  let module_go = artifact "internal/teslmodgocheckleaves/module.go" emitted in
  (* The Set version rebuilds a set from the accepted elements, going through the set's own list
     so ONE traversal rule covers both containers. *)
  check bool "Set.filterCheck rebuilds a set from the accepted elements" true
    (contains module_go
       "teslOut1 = teslrt.SetInsert(teslKept1, teslOut1, teslKeyLessTeslrtInt)");
  check bool "and it walks the set through its own list" true
    (contains module_go "range teslrt.SetToList(s)");
  (* `emptyForAll` is the empty slice: the proof erases, and the check names the element type. *)
  check bool "emptyForAll is the empty slice" true
    (contains module_go "return []teslrt.Int{}");
  gate_emitted "tesl-go-check-leaves" emitted

(* A seeded api-test: rows the block declares, inserted before its own statements — which is what
   pairs with the per-test reset, since a block that seeds must not inherit another's rows. *)
let seeded_source = {|module GoSeeded exposing [Widget, listWidgets, SeedApi, SeedServer]

import Tesl.Prelude exposing [Int, String, List]
import Tesl.Json exposing [intCodec]
import Tesl.Database exposing [Database, Memory]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.List exposing [List.length]
import Tesl.ApiTest exposing [statusOk]

entity Widget table "seed_widgets" primaryKey id {
  id: String
  label: String
}

database SeedDb = Database {
  schema: "goseeded"
  entities: [Widget]
  backend: Memory
}

record Count { widgets: Int }

codec Count {
  toJson {
    widgets -> "widgets" with_codec intCodec
  }
  fromJson_forbidden
}

handler get listWidgets() -> Count
  requires [dbRead] =
  let rows = select w from Widget
  Count { widgets: List.length rows }

api SeedApi {
  get "/widgets"
    -> Count
}

server SeedServer for SeedApi {
  listWidgets
}

api-test "a seeded block sees the rows it declared" for SeedServer requires [dbRead, dbWrite] {
  seed {
    insert Widget { id: "w-1", label: "first" }
    insert Widget { id: "w-2", label: "second" }
  }
  let counted = get "/widgets"
  expect statusOk counted.status
  expect counted.body.widgets == 2
}

api-test "and the next block does not inherit them" for SeedServer requires [dbRead, dbWrite] {
  let counted = get "/widgets"
  expect counted.body.widgets == 0
}
|}

let test_seeded_api_test_with_go () =
  let emitted = emit_ok "<go-seeded>" seeded_source in
  let tests_go = artifact "internal/teslmodgoseeded/module_test.go" emitted in
  check bool "the seed runs before the block's own statements" true
    (contains tests_go "_ = teslrt.TableInsert(WidgetTable, \"Widget\"");
  (* The reset comes FIRST, or the second block would count the first block's rows — which the
     second api-test asserts at runtime. *)
  check bool "and after the per-test reset" true
    (contains tests_go "teslResetTestState()");
  gate_emitted "tesl-go-seeded" emitted

(* ─── `Tesl.Telemetry`, `Tesl.App`, and load tests ─────────────────────────────
   Three things that arrive together, because a program that reports signals is usually the same
   program that runs as a server and gets load-tested.

   Telemetry is AMBIENT by design — an observability call that needed a capability would be
   threaded through every signature or left out of the code that most needs it — so what is left
   at run time is one recorder call per signal. What this backend does NOT do is export: OTLP, the
   `/v1/metrics` endpoint and the span tree are the Racket runtime's, and an exporter that
   silently dropped spans would be worse than an honestly absent one.

   `main() -> App { … }` is CONFIGURATION, not a value: the compiler lowers it into the startup
   chain it describes (activate each queue's workers, then serve) through the same
   backend-neutral pass the Racket path uses, and the emitted program gets the one `package main`
   Go needs to build a binary. *)
let telemetry_app_source = {|module GoTelemetryApp exposing [greet, TelemetryApi, TelemetryServer]

import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Float exposing [Float]
import Tesl.String exposing [String.length]
import Tesl.Json exposing [stringCodec]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]
import Tesl.Telemetry exposing [initTelemetry, telemetry, counter, histogram, gauge]
import Tesl.ApiTest exposing [statusOk]

record Greeting { message: String }

codec Greeting {
  toJson {
    message -> "message" with_codec stringCodec
  }
  fromJson_forbidden
}

# A telemetry block is a STATEMENT: the function has the type it would have without it, which is
# what every telemetry test in the corpus asserts.
fn greet(name: String) -> String =
  let _ = telemetry "greet.called" { user.name = name, length = String.length name, ok = True }
  let _ = counter "greetings" 1 []
  let _ = histogram "greeting.length" 1.5 []
  let _ = gauge "greeters" 1.0 []
  name

handler get greeting() -> Greeting =
  Greeting { message: greet "world" }

api TelemetryApi {
  get "/greeting"
    -> Greeting
}

server TelemetryServer for TelemetryApi {
  greeting
}

database TelemetryDb = Database {
  schema: "gotelemetryapp"
  entities: []
  backend: Memory
}

main() -> App requires [] =
  let _ = initTelemetry service "go-telemetry-app" endpoint "in-memory" console False
  App {
    database: TelemetryDb
    api: TelemetryServer
    port: 8099
  }

test "telemetry does not disturb the function's result" {
  expect greet "world" == "world"
}

api-test "an endpoint that reports signals still answers" for TelemetryServer {
  let response = get "/greeting"
  expect statusOk response.status
  expect response.body.message == "world"
}

load-test "the greeting endpoint under load" for TelemetryServer
  rate 50rps
  duration 1s
  baseline "greeting-latency" {

  get "/greeting"

  assert errorRate < 0.01
  assert regressionVsBaseline p95 < 1.5
}
|}

let test_debug_main_starts_control_server () =
  let emitted =
    match Compile.compile_go_source ~debug:true "<go-debug-main>" telemetry_app_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "debug main compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let main_go = artifact "cmd/app/main.go" emitted in
  check bool "debug main starts discovered control endpoint" true
    (contains main_go "teslrt.StartDebugControlFromEnvironment()");
   check bool "debug main imports runtime" true (contains main_go "/internal/teslrt");
   ignore (artifact "internal/teslrt/debug_control.go" emitted);
   gate_emitted ~short:true "tesl-go-debug-main" emitted;
   let test_emitted =
     match Compile.compile_go_source ~debug:true "<go-debug-tests>" source with
     | Compile.GoSuccess artifacts -> artifacts
     | Compile.GoFailure diagnostics ->
       failf "debug test compilation failed: %s"
         (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
   in
   let tests_go = artifact "internal/teslmodgosmoke/module_test.go" test_emitted in
   check bool "debug tests start the control endpoint" true
     (contains tests_go "teslrt.StartDebugControlFromEnvironment()");
   gate_emitted ~short:true "tesl-go-debug-tests" test_emitted

let test_telemetry_app_with_go () =
  let emitted = emit_ok "<go-telemetry-app>" telemetry_app_source in
  let module_go = artifact "internal/teslmodgotelemetryapp/module.go" emitted in
  (* Each attribute value is rendered to text HERE, where its type is known — the runtime takes
     one attribute type while a block's values are a mixed bag. *)
  check bool "a telemetry block is one recorder call with rendered attributes" true
    (contains module_go
       "teslrt.Telemetry(\"greet.called\", []teslrt.Tuple2[string, string]{{Tuple2First: \"user.name\", Tuple2Second: name}");
  check bool "an Int attribute renders through its own String()" true
    (contains module_go "Tuple2Second: (teslrt.StringLength(name)).String()");
  (* A secret attribute never gets here at all: the CHECKER refuses one, which is better than
     redacting — a redacted attribute is useless rather than safe. The emitter's redaction branch
     is defence in depth behind that. *)
  check bool "the three instruments are one runtime call each" true
    (contains module_go "teslrt.Counter(\"greetings\", teslrt.FromInt64(1)");
  (* `main` lowers into the startup chain; the App record has no runtime form. *)
  check bool "main serves the declared server on the declared port" true
    (contains module_go "teslrt.Serve(TelemetryServer, teslrt.ServeOptions{Port: teslrt.PortOf(teslrt.FromInt64(8099))})");
  check bool "and initTelemetry's keyword surface becomes one call" true
    (contains module_go
       "teslrt.InitTelemetry(\"go-telemetry-app\", \"in-memory\", false, true, false, 60000, 1.0)");
  (* A program gets the one `package main` Go needs to build a binary. *)
  let main_go = artifact "cmd/app/main.go" emitted in
  check bool "the entry point calls the module's Main" true
    (contains main_go "teslmodgotelemetryapp.Main()");
  (* A load test drives the same in-process dispatch an api-test does, at a fixed arrival rate. *)
  let tests_go = artifact "internal/teslmodgotelemetryapp/module_test.go" emitted in
   check bool "a load-test block becomes a Go test over the harness" true
     (contains tests_go "teslResult := teslrt.RunLoadTest(50, 1, func() int {");
   check bool "named test launch filters by description or Go name" true
     (contains tests_go "os.Getenv(\"TESL_TEST_NAME\")");
   check bool "named test launch filters by block kind" true
     (contains tests_go "os.Getenv(\"TESL_TEST_KIND\")");
   check bool "its assertion names the metric and the threshold" true
    (contains tests_go
       "teslrt.AssertLoadTest(teslT, teslResult, \"errorRate\", \"<\", float64(0.01))");
  check bool "and `-short` skips it, so an ordinary test run does not pay for it" true
    (contains tests_go "if testing.Short() {");
  (* A `baseline` clause and a regression assertion are NOTED rather than refused or dropped.
     Neither backend stores baselines — `dsl/load-test.rkt` prints "store/compare deferred" — so
     refusing would fail to compile a load test that runs on Racket, and dropping would read as a
     regression check that ran.  The note text is the Racket text, so the oracle compares it. *)
  check bool "a regression assertion is noted rather than silently dropped" true
    (contains tests_go "teslrt.NoteLoadTestRegression(teslT, \"p95\", float64(1.5))");
  check bool "and the baseline clause after it" true
    (contains tests_go "teslrt.NoteLoadTestBaseline(teslT, \"greeting-latency\")");
  gate_emitted ~short:true "tesl-go-telemetry-app" emitted

(* ─── `case` over a scalar ─────────────────────────────────────────────────────
   `case a + b of 0 -> … | _ -> …` is ordinary Tesl and was refused outright ("supports `case`
   over a module ADT only"), which blocked whole files on one line. The emitted shape is an
   if/else-if chain rather than a Go `switch` on the value, because `teslrt.Int` is deliberately
   not comparable with `==`; the scrutinee is bound once, so a non-trivial one is evaluated once.
   `True`/`False` parse as nullary CONSTRUCTORS but over a Bool scrutinee they are the two
   literals, which is how Racket matches them too. *)
let scalar_case_source = {|module GoScalarCase exposing [classify, label, flagName, tally]

import Tesl.Prelude exposing [Int, String, Bool(..)]

fn classify(a: Int, b: Int) -> Int =
  case a + b of
    0 -> 100
    1 -> 200
    _ -> a + b

fn label(text: String) -> Int =
  case text of
    "yes" -> 1
    "no" -> 0
    _ -> 0 - 1

fn flagName(flag: Bool) -> String =
  case flag of
    True -> "on"
    False -> "off"

# A variable pattern binds the scrutinee, and a guard may read the name it binds.
fn tally(n: Int) -> String =
  case n of
    0 -> "none"
    other where other > 10 -> "many"
    other -> "some"

test "a scalar case discriminates by literal" {
  expect classify 0 0 == 100
  expect classify 1 0 == 200
  expect classify 3 4 == 7
  expect label "yes" == 1
  expect label "no" == 0
  expect label "maybe" == 0 - 1
  expect flagName True == "on"
  expect flagName False == "off"
}

test "a variable pattern binds, and a guard filters" {
  expect tally 0 == "none"
  expect tally 50 == "many"
  expect tally 3 == "some"
}
|}

let test_scalar_case_with_go () =
  let emitted = emit_ok "<go-scalar-case>" scalar_case_source in
  let module_go = artifact "internal/teslmodgoscalarcase/module.go" emitted in
  (* The scrutinee is bound once — `a + b` is not re-evaluated per arm. *)
  check bool "the scrutinee is bound once" true
    (contains module_go "teslScrut1 := teslrt.Add(a, b)");
  (* The arms are ONE expressionless switch: first match wins, no fallthrough, at most one
     arm — which is what a `case` means, and what an if/else chain of equality tests against
     one value is only by convention (staticcheck asks for the switch: QF1003). *)
  check bool "an Int literal arm compares through the runtime" true
    (contains module_go "case teslrt.Equal(teslScrut1, teslrt.FromInt64(0)):");
  check bool "a String literal arm compares directly" true
    (contains module_go "switch teslScrut1 {") ;
  check bool "a Bool arm is the scrutinee, or its negation" true
    (contains module_go "case !teslScrut1:");
  (* A guarded variable arm binds BEFORE the guard runs: the guard names the variable. *)
  check bool "a guarded variable pattern binds before its guard" true
    (contains module_go "other := teslScrut1");
  check bool "and exhaustiveness is the checker's, stated rather than defaulted" true
    (contains module_go "panic(\"unreachable: checker guarantees case exhaustiveness\")");
  gate_emitted "tesl-go-scalar-case" emitted

(* A NEWTYPE scrutinee compares through its payload, since the pattern is written as the base
   value (`case code of 404 -> …`). This is Go-only on purpose: the same program RAISES on
   Racket — `=: contract violation … given: (newtype-value … 404)` — a newtype-unwrap gap at the
   pattern-comparison site, of the same family as the `>=`/`<=` and dot-read gaps fixed earlier.
   Recorded rather than fixed here; the Go behaviour is the correct one. *)
let newtype_case_source = {|module GoNewtypeCase exposing [viaNewtype]

import Tesl.Prelude exposing [Int, String]

type Code = Int

fn viaNewtype(code: Code) -> String =
  case code of
    404 -> "missing"
    _ -> "other"

test "a newtype scrutinee compares through its payload" {
  expect viaNewtype (Code 404) == "missing"
  expect viaNewtype (Code 200) == "other"
}
|}

let test_newtype_case_with_go () =
  let emitted = emit_ok "<go-newtype-case>" newtype_case_source in
  let module_go = artifact "internal/teslmodgonewtypecase/module.go" emitted in
  check bool "the comparison reads the newtype's payload" true
    (contains module_go "teslrt.Equal(teslScrut1.Value, teslrt.FromInt64(404))");
  gate_emitted "tesl-go-newtype-case" emitted

(* ─── `Tesl.JWT` and the session cookie ───────────────────────────────────────
   The one blessed session: an HS256 token in one fixed `__Host-`-prefixed cookie, with no
   options anywhere. The signature is `Tesl.Crypto`'s HMAC-SHA256 over `header.payload`, so a
   token minted by either backend verifies on the other — the runtime suite pins that against an
   actual Racket-minted token, and this case pins the SURFACE: what the emitter writes, and that
   the whole round trip behaves the same on both backends. *)
let jwt_source = {|module GoJwt exposing [issue, subjectOf, renewFor, LoginOut, SessionApi, SessionServer]

import Tesl.Prelude exposing [Bool, String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Dict exposing [Dict, Dict.singleton, Dict.lookup]
import Tesl.Json exposing [stringCodec, boolCodec]
import Tesl.String exposing [String.startsWith]
import Tesl.Env exposing [requireSecret, envRead]
import Tesl.Crypto exposing [Secret]
import Tesl.Time exposing [time]
import Tesl.JWT exposing [jwt, JwtToken, JWT.sign, JWT.verify, JWT.renew, JWT.decode, Authentic]
import Tesl.Http exposing [
  HttpRequest,
  cookieCap,
  Http.setSessionCookie,
  Http.clearSessionCookie,
  Http.sessionToken,
]
import Tesl.ApiTest exposing [statusOk, responseCookie]

# A module-level constant: the JOSE header prefix every token shares, which is what makes the
# `kid` stamp assertable without repeating it.
joseHeaderPrefix = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6"

capability sessions implies jwt, cookieCap, envRead, time

fn sessionKey() -> Secret
  requires [sessions] =
  requireSecret "GOJWT_KEY"

fn issue(subject: String) -> JwtToken
  requires [sessions] =
  JWT.sign (Dict.singleton "sub" subject) (sessionKey())

fn subjectOf(token: JwtToken) -> String
  requires [sessions] =
  let claims = check JWT.verify token (sessionKey())
  case Dict.lookup "sub" claims of
    Nothing -> ""
    Something s -> s

fn renewFor(token: JwtToken) -> JwtToken
  requires [sessions] =
  check JWT.renew token (sessionKey())

fn decodedSubject(token: JwtToken) -> String
  requires [sessions] =
  case Dict.lookup "sub" (JWT.decode token) of
    Nothing -> ""
    Something s -> s

record LoginOut { succeeded: Bool }

codec LoginOut {
  toJson {
    succeeded -> "succeeded" with_codec boolCodec
  }
  fromJson_forbidden
}

# A handler that writes the session cookie and then FAILS: no session may escape on a non-2xx
# response even though the cookie was written.
handler post loginThenFail() -> LoginOut
  requires [sessions] =
  let _ = Http.setSessionCookie (issue "carol")
  fail 403 "second factor required"

handler post login() -> LoginOut
  requires [sessions] =
  let _ = Http.setSessionCookie (issue "carol")
  LoginOut { succeeded: True }

api SessionApi {
  post "/login"
    -> LoginOut

  post "/login-then-fail"
    -> LoginOut
}

server SessionServer for SessionApi {
  login
  loginThenFail
}

test "a token round-trips through sign and verify" requires [sessions] {
  let token = issue "carol"
  expect subjectOf token == "carol"
  expect decodedSubject token == "carol"
  expect String.startsWith token.value joseHeaderPrefix
}

test "a token minted under another key does not verify" requires [sessions] {
  let token = JWT.sign (Dict.singleton "sub" "mallory") (Secret "not-the-session-key")
  expectFail subjectOf token
}

test "renewal preserves the subject" requires [sessions] {
  let token = issue "carol"
  expect subjectOf (renewFor token) == "carol"
}

api-test "a successful login sets the session cookie" for SessionServer requires [sessions] {
  let response = post "/login"
  expect statusOk response.status
  case responseCookie response of
    Nothing -> expect False
    Something cookie -> expect String.startsWith cookie "__Host-session="
}

api-test "a handler that fails mints no session" for SessionServer requires [sessions] {
  let response = post "/login-then-fail"
  expect response.status == 403
  case responseCookie response of
    Nothing -> expect True
    Something cookie -> expect False
}
|}

let test_jwt_with_go () =
  let emitted = emit_ok "<go-jwt>" jwt_source in
  let module_go = artifact "internal/teslmodgojwt/module.go" emitted in
  check bool "a module-level constant becomes a package-level var" true
    (contains module_go "var JoseHeaderPrefix = \"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6\"");
  check bool "signing is one runtime call over the claims dict" true
    (contains module_go
       "teslrt.JwtSign(teslrt.DictSingleton(\"sub\", subject), sessionKey(teslScope))");
  (* A verification rejected inside a `fn` traps, as it does on Racket; inside a HANDLER it
     answers. What matters here is that it is the runtime's check, not a hand-rolled compare. *)
  check bool "verification goes through the runtime's check" true
    (contains module_go "teslrt.JwtVerify(token, sessionKey(teslScope))");
  (* Every function declaring the BUNDLE takes the scope, including the pure ones: the
     `requires` clause is the proxy for "may write to the response", and a bundle makes that
     proxy coarse. It is sound and it is visible — a call-graph pass would narrow it. *)
  (* The cookie writer needs the request scope, and `sessions implies cookieCap` is what says
     so — testing the capability NAME directly missed every program that bundles capabilities. *)
  check bool "an implied cookieCap still threads the request scope" true
    (contains module_go "func login(teslScope *teslrt.RequestScope) LoginOut");
  check bool "the session cookie is written through the scope" true
    (contains module_go "teslrt.SetSessionCookie(teslScope, Issue(teslScope, \"carol\"))");
  (* A handler's `fail` is a statement, not a returned closure: `panic` terminates, which is
     also what keeps it gofmt-stable at any message length. *)
  check bool "a handler's `fail` travels as a request rejection" true
    (contains module_go
       "panic(teslrt.RequestRejection{Status: 403, Message: \"second factor required\"})");
  gate_emitted ~env:[ "GOJWT_KEY=test-session-key" ] "tesl-go-jwt" emitted

(* Password storage: Argon2id through `golang.org/x/crypto/argon2`, the ONE approved non-stdlib
   dependency emitted code can take (maintainer decision, 2026-08-14).  The alternatives were
   both worse: stdlib PBKDF2 would mint hashes the Racket side cannot verify — a shared database
   becoming a silent lockout — and hand-writing Argon2id would put hand-rolled cryptography in
   the runtime.  The runtime suite verifies an ACTUAL libsodium hash, which is the property that
   justifies the dependency; what is checked here is that the dependency travels correctly and
   only with the programs that need it. *)
let password_source = {|module GoPassword exposing [Stored, register, signIn, staleHash]

import Tesl.Prelude exposing [Bool, String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Random exposing [random]
import Tesl.Crypto exposing [
  PasswordHash,
  Crypto.hashPassword,
  Crypto.checkPassword,
  Crypto.needsRehash,
]

capability accounts implies random

secret Password = String

fact SignedIn (stored: Maybe PasswordHash)

record Stored { hash: PasswordHash }

fn register(plaintext: Password) -> Stored
  requires [accounts] =
  Stored { hash: Crypto.hashPassword plaintext }

# The check is used for its FAILURE: reaching the next line at all is the guarantee.
check signIn(stored: Maybe PasswordHash, submitted: Password) -> verified: Maybe PasswordHash ::: SignedIn verified requires [accounts] =
  let verified = check Crypto.checkPassword stored submitted
  ok verified ::: SignedIn verified

fn staleHash(hash: PasswordHash) -> Bool =
  Crypto.needsRehash hash

test "a fresh hash verifies, and does not ask to be rehashed" requires [accounts] {
  let stored = register (Password "hunter2")
  let verified = check signIn (Something stored.hash) (Password "hunter2")
  expect staleHash stored.hash == False
}

test "a wrong password does not verify" requires [accounts] {
  let stored = register (Password "hunter2")
  expectFail check signIn (Something stored.hash) (Password "hunter3")
}

# A missing account answers exactly like a wrong password — same status, same message — because
# the difference would enumerate the user table.
test "a missing account is refused too" requires [accounts] {
  expectFail check signIn Nothing (Password "hunter2")
}

test "two hashes of one password differ, since each draws its own salt" requires [accounts] {
  let first = register (Password "hunter2")
  let second = register (Password "hunter2")
  expect staleHash first.hash == False
  expect staleHash second.hash == False
}
|}

let test_password_storage_with_go () =
  let emitted = emit_ok "<go-password>" password_source in
  let module_go = artifact "internal/teslmodgopassword/module.go" emitted in
  (* The plaintext reaches the runtime as the secret newtype's own payload — never as a bare
     string, and with no `Reveal()` at the call site. *)
  check bool "the plaintext is handed over as a SecretString" true
    (contains module_go "teslrt.HashPassword(plaintext.Value)");
  check bool "and a verification takes the same shape" true
    (contains module_go "teslrt.CheckPassword(stored, submitted.Value)");
  check bool "no call site reveals the plaintext" false (contains module_go ".Reveal()");
  (* The dependency travels with the program that needs it, pinned, with its go.sum. *)
  let go_mod = artifact "go.mod" emitted in
  check bool "the emitted module requires x/crypto" true
    (contains go_mod "require golang.org/x/crypto v0.55.0");
  ignore (artifact "go.sum" emitted);
  ignore (artifact "internal/teslrt/password.go" emitted);
  gate_emitted "tesl-go-password" emitted

(* And nothing else carries it: a program that stores no passwords emits a go.mod with no
   requirements at all, which is the property the by-reference rule protects. *)
let test_password_dependency_ships_only_where_needed () =
  let emitted = emit_ok "<go-no-password>" recursion_source in
  let go_mod = artifact "go.mod" emitted in
  check bool "a program without password storage requires nothing" false
    (contains go_mod "require");
  check bool "and does not ship the Argon2 runtime" false
    (List.exists (fun (a : Emit_go.artifact) -> a.path = "internal/teslrt/password.go") emitted);
  check bool "nor a go.sum" false
    (List.exists (fun (a : Emit_go.artifact) -> a.path = "go.sum") emitted)

(* The pinned versions are the runtime module's own: a bump in one place would otherwise leave
   emitted projects on a version whose hashes no longer match, which fails at `go build` time in
   a way that reads as an emitter bug. *)
let test_dependency_pin_matches_the_runtime_module () =
  let read path =
    let full = Filename.concat (Compile.default_root_path ()) path in
    In_channel.with_open_bin full In_channel.input_all
  in
  let runtime_go_mod = read "runtime/go/go.mod" in
  let runtime_go_sum = read "runtime/go/go.sum" in
  let emitted = emit_ok "<go-password-pin>" password_source in
  let go_mod = artifact "go.mod" emitted in
  List.iter (fun requirement ->
    check bool (requirement ^ " is the runtime module's version") true
      (contains runtime_go_mod requirement && contains go_mod requirement))
    [ "golang.org/x/crypto v0.55.0"; "golang.org/x/sys v0.47.0" ];
  (* The emitted go.sum is a SUBSET of the runtime module's, not a copy of it: this repo's
     module also builds `postgres.go`, whose pgx dependency emitted code never sees (the file
     is deliberately outside the embedded runtime).  What must hold is that every line the
     emitter pins is the runtime module's line for that module — a hash that drifted would let
     an emitted project build against a dependency this repo never verified — and that the pin
     covers everything the emitted go.mod requires. *)
  let lines text =
    String.split_on_char '\n' text
    |> List.filter (fun line -> String.trim line <> "") in
  let emitted_sum = artifact "go.sum" emitted in
  List.iter (fun line ->
    check bool ("pinned line is the runtime module's: " ^ line) true
      (List.mem line (lines runtime_go_sum))) (lines emitted_sum);
  List.iter (fun dependency ->
    check bool (dependency ^ " is pinned in the emitted go.sum") true
      (List.exists (fun line ->
         String.length line > String.length dependency
         && String.sub line 0 (String.length dependency) = dependency) (lines emitted_sum)))
    [ "golang.org/x/crypto"; "golang.org/x/sys" ]

(* ─── Derived decoders, and the near-miss batch they came from ────────────────
   A request-body record needs no `codec` block: Racket decodes it generically from the record
   spec at run time, so the type IS the contract.  The emitter had no counterpart and still
   emitted the dispatcher's `Decode<T>JSON` call, so the package referenced a function nobody
   wrote — uncompilable Go rather than a refusal, which is the worst shape a gap can take. *)
let derived_body_source = {|module GoDerivedBody exposing [Inner, Outer, Reply, save, DerivedApi, DerivedServer]

import Tesl.Prelude exposing [Bool, Int, String, List]
import Tesl.Float exposing [Float]
import Tesl.ApiTest exposing [statusOk, statusClientError]

secret Token = String

record Inner { note: String, count: Int }
record Outer {
  name: String
  token: Token
  inner: Inner
  tags: List String
  ratio: Float
  active: Bool
}
record Reply { saved: String }

handler post save(body: Outer) -> Reply =
  let out = Reply { saved: body.inner.note }
  out

api DerivedApi {
  post "/save"
    body body: Outer
    -> Reply
}

server DerivedServer for DerivedApi {
  save
}

api-test "a record with no codec still decodes, nested and all" for DerivedServer {
  let fine = post "/save" body { "name": "n", "token": "t", "inner": { "note": "hi", "count": 2 }, "tags": ["a", "b"], "ratio": 1.5, "active": True }
  expect statusOk fine.status
  expect fine.body.saved == "hi"
}

api-test "a missing field is a 400" for DerivedServer {
  let bad = post "/save" body { "name": "n" }
  expect statusClientError bad.status
}

api-test "an unexpected field is a 400 too" for DerivedServer {
  let bad = post "/save" body { "name": "n", "token": "t", "inner": { "note": "hi", "count": 2 }, "tags": [], "ratio": 1.0, "active": True, "extra": "x" }
  expect statusClientError bad.status
}
|}

let test_derived_body_with_go () =
  let emitted = emit_ok "<go-derived-body>" derived_body_source in
  let module_go = artifact "internal/teslmodgoderivedbody/module.go" emitted in
  check bool "the derived decoder checks the object's shape first" true
    (contains module_go
       "teslrt.DecodeObjectShape(teslJSON, \"Outer\", []string{\"name\", \"token\", \"inner\", \"tags\", \"ratio\", \"active\"})");
  (* A secret field decodes its BASE value and is wrapped after — the same ordering the
     `via` case needs, for the same reason. *)
  check bool "a secret field is minted from the decoded string" true
    (contains module_go "return Token{Value: teslrt.MakeSecret(teslBase)}, nil");
  check bool "a nested record decodes through its own derived decoder" true
    (contains module_go "teslNested := DecodeInnerJSON(teslRaw)");
  check bool "and a list composes over its element's decoder" true
    (contains module_go "teslrt.DecodeListValue(teslRaw, teslrt.DecodeStringValue)");
  (* `go test` runs the api-tests: an extra key is a 400, which is the surprising half of the
     generic decoder's rule and the one worth pinning at runtime. *)
  gate_emitted "tesl-go-derived-body" emitted

(* An `auth` function takes a `teslrt.HttpRequest`, and the module declaring it need not be
   the one declaring the `server`.  The HTTP half of the runtime ships by REFERENCE for that
   reason: keyed on `server` declarations alone, this module compiled against a runtime file
   that was never shipped. *)
let auth_without_server_source = {|module GoAuthOnly exposing [cookieAuth]

import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]

fact Authenticated (user: String)

auth cookieAuth(request: HttpRequest) -> user: String ::: Authenticated user =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "not signed in"
    Something name -> ok name ::: Authenticated user
|}

let test_auth_without_server_ships_the_http_runtime () =
  let emitted = emit_ok "<go-auth-only>" auth_without_server_source in
  (* `artifact` fails the test when the path is absent, which is the assertion here. *)
  ignore (artifact "internal/teslrt/request.go" emitted);
  gate_emitted "tesl-go-auth-only" emitted;
  (* And the size argument still holds: a module that touches no HTTP does not pull net/http
     (and its vulnerability surface) into a pure-computation program. *)
  let pure = emit_ok "<go-pure>" recursion_source in
  check bool "a pure module ships no HTTP runtime" true
    (not (List.exists (fun (a : Emit_go.artifact) -> a.path = "internal/teslrt/request.go") pure))

(* A comprehension whose SOURCE is another comprehension: `List.filter f (List.map g xs)`.
   The source used to be spliced twice — evaluating the inner comprehension twice, squaring the
   work — at the OUTER indent, which gofmt then reflowed (a finding on emitted code), with both
   levels reusing the same `teslOut1` name. *)
let nested_comprehension_source = {|module GoNestedComprehension exposing [negatives, longWords]

import Tesl.Prelude exposing [Int, String, Bool, List]
import Tesl.List exposing [List.map, List.filter, List.length]
import Tesl.String exposing [String.length, String.concat]

fn negatives(xs: List Int) -> List Int =
  List.filter (fn(x: Int) -> x < 0) (List.map (fn(x: Int) -> 0 - x) xs)

fn longWords(words: List String) -> Int =
  List.length (List.filter (fn(w: String) -> String.length w > 3) (List.map (fn(w: String) -> String.concat w "!") words))

test "a nested comprehension answers what the source says" {
  expect negatives [1, 0 - 2, 3] == [0 - 1, 0 - 3]
  expect longWords ["a", "abc", "abcd"] == 2
}
|}

let test_nested_comprehension_with_go () =
  let emitted = emit_ok "<go-nested-comprehension>" nested_comprehension_source in
  let module_go = artifact "internal/teslmodgonestedcomprehension/module.go" emitted in
  check bool "the inner comprehension is bound to a name rather than spliced twice" true
    (contains module_go "teslSrc1 := (func() []teslrt.Int {");
  (* The nested level gets its OWN depth, so its loop variables cannot shadow the outer
     level's — both used to be `teslOut1`/`teslAt1`. *)
  check bool "and the nested level has its own loop names" true
    (contains module_go "teslOut2[teslAt2] =");
  (* The inner comprehension appears ONCE. Its `make` line is the marker: two copies meant two
     evaluations of the whole nested loop. *)
  let inner_copies =
    let rec count from total =
      match String.index_from_opt module_go from 'm' with
      | None -> total
      | Some at ->
        let candidate = "make([]teslrt.Int, len(xs))" in
        let matches =
          at + String.length candidate <= String.length module_go
          && String.sub module_go at (String.length candidate) = candidate
        in
        count (at + 1) (if matches then total + 1 else total)
    in
    count 0 0
  in
  check int "the inner comprehension is emitted once" 1 inner_copies;
  gate_emitted "tesl-go-nested-comprehension" emitted

(* ─── Outbound HTTP, and its test double ──────────────────────────────────────
   `Tesl.HttpClient` is the only stdlib module that reaches the network, so the emitted call
   carries protections a program cannot opt out of (a CR/LF header guard, SSRF containment by
   resolved address, verified TLS, deadlines, a response-body cap) — those are unit-tested in
   the runtime.  What is tested HERE is the language surface: the four verbs, the response
   record's fields, and the stub double that makes a handler which calls out testable at all.

   `HttpResponse` is also where the two backends' shapes could drift: the checker has ONE
   opaque type shared with `Tesl.ApiTest`, so a module importing both (lesson58 does) must get
   the outbound record for an annotation and the api-test record for a request verb. *)
let httpclient_source = {|module GoHttpClient exposing [fetchRates, isSuccess, headersOf]

import Tesl.Prelude exposing [Int, String, Bool(..), List]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.List exposing [List.head, List.length]
import Tesl.String exposing [String.contains]
import Tesl.Tuple exposing [Tuple2, Tuple2.first, Tuple2.second]
import Tesl.HttpClient exposing [
  httpClient,
  HttpResponse,
  HttpClient.get,
  HttpClient.post,
  HttpClient.put,
  HttpClient.delete,
]
import Tesl.ApiTest exposing [
  stubHttp,
  stubHttpFailure,
  stubHttpTimeout,
  httpCalled,
  httpCallCount,
  httpLastBody,
]

capability webClient implies httpClient

fn isSuccess(resp: HttpResponse) -> Bool =
  resp.status >= 200 && resp.status < 300

fn headersOf(resp: HttpResponse) -> List (Tuple2 String String) =
  resp.headers

fn firstHeaderName(headers: List (Tuple2 String String)) -> Maybe String =
  case List.head headers of
    Something h -> Something (Tuple2.first h)
    Nothing -> Nothing

fn fetchRates(url: String) -> HttpResponse
  requires [webClient] =
  HttpClient.get url [Tuple2 "Accept" "application/json"]

fn pushRates(url: String, payload: String) -> HttpResponse
  requires [webClient] =
  HttpClient.post url [] payload

fn replaceRates(url: String, payload: String) -> HttpResponse
  requires [webClient] =
  HttpClient.put url [] payload

fn dropRates(url: String) -> HttpResponse
  requires [webClient] =
  HttpClient.delete url []

test "a canned response answers without touching the network" requires [webClient] {
  stubHttp "GET" "https://rates.test/v1" 200 "{\"usd\": 110}"
  let r = fetchRates "https://rates.test/v1"
  expect r.status == 200
  expect r.body == "{\"usd\": 110}"
  expect isSuccess r == True
  expect String.contains r.body "usd"
  expect httpCalled "GET" "https://rates.test/v1"
  expect httpCallCount "GET" "https://rates.test/v1" == 1
}

test "the method is part of the match, and every verb dispatches" requires [webClient] {
  stubHttp "GET" "https://rates.test/v1" 200 "get"
  stubHttp "POST" "https://rates.test/v1" 201 "post"
  stubHttp "PUT" "https://rates.test/v1" 202 "put"
  stubHttp "DELETE" "https://rates.test/v1" 204 "delete"
  expect (fetchRates "https://rates.test/v1").body == "get"
  expect (pushRates "https://rates.test/v1" "p").body == "post"
  expect (replaceRates "https://rates.test/v1" "p").body == "put"
  expect (dropRates "https://rates.test/v1").status == 204
}

test "a trailing * matches a URL prefix and the first declared rule wins" requires [webClient] {
  stubHttp "GET" "https://rates.test/v1" 200 "specific"
  stubHttp "*" "https://rates.test/*" 500 "catch-all"
  expect (fetchRates "https://rates.test/v1").body == "specific"
  expect (fetchRates "https://rates.test/v2?since=1").status == 500
}

test "httpLastBody shows what was actually sent" requires [webClient] {
  stubHttp "POST" "https://rates.test/log" 202 "queued"
  let r = pushRates "https://rates.test/log" "{\"event\": \"sync\"}"
  expect r.status == 202
  expect httpLastBody "POST" "https://rates.test/log" == "{\"event\": \"sync\"}"
}

test "a refused connection and a timeout are both reachable" requires [webClient] {
  stubHttpFailure "GET" "https://rates.test/down" "connection refused"
  expectFail fetchRates "https://rates.test/down"
  stubHttpTimeout "GET" "https://rates.test/slow"
  expectFail fetchRates "https://rates.test/slow"
}

test "an unstubbed call fails loudly instead of reaching the network" requires [webClient] {
  stubHttp "GET" "https://rates.test/v1" 200 "ok"
  expectFail fetchRates "https://elsewhere.test/v1"
  expect httpCalled "GET" "https://elsewhere.test/v1"
}

test "neither a rule nor the call log leaks out of the previous block" requires [webClient] {
  expect httpCallCount "*" "*" == 0
  expect httpCalled "GET" "https://rates.test/v1" == False
  stubHttp "GET" "https://other.test/v1" 200 "ok"
  expectFail fetchRates "https://rates.test/v1"
}

test "response headers are a list of pairs" requires [webClient] {
  stubHttp "GET" "https://rates.test/v1" 200 "body"
  let r = fetchRates "https://rates.test/v1"
  expect List.length (headersOf r) == 0
  expect firstHeaderName (headersOf r) == Nothing
  expect firstHeaderName [Tuple2 "Content-Type" "application/json"] == Something "Content-Type"
  expect Tuple2.second (Tuple2 "a" "b") == "b"
}
|}

let test_httpclient_with_go () =
  let emitted = emit_ok "<go-httpclient>" httpclient_source in
  let module_go = artifact "internal/teslmodgohttpclient/module.go" emitted in
  check bool "a verb is one runtime call carrying the header list" true
    (contains module_go
       "teslrt.HttpGet(url, []teslrt.Tuple2[string, string]{teslrt.Tuple2[string, string]{Tuple2First: \"Accept\", Tuple2Second: \"application/json\"}})");
  check bool "the response record is the runtime's" true
    (contains module_go "func IsSuccess(resp teslrt.HttpResponse) bool");
  check bool "and its body is response TEXT, not a parsed value" true
    (contains module_go "func HeadersOf(resp teslrt.HttpResponse) []teslrt.Tuple2[string, string]");
  let tests_go = artifact "internal/teslmodgohttpclient/module_test.go" emitted in
  check bool "a stub declaration is a statement" true
    (contains tests_go
       "_ = teslrt.StubHttp(\"GET\", \"https://rates.test/v1\", teslrt.FromInt64(200), \"{\\\"usd\\\": 110}\")");
  check bool "and the call log is read back through the runtime" true
    (contains tests_go "teslrt.HttpCallCount(\"GET\", \"https://rates.test/v1\")");
  (* Isolation is not a property of the runtime alone: it needs the emitted per-test reset,
     because Go runs a package's tests in ONE process. *)
  check bool "every test block starts from a cleared stub table" true
    (contains tests_go "teslrt.ResetHttpStubs()");
  gate_emitted "tesl-go-httpclient" emitted

(* The secret-accepting header builders are the sanctioned sink for a `secret`: they exist so
   that `("Authorization", "Bearer " ++ key.value)` — which `secret` makes impossible — has a
   replacement.  Their Tesl type is `Tuple2 String String`, so the value half is a Go `string`
   and CANNOT be Racket's opaque wrapper; it is an unguessable handle naming the plaintext in a
   runtime table instead, unwrapped only on its way to the socket.  Same property, different
   mechanism — so the test asserts the property: the name is readable, the value is not the
   secret, and the call still goes out. *)
let secret_header_source = {|module GoSecretHeader exposing [callUpstream, callWithApiKey]

import Tesl.Prelude exposing [Int, String, Bool(..), List]
import Tesl.Tuple exposing [Tuple2, Tuple2.first, Tuple2.second]
import Tesl.HttpClient exposing [
  httpClient,
  HttpResponse,
  HttpClient.get,
  HttpClient.bearer,
  HttpClient.secretHeader,
]
import Tesl.ApiTest exposing [stubHttp, httpCallCount]

capability webClient implies httpClient

secret ApiKey = String

fn callUpstream(url: String, key: ApiKey) -> HttpResponse
  requires [webClient] =
  HttpClient.get url [HttpClient.bearer key]

fn callWithApiKey(url: String, key: ApiKey) -> HttpResponse
  requires [webClient] =
  HttpClient.get url [HttpClient.secretHeader "X-Api-Key" key]

test "a bearer header carries a secret to the upstream" requires [webClient] {
  stubHttp "GET" "https://api.test/me" 200 "{\"id\": \"u-1\"}"
  let r = callUpstream "https://api.test/me" (ApiKey "sk-live-123")
  expect r.status == 200
  expect httpCallCount "GET" "https://api.test/me" == 1
}

test "a named secret header does too" requires [webClient] {
  stubHttp "GET" "https://api.test/me" 200 "ok"
  let r = callWithApiKey "https://api.test/me" (ApiKey "sk-live-123")
  expect r.body == "ok"
}

test "the header NAME is readable, and the value is not the secret" requires [webClient] {
  let header = HttpClient.bearer (ApiKey "sk-live-123")
  expect Tuple2.first header == "Authorization"
  expect (Tuple2.second header == "sk-live-123") == False
}
|}

let test_secret_header_with_go () =
  let emitted = emit_ok "<go-secret-header>" secret_header_source in
  let module_go = artifact "internal/teslmodgosecretheader/module.go" emitted in
  (* The unwrapping is at the ARGUMENT: every `secret` newtype is a distinct Go type, so the
     builder takes the payload rather than the wrapper. *)
  check bool "a secret newtype hands over its payload at the sink" true
    (contains module_go "teslrt.HttpBearer(key.Value)");
  check bool "and a named header does the same" true
    (contains module_go "teslrt.HttpSecretHeader(\"X-Api-Key\", key.Value)");
  gate_emitted "tesl-go-secret-header" emitted

(* A hung upstream INSIDE A WORKER is the case the deadline exists for: without one the job
   never fails, so retry and dead-lettering never run.  Stubbing the timeout makes that
   deterministic, and `deadJobs` is how a test sees where the job ended up.

   This module imports `Tesl.HttpClient` and `Tesl.ApiTest` together — the shape that made the
   shared `HttpResponse` name ambiguous — so an annotation resolving to the outbound record and
   a request verb resolving to the api-test one are both exercised here. *)
let http_worker_source = {|module GoHttpWorker exposing [SyncServer]

import Tesl.Prelude exposing [Int, String, Bool(..), List]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.List exposing [List.length]
import Tesl.Json exposing [stringCodec]
import Tesl.Database exposing [Database, Memory]
import Tesl.Queue exposing [
  FromQueue,
  deadJobs,
  queueRead,
  queueWrite,
  Queue,
  Job,
  QueueRetryStrategy,
  Fixed,
]
import Tesl.HttpClient exposing [httpClient, HttpResponse, HttpClient.get]
import Tesl.ApiTest exposing [
  statusOk,
  JobResult(..),
  processNextJob,
  pendingJobCount,
  expectJobFailed,
  stubHttp,
  stubHttpTimeout,
  httpCallCount,
]

capability webClient implies httpClient

database SyncDb = Database {
  schema: "gohttpworker"
  entities: []
  backend: Memory
}

fn fetchUpstream(url: String) -> HttpResponse
  requires [webClient] =
  HttpClient.get url []

record SyncJob {
  tag: String
}

queue SyncQueue requires [queueRead, webClient] = Queue {
  database: SyncDb
  jobs: [Job SyncJob syncWorker Nothing]
  retry: QueueRetryStrategy {
    maxAttempts: 2
    backoff: Fixed
    initialDelay: 1
  }
}

worker syncWorker(job: SyncJob ::: FromQueue (Id == jobId) job)
  requires [queueRead, webClient] =
  let _resp = fetchUpstream "https://upstream.test/sync"
  job

record SyncRequest {
  tag: String
}

codec SyncRequest {
  toJson {
    tag -> "tag" with_codec stringCodec
  }
  fromJson [
    {
      tag <- "tag" with_codec stringCodec
    }
  ]
}

handler post startSync(req: SyncRequest) -> String
  requires [queueWrite] =
  enqueue SyncJob { tag: req.tag }
  "queued"

api SyncApi {
  post "/sync"
    body req: SyncRequest
    -> String
}

server SyncServer for SyncApi {
  startSync
}

api-test "an upstream timeout fails the job, then dead-letters it" for SyncServer requires [queueRead, queueWrite, webClient] {
  stubHttpTimeout "GET" "https://upstream.test/sync"

  let queued = post "/sync" body { "tag": "nightly" }
  expect statusOk queued.status
  expect pendingJobCount SyncQueue == 1

  let first = processNextJob SyncQueue
  let firstJob = expectJobFailed first
  expect pendingJobCount SyncQueue == 1

  let second = processNextJob SyncQueue
  let secondJob = expectJobFailed second
  expect pendingJobCount SyncQueue == 0
  expect List.length (deadJobs SyncQueue) == 1

  expect httpCallCount "GET" "https://upstream.test/sync" == 2
}

api-test "the same worker succeeds when the upstream answers" for SyncServer requires [queueRead, queueWrite, webClient] {
  stubHttp "GET" "https://upstream.test/sync" 200 "ok"

  let queued = post "/sync" body { "tag": "nightly" }
  expect statusOk queued.status

  let done = processNextJob SyncQueue
  expect pendingJobCount SyncQueue == 0
  expect List.length (deadJobs SyncQueue) == 0
  expect httpCallCount "GET" "https://upstream.test/sync" == 1
}
|}

let test_http_worker_with_go () =
  let emitted = emit_ok "<go-http-worker>" http_worker_source in
  let module_go = artifact "internal/teslmodgohttpworker/module.go" emitted in
  check bool "the worker's outbound call is an ordinary emitted call" true
    (contains module_go "teslrt.HttpGet(url, []teslrt.Tuple2[string, string]{})");
  let tests_go = artifact "internal/teslmodgohttpworker/module_test.go" emitted in
  check bool "the dead letter is read through the runtime" true
    (contains tests_go "teslrt.DeadJobs(SyncQueueQueue)");
  (* The SECOND api-test asserts an EMPTY dead letter, which only holds because the queue is
     reset per block: Racket gets that from `call-with-fresh-memory-db` wrapping every test
     body, and Go needs it emitted. *)
  check bool "the queue is emptied before each block" true
    (contains tests_go "teslrt.ResetQueue(SyncQueueQueue)");
  gate_emitted "tesl-go-http-worker" emitted

(* ─── Combined checks, and `case` as a test statement ─────────────────────────
   `check (checkA && checkB) x` runs each in turn and short-circuits on the first
   rejection — Racket's `check-and`, with the fact merge dropped because facts erase.  A
   `case` inside a test block discriminates through the same emitter as an expression
   `case`; only the arm bodies differ (statements rather than a value). *)
let combined_check_source = {|module GoCombinedCheck exposing [tidy]

import Tesl.Prelude exposing [Int, String]
import Tesl.String exposing [String.isEmpty, String.contains]

fact NonEmpty(s: String)
fact HasAt(s: String)

check checkNonEmpty(s: String) -> s: String ::: NonEmpty s =
  if String.isEmpty s then
    fail 400 "must not be empty"
  else
    ok s ::: NonEmpty s

check checkHasAt(s: String) -> s: String ::: HasAt s =
  if String.contains s "@" then
    ok s ::: HasAt s
  else
    fail 400 "must contain @"

# The combined check runs both in order and short-circuits on the first rejection.
fn tidy(raw: String) -> String =
  let email = check (checkHasAt && checkNonEmpty) raw
  "ok:${email}"

test "a combined check accepts a value both halves accept" {
  expect tidy "a@b" == "ok:a@b"
}

test "a combined check rejects when the FIRST half rejects" {
  expectFail tidy "no-at-sign"
}

test "a combined check rejects when the SECOND half rejects" {
  expectFail tidy ""
}
|}

let test_case_stmt_source = {|module GoTestCase exposing [pick]

import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.List exposing [List.head]

fn pick(wanted: Int) -> Maybe Int =
  case List.head [wanted] of
    Nothing -> Nothing
    Something first -> Something first

# `case` as a TEST statement: each arm carries statements, not a value.
test "case in a test block discriminates and binds" {
  case pick 7 of
    Nothing -> expect False == True
    Something value -> expect value == 7
}

test "the other arm is reachable too" {
  case pick 0 of
    Something value -> expect value == 0
    Nothing -> expect False == True
}
|}

let test_combined_check_with_go () =
  let emitted = emit_ok "<go-combined-check>" combined_check_source in
  let module_go = artifact "internal/teslmodgocombinedcheck/module.go" emitted in
  check bool "the conjuncts are hoisted into one helper" true
    (contains module_go "func teslCheckAll1(teslValue string) teslrt.Check[string] {");
  check bool "the first rejection short-circuits" true
    (contains module_go "return teslrt.Reject[string](teslStep0.Status(), teslStep0.Message())");
  check bool "and the checked value feeds the next conjunct" true
    (contains module_go "teslStep1 := checkNonEmpty(teslrt.MustCheck(teslStep0))");
  (* `go test` RUNS all three cases: both halves accepting, and each half rejecting. *)
  gate_emitted "tesl-go-combined-check" emitted

let test_case_statement_with_go () =
  let emitted = emit_ok "<go-test-case>" test_case_stmt_source in
  let tests_go = artifact "internal/teslmodgotestcase/module_test.go" emitted in
  check bool "a test-block case switches on the ADT tag" true
    (contains tests_go "switch teslScrut1.Tag {");
  check bool "and binds the arm's payload for its statements" true
    (contains tests_go "value := teslScrut1.SomethingValue");
  gate_emitted "tesl-go-test-case" emitted


(* ─── Function values and lambdas ─────────────────────────────────────────────
   `f: Int -> Int` as a parameter, a lambda passed to it, and a NAMED function passed as a
   value — all three are the same Go shape (`func(teslrt.Int) teslrt.Int`).  The arrow's
   capability row is compile-time and does not survive. *)
let function_value_source = {|module GoFuncValue exposing [applyTwice, addTen, shout]

import Tesl.Prelude exposing [Int, String, List]
import Tesl.List exposing [List.map]

# A function VALUE as a parameter.
fn applyTwice(f: Int -> Int, n: Int) -> Int =
  f (f n)

fn addOne(n: Int) -> Int =
  n + 1

# A lambda passed to a user function that takes a function value.
fn addTen(n: Int) -> Int =
  applyTwice (fn(x: Int) -> x + 5) n

# A NAMED function passed as a value.
fn twiceNamed(n: Int) -> Int =
  applyTwice addOne n

# A lambda into a higher-order list leaf still works.
fn shout(xs: List Int) -> List Int =
  List.map (fn(x: Int) -> x * 2) xs

test "function values, lambdas and named functions" {
  expect addTen 0 == 10
  expect twiceNamed 5 == 7
  expect applyTwice (fn(x: Int) -> x * 3) 2 == 18
  expect shout [1, 2] == [2, 4]
}
|}

let test_function_values_with_go () =
  let emitted = emit_ok "<go-func-value>" function_value_source in
  let module_go = artifact "internal/teslmodgofuncvalue/module.go" emitted in
  check bool "a function parameter is a Go func type" true
    (contains module_go
       "func ApplyTwice(f func(teslrt.Int) teslrt.Int, n teslrt.Int) teslrt.Int {");
  check bool "a call through it is an ordinary call" true
    (contains module_go "return f(f(n))");
  check bool "a lambda is a func literal" true
    (contains module_go "func(x teslrt.Int) teslrt.Int {");
  check bool "and a named function passed as a value is its own name" true
    (contains module_go "ApplyTwice(addOne, n)");
  gate_emitted "tesl-go-func-value" emitted


(* ─── Secret newtypes ─────────────────────────────────────────────────────────
   A `secret` newtype's payload is a `teslrt.SecretString`: it prints as "[redacted]"
   through every fmt verb (and through JSON), and equality on it is CONSTANT TIME.  Both
   halves matter — a secret that leaked through a log line or through how long a comparison
   took would be a secret in name only. *)
let secret_source = {|module GoSecret exposing [matches, stored]

import Tesl.Prelude exposing [Bool(..), String]

# A `secret` newtype: distinct from String, and its payload must never print.
secret Password = String

record Credential {
  user: String
  password: Password
}

fn matches(left: Password, right: Password) -> Bool =
  left == right

fn stored(user: String, raw: String) -> Credential =
  Credential { user: user, password: Password raw }

test "secrets compare by value and travel inside records" {
  expect matches (Password "hunter2") (Password "hunter2") == True
  expect matches (Password "hunter2") (Password "hunter3") == False
  expect (stored "ada" "hunter2").user == "ada"
  expect matches (stored "ada" "hunter2").password (Password "hunter2") == True
}
|}

let test_secret_newtype_with_go () =
  let emitted = emit_ok "<go-secret>" secret_source in
  let module_go = artifact "internal/teslmodgosecret/module.go" emitted in
  check bool "a secret's payload is the redacting carrier" true
    (contains module_go "type Password struct {\n\tValue teslrt.SecretString\n}");
  check bool "and the type itself redacts when printed" true
    (contains module_go
       "func (teslSecret Password) String() string { return teslrt.SecretRedaction }");
  check bool "the plaintext enters through MakeSecret" true
    (contains module_go "Password{Value: teslrt.MakeSecret(raw)}");
  check bool "equality is constant time, never ==" true
    (contains module_go "teslrt.SecretEqual(left.Value, right.Value)");
  check bool "a secret is never compared with Go ==" false
    (contains module_go "left.Value == right.Value");
  gate_emitted "tesl-go-secret" emitted

let test_secret_over_non_string_fails_closed () =
  let unsupported = {|module SecretInt exposing [wrap]
import Tesl.Prelude exposing [Int]
secret Token = Int
fn wrap(n: Int) -> Token = Token n
|} in
  match Compile.compile_go_source "<go-secret-int>" unsupported with
  | Compile.GoSuccess _ -> fail "a secret over Int emitted Go artifacts"
  | Compile.GoFailure diagnostics ->
    check bool "only a String-backed secret has a carrier today" true
      (List.exists (fun (d : Compile.diagnostic) ->
         d.source = "go-emitter" && contains d.message "`secret` newtype over String only")
         diagnostics)


(* ─── The api-test surface is UNTYPED, as it is on Racket ──────────────────────
   Inside an `api-test` block a response body is inspected without types: `r.body.userId`
   is a dynamic read, a missing key is NULL rather than an error, and every assertion reads
   like the JSON it checks.  That ergonomics is deliberate — the checker types the body as a
   fresh variable — so the emitter carries a dynamic value rather than inventing a typed
   view.  `resp.body` is therefore the PARSED body, matching
   `api-test-field-access-ref`; a raw string would have turned every assertion into a
   string-compare against serialised JSON. *)
let api_json_source = {|module GoApiJson exposing [JsonServer]

import Tesl.Prelude exposing [Bool(..), Int, String, List]
import Tesl.Json exposing [stringCodec, intCodec]
import Tesl.ApiTest exposing [
  statusOk,
  isNull,
  isNotNull,
  isEmpty,
  isNotEmpty,
  hasField,
  hasLength,
  jsonInt,
  jsonString,
  jsonLength,
  arrayAt,
  fieldAt,
  bodyField,
  jsonContains,
]

record Reply {
  userId: String
  count: Int
}

codec Reply {
  toJson {
    userId -> "userId" with_codec stringCodec
    count -> "count" with_codec intCodec
  }
  fromJson_forbidden
}

handler get show() -> Reply =
  Reply { userId: "user-1", count: 3 }

api JsonApi {
  get "/show"
    -> Reply
}

server JsonServer for JsonApi {
  show
}

# Every assertion here reads the body WITHOUT types, exactly as it does on Racket.
api-test "a response body is inspected without types" for JsonServer requires [] {
  let r = get "/show"
  expect statusOk r.status

  expect r.body.userId == "user-1"
  expect r.body.count == 3
  expect isNull r.body.missing
  expect isNotNull r.body.userId
  expect hasField "userId" r.body
  expect jsonString r.body.userId == "user-1"
  expect jsonInt r.body.count == 3
  expect jsonLength r.body == 2
  expect hasLength 2 r.body
  expect isNotEmpty r.body
  expect fieldAt "userId" r.body == "user-1"
  expect bodyField "count" r == 3
  expect jsonContains "user" r.body.userId
}
|}

let test_api_test_json_with_go () =
  let emitted = emit_ok "<go-api-json>" api_json_source in
  let tests_go = artifact "internal/teslmodgoapijson/module_test.go" emitted in
  check bool "a body field read is dynamic" true
    (contains tests_go "teslrt.JsonFieldOf(r.Body, \"userId\")");
  check bool "and comparing it to a Tesl value is structural" true
    (contains tests_go
       "teslrt.JsonEqual(teslrt.JsonFieldOf(r.Body, \"count\"), teslrt.FromInt64(3))");
  check bool "a missing key is null, not an error" true
    (contains tests_go "teslrt.JsonIsNull(teslrt.JsonFieldOf(r.Body, \"missing\"))");
  check bool "the predicates keep Tesl's argument order" true
    (contains tests_go "teslrt.JsonHasField(\"userId\", r.Body)");
  check bool "hasLength takes the length first" true
    (contains tests_go "teslrt.JsonHasLength(teslrt.FromInt64(2), r.Body)");
  check bool "bodyField reads the response's own body" true
    (contains tests_go "teslrt.JsonFieldAt(\"count\", r.Body)");
  (* `go test` RUNS the api-test, so every assertion above is checked against a real
     response. *)
  gate_emitted "tesl-go-api-json" emitted

(* The transcendentals used to fail closed here: Go's sin/cos/tan disagree with Racket on
   22-34% of inputs and its math.Log is outright wrong for subnormals. They are SUPPORTED
   now — the maintainer's recorded call (2026-08-12) is that a divergence of up to an ulp on
   the transcendentals is acceptable, and `Float.log` no longer diverges at all (the runtime
   scales a subnormal into the normal range rather than forwarding to math.Log). What they
   emit and what they answer is pinned where the feature lives ("a plain-value check tail,
   and the Float transcendentals"), so this file no longer states the refusal. *)

let set_source = {|module GoSets exposing [build, has, size, without, both, common, only, subset, listed, sameSet, emptyOf]
import Tesl.Prelude exposing [Bool(..), Int, List, String]
import Tesl.Set exposing [Set, Set.empty, Set.singleton, Set.member, Set.insert, Set.remove, Set.size, Set.isEmpty, Set.toList, Set.fromList, Set.union, Set.intersection, Set.difference, Set.isSubset]
import Tesl.List exposing [List.length, List.member]

fn build(s: Set String, value: String) -> Set String = Set.insert value s

fn has(s: Set String, value: String) -> Bool = Set.member value s

fn size(s: Set String) -> Int = Set.size s

fn without(s: Set String, value: String) -> Set String = Set.remove value s

fn both(left: Set String, right: Set String) -> Set String = Set.union left right

fn common(left: Set String, right: Set String) -> Set String = Set.intersection left right

fn only(left: Set String, right: Set String) -> Set String = Set.difference left right

fn subset(left: Set String, right: Set String) -> Bool = Set.isSubset left right

fn listed(s: Set String) -> List String = Set.toList s

fn sameSet(left: Set String, right: Set String) -> Bool = left == right

fn emptyOf() -> Set String = Set.empty

test "Tesl.Set leaves" {
  let base = Set.fromList ["b", "a", "b"]
  expect size base == 2
  expect has base "a" == True
  expect has base "zz" == False
  expect size (build base "c") == 3
  expect size (build base "a") == 2
  expect size (without base "a") == 1
  expect size (both base (Set.singleton "c")) == 3
  expect size (common base (Set.fromList ["a"])) == 1
  expect size (only base (Set.fromList ["a"])) == 1
  expect subset (Set.fromList ["a"]) base == True
  expect subset (Set.fromList ["zz"]) base == False
  # Set element order is UNSPECIFIED in Tesl (Racket iterates a hash), so only
  # membership and size may be observed.
  expect List.length (listed base) == 2
  expect List.member "a" (listed base) == True
  expect sameSet base (Set.fromList ["a", "b"]) == True
  expect sameSet base (Set.fromList ["a"]) == False
  expect Set.isEmpty (emptyOf()) == True
  expect Set.size (emptyOf()) == 0
}
|}

(* Set is Dict's sibling: elements kept sorted, for the same two reasons (a Go map
   cannot be keyed by the non-comparable teslrt.Int, and Go randomises map order per
   run).  Sorted storage is also what lets union/intersection/difference be one ordered
   pass instead of n lookups. *)
let test_sets_with_go () =
  let emitted = match Compile.compile_go_source "<go-sets>" set_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "Set compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgosets/module.go" emitted in
  check bool "the runtime Set ships with the project" true
    (List.exists (fun (a : Emit_go.artifact) -> a.path = "internal/teslrt/set.go") emitted);
  check bool "Set renders with its element type" true
    (contains module_go "func Build(s teslrt.Set[string], value string) teslrt.Set[string]");
  check bool "a membership leaf carries the element ordering" true
    (contains module_go
       "teslrt.SetInsert(value, s, teslKeyLessString)");
  check bool "the algebra keeps its Tesl argument order" true
    (contains module_go "teslrt.SetUnion(left, right, teslKeyLessString)");
  (* `Set.empty` takes no arguments, so it parses as a bare field access over the module
     name and its type parameter has to be written out. *)
  check bool "Set.empty is instantiated from the expected type" true
    (contains module_go "return teslrt.SetEmpty[string]()");
  check bool "set equality is one ordered pass" true
    (contains module_go "teslrt.SetEqualBy(left, right, teslEqualString)");
  if Sys.command "go version >/dev/null 2>&1" = 0 then
    let root = Filename.temp_dir "tesl-go-sets" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted Set source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)

(* A multi-module program emits ONE Go package per Tesl module, all under a single Go
   module path so an importer and its dependency agree on the import path.  A reference
   to a name another module owns is qualified with that package; a reference to one's own
   is bare, since Go forbids self-qualification. *)
let test_multi_module_with_go () =
  let path = Filename.concat (Compile.default_root_path ())
    "example/learn/lesson07-consumer.tesl" in
  let emitted = match Compile.compile_go_file path with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "multi-module compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let paths = List.map (fun (a : Emit_go.artifact) -> a.path) emitted in
  List.iter (fun path -> check bool ("emits " ^ path) true (List.mem path paths)) [
    "go.mod";
    "internal/teslmodlesson07consumer/module.go";
    "internal/teslmodlesson07home/module.go";
    "internal/teslrt/int.go";
  ];
  (* Shared artifacts are emitted once, not once per module. *)
  check bool "go.mod is emitted exactly once" true
    (List.length (List.filter (fun p -> p = "go.mod") paths) = 1);
  let consumer = artifact "internal/teslmodlesson07consumer/module.go" emitted in
  check bool "the dependency's package is imported" true
    (contains consumer
       "\"tesl.generated/teslmodlesson07consumer/internal/teslmodlesson07home\"");
  check bool "a call into the dependency is qualified" true
    (contains consumer "teslmodlesson07home.CheckInBounds(rawN)"
     && contains consumer "teslmodlesson07home.Sanitize(rawLabel)");
  check bool "a call within the module stays unqualified" true
    (contains consumer "return ProcessInput(validN, validLabel)");
  (* Imported facts erase entirely — the proofs they carry are compile-time only.
     `Sanitized` is the witness rather than `InBounds`, because the latter is a
     substring of the check function `CheckInBounds` and so cannot distinguish a leaked
     fact from a legitimate call. *)
  check bool "imported facts leave no runtime trace" false (contains consumer "Sanitized");
  if Sys.command "go version >/dev/null 2>&1" = 0 then
    let root = Filename.temp_dir "tesl-go-multi" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted multi-module source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
       ignore (run_command root "go test -race -count=1 ./...");
       run_go_gates root);
  let debug_emitted = match Compile.compile_go_file ~debug:true path with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "debug multi-module compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  gate_emitted ~short:true "tesl-go-debug-multi" debug_emitted

let cross_module_dep_source = {|module GoDep exposing [Point, Status(..), Slug, origin, shift, describe, tagOf]
import Tesl.Prelude exposing [Int, String]

type Slug = String

record Point {
  x: Int
  y: Int
}

type Status
  = Open
  | Closed (reason: String)

fn origin() -> Point = Point { x: 0, y: 0 }

fn shift(p: Point, dx: Int) -> Point = { p | x = p.x + dx }

fn describe(s: Status) -> String =
  case s of
    Open -> "open"
    Closed reason -> "closed: ${reason}"

fn tagOf(slug: Slug) -> String = slug.value
|}

let cross_module_user_source = {|module GoUser exposing [start, moved, sameSpot, report, label]
import Tesl.Prelude exposing [Bool, Int, String]
import GoDep exposing [Point, Status(..), Slug, origin, shift, describe, tagOf]

fn start() -> Point = origin()

fn moved(dx: Int) -> Point = shift (origin()) dx

fn sameSpot(left: Point, right: Point) -> Bool = left == right

fn report(s: Status) -> String = describe s

fn label(raw: String) -> String = tagOf (Slug raw)

test "cross-module types" {
  expect (start()).x == 0
  expect (moved 3).x == 3
  expect sameSpot (start()) (origin()) == True
  expect sameSpot (start()) (moved 1) == False
  expect report Open == "open"
  expect report (Closed "eod") == "closed: eod"
  expect label "abc" == "abc"
}
|}

(* A TYPE crossing a module boundary is the same type on both sides because the importer
   reuses the very info record its dependency emitted from — modules are compiled
   dependency-first for exactly this reason.  Re-deriving would produce a record that
   compares unequal to the original (`go_type` equality is structural), so a value
   crossing the boundary would look like a different type. *)
let test_cross_module_types_with_go () =
  let root = Filename.temp_dir "tesl-go-crossmodule" "" in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
    let write name contents =
      let path = Filename.concat root name in
      Out_channel.with_open_bin path (fun channel -> output_string channel contents);
      path
    in
    ignore (write "go-dep.tesl" cross_module_dep_source);
    let user = write "go-user.tesl" cross_module_user_source in
    let emitted = match Compile.compile_go_file user with
      | Compile.GoSuccess artifacts -> artifacts
      | Compile.GoFailure diagnostics ->
        failf "cross-module compilation failed: %s"
          (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
    in
    let consumer = artifact "internal/teslmodgouser/module.go" emitted in
    let dependency = artifact "internal/teslmodgodep/module.go" emitted in
    check bool "a record type is qualified at the use site" true
      (contains consumer "func Moved(dx teslrt.Int) teslmodgodep.Point");
    check bool "only the declaring package emits the declaration" true
      (contains dependency "type Point struct {" && not (contains consumer "type Point struct {"));
    check bool "a foreign record's fields are read directly" true
      (contains consumer "(teslrt.Equal(left.X, right.X) && teslrt.Equal(left.Y, right.Y))");
    (* A newtype's wrapper field is exported for the same reason the ADT tag is: it is
       constructed from another package. *)
    check bool "a foreign newtype is constructed with an exported field" true
      (contains consumer "teslmodgodep.Slug{Value: raw}");
    check bool "a foreign ADT is matched on its qualified tag" true
      (contains dependency "StatusOpen");
    if Sys.command "go version >/dev/null 2>&1" = 0 then begin
      let out = Filename.concat root "emitted" in
      write_artifacts out emitted;
      let unformatted = run_command out "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted cross-module source is not gofmt-clean (%s):\n%s"
          unformatted (run_command out "gofmt -d .");
      ignore (run_command out "go test -count=1 ./...");
      ignore (run_command out "go vet ./...");
      ignore (run_command out "go test -race -count=1 ./...");
      run_go_gates out
    end)

(* ── Import cycles ────────────────────────────────────────────────────────────
   A cyclic SCC collapses into ONE Go package.  Racket cannot express a cyclic
   `require`, so its backend inlines the members into one module; Go files in the same
   package reference each other with no ordering and no forward declarations, so the
   cycle needs no inlining at all — just a shared package.  compile.ml does the
   collapsing, which is why nothing in emit_go.ml knows what a cycle is. *)
let cycle_facts_source = {|module CycFacts exposing [Positive, checkPositive, checkedArea, tagOf, sizeOf, describe, deepB]
import Tesl.Prelude exposing [Int, String]
import CycShapes exposing [Point, Shape(..), Slug, origin, area, deepA]

fact Positive (n: Int)

check checkPositive(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "must be positive"

# A foreign record's field read, from the other member of the cycle.
fn sizeOf(p: Point) -> Int = p.x + p.y

# A foreign ADT, matched here.
fn describe(s: Shape) -> String =
  case s of
    Dot -> "dot"
    Box w -> "box ${w}"

# A foreign newtype, unwrapped here.
fn tagOf(slug: Slug) -> String = slug.value

# Establishes the proof HERE and calls the consumer over there.
fn checkedArea(w: Int, h: Int) -> Int =
  if w > 0 then
    let checkedWidth = check checkPositive w
    area checkedWidth h
  else
    0

# Mutual recursion across the cycle.
fn deepB(n: Int) -> Int =
  if n <= 0 then
    1
  else
    deepA (n - 1)

test "cycle: facts side" {
  expect sizeOf (origin()) == 0
  expect describe Dot == "dot"
  expect describe (Box 4) == "box 4"
  expect tagOf (Slug "abc") == "abc"
  expect checkedArea 3 4 == 12
  expect checkedArea 0 4 == 0
  expect deepB 6 == 1
}
|}

let cycle_shapes_source = {|module CycShapes exposing [Point, Shape(..), Slug, origin, area, deepA, report]
import Tesl.Prelude exposing [Int, String]
import CycFacts exposing [Positive, checkPositive, sizeOf, describe, deepB]

record Point {
  x: Int
  y: Int
}

type Shape
  = Dot
  | Box (w: Int)

type Slug = String

fn origin() -> Point = Point { x: 0, y: 0 }

# Consumes a fact declared in the OTHER member of the cycle.
fn area(w: Int ::: Positive w, h: Int) -> Int = w * h

# Calls a function that reads a type declared here.
fn report(p: Point) -> String = "size=${sizeOf p} shape=${describe Dot}"

fn deepA(n: Int) -> Int =
  if n <= 0 then
    0
  else
    deepB (n - 1)

test "cycle: shapes side" {
  let five = 5
  let checkedFive = check checkPositive five
  expect area checkedFive 2 == 10
  expect report (Point { x: 1, y: 2 }) == "size=3 shape=dot"
  expect deepA 7 == 1
}
|}

(* The case that matters most: each member imports from the other a DIFFERENT KIND of
   declaration — CycFacts imports a type, a record, an ADT and a newtype from CycShapes,
   while CycShapes imports a FACT (and its check) back from CycFacts.  Merging is
   kind-agnostic precisely because everything lands in one namespace. *)
let test_import_cycle_with_go () =
  let root = Filename.temp_dir "tesl-go-cycle" "" in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
    let write name contents =
      let path = Filename.concat root name in
      Out_channel.with_open_bin path (fun channel -> output_string channel contents);
      path
    in
    let facts = write "cyc-facts.tesl" cycle_facts_source in
    let shapes = write "cyc-shapes.tesl" cycle_shapes_source in
    (* Either member may be the entry, and both must produce the same single package. *)
    List.iter (fun (label, entry) ->
      let emitted = match Compile.compile_go_file entry with
        | Compile.GoSuccess artifacts -> artifacts
        | Compile.GoFailure diagnostics ->
          failf "cyclic compilation failed (entry %s): %s" label
            (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
      in
      (* Named after the alphabetically-first member, so the package is stable no matter
         which member the compile started from. *)
      let merged = artifact "internal/teslmodcycfacts/module.go" emitted in
      check bool (label ^ ": one package holds both members") true
        (contains merged "func SizeOf(" && contains merged "func Area(");
      check bool (label ^ ": no second package is emitted for the other member") true
        (not (List.exists (fun (a : Emit_go.artifact) ->
           a.path = "internal/teslmodcycshapes/module.go") emitted));
      (* Same package, so a cross-member reference needs no qualification at all. *)
      check bool (label ^ ": a cross-member call is unqualified") true
        (contains merged "return Mul(" || contains merged "teslrt.Mul(w, h)");
      check bool (label ^ ": the foreign record's type is unqualified") true
        (contains merged "func SizeOf(p Point) teslrt.Int");
      (* Each declaration keeps its OWN source file, so a merged file still maps every
         declaration back to the .tesl it was written in. *)
      check bool (label ^ ": both source files appear in //line directives") true
        (contains merged "//line cyc-facts.tesl" && contains merged "//line cyc-shapes.tesl");
      (* The fact crossing the boundary erases, like every other proof. *)
      check bool (label ^ ": the imported fact leaves no runtime trace") true
        (contains merged "func Area(w teslrt.Int, h teslrt.Int) teslrt.Int");
      let tests_file = artifact "internal/teslmodcycfacts/module_test.go" emitted in
      check bool (label ^ ": both members' test blocks survive the merge") true
        (contains tests_file "TestTesl0" && contains tests_file "TestTesl1");
      if Sys.command "go version >/dev/null 2>&1" = 0 then begin
        let out = Filename.concat root ("emitted-" ^ label) in
        write_artifacts out emitted;
        let unformatted = run_command out "gofmt -l ." |> String.trim in
        if unformatted <> "" then
          failf "emitted cyclic source is not gofmt-clean (%s):\n%s"
            unformatted (run_command out "gofmt -d .");
        ignore (run_command out "go test -count=1 ./...");
        ignore (run_command out "go vet ./...");
        ignore (run_command out "go test -race -count=1 ./...");
        run_go_gates out
      end) ["facts", facts; "shapes", shapes])

let cycle_leaf_source = {|module Leaf exposing [double, triple]
import Tesl.Prelude exposing [Int]

fn double(n: Int) -> Int = n * 2

fn triple(n: Int) -> Int = n * 3
|}

let cycle_tri_a_source = {|module TriA exposing [AType, fromA, deepA]
import Tesl.Prelude exposing [Int, String]
import TriB exposing [fromB, deepB]

record AType {
  label: String
}

fn fromA(n: Int) -> Int = fromB n + 1

fn deepA(n: Int) -> Int =
  if n <= 0 then
    0
  else
    deepB (n - 1)
|}

let cycle_tri_b_source = {|module TriB exposing [fromB, deepB]
import Tesl.Prelude exposing [Int]
import TriC exposing [fromC, deepC]
import Leaf exposing [double]

fn fromB(n: Int) -> Int = double (fromC n)

fn deepB(n: Int) -> Int =
  if n <= 0 then
    1
  else
    deepC (n - 1)
|}

let cycle_tri_c_source = {|module TriC exposing [fromC, deepC, describeA]
import Tesl.Prelude exposing [Int, String]
import TriA exposing [AType, deepA]
import Leaf exposing [triple]

fn fromC(n: Int) -> Int = triple n + 10

fn describeA(a: AType) -> String = "label=${a.label}"

fn deepC(n: Int) -> Int =
  if n <= 0 then
    2
  else
    deepA (n - 1)
|}

let cycle_top_source = {|module Top exposing [total, viaC, named]
import Tesl.Prelude exposing [Int, String]
import TriA exposing [AType, fromA]
import TriC exposing [fromC, describeA]
import Leaf exposing [double]

fn total(n: Int) -> Int = fromA n + double n

fn viaC(n: Int) -> Int = fromC n

fn named(label: String) -> String = describeA (AType { label: label })

test "cycle seen from outside" {
  expect viaC 5 == 25
  expect total 1 == 29
  expect named "x" == "label=x"
}
|}

(* Three members, an acyclic module hanging off the cycle, and an entry OUTSIDE it that
   imports names declared in two DIFFERENT members.  The outside importer is the reason
   compile.ml rewrites import targets: it writes `import TriC exposing [fromC]`, but the
   merged package answers to one name only, so a reference to a collapsed member would
   otherwise resolve to nothing. *)
let test_import_cycle_three_modules_with_go () =
  let root = Filename.temp_dir "tesl-go-cycle3" "" in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
    let write name contents =
      let path = Filename.concat root name in
      Out_channel.with_open_bin path (fun channel -> output_string channel contents);
      path
    in
    ignore (write "leaf.tesl" cycle_leaf_source);
    ignore (write "tri-a.tesl" cycle_tri_a_source);
    ignore (write "tri-b.tesl" cycle_tri_b_source);
    ignore (write "tri-c.tesl" cycle_tri_c_source);
    let top = write "top.tesl" cycle_top_source in
    let emitted = match Compile.compile_go_file top with
      | Compile.GoSuccess artifacts -> artifacts
      | Compile.GoFailure diagnostics ->
        failf "three-module cyclic compilation failed: %s"
          (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
    in
    let merged = artifact "internal/teslmodtria/module.go" emitted in
    let outside = artifact "internal/teslmodtop/module.go" emitted in
    check bool "all three members land in one package" true
      (contains merged "func FromA(" && contains merged "func FromB("
       && contains merged "func FromC(");
    check bool "a module outside the cycle stays its own package" true
      (contains (artifact "internal/teslmodleaf/module.go" emitted) "func Double(");
    check bool "no package is emitted for a collapsed member" true
      (not (List.exists (fun (a : Emit_go.artifact) ->
         a.path = "internal/teslmodtrib/module.go" || a.path = "internal/teslmodtric/module.go")
         emitted));
    (* `fromC` is declared by TriC, but reached through the merged package's name. *)
    check bool "an outside importer reaches a member through the merged package" true
      (contains outside "return teslmodtria.FromC(n)");
    (* TriB imports `double` and TriC imports `triple` — the SAME outside module with
       DIFFERENT exposed lists, which merging must union into one import rather than
       registering the dependency twice. *)
    check bool "the cycle's own acyclic dependency is still imported normally" true
      (contains merged "teslmodleaf.Double(" && contains merged "teslmodleaf.Triple(");
    (* The record literal below is the bug this slice found: a record declared in another
       package was constructed with a BARE type name, which does not compile.  It escaped
       the cross-module test because that test only ever constructed a foreign NEWTYPE. *)
    check bool "a foreign record literal is qualified" true
      (contains outside "teslmodtria.AType{Label: label}");
    if Sys.command "go version >/dev/null 2>&1" = 0 then begin
      let out = Filename.concat root "emitted" in
      write_artifacts out emitted;
      let unformatted = run_command out "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command out "gofmt -d .");
      ignore (run_command out "go test -count=1 ./...");
      ignore (run_command out "go vet ./...");
      ignore (run_command out "go test -race -count=1 ./...");
      run_go_gates out
    end)

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
    (contains module_go "type Count struct {\n\tValue teslrt.Int\n}");
  check bool "String newtype is nominal" true
    (contains module_go "type Label struct {\n\tValue string\n}");
  check bool "Bool newtype is nominal" true
    (contains module_go "type EnabledFlag struct {\n\tValue bool\n}");
  check bool "Unit newtype is nominal" true
    (contains module_go "type Marker struct {\n\tValue struct{}\n}");
  check bool "newtype Int equality uses runtime helper" true
    (contains module_go "teslrt.Equal(left.Value, right.Value)");
  check bool "newtype Int ordering uses runtime helper" true
    (contains module_go "teslrt.Compare(left.Value, right.Value)");
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
  (* A newtype over a NEWTYPE is SUPPORTED — `type WrappedUserId = UserId` nests exactly as
     Racket nests it — so it is no longer a case here; see "a newtype over a newtype, and
     unobservable containers" for what it emits and its Racket oracle. What stays refused is
     a base that is not a type at all in this position: an APPLIED one. *)
  (* The needle is the newtype-base arm's own words.  It used to read "applied types", which
     matched a SECOND diagnostic from the type walk — reworded since, because that arm is
     unreachable and now says so. *)
  expect_go_error "applied newtype base" "newtype base is an applied type"
    {|module AppliedNewtype exposing [Counts]
import Tesl.Prelude exposing [Int, List]
type Counts = (List Int)
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
  (* A record INVARIANT used to fail closed here.  It ERASES: LANGUAGE-SPEC calls the
     record-level `::: P` a zero-cost annotation, and the Racket emitter reads it only for
     property-test generators, never for a check at construction — so this is now a positive
     assertion, like the proof-carrying FIELD below. *)
  (match Compile.compile_go_source "<invariant-record>" {|module InvariantRecord exposing [Span, width]
import Tesl.Prelude exposing [Int]
fact Ordered (lo: Int, hi: Int)
record Span {
  lo: Int
  hi: Int
} ::: Ordered lo hi
fn width(s: Span) -> Int = s.hi - s.lo
|} with
   | Compile.GoSuccess artifacts ->
     let module_go = artifact "internal/teslmodinvariantrecord/module.go" artifacts in
     check bool "a record invariant leaves no runtime structure" true
       (contains module_go "type Span struct {\n\tLo teslrt.Int\n\tHi teslrt.Int\n}")
   | Compile.GoFailure diagnostics ->
     failf "record invariant failed to compile: %s"
       (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics)));
  (* A proof-carrying record field used to fail closed here.  It ERASES like every other
     proof — codecs forced the question, since a decoded field is exactly one — so this is
     now a positive assertion. *)
  (match Compile.compile_go_source "<proof-field-record>" {|module ProofFieldRecord exposing [Positive, Box, valueOf]
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
record Box {
  value: Int ::: Positive value
}
fn valueOf(b: Box) -> Int = b.value
|} with
   | Compile.GoFailure diagnostics ->
     failf "a proof-carrying record field must emit: %s"
       (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
   | Compile.GoSuccess artifacts ->
     let module_go = artifact "internal/teslmodprooffieldrecord/module.go" artifacts in
     check bool "the proof erases from the field type" true
       (contains module_go "Value teslrt.Int"));
  (* Float, Set and — since function values landed — FUNCTION-typed fields all work.  The
     calling-convention decision this was waiting on is made: a function value is a Go func
     type, so a field holding one is an ordinary field. *)
  (match Compile.compile_go_source "<function-field-record>" {|module FunctionFieldRecord exposing [Handler, run]
import Tesl.Prelude exposing [Int]
record Handler {
  apply: Int -> Int
}
fn run(h: Handler, n: Int) -> Int = h.apply n
|} with
   | Compile.GoSuccess artifacts ->
     let module_go = artifact "internal/teslmodfunctionfieldrecord/module.go" artifacts in
     check bool "a function-typed field is a Go func field" true
       (contains module_go "Apply func(teslrt.Int) teslrt.Int");
     check bool "and calling through it is an ordinary call" true
       (contains module_go "h.Apply(n)")
   | Compile.GoFailure diagnostics ->
     failf "function-typed record field failed to compile: %s"
       (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics)))

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
  (* A GENERIC FUNCTION is supported now — `fn identity(value: a) -> a` becomes
     `func Identity[A any](value A) A`, and a call reads its type argument off what it is
     applied to (see "a generic function", with its Racket oracle). What still fails closed
     is a type parameter nothing can settle AT THE CALL, which that test states.

     A DIRECT self-reference is supported too: the field is a pointer. A self-reference
     reached through another VALUE type is not — the indirection would have to live inside
     that type's own layout. *)
  expect_go_error "indirectly recursive ADT" "the payload field IS the type"
    {|module RecursiveAdt exposing [Chain, depth]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
type Chain
  = Stop
  | Link (next: Maybe Chain)
fn depth(c: Chain) -> Int = 0
|};
  (* A generic type naming itself at ANOTHER instantiation (`Node left: (Tree Int)` inside
     `Tree a`) is supported now: the field takes the same pointer a self-reference at its own
     instantiation gets, and Go accepts the declaration — the instantiation cycle it rejects
     is the one whose type ARGUMENT grows. See "a recursive generic at another
     instantiation". *)
  (* A `case` over Int, String or Bool IS supported now; anything with no equality this backend
     emits — a record here, and a Float, which cannot even be written as a pattern — still fails
     closed rather than being guessed at. *)
  expect_go_error "case over a record" "case` over a module ADT or a scalar"
    {|module CaseOverRecord exposing [classify]
import Tesl.Prelude exposing [Int, String]
record Point { x: Int }
fn classify(p: Point) -> String =
  case p of
    _ -> "other"
|}
  (* A proof-carrying CONSTRUCTOR field is supported now: the annotation is a type-level
     contract with no runtime structure, so the field is its own type and the proof erases —
     the same rule a record field follows. See "proof shapes at the edges of erasure". *)

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

(* The container and Either LEAVES added after the Postgres slice, each of which stopped a
   corpus file on one line: `Dict.union`/`delete`/`filterCheckValues`/`filterCheckKeys`,
   `Set.allCheck`, `List.count`/`product`, `Int.gcd`/`lcm`, and the whole `Either` combinator
   family.  Also here: an EMPTY container written in place as an argument or a fold's init
   (`Dict.insert k v Dict.empty`, `List.foldl f Dict.empty xs`), which carries no key or
   element type of its own and takes one from what surrounds it. *)
let leaves2_source = {|module GoLeaves2 exposing [countBig, tally, verified, keyed, splitSides, categorise]

import Tesl.Prelude exposing [Bool(..), Int, String, List, Unit]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Either exposing [
  Either(..),
  Either.isLeft,
  Either.isRight,
  Either.fromLeft,
  Either.fromRight,
  Either.map,
  Either.mapLeft,
  Either.andThen,
  Either.withDefault,
  Either.toMaybe,
  Either.fromMaybe,
  Either.partition,
]
import Tesl.List exposing [List.count, List.product, List.length]
import Tesl.Dict exposing [
  Dict,
  Dict.empty,
  Dict.insert,
  Dict.delete,
  Dict.union,
  Dict.member,
  Dict.size,
  Dict.lookup,
  Dict.filterCheckValues,
  Dict.filterCheckKeys,
]
import Tesl.Set exposing [Set, Set.empty, Set.insert, Set.delete, Set.member, Set.size, Set.allCheck, Set.fromList]
import Tesl.Int exposing [Int.gcd, Int.lcm]
import Tesl.Tuple exposing [Tuple2, Tuple2.first, Tuple2.second]

fact IsPositive (n: Int)
fact HasText (s: String)

check positive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 422 "must be positive"

check nonEmptyKey(s: String) -> s: String ::: HasText s =
  if s != "" then
    ok s ::: HasText s
  else
    fail 422 "must not be empty"

fn isBig(n: Int) -> Bool =
  n > 10

fn countBig(ns: List Int) -> Int =
  List.count isBig ns

fn tally(ns: List Int) -> Int =
  List.product ns

# A dict built from an empty one written in place, then merged left-biased.
fn merged() -> Int =
  let left = Dict.insert "a" 1 (Dict.insert "b" 2 Dict.empty)
  let right = Dict.insert "b" 99 (Dict.insert "c" 3 Dict.empty)
  let both = Dict.union left right
  case Dict.lookup "b" both of
    Nothing -> 0
    Something v -> v + Dict.size both

fn dropped() -> Bool =
  let d = Dict.insert "k" 1 Dict.empty
  Dict.member "k" (Dict.delete "k" d)

fn verified(d: Dict String Int) -> Int =
  Dict.size (Dict.filterCheckValues positive d)

fn keyed(d: Dict String Int) -> Int =
  Dict.size (Dict.filterCheckKeys nonEmptyKey d)

fn setDropped() -> Bool =
  let s = Set.insert 7 Set.empty
  Set.member 7 (Set.delete 7 s)

fn allPositive(ns: List Int) -> Int =
  case Set.allCheck positive (Set.fromList ns) of
    Nothing -> 0 - 1
    Something s -> Set.size s

fn categorise(n: Int) -> String =
  if n > 10 then
    "big"
  else
    "small"

fn parse(raw: Int) -> Either String Int =
  if raw > 0 then
    Right raw
  else
    Left "not positive"

fn described(raw: Int) -> Either String String =
  Either.map categorise (parse raw)

fn label(reason: String) -> String =
  "error: " ++ reason

fn shouted(raw: Int) -> Either String Int =
  Either.mapLeft label (parse raw)

fn chained(raw: Int) -> Either String Int =
  Either.andThen parse (parse raw)

fn sides() -> List (Either String Int) =
  [parse 1, parse (0 - 1), parse 2]

fn splitSides(values: List (Either String Int)) -> Int =
  let parts = Either.partition values
  List.length (Tuple2.first parts) + List.length (Tuple2.second parts)

test "the container leaves answer what Racket answers" {
  expect countBig [1, 20, 30] == 2
  expect tally [2, 3, 4] == 24
  expect tally [] == 1
  expect merged () == 5
  expect dropped () == False
  expect setDropped () == False
  expect allPositive [1, 2, 3] == 3
  expect allPositive [1, 0 - 2, 3] == 0 - 1
  expect Int.gcd 12 18 == 6
  expect Int.gcd (0 - 12) 18 == 6
  expect Int.lcm 4 6 == 12
  expect Int.lcm 0 6 == 0
}

test "the Either combinators answer what Racket answers" {
  expect Either.isLeft (parse (0 - 1)) == True
  expect Either.isRight (parse 5) == True
  expect Either.withDefault 0 (parse 5) == 5
  expect Either.withDefault 0 (parse (0 - 1)) == 0
  expect Either.fromRight (parse 5) == Something 5
  expect Either.fromLeft (parse 5) == Nothing
  expect Either.toMaybe (parse (0 - 1)) == Nothing
  expect Either.fromMaybe "none" (Something 7) == Right 7
  expect described 20 == Right "big"
  expect described (0 - 1) == Left "not positive"
  expect shouted (0 - 1) == Left "error: not positive"
  expect chained 5 == Right 5
  expect splitSides (sides ()) == 3
}

test "dict checks keep the entries that pass" {
  let d = Dict.insert "a" 5 (Dict.insert "b" (0 - 1) Dict.empty)
  expect verified d == 1
  expect keyed d == 2
}
|}

let test_leaves2_with_go () =
  let emitted = emit_ok "<go-leaves2>" leaves2_source in
  let module_go = artifact "internal/teslmodgoleaves2/module.go" emitted in
  (* `Dict.union` is the one dict leaf that is NOT rotated: both operands are dicts, and
     swapping them would silently reverse the left bias. *)
  check bool "union keeps its operand order" true
    (contains module_go "teslrt.DictUnion(left, right, teslKeyLessString)");
  check bool "an empty dict written in place is instantiated" true
    (contains module_go "teslrt.DictEmpty[string, teslrt.Int]()");
  check bool "delete is remove under another name" true
    (contains module_go "teslrt.DictRemove(d, \"k\", teslKeyLessString)");
  (* The Either combinators that take a function are emitted INLINE, like every other
     callback — no Go func value is passed. *)
  check bool "Either.map inlines its callback" true
    (contains module_go "if teslEither1.Tag == teslrt.EitherRight {");
  check bool "and rebuilds the other side unchanged" true
    (contains module_go "return teslrt.Left[string, string](teslEither1.LeftValue)");
  (* `go test` RUNS all three blocks, so a wrong answer fails here. *)
  gate_emitted "tesl-go-leaves2" emitted

(* A RECURSIVE ADT: a payload field that IS the type it belongs to.  Go has no such value —
   a struct containing itself has no finite size — so the field is a POINTER, filled through
   `teslrt.Boxed` at construction and read through `teslrt.Unboxed` at every binding and
   comparison.  What made this more than a representation change is that a recursive type
   makes the emitter's own type values CYCLIC, and OCaml's `=` walks a cycle forever: type
   comparisons go through `type_equal`, which compares an ADT by its declaration. *)
let recursive_adt_source = {|module GoRecursive exposing [evaluate, treeSum, treeDepth, sameTree]

import Tesl.Prelude exposing [Bool(..), Int, String]

# A self-referential ADT: each payload field that IS the type becomes a Go pointer.
type Expr
  = Lit value: Int
  | Neg inner: Expr
  | Add left: Expr right: Expr

type Tree
  = Leaf
  | Node left: Tree value: Int right: Tree

fn evaluate(e: Expr) -> Int =
  case e of
    Lit value -> value
    Neg inner -> 0 - evaluate(inner)
    Add left right -> evaluate(left) + evaluate(right)

fn treeSum(t: Tree) -> Int =
  case t of
    Leaf -> 0
    Node left value right -> treeSum(left) + value + treeSum(right)

fn treeDepth(t: Tree) -> Int =
  case t of
    Leaf -> 0
    Node left value right ->
      let ld = treeDepth(left)
      let rd = treeDepth(right)
      if ld > rd then
        1 + ld
      else
        1 + rd

fn sameTree(a: Tree, b: Tree) -> Bool =
  a == b

fn sample() -> Tree =
  let leftChild = Node Leaf 1 Leaf
  let rightChild = Node Leaf 3 Leaf
  Node leftChild 2 rightChild

fn expression() -> Expr =
  let three = Lit 3
  let four = Lit 4
  Add three (Neg four)

test "a recursive value is built, walked and compared" {
  expect evaluate (expression ()) == 0 - 1
  expect treeSum (sample ()) == 6
  expect treeDepth (sample ()) == 2
  expect sameTree (sample ()) (sample ()) == True
  expect sameTree (sample ()) Leaf == False
  expect treeSum Leaf == 0
}
|}

let test_recursive_adt_with_go () =
  let emitted = emit_ok "<go-recursive>" recursive_adt_source in
  let module_go = artifact "internal/teslmodgorecursive/module.go" emitted in
  check bool "a self-referential payload is a pointer" true
    (contains module_go "NodeLeft  *Tree");
  check bool "construction boxes it" true
    (contains module_go "NodeLeft: teslrt.Boxed(leftChild)");
  check bool "a pattern binding unboxes it" true
    (contains module_go "left := teslrt.Unboxed(teslScrut1.NodeLeft)");
  (* Equality walks the pointers rather than comparing them: two trees with the same shape
     and the same values are equal, whoever built them. *)
  check bool "equality compares through the pointer" true
    (contains module_go
       "(teslrt.Unboxed(teslLeft.NodeLeft)).TeslEqual(teslrt.Unboxed(teslRight.NodeLeft))");
  (* `go test` RUNS the block, so a wrong answer — or a nil deref — fails here. *)
  gate_emitted "tesl-go-recursive" emitted

(* NESTED constructor patterns: `Neg (Lit n)`, `Wrapped Nothing`, and the labeled literal
   form `RGB { r = 255, … }`.  An arm like that tests more than its own tag, so it cannot be
   a `switch` case — the emitter falls back to the if-chain the guarded form already uses,
   and the tag test and the nested tests are ONE `&&` condition so the nested read only
   happens once the tag says the payload is there. *)
let nested_pattern_source = {|module GoNestedPatterns exposing [evalExpr, describeShape, describeColor, firstOf]

import Tesl.Prelude exposing [Bool(..), Int, String, List]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.String exposing [String.fromInt]

# A nested pattern over a RECURSIVE type: the inner test reads through the pointer.
type Expr
  = Lit value: Int
  | Neg inner: Expr
  | Add left: Expr right: Expr

fn evalExpr(e: Expr) -> Int =
  case e of
    Lit value -> value
    Neg (Lit n) -> 0 - n
    Neg inner -> 0 - evalExpr(inner)
    Add (Lit 0) right -> evalExpr(right)
    Add left right -> evalExpr(left) + evalExpr(right)

# A nested NULLARY constructor, and a nested one that binds.
type Shape
  = Circle radius: Int
  | Wrapped inner: Maybe Int

fn describeShape(s: Shape) -> String =
  case s of
    Circle radius -> "circle r=${String.fromInt radius}"
    Wrapped Nothing -> "empty wrapper"
    Wrapped (Something value) -> "wrapped ${String.fromInt value}"

# Labeled LITERAL sub-patterns, and a flat arm after them.
type Color = RGB r: Int g: Int b: Int

fn describeColor(c: Color) -> String =
  case c of
    RGB { r = 255, g = 255, b = 255 } -> "white"
    RGB { r = 0, g = 0, b = 0 } -> "black"
    RGB r g _ -> "r=${String.fromInt r} g=${String.fromInt g}"

# A nested pattern alongside a GUARD on the same arm.
fn firstOf(m: Maybe Int) -> Int =
  case m of
    Something value where value > 10 -> value
    Something _ -> 0
    Nothing -> 0 - 1

test "nested patterns discriminate and bind" {
  expect evalExpr (Lit 7) == 7
  expect evalExpr (Neg (Lit 3)) == 0 - 3
  expect evalExpr (Neg (Add (Lit 1) (Lit 2))) == 0 - 3
  expect evalExpr (Add (Lit 0) (Lit 9)) == 9
  expect evalExpr (Add (Lit 4) (Lit 5)) == 9
  expect describeShape (Circle 5) == "circle r=5"
  expect describeShape (Wrapped Nothing) == "empty wrapper"
  expect describeShape (Wrapped (Something 42)) == "wrapped 42"
  expect describeColor (RGB 255 255 255) == "white"
  expect describeColor (RGB 0 0 0) == "black"
  expect describeColor (RGB 1 2 3) == "r=1 g=2"
  expect firstOf (Something 42) == 42
  expect firstOf (Something 1) == 0
  expect firstOf Nothing == 0 - 1
}
|}

let test_nested_patterns_with_go () =
  let emitted = emit_ok "<go-nested>" nested_pattern_source in
  let module_go = artifact "internal/teslmodgonestedpatterns/module.go" emitted in
  (* The tag test and the nested test are one condition, left to right. *)
  (* The scrutinee's temporary is numbered by nesting depth, so the assertions name the
     shape rather than the number. *)
  check bool "a nested pattern tests through the payload" true
    (contains module_go ".Tag == ExprNeg && teslrt.Unboxed("
     && contains module_go ".NegInner).Tag == ExprLit {");
  check bool "and binds two levels down" true
    (contains module_go "n := teslrt.Unboxed("
     && contains module_go ".NegInner).LitValue");
  (* A literal sub-pattern compares through the same equality a value comparison uses. *)
  check bool "a literal sub-pattern compares as a value" true
    (contains module_go ".RGBR, teslrt.FromInt64(255))");
  (* A nullary sub-pattern over a runtime ADT reads its tag. *)
  check bool "a nested nullary constructor tests its tag" true
    (contains module_go ".WrappedInner.Tag == teslrt.MaybeNothing");
  (* `go test` RUNS the block, so a wrong arm order or a wrong binding fails here. *)
  gate_emitted "tesl-go-nested" emitted

(* `Tesl.UUID`: two generators gated by the `uuid` capability, and a validate that is a
   CHECK.  The v7 layout was already in the runtime (a queue job id is one, and it has to
   sort the same on both backends); v4 and the validator join it.  Also pinned here: a
   check's VALUE used where its base type is expected (`fn validated(s) -> String =
   UUID.validate s`), which traps on rejection — the same verdict `expectFail` sees on
   Racket. *)
let uuid_source = {|module GoUuid exposing [mintV4, mintV7, validated, versionDigit]

import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.String exposing [String.length, String.slice]
import Tesl.UUID exposing [uuid, IsUuid, UUID.v4, UUID.v7, UUID.validate]

fn mintV4() -> String requires [uuid] =
  UUID.v4()

fn mintV7() -> String requires [uuid] =
  UUID.v7()

# A check used where its VALUE is expected: the rejection is the failure.
fn validated(s: String) -> String =
  UUID.validate s

fn versionDigit(s: String) -> String =
  String.slice s 14 15

test "a minted UUID has the shape both backends agree on" requires [uuid] {
  let v4 = mintV4()
  let v7 = mintV7()
  expect String.length v4 == 36
  expect String.length v7 == 36
  expect versionDigit v4 == "4"
  expect versionDigit v7 == "7"
  expect String.slice v4 8 9 == "-"
  expect String.slice v4 23 24 == "-"
  expect v4 != v7
}

test "validate accepts a well-formed UUID in either case" {
  expect validated "a8098c1a-f86e-4f11-8d1c-6e9e14b9d8e2" == "a8098c1a-f86e-4f11-8d1c-6e9e14b9d8e2"
  expect String.length (validated "A8098C1A-F86E-4F11-8D1C-6E9E14B9D8E2") == 36
  expect String.length (validated "00000000-0000-0000-0000-000000000000") == 36
}

test "validate rejects anything else" {
  expectFail (validated "not-a-uuid")
  expectFail (validated "")
  expectFail (validated "a8098c1a-f86e-4f11-8d1c")
  expectFail (validated "a8098c1a-f86e-4f11-8d1c-6e9e14b9d8e2-extra")
  expectFail (validated "g8098c1a-f86e-4f11-8d1c-6e9e14b9d8e2")
}
|}

let test_uuid_with_go () =
  let emitted = emit_ok "<go-uuid>" uuid_source in
  let module_go = artifact "internal/teslmodgouuid/module.go" emitted in
  check bool "generation is one runtime call" true
    (contains module_go "return teslrt.UUIDv4()" && contains module_go "return teslrt.UUIDv7()");
  (* The check's rejection is the failure at the point of use. *)
  check bool "a check used as a value must succeed" true
    (contains module_go "return teslrt.MustCheck(teslrt.UUIDValidate(s))");
  (* `go test` RUNS the blocks: shape, version digit, and every rejection. *)
  gate_emitted "tesl-go-uuid" emitted

(* `Tesl.Cache`: a declared cache is one package-level store, TYPED by its `valueType:` — so a
   hit needs no decode and cannot answer the wrong shape, which is where this departs from
   Racket (whose PostgreSQL path stores JSON text because a column has to hold something).
   Expiry is noticed on READ, so a stale value is never answered and no sweeper runs; the
   default TTL is baked into the store because it belongs to the declaration, and an explicit
   TTL on a `Cache.set` overrides it.  `invalidate` matches a LITERAL prefix — Racket spells
   that `left(key, length($1)) = $1` precisely so a `%` cannot behave as a wildcard. *)
let cache_source = {|module GoCache exposing [lookup, remember, rememberBriefly, forget, forgetAll, counterOf]

import Tesl.Prelude exposing [Bool(..), Int, String, Unit]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Database exposing [Database, Memory]
import Tesl.Cache exposing [Cache]

database Store = Database {
  schema: "gocache"
  entities: []
  backend: Memory
}

cache ProfileCache = Cache {
  database: Store
  defaultTtl: 3600
  valueType: String
}

cache CounterCache = Cache {
  database: Store
  valueType: Int
}

fn lookup(key: String) -> Maybe String requires [cacheCap ProfileCache] =
  Cache.get ProfileCache (key)

fn remember(key: String, value: String) -> Unit requires [cacheCap ProfileCache] =
  Cache.set ProfileCache (key) value

fn rememberBriefly(key: String, value: String) -> Unit requires [cacheCap ProfileCache] =
  Cache.set ProfileCache (key) value 60

fn forget(key: String) -> Unit requires [cacheCap ProfileCache] =
  Cache.delete ProfileCache (key)

fn forgetAll(prefix: String) -> Unit requires [cacheCap ProfileCache] =
  Cache.invalidate ProfileCache (prefix)

fn bump(key: String, value: Int) -> Unit requires [cacheCap CounterCache] =
  Cache.set CounterCache (key) value

fn counterOf(key: String) -> Int requires [cacheCap CounterCache] =
  case Cache.get CounterCache (key) of
    Nothing -> 0 - 1
    Something n -> n

test "a miss, a hit, and an overwrite" requires [cacheCap ProfileCache] {
  expect lookup "profile:1" == Nothing
  let _ = remember "profile:1" "ada"
  expect lookup "profile:1" == Something "ada"
  let _ = remember "profile:1" "grace"
  expect lookup "profile:1" == Something "grace"
}

test "each cache keeps its own declared value type" requires [cacheCap CounterCache] {
  expect counterOf "hits" == 0 - 1
  let _ = bump "hits" 41
  expect counterOf "hits" == 41
}

test "delete takes one key, invalidate takes a namespace" requires [cacheCap ProfileCache] {
  let _ = remember "profile:1" "ada"
  let _ = remember "profile:2" "grace"
  let _ = remember "session:1" "token"
  let _ = forget "profile:1"
  expect lookup "profile:1" == Nothing
  expect lookup "profile:2" == Something "grace"
  let _ = forgetAll "profile:"
  expect lookup "profile:2" == Nothing
  expect lookup "session:1" == Something "token"
}

test "a prefix is literal, not a pattern" requires [cacheCap ProfileCache] {
  let _ = remember "100%sure" "yes"
  let _ = remember "unrelated" "no"
  let _ = forgetAll "%"
  expect lookup "unrelated" == Something "no"
  let _ = forgetAll "100%"
  expect lookup "100%sure" == Nothing
}

test "an explicit TTL is accepted and the entry is live inside it" requires [cacheCap ProfileCache] {
  let _ = rememberBriefly "profile:9" "live"
  expect lookup "profile:9" == Something "live"
}

test "each block starts from an empty cache" requires [cacheCap ProfileCache] {
  expect lookup "profile:1" == Nothing
  expect lookup "profile:9" == Nothing
}

|}

let test_cache_with_go () =
  let emitted = emit_ok "<go-cache>" cache_source in
  let module_go = artifact "internal/teslmodgocache/module.go" emitted in
  check bool "a declaration becomes one typed store" true
    (contains module_go "var ProfileCacheStore = teslrt.NewCache[string](3600)");
  check bool "and a cache with no defaultTtl gets none" true
    (contains module_go "var CounterCacheStore = teslrt.NewCache[teslrt.Int](0)");
  check bool "an explicit TTL takes the other setter" true
    (contains module_go "teslrt.CacheSetTTL(ProfileCacheStore, key, value, teslrt.FromInt64(60))");
  check bool "invalidate is a prefix, not a key" true
    (contains module_go "teslrt.CacheInvalidatePrefix(ProfileCacheStore, prefix)");
  (* Per-test isolation: one block's entries must not be another's, the same rule tables and
     queues follow.  The Racket runtime did NOT clear its cache store between blocks until the
     oracle for this case caught it (dsl/test-support.rkt), which is the bug an oracle exists
     to find: a program's tests would have passed in one order and failed in another. *)
  let tests_go = artifact "internal/teslmodgocache/module_test.go" emitted in
  check bool "each test block starts from an empty cache" true
    (contains tests_go "teslrt.CacheReset(ProfileCacheStore)");
  (* `go test` RUNS the blocks: miss/hit, overwrite, per-cache typing, delete vs invalidate,
     the literal-prefix rule, and the reset. *)
  gate_emitted "tesl-go-cache" emitted

let money_source = {|module GoMoney exposing [invoiceTotal, discounted, converted, hourlyFee, pace]

import Tesl.Prelude exposing [Bool(..), Int, String, Unit]
import Tesl.Float exposing [Float]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Money exposing [
  Money,
  Currency,
  ExchangeRate,
  MoneyPerDuration,
  Usd,
  Sek,
  Money.usd,
  Money.sek,
  Money.minorUnits,
  Money.display,
  Money.scale,
  Money.scaleBy,
  Money.add,
  Money.convertChecked,
  Money.requireRateFor,
  Money.requireSameCurrency,
  Currency.code,
  Currency.fromCode,
  ExchangeRate.make,
  MoneyRate.perHour,
  MoneyRate.display,
]
import Tesl.Time exposing [PosixMillis, Time.secondsToPosix]
import Tesl.Units exposing [
  Length,
  Duration,
  Speed,
  Length.kilometers,
  Length.inMeters,
  Duration.hours,
  Duration.minutes,
  Speed.inKilometersPerHour,
  Units.requireNonZero,
]

# An integer scale is EXACT — quantity times unit price never rounds.
fn invoiceTotal(unitPrice: Money, quantity: Int) -> Money =
  Money.scale unitPrice quantity

# A fractional scale ROUNDS, half-even, which is why it has its own name.
fn discounted(amount: Money) -> Money =
  Money.scaleBy amount 0.9

# The sanctioned conversion flow: mint the RateFor proof, then convert under it.
fn converted(amount: Money) -> Money =
  let rate = ExchangeRate.make Usd Sek 0.9155 (Time.secondsToPosix 0)
  let checked = check Money.requireRateFor rate amount
  Money.convertChecked rate checked

fn hourlyFee(rate: MoneyPerDuration, worked: Duration) -> Money =
  rate * worked

fn pace(distance: Length, elapsed: Duration) -> Speed =
  let elapsedNonZero = check Units.requireNonZero elapsed
  distance / elapsedNonZero

test "an exact scale and a rounding one" {
  expect Money.display (invoiceTotal (Money.usd 1999) 3) == "$59.97"
  # 1005 × 0.9 = 904.5, and half-even sends a tie to the EVEN neighbour.
  expect Money.minorUnits (discounted (Money.usd 1005)) == 904
  let first = Money.usd 1000
  let second = Money.usd 250
  let sameCurrency = check Money.requireSameCurrency first second
  expect Money.display (Money.add first sameCurrency) == "$12.50"
}

test "a conversion rounds half-even on the exact rate" {
  expect Money.minorUnits (converted (Money.usd 1000)) == 916
  expect Money.display (converted (Money.usd 1000)) == "9.16 SEK"
}

test "a currency resolves from its ISO code" {
  expect (case Currency.fromCode "SEK" of
    Something c -> Currency.code c
    Nothing -> "none") == "SEK"
  expect (case Currency.fromCode "ZZZ" of
    Something c -> Currency.code c
    Nothing -> "none") == "none"
}

test "a rate displays per its own unit and materializes once" {
  let hourly = MoneyRate.perHour (Money.sek 95000)
  expect MoneyRate.display hourly == "950.00 SEK/h"
  expect Money.display (hourlyFee hourly (Duration.hours 1.5)) == "1425.00 SEK"
  expect Money.display (hourlyFee hourly (Duration.minutes 30.0)) == "475.00 SEK"
}

test "quantities convert and divide" {
  expect Length.inMeters (Length.kilometers 2.0) == 2000.0
  expect Speed.inKilometersPerHour (pace (Length.kilometers 10.0) (Duration.hours 0.5)) == 20.0
}
|}

let test_money_with_go () =
  let emitted = emit_ok "<go-money>" money_source in
  let module_go = artifact "internal/teslmodgomoney/module.go" emitted in
  let tests_go = artifact "internal/teslmodgomoney/module_test.go" emitted in
  (* A per-currency constructor bakes its ISO code and its minor-digit count, both read from
     the compiler's own currency table — the runtime looks nothing up.  The constructor is
     written in the TEST block (a `Money` reaches the functions as a parameter), so that is
     where the baked call lands. *)
  check bool "a money constructor bakes its currency" true
    (contains tests_go "teslrt.MoneyOf(teslrt.FromInt64(1999), \"USD\", 2)");
  check bool "and a bare currency is a value, not a call" true
    (contains module_go "teslrt.CurrencyOf(\"USD\", 2)");
  (* An integer scale is exact; a fractional one rounds and is a different function. *)
  check bool "an exact scale stays exact" true (contains module_go "teslrt.MoneyScale(");
  check bool "a fractional scale is the rounding one" true
    (contains module_go "teslrt.MoneyScaleBy(");
  (* `rate * quantity` is the one place a rate materialises, so it is a named call rather
     than a `*`: at run time both operands are floats, and only the TYPES tell it from a
     rescale. *)
  check bool "a rate times a quantity materialises money" true
    (contains module_go "teslrt.MoneyRateMul(");
  (* The rate itself is BUILT in the test block — a function takes one as a parameter — so the
     baked label lands there, beside the currency the constructor bakes. *)
  check bool "a per-hour rate bakes its label" true
    (contains tests_go "teslrt.MoneyRateOfLabel(");
  (* A quantity is a float64 with a dimension the compiler kept: the arithmetic is ordinary. *)
  check bool "quantity division is plain float arithmetic" true
    (contains module_go "(distance / elapsedNonZero)");
  (* `go test` RUNS the blocks: the scales, the conversion, the ISO lookup, the rate, and the
     unit conversions. *)
  gate_emitted "tesl-go-money" emitted

let property_source = {|module GoProperty exposing [clamp, evenDouble, lengthOf, smallInt]

import Tesl.Prelude exposing [Bool(..), Int, String, List, Unit]
import Tesl.List exposing [List.length, List.append]
import Tesl.Maybe exposing [Maybe(..)]

fn clamp(low: Int, high: Int, value: Int) -> Int =
  if value < low then
    low
  else
    if value > high then
      high
    else
      value

fn evenDouble(n: Int) -> Int =
  n * 2

fn lengthOf(xs: List Int) -> Int =
  List.length xs

# A custom generator is a function of the RUN INDEX, so it can walk a space rather than
# sample it — the same shape Racket's `via` generator has.
fn smallInt(run: Int) -> Int =
  run % 10

test "arithmetic properties hold over generated values" {
  property "addition commutes" (x: Int, y: Int) { x + y == y + x }
  property "doubling is even" (n: Int) { evenDouble n % 2 == 0 }
}

test "a where clause says which values the property is about" {
  property "clamping lands inside the range" (low: Int, high: Int where low <= high, value: Int) {
    clamp low high value >= low && clamp low high value <= high
  }
}

test "generated containers" with 50 runs {
  property "length is never negative" (xs: List Int) { lengthOf xs >= 0 }
  property "appending adds the lengths" (xs: List Int, ys: List Int) {
    lengthOf (List.append xs ys) == lengthOf xs + lengthOf ys
  }
}

test "a custom generator supplies the values" with 20 runs {
  property "the generator stays under ten" (n: Int via smallInt) { n < 10 && n >= 0 }
}
|}

let test_property_with_go () =
  let emitted = emit_ok "<go-property>" property_source in
  let tests_go = artifact "internal/teslmodgoproperty/module_test.go" emitted in
  (* 200 runs unless the block says otherwise, which is Racket's default. *)
  check bool "a property runs 200 times by default" true
    (contains tests_go "< 200;");
  check bool "and `with N runs` sets the count" true
    (contains tests_go "< 50;");
  check bool "an Int parameter is generated" true (contains tests_go "teslrt.PropInt()");
  check bool "a List parameter generates its elements" true
    (contains tests_go "teslrt.PropList(func() teslrt.Int { return teslrt.PropInt() })");
  (* A custom generator takes the RUN INDEX, so it can walk a space rather than sample it. *)
  check bool "a custom generator is called with the run index" true
    (contains tests_go "SmallInt(teslrt.FromInt64(int64(teslPropRun");
  (* A `where` clause SKIPS the run rather than failing it: the guard says which values the
     property is about, so a value outside it is not a counterexample. *)
  check bool "a where clause guards the check" true
    (contains tests_go "\tif teslrt.Compare(low, high) <= 0 {");
  (* The failing BINDING is reported, not just the property's name. *)
  check bool "a failure names the values it failed on" true
    (contains tests_go "failed (x=%v, y=%v)");
  (* `go test` RUNS the properties: 200 draws each, plus the guarded and generated ones. *)
  gate_emitted "tesl-go-property" emitted

let sse_source = {|module GoSse exposing [MainServer, triggerRun, notifyUser]

import Tesl.Prelude exposing [Bool(..), Int, String, Unit]
import Tesl.Json exposing [stringCodec]
import Tesl.Queue exposing [pubsub]
import Tesl.ApiTest exposing [statusOk, isNotEmpty, includesWhere, subscribe, collect]
import Tesl.Database exposing [Database, Memory]
import Tesl.SSE exposing [SseChannel]

database GoSseDb = Database {
  schema: "go_sse"
  entities: []
  backend: Memory
}

record RunQueued {
  runId: String
}

codec RunQueued {
  toJson {
    runId -> "runId" with_codec stringCodec
  }
  fromJson [
    {
      runId <- "runId" with_codec stringCodec
    }
  ]
}

sseChannel RunEvents(scope: String) = SseChannel {
  database: GoSseDb
  payload: RunQueued
}

sseChannel UserNotices(userId: String) = SseChannel {
  database: GoSseDb
  payload: RunQueued
}

handler post triggerRun(runId: String) -> String
  requires [pubsub] =
  publish RunEvents("all") RunQueued { runId: runId }
  "ok"

handler post notifyUser(userId: String) -> String
  requires [pubsub] =
  publish UserNotices(userId) RunQueued { runId: userId }
  "ok"

api MainApi {
  post "/trigger"
    body runId: String
    -> String

  post "/notify/:userId"
    capture userId: String using stringCodec
    -> String

  sse "/runs/stream"
    subscribe RunEvents("all")

  sse "/events/:userId"
    capture userId: String using stringCodec
    subscribe UserNotices(userId)
}

server MainServer for MainApi {
  triggerRun
  notifyUser
}

api-test "a publish reaches a broadcast subscriber" for MainServer requires [pubsub] {
  let stream = subscribe "/runs/stream"
  let resp = post "/trigger" body "run-abc"
  expect statusOk resp.status
  let events = collect stream count 1 timeout 2000ms
  expect isNotEmpty events
  expect includesWhere { "runId": "run-abc" } events
}

api-test "a keyed publish reaches that key only" for MainServer requires [pubsub] {
  let ada = subscribe "/events/ada"
  let resp = post "/notify/ada"
  expect statusOk resp.status
  let events = collect ada count 1 timeout 2000ms
  expect includesWhere { "runId": "ada" } events
}
|}

let test_sse_with_go () =
  let emitted = emit_ok "<go-sse>" sse_source in
  let module_go = artifact "internal/teslmodgosse/module.go" emitted in
  check bool "a declaration becomes one channel" true
    (contains module_go "var RunEventsChannel = teslrt.NewSseChannel(\"RunEvents\")");
  (* A publish encodes through the payload type's own codec — the same encoder a response
     body goes through, so a subscriber and a caller read the same shape. *)
  check bool "a publish names its channel, key and encoded payload" true
    (contains module_go "teslrt.Publish(RunEventsChannel, \"all\", EncodeRunQueuedJSON(");
  check bool "a keyed publish carries the key it was given" true
    (contains module_go "teslrt.Publish(UserNoticesChannel, userId, ");
  (* The route: a GET whose endpoint name is the path, and a stream rather than a handler. *)
  check bool "an sse route is a stream, not a handler" true
    (contains module_go "Streams: map[string]teslrt.StreamFunc{");
  check bool "a literal-keyed route streams that key" true
    (contains module_go "teslrt.SseStream(RunEventsChannel, \"all\")");
  check bool "a param-keyed route keys on its own segment" true
    (contains module_go "teslrt.SseStreamParam(UserNoticesChannel, \"/events/:userId\", \"userId\")");
  let tests_go = artifact "internal/teslmodgosse/module_test.go" emitted in
  check bool "subscribe opens a stream against the server under test" true
    (contains tests_go "teslrt.SubscribeStream(MainServer, \"/runs/stream\", nil)");
  check bool "collect waits for the count it was given" true
    (contains tests_go "teslrt.CollectCount(");
  (* A SUBSCRIPTION is per-block state on both backends — Racket's api-test cleanups
     unregister the listener when the block ends — so the emitted block closes its stream. *)
  check bool "a block closes the stream it opened" true
    (contains tests_go "defer teslrt.UnsubscribeStream(stream)");
  check bool "and a block starts from a channel nobody is on" true
    (contains tests_go "teslrt.ResetChannel(RunEventsChannel)");
  (* `go test` RUNS the blocks: a published event reaches the subscriber over a real
     connection, and a keyed publish reaches that key only. *)
  gate_emitted "tesl-go-sse" emitted

let transaction_source = {|module GoTransaction exposing [addEntry, totalFor, entriesFor]

import Tesl.Prelude exposing [Bool(..), Int, String, Unit]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, Memory]

entity Ledger table "txn_ledger" primaryKey id {
  id: String
  account: String
  amount: Int
}

database TxnDb = Database {
  entities: [Ledger]
  backend: Memory
}

fn addEntry(id: String, account: String, amount: Int) -> Int
  requires [dbRead, dbWrite] =
  transaction {
    insert Ledger { id: id, account: account, amount: amount }
    selectCount l from Ledger where l.account == account
  }

fn totalFor(account: String) -> Int
  requires [dbRead] =
  selectSum l.amount from Ledger where l.account == account

fn entriesFor(account: String) -> Int
  requires [dbRead] =
  selectCount l from Ledger where l.account == account

test "a transaction groups its writes and answers its tail" requires [dbRead, dbWrite] {
  expect addEntry "1" "ada" 100 == 1
  expect addEntry "2" "ada" 50 == 2
  expect addEntry "3" "grace" 10 == 1
  expect totalFor "ada" == 150
  expect entriesFor "grace" == 1
}

test "each block starts from an empty table" requires [dbRead] {
  expect entriesFor "ada" == 0
}
|}

let test_transaction_with_go () =
  let emitted = emit_ok "<go-transaction>" transaction_source in
  let module_go = artifact "internal/teslmodgotransaction/module.go" emitted in
  (* On the Memory backend a transaction has NO runtime form — Racket's
     `call-with-queue-transaction` is `(thunk)` unless a PostgreSQL connection is active — so
     the body keeps statement form rather than collapsing into a closure. *)
  check bool "the grouped write is an ordinary statement" true
    (contains module_go "_ = teslrt.TableInsert(");
  check bool "and the block's tail is the function's answer" true
    (contains module_go "return teslrt.TableCount(");
  (* `go test` RUNS the blocks: the writes land, the tail answers, and the second block sees
     an empty table. *)
  gate_emitted "tesl-go-transaction" emitted

let fail_source = {|module GoFail exposing [nameOf, greet, attempts]

import Tesl.Prelude exposing [Bool(..), Int, String, Unit]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.String exposing [String.length]

fn nameOf(row: Maybe String) -> String =
  case row of
    Something n -> n
    Nothing -> fail 404 "row not found"

fn greet(row: Maybe String) -> String =
  let n = nameOf row
  "hello ${n}"

fn attempts(row: Maybe String) -> Int =
  case row of
    Something n -> String.length n
    Nothing -> fail 422 "nothing to count"

test "a plain function may answer with a failure" {
  expect nameOf (Something "ada") == "ada"
  expect greet (Something "ada") == "hello ada"
  expect attempts (Something "ada") == 3
  expectFail (greet Nothing)
  expectFail (attempts Nothing)
}
|}

let test_fail_in_a_function_with_go () =
  let emitted = emit_ok "<go-fail>" fail_source in
  let module_go = artifact "internal/teslmodgofail/module.go" emitted in
  (* A `fail` outside a check has nowhere to go in the Go signature, so it travels as the
     rejection a rejected check uses — and it is a STATEMENT, since panic terminates. *)
  check bool "a fn's fail is the request rejection" true
    (contains module_go "panic(teslrt.RequestRejection{Status: 404, Message: \"row not found\"})");
  check bool "and it keeps the status the source chose" true
    (contains module_go "Status: 422");
  (* `go test` RUNS the block: the succeeding paths answer, and the failing one is caught by
     the same `expectFail` that catches it on Racket — where the failure surfaces at the
     caller's `let` rather than at the `fail` itself. *)
  gate_emitted "tesl-go-fail" emitted

let email_source = {|module GoEmail exposing [welcome, notify, bodyKind, startMail]

import Tesl.Prelude exposing [Bool(..), Int, String, Unit]
import Tesl.Database exposing [Database, Memory]
import Tesl.Email exposing [Email, SmtpConfig, emailCap, EmailBody(..)]

database Store = Database {
  schema: "goemail"
  entities: []
  backend: Memory
}

email AppMail = Email {
  database: Store
  smtp: SmtpConfig {
    host: env "TESL_GO_SMTP_HOST"
    port: 2525
    username: "sender@example.com"
    password: env "TESL_GO_SMTP_PASS"
    tls: true
  }
}

email MarketingMail = Email {
  database: Store
  smtp: SmtpConfig {
    host: "mail.example.com"
    port: 25
    username: "marketing@example.com"
    password: "hunter2"
    tls: false
  }
}

fn welcome(addr: String, name: String) -> Unit requires [emailCap] =
  Email.send AppMail {
    to: addr
    subject: "Welcome, ${name}"
    body: RichBody "Hello ${name}" "<h1>Hello ${name}</h1>"
  }

fn notify(addr: String, message: String) -> Unit requires [emailCap] =
  Email.send MarketingMail {
    to: addr
    subject: "Notice"
    body: TextBody message
  }

fn announce(addr: String, html: String) -> Unit requires [emailCap] =
  let _ = notify addr "an announcement is coming"
  Email.send AppMail {
    to: addr
    subject: "Announcement"
    body: HtmlBody html
  }

fn bodyKind(body: EmailBody) -> String =
  case body of
    TextBody t -> "text:${t}"
    HtmlBody h -> "html:${h}"
    RichBody t h -> "rich:${t}|${h}"

fn startMail() -> Unit requires [emailCap] =
  startEmailWorker AppMail

test "a body carries the half its variant names" {
  expect bodyKind (TextBody "plain") == "text:plain"
  expect bodyKind (HtmlBody "<b>x</b>") == "html:<b>x</b>"
  expect bodyKind (RichBody "plain" "<b>x</b>") == "rich:plain|<b>x</b>"
}

test "sending enqueues against every declared email" requires [emailCap] {
  let _ = welcome "ada@example.com" "Ada"
  let _ = notify "grace@example.com" "hello"
  let _ = announce "ada@example.com" "<p>news</p>"
  expect bodyKind (TextBody "sent") == "text:sent"
}
|}

let test_email_with_go () =
  let emitted = emit_ok "<go-email>" email_source in
  let module_go = artifact "internal/teslmodgoemail/module.go" emitted in
  check bool "a declaration becomes one outbox" true
    (contains module_go "var AppMailOutbox = teslrt.NewOutbox(teslrt.SmtpSettings{");
  (* An `env` in the declaration is a READ at start-up, not a string baked in at build
     time: the variable belongs to the deployment. *)
  check bool "an env setting stays a read" true
    (contains module_go "teslrt.EnvString(\"TESL_GO_SMTP_HOST\", \"\")");
  check bool "and a literal setting stays a literal" true
    (contains module_go "\"mail.example.com\"");
  check bool "each declaration gets its own outbox" true
    (contains module_go "var MarketingMailOutbox = teslrt.NewOutbox(");
  (* Sending is ENQUEUEING against the named email's outbox. *)
  check bool "a send names its own outbox" true
    (contains module_go "teslrt.SendEmail(AppMailOutbox, addr, ");
  check bool "and a second email is a different one" true
    (contains module_go "teslrt.SendEmail(MarketingMailOutbox, addr, ");
  check bool "the worker runs against the same outbox" true
    (contains module_go "teslrt.StartEmailWorker(AppMailOutbox)");
  (* The body is the runtime ADT, so `RichBody` fills both halves and `HtmlBody` only the
     one it names — which is what decides whether the message is delivered as HTML. *)
  check bool "a rich body carries both halves" true
    (contains module_go "teslrt.EmailBody{Tag: teslrt.EmailBodyRich, Text: ");
  check bool "an HTML body carries only the HTML" true
    (contains module_go "teslrt.EmailBody{Tag: teslrt.EmailBodyHTML, HTML: html}");
  (* Per-test isolation: one block's outbox must not be another's, the same rule tables,
     queues and caches follow — on both backends (see the cache case). *)
  let tests_go = artifact "internal/teslmodgoemail/module_test.go" emitted in
  check bool "each test block starts from an empty outbox" true
    (contains tests_go "teslrt.ResetOutbox(AppMailOutbox)");
  (* `go test` RUNS the blocks: the variant-to-half mapping and three sends across two
     declared emails. *)
  gate_emitted "tesl-go-email" emitted

let go_corpus = [
  "example/learn/lesson00-hello-world.tesl";
  "example/learn/lesson03-records.tesl";
  "example/learn/lesson04-newtypes.tesl";
  "example/learn/lesson05-intro-to-proofs.tesl";
  "example/learn/lesson07-home.tesl";
  "example/learn/lesson39-case-where-guards.tesl";
  "example/learn/lesson45-tuples.tesl";
  "example/learn/lesson65-pipe-operators.tesl";
  "example/learn/lesson10-cross-parameter-proofs.tesl";
  "example/learn/lesson40-implicit-value-unwrapping.tesl";
  "example/learn/lesson44-multi-param-proofs.tesl";
  (* Reached by the fold slice: `foldr`, an unreachable private declaration (which the
     emitter used to refuse outright), a `let` before an under-constrained tail, and
     `List (List Int)` equality — whose comparator is the one that must be hoisted. *)
  "example/learn/lesson35-list-decomposition.tesl";
  (* First-class detached proofs: `establish` + `f <| value ::: pf`. *)
  "example/learn/lesson53-literal-parametrized-predicates.tesl";
  (* The compiler's own torture file: a three-module import CYCLE, a qualified-only
     `import Sandbox3` with qualified type references, proof decomposition
     (`let (v ::: pf) = y`), applied proof terms, and an `establish` returning
     `Maybe (Fact P)` whose Maybe is real control flow. *)
  "example/sandbox.tesl";
  "tests/multiparam_test.tesl";
  (* Outbound HTTP: the lesson is the docs-facing surface (four verbs, the response record,
     the stub double), and the stub suite adds the case the deadline exists for — a hung
     upstream INSIDE a worker, which must fail the job so retry and dead-lettering run. *)
  "example/learn/lesson58-httpclient.tesl";
  "tests/http-stub-tests.tesl";
  (* A repeated query parameter is LAST-wins, and a request body with no `codec` block decodes
     from the record spec alone. Both were emitted wrongly (the first value; a call to a decoder
     nobody wrote), and both are cheap to keep pinned end to end. *)
  "tests/query-parameters-tests.tesl";
  "tests/secret-inbound-tests.tesl";
  (* Four things at once, all of which were broken and are now pinned at RUNTIME: an api-test
     `headers { … }` modifier, an `auth` that verifies a MAC over the RAW body (the body must be
     read once and handed to both the auth and the decoder), `Tesl.Crypto`'s HMAC in both
     transports, and a stdlib check rejected inside an `auth` propagating as a 401 rather than
     panicking. *)
  "tests/webhook-signature-tests.tesl";
  (* A 200-element `List String` body decoded through `listCodec`, with a load test over it —
     the file whose p99 assertion is the regression guard for issue #80. *)
  "tests/issue-80-list-body-scaling-tests.tesl";
  (* Telemetry, an App that serves, and the metric instruments — the docs-facing shape of a
     program that reports signals and runs. *)
  "example/learn/lesson17-telemetry.tesl";
  (* The session transport end to end: the `__Host-` cookie shape, a sliding renewal, a handler
     that sets a cookie and then FAILS (no session may escape on a non-2xx answer), and a
     trapping auth block answering a SANITIZED 500 rather than leaking the trap text. *)
  "tests/session-cookie-tests.tesl";
  (* The load-test surface as the lessons teach it: an open-model rate, a seeded run, and a
     `backend: Postgres` declaration nothing connects to — which is exactly the shape that
     used to be refused outright.  It is the slowest file here (each block warms up until its
     p99 is steady, up to 30s, on either backend), and it is worth that: it is the one place
     the harness's own numbers are asserted end to end. *)
  "example/learn/lesson41-load-tests.tesl";
  (* The files the container/Either leaf wave unblocked, each pinned end to end: a Set
     check-leaf lesson, two review suites whose checks are written as CONJUNCTIONS
     (`List.allCheck (a && b) xs`), and the delete/empty-container suite. *)
  "example/learn/lesson30-forall-set-proofs.tesl";
  "tests/critical-review61-tests.tesl";
  "tests/critical-review64-tests.tesl";
  "tests/stdlib-delete-tests.tesl";
  (* The recursive-ADT files: an arithmetic `Expr` interpreter and a binary `Tree`, both
     walked recursively and compared structurally. *)
  "tests/critical-review-26-tests.tesl";
  "tests/critical-review62-tests.tesl";
  (* The nested-pattern files: the lesson that teaches the form, a generic recursive tree,
     and a review suite that mixes nested arms with flat ones. *)
  "example/learn/lesson50-nested-constructor-patterns.tesl";
  "tests/critical-review-51-tests.tesl";
  "tests/critical-review63-tests.tesl";
  (* The UUID lesson: generation under the capability, and validation as a check. *)
  "example/learn/lesson56-uuid.tesl";
  (* The cache files: the lesson that teaches the surface, and the suite that pins the
     operations one by one. *)
  "example/learn/lesson59-cache.tesl";
  "tests/cache-tests.tesl";
  (* The email files: the lesson, the suite that pins the declaration and the send shapes,
     and a sessions lesson that was blocked on nothing but the `email` declaration. *)
  "example/learn/lesson60-email.tesl";
  "tests/email-tests.tesl";
  "example/learn/lesson76-sessions.tesl";
  (* A `fail` in a plain `fn` (`Nothing -> fail 404 "task not found"`), which is the shape
     every db-lookup helper in the corpus has. *)
  "example/learn/lesson20-named-db-results.tesl";
  (* The Kanel application: three modules of a real multi-module program, reached by the
     transaction slice.  Between them they carry a `transaction` block grouping writes, a
     multi-line `update … set …` in a `fn` body, an imported ADT used as a record field
     type, and a codec declared in another module — each of which was its own refusal. *)
  "example/kanel/KanelOrg.tesl";
  "example/kanel/KanelBilling.tesl";
  "example/kanel/KanelIssues.tesl";
  (* SSE: a broadcast channel keyed on a literal, a per-entity channel keyed on a path
     segment, an ADT-variant payload published from a worker, and a path built out of a
     previous response's body. *)
  "tests/sse-literal-subscribe-key-tests.tesl";
  "tests/publish-record-payload-tests.tesl";
  "example/learn/lesson33-sse-and-queue-tests.tesl";
  "tests/api-test-computed-path-tests.tesl";
  (* Property tests: the lesson that teaches them (generators, `where`, custom `via`) and a
     suite whose properties run beside ordinary SQL assertions. *)
  "example/learn/lesson14-test-blocks.tesl";
  "tests/sql-clause-placement-tests.tesl";
  (* Money and Units: exact minor units with half-even rounding at every edge, the ISO
     currency table, money PER quantity, and the dimensioned-quantity algebra. *)
  "tests/money-tests.tesl";
  "tests/units-tests.tesl";
  "example/learn/lesson71-money.tesl";
  "example/learn/lesson72-units.tesl";
  "tests/memory-backend-regressions.tesl";
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

(* ── `Tesl.Agent` ────────────────────────────────────────────────────────────
   The whole mock-driven surface in one module: the two test doubles, the tool-calling
   loop, a hand-written tool and one derived by `asTool`, a dispatch the program partially
   applies, typed structured output with a retry, multi-turn conversation with its string
   round-trip, both streaming entry points, and a top-level `agent` declaration whose
   provider reads the environment.

   Nothing here reaches a network: every call is scripted, which is what lets the same
   source run under the Racket oracle beside it. *)
let agent_source = {|module GoAgent exposing [askOnce, plannedReply]

import Tesl.Prelude exposing [Bool(..), Int, String, List, Unit]
import Tesl.Json exposing [stringCodec, intCodec]
import Tesl.String exposing [String.concat, String.contains]
import Tesl.Env exposing [envRead, requireEnv]
import Tesl.Agent exposing [
  aiProvider,
  Agent,
  LlmProvider,
  AgentReply,
  Tool,
  ToolStep,
  Conversation,
  ConversationTurn,
  anthropic,
  openai,
  mistral,
  local,
  mockProvider,
  mockToolProvider,
  toolUseStep,
  textStep,
  tool,
  asTool,
  ask,
  askReply,
  askWith,
  replyText,
  replyTokens,
  replyToolCalls,
  decodeAs,
  askFor,
  newConversation,
  conversationFrom,
  converse,
  converseStreaming,
  turnReply,
  turnConversation,
  conversationJson,
  conversationLength,
  agentRun,
]

capability goAi implies aiProvider

record CityArgs {
  city: String
}

codec CityArgs {
  toJson_forbidden
  fromJson [
    {
      city <- "city" with_codec stringCodec
    }
  ]
}

record Verdict {
  label: String
  score: Int
}

codec Verdict {
  toJson_forbidden
  fromJson [
    {
      label <- "label" with_codec stringCodec
      score <- "score" with_codec intCodec
    }
  ]
}

fn validateCity(argsJson: String) -> CityArgs =
  decodeAs "CityArgs" argsJson

fn reportCity(args: CityArgs) -> String =
  String.concat "weather in " args.city

# A dispatch the program partially applies: the model chooses the city, the
# caller chooses which region the answer is for.
fn reportCityIn(region: String, args: CityArgs) -> String =
  String.concat (String.concat region ": ") args.city

fn decodeVerdict(j: String) -> Verdict =
  decodeAs "Verdict" j

# A plain typed function wrapped by `asTool`: two parameters of different types,
# so the derived schema and the derived decode both carry more than one shape.
fn bookTable(restaurant: String, guests: Int) -> String =
  String.concat "booked " restaurant

# A publisher for the streaming entry points.
fn dropEvent(event: String) -> Unit =
  Unit

# The top-level declaration, with a REAL provider whose key comes from the
# environment. Every test below overrides the provider, so nothing here reads it.
agent Assistant requires [envRead] = Agent {
  provider: anthropic (requireEnv "TESL_GO_AGENT_KEY") "claude-opus-5"
  systemPrompt: "You are a concierge."
  maxTokens: 256
  tools: [asTool bookTable]
}

fn askOnce(prompt: String) -> String requires [goAi] =
  let agent = Agent { provider: mockProvider ["one reply"], systemPrompt: "x", maxTokens: 32, tools: [] }
  ask agent prompt

fn plannedReply() -> String requires [goAi] =
  replyText (askWith Assistant "plan" (mockProvider ["from the override"]))

test "ask walks the mock script by call index" requires [goAi] {
  let agent = Agent { provider: mockProvider ["first", "second"], systemPrompt: "x", maxTokens: 32, tools: [] }
  expect (ask agent "a") == "first"
  expect (ask agent "b") == "second"
  expect (askOnce "hi") == "one reply"
}

test "a declared agent keeps its own tools while the provider is overridden" requires [goAi] {
  expect (plannedReply ()) == "from the override"
  let call = toolUseStep "bookTable" "c1" "{\"restaurant\":\"Chez Tesl\",\"guests\":4}"
  let final = textStep "All set."
  let reply = askWith Assistant "book it" (mockToolProvider [call, final])
  expect (replyText reply) == "All set."
  expect (replyToolCalls reply) == 1
}

test "a hand-written tool dispatches with the validated argument" requires [goAi] {
  let cityTool = tool "weather" "Look up the weather" "{\"type\":\"object\"}" validateCity reportCity
  let call = toolUseStep "weather" "c1" "{\"city\":\"Malmo\"}"
  let reply = askReply (Agent {
    provider: mockToolProvider [call, textStep "It is sunny."]
    systemPrompt: "x"
    maxTokens: 64
    tools: [cityTool]
  }) "weather?"
  expect (replyText reply) == "It is sunny."
  expect (replyToolCalls reply) == 1
  expect (replyTokens reply) == 4
}

test "a partially applied dispatch captures what the model may not choose" requires [goAi] {
  let cityTool = tool "weather" "Look up the weather" "{}" validateCity (reportCityIn "north")
  let call = toolUseStep "weather" "c1" "{\"city\":\"Malmo\"}"
  let reply = askReply (Agent {
    provider: mockToolProvider [call, textStep "done"]
    systemPrompt: "x"
    maxTokens: 64
    tools: [cityTool]
  }) "weather?"
  expect (replyText reply) == "done"
  expect (replyToolCalls reply) == 1
}

test "malformed tool arguments keep the loop running" requires [goAi] {
  let cityTool = tool "weather" "Look up the weather" "{}" validateCity reportCity
  let call = toolUseStep "weather" "c1" "{\"wrong\":\"field\"}"
  let reply = askReply (Agent {
    provider: mockToolProvider [call, textStep "I could not look that up."]
    systemPrompt: "x"
    maxTokens: 64
    tools: [cityTool]
  }) "weather?"
  expect (replyText reply) == "I could not look that up."
  expect (replyToolCalls reply) == 1
}

test "askFor decodes, and retries once when the first reply does not" requires [goAi] {
  let good = Agent { provider: mockProvider ["{\"label\":\"ok\",\"score\":42}"], systemPrompt: "x", maxTokens: 32, tools: [] }
  let first = askFor good "judge" decodeVerdict 2
  expect first.label == "ok"
  expect first.score == 42
  let retried = Agent { provider: mockProvider ["not json", "{\"label\":\"recovered\",\"score\":7}"], systemPrompt: "x", maxTokens: 32, tools: [] }
  let second = askFor retried "judge" decodeVerdict 2
  expect second.label == "recovered"
  expect second.score == 7
}

test "converse threads the transcript and round-trips through a String" requires [goAi] {
  let agent = Agent { provider: mockProvider ["reply one", "reply two"], systemPrompt: "x", maxTokens: 32, tools: [] }
  let turn1 = converse (newConversation agent) "first question"
  expect (replyText (turnReply turn1)) == "reply one"
  let conv1 = turnConversation turn1
  expect (conversationLength conv1) == 2
  let saved = conversationJson conv1
  expect (String.contains saved "first question")
  expect (String.contains saved "reply one")
  let reloaded = conversationFrom agent saved
  expect (conversationLength reloaded) == 2
  let turn2 = converse reloaded "second question"
  expect (replyText (turnReply turn2)) == "reply two"
  expect (conversationLength (turnConversation turn2)) == 4
}

test "the streaming entry points answer the same value as the blocking ones" requires [goAi] {
  let agent = Agent { provider: mockProvider ["streamed"], systemPrompt: "x", maxTokens: 32, tools: [] }
  let turn = converseStreaming (newConversation agent) "hi" dropEvent
  expect (replyText (turnReply turn)) == "streamed"
  let runner = Agent { provider: mockProvider ["ran"], systemPrompt: "x", maxTokens: 32, tools: [] }
  expect (replyText (agentRun runner "go" dropEvent)) == "ran"
  let inline = Agent { provider: mockProvider ["lambda"], systemPrompt: "x", maxTokens: 32, tools: [] }
  let lambdaTurn = converseStreaming (newConversation inline) "hi" (fn(event: String) -> dropEvent event)
  expect (replyText (turnReply lambdaTurn)) == "lambda"
}

test "every provider constructor builds a usable value" requires [goAi, envRead] {
  let a = Agent { provider: anthropic "k" "m", systemPrompt: "x", maxTokens: 8, tools: [] }
  let b = Agent { provider: openai "k" "m", systemPrompt: "x", maxTokens: 8, tools: [] }
  let c = Agent { provider: mistral "k" "m", systemPrompt: "x", maxTokens: 8, tools: [] }
  let d = Agent { provider: local "http://127.0.0.1:11434/v1/chat/completions" "m", systemPrompt: "x", maxTokens: 8, tools: [] }
  expect (replyText (askWith a "hi" (mockProvider ["a"]))) == "a"
  expect (replyText (askWith b "hi" (mockProvider ["b"]))) == "b"
  expect (replyText (askWith c "hi" (mockProvider ["c"]))) == "c"
  expect (replyText (askWith d "hi" (mockProvider ["d"]))) == "d"
}
|}

let test_agent_with_go () =
  let emitted = match Compile.compile_go_source "<go-agent>" agent_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "agent compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgoagent/module.go" emitted in
  let tests_go = artifact "internal/teslmodgoagent/module_test.go" emitted in
  (* The declaration is a package-level value whose PROVIDER is deferred: its
     `requireEnv` runs on the first provider call, not when the program loads. *)
  check bool "a declared agent is a package-level value" true
    (contains module_go "var Assistant = teslrt.Agent{Provider: teslrt.DeferredProvider(teslProvider1)");
  check bool "the provider builder is a named function, not an inline literal" true
    (contains module_go
       "func teslProvider1() teslrt.LlmProvider {\n\treturn teslrt.AnthropicProvider(teslrt.RequireEnv(\"TESL_GO_AGENT_KEY\"), \"claude-opus-5\")");
  (* `asTool` derives the schema from the parameter list, and the argument reader from each
     parameter's type — a String and an Int read differently. *)
  check bool "the derived schema names both parameters with their JSON types" true
    (contains module_go
       "{\\\"type\\\":\\\"object\\\",\\\"properties\\\":{\\\"restaurant\\\":{\\\"type\\\":\\\"string\\\"},\\\"guests\\\":{\\\"type\\\":\\\"integer\\\"}},\\\"required\\\":[\\\"restaurant\\\",\\\"guests\\\"]}");
  check bool "the derived decode reads each argument by its own type" true
    (contains module_go
       "return []any{teslrt.ToolArgString(teslFields, \"restaurant\"), teslrt.ToolArgInt(teslFields, \"guests\")}");
  check bool "the derived dispatch asserts back to the declared types" true
    (contains module_go "return bookTable(teslArgs[0].(string), teslArgs[1].(teslrt.Int))");
  (* A tool function wired in ONLY by the declaration is reached through it, so it needs no
     keep-alive reference. *)
  check bool "an agent declaration counts as a use of its tool functions" false
    (contains module_go "var _ = bookTable");
  (* `decodeAs` resolves its decoder at compile time from the literal type name. *)
  check bool "decodeAs goes through the type's own codec" true
    (contains module_go "teslrt.DecodeAs(\"CityArgs\", argsJson, DecodeCityArgsJSON)");
  (* A partially applied dispatch keeps the captured argument out of the model's reach. *)
  check bool "a captured dispatch argument is bound by the runtime combinator" true
    (contains tests_go "teslrt.ToolDispatchWith(reportCityIn, \"north\")");
  check bool "a named publisher is passed straight through" true
    (contains tests_go "teslrt.AgentRun(runner, \"go\", dropEvent)");
  check bool "a lambda publisher is the ordinary lambda emission" true
    (contains tests_go "teslrt.ConverseStreaming(teslrt.NewConversation(inline), \"hi\", func(event string) struct{} {");
  (* The agent SPEC is the one Tesl.Agent type with fields, so it is a keyed literal. *)
  check bool "an inline agent is a keyed struct literal" true
    (contains tests_go "teslrt.Agent{Provider: teslrt.MockProvider([]string{\"first\", \"second\"})");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-agent" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)
  end

(* The `Tesl.Agent` forms the GO BACKEND refuses, each with the reason it refuses them.
   Most of the surface's limits are the CHECKER's and are stronger for it — a `decodeAs`
   whose type has no codec, a non-literal type name, and `asTool` applied to anything but a
   bare reference are all T001s that never reach an emitter, and were verified to be so
   while this was written.  What is left here is what only the Go backend can decide. *)
let test_agent_limits_fail_closed () =
  let header = {|module GoAgentLimit exposing []
import Tesl.Prelude exposing [Int, String, List, Unit]
import Tesl.Agent exposing [aiProvider, Agent, Tool, tool, asTool, mockProvider]

capability limitAi implies aiProvider

fn plainText(v: String) -> String = v

fn threeArgs(a: String, b: String, c: String) -> String = a

|} in
  let cases = [
    (* A tool_result is text the model reads, so a tool function has to answer one.  The
       checker allows any return type here; only the emitter knows there is nothing to put
       in the result. *)
    "a String result",
    {|fn counts(n: Int) -> Int = n
fn wireIt() -> List Tool = [asTool counts]
|},
    "needs the function to answer a String";

    (* Go can pass a named function as a value; it cannot pass a Tesl lambda where the
       runtime expects one, because a lambda has no name to reference. *)
    "a named validator",
    {|fn wireIt() -> Tool = tool "n" "d" "{}" (fn(s: String) -> s) plainText
|},
    "a tool validator must be a named function";

    (* The captured half of a partially applied dispatch is bound by one runtime
       combinator, which takes exactly one value. *)
    "one captured argument",
    {|fn wireIt() -> Tool = tool "n" "d" "{}" plainText (threeArgs "a" "b")
|},
    "partially applied to ONE captured argument";
  ] in
  List.iter (fun (what, body, expected) ->
    match Compile.compile_go_source "<go-agent-limit>" (header ^ body) with
    | Compile.GoSuccess _ -> failf "%s: emitted instead of failing closed" what
    | Compile.GoFailure diagnostics ->
      check bool what true
        (List.exists (fun (d : Compile.diagnostic) -> contains d.message expected)
           diagnostics)) cases

(* ── `serverTools` / `humanActions` ──────────────────────────────────────────
   A server whose endpoints become agent tools, and the complement it holds back for the
   human.  The five endpoints cover what an endpoint tool has to carry: no arguments, a
   codec-decoded body with a `via` check, a capture with a capturer's check, a handler that
   rejects, and one gated behind a second fact — so the same source exercises inclusion (a
   plain user gets four tools, an admin five), the decode path, and every failure the loop
   must survive rather than crash on. *)
let endpoint_tools_source = {|module GoEndpointTools exposing [NotesServer, User, Authenticated, Admin, mkUser, mkAdmin]

import Tesl.Prelude exposing [Int, String, Bool, List]
import Tesl.Json exposing [stringCodec]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.String exposing [String.concat, String.length, String.startsWith, String.contains]
import Tesl.List exposing [List.length, List.append]
import Tesl.Agent exposing [
  aiProvider,
  Agent,
  Tool,
  serverTools,
  humanActions,
  asTool,
  mockToolProvider,
  toolUseStep,
  textStep,
  askWith,
  replyText,
  replyToolCalls,
]

capability notesBot implies aiProvider

record User {
  id: String
  role: String
}

fact Authenticated (u: User)
fact Admin (u: User)
fact NoteId (noteId: String)
fact TextSafe (text: String)

auth cookieAuth(request: HttpRequest) -> u: User ::: Authenticated u =
  case Dict.lookup "user" request.cookies of
    Something userId -> ok (User { id: userId, role: "user" }) ::: Authenticated u
    Nothing -> fail 401 "Missing user cookie"

auth adminAuth(request: HttpRequest) -> u: User ::: Authenticated u && Admin u =
  case Dict.lookup "admin" request.cookies of
    Something userId -> ok (User { id: userId, role: "admin" }) ::: Authenticated u && Admin u
    Nothing -> fail 401 "Missing admin cookie"

check isNoteId(noteId: String) -> noteId: String ::: NoteId noteId =
  if String.startsWith noteId "note-" then
    ok noteId ::: NoteId noteId
  else
    fail 400 "Malformed note id"

capturer noteIdCapture: String ::: NoteId noteId using stringCodec via isNoteId

check isSafeText(text: String) -> text: String ::: TextSafe text =
  if String.length text <= 20 then
    ok text ::: TextSafe text
  else
    fail 400 "Text too long"

record NewNote {
  text: String ::: TextSafe text
}

codec NewNote {
  toJson_forbidden
  fromJson [
    {
      text <- "text" with_codec stringCodec via isSafeText
    }
  ]
}

# Greet the authenticated user by id.
handler get greet(u: User ::: Authenticated u) -> String =
  String.concat "hello " u.id

# Store a validated note for the authenticated user.
handler post createNote(u: User ::: Authenticated u, note: NewNote) -> String =
  String.concat (String.concat u.id ":") note.text

# Read one note by its id.
handler get getNote(u: User ::: Authenticated u, noteId: String ::: NoteId noteId) -> String =
  String.concat "note " noteId

# Refuse for a blocked user.
handler get guarded(u: User ::: Authenticated u) -> String =
  if u.id == "blocked" then
    fail 403 "blocked user"
  else
    "ok"

# Wipe everything. Admin only.
handler post adminWipe(u: User ::: Authenticated u && Admin u) -> String =
  "wiped"

api NotesApi {
  get "/greet"
    auth u: User ::: Authenticated u via cookieAuth
    -> String

  post "/notes"
    auth u: User ::: Authenticated u via cookieAuth
    body note: NewNote
    -> String

  get "/notes/:noteId"
    auth u: User ::: Authenticated u via cookieAuth
    capture noteId: String ::: NoteId noteId via noteIdCapture
    -> String

  get "/guarded"
    auth u: User ::: Authenticated u via cookieAuth
    -> String

  post "/admin/wipe"
    auth u: User ::: Authenticated u && Admin u via adminAuth
    -> String
}

server NotesServer for NotesApi {
  greet
  createNote
  getNote
  guarded
  adminWipe
}

check mkUser(u: User) -> u: User ::: Authenticated u =
  ok u ::: Authenticated u

check mkAdmin(u: User) -> u: User ::: Authenticated u && Admin u =
  ok u ::: Authenticated u && Admin u

# A plain function alongside the endpoint tools, to prove the two kinds compose.
fn summarize(text: String) -> String =
  String.concat "summary of " text

fn plainAgent(u: User ::: Authenticated u) -> Agent =
  Agent {
    provider: mockToolProvider []
    systemPrompt: "You manage the user's notes."
    maxTokens: 256
    tools: List.append (serverTools NotesServer u) (humanActions NotesServer u)
  }

fn adminAgent(u: User ::: Authenticated u && Admin u) -> Agent =
  Agent {
    provider: mockToolProvider []
    systemPrompt: "You administer the notes service."
    maxTokens: 256
    tools: List.append (serverTools NotesServer u) [asTool summarize]
  }

test "the two sets partition the server's endpoints at each call site" {
  let raw = User { id: "alice", role: "user" }
  let user = check mkUser raw
  expect (List.length (serverTools NotesServer user)) == 4
  expect (List.length (humanActions NotesServer user)) == 1
  let rawAdmin = User { id: "root", role: "admin" }
  let admin = check mkAdmin rawAdmin
  expect (List.length (serverTools NotesServer admin)) == 5
  expect (List.length (humanActions NotesServer admin)) == 0
}

test "an endpoint tool dispatches its handler with the authenticated user" requires [notesBot] {
  let raw = User { id: "alice", role: "user" }
  let user = check mkUser raw
  let reply = askWith (plainAgent user) "greet me"
    (mockToolProvider [toolUseStep "greet" "c1" "{}", textStep "Greeted you."])
  expect (replyText reply) == "Greeted you."
  expect (replyToolCalls reply) == 1
}

test "a body argument decodes through the endpoint's own codec and via-check" requires [notesBot] {
  let raw = User { id: "alice", role: "user" }
  let user = check mkUser raw
  let reply = askWith (plainAgent user) "note"
    (mockToolProvider [toolUseStep "createNote" "c1" "{\"note\":{\"text\":\"buy milk\"}}", textStep "Saved."])
  expect (replyText reply) == "Saved."
  expect (replyToolCalls reply) == 1
}

test "a body that fails the via-check is an is_error result, not a crash" requires [notesBot] {
  let raw = User { id: "alice", role: "user" }
  let user = check mkUser raw
  let reply = askWith (plainAgent user) "note"
    (mockToolProvider [toolUseStep "createNote" "c1" "{\"note\":{\"text\":\"aaaaaaaaaaaaaaaaaaaaa\"}}", textStep "Too long."])
  expect (replyText reply) == "Too long."
  expect (replyToolCalls reply) == 1
}

test "a capture argument runs the capturer's check" requires [notesBot] {
  let raw = User { id: "alice", role: "user" }
  let user = check mkUser raw
  let reply = askWith (plainAgent user) "show it"
    (mockToolProvider [toolUseStep "getNote" "c1" "{\"noteId\":\"note-7\"}", textStep "Found it."])
  expect (replyText reply) == "Found it."
  expect (replyToolCalls reply) == 1
}

test "a capture the check rejects is an is_error result" requires [notesBot] {
  let raw = User { id: "alice", role: "user" }
  let user = check mkUser raw
  let reply = askWith (plainAgent user) "show it"
    (mockToolProvider [toolUseStep "getNote" "c1" "{\"noteId\":\"nope\"}", textStep "Bad id."])
  expect (replyText reply) == "Bad id."
  expect (replyToolCalls reply) == 1
}

test "a handler fail becomes an is_error result and the loop continues" requires [notesBot] {
  let rawBlocked = User { id: "blocked", role: "user" }
  let blocked = check mkUser rawBlocked
  let reply = askWith (plainAgent blocked) "do it"
    (mockToolProvider [toolUseStep "guarded" "c1" "{}", textStep "Not allowed."])
  expect (replyText reply) == "Not allowed."
  expect (replyToolCalls reply) == 1
}

test "a held-back action is inert: the handler never runs" requires [notesBot] {
  let raw = User { id: "alice", role: "user" }
  let user = check mkUser raw
  let reply = askWith (plainAgent user) "wipe it"
    (mockToolProvider [toolUseStep "adminWipe" "c1" "{}", textStep "Asked the human."])
  expect (replyText reply) == "Asked the human."
  expect (replyToolCalls reply) == 1
}

test "the admin-gated endpoint dispatches for an admin-proved user" requires [notesBot] {
  let rawAdmin = User { id: "root", role: "admin" }
  let admin = check mkAdmin rawAdmin
  let reply = askWith (adminAgent admin) "wipe it"
    (mockToolProvider [toolUseStep "adminWipe" "c1" "{}", textStep "Wiped."])
  expect (replyText reply) == "Wiped."
  expect (replyToolCalls reply) == 1
}

# An endpoint tool and an `asTool` function live in the same list, and the loop
# reaches both — the two kinds are the same Tool value by the time it runs.
test "endpoint tools compose with an asTool function in the same list" requires [notesBot] {
  let rawAdmin = User { id: "root", role: "admin" }
  let admin = check mkAdmin rawAdmin
  let reply = askWith (adminAgent admin) "summarize it"
    (mockToolProvider [toolUseStep "summarize" "c1" "{\"text\":\"the notes\"}", textStep "Summarized."])
  expect (replyText reply) == "Summarized."
  expect (replyToolCalls reply) == 1
}
|}

let test_endpoint_tools_with_go () =
  let emitted = match Compile.compile_go_source "<go-endpoint-tools>" endpoint_tools_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "endpoint-tools compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgoendpointtools/module.go" emitted in
  let tests_go = artifact "internal/teslmodgoendpointtools/module_test.go" emitted in
  (* The tool IS the endpoint: the same handler, bound to the same authenticated user. *)
  check bool "an endpoint tool binds the user to the handler" true
    (contains module_go "teslrt.ToolDispatchWith(teslEndpointCall");
  check bool "the dispatch calls the handler with the user first" true
    (contains module_go "(greet(teslUser)))");
  check bool "an argument-taking endpoint gets its arguments after the user" true
    (contains module_go "(createNote(teslUser, teslArgs[0].(NewNote))))");
  (* A rejection reaching a tool has no response to write, so it becomes the result text —
     with the status, which is what tells the model what went wrong. *)
  check bool "a handler rejection becomes the tool result" true
    (contains module_go "defer teslrt.ToolRejection()");
  (* Arguments go through the endpoint's OWN decode, so a tool argument cannot be validated
     more weakly than the HTTP boundary. *)
  check bool "a body argument decodes through the endpoint's codec" true
    (contains module_go "teslrt.ToolArgDecoded(teslFields, \"note\", DecodeNewNoteJSON)");
  check bool "a capture argument runs the capturer's check" true
    (contains module_go "teslrt.ToolChecked(\"noteId\", isNoteId(teslrt.ToolArgString(teslFields, \"noteId\")))");
  (* An endpoint taking nothing still requires an object, but binds no fields — a bound and
     unused variable does not compile. *)
  check bool "a no-argument endpoint validates without binding fields" true
    (contains module_go "_ = teslrt.ToolArguments(teslArgs)\n\treturn []any{}");
  (* The held-back set takes the server NAME and nothing else: with no route table and no
     handler in reach, an inert tool cannot become a call. *)
  check bool "a human action carries only the server name" true
    (contains module_go "teslrt.HumanActions(\"NotesServer\", []teslrt.HumanActionSpec{");
  check bool "the held-back tool is the one the user's proof does not cover" true
    (contains module_go "teslrt.HumanActionOf(\"adminWipe\"");
  (* Inclusion is per call site, so the admin's list has the endpoint the plain user's
     does not — and no `humanActions` entry for it. *)
  check bool "the admin site includes the admin-gated endpoint" true
    (contains module_go "teslrt.ToolOf(\"adminWipe\"");
  (* An admin's proof covers every endpoint, so the complement at that site is empty —
     which is what makes the two sets a partition rather than two overlapping lists. *)
  check bool "the admin site holds nothing back" true
    (contains tests_go "teslrt.HumanActions(\"NotesServer\", []teslrt.HumanActionSpec{})");
  (* The derived schema is what reaches the model. *)
  check bool "the body schema comes from the type's codec" true
    (contains module_go
       "{\\\"type\\\":\\\"object\\\",\\\"properties\\\":{\\\"note\\\":{\\\"type\\\":\\\"object\\\",\\\"properties\\\":{\\\"text\\\":{\\\"type\\\":\\\"string\\\"}},\\\"required\\\":[\\\"text\\\"]}},\\\"required\\\":[\\\"note\\\"]}");
  (* A handler with a doc comment describes itself to the model; one without falls back to
     its method and path. *)
  check bool "the description is the handler's own doc comment" true
    (contains module_go "\"Greet the authenticated user by id.\"");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-endpoint-tools" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)
  end

(* ── `Tesl.Proxy` ────────────────────────────────────────────────────────────
   The authenticating-proxy edge binding: one check-shaped function and the fact only it
   can mint.  The FACT erases here like every other, so what the emitted code has to get
   right is the comparison — constant time, against the configured secret — and the shape
   that makes the fact worth having: the value `internalOnly` receives is the one the check
   handed back, so a binding that was never verified cannot reach it. *)
let proxy_source = {|module GoProxy exposing [internalOnly, edgeCall]

import Tesl.Prelude exposing [Bool, String]
import Tesl.String exposing [String.concat]
import Tesl.Crypto exposing [Secret]
import Tesl.Proxy exposing [ProxyBound, Proxy.verifyBinding]

# The shared secret the reverse proxy stamps every request with.
secret ProxySecret = String

# `internalOnly` DEMANDS `ProxyBound`, and nothing but the verification below can
# mint it — so a request that never passed the proxy cannot reach this function.
fn internalOnly(bound: String ::: ProxyBound bound) -> String =
  String.concat "internal for " bound

# The edge: verify the presented header against the configured secret, then use
# the value the check hands back — which is the one carrying the proof.
fn edgeCall(configured: Secret, presented: String) -> String =
  let bound = check Proxy.verifyBinding configured presented
  internalOnly bound

test "a matching binding reaches the internal function" {
  let configured = Secret "edge-secret"
  expect (edgeCall configured "edge-secret") == "internal for edge-secret"
}

test "a binding that does not match is refused" {
  let configured = Secret "edge-secret"
  expect expectFail (edgeCall configured "not-the-secret")
  expect expectFail (edgeCall configured "")
  expect expectFail (edgeCall configured "edge-secre")
  expect expectFail (edgeCall configured "edge-secrett")
  expect expectFail (edgeCall configured "EDGE-SECRET")
}
|}

let test_proxy_with_go () =
  let emitted = match Compile.compile_go_source "<go-proxy>" proxy_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "proxy compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgoproxy/module.go" emitted in
  check bool "the verification is the runtime's constant-time compare" true
    (contains module_go "teslrt.ProxyVerifyBinding(configured, presented)");
  (* The proof erases, so the parameter is a plain String — and the only thing that makes
     `internalOnly` unreachable without a verification is that the checker said so. *)
  check bool "the proof-demanding function takes the checked value" true
    (contains module_go "return InternalOnly(bound)");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-proxy" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)
  end

(* ── A check that answers a plain value, and the Float transcendentals ───────
   Two unrelated gaps that the same source pins, because the first was only VISIBLE once
   the second stopped refusing the file.

   A `check` whose declared return is a plain value — `-> Maybe (v: T ::: P v)`, where the
   proof rides inside the `Something` — emitted the bare value where its Go signature says
   `Check[T]`, which does not compile.  It was invisible because every corpus file with that
   shape also had a bare `Nothing` the emitter refused first.

   The transcendentals now use Go's `math` and diverge from Racket by up to an ulp, which is
   the maintainer's recorded call (2026-08-12); only the exact points are asserted here. *)
let float_check_source = {|module GoFloatCheck exposing [maybePositive, useMaybePositive, bothProofs]

import Tesl.Prelude exposing [Int, Bool(..)]
import Tesl.Float exposing [
  Float,
  Float.sin,
  Float.cos,
  Float.tan,
  Float.exp,
  Float.log,
  Float.round,
  Float.isNaN,
  Float.isInfinite,
  Float.infinity,
  Float.nan,
]
import Tesl.Maybe exposing [Maybe(..)]

fact IsPositive (n: Int)
fact IsSmall (n: Int)

# A `check` whose declared return is a plain VALUE: the proof rides inside the
# `Something`, so the body has no `ok` to write and one branch is a bare `Nothing`
# that only the return type can give an element type.
check maybePositive(n: Int) -> Maybe (v: Int ::: IsPositive v) =
  if n > 0 then
    Something n
  else
    Nothing

fn useMaybePositive(raw: Int) -> Int =
  let m = check maybePositive raw
  case m of
    Nothing -> 0
    Something v -> v + 1

check checkPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "must be positive"

check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "must be small"

# A let-bound COMBINED check inside a check: the rejection must PROPAGATE with its
# own status, not trap.
check bothProofs(n: Int) -> n: Int ::: IsPositive n && IsSmall n =
  let validated = check (checkPositive && checkSmall) n
  validated

test "a check returning a plain value accepts it" {
  expect useMaybePositive 5 == 6
  expect useMaybePositive 0 == 0
}

# The comparison takes its type from whichever side has one, so a bare `Nothing`
# works on either side of `==` AND of `!=`.
test "a bare Nothing compares on both sides of both operators" {
  let some = check maybePositive 5
  let none = check maybePositive 0
  expect some != Nothing
  expect none == Nothing
  expect Nothing != some
  expect Nothing == none
}

test "a let-bound combined check propagates each conjunct's rejection" {
  let good = 50
  let accepted = check bothProofs good
  expect accepted == 50
  let notPositive = 0
  let tooBig = 100
  expectFail check bothProofs notPositive
  expectFail check bothProofs tooBig
}

# The transcendentals. Only inputs where both backends are exact are asserted:
# sin/cos/tan/exp diverge from Racket by up to an ulp elsewhere, which is recorded
# rather than pinned.
test "the transcendentals answer their exact values" {
  expect Float.sin 0.0 == 0.0
  expect Float.cos 0.0 == 1.0
  expect Float.tan 0.0 == 0.0
  expect Float.exp 0.0 == 1.0
  expect Float.log 1.0 == 0.0
  expect Float.round (Float.exp 1.0 * 1000.0) == 2718
  expect Float.round (Float.sin 1.0 * 1000.0) == 841
}

test "the two Float values that are not literals" {
  expect Float.isInfinite Float.infinity
  expect Float.isNaN Float.nan
  expect Float.isInfinite Float.nan == False
}
|}

let test_float_check_with_go () =
  let emitted = match Compile.compile_go_source "<go-float-check>" float_check_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "float/check compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgofloatcheck/module.go" emitted in
  (* The tail is an ACCEPTANCE, and it has to say so — the bare value did not compile. *)
  check bool "a plain-value check tail is accepted on the way out" true
    (contains module_go "return teslrt.Accept(teslrt.Maybe[teslrt.Int]{Tag: teslrt.MaybeNothing})");
  (* A let-bound COMBINED check propagates, exactly as the single-check form does: a
     rejection carries its own status out rather than trapping. *)
  check bool "a let-bound combined check propagates its rejection" true
    (contains module_go "return teslrt.Reject[teslrt.Int](teslDelegated1.Status(), teslDelegated1.Message())");
  check bool "the combined check is the hoisted sequencing helper" true
    (contains module_go "teslDelegated1 := teslCheckAll");
  (* Go has no literal for either, so they are functions rather than package variables. *)
  check bool "the two unwritable Float values are calls" true
    (contains module_go "teslrt.FloatInfinity()" || contains
       (artifact "internal/teslmodgofloatcheck/module_test.go" emitted) "teslrt.FloatInfinity()");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-float-check" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)
  end

(* ── Partial application, and a newtype named as a codec ─────────────────────
   `add 1` is a function of the remaining argument, and it is CURRIED: `blend 1` answers a
   function of `b` that answers a function of `c`, which is the surface's shape and the
   Racket runtime's — a flat `withA 2 3` is an arity error there, so it is refused here.

   The codec half is a separate bug the same file pins: `with_codec AcctId` names a NEWTYPE
   rather than a codec, and the emitter referenced an `EncodeAcctIdJSON` nobody writes.  A
   newtype has no codec of its own; the spelling means "through the base", and the two
   endpoints below assert that against each other. *)
let partial_source = {|module GoPartial exposing [add, blend, label, AcctServer]

import Tesl.Prelude exposing [Int, String, Bool(..), List]
import Tesl.Json exposing [stringCodec, intCodec]
import Tesl.ApiTest exposing [statusOk]
import Tesl.List exposing [List.map, List.length]

fn add(x: Int, y: Int) -> Int =
  x + y

fn blend(a: Int, b: Int, c: Int) -> Int =
  a + b * c

fn label(prefix: String, separator: String, body: String) -> String =
  "${prefix}${separator}${body}"

fn applyTwice(f: Int -> Int, n: Int) -> Int =
  f (f n)

# A newtype named as the codec: `with_codec AcctId` means "through the base", the
# same wire value `with_codec stringCodec` gives on the same field.
type AcctId = String

record Acct {
  id: AcctId
  count: Int
}

codec Acct {
  toJson {
    id -> "id" with_codec AcctId
    count -> "count" with_codec intCodec
  }
  fromJson [
    {
      id <- "id" with_codec AcctId
      count <- "count" with_codec intCodec
    }
  ]
}

# The other spelling, on a field of the same newtype: the two must agree.
record Plain {
  id: AcctId
}

codec Plain {
  toJson {
    id -> "id" with_codec stringCodec
  }
  fromJson [
    {
      id <- "id" with_codec stringCodec
    }
  ]
}

# The codec is reachable only across an HTTP boundary, which is also the place it
# matters: what a client receives.
handler get getAcct(id: String) -> Acct =
  Acct { id: AcctId id, count: 2 }

handler post echoAcct(body: Acct) -> Acct =
  Acct { id: body.id, count: body.count + 1 }

handler get getPlain(id: String) -> Plain =
  Plain { id: AcctId id }

api AcctApi {
  get "/accts/:id"
    capture id: String using stringCodec
    -> Acct

  post "/accts/echo"
    body body: Acct
    -> Acct

  get "/plain/:id"
    capture id: String using stringCodec
    -> Plain
}

server AcctServer for AcctApi {
  getAcct
  echoAcct
  getPlain
}

test "one of two arguments supplied" {
  let addOne = add 1
  expect addOne 4 == 5
  let subOne = add -1
  expect subOne 4 == 3
}

test "a partial application in argument position" {
  expect applyTwice (add 3) 1 == 7
}

test "a local function value reaches a higher-order leaf" {
  let addThree = add 3
  expect List.map addThree [1, 2, 3, 4] == [4, 5, 6, 7]
  expect List.length (List.map addThree []) == 0
}

# Partial application is CURRIED: `blend 1` is a function of `b` answering a
# function of `c`, applied one argument at a time on both backends.
test "one and two of three arguments supplied" {
  let withA = blend 1
  let thenB = withA 2
  expect thenB 3 == 7
  let withAB = blend 1 2
  expect withAB 3 == 7
  let greet = label "hello" ", "
  expect greet "world" == "hello, world"
}

# A newtype-typed field puts its PAYLOAD on the wire, not the wrapper — the wrapper
# marshals to an object, which is not what either backend sends.  `with_codec AcctId`
# names the NEWTYPE rather than a codec and means the same thing as the base codec,
# which is what the two endpoints below assert against each other.
api-test "a newtype field encodes as its payload, both spellings" for AcctServer requires [] {
  let named = get "/accts/a-1"
  expect statusOk named.status
  expect named.body.id == "a-1"
  expect named.body.count == 2
  let base = get "/plain/p-1"
  expect statusOk base.status
  expect base.body.id == "p-1"
}

api-test "a newtype field decodes back through the same spelling" for AcctServer requires [] {
  let echoed = post "/accts/echo" body { "id": "a-9", "count": 7 }
  expect statusOk echoed.status
  expect echoed.body.id == "a-9"
  expect echoed.body.count == 8
}
|}

let test_partial_with_go () =
  let emitted = match Compile.compile_go_source "<go-partial>" partial_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "partial-application compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgopartial/module.go" emitted in
  let tests_go = artifact "internal/teslmodgopartial/module_test.go" emitted in
  (* Go has no partial application, so the emitter goes through a runtime combinator rather
     than an inline closure — named, for the gofmt reason every hoisted helper is. *)
  check bool "one of two arguments is supplied by the runtime" true
    (contains tests_go "teslrt.Apply1Of2(Add, teslrt.FromInt64(1))");
  check bool "one of three is supplied the same way" true
    (contains tests_go "teslrt.Apply1Of3(Blend, teslrt.FromInt64(1))");
  check bool "two of three is its own combinator" true
    (contains tests_go "teslrt.Apply2Of3(Blend, teslrt.FromInt64(1), teslrt.FromInt64(2))");
  (* A partially applied value passed to a higher-order leaf is a LOCAL, not a declaration,
     so the callback is called through its own identifier. *)
  check bool "a local function value is called through its identifier" true
    (contains tests_go "addThree(Value2)");
  (* A newtype field puts its PAYLOAD on the wire under either spelling; the wrapper
     marshals to an object, which is what the client would otherwise have received. *)
  check bool "the newtype-named codec unwraps to the base" true
    (contains module_go "\"id\":    teslValue.Id.Value");
  check bool "the base-codec spelling unwraps identically" true
    (contains module_go "\"id\": teslValue.Id.Value");
  check bool "the newtype is rebuilt on the way back in" true
    (contains module_go "Acct{Id: AcctId{Value: teslFieldId}");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-partial" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)
  end

(* ── `formatTime` ────────────────────────────────────────────────────────────
   THE ONE SOURCE HERE WITH NO RACKET ORACLE, and the reason is the point: Racket's
   `formatTime` IGNORES its zone argument.  Its non-UTC branch sets `TZ` with `putenv` and
   calls `seconds->date`, which resolved the zone once at startup and does not read the
   variable again; and its "UTC" branch does not force UTC at all — it falls through to
   local time.  Measured here (2026-08-16): the same call answers 23:13 for an instant that
   is 22:13 UTC, for `"UTC"`, `"America/New_York"` and `"Asia/Tokyo"` alike.

   So a Racket service renders every timestamp in the SERVER's zone whatever the caller
   asked for — invisible on a UTC-configured host, an hour or thirteen wrong anywhere else.
   Go answers correctly, with the IANA database compiled in so the answer does not depend on
   the container either.  Asserting the two against each other would pin the bug. *)
let format_time_source = {|module GoFormatTime exposing [render]

import Tesl.Prelude exposing [Int, String, Bool(..)]
import Tesl.Time exposing [PosixMillis, Time.secondsToPosix, addMs, formatTime]

fn render(seconds: Int, zone: String, format: String) -> String =
  formatTime (Time.secondsToPosix seconds) zone format

test "the ISO shape, in UTC" {
  expect render 1699999999 "UTC" "%Y-%m-%dT%H:%M:%SZ" == "2023-11-14T22:13:19Z"
  expect render 0 "UTC" "%Y-%m-%dT%H:%M:%SZ" == "1970-01-01T00:00:00Z"
}

# A zone the host may not have installed: the database is compiled in, so the
# answer is the same wherever the binary runs.
test "a named IANA zone shifts the wall clock" {
  expect render 1699999999 "Europe/Stockholm" "%Y-%m-%d %H:%M:%S" == "2023-11-14 23:13:19"
  expect render 1699999999 "America/New_York" "%Y-%m-%d %H:%M:%S" == "2023-11-14 17:13:19"
  expect render 1699999999 "Asia/Tokyo" "%Y-%m-%d %H:%M:%S" == "2023-11-15 07:13:19"
}

# Summer time is a property of the INSTANT, not of the zone.
test "the offset follows daylight saving" {
  expect render 1699999999 "Europe/Stockholm" "%z" == "+0100"
  expect render 1689999999 "Europe/Stockholm" "%z" == "+0200"
  expect render 1699999999 "UTC" "%z" == "+0000"
}

test "milliseconds come from the instant, not the calendar" {
  let base = Time.secondsToPosix 1699999999
  expect formatTime (addMs base 250) "UTC" "%H:%M:%S.%3N" == "22:13:19.250"
  expect formatTime base "UTC" "%3N" == "000"
}

test "an unknown directive and a literal percent pass through" {
  expect render 0 "UTC" "100%% sure" == "100% sure"
  expect render 0 "UTC" "%Q" == "%Q"
  expect render 0 "UTC" "no directives here" == "no directives here"
}

# An unknown zone name is UTC rather than a trap: Racket answers the same when
# `TZ` names a zone the host has never heard of.
test "an unknown zone falls back to UTC" {
  expect render 1699999999 "Mars/Olympus_Mons" "%Y-%m-%dT%H:%M:%SZ" == "2023-11-14T22:13:19Z"
}
|}

let test_format_time_with_go () =
  let emitted = match Compile.compile_go_source "<go-format-time>" format_time_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "formatTime compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgoformattime/module.go" emitted in
  check bool "the zone and the format travel as written" true
    (contains module_go "teslrt.FormatTime(teslrt.SecondsToPosix(seconds), zone, format)");
  (* The database is compiled in, so `Europe/Stockholm` resolves in a container that has no
     /usr/share/zoneinfo — where the host-lookup version silently answers UTC instead. *)
  let runtime_go = artifact "internal/teslrt/timezone.go" emitted in
  check bool "the IANA database ships with it" true (contains runtime_go "_ \"time/tzdata\"");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-format-time" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)
  end

(* A program that formats no timestamps must not carry the 450 KB IANA database. *)
let test_timezone_data_ships_only_where_used () =
  let plain = {|module GoNoTime exposing [double]
import Tesl.Prelude exposing [Int]

fn double(n: Int) -> Int = n * 2
|} in
  match Compile.compile_go_source "<go-no-time>" plain with
  | Compile.GoFailure diagnostics ->
    failf "plain module failed: %s"
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  | Compile.GoSuccess artifacts ->
    check bool "no timezone runtime in a module that formats nothing" false
      (List.exists (fun (a : Emit_go.artifact) -> a.path = "internal/teslrt/timezone.go")
         artifacts)

(* ── What an empty container is, and what a seed block describes ─────────────
   Three shapes that all come down to "nothing here says what this holds".
   `Dict.fromList []` takes its key and value from the next line that uses the binding —
   one step, and only when the expression could not type by itself.  `Set.isEmpty
   Set.empty` needs no element at all: the answer is the same whatever the set holds, which
   is the relaxation `List.isEmpty []` already gets, while anything whose RESULT mentions
   the element still fails closed.  And an untyped api-test value where a String is wanted
   reads as the string it holds, the coercion `++` already applies to it.

   The seed block is the odd one out and the reason this source has an api-test: `seed {
   let _ = … }` is written as a discarding `let`, and what it describes is a STATEMENT — not
   an expression whose value is the binding it just discarded. *)
let inference_source = {|module GoInfer exposing [scoresOf, WidgetServer, seedWidgets]

import Tesl.Prelude exposing [Int, String, Bool(..), List]
import Tesl.Json exposing [stringCodec]
import Tesl.Dict exposing [Dict, Dict.fromList, Dict.size, Dict.insert, Dict.toList]
import Tesl.Set exposing [Set, Set.empty, Set.fromList, Set.isEmpty, Set.size, Set.insert]
import Tesl.String exposing [String.contains, String.concat]
import Tesl.List exposing [List.length]
import Tesl.Tuple exposing [Tuple2]
import Tesl.ApiTest exposing [statusOk]

fn scoresOf(raw: Dict String Int) -> Int =
  Dict.size raw

fn namesOf(raw: Set String) -> Int =
  Set.size raw

# `Dict.fromList []` carries no key or value type of its own; the LATER use is
# what says what it holds.
test "an empty container takes its type from a later use" {
  let raw = Dict.fromList []
  expect scoresOf raw == 0
  let names = Set.fromList []
  expect namesOf names == 0
}

# An element type nothing can observe: `isEmpty` and `size` answer the same
# whatever the container holds, so a bare empty one is answered rather than
# refused. Anything whose RESULT mentions the element still fails closed.
test "an unobservable element type is not a refusal" {
  expect Set.isEmpty Set.empty == True
  expect Set.size Set.empty == 0
}

test "a populated container still infers from its contents" {
  let scores = Dict.fromList [Tuple2 "a" 1, Tuple2 "b" 2]
  expect Dict.size scores == 2
  expect List.length (Dict.toList scores) == 2
  let names = Set.fromList ["x", "y", "x"]
  expect Set.size names == 2
}

# ── The api-test half: an untyped response value where a String is wanted ────

record Widget {
  id: String
  names: String
}

codec Widget {
  toJson {
    id -> "id" with_codec stringCodec
    names -> "names" with_codec stringCodec
  }
  fromJson [
    {
      id <- "id" with_codec stringCodec
      names <- "names" with_codec stringCodec
    }
  ]
}

fn seedWidgets() -> String =
  "seeded"

handler get getWidget(id: String) -> Widget =
  Widget { id: id, names: String.concat "alpha-" id }

api WidgetApi {
  get "/widgets/:id"
    capture id: String using stringCodec
    -> Widget
}

server WidgetServer for WidgetApi {
  getWidget
}

# `seed { let _ = … }` is written as a discarding `let`, and what it describes is
# a statement — not an expression whose value is the binding it just discarded.
api-test "an untyped response value reads as the string it holds" for WidgetServer requires [] {
  seed {
    let _ = seedWidgets()
  }

  let r = get "/widgets/three"
  expect statusOk r.status
  expect String.contains r.body.names "alpha-three" == True
  expect String.contains r.body.names "beta" == False
  expect String.concat "id=" r.body.id == "id=three"
}
|}

let test_inference_with_go () =
  let emitted = match Compile.compile_go_source "<go-infer>" inference_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "inference compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let tests_go = artifact "internal/teslmodgoinfer/module_test.go" emitted in
  (* The later use decides, so the empty dict is built at the type that use requires. *)
  check bool "an empty dict takes its key and value from a later use" true
    (contains tests_go "teslrt.DictFromList([]teslrt.Tuple2[string, teslrt.Int]{}");
  check bool "an empty set does too" true
    (contains tests_go "teslrt.SetFromList([]string{}");
  (* An unobservable element does not stop the call; the choice cannot change the answer. *)
  check bool "an unobservable element type is chosen rather than refused" true
    (contains tests_go "teslrt.SetIsEmpty(teslrt.SetEmpty[teslrt.Int]())");
  (* The untyped value reads as its string. *)
  check bool "an untyped response value is read as a string" true
    (contains tests_go "teslrt.StringContains(teslrt.JsonAsString(");
  (* The seed statement is a statement, not a closure returning the binding it discarded. *)
  check bool "a discarding seed let is emitted as a statement" true
    (contains tests_go "_ = SeedWidgets()");
  check bool "the seed block is not a closure returning `_`" false (contains tests_go "return _");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-infer" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)
  end

(* ── A newtype over a newtype, and two things a container does not observe ───
   `type Rank = Score` where `type Score = Int` nests in Go exactly as it does on Racket,
   and each layer compares through its payload — which is what "orderable transitively"
   means when it is emitted rather than asserted.

   `expectFail check (a && b) x` splits at the `check`, leaving the CONJUNCTION applied to
   the value: a shape nothing types on its own, since a check is not a function value.
   Rebuilding the application puts it back on the path that already knows what a combined
   check means.

   And `Dict.isEmpty Dict.empty` observes neither the key nor the value, so it is answered
   rather than refused — the same rule `List.isEmpty []` already has. *)
let ordered_newtype_source = {|module GoOrd exposing [Score, Rank, makeScore, promote, best]

import Tesl.Prelude exposing [Int, String, Bool(..), List]
import Tesl.Dict exposing [Dict, Dict.empty, Dict.isEmpty, Dict.size, Dict.insert]
import Tesl.Set exposing [Set, Set.empty, Set.isEmpty, Set.size]
import Tesl.String exposing [String.startsWith, String.endsWith]

fact IsA (s: String)
fact EndsB (s: String)

# A newtype over a newtype: ordering works transitively, because each layer
# compares through its payload.
type Score = Int
type Rank = Score

fn makeScore(n: Int) -> Score =
  Score n

fn promote(s: Score) -> Rank =
  Rank s

fn rankToInt(r: Rank) -> Int =
  r.value.value

# The DIRECT comparison, which is what a two-layer newtype has to support. It is
# not called from a test: the Racket runtime traps on it (`tesl-gt?: ordered
# comparison needs a number, got (newtype-value … Score)`) even though its own
# checker admits the type as transitively orderable, so running it here would
# pin that bug rather than this behaviour. The emitted shape is asserted instead.
fn best(a: Rank, b: Rank) -> Rank =
  if a > b then
    a
  else
    b

fn higherRank(a: Rank, b: Rank) -> Rank =
  if rankToInt a > rankToInt b then
    a
  else
    b

check startsA(s: String) -> s: String ::: IsA s =
  if String.startsWith s "A" then
    ok s ::: IsA s
  else
    fail 400 "must start with A"

check endsB(s: String) -> s: String ::: EndsB s =
  if String.endsWith s "B" then
    ok s ::: EndsB s
  else
    fail 400 "must end with B"

test "a newtype chain orders through its payload" {
  let low = promote (makeScore 3)
  let high = promote (makeScore 9)
  expect higherRank low high == high
  expect rankToInt low < rankToInt high
  expect low == promote (makeScore 3)
}

# `expectFail check (a && b) x` splits at the `check`, leaving the conjunction
# applied to the value — a shape nothing types on its own.
test "expectFail over a combined check reports each conjunct's rejection" {
  expectFail check (startsA && endsB) "XB"
  expectFail check (startsA && endsB) "AX"
  expectFail check (startsA && endsB) "XX"
  let good = check (startsA && endsB) "AB"
  expect good == "AB"
}

# Neither `isEmpty` nor `size` observes what the container holds, so an empty one
# is answered rather than refused.
test "an unobservable key or value is not a refusal" {
  expect Dict.isEmpty Dict.empty == True
  expect Dict.size Dict.empty == 0
  expect Set.isEmpty Set.empty == True
  expect Set.size Set.empty == 0
  let d = Dict.insert "x" 1 Dict.empty
  expect Dict.isEmpty d == False
  expect Dict.size d == 1
}
|}

let test_ordered_newtype_with_go () =
  let emitted = match Compile.compile_go_source "<go-ord>" ordered_newtype_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "ordered-newtype compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgoord/module.go" emitted in
  let tests_go = artifact "internal/teslmodgoord/module_test.go" emitted in
  (* The chain nests, and a comparison unwraps through BOTH layers.  The Racket runtime
     traps here — `tesl-gt?` unwraps one — which is why `best` is emitted but not run. *)
  check bool "a newtype over a newtype nests" true
    (contains module_go "type Rank struct {\n\tValue Score\n}");
  check bool "a comparison unwraps through both layers" true
    (contains module_go "teslrt.Compare(a.Value.Value, b.Value.Value) > 0");
  (* The combined check reaches its sequencing helper from `expectFail` too. *)
  check bool "expectFail over a combined check runs the sequencing helper" true
    (contains tests_go "teslCheckAll");
  (* Nothing observes the key or the value, so one is chosen and the call is emitted. *)
  check bool "an unobservable dict is instantiated rather than refused" true
    (contains tests_go "teslrt.DictIsEmpty(teslrt.DictEmpty[teslrt.Int, teslrt.Int]())");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-ord" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)
  end

(* ── The request boundary: captures, list bodies, chained checks ─────────────
   Five shapes that all meet at the edge of a request.

   An `intCodec` path capture is PARSED before anything looks at it, and a segment that is
   not an integer is a 400 rather than a 404: the route matched and the value in it did not.
   A LIST body is the JSON array itself, decoded element by element — through the element's
   own codec when it has one, which is a `Check` rather than an error and so goes through one
   adapter so a list of scalars and a list of records walk the same loop.  A queue's NAME is
   a TYPE, so `fn listDead(q: EmailQueue)` takes one as a value.  A check bound in a test
   binds its checked VALUE.  And a string literal inside an api-test is a template in EVERY
   position, including the right-hand side of a comparison.

   The chained `via` is the bug underneath: two checks on one codec field emitted the same
   result binder twice, which does not compile. *)
let boundary_source = {|module GoBoundary exposing [TaskServer, EmailQueue, listDead]

import Tesl.Prelude exposing [Int, String, Bool(..), List, Unit]
import Tesl.Json exposing [stringCodec, intCodec]
import Tesl.String exposing [String.length, String.startsWith, String.concat]
import Tesl.List exposing [List.length]
import Tesl.Int exposing [Int.toString]
import Tesl.UUID exposing [UUID.validate]
import Tesl.Database exposing [Database, Memory]
import Tesl.Queue exposing [Queue, QueueRetryStrategy, Fixed, queueRead, queueWrite, Job, FromQueue, deadJobs, DeadJob]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.ApiTest exposing [statusOk, statusClientError]

fact Positive (n: Int)
fact Trimmed (s: String)
fact Short (s: String)

# Two `via` checks on ONE codec field: each runs on the value the previous one
# accepted, and each needs its own result binder.
check isTrimmed(s: String) -> s: String ::: Trimmed s =
  if String.startsWith s " " then
    fail 400 "must not start with a space"
  else
    ok s ::: Trimmed s

check isShort(s: String) -> s: String ::: Short s =
  if String.length s <= 10 then
    ok s ::: Short s
  else
    fail 400 "too long"

check isPositive(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "must be positive"

capturer positiveId: Int ::: Positive taskId using intCodec via isPositive

record Task {
  id: Int
  label: String ::: Trimmed label && Short label
}

codec Task {
  toJson {
    id -> "id" with_codec intCodec
    label -> "label" with_codec stringCodec
  }
  fromJson [
    {
      id <- "id" with_codec intCodec
      label <- "label" with_codec stringCodec via (isTrimmed && isShort)
    }
  ]
}

entity Note table "notes" primaryKey id {
  id: String
}

database TaskDatabase = Database {
  entities: [Note]
  backend: Memory
}

record EmailJob {
  address: String
}

worker sendEmail(job: EmailJob ::: FromQueue (Id == jobId) job) requires [queueRead] =
  job

queue EmailQueue requires [] = Queue {
  database: TaskDatabase
  jobs: [Job EmailJob sendEmail Nothing]
  retry: QueueRetryStrategy {
    maxAttempts: 1
    backoff: Fixed
    initialDelay: 0
  }
}

# A queue as a VALUE: its name is a type, and `deadJobs` reads the store without
# needing the job type. (Not called from a test — a queue value has no literal
# spelling in the surface; what this pins is that the parameter TYPE resolves and
# the verb reaches the store through it.)
fn listDead(q: EmailQueue) -> List DeadJob requires [queueRead] =
  deadJobs q

# An `intCodec` path capture: the segment is parsed before anything looks at it.
handler get getTask(taskId: Int ::: Positive taskId) -> String =
  String.concat "task-" (Int.toString taskId)

# A LIST request body: the JSON array itself, decoded element by element.
handler post countLabels(labels: List String) -> Int =
  List.length labels

# A list of RECORDS, whose element decoder answers a check rather than an error —
# the two element kinds go through one loop.
handler post countTasks(tasks: List Task) -> Int =
  List.length tasks

api TaskApi {
  get "/tasks/:taskId"
    capture taskId: Int ::: Positive taskId via positiveId
    -> String

  post "/labels/count"
    body labels: List String
    -> Int

  post "/tasks/count"
    body tasks: List Task
    -> Int
}

server TaskServer for TaskApi {
  getTask
  countLabels
  countTasks
}

# A check bound in a test binds its VALUE; a rejection there is a failed test.
test "a check bound in a test is its checked value" {
  let raw = "550e8400-e29b-41d4-a716-446655440000"
  let valid = UUID.validate raw
  expect valid == raw
}

api-test "an intCodec capture is parsed, and a bad one is the client's error" for TaskServer requires [] {
  let ok1 = get "/tasks/7"
  expect statusOk ok1.status
  expect ok1.body == "task-7"
  let notAnInt = get "/tasks/seven"
  expect statusClientError notAnInt.status
  let notPositive = get "/tasks/0"
  expect statusClientError notPositive.status
}

api-test "a list body decodes element by element" for TaskServer requires [] {
  let counted = post "/labels/count" body ["a", "b", "c"]
  expect statusOk counted.status
  expect counted.body == 3
  let empty = post "/labels/count" body []
  expect statusOk empty.status
  expect empty.body == 0
}

# The `List Task` endpoint above is EMITTED but not exercised here: the Racket
# runtime answers 400 for a list-of-records body even when every element is valid
# (measured 2026-08-16, for a proof-free record with a codec too), so running it
# would pin that gap rather than this decoder. The emitted shape is asserted in
# the emitter suite instead.

# A string literal inside an api-test is a TEMPLATE in every position, including
# the right-hand side of a comparison — but `{}` alone is still two characters.
api-test "a template slot interpolates wherever it is written" for TaskServer requires [] {
  let id = "7"
  let r = get "/tasks/{id}"
  expect statusOk r.status
  expect ("id: " ++ r.body) == "id: task-7"
  # `{}` alone is two characters, not a slot: this expectation compares against
  # the braces themselves.
  let literal = post "/labels/count" body []
  expect ("empty: {}" ++ "") == "empty: {}"
  expect literal.body == 0
}
|}

let test_boundary_with_go () =
  let emitted = match Compile.compile_go_source "<go-boundary>" boundary_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "boundary compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgoboundary/module.go" emitted in
  let tests_go = artifact "internal/teslmodgoboundary/module_test.go" emitted in
  (* The capture is parsed, and a bad segment answers with the parser's own status. *)
  check bool "an intCodec capture is parsed before the handler sees it" true
    (contains module_go "teslSegmentTaskId := teslrt.IntegerSegment(teslRawTaskId)");
  (* Two `via` checks on one field need two binders — one name declared twice does not
     compile, which is how this was found. *)
  check bool "a chained via numbers its result binders" true
    (contains module_go "teslCheckedLabel2 := ");
  (* A list body walks its element's reader; a record element's codec answers a Check, which
     the adapter turns into the shape the loop takes. *)
  check bool "a list body decodes element by element" true
    (contains module_go "teslrt.DecodeListValue(teslParsed, teslrt.DecodeStringValue)");
  check bool "a list of records goes through each element's codec" true
    (contains module_go "teslrt.DecodeListValue(teslParsed, teslrt.CheckedDecoder(DecodeTaskJSON))");
  (* A queue is a value with a type of its own. *)
  check bool "a queue parameter is the runtime queue" true
    (contains module_go "func ListDead(q *teslrt.Queue) []teslrt.DeadJob");
  check bool "a queue value reaches the store directly" true (contains module_go "teslrt.DeadJobs(q)");
  (* A check bound in a test binds its VALUE, so the comparison is against the value. *)
  check bool "a check bound in a test is unwrapped" true
    (contains tests_go "valid := teslrt.MustCheck(teslrt.UUIDValidate(raw))");
  (* A template slot interpolates on the right of a comparison too. *)
  check bool "a template slot interpolates in an expectation" true
    (contains tests_go "teslrt.ApiTestFragment(");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-boundary" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)
  end

(* ── Proof shapes at the edges of erasure ────────────────────────────────────
   A proof ANNOTATION on a constructor field is a type-level contract with no runtime
   structure, like every other: what it buys is that a `Node` cannot be BUILT without a
   proven value, and that is the checker's to enforce.  A labelled constructor application
   resolves its labels against the declaration.  `-> Wrapper (T ? P)` answers the wrapper
   the source names, which is not always `Maybe`.

   `expectHasProof f x P` asserts, on Racket, that the value carries the fact.  Facts erase
   here, so what a Go run can still assert is the half that is about the run — that the
   check ACCEPTED, without which there is no value for the proof to be about.  The predicate
   is guaranteed statically, which is stronger than an assertion about a list.

   And a check whose body is a BARE call to another check DELEGATES: reading it as a value
   would `MustCheck` it, turning a rejection into a trap that escapes the caller's
   `expectFail`. *)
let proof_shapes_source = {|module GoProofShapes exposing [PositiveTree, insertTree, treeSum, findMin, wrapPositive]

import Tesl.Prelude exposing [Int, String, Bool(..), List]
import Tesl.Either exposing [Either(..)]
import Tesl.String exposing [String.length]

fact IsPositive (n: Int)
fact InRange (n: Int)

check checkPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "must be positive"

# A check whose body is a BARE call to another check: it hands back that check's
# own result, rejection included. Reading it as a value would trap instead.
check wrapPositive(n: Int) -> n: Int ::: IsPositive n =
  checkPositive n

check checkRange(n: Int) -> n: Int ::: InRange n =
  if n >= 0 then
    if n <= 100 then
      ok n ::: InRange n
    else
      fail 400 "too large"
  else
    fail 400 "too small"

# A constructor field carrying a proof: the annotation erases, and what it buys is
# that a Node cannot be BUILT without a proven value.
type PositiveTree
  = Leaf
  | Node (left: PositiveTree) (value: Int ::: IsPositive value) (right: PositiveTree)

# Labelled constructor application: the declaration fixes the order.
fn insertTree(t: PositiveTree, v: Int ::: IsPositive v) -> PositiveTree =
  case t of
    Leaf ->
      Node { left: Leaf, value: v, right: Leaf }
    Node l cur r ->
      if v < cur then
        Node { left: insertTree l v, value: cur, right: r }
      else
        Node { left: l, value: cur, right: insertTree r v }

fn treeSum(t: PositiveTree) -> Int =
  case t of
    Leaf -> 0
    Node l v r -> v + treeSum l + treeSum r

# `-> Wrapper (T ? P)` where the wrapper is NOT Maybe: the proof erases and the
# result is the wrapper the source names.
fn findMin(t: PositiveTree) -> Either String (Int ? IsPositive) =
  case t of
    Leaf -> Left "Not found"
    Node Leaf cur _ -> Right cur
    Node l _ _ -> findMin l

test "a proof-carrying constructor field builds and reads back" {
  let n3 = 3
  let n1 = 1
  let n7 = 7
  let three = check checkPositive n3
  let one = check checkPositive n1
  let seven = check checkPositive n7
  let t = insertTree (insertTree (insertTree Leaf three) one) seven
  expect treeSum t == 11
}

# `expectHasProof f x P` asserts the check accepts and mints the predicate. The
# predicate itself is a compile-time guarantee on Go; what a run can still show is
# that the check accepted.
test "a check mints its predicate" {
  let mid = 50
  let low = 0
  let high = 100
  expectHasProof checkRange mid InRange
  expectHasProof checkRange low InRange
  expectHasProof checkRange high InRange
}

# A bare delegation propagates its rejection rather than trapping.
test "a wrapping check rejects for the same reason the inner one does" {
  let five = 5
  let zero = 0
  let negative = -1
  let good = check wrapPositive five
  expect good == 5
  expectFail check wrapPositive zero
  expectFail check wrapPositive negative
}

# An `if` in a test body is the statement it describes.
test "an if in a test body picks a branch" {
  let tooLong = "aaaaaaaaaabbbbbbbbbbcccccccccc"
  let tooBig = 1000
  if String.length tooLong > 20 then
    expectFail check checkRange tooBig
  else
    expect True
  if String.length tooLong > 1000 then
    expect False
  else
    expect String.length tooLong == 30
}
|}

let test_proof_shapes_with_go () =
  let emitted = match Compile.compile_go_source "<go-proof-shapes>" proof_shapes_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "proof-shapes compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgoproofshapes/module.go" emitted in
  let tests_go = artifact "internal/teslmodgoproofshapes/module_test.go" emitted in
  (* The proof erases: the field is its own type. *)
  check bool "a proof-carrying constructor field is its own type" true
    (contains module_go "NodeValue teslrt.Int");
  (* Labels resolve against the declaration, so the positional order is the declared one. *)
  check bool "a labelled constructor application is ordered by the declaration" true
    (contains module_go "NodeLeft: ") ;
  (* The wrapper is the one the source names. *)
  check bool "a proof-carrying return keeps its own wrapper" true
    (contains module_go "func FindMin(t PositiveTree) teslrt.Either[string, teslrt.Int]");
  (* A bare delegation hands the inner check back rather than trapping on it. *)
  check bool "a bare check delegation propagates" true
    (contains module_go "func WrapPositive(n teslrt.Int) teslrt.Check[teslrt.Int] {"
     && contains module_go "\treturn checkPositive(n)\n}");
  (* `expectHasProof` asserts the run's half. *)
  check bool "expectHasProof asserts the check accepted" true
    (contains tests_go "teslT.Fatal(\"expected the check to accept, minting InRange\")");
  (* An `if` in a test body is the statement it describes. *)
  check bool "a test-body if is a Go if" true
    (contains tests_go "} else {");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-proof-shapes" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)
  end

(* A proof operation that could only fail on RACKET stays refused, and the rule is precise
   rather than a blanket one: its runtime raises when a value carries more than one proof,
   which the emitter can see — a `check` applied to a value that is itself a check's result
   ACCUMULATES.  A proof operation on a singly-checked value raises nowhere, so an
   `expectFail` over that function is expecting one of its CHECKS to reject, which happens
   here too. *)
let test_racket_only_proof_failures_fail_closed () =
  let header = {|module GoProofLimit exposing []
import Tesl.Prelude exposing [Int, Bool(..), Fact, forgetFact, detachFact, attachFact]

fact PosLimit (n: Int)
fact SmallLimit (n: Int)

check checkPos(n: Int) -> n: Int ::: PosLimit n =
  if n > 0 then
    ok n ::: PosLimit n
  else
    fail 400 "must be positive"

check checkSmall(n: Int ::: PosLimit n) -> n: Int ::: SmallLimit n =
  if n < 100 then
    ok n ::: SmallLimit n
  else
    fail 400 "too large"

|} in
  (* ACCUMULATED: the second check runs on the first one's result, so `detachFact` on it is
     the shape whose failure exists only on Racket. *)
  let accumulated = {|fn twoProofs(raw: Int) -> Int =
  let a = check checkPos raw
  let b = check checkSmall a
  let _p = detachFact b
  0

test "refused" {
  let n = 5
  expectFail (fn () -> twoProofs n)
}
|} in
  (match Compile.compile_go_source "<go-proof-limit>" (header ^ accumulated) with
   | Compile.GoSuccess _ -> fail "an accumulated-proof detach emitted instead of failing closed"
   | Compile.GoFailure diagnostics ->
     check bool "an accumulated-proof detach is refused" true
       (List.exists (fun (d : Compile.diagnostic) ->
          contains d.message "erases proofs, so `detachFact` cannot fail") diagnostics));
  (* SINGLY checked: the detach raises nowhere, and the expected failure is the check's. *)
  let single = {|fn oneProof(raw: Int) -> Int =
  let a = check checkPos raw
  let plain = forgetFact a
  let p = detachFact a
  let back = attachFact plain p
  back

test "emitted" {
  let n = 5
  expect oneProof n == 5
  let bad = 0
  expectFail (fn () -> oneProof bad)
}
|} in
  match Compile.compile_go_source "<go-proof-single>" (header ^ single) with
  | Compile.GoFailure diagnostics ->
    failf "a singly-checked detach was refused: %s"
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  | Compile.GoSuccess _ -> check bool "a singly-checked detach emits" true true

(* ── A conjunction whose conjuncts capture, and the cookie record form ───────
   `checkAtLeast 0 && checkAtMost 100` is two checks the PROGRAM has partially applied, and
   the values it supplied belong to the call site rather than to the conjunction.  The
   sequencing helper is cached by its source, so a captured value cannot be baked into it:
   it becomes a PARAMETER, and the call site — which is where the loop body sits, so the
   values are in scope — supplies it.  Every position a conjunction can be written in goes
   through the one resolver: applied to a value, as a callback, as `emptyForAll`'s element
   witness, and inside `expectFail`.

   `cookie { "name": value }` is the second spelling of a request cookie, for the case the
   value is computed. *)
let captured_conjunction_source = {|module GoCombined exposing [ProfileServer]

import Tesl.Prelude exposing [Int, String, Bool(..), List]
import Tesl.Json exposing [stringCodec, intCodec]
import Tesl.List exposing [List.length, List.filterCheck, List.allCheck, List.emptyForAll]
import Tesl.String exposing [String.concat]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.ApiTest exposing [statusOk, statusClientError]

fact AtLeast (lo: Int) (n: Int)
fact AtMost (hi: Int) (n: Int)
fact InBand (n: Int)

# Two checks that CAPTURE a bound: the value the program supplies belongs to the
# call site, not to the conjunction.
check checkAtLeast(lo: Int, n: Int) -> n: Int ::: AtLeast lo n =
  if n >= lo then
    ok n ::: AtLeast lo n
  else
    fail 400 "too small"

check checkAtMost(hi: Int, n: Int) -> n: Int ::: AtMost hi n =
  if n <= hi then
    ok n ::: AtMost hi n
  else
    fail 400 "too large"

check inBand(n: Int) -> n: Int ::: InBand n =
  if n >= 0 then
    ok n ::: InBand n
  else
    fail 400 "negative"

fn keepInRange(xs: List Int) -> List Int =
  List.filterCheck (checkAtLeast 0 && checkAtMost 100) xs

fn keepBanded(xs: List Int) -> List Int =
  List.filterCheck (inBand && checkAtMost 10) xs

fn emptyBanded() -> List Int =
  List.emptyForAll (inBand && checkAtMost 10)

fn allInRange(xs: List Int) -> Bool =
  case List.allCheck (checkAtLeast 0 && checkAtMost 100) xs of
    Something _ -> True
    Nothing -> False

# A `check (a && b) x` whose conjuncts capture, applied directly.
fn narrow(raw: Int) -> Int =
  let banded = check (checkAtLeast 5 && checkAtMost 9) raw
  banded

# ── The cookie record form ───────────────────────────────────────────────────

fact Authenticated (u: String)

auth cookieAuth(request: HttpRequest) -> u: String ::: Authenticated u =
  case Dict.lookup "session" request.cookies of
    Something userId -> ok userId ::: Authenticated u
    Nothing -> fail 401 "no session"

# A PRESENT value written to a nullable column is the present case of it.
handler get whoami(u: String ::: Authenticated u) -> String =
  String.concat "you are " u

api ProfileApi {
  get "/whoami"
    auth u: String ::: Authenticated u via cookieAuth
    -> String
}

server ProfileServer for ProfileApi {
  whoami
}

test "a conjunction of captured checks keeps only what passes both" {
  expect List.length (keepInRange [-7, 1, 50, 200, 99]) == 3
  expect List.length (keepBanded [-1, 0, 5, 11]) == 2
  expect allInRange [1, 2, 3] == True
  expect allInRange [1, 200] == False
  expect List.length (emptyBanded ()) == 0
}

test "a captured conjunction applied directly rejects for either reason" {
  let good = 7
  let low = 1
  let high = 99
  expect narrow good == 7
  expectFail (fn () -> narrow low)
  expectFail (fn () -> narrow high)
}

# `cookie { "name": value }` names the parts, which is what a test does when the
# value is computed.
api-test "a cookie written as a record reaches the request" for ProfileServer requires [] {
  let who = "alice"
  let resp = get "/whoami" cookie { "session": who }
  expect statusOk resp.status
  expect resp.body == "you are alice"
  let anonymous = get "/whoami"
  expect statusClientError anonymous.status
}
|}

let test_captured_conjunction_with_go () =
  let emitted = match Compile.compile_go_source "<go-combined>" captured_conjunction_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "combined-check compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgocombined/module.go" emitted in
  let tests_go = artifact "internal/teslmodgocombined/module_test.go" emitted in
  (* The captured bound is a PARAMETER of the helper, not a constant inside it. *)
  check bool "a captured conjunct's argument is a helper parameter" true
    (contains module_go "teslStep0 := checkAtLeast(teslCapture0, teslValue)");
  check bool "the next conjunct runs on the value the first accepted" true
    (contains module_go "teslStep1 := checkAtMost(teslCapture1, teslrt.MustCheck(teslStep0))");
  (* A conjunction mixing a bare conjunct with an applied one works the same way. *)
  check bool "a bare conjunct takes no capture parameter" true
    (contains module_go "teslStep0 := inBand(teslValue)");
  (* `emptyForAll` reads the element type off the first conjunct. *)
  check bool "emptyForAll over a conjunction answers the element's slice" true
    (contains module_go "func emptyBanded() []teslrt.Int");
  (* The cookie's two parts become the one wire form. *)
  check bool "a record cookie is written as name=value" true
    (contains tests_go "[]string{\"session=\" + ");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-combined" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)
  end

(* A value whose type is not the COLUMN's is refused, which is the language's own rule — the
   checker's SET-clause validation says the assigned value must have the same type.  Worth a
   test of its own because the tempting coercion (a String into a `Maybe String` column is
   "obviously" the present case) would make this backend agree with a hole in that
   validation rather than with the rule: it only sees entities declared in the SAME module,
   so a cross-module entity slips past it. *)
let test_column_type_mismatch_fails_closed () =
  let source = {|module GoColumn exposing [setOwner]
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Database exposing [Database, Memory]
import Tesl.DB exposing [dbWrite]

entity Ticket table "tickets" primaryKey id {
  id: String
  ownerId: Maybe String
}

database TicketDatabase = Database {
  entities: [Ticket]
  backend: Memory
}

fn setOwner(ticketId: String, owner: String) -> String requires [dbWrite] =
  let _ = update t in Ticket where t.id == ticketId set t.ownerId = owner
  ticketId
|} in
  match Compile.compile_go_source "<go-column>" source with
  | Compile.GoSuccess _ -> fail "a String written to a Maybe column emitted"
  | Compile.GoFailure diagnostics ->
    check bool "the column's own type is what the value must have" true
      (List.exists (fun (d : Compile.diagnostic) ->
         contains d.message "type mismatch" || contains d.message "different type than the column")
         diagnostics)

(* ── Property generators over proof-carrying records ─────────────────────────
   A field annotated `Int ::: IsPositive n` cannot be drawn from the whole Int range: the
   property would be handed a value its own annotation says is impossible.  The three
   predicates Racket has proof-aware draws for get the same three here, over the same
   ranges, so a property searches the same space on both backends; any other predicate falls
   back to the plain draw and the proof is NOT fabricated — what makes it true is the
   checker, not the generator.

   A RECORD-level invariant is a relation between fields, which no fieldwise draw can
   guarantee, so the generator redraws until the invariant's own check accepts — rejection
   sampling, the same 100 attempts Racket allows before it skips the iteration. *)
let property_generator_source = {|module GoPropGen exposing [isLarger, bumped]

import Tesl.Prelude exposing [Int, Bool(..)]

fact IsPositive (n: Int)
fact IsNonZero (n: Int)
fact Ordered (x: Int) (y: Int)

check isLarger(x: Int, y: Int) -> x: Int ::: Ordered x y =
  if x > y then
    ok x ::: Ordered x y
  else
    fail 400 "x must be larger than y"

# A field carrying a proof cannot be drawn from the whole range: the property
# would be handed a value its own annotation says is impossible.
record Bounds {
  low: Int ::: IsPositive low
  step: Int ::: IsNonZero step
}

# A RECORD-level invariant is a relation BETWEEN fields, which no fieldwise draw
# can guarantee — so the generator redraws until the invariant's check accepts.
record Span {
  hi: Int ::: IsPositive hi
  lo: Int ::: IsPositive lo
} ::: Ordered hi lo via isLarger

fn bumped(n: Int) -> Int =
  n + 1

test "a proof-annotated field is drawn from the range its predicate admits" with 50 runs {
  property "positive stays positive" (b: Bounds) { b.low > 0 }
}

test "a non-zero field is never zero" with 50 runs {
  property "step is usable as a divisor" (b: Bounds) { b.step != 0 }
}

test "a record invariant holds of every generated value" with 50 runs {
  property "hi is larger than lo" (s: Span) { s.hi > s.lo }
}

test "a where clause still narrows a proof-annotated draw" with 50 runs {
  property "bounded and positive" (b: Bounds where b.low < 10000) { bumped b.low > 1 }
}
|}

let test_property_generators_with_go () =
  let emitted =
    match Compile.compile_go_source "<go-prop-gen>" property_generator_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "property-generator compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let tests_go = artifact "internal/teslmodgopropgen/module_test.go" emitted in
  check bool "an IsPositive field draws a positive" true
    (contains tests_go "Low: teslrt.PropPositiveInt()");
  check bool "an IsNonZero field never draws zero" true
    (contains tests_go "Step: teslrt.PropNonZeroInt()");
  (* The invariant's check is called with the FIELDS its proof names. *)
  check bool "a record invariant redraws until its check accepts" true
    (contains tests_go "if IsLarger(teslCandidate.Hi, teslCandidate.Lo).OK() {");
  check bool "the redraw is bounded" true
    (contains tests_go "for teslAttempt := 0; teslAttempt < 100; teslAttempt++ {");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-prop-gen" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)
  end

(* ── `Tesl.Regex` ────────────────────────────────────────────────────────────
   Six functions over String, pattern first, and the Racket oracle beside them agrees on
   every one — the patterns a program may write are the compiler-checked subset, which is
   common ground between `pregexp` and RE2.

   ONE deliberate difference, and it is a strengthening: Racket runs every match in its own
   thread under a wall-clock deadline, because its matcher backtracks.  Go's `regexp` is RE2
   — linear in the input and the pattern, and unable to express the constructs that make
   backtracking blow up, which are the same ones the compiler's lint already refuses.  The
   bound the deadline existed to give holds by construction, so a timeout knob that can
   never fire would be a promise about scheduling rather than about work.  The INPUT bound
   is kept: it is about memory.

   The property worth a test of its own is the replacement: it is inserted LITERALLY, so a
   replacement built from user data cannot be reinterpreted as a substitution directive.
   Go's `ReplaceAllString` WOULD expand `$1`. *)
let regex_source = {|module GoRegex exposing [looksLikeSlug, firstNumber, allNumbers, parts, redact, fields]

import Tesl.Prelude exposing [Int, String, Bool(..), List]
import Tesl.Regex exposing [
  Regex.matches,
  Regex.find,
  Regex.findAll,
  Regex.captures,
  Regex.replace,
  Regex.split,
]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.List exposing [List.length]

fn looksLikeSlug(s: String) -> Bool =
  Regex.matches "^[a-z0-9]+(?:-[a-z0-9]+)*$" s

fn firstNumber(s: String) -> Maybe String =
  Regex.find "[0-9]+" s

fn allNumbers(s: String) -> List String =
  Regex.findAll "[0-9]+" s

fn parts(s: String) -> Maybe (List String) =
  Regex.captures "([a-z]+)-([0-9]+)" s

# The replacement is inserted LITERALLY: a replacement built from user data can
# never be reinterpreted as a substitution directive.
fn redact(s: String) -> String =
  Regex.replace "[0-9]+" s "#"

fn fields(s: String) -> List String =
  Regex.split "," s

test "matches is unanchored unless the pattern says otherwise" {
  expect Regex.matches "cat" "the cat sat"
  expect Regex.matches "^cat$" "the cat sat" == False
  expect looksLikeSlug "hello-world-2"
  expect looksLikeSlug "Hello" == False
  expect looksLikeSlug "-leading" == False
}

test "find answers the first match, or nothing" {
  expect firstNumber "abc 42 def 7" == Something "42"
  expect firstNumber "abc" == Nothing
}

test "findAll answers every match, left to right" {
  expect allNumbers "a1 b22 c333" == ["1", "22", "333"]
  expect List.length (allNumbers "abc") == 0
}

test "captures excludes the whole match" {
  expect parts "id: abc-42 rest" == Something ["abc", "42"]
  expect parts "nothing here" == Nothing
}

# Group references are ordinary characters in the replacement.
test "replace inserts the replacement literally" {
  expect redact "a1b22c" == "a#b#c"
  expect Regex.replace "([a-z])([0-9])" "a1" "$2$1" == "$2$1"
  expect Regex.replace "([a-z])([0-9])" "a1" "&" == "&"
  expect Regex.replace "cat" "the cat sat" "dog" == "the dog sat"
}

test "split keeps the empty pieces" {
  expect fields "a,b,c" == ["a", "b", "c"]
  expect fields ",a,,b," == ["", "a", "", "b", ""]
  expect List.length (fields "") == 1
}
|}

let test_regex_with_go () =
  let emitted = match Compile.compile_go_source "<go-regex>" regex_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "regex compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgoregex/module.go" emitted in
  check bool "the pattern is the first argument, as written" true
    (contains module_go "teslrt.RegexMatches(\"^[a-z0-9]+(?:-[a-z0-9]+)*$\", s)");
  check bool "find answers a Maybe" true (contains module_go "teslrt.RegexFind(");
  check bool "captures answers a Maybe of the group list" true
    (contains module_go "teslrt.RegexCaptures(");
  (* The one that would be a security bug if it went through the expanding form. *)
  let runtime_go = artifact "internal/teslrt/regex.go" emitted in
  check bool "replace uses the literal form" true
    (contains runtime_go "ReplaceAllLiteralString");
  check bool "replace never uses the expanding form" false
    (contains runtime_go "ReplaceAllString(");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-regex" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)
  end

(* A program that matches nothing must not carry the regex runtime. *)
let test_regex_runtime_ships_only_where_used () =
  let plain = {|module GoNoRegex exposing [twice]
import Tesl.Prelude exposing [Int]

fn twice(n: Int) -> Int = n * 2
|} in
  match Compile.compile_go_source "<go-no-regex>" plain with
  | Compile.GoFailure diagnostics ->
    failf "plain module failed: %s"
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  | Compile.GoSuccess artifacts ->
    check bool "no regex runtime in a module that matches nothing" false
      (List.exists (fun (a : Emit_go.artifact) -> a.path = "internal/teslrt/regex.go") artifacts)

(* ── `Tesl.Sso`: the runtime-owned login routes ───────────────────────────────
   An `sso "<seg>" connection <fn> onIdentity <fn>` clause mints /auth/<seg>/login and
   /auth/<seg>/callback. They are not handlers a program writes, and that is the point: the
   OAuth2/OIDC dance belongs to the runtime, and what reaches app code is ONE already-verified
   identity, at `onIdentity`, after the signature, the claims and the domain rules.

   Every value in the module is OPAQUE for the same reason — a program that could assemble an
   `SsoIdentity` could assert one.

   The api-test below drives a whole GitHub login through the stubbed HTTP client: the login
   redirect (with PKCE S256 and a sealed `__Host-oauth` cookie), the code exchange, the
   userinfo and verified-primary-email calls, and the session the callback mints. The Racket
   oracle beside it runs the same flow through `dsl/sso.rkt`. *)
let sso_source = {|module GoSso exposing [githubConn, linkUser, me, sessionKey]

import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Sso exposing [
  SsoConnection,
  SsoIdentity,
  Github,
  Sso.defaults,
  Sso.subject,
]
import Tesl.Time exposing [time]
import Tesl.Env exposing [envRead, requireSecret]
import Tesl.HttpClient exposing [httpClient]
import Tesl.Crypto exposing [Secret]
import Tesl.JWT exposing [jwt, JWT.sign, JWT.verify]
import Tesl.Http exposing [HttpRequest, Http.sessionToken]
import Tesl.Dict exposing [Dict, Dict.singleton, Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.String exposing [String.contains, String.indexOf, String.length, String.slice]
import Tesl.ApiTest exposing [stubHttp, httpCalled, responseCookie, statusOk]
import Tesl.Database exposing [Database, DatabaseBackend, Memory]
import Tesl.App exposing [App]

# The one capability the session surface needs, named once so every function that
# touches a session declares the same thing.
capability sessions implies jwt, time, envRead

record Profile {
  userId: String
}

record User {
  id: String
}

fact Authenticated (u: User)

fn sessionKey() -> Secret requires [envRead] = requireSecret "GO_SSO_SESSION_KEY"

fn githubConn() -> SsoConnection requires [envRead] =
  Sso.defaults Github "demo-github-client-id" (requireSecret "GO_SSO_CLIENT_SECRET")

fn linkUser(identity: SsoIdentity) -> String = Sso.subject identity

fn subjectOf(claims: Dict String String) -> String =
  case Dict.lookup "sub" claims of
    Nothing -> ""
    Something subject -> subject

auth sessionOwner(request: HttpRequest) -> user: User ::: Authenticated user
  requires [sessions] =
  case Http.sessionToken request of
    Nothing -> fail 401 "no session"
    Something token ->
      let claims = check JWT.verify token (sessionKey())
      ok (User { id: subjectOf claims }) ::: Authenticated user

handler get me(user: User ::: Authenticated user) -> Profile =
  Profile { userId: user.id }

api SsoApi {
  get "/me"
    auth user: User ::: Authenticated user via sessionOwner
    -> Profile
}

server SsoServer for SsoApi {
  me
  sso "github" connection githubConn onIdentity linkUser
  publicOrigin "https://app.example.com"
  sessionKey "GO_SSO_SESSION_KEY"
  afterLogin "/me"
  loginMethods [Sso]
}

database SsoDb = Database {
  entities: []
  backend: Memory
}

main() -> App requires [sessions, httpClient, envRead] =
  App {
    database: SsoDb
    api: SsoServer
    port: 8080
  }

fn onHost() -> Dict String String = Dict.singleton "Host" "app.example.com"

fn valueOf(url: String, key: String) -> String =
  let marker = key ++ "="
  case String.indexOf url marker of
    Nothing -> ""
    Something at ->
      let rest = String.slice url (at + String.length marker) (String.length url)
      case String.indexOf rest "&" of
        Nothing -> rest
        Something amp -> String.slice rest 0 amp

# No network is needed for the redirect: a blessed provider's endpoints are baked in.
api-test "the login redirect carries PKCE S256 and no secret" for SsoServer requires [sessions] {
  let resp = get "/auth/github/login" headers (onHost())
  expect resp.status == 303
  case Dict.lookup "location" resp.headers of
    Nothing -> expect False
    Something location ->
      expect String.contains location "https://github.com/login/oauth/authorize"
      expect String.contains location "code_challenge_method=S256"
      expect String.contains location "redirect_uri=https%3A%2F%2Fapp.example.com"
      # The client SECRET never travels in a URL — it goes in the Authorization header of
      # the token exchange, and nowhere else.
      expect String.contains location "client_secret" == False
}

api-test "an unknown segment is not a login route" for SsoServer requires [sessions] {
  let resp = get "/auth/nope/login" headers (onHost())
  expect resp.status == 404
}

# A callback with no in-flight cookie is a FIXED failure page, never a 500 and never
# the provider's own text.
api-test "a callback with no in-flight state fails closed" for SsoServer requires [sessions] {
  let resp = get "/auth/github/callback?code=c&state=s" headers (onHost())
  expect resp.status == 401
}

api-test "a whole GitHub login" for SsoServer requires [httpClient, sessions] {
  let login = get "/auth/github/login" headers (onHost())
  let location = case Dict.lookup "location" login.headers of
    Nothing -> ""
    Something loc -> loc
  let state = valueOf location "state"
  expect String.length state > 0

  let oauthCookie = case responseCookie login of
    Nothing -> ""
    Something pair -> pair
  expect String.contains oauthCookie "__Host-oauth="

  stubHttp "POST" "https://github.com/login/oauth/access_token" 200
    "{\"access_token\": \"gh-test-token\"}"
  stubHttp "GET" "https://api.github.com/user" 200
    "{\"id\": 4242, \"name\": \"Ada Lovelace\"}"
  stubHttp "GET" "https://api.github.com/user/emails" 200
    "[{\"email\": \"ada@example.com\", \"primary\": true, \"verified\": true}]"

  let cb = get ("/auth/github/callback?code=test-code&state=" ++ state)
    cookie oauthCookie headers (onHost())
  expect cb.status == 303
  expect httpCalled "POST" "https://github.com/login/oauth/access_token"

  # The response both SETS the session and CLEARS the spent in-flight cookie, and the
  # one that survives for a round trip is the one that sets a value.
  case responseCookie cb of
    Nothing -> expect False
    Something sessionCookie ->
      let profile = get "/me" cookie sessionCookie headers (onHost())
      expect statusOk profile.status
      expect profile.body.userId == "4242"
}

# The state is single-use: presenting the same callback twice is a replay.
api-test "a replayed callback is refused" for SsoServer requires [httpClient, sessions] {
  let login = get "/auth/github/login" headers (onHost())
  let location = case Dict.lookup "location" login.headers of
    Nothing -> ""
    Something loc -> loc
  let state = valueOf location "state"
  let oauthCookie = case responseCookie login of
    Nothing -> ""
    Something pair -> pair

  stubHttp "POST" "https://github.com/login/oauth/access_token" 200
    "{\"access_token\": \"gh-test-token\"}"
  stubHttp "GET" "https://api.github.com/user" 200
    "{\"id\": 4242, \"name\": \"Ada Lovelace\"}"
  stubHttp "GET" "https://api.github.com/user/emails" 200
    "[{\"email\": \"ada@example.com\", \"primary\": true, \"verified\": true}]"

  let path = "/auth/github/callback?code=test-code&state=" ++ state
  let first = get path cookie oauthCookie headers (onHost())
  expect first.status == 303
  let second = get path cookie oauthCookie headers (onHost())
  expect second.status == 401
}
|}

let test_sso_with_go () =
  let emitted = match Compile.compile_go_source "<go-sso>" sso_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "SSO compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgosso/module.go" emitted in
  (* The clause becomes a route the SERVER carries, not a handler the program wrote. *)
  check bool "the sso clause mints a runtime-owned route" true
    (contains module_go "SsoRoutes: []teslrt.SsoRoute{");
  check bool "the connection is a thunk, read per request" true
    (contains module_go "Connection:   GithubConn");
  check bool "the session key is read from the declared variable" true
    (contains module_go "teslrt.RequireSecret(\"GO_SSO_SESSION_KEY\")");
  (* `publicOrigin` is the redirect_uri's base and is NEVER derived from a request. *)
  check bool "the public origin comes from the clause" true
    (contains module_go "PublicOrigin: \"https://app.example.com\"");
  let sso_go = artifact "internal/teslrt/sso.go" emitted in
  check bool "the identity key is length-prefixed before hashing" true
    (contains sso_go "binary.BigEndian.PutUint64");
  check bool "the in-flight cookie is MAC'd under a derived subkey" true
    (contains sso_go "oauthCookieKdfContext");
  let jws_go = artifact "internal/teslrt/jws.go" emitted in
  check bool "a token that nominates its own key is refused" true
    (contains jws_go "nominatedHeaderKeys");
  check bool "alg:none is refused" true (contains jws_go "alg:none refused");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-sso" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root
        "GO_SSO_SESSION_KEY=go-sso-signing-key GO_SSO_CLIENT_SECRET=go-sso-client-secret \
         go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      run_go_gates root)
  end

(* ── A queue carrying more than one job type ──────────────────────────────────
   The store holds a payload as `any` precisely so one queue can carry several job types,
   and the emitter is what knows them: each worker call site becomes a type SWITCH over the
   declared wirings, so the right worker runs for the payload that was enqueued.

   `enqueue` is the half that had to change with it: the row it builds is the type ENQUEUED,
   not the queue's first — reading it off the queue would put every job in at one type. *)
let multi_job_queue_source = {|module GoMultiJob exposing [sendEmail, resizeImage, seedBoth]

import Tesl.Prelude exposing [Bool(..), Int, String, List, Unit]
import Tesl.Queue exposing [Queue, QueueRetryStrategy, Fixed, queueRead, queueWrite, FromQueue]
import Tesl.Database exposing [Database, DatabaseBackend, Memory]
import Tesl.DB exposing [dbRead, dbWrite]

entity Sent table "sent" primaryKey id {
  id: String
  kind: String
}

database MultiJobDb = Database {
  schema: "go_multi_job"
  entities: [Sent]
  backend: Memory
}

record EmailJob {
  jobId: String
  to: String
}

record ImageJob {
  jobId: String
  width: Int
}

worker sendEmail(job: EmailJob ::: FromQueue (Id == jobId) job) -> Int
  requires [dbWrite] =
  let _ = insert Sent { id: job.jobId, kind: "email" }
  1

worker resizeImage(job: ImageJob ::: FromQueue (Id == jobId) job) -> Int
  requires [dbWrite] =
  let _ = insert Sent { id: job.jobId, kind: "image" }
  job.width

queue MultiJobQueue requires [queueRead, dbWrite] = Queue {
  database: MultiJobDb
  jobs: [
    Job EmailJob sendEmail Nothing,
    Job ImageJob resizeImage Nothing
  ]
  numberOfWorkers: 1
  retry: QueueRetryStrategy {
    maxAttempts: 2
    backoff: Fixed
    initialDelay: 1
  }
}

# Two job types into ONE queue: each is enqueued at its own type.
fn queueEmail(id: String) -> Unit requires [queueWrite] =
  enqueue EmailJob { jobId: id, to: "ada@example.com" }

fn queueImage(id: String) -> Unit requires [queueWrite] =
  enqueue ImageJob { jobId: id, width: 64 }

fn seedBoth() -> Int requires [queueWrite] =
  let _ = queueEmail "e1"
  let _ = queueImage "i1"
  2

fn sentCount() -> Int requires [dbRead] = selectCount s from Sent

test "both job types run through their own worker" requires [dbRead, dbWrite, queueRead, queueWrite] {
  let _ = seedBoth ()
  expect sentCount () == 0
}
|}

let test_multi_job_queue_with_go () =
  let emitted = match Compile.compile_go_source "<go-multi-job>" multi_job_queue_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "multi-job queue compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgomultijob/module.go" emitted in
  (* Each job goes in at ITS OWN type, which is what the type switch then reads back. *)
  check bool "an email job is enqueued as an EmailJob" true
    (contains module_go "teslrt.EnqueueJob(MultiJobQueueQueue, EmailJob{");
  check bool "an image job is enqueued as an ImageJob" true
    (contains module_go "teslrt.EnqueueJob(MultiJobQueueQueue, ImageJob{");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-multi-job" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      run_go_gates root)
  end

(* A recursive GENERIC type may name itself at ANOTHER instantiation — `Node left: (Tree Int)`
   inside `Tree a`, which is what the corpus writes.  It is exactly as infinite by value as a
   reference to its own instantiation, so it takes the same pointer; Go accepts the
   declaration once it does, because the instantiation cycle Go rejects is the one whose type
   ARGUMENT grows and a constant one does not. *)
let recursive_generic_source = {|module GoRecGeneric exposing [size, depth]

import Tesl.Prelude exposing [Int]

type Tree a
  = Leaf
  | Node left: (Tree Int) value: Int right: (Tree Int)

fn size(t: Tree Int) -> Int =
  case t of
    Leaf -> 0
    Node left value right ->
      1 + size(left) + size(right)

fn biggest(a: Int, b: Int) -> Int =
  if a > b then
    a
  else
    b

fn depth(t: Tree Int) -> Int =
  case t of
    Leaf -> 0
    Node left value right ->
      1 + biggest (depth left) (depth right)

test "a tree that refers to another instantiation still counts" {
  let leaf = Leaf
  expect size leaf == 0
  let one = Node Leaf 1 Leaf
  expect size one == 1
  expect depth one == 1
  let three = Node (Node Leaf 1 Leaf) 2 (Node Leaf 3 Leaf)
  expect size three == 3
  expect depth three == 2
}
|}

let test_recursive_generic_with_go () =
  let emitted = match Compile.compile_go_source "<go-rec-generic>" recursive_generic_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "recursive generic compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgorecgeneric/module.go" emitted in
  (* The payload is a POINTER at the other instantiation, exactly as it would be at its
     own — a `Tree[teslrt.Int]` holding a `Tree[teslrt.Int]` by value has no size. *)
  check bool "the recursive field is boxed" true (contains module_go "*Tree[teslrt.Int]");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-rec-generic" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      run_go_gates root)
  end

(* ── A GENERIC function ───────────────────────────────────────────────────────
   `fn isEmpty(xs: List a) -> Bool` becomes `func IsEmpty[A any](xs []A) bool`: the type
   variables a declaration mentions become Go type parameters, in order of first appearance,
   and a call reads its type ARGUMENTS off the types it is applied to — `boxMap f box` with
   `f : Int -> String` and `box : Box Int` answers a `Box String`.

   Two things the collection has to get right, and both are here:
     - a lowercase name inside a PROOF is a VALUE, not a type: `-> Fact (AlwaysValid n)`
       names the parameter `n`, and reading it as a type variable made an `establish` a
       generic function over nothing;
     - a type parameter that appears ONLY in the result cannot be inferred from the
       arguments, and Go cannot infer it either — that is refused rather than emitted as
       code that does not compile. *)
let generic_function_source = {|module GoGeneric exposing [isEmpty, firstOr, boxMap, swap, countOf]

import Tesl.Prelude exposing [Bool(..), Int, String, List]
import Tesl.List exposing [List.isEmpty, List.length, List.head]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Tuple exposing [Tuple2, Tuple2.first, Tuple2.second]

type Box a
  = MkBox value: a

fn isEmpty(xs: List a) -> Bool = List.isEmpty xs

fn countOf(xs: List a) -> Int = List.length xs

# The type variable appears in a parameter AND in the result, which is what lets
# the call site settle it.
fn firstOr(fallback: a, xs: List a) -> a =
  case List.head xs of
    Nothing -> fallback
    Something value -> value

fn boxMap(f: a -> b, box: Box a) -> Box b =
  case box of
    MkBox value -> MkBox (f value)

fn swap(pair: Tuple2 a b) -> Tuple2 b a =
  Tuple2 (Tuple2.second pair) (Tuple2.first pair)

fn double(n: Int) -> Int = n * 2

fn label(n: Int) -> String = "n=${n}"

test "a type variable in a parameter is read off the argument" {
  expect isEmpty [1, 2, 3] == False
  expect isEmpty ["a"] == False
  expect countOf [1, 2, 3] == 3
  expect countOf ["a", "b"] == 2
}

test "a type variable in the result comes back instantiated" {
  expect firstOr 0 [7, 8] == 7
  expect firstOr 0 [] == 0
  expect firstOr "none" ["x"] == "x"
}

# A lambda and a NAMED function are both function values here.
test "a function parameter is instantiated at both ends" {
  expect boxMap double (MkBox 21) == MkBox 42
  expect boxMap label (MkBox 5) == MkBox "n=5"
  expect boxMap (fn(x: Int) -> x + 1) (MkBox 1) == MkBox 2
}

test "two type variables swap places" {
  let swapped = swap (Tuple2 1 "one")
  expect Tuple2.first swapped == "one"
  expect Tuple2.second swapped == 1
}
|}

let test_generic_function_with_go () =
  let emitted = match Compile.compile_go_source "<go-generic>" generic_function_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "generic function compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgogeneric/module.go" emitted in
  check bool "one type parameter, named by position" true
    (contains module_go "func IsEmpty[A any](xs []A) bool");
  check bool "two type parameters, in order of first appearance" true
    (contains module_go "func BoxMap[A any, B any](f func(A) B, box Box[A]) Box[B]");
  check bool "a type variable in the result is a parameter too" true
    (contains module_go "func FirstOr[A any](fallback A, xs []A) A");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-generic" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      run_go_gates root)
  end

(* A type parameter that appears ONLY in the result has nothing to be inferred FROM at the
   call site, and Go cannot infer it either.  The DECLARATION is fine — `func Conjure[A any]`
   compiles — so the refusal belongs where the type argument would have to be known, which is
   the call. *)
let test_uninferable_type_parameter_fails_closed () =
  let source = {|module GoGenericBad exposing [conjure, useIt]

import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.length]

fn conjure(n: Int) -> List a = []

fn useIt() -> Int = List.length (conjure 1)
|} in
  match Compile.compile_go_source "<go-generic-bad>" source with
  | Compile.GoSuccess _ -> fail "an uninferable type parameter was emitted"
  | Compile.GoFailure diagnostics ->
    check bool "the refusal names the type argument" true
      (List.exists (fun (d : Compile.diagnostic) ->
         d.source = "go-emitter" && contains d.message "cannot infer the type argument")
         diagnostics)

(* A `case` in a test block is a chain, not a run of independent `if`s.  In expression
   position every arm ends in a `return`, so a missing `else` was invisible; as statements it
   meant the arms AFTER a matching one ran as well, and `case label of "hello" -> … _ -> …`
   executed both — the catch-all failed the test the first arm had just passed. *)
let case_statement_source = {|module GoCaseStmt exposing [classify]

import Tesl.Prelude exposing [Bool(..), Int, String]

type Shape
  = Circle radius: Int
  | Rect width: Int height: Int
  | Point

fn classify(n: Int) -> String =
  case n of
    0 -> "zero"
    1 -> "one"
    _ -> "many"

test "a literal arm stops the chain" {
  let label = "hello"
  case label of
    "hello" -> expect 1 == 1
    _ -> expect 1 == 2
}

test "an integer literal arm stops the chain" {
  let n = 42
  case n of
    42 -> expect 1 == 1
    0 -> expect 1 == 2
    _ -> expect 1 == 2
}

test "a catch-all runs only when nothing matched" {
  let n = 7
  case n of
    42 -> expect 1 == 2
    _ -> expect 1 == 1
}

# A guard that fails must fall through to the next arm, and only one arm may run.
test "a guarded arm falls through when its guard fails" {
  let s = Rect 3 4
  case s of
    Rect w h where w > 10 -> expect 1 == 2
    Rect w h -> expect w + h == 7
    Circle _ -> expect 1 == 2
    Point -> expect 1 == 2
}

test "the same case in expression position still answers one arm" {
  expect classify 0 == "zero"
  expect classify 1 == "one"
  expect classify 9 == "many"
}
|}

let test_case_statement_chain_with_go () =
  let emitted = match Compile.compile_go_source "<go-case-stmt>" case_statement_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "case-statement compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let tests_go = artifact "internal/teslmodgocasestmt/module_test.go" emitted in
  (* The scalar arms are ONE switch: first match wins, no fallthrough, at most one arm — and
     a TAGGED one where every arm is a literal Go's `==` decides, which is the form
     staticcheck asks for and the one a reader recognises. *)
  check bool "a String case is a tagged switch" true (contains tests_go "switch teslScrut2 {");
  check bool "its catch-all is the default" true (contains tests_go "default:");
  (* An Int compares through the runtime, so its cases stay expressions. *)
  check bool "an Int case switches on expressions" true
    (contains tests_go "case teslrt.Equal(");
  (* A guarded ADT arm cannot be an `else if` — its guard reads bindings that only exist
     once the tag matched — so a flag carries "an arm already ran". *)
  check bool "a guarded ADT case carries a matched flag" true (contains tests_go "teslMatched");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-case-stmt" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      run_go_gates root)
  end

(* ── The calendar half of `Tesl.Time`: `TimeZone` and the bucket family ──────
   `Time.truncDay zone ts` is the bucket-START instant for the wall clock in a zone, and the
   engine behind it is a rule-for-rule port of `dsl/private/time-trunc.rkt` — deliberately
   dependency-free there for the same reason it is self-contained here: THREE consumers have
   to agree about where a bucket starts (the surface functions, the query DSL's grouped
   aggregates, and the PostgreSQL expressions), and they agree by calling one engine rather
   than by three implementations happening to match.

   The two things that are easy to get wrong, and are asserted below:
     - FLOOR division, not Go's truncate-toward-zero, which is only visible before 1970 —
       exactly where a truncating division puts an instant in the wrong bucket;
     - a named zone resolves its offset PER INSTANT, so one `EuropeStockholm` value buckets
       correctly on both sides of a DST transition, and a bucket that straddles one still
       starts at the true local midnight.

   The IANA database is compiled into the binary, so a container with no /usr/share/zoneinfo
   renders the same instants rather than silently falling back to UTC. *)
let time_zone_source = {|module GoTimeZone exposing [dayOf, hourOf, offsetOf, weekOf]

import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Time exposing [
  PosixMillis,
  TimeZone,
  Utc,
  FixedOffset,
  EuropeStockholm,
  Time.secondsToPosix,
  Time.posixToSeconds,
  Time.truncHour,
  Time.truncDay,
  Time.truncWeek,
  Time.truncMonth,
  Time.truncYear,
  Time.offsetAt,
]

fn dayOf(zone: TimeZone, seconds: Int) -> Int =
  Time.posixToSeconds (Time.truncDay zone (Time.secondsToPosix seconds))

fn hourOf(zone: TimeZone, seconds: Int) -> Int =
  Time.posixToSeconds (Time.truncHour zone (Time.secondsToPosix seconds))

fn weekOf(zone: TimeZone, seconds: Int) -> Int =
  Time.posixToSeconds (Time.truncWeek zone (Time.secondsToPosix seconds))

fn offsetOf(zone: TimeZone, seconds: Int) -> Int =
  Time.offsetAt zone (Time.secondsToPosix seconds)

# 2026-03-01T10:00:00Z, a Sunday.
test "the UTC buckets are the civil calendar" {
  expect dayOf Utc 1772359200 == 1772323200
  expect hourOf Utc 1772409000 == 1772406000
  expect weekOf Utc 1772359200 == 1771804800
  expect Time.posixToSeconds (Time.truncMonth Utc (Time.secondsToPosix 1772359200)) == 1772323200
  expect Time.posixToSeconds (Time.truncYear Utc (Time.secondsToPosix 1772359200)) == 1767225600
}

# Floor, not truncate-toward-zero: -1 s is 1969-12-31, not 1970-01-01.
test "an instant before the epoch buckets downwards" {
  expect dayOf Utc -1 == -86400
  expect Time.posixToSeconds (Time.truncYear Utc (Time.secondsToPosix -1)) == -31536000
  expect Time.posixToSeconds (Time.truncMonth Utc (Time.secondsToPosix -14182980)) == -15897600
}

# A fixed offset does not know about summer time, which is why it is its own
# constructor: its buckets shift by exactly the offset, always.
test "a fixed offset shifts every bucket by itself" {
  expect dayOf (FixedOffset 60) 1772359200 == 1772319600
  expect dayOf (FixedOffset -330) 1772359200 == 1772343000
  expect offsetOf (FixedOffset -330) 1772359200 == -330
}

# One zone VALUE, both sides of the transition.
test "a named zone resolves its offset per instant" {
  expect offsetOf EuropeStockholm 1768478400 == 60
  expect offsetOf EuropeStockholm 1784116800 == 120
  expect dayOf EuropeStockholm 1768478400 == 1768431600
  expect dayOf EuropeStockholm 1784116800 == 1784066400
  # 2026-03-29, the spring-forward day: an instant that afternoon still buckets
  # to local midnight, 2026-03-28T23:00:00Z.
  expect dayOf EuropeStockholm 1774792800 == 1774738800
}

test "a zone is the same zone as itself and not as another" {
  expect Utc == Utc
  expect EuropeStockholm == EuropeStockholm
  expect (Utc == EuropeStockholm) == False
  expect (FixedOffset 60 == FixedOffset 120) == False
  expect FixedOffset 60 == FixedOffset 60
}
|}

let test_time_zone_with_go () =
  let emitted = match Compile.compile_go_source "<go-timezone>" time_zone_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "TimeZone compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgotimezone/module.go" emitted in
  (* A named zone is one of a FIXED set, resolved from the compiler's own catalogue — there
     is no zone-name string for a program to get wrong. *)
  let tests_go = artifact "internal/teslmodgotimezone/module_test.go" emitted in
  check bool "a named zone carries its IANA name" true
    (contains tests_go "teslrt.NamedZone(\"Europe/Stockholm\")");
  check bool "Utc is a value, not a call the source wrote" true
    (contains tests_go "teslrt.UtcZone()");
  check bool "each bucket is its own runtime call" true
    (contains module_go "teslrt.TimeTruncDay(");
  (* A zone is COMPARED as a Go value: it is a name, an offset and a flag, and Go's `==`
     says exactly what "the same zone" means. *)
  check bool "zone equality is value equality" true
    (contains tests_go "teslrt.UtcZone() == teslrt.NamedZone(\"Europe/Stockholm\")");
  let runtime_go = artifact "internal/teslrt/timetrunc.go" emitted in
  check bool "the truncation floors rather than truncating" true
    (contains runtime_go "func floorDiv");
  let zone_go = artifact "internal/teslrt/timezone.go" emitted in
  check bool "the zone database is compiled in" true (contains zone_go "time/tzdata");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-timezone" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      run_go_gates root)
  end

(* ── The grouped aggregates, and `upsert` ────────────────────────────────────
   `selectSumBy … groupBy` answers one (bucket, value) pair per group, ORDERED BY KEY
   ASCENDING — the contract rather than an accident of iteration, since the Racket memory
   backend sorts its buckets and PostgreSQL's `GROUP BY … ORDER BY 1` does too, and a series
   a chart draws is only a series if its points are in order.

   A calendar bucket key goes through the SAME truncation engine `Time.truncDay` does, so
   the group key and the expression cannot disagree about where a day starts.

   `upsert … onConflict [c] doUpdate [u]` is here beside it because the two meet in the same
   store: the conflict target is a UNIQUE INDEX rather than necessarily the primary key, and
   the merged row keeps every column the `doUpdate` list does not name. *)
let group_by_source = {|module GoGroupBy exposing [minutesPerDay, entriesPerOrg, seed, touch]

import Tesl.Prelude exposing [Bool(..), Int, String, List, Unit]
import Tesl.Time exposing [
  PosixMillis, TimeZone, Utc, Time.secondsToPosix, Time.posixToSeconds, Time.truncDay,
]
import Tesl.Tuple exposing [Tuple2, Tuple2.first, Tuple2.second]
import Tesl.List exposing [List.length, List.map]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, DatabaseBackend, Memory]

entity Entry table "entries" primaryKey id {
  id: String
  orgId: String
  minutes: Int
  startedAt: PosixMillis
}

# Declared, so each test block starts from an empty table — which is what a
# `database` block buys and what a file without one does not get.
database GroupByDb = Database {
  schema: "go_group_by"
  entities: [Entry]
  backend: Memory
}

fn minutesPerDay(zone: TimeZone) -> List (Tuple2 PosixMillis Int) requires [dbRead] =
  selectSumBy e.minutes from Entry
    groupBy (Time.truncDay zone e.startedAt)

fn entriesPerOrg() -> List (Tuple2 String Int) requires [dbRead] =
  selectCountBy e from Entry
    groupBy e.orgId

fn add(id: String, org: String, minutes: Int, seconds: Int) -> Entry requires [dbWrite] =
  insert Entry {
    id: id, orgId: org, minutes: minutes, startedAt: Time.secondsToPosix seconds
  }

# 2026-03-01 10:00 and 23:30 UTC, then 2026-03-02 01:00 UTC.
fn seed() -> Int requires [dbWrite] =
  let _ = add "e1" "acme" 60 1772359200
  let _ = add "e2" "acme" 30 1772407800
  let _ = add "e3" "acme" 15 1772413200
  let _ = add "e4" "other" 5 1772359200
  4

fn touch(id: String, minutes: Int) -> Unit requires [dbWrite] =
  upsert Entry {
    id: id, orgId: "acme", minutes: minutes, startedAt: Time.secondsToPosix 0
  } onConflict [id] doUpdate [minutes]

fn dayMinutes(zone: TimeZone) -> List Int requires [dbRead] =
  List.map minutesOfRow (minutesPerDay zone)

fn minutesOfRow(row: Tuple2 PosixMillis Int) -> Int = Tuple2.second row

fn dayStarts(zone: TimeZone) -> List Int requires [dbRead] =
  List.map startOfRow (minutesPerDay zone)

fn startOfRow(row: Tuple2 PosixMillis Int) -> Int =
  Time.posixToSeconds (Tuple2.first row)

fn orgNames() -> List String requires [dbRead] = List.map nameOfRow (entriesPerOrg ())

fn nameOfRow(row: Tuple2 String Int) -> String = Tuple2.first row

fn orgCounts() -> List Int requires [dbRead] = List.map countOfRow (entriesPerOrg ())

fn countOfRow(row: Tuple2 String Int) -> Int = Tuple2.second row

test "the day buckets are one row each, in ascending key order" requires [dbRead, dbWrite] {
  let _ = seed ()
  expect List.length (minutesPerDay Utc) == 2
  expect dayMinutes Utc == [95, 15]
  expect dayStarts Utc == [1772323200, 1772409600]
}

test "a plain column groups too" requires [dbRead, dbWrite] {
  let _ = seed ()
  expect orgNames () == ["acme", "other"]
  expect orgCounts () == [3, 1]
}

# The row already there keeps its other columns; a row that is not there is inserted.
test "upsert updates only the columns it names" requires [dbRead, dbWrite] {
  let _ = seed ()
  let _ = touch "e1" 999
  expect orgNames () == ["acme", "other"]
  # e1 kept its startedAt — it is still in the first day's bucket, now at 999.
  expect dayMinutes Utc == [1034, 15]
}

test "upsert inserts when nothing conflicts" requires [dbRead, dbWrite] {
  let _ = touch "fresh" 7
  expect orgNames () == ["acme"]
  expect orgCounts () == [1]
}
|}

let test_group_by_with_go () =
  let emitted = match Compile.compile_go_source "<go-group-by>" group_by_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "grouped aggregate compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgogroupby/module.go" emitted in
  check bool "the grouped aggregate is one runtime call" true
    (contains module_go "teslrt.TableGroupFold(");
  (* The group key goes through the truncation engine, not a hand-rolled day division. *)
  check bool "a calendar key uses the truncation engine" true
    (contains module_go "teslrt.TimeTruncDay(");
  check bool "upsert is its own runtime call" true (contains module_go "teslrt.TableUpsert(");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-group-by" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      run_go_gates root)
  end

(* An OPAQUE record has no fields HERE, and comparing zero fields answers `true` for any two
   of them — which is not "equal" but "nothing was compared".  It made `zone a == zone b`
   inside `Tesl.CivilTime` a tautology, so two dates read in different calendars passed for
   the same one and a check that exists to refuse them accepted.  A record that the runtime
   does not say how to compare is now REFUSED rather than answered. *)
let test_opaque_record_equality_is_not_vacuous () =
  let source = {|module GoOpaqueEq exposing [sameProvider]

import Tesl.Prelude exposing [Bool, List, String]
import Tesl.Agent exposing [LlmProvider, mockProvider]

fn sameProvider(left: List String, right: List String) -> Bool =
  mockProvider left == mockProvider right
|} in
  match Compile.compile_go_source "<go-opaque-eq>" source with
  | Compile.GoSuccess _ ->
    fail "equality on an opaque record was answered instead of refused"
  | Compile.GoFailure diagnostics ->
    check bool "the refusal comes from the go emitter" true
      (List.exists (fun (d : Compile.diagnostic) -> d.source = "go-emitter") diagnostics)

(* ── An ADT type argument nothing constrains ──────────────────────────────────
   `Left "err"` says what its Left payload is and says NOTHING about the Right one, and a
   value written that way may never meet a context that settles it: `Either.withDefault 99
   (Left "err")` reads only the Left side.  Go needs a type there, and the honest one is
   "none of them" — the variant that would carry a Right value is not the variant in hand,
   so no value of that parameter exists and the empty struct is a witness.

   The three shapes that have to agree are here because each one broke a different way:
     - the DEFAULT settles the Right side of the Either beside it, so both arguments of the
       call have to be built at the same instantiation;
     - a list literal is settled ACROSS its elements — `[Left "e", Right 1]` learns its Left
       type from one element and its Right type from another;
     - `Either.partition []` has no element at all, and both sides stay anonymous — the
       answer is two empty lists whatever they would have held. *)
let anon_type_argument_source = {|module GoAnon exposing [orDefault, errorsOf]

import Tesl.Prelude exposing [Int, String, List]
import Tesl.Either exposing [
  Either(..),
  Either.withDefault,
  Either.partition,
  Either.isLeft,
  Either.fromLeft,
]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Tuple exposing [Tuple2, Tuple2.first, Tuple2.second]

fn orDefault(e: Either String Int) -> Int = Either.withDefault 0 e

fn errorsOf(es: List (Either String Int)) -> List String =
  Tuple2.first (Either.partition es)

test "the default settles the side the Either never mentions" {
  expect Either.withDefault 99 (Left "err") == 99
  expect Either.withDefault 99 (Right 42) == 42
  expect orDefault (Left "e") == 0
}

test "a bare constructor still answers the predicates" {
  expect Either.isLeft (Left "e")
  expect Either.fromLeft (Left "e") == Something "e"
}

# One element knows the Left type, another knows the Right one.
test "a list literal is settled across its elements" {
  let xs = [Left "e1", Right 1, Left "e2", Right 2]
  let split = Either.partition xs
  expect Tuple2.first split == ["e1", "e2"]
  expect Tuple2.second split == [1, 2]
  expect errorsOf xs == ["e1", "e2"]
}

test "a list of only one side leaves the other anonymous" {
  let allLeft = Either.partition [Left "a", Left "b"]
  expect Tuple2.first allLeft == ["a", "b"]
  expect Tuple2.second allLeft == []
}

# No element at all: neither side is observable, and the answer is two empty lists.
test "an empty list partitions into two empty lists" {
  let empty = Either.partition []
  expect Tuple2.first empty == []
  expect Tuple2.second empty == []
}
|}

let test_anon_type_argument_with_go () =
  let emitted = match Compile.compile_go_source "<go-anon>" anon_type_argument_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "anonymous type argument compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let tests_go = artifact "internal/teslmodgoanon/module_test.go" emitted in
  (* The default's type reaches the constructor beside it: both are `teslrt.Int`. *)
  check bool "the default settles the Either's Right side" true
    (contains tests_go "teslrt.Either[string, teslrt.Int]");
  (* Nothing settles the side a one-sided list never mentions, and that is what it says. *)
  check bool "an unsettled side is the empty struct" true
    (contains tests_go "struct{}");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-anon" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      run_go_gates root)
  end

(* The wildcard must not become a way to write a value into a column it does not fit: a
   record field has a DECLARED type, which is never anonymous, and the comparison is against
   that. *)
let test_anon_does_not_widen_a_declared_type () =
  let mismatch = {|module GoAnonField exposing [wrap]

import Tesl.Prelude exposing [Int, String]
import Tesl.Either exposing [Either(..)]

record Box { held: Either String Int }

fn wrap(text: String) -> Box = Box { held: Left text }
|} in
  match Compile.compile_go_source "<go-anon-field>" mismatch with
  | Compile.GoFailure diagnostics ->
    failf "a field settled by its declared type failed: %s"
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  | Compile.GoSuccess artifacts ->
    let module_go = artifact "internal/teslmodgoanonfield/module.go" artifacts in
    (* The DECLARED field type is what the constructor is built at — not `struct{}`. *)
    check bool "the field's declared type settles the constructor" true
      (contains module_go "teslrt.Either[string, teslrt.Int]");
    check bool "no anonymous side survives into the field" false
      (contains module_go "teslrt.Either[string, struct{}]")

(* ── `Tesl.Url` and `Tesl.Net` ───────────────────────────────────────────────
   The Go half is a rule-for-rule port of `dsl/private/url-parse.rkt` and
   `dsl/private/host-classify.rkt`, NOT a wrapper over `net/url` and `net.ParseIP`, and the
   difference is the whole point of the module: `net.ParseIP` accepts the strict dotted quad
   and nothing else, while a resolver — and therefore curl, and therefore an attacker's URL —
   also accepts `2130706433`, `0x7f.0.0.1` and `127.1`, all of which are 127.0.0.1.  A
   classifier that does not know those spellings answers "public" for the loopback address.

   Two shapes below are the ones a hand-rolled guard gets wrong, and both are here because
   the Racket oracle beside this test agrees on them:
     - the userinfo cut is at the LAST `@`, so `https://a@trusted.example.com@127.0.0.1/`
       has host 127.0.0.1 rather than the trusted-looking name;
     - an unbracketed IPv6 literal is REFUSED rather than guessed at, because it is
       indistinguishable from a host with a bad port.

   `HostClass` is a real ADT rather than a string: a `case` over a classification is
   exhaustive, which is what makes "did you handle link-local?" a question the compiler
   answers. *)
let url_net_source = {|module GoUrlNet exposing [hostOf, allowed, describe, effectivePortOf]

import Tesl.Prelude exposing [Bool(..), String, Int]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Url exposing [
  Url,
  Url.parse,
  Url.scheme,
  Url.host,
  Url.port,
  Url.effectivePort,
  Url.path,
  Url.query,
  Url.fragment,
  Url.userInfo,
  Url.toString,
]
import Tesl.Net exposing [
  HostClass(..),
  Net.classifyHost,
  Net.normalizeHost,
  Net.isLoopback,
  Net.isPrivate,
  Net.isLinkLocal,
  Net.isCgnat,
  Net.isMulticast,
  Net.isIpLiteral,
  Net.isIpv4Mapped,
  Net.isForbiddenHost,
]

# Fail-closed: an unparseable URL yields a host that matches no allowlist.
fn hostOf(raw: String) -> String =
  case Url.parse raw of
    Nothing -> ""
    Something u -> Url.host u

fn allowed(raw: String) -> Bool =
  case Url.parse raw of
    Nothing -> False
    Something u -> !(Net.isForbiddenHost (Url.host u))

# Exhaustive over the classification: adding a class to the ADT would break this.
fn describe(host: String) -> String =
  case Net.classifyHost host of
    Loopback -> "loopback"
    PrivateIp -> "private"
    LinkLocal -> "link-local"
    Cgnat -> "cgnat"
    Multicast -> "multicast"
    Unspecified -> "unspecified"
    PublicIp -> "public"
    DomainName -> "domain"
    InvalidHost -> "invalid"

fn effectivePortOf(raw: String) -> Int =
  case Url.parse raw of
    Nothing -> 0
    Something u ->
      case Url.effectivePort u of
        Nothing -> 0
        Something p -> p

test "the inet_aton spellings are all 127.0.0.1" {
  expect describe "127.0.0.1" == "loopback"
  expect describe "127.1" == "loopback"
  expect describe "2130706433" == "loopback"
  expect describe "0x7f.0.0.1" == "loopback"
  expect describe "017700000001" == "loopback"
  expect Net.normalizeHost "0x7f.0.0.1" == Something "127.0.0.1"
  expect Net.normalizeHost "2130706433" == Something "127.0.0.1"
}

test "each private range is its own class" {
  expect describe "10.0.0.1" == "private"
  expect describe "172.16.0.1" == "private"
  expect describe "172.32.0.1" == "public"
  expect describe "169.254.169.254" == "link-local"
  expect describe "100.64.0.1" == "cgnat"
  expect describe "100.128.0.1" == "public"
  expect describe "224.0.0.1" == "multicast"
  expect describe "0.0.0.0" == "unspecified"
  expect describe "8.8.8.8" == "public"
}

test "localhost is loopback by RFC 6761, and a name that merely contains it is not" {
  expect describe "localhost" == "loopback"
  expect describe "LOCALHOST" == "loopback"
  expect describe "foo.localhost" == "loopback"
  expect describe "notlocalhost" == "domain"
  expect Net.isLoopback "foo.localhost"
  expect Net.isIpLiteral "localhost" == False
}

# An IPv6 literal needs its brackets: unbracketed, it is indistinguishable from a
# host with a bad port, so it is refused rather than guessed at.
test "IPv6 is classified in brackets and refused without them" {
  expect describe "[::1]" == "loopback"
  expect describe "::1" == "invalid"
  expect describe "[fe80::1]" == "link-local"
  expect describe "[::ffff:169.254.169.254]" == "link-local"
  expect describe "[2001:db8::1]" == "public"
  expect Net.isIpv4Mapped "[::ffff:169.254.169.254]"
  expect Net.isIpv4Mapped "[2001:db8::1]" == False
}

test "the classification predicates agree with the classification" {
  expect Net.isPrivate "10.0.0.1"
  expect Net.isLinkLocal "169.254.169.254"
  expect Net.isCgnat "100.64.0.1"
  expect Net.isMulticast "224.0.0.1"
  expect Net.isForbiddenHost "2130706433"
  expect Net.isForbiddenHost "example.com" == False
}

# The bypass: taking the FIRST `@` puts a trusted-looking name in the host slot.
test "userinfo is cut at the last @" {
  expect hostOf "https://a@trusted.example.com@127.0.0.1/" == "127.0.0.1"
  expect allowed "https://a@trusted.example.com@127.0.0.1/" == False
  expect hostOf "https://user:pass@example.com/" == "example.com"
}

test "the parts of a URL are the parts a check examines" {
  expect hostOf "HTTPS://Example.COM:8443/a/b?x=1#frag" == "example.com"
  expect effectivePortOf "https://example.com/" == 443
  expect effectivePortOf "http://example.com/" == 80
  expect effectivePortOf "ws://example.com/" == 80
  expect effectivePortOf "gopher://example.com/" == 0
  expect hostOf "http://example.com" == "example.com"
  expect hostOf "http://example.com:65536/" == ""
  expect hostOf "http://example.com:0/" == ""
  expect hostOf "http://example.com:abc/" == ""
}

# A backslash is a path separator to some clients and an ordinary character to
# others, so it is refused anywhere rather than read either way.
test "a URL that is not authority-based, or holds a backslash, does not parse" {
  expect hostOf "example.com" == ""
  expect hostOf "//example.com/" == ""
  expect hostOf "http:/example.com/" == ""
  expect hostOf "http://exam ple.com/" == ""
  expect hostOf "http://example.com\\@evil.com/" == ""
  expect hostOf "http://" == ""
}

test "toString rebuilds from the canonical parts, not from the input text" {
  case Url.parse "HTTPS://Example.COM:8443/a/b?x=1#frag" of
    Nothing -> expect False
    Something u -> {
      expect Url.scheme u == "https"
      expect Url.path u == "/a/b"
      expect Url.query u == Something "x=1"
      expect Url.fragment u == Something "frag"
      expect Url.userInfo u == Nothing
      expect Url.port u == Something 8443
      expect Url.toString u == "https://example.com:8443/a/b?x=1#frag"
    }
}

# `?` with nothing after it is not the same URL as no `?` at all, which is why
# these answer a Maybe rather than a String.
test "a written-but-empty query is not an absent query" {
  case Url.parse "http://example.com?" of
    Nothing -> expect False
    Something u -> {
      expect Url.query u == Something ""
      expect Url.path u == "/"
    }
  case Url.parse "http://example.com" of
    Nothing -> expect False
    Something u -> expect Url.query u == Nothing
}
|}

let test_url_net_with_go () =
  let emitted = match Compile.compile_go_source "<go-url-net>" url_net_source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics ->
      failf "Url/Net compilation failed: %s"
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  in
  let module_go = artifact "internal/teslmodgourlnet/module.go" emitted in
  check bool "parse answers a Maybe of the opaque value" true
    (contains module_go "teslrt.UrlParse(raw)");
  check bool "the accessors are the runtime's" true
    (contains module_go "teslrt.UrlHost(u)");
  (* A classification is a tag switch, which is what makes the `case` exhaustive. *)
  check bool "HostClass switches on the runtime tag" true
    (contains module_go "teslrt.HostClassLinkLocal");
  check bool "the classifier is the runtime's" true
    (contains module_go "teslrt.ClassifyHost(host)");
  let hostname_go = artifact "internal/teslrt/hostname.go" emitted in
  (* The reason this file exists rather than a `net.ParseIP` call. *)
  check bool "the inet_aton spellings are parsed here" true
    (contains hostname_go "parseIPv4Any");
  let url_go = artifact "internal/teslrt/url.go" emitted in
  check bool "the userinfo cut is at the last @" true
    (contains url_go "LastIndexByte(authority, '@')");
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-go-url-net" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_artifacts root emitted;
      let unformatted = run_command root "gofmt -l ." |> String.trim in
      if unformatted <> "" then
        failf "emitted source is not gofmt-clean (%s):\n%s"
          unformatted (run_command root "gofmt -d .");
      ignore (run_command root "go test -count=1 ./...");
      ignore (run_command root "go vet ./...");
      ignore (run_command root "go test -race -count=1 ./...");
      run_go_gates root)
  end

(* A program that parses no URLs must not carry either file — and they travel together,
   because a URL's host is canonicalised by the classifier. *)
let test_url_net_runtime_ships_only_where_used () =
  let plain = {|module GoNoUrl exposing [twice]
import Tesl.Prelude exposing [Int]

fn twice(n: Int) -> Int = n * 2
|} in
  match Compile.compile_go_source "<go-no-url>" plain with
  | Compile.GoFailure diagnostics ->
    failf "plain module failed: %s"
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  | Compile.GoSuccess artifacts ->
    List.iter (fun path ->
      check bool ("no " ^ path ^ " in a module that parses no URLs") false
        (List.exists (fun (a : Emit_go.artifact) -> a.path = path) artifacts))
      [ "internal/teslrt/url.go"; "internal/teslrt/hostname.go" ]

let () =
  run "emit_go" [
    "emission", [
      test_case "artifact layout and helpers" `Quick test_artifact_layout;
      test_case "App module does not shadow Tesl.App" `Quick test_app_module_does_not_shadow_tesl_app;
      test_case "debug emission has versioned checkpoint" `Quick test_debug_emission_has_versioned_checkpoint;
      test_case "release emission excludes debug runtime" `Quick test_release_emission_excludes_debug_runtime;
      test_case "release artifacts have no debug symbols" `Quick test_release_artifacts_have_no_debug_symbols;
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
      test_case "unreachable private functions are emitted" `Slow test_unreachable_private_function_is_emitted;
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
      test_case "higher-order list leaves" `Slow test_higher_order_lists_with_go;
      test_case "check-driven list leaves" `Slow test_check_driven_lists_with_go;
      test_case "tuples" `Slow test_tuples_with_go;
      test_case "Either from the runtime" `Slow test_either_with_go;
      test_case "Tesl.Dict leaves" `Slow test_dicts_with_go;
      test_case "Float" `Slow test_floats_with_go;
      test_case "Tesl.Set leaves" `Slow test_sets_with_go;
      test_case "multi-module program" `Slow test_multi_module_with_go;
      test_case "cross-module types" `Slow test_cross_module_types_with_go;
      test_case "import cycle" `Slow test_import_cycle_with_go;
      test_case "import cycle across three modules" `Slow test_import_cycle_three_modules_with_go;
      test_case "sets behave the same on Racket" `Slow (racket_behavior_oracle "<go-sets>" set_source);
      test_case "Float behaves the same on Racket" `Slow (racket_behavior_oracle "<go-floats>" float_source);
      test_case "HTTP api, server and handlers" `Slow test_http_server_with_go;
      test_case "HTTP auth at the trust boundary" `Slow test_http_auth_with_go;
      test_case "HTTP checked path captures" `Slow test_http_capture_with_go;
      test_case "release/debug unattached equivalence" `Slow test_release_debug_unattached_equivalence;
      test_case "HTTP cookie writing via requires [cookieCap]" `Slow test_http_cookie_with_go;
      test_case "Tesl api-tests run against the Go server" `Slow test_go_api_tests;
      test_case "api-test bodies are untyped" `Slow test_api_test_json_with_go;
      test_case "untyped api-test bodies behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-api-json-oracle>" api_json_source);
      test_case "secret newtypes" `Slow test_secret_newtype_with_go;
      test_case "secrets behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-secret-oracle>" secret_source);
      test_case "a secret over a non-String fails closed" `Quick
        test_secret_over_non_string_fails_closed;
      test_case "function values and lambdas" `Slow test_function_values_with_go;
      test_case "function values behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-func-value-oracle>" function_value_source);
      test_case "combined checks" `Slow test_combined_check_with_go;
      test_case "combined checks behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-combined-check-oracle>" combined_check_source);
      test_case "`case` as a test statement" `Slow test_case_statement_with_go;
      test_case "test-statement case behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-test-case-oracle>" test_case_stmt_source);
      test_case "check-driven container leaves" `Slow test_check_leaves_with_go;
      test_case "check-driven leaves behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-check-leaves-oracle>" check_leaf_source);
      test_case "a seeded api-test" `Slow test_seeded_api_test_with_go;
      test_case "seeded api-tests behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-seeded-oracle>" seeded_source);
      test_case "Tesl.Telemetry, Tesl.App and load tests" `Slow test_telemetry_app_with_go;
      test_case "debug main starts control server" `Quick test_debug_main_starts_control_server;
      test_case "telemetry and App behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-telemetry-app-oracle>" telemetry_app_source);
      test_case "`case` over a scalar" `Slow test_scalar_case_with_go;
      test_case "scalar case behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-scalar-case-oracle>" scalar_case_source);
      test_case "`case` over a newtype scrutinee (Go-only; Racket raises)" `Slow
        test_newtype_case_with_go;
      test_case "Tesl.JWT and the session cookie" `Slow test_jwt_with_go;
      test_case "JWT and sessions behave the same on Racket" `Slow
        (racket_behavior_oracle ~env:[ "GOJWT_KEY=test-session-key" ] "<go-jwt-oracle>" jwt_source);
      test_case "Tesl.Crypto: MACs, digests, tokens" `Slow test_crypto_with_go;
      test_case "Tesl.Crypto behaves the same on Racket" `Slow
        (racket_behavior_oracle ~env:[ "GOCRYPTO_KEY=test-signing-key" ]
           "<go-crypto-oracle>" crypto_source);
      test_case "password storage (Argon2id)" `Slow test_password_storage_with_go;
      test_case "password storage behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-password-oracle>" password_source);
      test_case "the Argon2 dependency ships only where needed" `Quick
        test_password_dependency_ships_only_where_needed;
      test_case "the dependency pin matches the runtime module" `Quick
        test_dependency_pin_matches_the_runtime_module;
      test_case "derived decoders for a body with no codec" `Slow test_derived_body_with_go;
      test_case "derived decoders behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-derived-body-oracle>" derived_body_source);
      test_case "an `auth` module ships the HTTP runtime it references" `Slow
        test_auth_without_server_ships_the_http_runtime;
      test_case "nested comprehensions" `Slow test_nested_comprehension_with_go;
      test_case "nested comprehensions behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-nested-comprehension-oracle>" nested_comprehension_source);
      test_case "outbound HTTP and its test double" `Slow test_httpclient_with_go;
      test_case "outbound HTTP behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-httpclient-oracle>" httpclient_source);
      test_case "secret-accepting outbound headers" `Slow test_secret_header_with_go;
      test_case "secret headers behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-secret-header-oracle>" secret_header_source);
      test_case "an upstream timeout inside a worker" `Slow test_http_worker_with_go;
      test_case "a worker's upstream timeout behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-http-worker-oracle>" http_worker_source);
      test_case "Memory-backend queues" `Slow test_queue_with_go;
      test_case "queues behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-queue-oracle>" queue_source);
      test_case "Memory-backend databases" `Slow test_db_with_go;
      test_case "databases behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-db-oracle>" db_source);
      test_case "Tesl.Int32" `Slow test_int32_with_go;
      test_case "Int32 behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-int32-oracle>" int32_source);
      test_case "a declared unique index" `Slow test_unique_index_with_go;
      test_case "a unique index behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-unique-index-oracle>" unique_index_source);
      test_case "an instant on the wire" `Slow test_posix_codec_with_go;
      test_case "an instant on the wire behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-posix-codec-oracle>" posix_codec_source);
      test_case "a Postgres round trip" `Slow test_postgres_live_with_go;
      test_case "a Postgres round trip behaves the same on Racket" `Slow
        test_postgres_live_oracle;
      test_case "payload ADT, secret and nullable columns" `Slow test_pg_columns_with_go;
      test_case "those columns behave the same on Racket" `Slow test_pg_columns_oracle;
      test_case "every server clause reaches the boot init" `Slow test_server_clauses_with_go;
      test_case "server clauses behave the same on Racket" `Slow
        (racket_behavior_oracle
           ~env:["GOCLAUSES_SESSION_KEY=clauses-signing-key-0123456789";
                 "GOCLAUSES_PREVIOUS_KEY=clauses-previous-key-0123456789"]
           "<go-server-clauses-oracle>" server_clauses_source);
      test_case "trustedProxies fails closed" `Quick test_trusted_proxies_fails_closed;
      test_case "List.unique takes a keyed path where it can" `Slow test_list_unique_with_go;
      test_case "keyed unique behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-list-unique-oracle>" list_unique_source);
      test_case "a declared JSON payload is checked before parsing" `Slow
        test_json_payload_with_go;
      test_case "polymorphic equality travels as a dictionary" `Slow test_poly_equality_with_go;
      test_case "polymorphic equality behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-poly-equality-oracle>" poly_equality_source);
      test_case "a wide ADT is emitted boxed" `Slow test_wide_adt_is_boxed;
      test_case "a boxed ADT behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-wide-adt-oracle>" wide_adt_source);
      test_case "Tesl.Cache" `Slow test_cache_with_go;
      test_case "caches behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-cache-oracle>" cache_source);
      test_case "Tesl.Money and Tesl.Units" `Slow test_money_with_go;
      test_case "money and units behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-money-oracle>" money_source);
      test_case "property tests" `Slow test_property_with_go;
      test_case "properties behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-property-oracle>" property_source);
      test_case "SSE channels, publish and subscribe" `Slow test_sse_with_go;
      test_case "SSE behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-sse-oracle>" sse_source);
      test_case "a Memory-backend transaction" `Slow test_transaction_with_go;
      test_case "transactions behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-transaction-oracle>" transaction_source);
      test_case "a fail in a plain function" `Slow test_fail_in_a_function_with_go;
      test_case "a failing function behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-fail-oracle>" fail_source);
      test_case "Tesl.Email" `Slow test_email_with_go;
      test_case "email behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-email-oracle>" email_source);
      test_case "Tesl.UUID" `Slow test_uuid_with_go;
      test_case "UUIDs behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-uuid-oracle>" uuid_source);
      test_case "nested constructor patterns" `Slow test_nested_patterns_with_go;
      test_case "nested patterns behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-nested-oracle>" nested_pattern_source);
      test_case "recursive ADTs" `Slow test_recursive_adt_with_go;
      test_case "recursive ADTs behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-recursive-oracle>" recursive_adt_source);
      test_case "container and Either leaves" `Slow test_leaves2_with_go;
      test_case "container and Either leaves behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-leaves2-oracle>" leaves2_source);
      test_case "a Postgres-backed entity" `Slow test_postgres_declaration_with_go;
      test_case "a Postgres-backed entity behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-pg-decl-oracle>" postgres_declaration_source);
      test_case "a rejected check answers instead of crashing" `Slow
        test_check_delegation_with_go;
      test_case "check delegation behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-check-delegate-oracle>" check_delegation_source);
      test_case "instants (Tesl.Time core)" `Slow test_time_with_go;
      test_case "instants behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-time-oracle>" time_source);
      test_case "env, randomness and ids" `Slow test_effect_leaves_with_go;
      test_case "effect leaves behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-effects-oracle>" effects_source);
      test_case "establish and detached proofs" `Slow test_establish_with_go;
      test_case "detached proofs behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-establish>" establish_source);
      test_case "more Tesl.Int leaves" `Slow test_int_leaves_with_go;
      test_case "more Tesl.Int leaves behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-int-leaves>" int_leaves_source);
      test_case "proof-bearing returns" `Slow test_proof_bearing_returns_with_go;
      test_case "proof-bearing returns behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-proof-returns>" proof_return_source);
      test_case "an unconstrained empty list compiles" `Slow
        test_unconstrained_empty_list_compiles;
      test_case "higher-order Tesl.List leaves" `Slow test_higher_order_leaves_with_go;
      test_case "higher-order leaves behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-hof-leaves>" higher_order_leaves_source);
      test_case "filterMap keeps a falsy payload on both backends" `Slow
        (racket_behavior_oracle "<go-filtermap-bool>" filter_map_bool_source);
      test_case "Tesl.Agent" `Slow test_agent_with_go;
      test_case "Tesl.Agent behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-agent>" agent_source);
      test_case "unsupported Tesl.Agent forms fail closed" `Quick test_agent_limits_fail_closed;
      test_case "serverTools and humanActions" `Slow test_endpoint_tools_with_go;
      test_case "Tesl.Proxy" `Slow test_proxy_with_go;
      test_case "Tesl.Regex" `Slow test_regex_with_go;
      test_case "Tesl.Regex behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-regex>" regex_source);
      test_case "the regex runtime ships only where used" `Quick
        test_regex_runtime_ships_only_where_used;
      test_case "Tesl.Sso: the runtime-owned login routes" `Slow test_sso_with_go;
      test_case "Tesl.Sso behaves the same on Racket" `Slow
        (racket_behavior_oracle
           ~env:["GO_SSO_SESSION_KEY=go-sso-signing-key";
                 "GO_SSO_CLIENT_SECRET=go-sso-client-secret"]
           "<go-sso>" sso_source);
      test_case "a queue carrying more than one job type" `Slow test_multi_job_queue_with_go;
      test_case "a queue carrying more than one job type behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-multi-job>" multi_job_queue_source);
      test_case "a recursive generic at another instantiation" `Slow
        test_recursive_generic_with_go;
      test_case "a recursive generic behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-rec-generic>" recursive_generic_source);
      test_case "a generic function" `Slow test_generic_function_with_go;
      test_case "a generic function behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-generic>" generic_function_source);
      test_case "an uninferable type parameter fails closed" `Quick
        test_uninferable_type_parameter_fails_closed;
      test_case "a case in a test block is a chain" `Slow test_case_statement_chain_with_go;
      test_case "a case in a test block behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-case-stmt>" case_statement_source);
      test_case "the calendar half of Tesl.Time" `Slow test_time_zone_with_go;
      test_case "the calendar half of Tesl.Time behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-timezone>" time_zone_source);
      test_case "grouped aggregates and upsert" `Slow test_group_by_with_go;
      test_case "grouped aggregates and upsert behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-group-by>" group_by_source);
      test_case "equality on an opaque record is refused, not vacuous" `Quick
        test_opaque_record_equality_is_not_vacuous;
      test_case "an ADT type argument nothing constrains" `Slow
        test_anon_type_argument_with_go;
      test_case "an ADT type argument nothing constrains behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-anon>" anon_type_argument_source);
      test_case "an anonymous type argument does not widen a declared type" `Quick
        test_anon_does_not_widen_a_declared_type;
      test_case "Tesl.Url and Tesl.Net" `Slow test_url_net_with_go;
      test_case "Tesl.Url and Tesl.Net behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-url-net>" url_net_source);
      test_case "the url/net runtime ships only where used" `Quick
        test_url_net_runtime_ships_only_where_used;
      test_case "property generators over proof-carrying records" `Slow
        test_property_generators_with_go;
      test_case "proof-aware generators behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-prop-gen>" property_generator_source);
      test_case "conjunctions whose conjuncts capture" `Slow test_captured_conjunction_with_go;
      test_case "captured conjunctions behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-combined>" captured_conjunction_source);
      test_case "a column-type mismatch fails closed" `Quick
        test_column_type_mismatch_fails_closed;
      test_case "proof shapes at the edges of erasure" `Slow test_proof_shapes_with_go;
      test_case "proof shapes behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-proof-shapes>" proof_shapes_source);
      test_case "Racket-only proof failures fail closed" `Quick
        test_racket_only_proof_failures_fail_closed;
      test_case "the request boundary: captures, list bodies, chained checks" `Slow
        test_boundary_with_go;
      test_case "the request boundary behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-boundary>" boundary_source);
      test_case "a newtype over a newtype, and unobservable containers" `Slow
        test_ordered_newtype_with_go;
      test_case "nested newtypes behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-ord>" ordered_newtype_source);
      test_case "empty containers, and what a seed block describes" `Slow
        test_inference_with_go;
      test_case "empty-container inference behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-infer>" inference_source);
      test_case "formatTime" `Slow test_format_time_with_go;
      test_case "the timezone database ships only where used" `Quick
        test_timezone_data_ships_only_where_used;
      test_case "partial application, and a newtype named as a codec" `Slow
        test_partial_with_go;
      test_case "partial application behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-partial>" partial_source);
      test_case "a plain-value check tail, and the Float transcendentals" `Slow
        test_float_check_with_go;
      test_case "plain-value checks behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-float-check>" float_check_source);
      test_case "Tesl.Proxy behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-proxy>" proxy_source);
      test_case "endpoint tools behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-endpoint-tools>" endpoint_tools_source);
      test_case "more Tesl.List leaves" `Slow test_list_leaves_with_go;
      test_case "more Tesl.List leaves behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-list-leaves>" list_leaves_source);
      test_case "List.foldr" `Slow test_foldr_with_go;
      test_case "List.foldr behaves the same on Racket" `Slow
        (racket_behavior_oracle "<go-foldr>" foldr_source);
      test_case "folds with an empty accumulator" `Slow test_fold_empty_init_with_go;
      test_case "empty-init folds behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-fold-empty-init>" fold_empty_init_source);
      test_case "Float keys in Dict and Set" `Slow test_float_keys_with_go;
      test_case "Float keys behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-float-keys>" float_key_source);
      test_case "dicts behave the same on Racket" `Slow (racket_behavior_oracle "<go-dicts>" dict_source);
      test_case "unordered dict keys fail closed" `Quick test_unordered_dict_keys_fail_closed;
      test_case "Either behaves the same on Racket" `Slow (racket_behavior_oracle "<go-either>" either_source);
      test_case "tuples behave the same on Racket" `Slow (racket_behavior_oracle "<go-tuples>" tuple_source);
      test_case "check-driven lists behave the same on Racket" `Slow (racket_behavior_oracle "<go-check-lists>" check_list_source);
      test_case "higher-order lists behave the same on Racket" `Slow (racket_behavior_oracle "<go-hof>" hof_source);
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
