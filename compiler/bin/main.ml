(** Tesl compiler CLI.

    Usage:
      tesl <file>                compile .tesl file to Racket (stdout)
      tesl --check <file> ...    check for parse + type errors (exit 1 if any)
      tesl --check-batch <file> ...  batch-check many files in one process (per-file summary)
      tesl --check-all <dir>     recursively batch-check every .tesl file under <dir>
      tesl --check-json <file>   check, emit diagnostics as IR-2 JSON
      tesl --local-bindings-json <file> emit inferred local binding types as JSON
      tesl --definition-json <file> <line> <col> emit definition location as JSON
      tesl --occurrences-json <file> <line> <col> emit same-file occurrences as JSON
      tesl --type-at-json <file> <line> <col> emit expression type at cursor as JSON
      tesl --field-at-json <file> <line> <col> emit record field info at cursor as JSON
      tesl --completions-json <file> <line> <col> emit completions at cursor as JSON
      tesl --fmt <file>          format source file in place
      tesl --fmt-check <file>    check formatting without modifying
      tesl --lint <file> ...     run the opinionated linter
      tesl --ir <file>           emit API IR JSON
      tesl --deps <file>         list all transitively imported local .tesl files
      tesl --semantic-json <file>  emit full module semantic snapshot as JSON
      tesl --mutate <file> [test-file ...]  run mutation testing
      tesl help [manual] [section]  show help and documentation
*)

let usage = {|Usage:
  tesl <file>                  compile .tesl file to Racket (stdout)
  tesl --check <file> [...]    check for parse + type errors (exit 1 if any)
  tesl --check-batch <file> [...]  batch-check many files in one process (shared import cache, per-file summary)
  tesl --check-all <dir>       recursively batch-check every .tesl file under <dir>
  tesl --check-json <file>     check, emit diagnostics as IR-2 JSON
  tesl --local-bindings-json <file> emit inferred local binding types as JSON
  tesl --definition-json <file> <line> <col> emit definition location as JSON
  tesl --occurrences-json <file> <line> <col> emit same-file occurrences as JSON
  tesl --type-at-json <file> <line> <col> emit expression type at cursor as JSON
  tesl --field-at-json <file> <line> <col> emit record field info at cursor as JSON
  tesl --completions-json <file> <line> <col> emit completions at cursor as JSON
  tesl --signature-help-json <file> <line> <col> emit call signature + active param as JSON
  tesl --selection-range-json <file> <line> <col> emit nested node ranges at cursor as JSON
  tesl --type-definition-json <file> <line> <col> emit the type's declaration location as JSON
  tesl --fmt <file>            format source file in place
  tesl --fmt-check <file>      check formatting without modifying
  tesl --lint <file> [...]     run the opinionated linter
  tesl --debug <file>          compile with step-debugger instrumentation (thsl-src wrappers)
  tesl --ir <file>             emit API IR JSON
  tesl --deps <file>           list all transitively imported local .tesl files (one per line)
  tesl --semantic-json <file>  emit full module semantic snapshot as JSON (IR-1 foundation)
  tesl agent-context <file>    emit a compact AI-agent snapshot (diagnostics+symbols+obligations) as JSON
  tesl --agent-context-json <file>  alias for `tesl agent-context`
  tesl debug-inspect <file> --break-at SPEC [...]  run to a breakpoint (headless) and dump paused runtime state as JSON
  tesl --mutate <file> [test-file ...]  run mutation testing; optionally merge tests from extra files
  tesl --exe <file> [--out <path>]  build a standalone executable via `raco exe` (needs raco on PATH)

Help:
  tesl help                    show this help message
  tesl help manual             show the complete manual index
  tesl help manual <section>   show a specific manual section (overview, language-spec, examples, best-practices, faq, dev)
  tesl help manual <section>#<anchor>  jump to a sub-section (e.g. best-practices#proof-management)
  tesl help manual full        show all documentation concatenated (for LLMs with large context windows)
  tesl help full               same as 'tesl help manual full'
  tesl help examples           show the list of all examples
  tesl help search <query>     search across all documentation for a query
  tesl help codes              list every diagnostic code the compiler can emit
  tesl help <CODE>             explain a diagnostic code (e.g. tesl help V001)
  tesl explain <CODE>          same as 'tesl help <CODE>'
|}

(* ── ANSI colours ────────────────────────────────────────────────────────── *)

let use_colour = Unix.isatty Unix.stderr
let col code   = if use_colour then "\027[" ^ code ^ "m" else ""

(* ── Documentation paths ───────────────────────────────────────────────────── *)

let manual_dir = ref ""
let root_path = ref ""

(* ── File reading ──────────────────────────────────────────────────────────── *)

let read_file filename =
  try
    let ic = open_in filename in
    let contents = really_input_string ic (in_channel_length ic) in
    close_in ic;
    Some contents
  with Sys_error _ -> None

(** Read a file from disk; fall back to the embedded content store when the
    file is not present on disk (e.g. in an installed nix-flake binary with
    no local repo checkout).  [embedded_key] is the path relative to the
    repo root used as the key in [Embedded_docs]. *)
let read_file_or_embedded disk_path embedded_key =
  match read_file disk_path with
  | Some _ as r -> r
  | None -> Embedded_docs.lookup embedded_key

