(** Pure-OCaml unit test for the mutation-testing classification logic in
    [Compile] ([classify_mutant_run] / [output_indicates_failure]).

    Runs no Racket: it exercises only the OCaml predicate that decides whether a
    single mutant's [raco test] run means KILLED or SURVIVED.  This guards the
    fix for the false-survivor bug where a genuinely-killed mutant (tests failed)
    was reported as SURVIVED because classification trusted the process exit code
    alone.  Run as a standalone executable; exits non-zero if any case fails. *)

let failed = ref 0
let check name cond =
  if cond then Printf.printf "ok   - %s\n" name
  else (incr failed; Printf.printf "FAIL - %s\n" name)

let survived ~exit_code ~output = Compile.classify_mutant_run ~exit_code ~output
let killed ~exit_code ~output = not (survived ~exit_code ~output)

let () =
  (* Clean pass: exit 0, no failure banner -> SURVIVED (a true test gap). *)
  check "exit 0 + clean output = SURVIVED"
    (survived ~exit_code:0 ~output:"3 tests passed\n");

  (* rackunit check failure: non-zero exit AND a FAILURE banner -> KILLED. *)
  check "exit 1 + FAILURE marker = KILLED"
    (killed ~exit_code:1 ~output:"--------------------\nFAILURE\nname: foo\n");

  (* Raised exception during the test: ERROR banner -> KILLED. *)
  check "exit 1 + ERROR marker = KILLED"
    (killed ~exit_code:1 ~output:"--------------------\nERROR\nboom\n");

  (* Module load / macro-expansion error in the mutant -> KILLED. *)
  check "non-zero exit, no marker = KILLED"
    (killed ~exit_code:1 ~output:"mutant.rkt: expand: unbound identifier\n");

  (* Hang: coreutils [timeout] exits 124 -> KILLED (the hang is detected). *)
  check "timeout (exit 124) = KILLED"
    (killed ~exit_code:124 ~output:"");

  (* Shell could not run the command (e.g. raco missing): 127 -> KILLED. *)
  check "exit 127 = KILLED"
    (killed ~exit_code:127 ~output:"raco: command not found\n");

  (* The false-survivor guard: exit 0 yet a failure banner was printed.  This is
     the regression the fix targets — previously SURVIVED, now KILLED. *)
  check "exit 0 + FAILURE marker = KILLED (false-survivor guard)"
    (killed ~exit_code:0 ~output:"some output\nFAILURE\ndetails\n");
  check "exit 0 + ERROR marker = KILLED (false-survivor guard)"
    (killed ~exit_code:0 ~output:"ERROR\n");

  (* The marker must be a whole line: a value that merely contains the substring
     must not trip the guard, so legitimate program output never causes a false
     kill of a true survivor. *)
  check "exit 0 + 'ERRORLEVEL' substring = SURVIVED"
    (survived ~exit_code:0 ~output:"ERRORLEVEL=0\nall good\n");
  check "exit 0 + 'no FAILUREs here' substring = SURVIVED"
    (survived ~exit_code:0 ~output:"no FAILUREs here\n");

  (* Direct checks of the marker predicate. *)
  check "output_indicates_failure: leading FAILURE"
    (Compile.output_indicates_failure "FAILURE\nx");
  check "output_indicates_failure: trailing ERROR (no newline)"
    (Compile.output_indicates_failure "blah\nERROR");
  check "output_indicates_failure: none in clean output"
    (not (Compile.output_indicates_failure "1 test passed\n"));

  if !failed = 0 then print_endline "\nALL CLASSIFICATION TESTS PASSED"
  else (Printf.printf "\n%d classification test failure(s)\n" !failed; exit 1)
