(** Suite-registration meta-test (formal-review G1/S2).

    Closes the bug CLASS "a [test_*.ml] exists on disk but no dune stanza runs
    it, so every gate has zero signal from it."  The instance that motivated
    this: [test_review18_antagonistic.ml] — a real antagonistic regression suite
    — sat in the source tree completely unregistered and was never built or run
    by any gate.

    This asserts that EVERY [test_*.ml] in [compiler/test/] is named in
    [compiler/test/dune] (in a (tests)/(test)/(executable) stanza).  An
    unregistered file is a HARD FAILURE here, not a silent coverage hole — so a
    contributor who adds a soundness suite and forgets to wire it up gets a red
    build instead of zero signal.

    Pure OCaml; no Racket / no PostgreSQL, so it runs in every gate.  Mirrors the
    CWD-walk that [test_error_codes.ml] uses to find [manual/]. Run:
      dune exec test/test_suite_registration.exe *)

let () =
  (* Locate compiler/test/ — cwd is the project root under dune; be robust. *)
  let has_dune d = Sys.file_exists (Filename.concat d "dune") in
  let rec up dir n =
    if n > 12 then None
    else
      let here_is_test = Filename.basename dir = "test" && has_dune dir in
      if here_is_test then Some dir
      else
        let cand = Filename.concat (Filename.concat dir "compiler") "test" in
        if has_dune cand then Some cand
        else
          let cand2 = Filename.concat dir "test" in
          if has_dune cand2 && Sys.file_exists (Filename.concat cand2 "test_lexer.ml")
          then Some cand2
          else
            let parent = Filename.dirname dir in
            if parent = dir then None else up parent (n + 1)
  in
  let test_dir =
    match (try Sys.getenv "TESL_TEST_DIR" with Not_found -> "") with
    | "" ->
      (match up (Sys.getcwd ()) 0 with
       | Some d -> d
       | None ->
         Printf.eprintf
           "test_suite_registration: could not locate compiler/test/ from %s\n"
           (Sys.getcwd ());
         exit 2)
    | d -> d
  in
  let dune_text =
    In_channel.with_open_text (Filename.concat test_dir "dune") In_channel.input_all
  in
  (* Tokenise the dune file on non-identifier characters so a name only matches
     as a whole word (`test_review1` must NOT match inside `test_review18`). *)
  let dune_tokens =
    let buf = Buffer.create (String.length dune_text) in
    String.iter (fun c ->
      if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
         || (c >= '0' && c <= '9') || c = '_'
      then Buffer.add_char buf c else Buffer.add_char buf ' ') dune_text;
    Buffer.contents buf |> String.split_on_char ' '
    |> List.filter (fun s -> s <> "")
  in
  let on_disk =
    Sys.readdir test_dir |> Array.to_list
    |> List.filter (fun f ->
         Filename.check_suffix f ".ml"
         && String.length f > 5 && String.sub f 0 5 = "test_")
    |> List.map (fun f -> Filename.chop_suffix f ".ml")
    |> List.sort compare
  in
  let orphans = List.filter (fun n -> not (List.mem n dune_tokens)) on_disk in
  if orphans <> [] then begin
    Printf.eprintf
      "SUITE-REGISTRATION FAILURE: %d test file(s) on disk are not named in \
       compiler/test/dune, so no gate runs them:\n" (List.length orphans);
    List.iter (fun n -> Printf.eprintf "  - test/%s.ml\n" n) orphans;
    Printf.eprintf
      "Add each to a (tests)/(test)/(executable) stanza in compiler/test/dune, \
       or delete the file.\n";
    exit 1
  end;
  (* S2b: "named in dune" is NOT the same as "run by a gate".  A file named only
     in an (executable)/(executables) stanza never runs under `dune test`/
     `dune runtest`, so it contributes zero signal even though the orphan check
     above passes it (the motivating instances: test_mutate_differential /
     test_mutate_classify).  Split the dune into top-level stanzas, collect the
     test_* names that appear in a RUN stanza ((test)/(tests)), and require every
     test_*.ml on disk to be in a run stanza OR on an explicit, documented
     allowlist of intentional standalone executables. *)
  let stanzas =
    let out = ref [] and buf = Buffer.create 256 and depth = ref 0 in
    String.iter (fun c ->
      (match c with
       | '(' -> if !depth = 0 then Buffer.clear buf; incr depth
       | ')' -> decr depth
       | _ -> ());
      if !depth > 0 || c = ')' then Buffer.add_char buf c;
      if c = ')' && !depth = 0 then begin
        out := Buffer.contents buf :: !out; Buffer.clear buf
      end) dune_text;
    List.rev !out
  in
  let tokens_of s =
    let b = Buffer.create (String.length s) in
    String.iter (fun c ->
      if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
         || (c >= '0' && c <= '9') || c = '_'
      then Buffer.add_char b c else Buffer.add_char b ' ') s;
    Buffer.contents b |> String.split_on_char ' ' |> List.filter (fun t -> t <> "")
  in
  let is_test_name t = String.length t > 5 && String.sub t 0 5 = "test_" in
  let run_stanza_names =
    List.concat_map (fun st ->
      match tokens_of st with
      | ("test" | "tests") :: _ -> List.filter is_test_name (tokens_of st)
      | _ -> []) stanzas
  in
  (* Intentional standalone executables that no `dune test` gate runs — each has
     a documented reason in compiler/test/dune.  Adding a new (executable) test_*
     without allowlisting it here fails the build. *)
  let standalone_executable_allowlist = []
  in
  (* Suites the shared migration runner (scripts/run-migration-tests.sh) runs
     as its own phases are plain executables: they build private PostgreSQL
     clusters and generated applications, and running them again under the
     compiler shard's `dune test` doubled that work without adding signal.
     Read the runner's `compiler_test NAME` lines and its single
     `for suite in ...; do compiler_test "$suite"` inventory. *)
  let runner_names =
    let rec find dir n =
      let cand = Filename.concat (Filename.concat dir "scripts") "run-migration-tests.sh" in
      if Sys.file_exists cand then Some cand
      else if n > 8 then None
      else let parent = Filename.dirname dir in
        if parent = dir then None else find parent (n + 1)
    in
    match find test_dir 0 with
    | None ->
      Printf.eprintf "test_suite_registration: could not locate scripts/run-migration-tests.sh from %s\n" test_dir;
      exit 2
    | Some path ->
      let text = In_channel.with_open_text path In_channel.input_all in
      let lines = String.split_on_char '\n' text in
      let direct = List.filter_map (fun line ->
        match tokens_of line with
        | ["compiler_test"; name] when is_test_name name -> Some name
        | _ -> None) lines in
      let find_from sub from =
        let n = String.length sub and m = String.length text in
        let rec go i = if i + n > m then None
          else if String.sub text i n = sub then Some i else go (i + 1) in
        go from
      in
      let loop = match find_from "for suite in" 0 with
        | None -> []
        | Some start ->
          (match find_from "; do" start with
           | None -> []
           | Some stop -> List.filter is_test_name (tokens_of (String.sub text start (stop - start))))
      in
      direct @ loop
  in
  let in_run_stanza n = List.mem n run_stanza_names in
  let doubled = List.filter in_run_stanza runner_names in
  if doubled <> [] then begin
    Printf.eprintf
      "SUITE-RUN FAILURE: %d suite(s) run by scripts/run-migration-tests.sh are also in a \
       (test)/(tests) stanza, so CI runs them twice:\n" (List.length doubled);
    List.iter (fun n -> Printf.eprintf "  - test/%s.ml\n" n) doubled;
    Printf.eprintf "Declare each as an (executable) in compiler/test/dune.\n";
    exit 1
  end;
  let unknown = List.filter (fun n -> not (List.mem n on_disk)) runner_names in
  if unknown <> [] then begin
    Printf.eprintf "SUITE-RUN FAILURE: scripts/run-migration-tests.sh runs missing suites:\n";
    List.iter (fun n -> Printf.eprintf "  - test/%s.ml\n" n) unknown;
    exit 1
  end;
  let not_run =
    List.filter (fun n ->
      not (List.mem n run_stanza_names)
      && not (List.mem n runner_names)
      && not (List.mem n standalone_executable_allowlist)) on_disk
  in
  if not_run <> [] then begin
    Printf.eprintf
      "SUITE-RUN FAILURE: %d test file(s) are named in dune but NOT in a \
       (test)/(tests) stanza, so `dune test` never runs them:\n"
      (List.length not_run);
    List.iter (fun n -> Printf.eprintf "  - test/%s.ml\n" n) not_run;
    Printf.eprintf
      "Move each into a (test)/(tests) stanza, or add it to \
       standalone_executable_allowlist in test_suite_registration.ml with a reason.\n";
    exit 1
  end;
  let stale_allow =
    List.filter (fun n ->
      not (List.mem n on_disk) || List.mem n run_stanza_names)
      standalone_executable_allowlist
  in
  if stale_allow <> [] then begin
    Printf.eprintf
      "SUITE-RUN allowlist is stale (entries missing on disk or now in a run stanza):\n";
    List.iter (fun n -> Printf.eprintf "  - %s\n" n) stale_allow;
    exit 1
  end;
  Printf.printf
    "test_suite_registration: OK — all %d test_*.ml files in %s are registered \
     AND run (or explicitly allowlisted as standalone executables)\n"
    (List.length on_disk) test_dir
