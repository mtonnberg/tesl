(** Manual coherence + stable-anchor tests.

    Self-contained: this test reads the [manual/] markdown files directly and
    needs NO compiler library and NO Racket runtime, so it is safe to run in
    isolation while a shared-backend audit is in flight:

      dune exec --root manual/tests test_embedded_docs.exe
      # or, from inside manual/tests:
      dune runtest

    What it guards:

      1. Stable-anchor contract — every anchor documented in [manual/anchors.md]
         (the `<section>#<anchor>` rows) resolves to a real heading in the
         section file it names, using the slug rule that file documents.

      2. Error-message anchors — the exact anchors that the compiler CLI emits
         from [get_help_suggestion] in compiler/bin/main.ml are present.  These
         must never break, independently of what anchors.md happens to list.

      3. Section map — each documented manual section maps to a file that exists
         and is the file the CLI's `tesl help manual <section>` resolves to.

      4. Proof cost model — no manual page still describes proofs with the old
         "alpha safety net / erasure is a future goal" wording.  Proofs are now
         zero-cost and erased unconditionally (release and `--debug`); the
         debugger reads proof/type from compile-time. *)

(* ── Locate the manual/ directory ─────────────────────────────────────────── *)

(* Works whether run via `dune exec` (cwd = project root = manual/tests) or via
   `dune runtest` (cwd = the build dir), or directly.  We try a handful of
   candidate roots and pick the first that actually contains anchors.md. *)
let is_manual_dir d =
  Sys.file_exists (Filename.concat d "anchors.md")
  && Sys.file_exists (Filename.concat d "MANUAL.md")

(* Walk up from [start], returning the first ancestor that looks like manual/. *)
let find_manual_upwards start =
  let rec up dir n =
    if n > 10 then None
    else if is_manual_dir dir then Some dir
    (* the exe lives under manual/tests/_build/...; manual/ is an ancestor *)
    else
      let parent = Filename.dirname dir in
      if parent = dir then None else up parent (n + 1)
  in
  up start 0

