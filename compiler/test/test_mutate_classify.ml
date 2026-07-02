(** Pure-OCaml unit test for the mutation-testing classification logic in
    [Compile] ([classify_mutant_outcome] / [classify_mutant_run] /
    [output_indicates_failure] / [output_indicates_tests_ran]).

    Runs no Racket: it exercises only the OCaml predicates that decide whether a
    single mutant's [raco test] run means KILLED, SURVIVED, or INVALID.  Two
    guards live here:

    - the false-survivor guard: a genuinely-killed mutant (tests failed) must
      not be reported as SURVIVED just because the process exit code was 0; and
    - the compile-error-not-killed guard (S10): a mutant that fails to COMPILE
      / expand — a non-zero exit with NO evidence any test ran — is INVALID
      (skipped), NOT credited as a kill.  Crediting it would inflate the
      kill-rate with mutants the tests never even got to distinguish.

    The [output_*] marker/banner strings used below are taken verbatim from real
    `raco test --quiet` runs (clean pass, rackunit FAILURE/ERROR banners, and
    Racket unbound-identifier / read-syntax errors).

    Run as a standalone executable; exits non-zero if any case fails. *)

let failed = ref 0
let check name cond =
  if cond then Printf.printf "ok   - %s\n" name
  else (incr failed; Printf.printf "FAIL - %s\n" name)

let survived ~exit_code ~output = Compile.classify_mutant_run ~exit_code ~output
let killed ~exit_code ~output = not (survived ~exit_code ~output)