let find_doc_root () =
  (* First, check TESL_REPO_ROOT environment variable *)
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some repo_root when repo_root <> "" ->
    let manual_path = Filename.concat repo_root "manual" in
    if Sys.file_exists manual_path then Some manual_path else None
  | _ ->
    (* Then check TESL_ROOT *)
    (match Sys.getenv_opt "TESL_ROOT" with
     | Some root when root <> "" ->
       let manual_path = Filename.concat root "manual" in
       if Sys.file_exists manual_path then Some manual_path else None
     | _ -> None)
  |> function
    | Some p -> Some p
    | None ->
      let bin_dir = Filename.dirname (Sys.argv.(0)) in
      
      (* Then check if we're in an installed location (share/tesl/doc) *)
      let rec check_parent dir count =
        if count > 5 then None  (* Don't go too far up *)
        else
          let doc_dir = Filename.concat dir "share/tesl/doc" in
          if Sys.file_exists doc_dir then
            Some (Filename.concat dir "share/tesl/doc")
          else
            let parent = Filename.dirname dir in
            if parent = dir then None
            else check_parent parent (count + 1)
      in
      
      match check_parent bin_dir 0 with
      | Some doc_path -> Some doc_path
      | None ->
        (* Fall back to repo layout *)
        let candidate =
          Filename.concat bin_dir "../../../../.." |> Filename.concat "" |> fun p ->
          try Unix.realpath p with _ -> p
        in
        if Sys.file_exists (Filename.concat candidate "dsl") then
          Some (Filename.concat candidate "manual")
        else
          let rec find_root dir =
            if Sys.file_exists (Filename.concat dir "dsl") then
              Some (Filename.concat dir "manual")
            else
              let parent = Filename.dirname dir in
              if parent = dir then None
              else find_root parent
          in
          find_root (Filename.dirname bin_dir)

let find_repo_root () =
  (* First, check environment variables *)
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some p when p <> "" -> p
  | _ ->
    match Sys.getenv_opt "TESL_ROOT" with
    | Some p when p <> "" -> p
    | _ ->
      match find_doc_root () with
      | Some doc_path ->
        (* If we found a doc directory, the repo root is the parent of share/tesl/doc *)
        let rec get_repo_root path =
          let parent = Filename.dirname path in
          if Filename.basename parent = "share" then
            Filename.dirname parent
          else
            get_repo_root parent
        in
        get_repo_root doc_path
      | None ->
        let bin_dir = Filename.dirname (Sys.argv.(0)) in
        let candidate =
          Filename.concat bin_dir "../../../../.." |> Filename.concat "" |> fun p ->
          try Unix.realpath p with _ -> p
        in
        if Sys.file_exists (Filename.concat candidate "dsl") then candidate
        else
          let rec find_root dir =
            if Sys.file_exists (Filename.concat dir "dsl") then dir
            else
              let parent = Filename.dirname dir in
              if parent = dir then Sys.getcwd ()
              else find_root parent
          in
          find_root (Filename.dirname bin_dir)

let init_paths () =
  match find_doc_root () with
  | Some doc_path ->
    (* Check if this is an installed location (ends with /share/tesl/doc) *)
    if Filename.check_suffix doc_path "/share/tesl/doc" then begin
      root_path := Filename.dirname (Filename.dirname doc_path);  (* Remove /share/tesl/doc *)
      manual_dir := doc_path
    end else begin
      (* This is a dev mode path - doc_path is the manual directory itself *)
      let rp = Filename.dirname doc_path in
      root_path := rp;
      manual_dir := doc_path
    end
  | None ->
    let rp = find_repo_root () in
    root_path := rp;
    manual_dir := Filename.concat rp "manual"

(* ── Manual content ────────────────────────────────────────────────────────── *)

(** Map a section name to the embedded-docs key used to look it up in
    [Embedded_docs] when the file is not found on disk. *)
let section_to_embedded_key name =
  (* Strip "example/" or "examples/" prefix for example lookups *)
  let remove_example_prefix s =
    if String.starts_with ~prefix:"examples/" s then
      String.sub s 9 (String.length s - 9)
    else if String.starts_with ~prefix:"example/" s then
      String.sub s 8 (String.length s - 8)
    else s
  in
  match name with
  | "" | "manual"                         -> "manual/MANUAL.md"
  | "getting-started" | "get-started" | "start" -> "manual/GETTING-STARTED.md"
  | "overview" | "tutorial"               -> "manual/overview.md"
  | "language-spec"                        -> "LANGUAGE-SPEC.md"
  | "examples"                             -> "manual/examples.md"
  | "best-practices"                       -> "manual/best-practices.md"
  (* dev docs live at the repo root in dev-docs/, embedded under "dev-docs/…" *)
  | "dev"                                  -> "dev-docs/README.md"
  | "faq"                                  -> "manual/FAQ.md"
  (* D17: the prose "TLDR of the whole language" newcomer track. *)
  | "intro"                                -> "example/intro/README.md"
  (* D12/D13: the guided feature tour + the rehomed user-facing deploy/manifest docs. *)
  | "tour"                                 -> "manual/tour.md"
  | "deploy"                               -> "manual/deploy.md"
  | "tesl-manifest" | "manifest"           -> "manual/tesl-manifest.md"
  | other ->
    let ex = remove_example_prefix other in
    (* allow `dev/<file>` and `dev-docs/<file>` to reach a specific dev doc *)
    let dev_rel =
      if String.starts_with ~prefix:"dev/" other then
        Some (String.sub other 4 (String.length other - 4))
      else if String.starts_with ~prefix:"dev-docs/" other then
        Some (String.sub other 9 (String.length other - 9))
      else None
    in
    (* Try each candidate embedded key in priority order; use the first that exists *)
    let candidates = [
      "manual/" ^ other ^ ".md";
      "manual/" ^ other;
      "example/intro/" ^ ex ^ ".md";
      "example/learn/" ^ ex ^ ".tesl";
      "example/learn/" ^ ex ^ ".md";
      "example/kanel/" ^ ex ^ ".tesl";
      "example/" ^ ex ^ ".tesl";
      "example/" ^ ex ^ ".md";
      other ^ ".md";
      other;
    ] @ (match dev_rel with
         | Some f -> [ "dev-docs/" ^ f ^ ".md"; "dev-docs/" ^ f ]
         | None -> []) in
    (match List.find_opt (fun k -> Embedded_docs.lookup k <> None) candidates with
     | Some k -> k
     | None -> "manual/" ^ other ^ ".md")

let get_manual_content section =
  init_paths ();
  let get_disk_path name =
    match name with
    | "" | "manual" -> Filename.concat !manual_dir "MANUAL.md"
    | "getting-started" | "get-started" | "start" -> Filename.concat !manual_dir "GETTING-STARTED.md"
    | "overview" | "tutorial" -> Filename.concat !manual_dir "overview.md"
    | "language-spec" -> Filename.concat !manual_dir "LANGUAGE-SPEC.md"
    | "examples" -> Filename.concat !manual_dir "examples.md"
    | "best-practices" -> Filename.concat !manual_dir "best-practices.md"
    (* dev docs live at the repo root in dev-docs/.  Prefer the repo-root copy;
       fall back to a doc-dir copy if one was shipped there.  When neither is on
       disk (installed binary), the embedded store ("dev-docs/README.md") is
       consulted by the caller below. *)
    | "dev" ->
      let root_dev = Filename.concat !root_path "dev-docs/README.md" in
      let doc_dev = Filename.concat !manual_dir "dev-docs/README.md" in
      if Sys.file_exists root_dev then root_dev else doc_dev
    | "faq" -> Filename.concat !manual_dir "FAQ.md"
    | "intro" -> Filename.concat !root_path "example/intro/README.md"
    | "tour" -> Filename.concat !manual_dir "tour.md"
    | "deploy" -> Filename.concat !manual_dir "deploy.md"
    | "tesl-manifest" | "manifest" -> Filename.concat !manual_dir "tesl-manifest.md"
    | _ ->
      let try_path path = if Sys.file_exists path then Some path else None in
      let try_paths paths =
        List.fold_left (fun acc path -> match acc with Some _ -> acc | None -> try_path path) None paths
      in
      let doc_example_path = Filename.concat !manual_dir "example" in
      let remove_example_prefix s =
        if String.starts_with ~prefix:"examples/" s then String.sub s 9 (String.length s - 9)
        else if String.starts_with ~prefix:"example/" s then String.sub s 8 (String.length s - 8)
        else s
      in
      let example_name = remove_example_prefix name in
      (* `dev/<file>` and `dev-docs/<file>` reach a specific contributor doc. *)
      let dev_rel =
        if String.starts_with ~prefix:"dev/" name then
          Some (String.sub name 4 (String.length name - 4))
        else if String.starts_with ~prefix:"dev-docs/" name then
          Some (String.sub name 9 (String.length name - 9))
        else None
      in
      let dev_paths = match dev_rel with
        | Some f ->
          [ Filename.concat !root_path ("dev-docs/" ^ f ^ ".md");
            Filename.concat !root_path ("dev-docs/" ^ f);
            Filename.concat !manual_dir ("dev-docs/" ^ f ^ ".md") ]
        | None -> []
      in
      let possible_paths = dev_paths @ [
        Filename.concat !manual_dir (name ^ ".md");
        Filename.concat !manual_dir name;
        Filename.concat doc_example_path (example_name ^ ".tesl");
        Filename.concat doc_example_path (example_name ^ ".md");
        Filename.concat doc_example_path example_name;
        Filename.concat !root_path (name ^ ".md");
        Filename.concat !root_path (name ^ ".tesl");
        Filename.concat !root_path ("example/" ^ example_name ^ ".tesl");
        Filename.concat !root_path ("example/" ^ example_name);
        Filename.concat !root_path ("example/" ^ example_name ^ ".md");
        Filename.concat !root_path ("example/intro/" ^ example_name ^ ".md");
      ] in
      match try_paths possible_paths with
      | Some p -> p
      | None -> Filename.concat !manual_dir (name ^ ".md")
  in
  let disk_path = get_disk_path section in
  match read_file disk_path with
  | Some _ as r -> r
  | None -> Embedded_docs.lookup (section_to_embedded_key section)

let get_examples_list () =
  init_paths ();
  read_file_or_embedded
    (Filename.concat !manual_dir "examples.md")
    "manual/examples.md"

(* ── Full manual content for LLMs ─────────────────────────────────────────── *)

(* Helper function to recursively collect all .md files from a directory *)
let rec collect_md_files dir acc =
  try
    let files = Array.to_list (Sys.readdir dir) in
    List.fold_left (fun acc filename ->
      let path = Filename.concat dir filename in
      if Sys.is_directory path then
        collect_md_files path acc
      else if Filename.check_suffix filename ".md" then
        path :: acc
      else
        acc
    ) acc files
  with Sys_error _ -> acc

let get_full_manual () =
  init_paths ();

  (* Priority-ordered list of (disk-path, embedded-key) pairs for documentation *)
  let doc_pairs = [
    Filename.concat !manual_dir "MANUAL.md",         "manual/MANUAL.md";
    Filename.concat !manual_dir "GETTING-STARTED.md","manual/GETTING-STARTED.md";
    Filename.concat !manual_dir "overview.md",        "manual/overview.md";
    Filename.concat !manual_dir "examples.md",        "manual/examples.md";
    Filename.concat !manual_dir "best-practices.md",  "manual/best-practices.md";
    Filename.concat !manual_dir "FAQ.md",             "manual/FAQ.md";
    Filename.concat !manual_dir "LANGUAGE-SPEC.md",   "LANGUAGE-SPEC.md";
    Filename.concat !manual_dir "TESL.md",            "TESL.md";
    Filename.concat !manual_dir "INSTALL.md",         "INSTALL.md";
    Filename.concat !manual_dir "README.md",          "README.md";
  ] in

  (* Contributor docs live at the repo root in dev-docs/ (NOT manual/dev-docs/).
     Disk path is rooted at !root_path; embedded key is "dev-docs/<file>" to
     match what gen_docs.ml bakes in. *)
  let dev_doc_pairs =
    List.map (fun f ->
      Filename.concat !root_path ("dev-docs/" ^ f), "dev-docs/" ^ f)
      [ "README.md"; "01-overview.md"; "02-parser.md"; "03-module-system.md";
        "04-body-compiler.md"; "05-adding-stdlib-function.md"; "06-gdp-runtime.md";
        "07-sql-layer.md"; "08-queue-pubsub.md"; "09-adding-tests.md";
        "10-common-patterns.md"; "11-frontend-ir.md"; "zero-cost-proofs-contract.md" ]
  in

  (* Collect disk-based example .md files (only in dev/repo environments) *)
  let disk_example_md_files =
    let example_dir = Filename.concat !manual_dir "example" in
    if Sys.file_exists example_dir then
      collect_md_files example_dir []
    else
      let repo_example_dir = Filename.concat !root_path "example" in
      if Sys.file_exists repo_example_dir then collect_md_files repo_example_dir []
      else []
  in

  (* Collect content: disk takes priority, fallback to embedded for each doc *)
  let collect_pairs pairs =
    List.filter_map (fun (disk_path, embedded_key) ->
      match read_file_or_embedded disk_path embedded_key with
      | Some content -> Some (embedded_key, content)
      | None -> None
    ) pairs
  in

  (* Collect all embedded lesson and example tesl files *)
  let embedded_examples =
    Embedded_docs.all_keys ()
    |> List.filter (fun k ->
         (String.starts_with ~prefix:"example/" k)
         && (Filename.check_suffix k ".tesl" || Filename.check_suffix k ".md"))
    |> List.sort String.compare
    |> List.filter_map (fun k ->
         (* Skip files already on disk via disk_example_md_files *)
         match Embedded_docs.lookup k with
         | Some content -> Some (k, content)
         | None -> None)
  in

  let doc_contents     = collect_pairs doc_pairs in
  let dev_doc_contents = collect_pairs dev_doc_pairs in
  let disk_md_contents =
    List.filter_map (fun f ->
      match read_file f with
      | Some content -> Some (f, content)
      | None -> None
    ) disk_example_md_files
  in

  let buf = Buffer.create 512000 in
  Buffer.add_string buf "TESL FULL MANUAL FOR LLMS\n";
  Buffer.add_string buf "=====================================\n";
  Buffer.add_string buf "(This is a concatenated, non-human-readable format for LLM context windows)\n\n";

  let emit_section label contents =
    if contents <> [] then begin
      Buffer.add_string buf ("\n\n" ^ String.make 72 '=' ^ "\n");
      Buffer.add_string buf ("== " ^ label ^ "\n");
      Buffer.add_string buf (String.make 72 '=' ^ "\n\n");
      List.iter (fun (key, content) ->
        Buffer.add_string buf ("\n--- [" ^ key ^ "] ---\n");
        Buffer.add_string buf content;
        Buffer.add_string buf "\n"
      ) contents
    end
  in

  emit_section "DOCUMENTATION" doc_contents;
  emit_section "DEVELOPER DOCS" dev_doc_contents;
  emit_section "EXAMPLES AND LESSONS" (disk_md_contents @ embedded_examples);

  Buffer.contents buf

(* ── Search functionality ───────────────────────────────────────────────────── *)

let string_contains substring str =
  let len = String.length substring in
  if len = 0 then true
  else
    let rec check i =
      if i > String.length str - len then false
      else if String.sub str i len = substring then true
      else check (i + 1)
    in check 0

let search_docs query =
  init_paths ();
  let query_lower = String.lowercase_ascii query in
  (* Order-insensitive match: a line matches when it contains every
     whitespace-separated query word (in any order), rather than the exact
     phrase.  So "client generate" and "generate client" both match a line that
     mentions both words.  A single-word (or empty) query behaves as before. *)
  let query_words =
    String.split_on_char ' ' query_lower
    |> List.filter (fun w -> w <> "")
  in
  let line_matches line_lower =
    List.for_all (fun w -> string_contains w line_lower) query_words
  in
  let search_content key content acc =
    let lines = String.split_on_char '\n' content in
    let matching_lines = List.filter (fun line ->
      line_matches (String.lowercase_ascii line)
    ) lines in
    if matching_lines <> [] then (key, matching_lines) :: acc
    else acc
  in
  let search_file file acc =
    match read_file file with
    | None -> acc
    | Some content -> search_content file content acc
  in
  let rec search_dir dir acc =
    try
      let files = Array.to_list (Sys.readdir dir) in
      List.fold_left (fun acc filename ->
        let path = Filename.concat dir filename in
        if Sys.is_directory path then search_dir path acc
        else if Filename.check_suffix filename ".md" then search_file path acc
        else acc
      ) acc files
    with Sys_error _ -> acc
  in
  (* Search disk files first *)
  let disk_results = search_dir !root_path [] in
  let disk_keys = List.map fst disk_results in
  (* De-duplicate by document identity: the same manual doc can be found on disk
     (an absolute path key) and in the embedded bundle (a repo-relative key like
     "manual/best-practices.md").  Skip the embedded copy when a disk file
     resolves to the same relative path (its absolute key ends with "/" ^ key),
     so the doc is not listed twice under two path forms. *)
  let is_on_disk k =
    List.exists
      (fun dk -> dk = k || String.ends_with ~suffix:(Filename.dir_sep ^ k) dk)
      disk_keys
  in
  let embedded_results =
    Embedded_docs.files
    |> List.filter (fun (k, _) -> not (is_on_disk k))
    |> List.fold_left (fun acc (k, content) -> search_content k content acc) []
  in
  disk_results @ embedded_results

let format_search_results results query =
  if results = [] then
    "No results found for \"" ^ query ^ "\"\n"
  else
    let buf = Buffer.create 1024 in
    Buffer.add_string buf ("Search results for \"" ^ query ^ "\":\n\n");
    List.iter (fun (file, lines) ->
      Buffer.add_string buf ("**" ^ file ^ "**:\n");
      List.iter (fun line ->
        (* Remove any newline characters and trim whitespace *)
        let line_content = 
          let cleaned = String.map (fun c -> if c = '\n' || c = '\r' then ' ' else c) line in
          String.trim cleaned
        in
        if line_content <> "" then
          Buffer.add_string buf ("  - " ^ line_content ^ "\n")
      ) lines;
      Buffer.add_string buf "\n"
    ) results;
    Buffer.contents buf

(* ── Help display ───────────────────────────────────────────────────────────── *)

let display_help () =
  print_string usage;
  exit 0

(* ── Anchor (slug) resolution within a manual section ─────────────────────────

   The manual is addressed as `<section>[#<anchor>]` (see manual/anchors.md).
   `<anchor>` is a GitHub-flavoured-Markdown heading slug. We resolve it the
   same way the anchor-contract test does, so a citation printed by a diagnostic
   (`tesl help manual best-practices#proof-management`) jumps to that heading. *)

(** Slug rule — single-sourced in {!Error_codes.slug_of_heading} (D16) so the
    diagnostic deep-links here and the anchor-contract test cannot drift. *)
let slug_of_heading = Error_codes.slug_of_heading

(* Is [line] a Markdown ATX heading?  Returns Some (level, text) if so. *)
let heading_of_line line =
  let l = String.trim line in
  if String.length l >= 2 && l.[0] = '#' then begin
    let i = ref 0 in
    while !i < String.length l && l.[!i] = '#' do incr i done;
    let level = !i in
    let text = String.sub l !i (String.length l - !i) |> String.trim in
    if text = "" then None else Some (level, text)
  end else None

(** Extract the sub-section of [content] whose heading slugs to [anchor]: the
    heading line plus everything up to (not including) the next heading at the
    same-or-shallower level.  Returns [None] if no heading matches. *)
let extract_anchor_section content anchor =
  let lines = Array.of_list (String.split_on_char '\n' content) in
  let n = Array.length lines in
  let rec find i =
    if i >= n then None
    else match heading_of_line lines.(i) with
      | Some (level, text) when slug_of_heading text = anchor -> Some (i, level)
      | _ -> find (i + 1)
  in
  match find 0 with
  | None -> None
  | Some (start, level) ->
    let buf = Buffer.create 1024 in
    let j = ref start in
    let stop = ref false in
    Buffer.add_string buf lines.(!j);
    Buffer.add_char buf '\n';
    incr j;
    while !j < n && not !stop do
      (match heading_of_line lines.(!j) with
       | Some (lvl, _) when lvl <= level -> stop := true
       | _ ->
         Buffer.add_string buf lines.(!j);
         Buffer.add_char buf '\n';
         incr j)
    done;
    Some (Buffer.contents buf)

(** Display a manual section, resolving an optional `#anchor` to just that
    sub-section.  `section_spec` may be "<section>" or "<section>#<anchor>".
    When an anchor is present but does not resolve, we print the whole section
    with a note so the citation still leads somewhere useful. *)
let display_manual section_spec =
  init_paths ();
  (* split off a trailing #anchor (only the FIRST '#'; slugs never contain '#') *)
  let section, anchor =
    match String.index_opt section_spec '#' with
    | Some i ->
      String.sub section_spec 0 i,
      Some (String.sub section_spec (i + 1) (String.length section_spec - i - 1))
    | None -> section_spec, None
  in
  match get_manual_content section with
  | Some content ->
    (match anchor with
     | None | Some "" -> print_string content; exit 0
     | Some a ->
       (match extract_anchor_section content a with
        | Some sub -> print_string sub; exit 0
        | None ->
          Printf.eprintf
            "note: no heading in section '%s' slugs to '#%s'; showing the whole section.\n\n"
            section a;
          print_string content; exit 0))
  | None ->
    Printf.eprintf "Error: Manual section '%s' not found.\n" section;
    Printf.eprintf "Available sections: getting-started, overview, tour, language-spec, examples, best-practices, ai-testing, deploy, tesl-manifest, faq, intro, anchors, dev\n";
    Printf.eprintf "Use 'tesl help' for command line usage; 'tesl help codes' for the diagnostic-code index.\n";
    exit 1

let display_examples () =
  match get_examples_list () with
  | Some content ->
    print_string content;
    exit 0
  | None ->
    Printf.eprintf "Error: Examples list not found.\n";
    exit 1

let display_full_manual () =
  match get_full_manual () with
  | content when content <> "" ->
    print_string content;
    exit 0
  | _ ->
    Printf.eprintf "Error: Could not load full manual.\n";
    exit 1

(* ── Diagnostic-code help (`tesl help <code>` / `tesl explain <code>`) ──────── *)

(** Does [s] look like a diagnostic code (E000, T001, V001, W010, VBOOL001, …)?
    Used to route `tesl help E000` to the code explainer rather than treating it
    as a manual section name.  Codes are letters+digits and always contain a
    digit; manual section names are lower-case-with-hyphens and contain no
    digits, so the shape alone disambiguates (no risk of shadowing a section).
    Case-insensitive on letters so `tesl help v001` works (the explainer
    upper-cases). Code-shaped-but-unknown input still routes here, so the user
    gets the helpful "unknown diagnostic code — run `tesl help codes`" message. *)
let looks_like_code s =
  let n = String.length s in
  n >= 2
  && (let c = Char.uppercase_ascii s.[0] in c >= 'A' && c <= 'Z')
  && String.exists (fun c -> c >= '0' && c <= '9') s
  && String.for_all
       (fun c -> let u = Char.uppercase_ascii c in
                 (u >= 'A' && u <= 'Z') || (c >= '0' && c <= '9')) s

(** Print the registry explanation for a code and exit.  The code is normalised
    to upper-case so `tesl help e000` works too. *)
let display_code_explanation raw =
  let code = String.uppercase_ascii raw in
  match Error_codes.explain code with
  | Some text -> print_string text; exit 0
  | None ->
    Printf.eprintf "Error: unknown diagnostic code '%s'.\n\n" raw;
    Printf.eprintf "Run `tesl help codes` for the list of all diagnostic codes.\n";
    exit 1

(** Print the full diagnostic-code index (`tesl help codes`). *)
let display_codes_index () =
  print_string (Error_codes.index ());
  exit 0

(* ── Help suggestions for error messages ───────────────────────────────────── *)

let get_help_suggestion message =
  let message_lower = String.lowercase_ascii message in
  let suggestions = [
    (* Validation-related errors *)
    ("proof", "For information about proofs and validation, see 'tesl help manual best-practices#proof-management'");
    ("validate", "For validation patterns, see 'tesl help manual best-practices#validation-patterns'");
    ("check", "For check functions, see 'tesl help manual best-practices#validation-patterns'");
    
    (* Type-related errors *)
    ("type", "For type system information, see 'tesl help manual overview#core-principles'");
    ("predicate", "For predicates and proofs, see 'tesl help manual overview#core-principles'");
    
    (* Route-related errors *)
    ("route", "For route definitions, see 'tesl help manual best-practices#api-design'");
    ("auth", "For authentication, see 'tesl help manual best-practices#api-design'");
    
    (* Database-related errors *)
    ("db", "For database operations, see 'tesl help manual best-practices#database-access'");
    ("query", "For database queries, see 'tesl help manual best-practices#database-access'");
    ("transaction", "For transactions, see 'tesl help manual best-practices#database-access'");
    
    (* General *)
    ("syntax", "For syntax help, see 'tesl help manual language-spec'");
    ("parse", "For parsing errors, see 'tesl help manual language-spec'");
  ] in
  
  let rec find_suggestion = function
    | [] -> None
    | (keyword, suggestion) :: rest ->
      if string_contains keyword message_lower then
        Some suggestion
      else
        find_suggestion rest
  in
  find_suggestion suggestions

let handle_help args =
  init_paths ();
  match args with
  | [] -> display_help ()
  | ("codes" | "code") :: [] -> display_codes_index ()
  (* `tesl help manual <section>[#anchor]` — anchor resolution lives in
     display_manual.  A single arg carries any `#anchor` verbatim. *)
  | "manual" :: [] -> display_manual ""
  | "manual" :: "full" :: [] -> display_full_manual ()
  | "manual" :: "codes" :: [] -> display_codes_index ()
  | "manual" :: sections when sections <> [] ->
    let section = String.concat "/" sections in
    display_manual section
  | "full" :: [] -> display_full_manual ()
  | "examples" :: [] -> display_examples ()
  | "search" :: query :: [] ->
    let results = search_docs query in
    print_string (format_search_results results query);
    exit 0
  (* `tesl help <CODE>` — explain a diagnostic code (e.g. `tesl help V001`). *)
  | [single] when looks_like_code single ->
    display_code_explanation single
  | _ ->
    Printf.eprintf "Error: Unknown help command.\n\n";
    display_help ()

(** LSP host indirection: the editor validates an unsaved buffer by writing its
    text to a transient copy (now in a system temp dir, so the buffer never
    touches the project tree) and invoking a query command on that copy.  But
    local imports resolve relative to [Filename.dirname source_file]
    ([Checker.resolve_local_import_path]), so a system-temp copy would no longer
    see its sibling modules.

    [TESL_LOGICAL_PATH] lets the host say "read the content from this real file,
    but treat it as if it lived at this logical path" — the editor sets it to the
    document's true on-disk path.  Content is still read from the [filename]
    argument; only the *path* the checker reasons about (import dir + the [file]
    field of locations) becomes the logical one.  Absent/empty ⇒ unchanged. *)
let logical_path filename =
  match Sys.getenv_opt "TESL_LOGICAL_PATH" with
  | Some p when p <> "" -> p
  | _ -> filename

let check_json_diags filename source =
  (* Import resolution + diagnostic [file] use the logical path; the linter
     still reads the real (temp) file's edited content from disk. *)
  let diags = Compile.check_source (logical_path filename) source in
  (* Don't lint an unparseable file: on a parser OR lexer error the linter's
     re-parse is meaningless (and used to crash the JSON entry points — the
     LSP-crash class).  Linter.lint_file now also swallows parse failures. *)
  if List.exists (fun (d : Compile.diagnostic) ->
        d.source = "parser" || d.source = "lexer") diags
  then diags
  else diags @ Linter.lint_file filename

(** Print a single diagnostic to stderr.

    Each diagnostic carries a stable [code] (documented in [Error_codes]). When
    the code maps to a manual section we print a "read more" deep-link that the
    reader can paste verbatim: `tesl help manual <section>#<anchor>`. We also
    point at `tesl help <code>` so the full explanation is one command away.

    The manual anchor is the one resolved upstream from the diagnostic's
    structured topic (carried on [d.manual] for validation errors), or, for other
    codes, the central registry's code→anchor mapping. If neither yields an
    anchor, we fall back to the older keyword-based suggestion so no diagnostic
    loses its existing hint. *)
let print_diagnostic (d : Compile.diagnostic) =
  let sev_col = match d.severity with
    | "error"   -> col "1;31"
    | "warning" -> col "1;33"
    | _         -> col "1;34"
  in
  Printf.eprintf "%s%s%s%s[%s]%s: %s\n"
    sev_col (col "1") d.severity (col "0")
    d.code (col "0") d.message;
  Printf.eprintf "  %s-->%s %s:%d:%d\n"
    (col "1;34") (col "0")
    d.file (d.start_line + 1) (d.start_col + 1);
  (* B5: prefer the STRUCTURED anchor resolved upstream from the diagnostic's
     topic (carried on [d.manual]); message text no longer routes the anchor.
     For non-validation codes [d.manual] is None and we resolve via the registry
     code→anchor mapping (1:1 for every such code). *)
  let manual_link =
    match d.manual with
    | Some _ as a -> a
    | None -> Error_codes.manual_for ~code:d.code ~message:d.message ()
  in
  (match manual_link with
   | Some anchor ->
     Printf.eprintf "  %s%s\n" (col "1;36") (col "0");
     Printf.eprintf "  read more: tesl help manual %s%s%s  (explain: tesl help %s)\n"
       (col "1;36") anchor (col "0") d.code
   | None ->
     (match get_help_suggestion d.message with
      | Some suggestion ->
        Printf.eprintf "  %s%s\n" (col "1;36") (col "0");
        Printf.eprintf "  hint: %s\n" suggestion
      | None ->
        (* Even with no manual section, surface the explain command if the code
           is documented in the registry. *)
        (match Error_codes.lookup d.code with
         | Some _ ->
           Printf.eprintf "  hint: run `tesl help %s` for an explanation\n" d.code
         | None -> ())))

(** WS4: print per-file results for a batch / whole-project check, then a
    one-line summary, and exit (1 if any file has an error diagnostic, else 0).
    Diagnostics go to stderr (as for `--check`); the summary goes to stdout so
    it is easy to capture separately. *)
let print_batch_results (results : (string * Compile.diagnostic list) list) =
  let file_has_error diags =
    List.exists (fun (d : Compile.diagnostic) -> d.severity = "error") diags
  in
  let total = List.length results in
  let failed = ref 0 in
  List.iter (fun (filename, diags) ->
    if diags <> [] then begin
      Printf.eprintf "%s%s%s\n" (col "1") filename (col "0");
      List.iter print_diagnostic diags
    end;
    if file_has_error diags then incr failed
  ) results;
  let passed = total - !failed in
  Printf.printf "%schecked %d file%s%s: %s%d passed%s"
    (col "1") total (if total = 1 then "" else "s") (col "0")
    (col "1;32") passed (col "0");
  if !failed > 0 then
    Printf.printf ", %s%d failed%s" (col "1;31") !failed (col "0");
  print_newline ();
  exit (if !failed > 0 then 1 else 0)

(* ── Root-path discovery ─────────────────────────────────────────────────── *)

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  let root_path = find_repo_root () in

  (* Outermost safety net (review LSP-crash class): convert ANY uncaught
     exception into a clean `error:`/exit-1 instead of the OCaml runtime's
     "Fatal error: exception …" + exit 2.  The editor/agent drive these entry
     points with in-progress buffers, so a lexer/parser `Failure` (or a stale
     partial-function guard) must never crash the process.  `exit` does not raise
     a catchable exception, so the explicit `exit` calls in each branch are
     unaffected. *)
  try (match args with
  (* Handle help commands first *)
  | "--help" :: rest -> handle_help rest
  | "help" :: rest -> handle_help rest
  | ["-h"] -> display_help ()
  (* `tesl explain <CODE>` — alias for `tesl help <CODE>`; show a diagnostic
     code's explanation + manual link. *)
  | "explain" :: [code] -> display_code_explanation code
  | ["explain"] | "explain" :: _ ->
    Printf.eprintf "Usage: tesl explain <CODE>   (e.g. tesl explain V001)\n";
    Printf.eprintf "Run `tesl help codes` for the list of all diagnostic codes.\n";
    exit 1
  | [] -> print_string usage; exit 1

  | ("--check" :: filenames) when filenames <> [] ->
    let all_diags = List.concat_map Compile.check_file filenames in
    List.iter print_diagnostic all_diags;
    exit (if all_diags = [] then 0 else 1)

  | ("--check-batch" :: filenames) when filenames <> [] ->
    (* WS4: batch check N explicit files in ONE process, sharing the imported-
       module parse cache across files, with a per-file pass/fail summary. *)
    let results = Compile.check_files_batch filenames in
    print_batch_results results

  | ["--check-all"; dir] ->
    (* WS4: recursively find and batch-check every .tesl file under [dir]. *)
    let results = Compile.check_all_in_dir dir in
    if results = [] then begin
      Printf.eprintf "%swarning%s: no .tesl files found under %s\n"
        (col "1;33") (col "0") dir;
      exit 0
    end;
    print_batch_results results

  | ["--check-json"; filename] ->
    (try
       let source = In_channel.with_open_text filename In_channel.input_all in
       let diags = check_json_diags filename source in
       print_string (Compile.diagnostics_to_json diags);
       print_newline ();
       (* 2026-07-03 ergonomics fix: exit non-zero IFF there is an error-severity
          diagnostic — matching the documented contract (AGENTS.md, usage: "exit
          code is non-zero iff there are error-severity diags") and `agent-context`
          below.  The old `diags <> []` test also failed on WARNING-only files, so
          a CI gate or editor keyed on the exit code saw ~40/92 shipped example
          files "fail" on nothing but lint warnings (e.g. unused-import). *)
       let has_error =
         List.exists (fun (d : Compile.diagnostic) -> d.severity = "error") diags in
       exit (if has_error then 1 else 0)
     with Sys_error msg ->
       Printf.eprintf "error: %s\n" msg; exit 1)

  | ["--agent-context-json"; filename]
  | ["agent-context"; filename] ->
    (* AC1: token-economical compiler/linter snapshot for an AI coding agent.
       Always emits a JSON snapshot; exit 0 iff there are no error-severity
       diagnostics ([ok]), 1 otherwise, mirroring --check-json's exit code so a
       wrapper can branch on the status without re-parsing. *)
    (try
       let source = In_channel.with_open_text filename In_channel.input_all in
       let lpath = logical_path filename in
       (* Include linter findings so agent-context reports the SAME diagnostic
          set as --check-json (review 2026-07 TOOL-AGENTCTX). *)
       let lint_diags = Linter.lint_file filename in
       let json = Compile.agent_context_source ~extra_diags:lint_diags lpath source in
       print_string json;
       print_newline ();
       let diags = Compile.check_source lpath source in
       let has_error = List.exists (fun (d : Compile.diagnostic) -> d.severity = "error") diags in
       exit (if has_error then 1 else 0)
     with Sys_error msg ->
       Printf.eprintf "error: %s\n" msg; exit 1)

  | ["--local-bindings-json"; filename] ->
    (try
       let source = In_channel.with_open_text filename In_channel.input_all in
       let bindings = Compile.local_bindings_source (logical_path filename) source in
       print_string (Compile.local_bindings_to_json bindings);
       print_newline ();
       exit 0
     with Sys_error msg ->
       Printf.eprintf "error: %s\n" msg; exit 1)

  | ["--definition-json"; filename; line; col] ->
    (try
       let source = In_channel.with_open_text filename In_channel.input_all in
       let definition = Compile.definition_source (logical_path filename) source (int_of_string line) (int_of_string col) in
       print_string (Compile.definition_response_to_json definition);
       print_newline ();
       exit 0
     with
     | Sys_error msg -> Printf.eprintf "error: %s\n" msg; exit 1
     | Failure msg -> Printf.eprintf "error: %s\n" msg; exit 1)

  | ["--occurrences-json"; filename; line; col] ->
    (try
       let source = In_channel.with_open_text filename In_channel.input_all in
       let occurrences = Compile.occurrences_source (logical_path filename) source (int_of_string line) (int_of_string col) in
       print_string (Compile.occurrences_response_to_json occurrences);
       print_newline ();
       exit 0
     with
     | Sys_error msg -> Printf.eprintf "error: %s\n" msg; exit 1
     | Failure msg -> Printf.eprintf "error: %s\n" msg; exit 1)

  | ["--type-at-json"; filename; line; col] ->
    (try
       let source = In_channel.with_open_text filename In_channel.input_all in
       let result = Compile.type_at_source (logical_path filename) source (int_of_string line) (int_of_string col) in
       print_string (Compile.type_at_response_to_json result);
       print_newline ();
       exit 0
     with
     | Sys_error msg -> Printf.eprintf "error: %s\n" msg; exit 1
     | Failure msg -> Printf.eprintf "error: %s\n" msg; exit 1)

  | ["--field-at-json"; filename; line; col] ->
    (try
       let source = In_channel.with_open_text filename In_channel.input_all in
       let result = Compile.field_at_source (logical_path filename) source (int_of_string line) (int_of_string col) in
       print_string (Compile.field_at_response_to_json result);
       print_newline ();
       exit 0
     with
     | Sys_error msg -> Printf.eprintf "error: %s\n" msg; exit 1
     | Failure msg -> Printf.eprintf "error: %s\n" msg; exit 1)

  | ["--config-context-json"; filename; line; col] ->
    (try
       let source = In_channel.with_open_text filename In_channel.input_all in
       let result = Compile.config_context_source (logical_path filename) source (int_of_string line) (int_of_string col) in
       print_string (Compile.config_context_response_to_json result);
       print_newline ();
       exit 0
     with
     | Sys_error msg -> Printf.eprintf "error: %s\n" msg; exit 1
     | Failure msg -> Printf.eprintf "error: %s\n" msg; exit 1)

  | ["--completions-json"; filename; line; col] ->
    (try
       let source = In_channel.with_open_text filename In_channel.input_all in
       let items = Compile.completions_source (logical_path filename) source (int_of_string line) (int_of_string col) in
       print_string (Compile.completions_response_to_json items);
       print_newline ();
       exit 0
     with
     | Sys_error msg -> Printf.eprintf "error: %s\n" msg; exit 1
     | Failure msg -> Printf.eprintf "error: %s\n" msg; exit 1)

  | ["--signature-help-json"; filename; line; col] ->
    (try
       let source = In_channel.with_open_text filename In_channel.input_all in
       let sig_ = Compile.signature_help_source (logical_path filename) source (int_of_string line) (int_of_string col) in
       print_string (Compile.signature_help_response_to_json sig_);
       print_newline ();
       exit 0
     with
     | Sys_error msg -> Printf.eprintf "error: %s\n" msg; exit 1
     | Failure msg -> Printf.eprintf "error: %s\n" msg; exit 1)

  | ["--selection-range-json"; filename; line; col] ->
    (try
       let source = In_channel.with_open_text filename In_channel.input_all in
       let ranges = Compile.selection_range_source (logical_path filename) source (int_of_string line) (int_of_string col) in
       print_string (Compile.selection_ranges_response_to_json ranges);
       print_newline ();
       exit 0
     with
     | Sys_error msg -> Printf.eprintf "error: %s\n" msg; exit 1
     | Failure msg -> Printf.eprintf "error: %s\n" msg; exit 1)

  | ["--type-definition-json"; filename; line; col] ->
    (try
       let source = In_channel.with_open_text filename In_channel.input_all in
       let loc = Compile.type_definition_source (logical_path filename) source (int_of_string line) (int_of_string col) in
       print_string (Compile.type_definition_response_to_json loc);
       print_newline ();
       exit 0
     with
     | Sys_error msg -> Printf.eprintf "error: %s\n" msg; exit 1
     | Failure msg -> Printf.eprintf "error: %s\n" msg; exit 1)

  | ("--fmt" :: filenames) when filenames <> [] ->
    let ret = ref 0 in
    List.iter (fun filename ->
      match Formatter.format_file filename with
      | Ok ()  -> ()
      | Error msg -> Printf.eprintf "%s: %s\n" filename msg; ret := 1
    ) filenames;
    exit !ret

  | ("--fmt-check" :: filenames) when filenames <> [] ->
    let ret = ref 0 in
    List.iter (fun filename ->
      match Formatter.format_check filename with
      | Ok true  -> ()
      | Ok false ->
        Printf.eprintf "%s: not formatted (run `tesl fmt %s` to fix)\n" filename filename;
        ret := 1
      | Error msg -> Printf.eprintf "%s: %s\n" filename msg; ret := 1
    ) filenames;
    exit !ret

  | ("--lint" :: filenames) when filenames <> [] ->
    let all_diags = List.concat_map Linter.lint_file filenames in
    List.iter print_diagnostic all_diags;
    let has_errors = List.exists (fun (d : Compile.diagnostic) ->
      d.severity = "error") all_diags in
    exit (if has_errors then 1 else 0)

  | ["--deps"; filename] ->
    (* Print all transitively imported local .tesl files, one per line.
       Used by `tesl watch` to build the dependency set to monitor. *)
    let rec collect_deps visited file =
      if List.mem file visited then visited
      else
        let visited = file :: visited in
        (try
           let source = In_channel.with_open_text file In_channel.input_all in
           match Parser.parse_module file source with
           | Err _ -> visited
           | Ok m ->
             List.fold_left (fun vis (imp : Ast.import_decl) ->
               let path = Checker.resolve_local_import_path file imp.module_name in
               if Sys.file_exists path then collect_deps vis path
               else vis
             ) visited m.imports
         with Sys_error _ -> visited)
    in
    let all_deps = collect_deps [] filename in
    List.iter (fun f -> if f <> filename then print_endline f) all_deps;
    exit 0

  | ["--ir"; filename] ->
    (try
       let source = In_channel.with_open_text filename In_channel.input_all in
       match Parser.parse_module filename source with
       | Ok m ->
         print_string (Ir.module_to_json ~source_name:(Filename.basename filename) m);
         print_newline ();
         exit 0
       | Err e ->
         Printf.eprintf "%s:%d:%d: error: %s\n"
           e.loc.file (e.loc.start.line + 1) (e.loc.start.col + 1) e.msg;
         exit 1
     with Sys_error msg ->
       Printf.eprintf "error: %s\n" msg; exit 1)

  | ("--generate-ts" :: filename :: rest) ->
    let out_file = match rest with ["--out"; f] -> Some f | _ -> None in
    (try
       (* B1 / review §8.2: gate the client generator behind the FULL checker
          (type + proof + validation), so a program that fails `--check` cannot
          still emit a plausible client (the checker-bypass hole). *)
       (match Compile.compile_file ~root_path ~type_check:true filename with
        | Compile.Failure diags -> List.iter print_diagnostic diags; exit 1
        | Compile.Success _ -> ());
       let source = In_channel.with_open_text filename In_channel.input_all in
       match Parser.parse_module filename source with
       | Ok m ->
         let output = Emit_ts.emit_ts m in
         (match out_file with
          | None -> print_string output
          | Some f ->
            let oc = Out_channel.open_text f in
            Out_channel.output_string oc output;
            Out_channel.close oc);
         exit 0
       | Err e ->
         Printf.eprintf "%s:%d:%d: error: %s\n"
           e.loc.file (e.loc.start.line + 1) (e.loc.start.col + 1) e.msg;
         exit 1
     with Sys_error msg ->
       Printf.eprintf "error: %s\n" msg; exit 1)

  | ("--generate-elm" :: filename :: rest) ->
    let out_file = match rest with ["--out"; f] -> Some f | _ -> None in
    (try
       (* B1 / review §8.2: gate the client generator behind the FULL checker. *)
       (match Compile.compile_file ~root_path ~type_check:true filename with
        | Compile.Failure diags -> List.iter print_diagnostic diags; exit 1
        | Compile.Success _ -> ());
       let source = In_channel.with_open_text filename In_channel.input_all in
       match Parser.parse_module filename source with
       | Ok m ->
         let inferred_module_name =
           match out_file with
           | None -> None
           | Some f ->
             let normalized = String.map (fun c -> if c = '\\' then '/' else c) f in
             let parts = List.filter (fun s -> s <> "") (String.split_on_char '/' normalized) in
             let rec after_src = function
               | [] -> None
               | "src" :: rest -> Some rest
               | _ :: rest -> after_src rest
             in
             let strip_elm name =
               let suffix = ".elm" in
               let len = String.length name in
               let suffix_len = String.length suffix in
               if len > suffix_len && String.sub name (len - suffix_len) suffix_len = suffix then
                 String.sub name 0 (len - suffix_len)
               else
                 name
             in
             (match after_src parts with
              | Some module_parts when module_parts <> [] -> Some (String.concat "." (List.map strip_elm module_parts))
              | _ -> None)
         in
         let output = Emit_elm.emit_elm ?module_name_override:inferred_module_name m in
         (match out_file with
          | None -> print_string output
          | Some f ->
            let oc = Out_channel.open_text f in
            Out_channel.output_string oc output;
            Out_channel.close oc);
         exit 0
       | Err e ->
         Printf.eprintf "%s:%d:%d: error: %s\n"
           e.loc.file (e.loc.start.line + 1) (e.loc.start.col + 1) e.msg;
         exit 1
     with Sys_error msg ->
       Printf.eprintf "error: %s\n" msg; exit 1)

  | ["--semantic-json"; filename] ->
    (try
       match Compile.semantic_json_file filename with
       | Some json -> print_string json; print_newline (); exit 0
       | None ->
         Printf.eprintf "error: could not parse %s\n" filename; exit 1
     with Sys_error msg ->
       Printf.eprintf "error: %s\n" msg; exit 1)

  | ["--debug"; filename] ->
    (try
       Emit_racket.set_debug_mode true;
       match Compile.compile_file ~root_path ~type_check:true filename with
       | Compile.Success racket -> print_string racket
       | Compile.Failure diags ->
         List.iter print_diagnostic diags;
         exit 1
     with
     | Failure msg -> Printf.eprintf "%serror%s: %s\n" (col "1;31") (col "0") msg; exit 1
     | Sys_error msg -> Printf.eprintf "%serror%s: %s\n" (col "1;31") (col "0") msg; exit 1)

  | ["--test-name"; test_name; filename] ->
    (try
       Emit_racket.set_test_name_filter (Some test_name);
       match Compile.compile_file ~root_path ~type_check:true filename with
       | Compile.Success racket -> print_string racket
       | Compile.Failure diags ->
         List.iter print_diagnostic diags;
         exit 1
     with
     | Failure msg -> Printf.eprintf "%serror%s: %s\n" (col "1;31") (col "0") msg; exit 1
     | Sys_error msg -> Printf.eprintf "%serror%s: %s\n" (col "1;31") (col "0") msg; exit 1)

  (* `--test-kind KIND` (test|api-test|load-test|doctest) pins single-test selection to
     one kind, so a named api-test/load-test can be run in isolation. *)
  | ["--test-name"; test_name; "--test-kind"; test_kind; filename] ->
    (try
       Emit_racket.set_test_name_filter (Some test_name);
       Emit_racket.set_test_kind_filter (Some test_kind);
       match Compile.compile_file ~root_path ~type_check:true filename with
       | Compile.Success racket -> print_string racket
       | Compile.Failure diags ->
         List.iter print_diagnostic diags;
         exit 1
     with
     | Failure msg -> Printf.eprintf "%serror%s: %s\n" (col "1;31") (col "0") msg; exit 1
     | Sys_error msg -> Printf.eprintf "%serror%s: %s\n" (col "1;31") (col "0") msg; exit 1)

  | ["--debug"; "--test-name"; test_name; filename] ->
    (try
       Emit_racket.set_debug_mode true;
       Emit_racket.set_test_name_filter (Some test_name);
       match Compile.compile_file ~root_path ~type_check:true filename with
       | Compile.Success racket -> print_string racket
       | Compile.Failure diags ->
         List.iter print_diagnostic diags;
         exit 1
     with
     | Failure msg -> Printf.eprintf "%serror%s: %s\n" (col "1;31") (col "0") msg; exit 1
     | Sys_error msg -> Printf.eprintf "%serror%s: %s\n" (col "1;31") (col "0") msg; exit 1)

  | ["--debug"; "--test-name"; test_name; "--test-kind"; test_kind; filename] ->
    (try
       Emit_racket.set_debug_mode true;
       Emit_racket.set_test_name_filter (Some test_name);
       Emit_racket.set_test_kind_filter (Some test_kind);
       match Compile.compile_file ~root_path ~type_check:true filename with
       | Compile.Success racket -> print_string racket
       | Compile.Failure diags ->
         List.iter print_diagnostic diags;
         exit 1
     with
     | Failure msg -> Printf.eprintf "%serror%s: %s\n" (col "1;31") (col "0") msg; exit 1
     | Sys_error msg -> Printf.eprintf "%serror%s: %s\n" (col "1;31") (col "0") msg; exit 1)

  (* AC2: headless breakpoint inspector — agent-set breakpoints, full control.
       tesl debug-inspect <file.tesl> --break-at SPEC [--break-at SPEC ...]
                          [--when EXPR] [--hit SPEC] [--mode program|test]
     Compiles the .tesl with debug instrumentation, registers ALL requested
     breakpoints, runs to whichever fires FIRST (with stop-the-world active), and
     emits the paused runtime state (locals + live domain registry + SQL capture)
     plus the breakpoint that stopped it as ONE JSON object on stdout.

     --break-at SPEC, where SPEC is one of:
        LINE                bare, unconditional            e.g. 42
        LINE:COL            column accepted and ignored    e.g. 42:7
        LINE: <expr>        conditional (boolean over locals)  e.g. "42: n == 100"
        LINE: <hit>         hit-count (==|>=|<=|>|<|% N)   e.g. "42: %3"
        L1,L2,L3            comma-separated bare lines     e.g. 10,22,40
     --break-at is repeatable; all breakpoints are registered.
     --when EXPR  default boolean condition for breakpoints with no inline one.
     --hit  SPEC  default hit-condition for breakpoints with no inline one.
     A bad condition FAILS OPEN (treated as true) so a typo never silently drops a
     breakpoint — same semantics as the DAP conditional breakpoints. *)
  | "debug-inspect" :: filename :: rest
    when not (String.length filename > 2 && filename.[0] = '-') ->
    let inspect_usage () =
      Printf.eprintf "usage: tesl debug-inspect <file.tesl> --break-at SPEC [--break-at SPEC ...] [--when EXPR] [--hit SPEC] [--mode program|test] [--continue]\n";
      Printf.eprintf "  SPEC := LINE | LINE:COL | \"LINE: <cond-expr>\" | \"LINE: <hit-spec>\" | L1,L2,L3\n";
      Printf.eprintf "  --continue : stop at each breakpoint in turn, resume after each, and let the program finish (headless F5); emits {snapshots:[...],completed}\n"
    in
    (* A single --break-at spec may carry several comma-separated bare lines OR one
       conditional/hit breakpoint.  We classify the text after the first ':' the
       SAME way the Racket driver's parse-bp-spec does:
         - a bare integer after ':'         → a COLUMN (legacy), ignored
         - an operator+int (==|>=|<=|>|<|%) → a hit-condition
         - anything else                    → a boolean condition expression.
       Comma-splitting only applies to a spec with NO ':' (a pure line list); a
       spec containing ':' is treated as ONE breakpoint so commas inside an
       expression are never mis-split. *)
    let is_hit_spec s =                       (* (==|>=|<=|>|<|%) <digits> *)
      let s = String.trim s in
      let n = String.length s in
      if n = 0 then false
      else
        let op_len =
          if n >= 2 && (let p = String.sub s 0 2 in p="=="||p=">="||p="<=") then 2
          else if (s.[0]='>'||s.[0]='<'||s.[0]='%') then 1
          else 0
        in
        op_len > 0 &&
        (let rest = String.trim (String.sub s op_len (n - op_len)) in
         String.length rest > 0 &&
         String.for_all (fun c -> c >= '0' && c <= '9') rest)
    in
    let is_all_digits s =
      let s = String.trim s in
      String.length s > 0 && String.for_all (fun c -> c >= '0' && c <= '9') s
    in
    (* Parse one chunk "LINE[: rest]" into (line, condition opt, hit opt). *)
    let parse_chunk chunk : (int * string option * string option) option =
      match String.index_opt chunk ':' with
      | None ->
        (match int_of_string_opt (String.trim chunk) with
         | Some l when l > 0 -> Some (l, None, None)
         | _ -> None)
      | Some i ->
        let line_str = String.trim (String.sub chunk 0 i) in
        let rest = String.trim (String.sub chunk (i+1) (String.length chunk - i - 1)) in
        (match int_of_string_opt line_str with
         | Some l when l > 0 ->
           if rest = "" || is_all_digits rest then Some (l, None, None)   (* COL ignored *)
           else if is_hit_spec rest then Some (l, None, Some rest)
           else Some (l, Some rest, None)
         | _ -> None)
    in
    let parse_break_at spec : (int * string option * string option) list =
      if String.contains spec ':' then
        (match parse_chunk spec with Some bp -> [bp] | None -> [])
      else
        String.split_on_char ',' spec
        |> List.filter_map (fun part ->
             let part = String.trim part in
             if part = "" then None else parse_chunk part)
    in
    let continue_mode = ref false in
    let rec parse_opts bps when_opt hit_opt mode = function
      | [] -> (List.rev bps, when_opt, hit_opt, mode)
      | "--break-at" :: spec :: tl ->
        let parsed = parse_break_at spec in
        if parsed = [] then begin
          Printf.eprintf "%serror%s: --break-at expects LINE[:COL]/LINE:<cond>/LINE:<hit>/L1,L2, got %s\n"
            (col "1;31") (col "0") spec;
          inspect_usage (); exit 2
        end;
        parse_opts (List.rev_append parsed bps) when_opt hit_opt mode tl
      | "--when" :: w :: tl -> parse_opts bps (Some w) hit_opt mode tl
      | "--hit"  :: h :: tl -> parse_opts bps when_opt (Some h) mode tl
      | "--mode" :: m :: tl -> parse_opts bps when_opt hit_opt (Some m) tl
      (* Headless F5: stop at each breakpoint in turn, resume after each, and let
         the program finish — instead of one-shot (issue #16). *)
      | ("--continue" | "--step-through") :: tl -> continue_mode := true; parse_opts bps when_opt hit_opt mode tl
      | other :: _ ->
        Printf.eprintf "%serror%s: unexpected argument to debug-inspect: %s\n"
          (col "1;31") (col "0") other;
        inspect_usage (); exit 2
    in
    let (bps, when_opt, hit_opt, mode_opt) = parse_opts [] None None None rest in
    if bps = [] then begin
      Printf.eprintf "%serror%s: debug-inspect requires at least one --break-at SPEC\n"
        (col "1;31") (col "0");
      inspect_usage (); exit 2
    end;
    (* Apply the global --when / --hit defaults to any breakpoint that has no
       inline condition / hit-condition. *)
    let breakpoints =
      List.map (fun (line, c, h) ->
        (line,
         (match c with Some _ -> c | None -> when_opt),
         (match h with Some _ -> h | None -> hit_opt)))
        bps
    in
    let mode = match mode_opt with
      | Some ("program" | "test" as m) -> m
      | None -> "program"
      | Some bad ->
        Printf.eprintf "%serror%s: --mode must be program or test, got %s\n"
          (col "1;31") (col "0") bad;
        exit 2
    in
    (match Compile.debug_inspect ~root_path ~continue_mode:!continue_mode ~breakpoints ~mode filename with
     | Compile.InspectDiags diags -> List.iter print_diagnostic diags; exit 1
     | Compile.InspectErr msg ->
       Printf.eprintf "%serror%s: %s\n" (col "1;31") (col "0") msg; exit 1)

  | [filename] when not (String.length filename > 2 && filename.[0] = '-') ->
    (try
       match Compile.compile_file ~root_path ~type_check:true filename with
       | Compile.Success racket -> print_string racket
       | Compile.Failure diags ->
         List.iter print_diagnostic diags;
         exit 1
     with
     | Failure msg -> Printf.eprintf "%serror%s: %s\n" (col "1;31") (col "0") msg; exit 1
     | Sys_error msg -> Printf.eprintf "%serror%s: %s\n" (col "1;31") (col "0") msg; exit 1)

  | "--exe" :: filename :: rest
    when not (String.length filename > 2 && filename.[0] = '-')
         && (rest = [] || (match rest with ["--out"; _] -> true | _ -> false)) ->
    (* WS6: build a standalone executable via `raco exe`.  Emits byte-identical
       Racket (same as `tesl <file>`) next to the source, then bundles it. *)
    let out = match rest with ["--out"; f] -> Some f | _ -> None in
    (match Compile.build_exe ~root_path ?out filename with
     | Compile.BuildOk exe_path ->
       Printf.eprintf "%sbuilt%s %s\n" (col "1;32") (col "0") exe_path; exit 0
     | Compile.BuildDiags diags ->
       List.iter print_diagnostic diags; exit 1
     | Compile.BuildErr msg ->
       Printf.eprintf "%serror%s: %s\n" (col "1;31") (col "0") msg; exit 1)

  | "--mutate" :: filename :: rest when rest = [] || List.for_all (fun s -> not (String.length s > 2 && s.[0] = '-' && s.[1] = '-')) rest ->
    let extra_test_files = rest in
    (match Compile.mutate_file ~root_path ~extra_test_files filename with
     | Compile.MutateErr msg ->
       Printf.eprintf "%serror%s: %s\n" (col "1;31") (col "0") msg;
       exit 1
     | Compile.MutateOk report ->
       let total    = report.Mutate.total in
       let killed   = report.Mutate.killed in
       let survived = report.Mutate.survived in
       let invalid  = report.Mutate.invalid in
       let errors   = report.Mutate.errors in
       let no_tests = List.length
           (List.filter (fun (_, r) -> r = Mutate.NoTests) report.Mutate.results) in
       let label = match extra_test_files with
         | [] -> filename
         | _ -> filename ^ " (with tests from: " ^ String.concat ", " extra_test_files ^ ")"
       in
       Printf.printf "%sMutation testing%s: %s\n\n" (col "1") (col "0") label;
       List.iter (fun ((mut : Mutate.mutant), result) ->
         let marker, colour = match result with
           | Mutate.Killed    -> "KILLED",   "1;32"
           | Mutate.Survived  -> "SURVIVED", "1;31"
           | Mutate.NoTests   -> "NO TESTS", "1;33"
           | Mutate.Invalid _ -> "INVALID",  "1;33"
           | Mutate.Error _   -> "ERROR",    "1;33"
         in
         Printf.printf "  [%s%s%s] %s\n"
           (col colour) marker (col "0") mut.description
       ) report.Mutate.results;
       Printf.printf "\n%sSummary%s: %d mutants | %s%d killed%s | %s%d survived%s"
         (col "1") (col "0")
         total
         (col "1;32") killed   (col "0")
         (if survived > 0 then col "1;31" else col "0")
         survived (col "0");
       if invalid > 0 then
         (* Compile/expand failures: not counted toward the kill rate. *)
         Printf.printf " | %s%d invalid%s" (col "1;33") invalid (col "0");
       if errors > 0 then
         Printf.printf " | %s%d error%s" (col "1;33") errors (col "0");
       if no_tests > 0 then
         Printf.printf " | %s%d no-tests%s" (col "1;33") no_tests (col "0");
       (* Kill rate reflects ONLY mutants whose tests actually ran and could
          distinguish behaviour: killed / (killed + survived).  Mutants that
          failed to compile (INVALID), timed out / could not be emitted (ERROR),
          or have no test block (NO TESTS) prove nothing and are excluded from
          the denominator, so a compile-error mutant can never inflate the
          score. *)
       let scored = killed + survived in
       (* Review 2026-07 (VER-MUT): a file with ZERO scorable mutants (all
          Invalid/Error/NoTests) proves nothing about test strength — reporting
          "100%" for it read as "perfectly tested" when coverage was actually
          nil.  Report "n/a" for the no-coverage case instead of a misleading
          perfect score.  (Exit is unchanged: survived = 0 here.) *)
       if scored = 0 then
         Printf.printf "\n%sMutation score%s: n/a %s(0 scorable mutants — no effective coverage)%s\n"
           (col "1") (col "0") (col "2") (col "0")
       else begin
         let score = float_of_int killed /. float_of_int scored *. 100.0 in
         Printf.printf "\n%sMutation score%s: %.0f%%" (col "1") (col "0") score;
         Printf.printf " %s(%d killed / %d scored)%s\n" (col "2") killed scored (col "0")
       end;
       if survived > 0 then exit 1)

  | _ -> print_string usage; exit 1)
  with
  | Sys_error msg -> Printf.eprintf "error: %s\n" msg; exit 1
  | Failure msg   -> Printf.eprintf "error: %s\n" msg; exit 1
  | e             -> Printf.eprintf "error: %s\n" (Printexc.to_string e); exit 1
