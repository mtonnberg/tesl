(** Spec §-citation resolution test (roadmap D9 / decision #6).

    Guards the contract documented in manual/anchors.md ("language-spec"): every
    LANGUAGE-SPEC.md section number cited by name from the compiler
    (compiler/lib/*.ml + compiler/test/*.ml) must resolve to a REAL heading in
    LANGUAGE-SPEC.md.  This is the spec-side twin of test_error_codes.ml (which
    guards the manual-side anchors): a diagnostic or comment that says
    "see LANGUAGE-SPEC.md §7.12" must never dangle after the spec is renumbered.

    What counts as a "spec citation":
      - a "§<number>" token, e.g. §7, §7.12, §14b, §14b.2, §20.5.

    What is deliberately EXCLUDED (these numbers are NOT spec sections):
      - internal-review shorthand — "Fix-11 §…", "Review20 §…",
        "critical-review-17 §…", "review 50 §…" (they cite review documents that
        carry their own §-numbering, e.g. Fix-11 §5.1 which is not a spec §);
      - by-LINE references (a "§" used to mean a source line, not a section).

    The test does NOT rewrite any citation — it only validates the existing ones.

    Pure OCaml, str + unix only (no alcotest, no compiler lib), so the parent can
    register it as a plain (test).  Locates the repo root by walking up from the
    cwd / executable, the same way test_error_codes.ml locates manual/.  Run:
      dune exec test/test_spec_anchors.exe
*)

let failures = ref 0
let check name ok msg =
  if ok then Printf.printf "ok   - %s\n" name
  else begin incr failures; Printf.printf "FAIL - %s: %s\n" name msg end

(* ── Locate the repo root (contains LANGUAGE-SPEC.md and compiler/) ────────── *)
let is_repo_root d =
  Sys.file_exists (Filename.concat d "LANGUAGE-SPEC.md")
  && Sys.file_exists (Filename.concat d "compiler")

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
      let s = if s = "" then Sys.getcwd () else s in
      (match up_to_root s 0 with Some d -> Some d | None -> pick rest)
  in
  match pick starts with
  | Some d -> d
  | None ->
    prerr_endline "FATAL: could not locate repo root (set TESL_REPO_ROOT)";
    exit 2

let read_file path =
  try Some (In_channel.with_open_text path In_channel.input_all)
  with Sys_error _ -> None

(* ── 1. Extract every section number that has a real heading ──────────────── *)
(* A heading line is "#{1,6} <text>".  A numbered section starts its text with a
   token like  1  |  7.12  |  14b  |  14b.1  |  20 .  We accept an optional
   trailing '.' after the number (as in "## 7. …" / "## 14b. …").  Headings whose
   text does not start with a digit (e.g. "## Table of Contents", "### Proofs vs
   Facts", "## Appendix A. …", "#### Boundary rules") contribute no number. *)
let heading_number_re =
  (* leading digits, optional trailing letters (14b), then dotted numeric tail *)
  Str.regexp "^#+[ \t]+\\([0-9]+[a-z]*\\(\\.[0-9]+\\)*\\)\\.?\\([ \t]\\|$\\)"

let spec_section_numbers spec_text =
  String.split_on_char '\n' spec_text
  |> List.filter_map (fun line ->
       if Str.string_match heading_number_re line 0 then
         Some (Str.matched_group 1 line)
       else None)
  |> List.sort_uniq compare

(* ── 2. Collect cited §-numbers from compiler sources ─────────────────────── *)

(* Is the '§' at [pos] in [line] an internal-review reference we must skip?
   Look at the text immediately before it (case-insensitively): review shorthand
   ends with  fix-<n> | review<n>? | review <n> | critical-review[-<n>]  then
   optional spaces right before the '§'. *)
let review_prefix_re =
  Str.regexp_case_fold
    ".*\\(fix-[0-9]+\\|review[ ]*[0-9]*\\|critical-review[-0-9]*\\)[ ]*$"

let is_review_ref line pos =
  let prefix = String.sub line 0 pos in
  Str.string_match review_prefix_re prefix 0
  && Str.match_end () = String.length prefix

(* A cited section number right after '§': same shape as a heading number. *)
let cite_re = Str.regexp "§\\([0-9]+[a-z]*\\(\\.[0-9]+\\)*\\)"

let citations_in_line acc line =
  let rec scan start acc =
    try
      let i = Str.search_forward cite_re line start in
      let num = Str.matched_group 1 line in
      let next = Str.match_end () in
      let acc =
        (* skip internal-review shorthand refs (they cite review docs, not spec) *)
        if is_review_ref line i then acc else (num, line) :: acc
      in
      scan next acc
    with Not_found -> acc
  in
  scan 0 acc

let ml_files_in dir =
  if Sys.file_exists dir then
    Sys.readdir dir |> Array.to_list |> List.sort String.compare
    |> List.filter (fun f -> Filename.check_suffix f ".ml")
    |> List.map (Filename.concat dir)
  else []

let citations_in_file acc path =
  match read_file path with
  | None -> acc
  | Some content ->
    String.split_on_char '\n' content
    |> List.fold_left citations_in_line acc

let () =
  Printf.printf "# spec §-anchor resolution test (repo_root = %s)\n" repo_root;

  let spec_path = Filename.concat repo_root "LANGUAGE-SPEC.md" in
  let spec =
    match read_file spec_path with
    | Some s -> s
    | None ->
      Printf.printf "FATAL: cannot read %s\n" spec_path; exit 2
  in
  let headings = spec_section_numbers spec in
  check "spec has a plausible heading set" (List.length headings >= 20)
    (Printf.sprintf "only %d numbered headings found" (List.length headings));

  (* sanity: a few headings we know must exist resolve *)
  List.iter (fun n ->
    check (Printf.sprintf "known heading present: %s" n) (List.mem n headings)
      (Printf.sprintf "spec has no §%s heading (extractor or spec drift?)" n))
    [ "7.4"; "7.12"; "14b"; "14b.2"; "20.5" ];

  let dirs =
    [ Filename.concat (Filename.concat repo_root "compiler") "lib";
      Filename.concat (Filename.concat repo_root "compiler") "test" ]
  in
  let files = List.concat_map ml_files_in dirs in
  check "found compiler sources to scan" (files <> [])
    "no .ml files under compiler/lib or compiler/test";

  let citations = List.fold_left citations_in_file [] files in
  (* de-dup on the (number, line) pair so the report is readable *)
  let citations = List.sort_uniq compare citations in
  let cited_nums = List.sort_uniq compare (List.map fst citations) in
  check "found spec citations to validate" (cited_nums <> [])
    "no §<n> citations found in compiler sources (regex or exclusion too broad?)";
  Printf.printf "  scanned %d file(s); %d distinct spec § cited: %s\n"
    (List.length files) (List.length cited_nums)
    (String.concat " " (List.map (fun n -> "§" ^ n) cited_nums));

  (* ── 3. every cited § resolves to a real heading ────────────────────────── *)
  let unresolved =
    List.filter (fun (n, _) -> not (List.mem n headings)) citations
    |> List.sort_uniq compare
  in
  List.iter (fun (n, line) ->
    Printf.printf "  OFFENDER: §%s has no heading in LANGUAGE-SPEC.md — cited in: %s\n"
      n (String.trim line))
    unresolved;
  check "every cited spec § resolves to a real heading" (unresolved = [])
    (Printf.sprintf "%d unresolved citation(s)" (List.length unresolved));

  Printf.printf "\n%s (%d failure(s))\n"
    (if !failures = 0 then "PASS" else "FAILURES") !failures;
  exit (if !failures = 0 then 0 else 1)
