open Alcotest

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

let named_wrapper_source = {|module GoMutationBoundary exposing [Positive, checkPositive, requirePositive]
import Tesl.Prelude exposing [Int]

fact Positive (n: Int)

check checkPositive(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 422 "not positive"

fn requirePositive(n: Int) -> Int =
  let positive = check checkPositive n
  positive

test "named wrapper failures kill boundary mutations" {
  expect requirePositive 1 == 1
  expectFail requirePositive 0
  expectFail requirePositive -1
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

let test_named_wrapper_expect_fail_kills_all () =
  let report = report named_wrapper_source in
  check int "named wrapper mutant count" 4 report.Mutate.total;
  check int "named wrapper killed" 4 report.Mutate.killed;
  check int "named wrapper survived" 0 report.Mutate.survived;
  check int "named wrapper invalid" 0 report.Mutate.invalid;
  check int "named wrapper errors" 0 report.Mutate.errors

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
      test_case "weak suite reports survivors" `Slow test_weak_suite_reports_survivors;
      test_case "red baseline aborts scoring" `Slow test_red_baseline_never_scores_mutants;
      test_case "named wrapper expectFail kills all" `Slow test_named_wrapper_expect_fail_kills_all;
      test_case "infrastructure tests are not skipped" `Quick test_infrastructure_tests_are_not_silently_skipped;
    ];
  ]
