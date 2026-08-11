open Alcotest

let strong_source = {|module GoMutationBoundary exposing [Positive, checkPositive]
import Tesl.Prelude exposing [Int]

fact Positive (n: Int)

check checkPositive(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 422 "not positive"

test "boundary kills every mutation" {
  expect check checkPositive 1 == 1
  expectFail check checkPositive 0
  expectFail check checkPositive -1
}
|}

let weak_source = {|module GoMutationBoundary exposing [Positive, checkPositive]
import Tesl.Prelude exposing [Int]

fact Positive (n: Int)

check checkPositive(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 422 "not positive"

test "typical value misses boundaries" {
  expect check checkPositive 5 == 5
}
|}

let red_baseline_source = {|module GoMutationBoundary exposing [Positive, checkPositive]
import Tesl.Prelude exposing [Int]

fact Positive (n: Int)

check checkPositive(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 422 "not positive"

test "red baseline" {
  expect check checkPositive 1 == 99
}
|}

let huge_boundary_source = {|module GoMutationBoundary exposing [Huge, checkHuge]
import Tesl.Prelude exposing [Int]

fact Huge (n: Int)

check checkHuge(n: Int) -> n: Int ::: Huge n =
  if n > 9223372036854775808 then
    ok n ::: Huge n
  else
    fail 422 "not huge"

test "huge boundary" {
  expect check checkHuge 9223372036854775809 == 9223372036854775809
  expectFail check checkHuge 9223372036854775808
}
|}

let negative_boundary_source = {|module GoMutationBoundary exposing [AboveNegativeOne, checkAboveNegativeOne]
import Tesl.Prelude exposing [Int]

fact AboveNegativeOne (n: Int)

check checkAboveNegativeOne(n: Int) -> n: Int ::: AboveNegativeOne n =
  if n > -1 then
    ok n ::: AboveNegativeOne n
  else
    fail 422 "too small"

test "negative boundary" {
  expect check checkAboveNegativeOne 0 == 0
  expectFail check checkAboveNegativeOne -1
}
|}

let with_source source f =
  let dir = Filename.temp_dir "tesl-go-mutation" "" in
  let path = Filename.concat dir "go-mutation-boundary.tesl" in
  Out_channel.with_open_bin path (fun channel -> output_string channel source);
  Fun.protect
    ~finally:(fun () -> Sys.remove path; Unix.rmdir dir)
    (fun () -> f path)

let require_go () =
  if Sys.command "go version >/dev/null 2>&1" <> 0 then skip ()

let starts_with prefix value =
  String.length value >= String.length prefix
  && String.sub value 0 (String.length prefix) = prefix

let report source =
  require_go ();
  with_source source (fun path ->
    match Compile.mutate_go_file path with
    | Compile.MutateOk report -> report
    | Compile.MutateErr message -> fail message)

let test_strong_suite_kills_all () =
  let report = report strong_source in
  check int "mutant count" 4 report.Mutate.total;
  check int "killed" 4 report.Mutate.killed;
  check int "survived" 0 report.Mutate.survived;
  check int "invalid" 0 report.Mutate.invalid;
  check int "errors" 0 report.Mutate.errors

let test_weak_suite_reports_survivors () =
  let report = report weak_source in
  check int "mutant count" 4 report.Mutate.total;
  check int "killed" 2 report.Mutate.killed;
  check int "survived" 2 report.Mutate.survived;
  check int "invalid" 0 report.Mutate.invalid;
  check int "errors" 0 report.Mutate.errors

let test_red_baseline_never_scores_mutants () =
  require_go ();
  with_source red_baseline_source (fun path ->
    match Compile.mutate_go_file path with
    | Compile.MutateOk _ -> fail "red baseline produced a mutation score"
    | Compile.MutateErr message ->
      check bool "baseline failure identified" true
        (starts_with "Go mutation baseline tests" message))

let test_huge_integer_literal_is_mutated_exactly () =
  let report = report huge_boundary_source in
  check int "huge mutant count" 4 report.Mutate.total;
  check int "huge killed" 4 report.Mutate.killed;
  check int "huge survived" 0 report.Mutate.survived;
  check bool "contains exact bigint increment" true
    (List.exists (fun ((mutant : Mutate.mutant), _) ->
       match mutant.replacement with
       | Mutate.MOInt "9223372036854775809" -> true
       | _ -> false) report.Mutate.results)

let test_negative_literal_mutates_as_signed_value () =
  let report = report negative_boundary_source in
  check int "negative mutant count" 4 report.Mutate.total;
  check int "negative killed" 4 report.Mutate.killed;
  check bool "-1 increments to zero" true
    (List.exists (fun ((mutant : Mutate.mutant), _) ->
       match mutant.site.original, mutant.replacement with
       | Mutate.MOInt "-1", Mutate.MOInt "0" -> true
       | _ -> false) report.Mutate.results)

let test_runner_failures_never_count_as_kills () =
  (match Compile.classify_go_test_run ~exit_code:2
           ~output:"TESL_GO_TESTS_STARTED\npanic: init failed\n" with
   | Compile.GoTestRunnerFailed _ -> ()
   | _ -> fail "panic without a failed test was classified as a kill");
  (match Compile.classify_go_test_run ~exit_code:1
           ~output:"TESL_GO_TESTS_STARTED\n--- FAIL: TestTesl0 (0.00s)\n" with
   | Compile.GoTestsFailed _ -> ()
   | _ -> fail "executed failed test was not classified as a kill");
  (match Compile.classify_go_test_run ~exit_code:0 ~output:"PASS\n" with
   | Compile.GoTestRunnerFailed _ -> ()
   | _ -> fail "missing test-start marker was accepted");
  (match Compile.classify_go_build_run ~exit_code:124 ~output:"" with
   | Some (Compile.GoTestsTimedOut _) -> ()
   | _ -> fail "Go test build timeout was not classified as a timeout");
  (match Compile.classify_go_build_run ~exit_code:1 ~output:"compile failed" with
   | Some (Compile.GoBuildFailed _) -> ()
   | _ -> fail "Go test compile failure was not classified as a build failure")

let test_infrastructure_tests_are_not_silently_skipped () =
  require_go ();
  let path = Filename.concat (Compile.default_root_path ())
      "example/learn/lesson32-api-tests.tesl" in
  match Compile.mutate_go_file path with
  | Compile.MutateOk _ -> fail "api-test suite produced a partial mutation score"
  | Compile.MutateErr message ->
    check bool "partial score refused" true (starts_with "mutation testing would skip" message)

let () =
  run "mutation_go" [
    "backend", [
      test_case "strong suite kills all mutants" `Slow test_strong_suite_kills_all;
      test_case "weak suite reports survivors" `Slow test_weak_suite_reports_survivors;
      test_case "red baseline aborts scoring" `Slow test_red_baseline_never_scores_mutants;
      test_case "huge integer threshold mutates exactly" `Slow test_huge_integer_literal_is_mutated_exactly;
      test_case "negative integer mutates as signed" `Slow test_negative_literal_mutates_as_signed_value;
      test_case "runner failures are not kills" `Quick test_runner_failures_never_count_as_kills;
      test_case "infrastructure tests are not skipped" `Quick test_infrastructure_tests_are_not_silently_skipped;
    ];
  ]