(* 3-way outcome predicates. *)
let outcome ~exit_code ~output = Compile.classify_mutant_outcome ~exit_code ~output
let is_killed   ~exit_code ~output = outcome ~exit_code ~output = `Killed
let is_survived ~exit_code ~output = outcome ~exit_code ~output = `Survived
let is_invalid  ~exit_code ~output = outcome ~exit_code ~output = `Invalid

(* Real `raco test --quiet` fragments, captured empirically. *)
let clean_pass      = "1 test passed\n"
let rackunit_fail   = "--------------------\nFAILURE\nname: foo\n--------------------\n1/1 test failures\n"
let rackunit_error  = "--------------------\nERROR\nname: foo\n\ncar: contract violation\n--------------------\n1/1 test failures\n"
(* A Racket module that never expands: exit non-zero, no rackunit banner, and
   crucially NO "N test passed" progress line — the tests never ran. *)
let expand_error    = "mutant.rkt:4:17: undefined-identifier-xyz: unbound identifier\n  in: undefined-identifier-xyz\n"
let read_error      = "mutant.rkt:4:2: read-syntax: expected a `)` to close `(`\n  context...:\n"

let () =
  (* ── classify_mutant_run (boolean survivor predicate) ──────────────────── *)

  (* Clean pass: exit 0, no failure banner -> SURVIVED (a true test gap). *)
  check "exit 0 + clean output = SURVIVED"
    (survived ~exit_code:0 ~output:clean_pass);

  (* rackunit check failure: non-zero exit AND a FAILURE banner -> not a survivor. *)
  check "exit 1 + FAILURE marker = not-survivor"
    (killed ~exit_code:1 ~output:rackunit_fail);

  (* Raised exception during the test: ERROR banner -> not a survivor. *)
  check "exit 1 + ERROR marker = not-survivor"
    (killed ~exit_code:1 ~output:rackunit_error);

  (* Timeout: coreutils [timeout] exits 124 (handled as Error by the caller);
     as a bare survivor predicate it is still "not a survivor". *)
  check "timeout (exit 124) = not-survivor"
    (killed ~exit_code:124 ~output:"");

  (* The false-survivor guard: exit 0 yet a failure banner was printed. *)
  check "exit 0 + FAILURE marker = not-survivor (false-survivor guard)"
    (killed ~exit_code:0 ~output:"some output\nFAILURE\ndetails\n");
  check "exit 0 + ERROR marker = not-survivor (false-survivor guard)"
    (killed ~exit_code:0 ~output:"ERROR\n");

  (* The marker must be a whole line: a value that merely contains the substring
     must not trip the guard, so legitimate program output never causes a false
     kill of a true survivor. *)
  check "exit 0 + 'ERRORLEVEL' substring = SURVIVED"
    (survived ~exit_code:0 ~output:"ERRORLEVEL=0\nall good\n");
  check "exit 0 + 'no FAILUREs here' substring = SURVIVED"
    (survived ~exit_code:0 ~output:"no FAILUREs here\n");

  (* ── classify_mutant_outcome (3-way: Killed / Survived / Invalid) ───────── *)

  (* A clean pass is a SURVIVOR — the suite ran and did not detect the mutant. *)
  check "outcome: exit 0 + clean pass = Survived"
    (is_survived ~exit_code:0 ~output:clean_pass);

  (* A rackunit FAILURE / ERROR banner means the suite RAN and detected the
     mutant: a genuine KILL (regardless of the exact exit code). *)
  check "outcome: exit 1 + FAILURE banner = Killed"
    (is_killed ~exit_code:1 ~output:rackunit_fail);
  check "outcome: exit 1 + ERROR banner = Killed"
    (is_killed ~exit_code:1 ~output:rackunit_error);
  check "outcome: exit 0 + FAILURE banner = Killed (false-survivor -> kill)"
    (is_killed ~exit_code:0 ~output:rackunit_fail);

  (* ── S10 compile-error-not-killed guard ────────────────────────────────── *)

  (* A mutant that fails to expand (unbound identifier) exits non-zero with NO
     rackunit banner and NO pass line — the tests never ran.  It is INVALID,
     NOT a kill: it proves nothing about whether the tests distinguish behaviour. *)
  check "outcome: expand error = Invalid (NOT Killed)"
    (is_invalid ~exit_code:1 ~output:expand_error);
  check "outcome: expand error is NOT Killed"
    (not (is_killed ~exit_code:1 ~output:expand_error));

  (* Same for a read/syntax error: a mutant that does not even parse is INVALID. *)
  check "outcome: read-syntax error = Invalid (NOT Killed)"
    (is_invalid ~exit_code:1 ~output:read_error);
  check "outcome: read-syntax error is NOT Killed"
    (not (is_killed ~exit_code:1 ~output:read_error));

  (* A generic non-zero exit with only a bare compile-error blurb (no banner,
     no pass line) is INVALID — the historical "non-zero, no marker = KILLED"
     behaviour was the bug S10 fixes. *)
  check "outcome: non-zero + no marker + no pass line = Invalid (regression guard)"
    (is_invalid ~exit_code:1 ~output:"mutant.rkt: expand: unbound identifier\n");
  check "outcome: that same run is NOT Killed"
    (not (is_killed ~exit_code:1 ~output:"mutant.rkt: expand: unbound identifier\n"));

  (* ── output_indicates_failure marker predicate ─────────────────────────── *)
  check "output_indicates_failure: leading FAILURE"
    (Compile.output_indicates_failure "FAILURE\nx");
  check "output_indicates_failure: trailing ERROR (no newline)"
    (Compile.output_indicates_failure "blah\nERROR");
  check "output_indicates_failure: none in clean output"
    (not (Compile.output_indicates_failure "1 test passed\n"));
  (* A compile/expand error must NOT look like a rackunit failure marker. *)
  check "output_indicates_failure: expand error has no FAILURE/ERROR line"
    (not (Compile.output_indicates_failure expand_error));

  (* ── output_indicates_tests_ran (the S10 kill/invalid discriminator) ────── *)
  check "tests_ran: clean pass line = true"
    (Compile.output_indicates_tests_ran clean_pass);
  check "tests_ran: FAILURE banner = true"
    (Compile.output_indicates_tests_ran rackunit_fail);
  check "tests_ran: ERROR banner = true"
    (Compile.output_indicates_tests_ran rackunit_error);
  check "tests_ran: expand error = false (tests never ran)"
    (not (Compile.output_indicates_tests_ran expand_error));
  check "tests_ran: read-syntax error = false"
    (not (Compile.output_indicates_tests_ran read_error));

  (* ── S10 mutation-operator breadth (pure AST-rewrite coverage) ───────────
     [generate_mutants] must now emit, beyond binop swaps, a boolean-literal
     flip, comparison-operator swaps, and an integer-literal +1 perturbation —
     each total and deterministic.  We parse a small `check` body carrying one
     of each and inspect the generated [Mutate.mutant] descriptions / ops; no
     Racket is run (we exercise generation only, not evaluation). *)
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
    "#lang tesl\n\
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

  (* Boolean-literal flip: the `True` literal must be flipped to `False`. *)
  check "operator: boolean-literal flip present (True → False)"
    (has_op mutants (function Mutate.MOBool false -> true | _ -> false));
  check "operator: bool flip described as `True → False`"
    (desc_has mutants "True → False");

  (* Integer-literal perturbation: the literal `3` must be perturbed to `4`. *)
  check "operator: integer-literal perturbation present (3 → 4)"
    (has_op mutants (function Mutate.MOInt 4 -> true | _ -> false));
  check "operator: int perturbation described as `3 → 4`"
    (desc_has mutants "3 → 4");

  (* Determinism: regenerating yields the identical sequence of (kind, index,
     replacement) triples.  (Full descriptions embed the temp file path, which
     differs per call, so we compare the path-independent mutation identity.) *)
  let identity (m : Mutate.mutant) = (m.site.kind, m.site.site_index, m.replacement) in
  let mutants2 = generate_from_src src in
  check "operator: generation is deterministic"
    (List.map identity mutants = List.map identity mutants2);

  (* A boolean-only body (no binops, no ints) still yields exactly the flip. *)
  let bool_src =
    "#lang tesl\n\
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
