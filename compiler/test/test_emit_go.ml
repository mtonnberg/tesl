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
  let expect_go_error label needle source =
    match Compile.compile_go_source ("<" ^ label ^ ">") source with
    | Compile.GoSuccess _ -> failf "%s emitted unsupported Go artifacts" label
    | Compile.GoFailure diagnostics ->
      check bool label true
        (List.exists (fun (d : Compile.diagnostic) ->
           d.source = "go-emitter" && contains d.message needle) diagnostics)
  in
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
  (* The point of this case survives: the runtime ADTs are whitelisted BY NAME, not
     "any stdlib ADT".  One that has no runtime type behind it still fails closed. *)
  let unsupported = {|module DeleteResultUser exposing [count]
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [DeleteResult(..)]
fn count(r: DeleteResult) -> Int = 0
|} in
  match Compile.compile_go_source "<go-delete-result>" unsupported with
  | Compile.GoSuccess _ -> fail "an unsupported stdlib ADT emitted Go artifacts"
  | Compile.GoFailure diagnostics ->
    check bool "an unlisted stdlib ADT is refused" true
      (List.exists (fun (d : Compile.diagnostic) ->
         d.source = "go-emitter" && contains d.message "`Tesl.DB` export") diagnostics)

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

(* Tesl functions are curried and lambdas are real closures, so a function VALUE is a
   language feature rather than a corner case — and it needs a calling-convention
   decision the backend has not made.  Until then it must fail closed rather than
   emit something that only works for the fully-applied shape. *)
let test_function_values_fail_closed () =
  let expect_failure label source =
    match Compile.compile_go_source ("<" ^ label ^ ">") source with
    | Compile.GoSuccess _ -> failf "%s emitted Go artifacts" label
    | Compile.GoFailure diagnostics ->
      check bool label true
        (List.exists (fun (d : Compile.diagnostic) ->
           d.source = "go-emitter") diagnostics)
  in
  expect_failure "let-bound lambda as a function value" {|module LambdaValue exposing [doubled]
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.map]
fn doubled(xs: List Int) -> List Int =
  let twice = fn(x: Int) -> x * 2
  List.map twice xs
|};
  (* A partial application AT a higher-order argument is supported — it emits fully
     applied — so the boundary is a partial application used as a VALUE. *)
  expect_failure "let-bound partial application" {|module PartialValue exposing [shifted]
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.map]
fn add(a: Int, b: Int) -> Int = a + b
fn shifted(xs: List Int) -> List Int =
  let bump = add 1
  List.map bump xs
|}

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
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(method, path, strings.NewReader(body))
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
  check bool "auth runs before the handler body" true
    (contains module_go "teslAuth := CookieAuth(teslrt.NewHttpRequest(teslRequest, \"\"))");
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
  expect r.body == "{\"message\":\"hi\"}"
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

let gate_emitted prefix emitted =
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir prefix "" in
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

let test_http_capture_with_go () =
  let emitted = emit_ok "<go-http-capture>" http_capture_source in
  let module_go = artifact "internal/teslmodgohttpcapture/module.go" emitted in
  check bool "the capturer's check runs on the segment" true
    (contains module_go "teslCapturedId := CheckId(id)");
  check bool "a failing capture returns the check's own status" true
    (contains module_go "return teslrt.Fail(teslCapturedId.Status(), teslCapturedId.Message())");
  gate_emitted "tesl-go-http-capture" emitted

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
    (contains tests_go "teslrt.ApiRequest(HelloServer, \"GET\", \"/hello\", \"\")");
  check bool "a status predicate becomes a runtime call" true
    (contains tests_go "teslrt.StatusOk(r.Status)");
  (* `go test` on the emitted tree RUNS these, so a wrong body or status fails here. *)
  gate_emitted "tesl-go-api-test" emitted


(* ─── Databases ───────────────────────────────────────────────────────────────
   The `backend: Memory` slice end to end: an entity's row struct and table, the write
   forms (insert / insertMany / update … set / delete), and the read forms (select,
   selectOne, selectCount, selectSum, selectMax/Min, where predicates including `like`,
   `order`, `limit`).  Racket runs the same source as the oracle. *)
