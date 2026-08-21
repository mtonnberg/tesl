(** Pure-OCaml unit test for Go mutation-run classification and mutation
    operator generation.

    Runs no generated program: it exercises only the OCaml predicates that
    distinguish passed tests, failed tests, build failures, timeouts, and test
    runner failures. Two guards live here:

    - only an executed Go test failure may kill a mutant; and
    - a mutant that fails to build or whose runner fails is not credited as a
      kill. Crediting it would inflate the kill-rate with mutants the tests
      never distinguished.

    Run as a standalone executable; exits non-zero if any case fails. *)

let failed = ref 0
let check name cond =
  if cond then Printf.printf "ok   - %s\n" name
  else (incr failed; Printf.printf "FAIL - %s\n" name)

let () =
  let classify exit_code output = Compile.classify_go_test_run ~exit_code ~output in
  check "Go test pass is a survivor"
    (classify 0 "TESL_GO_TESTS_STARTED\n--- PASS: TestTesl0\nPASS\n" = Compile.GoTestsPassed);
  check "executed Go test failure kills mutant"
    (match classify 1 "TESL_GO_TESTS_STARTED\n--- FAIL: TestTesl0 (0.00s)\n" with
     | Compile.GoTestsFailed _ -> true | _ -> false);
  check "panic without failed test is runner failure, not kill"
    (match classify 2 "TESL_GO_TESTS_STARTED\npanic: init failed\n" with
     | Compile.GoTestRunnerFailed _ -> true | _ -> false);
  check "missing start marker is runner failure"
    (match classify 0 "PASS\n" with
     | Compile.GoTestRunnerFailed _ -> true | _ -> false);
  check "failure text without start marker is not a kill"
    (match classify 1 "--- FAIL: TestTesl0 (0.00s)\n" with
     | Compile.GoTestRunnerFailed _ -> true | _ -> false);
  check "build failure remains distinct from killed mutant"
    (match Compile.classify_go_build_run ~exit_code:1 ~output:"compile failed" with
     | Some (Compile.GoBuildFailed _) -> true | _ -> false);
  check "build timeout remains distinct from killed mutant"
    (match Compile.classify_go_build_run ~exit_code:124 ~output:"" with
     | Some (Compile.GoTestsTimedOut _) -> true | _ -> false);
  check "successful build has no failure outcome"
    (Compile.classify_go_build_run ~exit_code:0 ~output:"" = None);

  (* ── S10 mutation-operator breadth (pure AST-rewrite coverage) ───────────
     [generate_mutants] must now emit, beyond binop swaps, a boolean-literal
     flip, comparison-operator swaps, and an integer-literal +1 perturbation —
     each total and deterministic.  We parse a small `check` body carrying one
     of each and inspect the generated [Mutate.mutant] descriptions / ops; no
     generated program is run (we exercise generation only, not evaluation). *)
  let generate_from_src src =
    let dir = Filename.temp_dir "tesl-mutate-gen" "" in
    let path = Filename.concat dir "t.tesl" in
    Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc src);
    let mutants =
      match Compile.parse_module_file path with
      | Some m -> Mutate.generate_mutants m
      | None   -> []
    in
    (try Sys.remove path with _ -> ());
    (try Sys.rmdir dir with _ -> ());
    mutants
  in
  let has_op mutants pred = List.exists (fun (m : Mutate.mutant) -> pred m.replacement) mutants in
  let desc_has mutants sub =
    List.exists (fun (m : Mutate.mutant) ->
      let n = String.length sub and s = m.description in
      let rec at i = i + n <= String.length s && (String.sub s i n = sub || at (i + 1)) in
      at 0) mutants
  in

  (* A check whose body exercises a comparison operator, a boolean literal, and
     an integer literal — all inside a mutated function kind. *)
  let src =
    "\
     module T exposing [checkOp]\n\
     import Tesl.Prelude exposing [Int, Bool(..)]\n\
     \n\
     fact Okay (n: Int)\n\
     \n\
     check checkOp(n: Int) -> n: Int ::: Okay n =\n\
    \  if n > 3 && True then\n\
    \    ok n ::: Okay n\n\
    \  else\n\
    \    fail 400 \"nope\"\n"
  in
  let mutants = generate_from_src src in
  check "generate: produced at least one mutant"
    (List.length mutants > 0);

  (* Comparison-operator swaps: `>` must be swapped to at least one of >=, <, <=. *)
  check "operator: comparison swap present (> → >=/</<=)"
    (has_op mutants (function
       | Mutate.MOBinop (Ast.BGe | Ast.BLt | Ast.BLe) -> true | _ -> false));
  check "operator: comparison swap described as `> → ...`"
    (desc_has mutants "> →");
  check "operator: conjunction swap present (&& → ||)"
    (has_op mutants (function Mutate.MOBinop Ast.BOr -> true | _ -> false));

  (* Boolean-literal flip: the `True` literal must be flipped to `False`. *)
  check "operator: boolean-literal flip present (True → False)"
    (has_op mutants (function Mutate.MOBool false -> true | _ -> false));
  check "operator: bool flip described as `True → False`"
    (desc_has mutants "True → False");

  (* Integer-literal perturbation: the literal `3` must be perturbed to `4`. *)
  check "operator: integer-literal perturbation present (3 → 4)"
    (has_op mutants (function Mutate.MOInt "4" -> true | _ -> false));
  check "operator: int perturbation described as `3 → 4`"
    (desc_has mutants "3 → 4");

  let loc = Location.dummy_loc "<negative-zero>" in
  let negative_zero = Ast.EUnop {
    op = Ast.UNeg;
    arg = Ast.ELit { lit = Ast.LInt 0; loc };
    loc;
  } in
  let negative_zero_sites = Mutate.collect_sites "zero" Ast.FnKind negative_zero in
  check "operator: negative zero increments to one"
    (List.exists (fun ((site : Mutate.mutation_site), alternatives) ->
       site.original = Mutate.MOInt "-0" && List.mem (Mutate.MOInt "1") alternatives)
       negative_zero_sites);

  let huge_src =
    "module T exposing [checkHuge]\n\
     import Tesl.Prelude exposing [Int]\n\
     fact Huge (n: Int)\n\
     check checkHuge(n: Int) -> n: Int ::: Huge n =\n\
    \  if n > 9223372036854775808 then\n\
    \    ok n ::: Huge n\n\
    \  else\n\
    \    fail 422 \"not huge\"\n"
  in
  let huge_mutants = generate_from_src huge_src in
  check "operator: bigint increment preserves exact precision"
    (has_op huge_mutants (function
       | Mutate.MOInt "9223372036854775809" -> true | _ -> false));

  let negative_src =
    "module T exposing [checkNegative]\n\
     import Tesl.Prelude exposing [Int]\n\
     fact AboveNegativeOne (n: Int)\n\
     check checkNegative(n: Int) -> n: Int ::: AboveNegativeOne n =\n\
    \  if n > -1 then\n\
    \    ok n ::: AboveNegativeOne n\n\
    \  else\n\
    \    fail 422 \"too small\"\n"
  in
  let negative_mutants = generate_from_src negative_src in
  check "operator: signed -1 increments to zero"
    (List.exists (fun (mutant : Mutate.mutant) ->
       mutant.site.original = Mutate.MOInt "-1"
       && mutant.replacement = Mutate.MOInt "0") negative_mutants);

  let scoped_src =
    "module T exposing [checkPos, helper]\n\
     import Tesl.Prelude exposing [Int, Bool(..)]\n\
     fact Positive (n: Int)\n\
     fn helper(n: Int) -> Bool = n > 0\n\
     check checkPos(n: Int) -> n: Int ::: Positive n =\n\
    \  if n > 0 then\n\
    \    ok n ::: Positive n\n\
    \  else\n\
    \    fail 422 \"not positive\"\n"
  in
  let scoped_mutants = generate_from_src scoped_src in
  check "scope: ordinary fn bodies are not mutated"
    (scoped_mutants <> []
     && List.for_all (fun (mutant : Mutate.mutant) ->
          mutant.site.fn_name = "checkPos") scoped_mutants);

  (* Determinism: regenerating yields the identical sequence of (kind, index,
     replacement) triples.  (Full descriptions embed the temp file path, which
     differs per call, so we compare the path-independent mutation identity.) *)
  let identity (m : Mutate.mutant) = (m.site.kind, m.site.site_index, m.replacement) in
  let mutants2 = generate_from_src src in
  check "operator: generation is deterministic"
    (List.map identity mutants = List.map identity mutants2);

  (* A boolean-only body (no binops, no ints) still yields exactly the flip. *)
  let bool_src =
    "\
     module T exposing [checkFlag]\n\
     import Tesl.Prelude exposing [Bool(..)]\n\
     \n\
     fact Flagged (b: Bool)\n\
     \n\
     check checkFlag(b: Bool) -> b: Bool ::: Flagged b =\n\
    \  if False then\n\
    \    fail 400 \"never\"\n\
    \  else\n\
    \    ok b ::: Flagged b\n"
  in
  let bool_mutants = generate_from_src bool_src in
  check "operator: bool-only body produces the True/False flip"
    (has_op bool_mutants (function Mutate.MOBool true -> true | _ -> false));

  if !failed = 0 then print_endline "\nALL CLASSIFICATION TESTS PASSED"
  else (Printf.printf "\n%d classification test failure(s)\n" !failed; exit 1)
