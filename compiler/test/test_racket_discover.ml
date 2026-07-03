(** S2b (Racket half) — filesystem-derived Racket run-set completeness.

    The OCaml half of S2b ("a test_*.ml that runs in NO gate is build-red") landed
    in test_suite_registration.ml.  This is the RACKET analogue: it fails the build
    if any [tests/*.rkt] on disk is run by NO gate and is not explicitly
    excluded-with-reason — closing the "a Racket suite exists but no gate runs it"
    class (the same shape as the orphaned OCaml test that let R66_CA15 hide).

    The gated set is DERIVED from the actual gate configuration, not hand-listed,
    so it cannot drift:

      1. AUTO-RUN — compile-examples.sh's detect_tesl_test_files runs, via
         tests/example-test-batch.rkt, the `(module+ test …)` submodule of every
         `tests/X.rkt` whose `tests/X.tesl` sibling it processes (ALL_FILES ⊇
         tests/*.tesl).  We recompute that rule here: a `tests/X.rkt` with a
         `tests/X.tesl` sibling AND a `(module+ test` submodule IS run.
      2. INTERNAL-ALL — the hand-written suites `racket tests/all.rkt` runs, parsed
         from tests/internal-all.rkt's `define-runtime-path … "X.rkt"` lines.
      3. CI-RKT — the suites compiler/ci.sh runs via `raco test`, parsed from its
         NON-COMMENT lines (so the `# NOT gated …` comments naming httpclient do
         not count as "run").
      4. SUPPORT — aggregators / batch-runner that are not themselves standalone
         gated suites (all.rkt, internal-all.rkt, frontend-all.rkt,
         example-test-batch.rkt).
      5. EXCLUDED — an explicit allowlist, each with a reason (today: the two
         httpclient suites, which need real loopback TCP and run via `raco test`
         in a network-capable environment — ci.sh documents this).

    A NEW tests/X.rkt that is a hand-written suite (no .tesl sibling) added to no
    gate lands in NONE of 1-5 → this test goes red until it is gated or
    excluded-with-reason.

    NOTE (remaining, tracked as S2b in roadmap/later): the OTHER half — making one
    gate a strict SUPERSET (compile-examples.sh also running `dune test`, or ci.sh
    calling it) so the OCaml and Racket gates are not disjoint — is a gate-script
    change deferred there; this test closes the Racket-discovery half.

    Pure OCaml (str + unix); runs under `dune runtest`:
      dune exec test/test_racket_discover.exe *)

module SS = Set.Make (String)

let failures = ref 0
let check name ok detail =
  if ok then Printf.printf "ok   - %s\n" name
  else begin incr failures; Printf.printf "FAIL - %s\n    %s\n" name detail end

(* ── Locate the repo root (has compile-examples.sh + tests/) ───────────────── *)
let is_repo_root d =
  Sys.file_exists (Filename.concat d "compile-examples.sh")
  && Sys.file_exists (Filename.concat d "tests")

let rec up_to_root dir n =
  if n > 12 then None
  else if is_repo_root dir then Some dir
  else
    let parent = Filename.dirname dir in
    if parent = dir then None else up_to_root parent (n + 1)

let repo_root =
  let starts =
    [ (try Sys.getenv "TESL_REPO_ROOT" with Not_found -> "");
      Sys.getcwd ();
      (try Filename.dirname (Unix.realpath Sys.executable_name)
       with _ -> Filename.dirname Sys.executable_name) ]
  in
  let rec pick = function
    | [] -> None
    | s :: rest ->
      if s <> "" && is_repo_root s then Some s
      else match up_to_root (if s = "" then Sys.getcwd () else s) 0 with
        | Some d -> Some d
        | None -> pick rest
  in
  match pick starts with
  | Some d -> d
  | None ->
    prerr_endline
      "FATAL: could not locate repo root (compile-examples.sh + tests/); \
       set TESL_REPO_ROOT";
    exit 2

let tests_dir = Filename.concat repo_root "tests"
let read_file path =
  try In_channel.with_open_text path In_channel.input_all
  with Sys_error _ -> Printf.eprintf "FATAL: could not read %s\n" path; exit 2

(* Return every group-1 capture of [re] across [s] (advancing past each match). *)
let find_all re s =
  let rec go pos acc =
    match Str.search_forward re s pos with
    | i ->
      let m = Str.matched_group 1 s in
      go (i + max 1 (String.length (Str.matched_string s))) (m :: acc)
    | exception Not_found -> List.rev acc
  in
  go 0 []

let string_contains ~needle hay =
  let nl = String.length needle and hl = String.length hay in
  if nl = 0 then true
  else if nl > hl then false
  else
    let rec at i =
      if i + nl > hl then false
      else if String.sub hay i nl = needle then true
      else at (i + 1)
    in at 0

(* ── 0. Disk: every tests/*.rkt ────────────────────────────────────────────── *)
let disk : SS.t =
  match Sys.readdir tests_dir with
  | arr ->
    Array.to_list arr
    |> List.filter (fun f -> Filename.check_suffix f ".rkt")
    |> SS.of_list
  | exception Sys_error _ ->
    Printf.eprintf "FATAL: could not list %s\n" tests_dir; exit 2

(* ── 1. AUTO-RUN — mirror compile-examples.sh detect_tesl_test_files ────────── *)
(* has_test_submodule: grep -Fq "(module+ test"; a .tesl sibling puts it in
   ALL_FILES (tests/*.tesl). *)
let auto_run : SS.t =
  SS.filter
    (fun rkt ->
       let stem = Filename.remove_extension rkt in
       let tesl_sibling = Filename.concat tests_dir (stem ^ ".tesl") in
       Sys.file_exists tesl_sibling
       && string_contains ~needle:"(module+ test"
            (read_file (Filename.concat tests_dir rkt)))
    disk

(* ── 2. INTERNAL-ALL — parse define-runtime-path "X.rkt" ────────────────────── *)
let internal_all : SS.t =
  let content = read_file (Filename.concat tests_dir "internal-all.rkt") in
  (* only .rkt targets of a define-runtime-path *)
  content
  |> String.split_on_char '\n'
  |> List.filter (fun ln -> string_contains ~needle:"define-runtime-path" ln)
  |> List.concat_map (find_all (Str.regexp "\"\\([A-Za-z0-9_-]+\\.rkt\\)\""))
  |> SS.of_list

(* ── 3. CI-RKT — parse the authoritative gate's non-comment lines for tests/X.rkt.
   The two historical QA scripts were merged into the repo-root `ci.sh`;
   `compiler/ci.sh` is now a thin `exec` shim (0 suite references), so the
   Racket run-set now lives in `<repo_root>/ci.sh`.  Parse that. ─────────────── *)
let ci_rkt : SS.t =
  let content = read_file (Filename.concat repo_root "ci.sh") in
  content
  |> String.split_on_char '\n'
  |> List.filter (fun ln ->
       let t = String.trim ln in
       String.length t > 0 && t.[0] <> '#')     (* drop comment lines *)
  |> List.concat_map (find_all (Str.regexp "tests/\\([A-Za-z0-9_-]+\\.rkt\\)"))
  |> SS.of_list

(* ── 4. SUPPORT — aggregators / batch runner (not standalone gated suites) ──── *)
let support : SS.t =
  SS.of_list
    [ "all.rkt"; "internal-all.rkt"; "frontend-all.rkt"; "example-test-batch.rkt" ]

(* ── 5. EXCLUDED — explicit allowlist, each with a reason ───────────────────── *)
let excluded : (string * string) list =
  [ "httpclient-test.rkt",
    "network — makes real loopback TCP connects (connection-refused assertions); \
     run via `raco test` in a network-capable environment (ci.sh documents this)";
    "httpclient-tests.rkt",
    "network — real HttpClient sockets; run via `raco test`, not in the portable gate" ]
let excluded_names = SS.of_list (List.map fst excluded)

(* ── Assertions ────────────────────────────────────────────────────────────── *)
let () =
  let accounted =
    List.fold_left SS.union SS.empty
      [ auto_run; internal_all; ci_rkt; support; excluded_names ]
  in

  (* (a) No disk file is unaccounted: every tests/*.rkt is run by some gate or
     explicitly excluded-with-reason. *)
  let unaccounted = SS.diff disk accounted in
  check "every tests/*.rkt is gated or excluded-with-reason"
    (SS.is_empty unaccounted)
    (Printf.sprintf
       "%d unaccounted Racket suite(s) — run by NO gate and not excluded: %s\n\
        \    Fix: gate it (give it a `tests/X.tesl` sibling with a `(module+ test)`, \
        or add it to internal-all.rkt / ci.sh RKT_SUITES), or add it to this test's \
        `excluded` allowlist WITH A REASON."
       (SS.cardinal unaccounted)
       (String.concat ", " (SS.elements unaccounted)));

  (* (b) No stale curated entry: every SUPPORT / EXCLUDED name exists on disk. *)
  SS.iter (fun f ->
    check (Printf.sprintf "support entry %s exists on disk" f) (SS.mem f disk)
      "remove it from the support allowlist (file is gone)")
    support;
  SS.iter (fun f ->
    check (Printf.sprintf "excluded entry %s exists on disk" f) (SS.mem f disk)
      "remove it from the excluded allowlist (file is gone)")
    excluded_names;

  (* (c) internal-all / ci parse actually found suites (guards against a parser
     regression silently emptying a run-set). *)
  check "internal-all.rkt run-set parsed (non-empty)" (not (SS.is_empty internal_all))
    "define-runtime-path parse found nothing — the regex or file moved";
  check "ci.sh RKT run-set parsed (non-empty)" (not (SS.is_empty ci_rkt))
    "ci.sh tests/*.rkt parse found nothing — the regex or file moved";

  Printf.printf
    "\ndisk=%d  auto-run=%d  internal-all=%d  ci-rkt=%d  support=%d  excluded=%d\n"
    (SS.cardinal disk) (SS.cardinal auto_run) (SS.cardinal internal_all)
    (SS.cardinal ci_rkt) (SS.cardinal support) (List.length excluded);
  Printf.printf "%s (%d failure(s))\n"
    (if !failures = 0 then "PASS" else "FAILURES") !failures;
  exit (if !failures = 0 then 0 else 1)
