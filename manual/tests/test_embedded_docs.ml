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

  (* 7. the new cost-model anchor exists where docs link to it *)
  check "best-practices#proof-cost-model exists"
    (List.mem "proof-cost-model" (slugs_of_file "best-practices.md"))
    "Proof Cost Model heading missing";
  check "faq#is-there-runtime-overhead-for-proofs exists"
    (List.mem "is-there-runtime-overhead-for-proofs" (slugs_of_file "FAQ.md"))
    "FAQ proof-overhead heading missing";

  Printf.printf "\n%s (%d failure(s))\n"
    (if !failures = 0 then "PASS" else "FAILURES") !failures;
  exit (if !failures = 0 then 0 else 1)