let manual_dir =
  let env = try Sys.getenv "TESL_MANUAL_DIR" with Not_found -> "" in
  let direct = [ env; ".."; "."; "../.." ] in
  let from_exe () =
    let exe = try Unix.realpath Sys.executable_name with _ -> Sys.executable_name in
    (* try both the exe's dir and the cwd as walk-up starting points *)
    match find_manual_upwards (Filename.dirname exe) with
    | Some _ as r -> r
    | None -> find_manual_upwards (Sys.getcwd ())
  in
  match
    List.find_opt (fun d -> d <> "" && is_manual_dir d) direct
  with
  | Some d -> d
  | None ->
    (match from_exe () with
     | Some d -> d
     | None ->
       prerr_endline
         "FATAL: could not locate manual/ (looked for anchors.md + MANUAL.md). \
          Set TESL_MANUAL_DIR or run from manual/tests.";
       exit 2)

let read file =
  let path = Filename.concat manual_dir file in
  In_channel.with_open_text path In_channel.input_all

(* ── Tiny test harness (no external deps) ─────────────────────────────────── *)

let failures = ref 0
let check name ok msg =
  if ok then Printf.printf "ok   - %s\n" name
  else begin
    incr failures;
    Printf.printf "FAIL - %s: %s\n" name msg
  end

(* ── Slug rule (must match the rule documented in anchors.md) ─────────────── *)

(* lower-case; keep [a-z0-9 -]; drop everything else (punctuation, emoji,
   multibyte); collapse spaces to single '-'; trim leading/trailing '-'. *)
let slug (heading : string) : string =
  let b = Buffer.create (String.length heading) in
  String.iter
    (fun c ->
       let c = Char.lowercase_ascii c in
       if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') then Buffer.add_char b c
       else if c = ' ' || c = '-' then Buffer.add_char b ' '
       (* anything else (punctuation, '?', ':', high bytes of emoji/UTF-8) is dropped *)
    )
    heading;
  let raw = Buffer.contents b in
  (* collapse runs of spaces to one '-' and trim *)
  let parts =
    String.split_on_char ' ' raw
    |> List.filter (fun s -> s <> "")
  in
  String.concat "-" parts

(* ── Heading extraction ───────────────────────────────────────────────────── *)

let headings_of_file file : string list =
  read file
  |> String.split_on_char '\n'
  |> List.filter_map (fun line ->
       let l = String.trim line in
       if String.length l >= 2 && l.[0] = '#' then begin
         (* strip leading '#' run and the following space(s) *)
         let i = ref 0 in
         while !i < String.length l && l.[!i] = '#' do incr i done;
         let text = String.sub l !i (String.length l - !i) |> String.trim in
         if text = "" then None else Some text
       end else None)

(* set of slugs available in a file *)
let slugs_of_file file = List.map slug (headings_of_file file)

(* ── Section → file map (mirrors compiler/bin/main.ml) ────────────────────── *)

let section_files =
  [ "getting-started", "GETTING-STARTED.md";
    "overview",        "overview.md";
    "examples",        "examples.md";
    "best-practices",  "best-practices.md";
    "faq",             "FAQ.md";
    "anchors",         "anchors.md";
    (* language-spec lives at repo root, not in manual/, so we don't slug-check it here *)
  ]

let file_of_section s = List.assoc s section_files

(* ── Parse the canonical anchor rows out of anchors.md ────────────────────── *)

(* Rows look like:  | `best-practices#validation-patterns` | ... |
   We extract every `<section>#<anchor>` token wrapped in backticks. *)
let documented_anchors () : (string * string) list =
  let content = read "anchors.md" in
  let re =
    Str.regexp "`\\([a-z-]+\\)#\\([a-z0-9-]+\\)`"
  in
  let rec scan acc pos =
    match Str.search_forward re content pos with
    | exception Not_found -> List.rev acc
    | found ->
      let sec = Str.matched_group 1 content in
      let anc = Str.matched_group 2 content in
      scan ((sec, anc) :: acc) (found + String.length (Str.matched_string content))
  in
  (* de-duplicate while preserving order *)
  let seen = Hashtbl.create 16 in
  scan [] 0
  |> List.filter (fun pair ->
       if Hashtbl.mem seen pair then false
       else (Hashtbl.add seen pair (); true))

(* ── Anchors the CLI hard-codes in get_help_suggestion (must never break) ─── *)

let error_message_anchors =
  [ "best-practices", "proof-management";
    "best-practices", "validation-patterns";
    "best-practices", "api-design";
    "best-practices", "database-access";
    "overview",       "core-principles" ]

(* ── Tests ────────────────────────────────────────────────────────────────── *)

let () =
  Printf.printf "# manual coherence tests (manual_dir = %s)\n" manual_dir;

  (* 1. slug rule sanity (locks the rule documented in anchors.md) *)
  check "slug: Validation Patterns" (slug "Validation Patterns" = "validation-patterns") "wrong slug";
  check "slug: Proof Cost Model" (slug "Proof Cost Model" = "proof-cost-model") "wrong slug";
  check "slug: question mark dropped"
    (slug "Is there runtime overhead for proofs?" = "is-there-runtime-overhead-for-proofs")
    "punctuation not stripped";
  check "slug: emoji + leading marker dropped"
    (slug "✅ Validate Once at the Boundary" = "validate-once-at-the-boundary")
    "emoji/space handling wrong";

  (* 2. every documented section file exists and is non-empty *)
  List.iter
    (fun (sec, file) ->
       let exists = Sys.file_exists (Filename.concat manual_dir file) in
       check (Printf.sprintf "section file exists: %s -> %s" sec file)
         (exists && String.length (read file) > 0)
         "missing or empty")
    section_files;

  (* 3. error-message anchors resolve (the contract main.ml depends on) *)
  List.iter
    (fun (sec, anc) ->
       let file = file_of_section sec in
       let ok = List.mem anc (slugs_of_file file) in
       check (Printf.sprintf "error-msg anchor resolves: %s#%s" sec anc)
         ok
         (Printf.sprintf "no heading in %s slugs to '%s'" file anc))
    error_message_anchors;

  (* 4. every anchor documented in anchors.md resolves to a real heading *)
  let documented = documented_anchors () in
  check "anchors.md lists some anchors" (List.length documented >= 8)
    (Printf.sprintf "only found %d" (List.length documented));
  List.iter
    (fun (sec, anc) ->
       match List.assoc_opt sec section_files with
       | None ->
         (* sections like 'language-spec' have no in-manual file to check *)
         check (Printf.sprintf "documented anchor section known: %s#%s" sec anc)
           (sec = "language-spec")
           (Printf.sprintf "anchors.md references unknown section '%s'" sec)
       | Some file ->
         let ok = List.mem anc (slugs_of_file file) in
         check (Printf.sprintf "documented anchor resolves: %s#%s" sec anc)
           ok
           (Printf.sprintf "no heading in %s slugs to '%s'" file anc))
    documented;

  (* 5. the contract anchors are themselves documented in anchors.md *)
  List.iter
    (fun (sec, anc) ->
       check (Printf.sprintf "error-msg anchor is documented: %s#%s" sec anc)
         (List.mem (sec, anc) documented)
         "present in main.ml but not listed in anchors.md")
    error_message_anchors;

  (* 6. proof cost model — no stale wording anywhere in the manual *)
  let stale_phrases =
    [ "elided in the future";
      "represented as runtime structs";
      "plan to elide";
      "goal is erasure";
      "will be completely elided";
      "currently allocated at runtime";
      "Proofs are carried as lightweight runtime structs" ]
  in
  let manual_md_files =
    Sys.readdir manual_dir
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".md")
    |> List.sort String.compare
  in
  List.iter
    (fun file ->
       let content = read file in
       List.iter
         (fun phrase ->
            let contains =
              let lc s = String.lowercase_ascii s in
              let hay = lc content and needle = lc phrase in
              let nlen = String.length needle and hlen = String.length hay in
              let rec at i =
                if i + nlen > hlen then false
                else if String.sub hay i nlen = needle then true
                else at (i + 1)
              in
              nlen > 0 && at 0
            in
            check
              (Printf.sprintf "no stale proof wording in %s: %S" file phrase)
              (not contains)
              "stale proof cost-model wording found")
         stale_phrases)
    manual_md_files;

  (* 6b. (D8a) Banned marketing phrases must not resurface in the calibrated
     docs (documentation_improvements, decision #4: retire "unbreakable" /
     "production-ready").  The ONLY allowed occurrence is TESL.md's honest alpha
     disclaimer, which uses the word inside an explicit negation — allowlisted by
     the "not as a promise" marker on that line. *)
  (* manual_dir may be relative (e.g. ".."), so append parent rather than
     dirname (which would map ".." -> "."). *)
  let repo_root = Filename.concat manual_dir Filename.parent_dir_name in
  let read_abs path = In_channel.with_open_text path In_channel.input_all in
  let lc s = String.lowercase_ascii s in
  let line_contains needle hay =
    let needle = lc needle and hay = lc hay in
    let nlen = String.length needle and hlen = String.length hay in
    let rec at i =
      if i + nlen > hlen then false
      else if String.sub hay i nlen = needle then true else at (i + 1)
    in
    nlen > 0 && at 0
  in
  let banned = [ "unbreakable"; "production-ready" ] in
  let disclaimer_marker = "not as a promise" in
  let scan_banned label content =
    let lines = String.split_on_char '\n' content in
    List.iter
      (fun phrase ->
         let offenders =
           List.filter
             (fun ln -> line_contains phrase ln
                        && not (line_contains disclaimer_marker ln))
             lines
         in
         check
           (Printf.sprintf "no banned marketing phrase %S in %s" phrase label)
           (offenders = [])
           (Printf.sprintf
              "found %d line(s) with %S outside the allowlisted beta disclaimer"
              (List.length offenders) phrase))
      banned
  in
  scan_banned "TESL.md" (read_abs (Filename.concat repo_root "TESL.md"));
  scan_banned "manual/overview.md" (read "overview.md");
  scan_banned "README.md" (read_abs (Filename.concat repo_root "README.md"));

  (* 6c. (D8b) every dev-docs/*.md carries an "Audience:" banner — the four-way
     partition discipline: a doc must declare WHO it is for so user vs. contributor
     material cannot silently interleave. *)
  let dev_dir = Filename.concat repo_root "dev-docs" in
  (if Sys.file_exists dev_dir then
     Sys.readdir dev_dir |> Array.to_list
     |> List.filter (fun f -> Filename.check_suffix f ".md")
     |> List.sort String.compare
     |> List.iter (fun f ->
          let content = read_abs (Filename.concat dev_dir f) in
          check (Printf.sprintf "dev-docs/%s has an Audience: banner" f)
            (line_contains "audience:" content)
            "add an `> Audience: …` banner right after the H1"));

  (* 6d. (D8c) README carries NO contributor build instructions (dev shell / CI
     runners) — those live behind a single link to dev-docs/README.md, so the user
     funnel does not cross into the contributor partition. *)
  let readme = read_abs (Filename.concat repo_root "README.md") in
  List.iter (fun tok ->
    check (Printf.sprintf "README has no contributor build instruction %S" tok)
      (not (line_contains tok readme))
      "move the dev shell / CI-runner instructions to dev-docs/README.md (link only)")
    [ "nix develop"; "nix-shell"; "compiler/ci.sh"; "compile-examples.sh" ];

  (* 6e. (D8d) every manual/*.md is reachable — it is the index/meta itself, or it
     is linked from MANUAL.md — so no orphaned manual page exists that a reader
     (or the CLI funnel) cannot find. *)
  let manual_index = read "MANUAL.md" in
  let manual_meta_allowlist = [ "MANUAL.md"; "anchors.md" ] in
  Sys.readdir manual_dir |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".md")
  |> List.sort String.compare
  |> List.iter (fun f ->
       check (Printf.sprintf "manual/%s is the index/meta or linked from MANUAL.md" f)
         (List.mem f manual_meta_allowlist || line_contains f manual_index)
         "link it from MANUAL.md, or add it to the meta allowlist if it is index/meta");

  (* 7. the new cost-model anchor exists where docs link to it *)
  check "best-practices#proof-cost-model exists"
    (List.mem "proof-cost-model" (slugs_of_file "best-practices.md"))
    "Proof Cost Model heading missing";
  check "faq#is-there-runtime-overhead-for-proofs exists"
    (List.mem "is-there-runtime-overhead-for-proofs" (slugs_of_file "FAQ.md"))
    "FAQ proof-overhead heading missing";

  (* 8. (D2-lite) prose ```tesl fences must not regress into the D1 syntax-rot
     class.  D1 was a GETTING-STARTED first program that failed to parse on line
     one (`predicate … where`, a `Tesl.Db` mis-case, `server … impl … on 8080`).
     FULL compile-gating of every fence (D2) needs a per-fence triage
     (complete-program vs. illustrative fragment) and is tracked in roadmap/later;
     this lint instead closes the specific STRUCTURAL rot class across ALL tesl
     fences with signals that are unambiguous and currently zero.
       NOTE: `--` line comments (another D1 symptom) are deliberately NOT linted —
     the SPEC and FAQ use `--` as an illustrative-comment convention inside
     pseudo-code fences (~119 occurrences), so it is not a reliable rot signal.
     The three signals below ARE (the Tesl comment marker is `#`; the DB module is
     `Tesl.DB`; `predicate` is not a keyword; the server clause is not `impl…on`). *)
  let tesl_fence_lines content =
    let fence = "```" in
    let sw p s =
      String.length s >= String.length p && String.sub s 0 (String.length p) = p in
    let rec go n in_tesl acc = function
      | [] -> List.rev acc
      | ln :: rest ->
        let t = String.trim ln in
        if sw fence t then begin
          if in_tesl then go (n + 1) false acc rest
          else
            let lang =
              String.lowercase_ascii
                (String.trim
                   (String.sub t (String.length fence)
                      (String.length t - String.length fence)))
            in
            go (n + 1) (sw "tesl" lang) acc rest
        end else
          go (n + 1) in_tesl (if in_tesl then (n, ln) :: acc else acc) rest
    in
    go 1 false [] (String.split_on_char '\n' content)
  in
  let re_search re s = try ignore (Str.search_forward re s 0); true with Not_found -> false in
  let re_predicate = Str.regexp "[ \t]*predicate[ \t]" in
  let re_tesl_db = Str.regexp_string "Tesl.Db" in     (* mis-case; correct is Tesl.DB *)
  let re_impl = Str.regexp "impl[^A-Za-z]" in          (* excludes `implies` / `implement` *)
  let re_on_port = Str.regexp "on[ \t]+[0-9]" in
  (* E3 (2026-07-04): the single-line `if cond then a else b` form is rejected by
     the parser (E000 — the then/else bodies must be on their own indented lines).
     Flag a fence line where the word `then` is followed by a token on the SAME
     line, EXCEPT (a) `then` followed only by whitespace + a `#` comment (the body
     is on the next line — valid), and (b) `then` inside a string literal (an even
     number of double-quote chars precede it), e.g. a test name that contains the
     word then. *)
  let re_single_line_if = Str.regexp "\\bthen\\b[ \t]+[^ \t#]" in
  let single_line_if ln =
    let t = String.trim ln in
    if t <> "" && t.[0] = '#' then false   (* whole-line comment — `then` is prose *)
    else
    try
      let idx = Str.search_forward re_single_line_if ln 0 in
      let quotes = ref 0 in
      for i = 0 to idx - 1 do if ln.[i] = '"' then incr quotes done;
      !quotes mod 2 = 0
    with Not_found -> false
  in
  let rot_of_line ln =
    (if re_search re_tesl_db ln then ["`Tesl.Db` mis-case (the module is `Tesl.DB`)"] else [])
    @ (if Str.string_match re_predicate ln 0 then ["`predicate` as a declaration keyword (use `check` / `fact`)"] else [])
    @ (if re_search re_impl ln && re_search re_on_port ln then ["old `server … impl … on PORT` syntax"] else [])
  in
  (* Block-aware single-line-if detection: a fence that DEMONSTRATES the rejected
     form as a counter-example labels it with a `#` marker (WRONG / Rejected / not
     supported / …), so skip the whole block; only CORRECT-intent blocks are held to
     the multi-line rule. *)
  let block_has_rejection_marker lines =
    List.exists (fun (_, ln) ->
      let t = String.trim ln in
      if t = "" || t.[0] <> '#' then false
      else
        let lc = String.lowercase_ascii t in
        let has s = re_search (Str.regexp_string s) lc in
        has "wrong" || has "reject" || has "not supported" || has "error"
        || has "bad" || has "don't" || has "avoid" || has "illegal") lines
  in
  (* Group consecutive in-fence line pairs into blocks (fence markers are absent
     from the pair list, so a gap in line numbers separates blocks). *)
  let group_blocks pairs =
    let rec go acc cur last = function
      | [] -> List.rev (if cur = [] then acc else List.rev cur :: acc)
      | (n, ln) :: rest ->
        if last >= 0 && n = last + 1 then go acc ((n, ln) :: cur) n rest
        else go (if cur = [] then acc else List.rev cur :: acc) [ (n, ln) ] n rest
    in
    go [] [] (-2) pairs
  in
  let single_line_if_offenders pairs =
    group_blocks pairs
    |> List.concat_map (fun block ->
         if block_has_rejection_marker block then []
         else
           List.filter_map (fun (n, ln) ->
             if single_line_if ln then
               Some (n, "single-line `if … then a` (E000 — put the then/else bodies \
                         on their own indented lines)", String.trim ln)
             else None) block)
  in
  let dir_md dir =
    let d = Filename.concat repo_root dir in
    if Sys.file_exists d then
      Sys.readdir d |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".md")
      |> List.sort String.compare
      |> List.map (fun f -> (Filename.concat dir f, Filename.concat d f))
    else []
  in
  let docs_to_lint =
    (List.map (fun f -> (f, Filename.concat repo_root f)) [ "README.md"; "TESL.md"; "LANGUAGE-SPEC.md" ])
    @ dir_md "manual" @ dir_md "dev-docs" @ dir_md "example/intro"
    |> List.filter (fun (_, abs) -> Sys.file_exists abs)
  in
  List.iter (fun (rel, abs) ->
    let pairs = tesl_fence_lines (read_abs abs) in
    let offenders =
      (pairs
       |> List.concat_map (fun (n, ln) ->
            List.map (fun why -> (n, why, String.trim ln)) (rot_of_line ln)))
      @ single_line_if_offenders pairs
    in
    check (Printf.sprintf "no D1-class syntax rot in tesl fences of %s" rel)
      (offenders = [])
      (match offenders with
       | [] -> ""
       | (n, why, txt) :: _ ->
         Printf.sprintf "%s:%d %s — %S%s" rel n why txt
           (if List.length offenders > 1
            then Printf.sprintf " (+%d more)" (List.length offenders - 1) else "")))
    docs_to_lint;

  Printf.printf "\n%s (%d failure(s))\n"
    (if !failures = 0 then "PASS" else "FAILURES") !failures;
  exit (if !failures = 0 then 0 else 1)