let db_source = {|module GoDb exposing [orderedNames, titleOf]

import Tesl.Prelude exposing [Bool(..), Int, String, List, Unit]
import Tesl.List exposing [List.length, List.map, List.head]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.DB exposing [dbRead, dbWrite]
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
  with database ProbeDb {
    let found = selectOne i from Item where i.id == wanted
    case found of
      Nothing -> "none"
      Something i -> i.name
  }

fn orderedNames() -> List String
  requires [dbRead] =
  with database ProbeDb {
    let rows = select i from Item order i.qty desc
    List.map (fn(i: Item) -> i.name) rows
  }

fn cheapestName() -> String
  requires [dbRead] =
  with database ProbeDb {
    let rows = select i from Item order i.qty asc limit 1
    case List.head rows of
      Nothing -> "none"
      Something i -> i.name
  }

fn countAbove(threshold: Int) -> Int
  requires [dbRead] =
  with database ProbeDb {
    selectCount i from Item where i.qty > threshold
  }

fn totalQty() -> Int
  requires [dbRead] =
  with database ProbeDb {
    selectSum i.qty from Item
  }

# selectMax/selectMin answer a Maybe: no matching row has no maximum.
fn biggestQty() -> Int
  requires [dbRead] =
  with database ProbeDb {
    case selectMax i.qty from Item of
      Nothing -> 0
      Something qty -> qty
  }

fn smallestQty() -> Int
  requires [dbRead] =
  with database ProbeDb {
    case selectMin i.qty from Item of
      Nothing -> 0
      Something qty -> qty
  }

# The empty answer itself, over a predicate nothing matches.
fn biggestQtyNamed(wanted: String) -> Maybe Int
  requires [dbRead] =
  with database ProbeDb {
    selectMax i.qty from Item where i.name == wanted
  }

fn namesLike(pattern: String) -> Int
  requires [dbRead] =
  with database ProbeDb {
    selectCount i from Item where like i.name pattern
  }

fn namesILike(pattern: String) -> Int
  requires [dbRead] =
  with database ProbeDb {
    selectCount i from Item where ilike i.name pattern
  }

fn bySku(raw: String) -> Int
  requires [dbRead] =
  with database ProbeDb {
    selectCount i from Item where i.sku == Sku raw
  }

fn eitherName(left: String, right: String) -> Int
  requires [dbRead] =
  with database ProbeDb {
    selectCount i from Item where i.name == left || i.name == right
  }

fn seed() -> Unit
  requires [dbWrite] =
  with database ProbeDb {
    let _ = insert Item { id: "i1", sku: Sku "S-1", name: "alpha", qty: 7 }
    let rest = [
      Item { id: "i2", sku: Sku "S-2", name: "beta", qty: 3 },
      Item { id: "i3", sku: Sku "S-3", name: "Gamma", qty: 5 }
    ]
    let _ = insertMany rest in Item
    Unit
  }

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
  with database ProbeDb {
    let _ = insert Item { id: "u1", sku: Sku "S-U1", name: "delta", qty: 20 }
    let _ = insert Item { id: "u2", sku: Sku "S-U2", name: "epsilon", qty: 30 }
    Unit
  }
  with database ProbeDb {
    update i in Item
      where i.id == "u1"
      set i.name = "renamed"
      set i.qty = 21
  }
  expect titleOf "u1" == "renamed"
  expect biggestQty () == 30
  expect titleOf "u1" == "renamed"
  expect countAbove 19 == 2
  with database ProbeDb {
    delete i from Item where i.qty > 25
  }
  expect countAbove 19 == 1
  expect titleOf "u2" == "none"
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
  check bool "a where clause becomes a predicate over the row" true
    (contains module_go
       "teslrt.TableSelectOne(ItemTable, func(i Item) bool { return (i.Id == wanted) })");
  check bool "`order … desc` swaps the comparison rather than sorting twice" true
    (contains module_go
       "teslrt.TableSelectSorted(ItemTable, func(_ Item) bool { return true }, func(teslLeft, teslRight Item) bool { return (teslrt.Compare(teslRight.Qty, teslLeft.Qty) < 0) }, 0, -1)");
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
  (* `go test` RUNS the two test blocks, so a wrong answer fails here. *)
  gate_emitted "tesl-go-db" emitted

let test_unsupported_database_forms_fail_closed () =
  let expect_go_error name source needle =
    match Compile.compile_go_source ("<go-" ^ name ^ ">") source with
    | Compile.GoSuccess _ -> failf "%s emitted instead of failing closed" name
    | Compile.GoFailure diagnostics ->
      check bool (name ^ " fails closed") true
        (List.exists (fun (d : Compile.diagnostic) ->
           d.source = "go-emitter" && contains d.message needle) diagnostics)
  in
  let program ~entity_extra ~backend ~body = Printf.sprintf {|module GoDbBad exposing [probe]
import Tesl.Prelude exposing [Int, String, List]
import Tesl.DB exposing [dbRead]
import Tesl.Database exposing [Database, Memory, Postgres, PostgresConfig, TcpConnection]

entity Item table "bad_items" primaryKey id {
  id: String
  qty: Int%s
}

database BadDb = Database {
  schema: "public"
  entities: [Item]
  backend: %s
}

fn probe() -> List Item
  requires [dbRead] =
  with database BadDb {
    %s
  }
|} entity_extra backend body
  in
  (* Postgres needs a driver; running it against an in-memory store instead would be a
     silent substitution, so it is refused. *)
  expect_go_error "postgres-backend"
    (program ~entity_extra:""
       ~backend:"Postgres (PostgresConfig {\n    dbName: \"x\"\n    user: \"u\"\n    password: \"p\"\n    connection: TcpConnection {\n      host: \"localhost\"\n      port: 5432\n    }\n  })"
       ~body:"select i from Item")
    "`backend: Memory` only";
  (* A UNIQUE index is ENFORCED by the Racket memory backend, so accepting one without
     enforcing it would make the two backends run different programs. *)
  expect_go_error "unique-index"
    (program ~entity_extra:"\n  unique index [qty]" ~backend:"Memory"
       ~body:"select i from Item")
    "unique index";
  expect_go_error "inner-join"
    (program ~entity_extra:"" ~backend:"Memory"
       ~body:"select i from Item innerJoin Item on i.id Item.id")
    "innerJoin"


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

import Tesl.Prelude exposing [Int, String, Unit]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Json exposing [stringCodec, intCodec]
import Tesl.Database exposing [Database, Memory]
import Tesl.Queue exposing [
  FromQueue,
  queueRead,
  queueWrite,
  Queue,
  QueueRetryStrategy,
  Fixed,
]
import Tesl.ApiTest exposing [
  statusOk,
  JobResult(..),
  processNextJob,
  pendingJobCount,
  expectJobOk,
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

api QueueApi {
  post "/send"
    body request: TriggerRequest
    -> TriggerReply
}

server QueueServer for QueueApi {
  send
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
    (contains tests_go "teslrt.ApiRequest(QueueServer, \"POST\", \"/send\", \"{\\\"tag\\\":\\\"one\\\"}\")");
  (* `go test` RUNS the api-test: FIFO order and the pending count are asserted there. *)
  gate_emitted "tesl-go-queue" emitted


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

let test_divergent_float_functions_fail_closed () =
  (* Go's sin/cos/tan disagree with Racket on 22-34% of inputs and its math.Log is
     outright wrong for subnormals, so these are rejected rather than emitted
     divergent.  sqrt is the one that is bit-identical, and it IS supported. *)
  let expect_go_error name source =
    match Compile.compile_go_source ("<go-" ^ name ^ ">") source with
    | Compile.GoSuccess _ -> failf "%s emitted Go artifacts" name
    | Compile.GoFailure diagnostics ->
      check bool name true
        (List.exists (fun (d : Compile.diagnostic) ->
           d.source = "go-emitter" && contains d.message ("`" ^ name ^ "`")) diagnostics)
  in
  List.iter (fun name ->
    expect_go_error name (Printf.sprintf {|module Divergent exposing [apply]
import Tesl.Float exposing [Float, %s]
fn apply(x: Float) -> Float = %s x
|} name name)) ["Float.log"; "Float.exp"; "Float.sin"; "Float.cos"; "Float.tan"]

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
      run_go_gates root)

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
  (* Float and Set fields both work now, so the boundary is the one that will outlast
     the collection tier: a FUNCTION-typed field, which needs the calling-convention
     decision function values are waiting on. *)
  expect_go_error "unsupported record field type" "function values"
    {|module FunctionFieldRecord exposing [Handler, run]
import Tesl.Prelude exposing [Int]
record Handler {
  apply: Int -> Int
}
fn run(h: Handler) -> Int = 0
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
      test_case "HTTP cookie writing via requires [cookieCap]" `Slow test_http_cookie_with_go;
      test_case "Tesl api-tests run against the Go server" `Slow test_go_api_tests;
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
      test_case "Memory-backend queues" `Slow test_queue_with_go;
      test_case "queues behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-queue-oracle>" queue_source);
      test_case "Memory-backend databases" `Slow test_db_with_go;
      test_case "databases behave the same on Racket" `Slow
        (racket_behavior_oracle "<go-db-oracle>" db_source);
      test_case "unsupported database forms fail closed" `Quick
        test_unsupported_database_forms_fail_closed;
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
      test_case "divergent Float functions fail closed" `Quick test_divergent_float_functions_fail_closed;
      test_case "dicts behave the same on Racket" `Slow (racket_behavior_oracle "<go-dicts>" dict_source);
      test_case "unordered dict keys fail closed" `Quick test_unordered_dict_keys_fail_closed;
      test_case "Either behaves the same on Racket" `Slow (racket_behavior_oracle "<go-either>" either_source);
      test_case "tuples behave the same on Racket" `Slow (racket_behavior_oracle "<go-tuples>" tuple_source);
      test_case "check-driven lists behave the same on Racket" `Slow (racket_behavior_oracle "<go-check-lists>" check_list_source);
      test_case "higher-order lists behave the same on Racket" `Slow (racket_behavior_oracle "<go-hof>" hof_source);
      test_case "function values fail closed" `Quick test_function_values_fail_closed;
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
