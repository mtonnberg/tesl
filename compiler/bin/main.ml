(** Tesl compiler CLI.

    Usage:
      tesl <file>                compile .tesl file to Racket (stdout)
      tesl --check <file> ...    check for parse + type errors (exit 1 if any)
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
  tesl --check-json <file>     check, emit diagnostics as IR-2 JSON
  tesl --local-bindings-json <file> emit inferred local binding types as JSON
  tesl --definition-json <file> <line> <col> emit definition location as JSON
  tesl --occurrences-json <file> <line> <col> emit same-file occurrences as JSON
  tesl --type-at-json <file> <line> <col> emit expression type at cursor as JSON
  tesl --field-at-json <file> <line> <col> emit record field info at cursor as JSON
  tesl --completions-json <file> <line> <col> emit completions at cursor as JSON
  tesl --fmt <file>            format source file in place
  tesl --fmt-check <file>      check formatting without modifying
  tesl --lint <file> [...]     run the opinionated linter
  tesl --ir <file>             emit API IR JSON
  tesl --deps <file>           list all transitively imported local .tesl files (one per line)
  tesl --semantic-json <file>  emit full module semantic snapshot as JSON (IR-1 foundation)
  tesl --mutate <file> [test-file ...]  run mutation testing; optionally merge tests from extra files

Help:
  tesl help                    show this help message
  tesl help manual             show the complete manual index
  tesl help manual <section>   show a specific manual section (overview, language-spec, examples, best-practices, faq)
  tesl help manual full        show all documentation concatenated (for LLMs with large context windows)
  tesl help full               same as 'tesl help manual full'
  tesl help examples           show the list of all examples
  tesl help search <query>     search across all documentation for a query
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

let find_doc_root () =
  let bin_dir = Filename.dirname (Sys.argv.(0)) in
  
  (* First, check if we're in an installed location (share/tesl/doc) *)
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
    root_path := Filename.dirname (Filename.dirname doc_path);  (* Remove /share/tesl/doc *)
    manual_dir := doc_path
  | None ->
    let rp = find_repo_root () in
    root_path := rp;
    manual_dir := Filename.concat rp "manual"

(* ── Manual content ────────────────────────────────────────────────────────── *)

let get_manual_content section =
  init_paths ();
  (* Build the mapping with full paths *)
  let get_path name = 
    (* Handle special aliases first *)
    match name with
    | "" | "manual" -> Filename.concat !manual_dir "MANUAL.md"
    | "getting-started" | "get-started" | "start" -> Filename.concat !manual_dir "GETTING-STARTED.md"
    | "overview" | "tutorial" -> Filename.concat !manual_dir "overview.md"
    | "language-spec" -> Filename.concat !manual_dir "LANGUAGE-SPEC.md"
    | "examples" -> Filename.concat !manual_dir "examples.md"
    | "best-practices" -> Filename.concat !manual_dir "best-practices.md"
    | "dev" -> Filename.concat !manual_dir "dev-docs/README.md"
    | "faq" -> Filename.concat !manual_dir "FAQ.md"
    | _ -> 
      (* Handle paths with slashes - try multiple locations *)
      let try_path path = if Sys.file_exists path then Some path else None in
      let try_paths paths =
        List.fold_left (fun acc path -> match acc with Some _ -> acc | None -> try_path path) None paths
      in
      
      (* Try various possible locations in order *)
      (* First, try in the installed doc/example directory *)
      let doc_example_path = Filename.concat !manual_dir "example" in
      (* Helper function to remove "examples/" or "example/" prefix *)
      let remove_example_prefix name =
        if String.starts_with ~prefix:"examples/" name then
          String.sub name 9 (String.length name - 9)
        else if String.starts_with ~prefix:"example/" name then
          String.sub name 8 (String.length name - 8)
        else
          name
      in
      let example_name = remove_example_prefix name in
      let possible_paths = [
        (* In manual_dir with .md *)
        Filename.concat !manual_dir (name ^ ".md");
        (* In manual_dir without extension *)
        Filename.concat !manual_dir name;
        (* In manual_dir/example/ with .tesl *)
        Filename.concat doc_example_path (example_name ^ ".tesl");
        (* In manual_dir/example/ with .md *)
        Filename.concat doc_example_path (example_name ^ ".md");
        (* In manual_dir/example/ without extension *)
        Filename.concat doc_example_path example_name;
        (* In root_path with .md *)
        Filename.concat !root_path (name ^ ".md");
        (* In root_path with .tesl *)
        Filename.concat !root_path (name ^ ".tesl");
        (* In root_path/example/ with .tesl *)
        Filename.concat !root_path ("example/" ^ name ^ ".tesl");
        (* In root_path/example/ without extension *)
        Filename.concat !root_path ("example/" ^ name);
      ] in
      
      match try_paths possible_paths with
      | Some p -> p
      | None -> Filename.concat !manual_dir (name ^ ".md")
  in
  
  (* Special case: empty section or "manual" should show MANUAL.md *)
  if section = "" || section = "manual" then
    read_file (Filename.concat !manual_dir "MANUAL.md")
  else
    let path = get_path section in
    if Sys.file_exists path then
      read_file path
    else
      None

let get_examples_list () =
  init_paths ();
  read_file (Filename.concat !manual_dir "examples.md")

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
  (* List of all documentation files to include in full manual *)
  let doc_files = [
    Filename.concat !manual_dir "MANUAL.md";
    Filename.concat !manual_dir "GETTING-STARTED.md";
    Filename.concat !manual_dir "overview.md";
    Filename.concat !manual_dir "examples.md";
    Filename.concat !manual_dir "best-practices.md";
    Filename.concat !manual_dir "FAQ.md";
    Filename.concat !manual_dir "LANGUAGE-SPEC.md";
    Filename.concat !manual_dir "TESL.md";
    Filename.concat !manual_dir "INSTALL.md";
    Filename.concat !manual_dir "README.md";
  ] in
  
  (* Also include dev-docs *)
  let dev_docs = [
    Filename.concat !manual_dir "dev-docs/README.md";
    Filename.concat !manual_dir "dev-docs/01-overview.md";
    Filename.concat !manual_dir "dev-docs/02-parser.md";
    Filename.concat !manual_dir "dev-docs/03-module-system.md";
    Filename.concat !manual_dir "dev-docs/04-body-compiler.md";
    Filename.concat !manual_dir "dev-docs/05-adding-stdlib-function.md";
    Filename.concat !manual_dir "dev-docs/06-gdp-runtime.md";
    Filename.concat !manual_dir "dev-docs/07-sql-layer.md";
    Filename.concat !manual_dir "dev-docs/08-queue-pubsub.md";
    Filename.concat !manual_dir "dev-docs/09-adding-tests.md";
    Filename.concat !manual_dir "dev-docs/10-common-patterns.md";
    Filename.concat !manual_dir "dev-docs/11-frontend-ir.md";
  ] in
  
  (* Include example markdown files *)
  let example_dir = Filename.concat !manual_dir "example" in
  let example_md_files = 
    if Sys.file_exists example_dir then
      collect_md_files example_dir []
    else
      (* Also try the repo-level example directory *)
      let repo_example_dir = Filename.concat !root_path "example" in
      if Sys.file_exists repo_example_dir then
        collect_md_files repo_example_dir []
      else
        []
  in
  
  let all_files = doc_files @ dev_docs @ example_md_files in
  
  let rec collect_content = function
    | [] -> []
    | file :: rest ->
      match read_file file with
      | Some content -> (file, content) :: collect_content rest
      | None -> collect_content rest
  in
  
  let file_contents = collect_content all_files in
  
  (* Format as: === [FILE_PATH] === CONTENTS *)
  let buf = Buffer.create 102400 in
  Buffer.add_string buf "TESL FULL MANUAL FOR LLMS\n";
  Buffer.add_string buf "=====================================\n";
  Buffer.add_string buf "(This is a concatenated, non-human-readable format for LLM context windows)\n\n";
  
  List.iter (fun (file, content) ->
    Buffer.add_string buf ("\n=== [" ^ file ^ "] ===\n");
    Buffer.add_string buf content;
    Buffer.add_string buf "\n";
  ) file_contents;
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
  let search_file file acc =
    match read_file file with
    | None -> acc
    | Some content ->
      let lines = String.split_on_char '\n' content in
      let matching_lines = List.filter (fun line -> 
        let line_lower = String.lowercase_ascii line in
        string_contains query_lower line_lower
      ) lines in
      if matching_lines <> [] then
        (file, matching_lines) :: acc
      else
        acc
  in
  let rec search_dir dir acc =
    try
      let files = Array.to_list (Sys.readdir dir) in
      List.fold_left (fun acc filename ->
        let path = Filename.concat dir filename in
        if Sys.is_directory path then
          search_dir path acc
        else if Filename.check_suffix filename ".md" then
          search_file path acc
        else
          acc
      ) acc files
    with Sys_error _ -> acc
  in
  let results = search_dir !root_path [] in
  results

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

let display_manual section =
  init_paths ();
  match get_manual_content section with
  | Some content ->
    print_string content;
    exit 0
  | None ->
    Printf.eprintf "Error: Manual section '%s' not found.\n" section;
    Printf.eprintf "Available sections: manual (index), manual/overview, manual/language-spec, manual/examples, manual/best-practices\n";
    Printf.eprintf "Use 'tesl help' for command line usage.\n";
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
  | "manual" :: [] -> display_manual ""
  | "manual" :: "full" :: [] -> display_full_manual ()
  | "manual" :: sections when sections <> [] ->
    let section = String.concat "/" sections in
    display_manual section
  | "full" :: [] -> display_full_manual ()
  | "examples" :: [] -> display_examples ()
  | "search" :: query :: [] ->
    let results = search_docs query in
    print_string (format_search_results results query);
    exit 0
  | _ ->
    Printf.eprintf "Error: Unknown help command.\n\n";
    display_help ()

let check_json_diags filename source =
  let diags = Compile.check_source filename source in
  if List.exists (fun (d : Compile.diagnostic) -> d.source = "parser") diags then diags
  else diags @ Linter.lint_file filename

(** Print a single diagnostic to stderr. *)
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
  (* Add help suggestion if available *)
  match get_help_suggestion d.message with
  | Some suggestion ->
    Printf.eprintf "  %s%s\n" (col "1;36") (col "0");
    Printf.eprintf "  hint: %s\n" suggestion
  | None -> ()

(* ── Root-path discovery ─────────────────────────────────────────────────── *)

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  let root_path =
    match Sys.getenv_opt "TESL_REPO_ROOT" with
    | Some p when p <> "" -> p
    | _ ->
    match Sys.getenv_opt "TESL_ROOT" with
    | Some p when p <> "" -> p
    | _ ->
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
  in

  match args with
  (* Handle help commands first *)
  | "--help" :: rest -> handle_help rest
  | "help" :: rest -> handle_help rest
  | ["-h"] -> display_help ()
  | [] -> print_string usage; exit 1

  | ("--check" :: filenames) when filenames <> [] ->
    let all_diags = List.concat_map Compile.check_file filenames in
    List.iter print_diagnostic all_diags;
    exit (if all_diags = [] then 0 else 1)

  | ["--check-json"; filename] ->
    (try
       let source = In_channel.with_open_text filename In_channel.input_all in
       let diags = check_json_diags filename source in
       print_string (Compile.diagnostics_to_json diags);
       print_newline ();
       exit (if diags = [] then 0 else 1)
     with Sys_error msg ->
       Printf.eprintf "error: %s\n" msg; exit 1)

  | ["--local-bindings-json"; filename] ->
    (try
       let source = In_channel.with_open_text filename In_channel.input_all in
       let bindings = Compile.local_bindings_source filename source in
       print_string (Compile.local_bindings_to_json bindings);
       print_newline ();
       exit 0
     with Sys_error msg ->
       Printf.eprintf "error: %s\n" msg; exit 1)

  | ["--definition-json"; filename; line; col] ->
    (try
       let source = In_channel.with_open_text filename In_channel.input_all in
       let definition = Compile.definition_source filename source (int_of_string line) (int_of_string col) in
       print_string (Compile.definition_response_to_json definition);
       print_newline ();
       exit 0
     with
     | Sys_error msg -> Printf.eprintf "error: %s\n" msg; exit 1
     | Failure msg -> Printf.eprintf "error: %s\n" msg; exit 1)

  | ["--occurrences-json"; filename; line; col] ->
    (try
       let source = In_channel.with_open_text filename In_channel.input_all in
       let occurrences = Compile.occurrences_source filename source (int_of_string line) (int_of_string col) in
       print_string (Compile.occurrences_response_to_json occurrences);
       print_newline ();
       exit 0
     with
     | Sys_error msg -> Printf.eprintf "error: %s\n" msg; exit 1
     | Failure msg -> Printf.eprintf "error: %s\n" msg; exit 1)

  | ["--type-at-json"; filename; line; col] ->
    (try
       let source = In_channel.with_open_text filename In_channel.input_all in
       let result = Compile.type_at_source filename source (int_of_string line) (int_of_string col) in
       print_string (Compile.type_at_response_to_json result);
       print_newline ();
       exit 0
     with
     | Sys_error msg -> Printf.eprintf "error: %s\n" msg; exit 1
     | Failure msg -> Printf.eprintf "error: %s\n" msg; exit 1)

  | ["--field-at-json"; filename; line; col] ->
    (try
       let source = In_channel.with_open_text filename In_channel.input_all in
       let result = Compile.field_at_source filename source (int_of_string line) (int_of_string col) in
       print_string (Compile.field_at_response_to_json result);
       print_newline ();
       exit 0
     with
     | Sys_error msg -> Printf.eprintf "error: %s\n" msg; exit 1
     | Failure msg -> Printf.eprintf "error: %s\n" msg; exit 1)

  | ["--completions-json"; filename; line; col] ->
    (try
       let source = In_channel.with_open_text filename In_channel.input_all in
       let items = Compile.completions_source filename source (int_of_string line) (int_of_string col) in
       print_string (Compile.completions_response_to_json items);
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
       let no_tests = List.length
           (List.filter (fun (_, r) -> r = Mutate.NoTests) report.Mutate.results) in
       let label = match extra_test_files with
         | [] -> filename
         | _ -> filename ^ " (with tests from: " ^ String.concat ", " extra_test_files ^ ")"
       in
       Printf.printf "%sMutation testing%s: %s\n\n" (col "1") (col "0") label;
       List.iter (fun ((mut : Mutate.mutant), result) ->
         let marker, colour = match result with
           | Mutate.Killed   -> "KILLED",   "1;32"
           | Mutate.Survived -> "SURVIVED", "1;31"
           | Mutate.NoTests  -> "NO TESTS", "1;33"
           | Mutate.Error _  -> "ERROR",    "1;33"
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
       if no_tests > 0 then
         Printf.printf " | %s%d no-tests%s" (col "1;33") no_tests (col "0");
       let score = if total = 0 then 100.0
                   else float_of_int (killed + report.Mutate.errors) /. float_of_int total *. 100.0 in
       Printf.printf "\n%sMutation score%s: %.0f%%\n" (col "1") (col "0") score;
       if survived > 0 then exit 1)

  | _ -> print_string usage; exit 1
