(** Tesl compiler CLI.

    Usage:
      tesl <file>                compile to Racket (output to stdout)
      tesl --check <file> ...    type-check without output
      tesl --check-json <file>   type-check, diagnostics as IR-2 JSON to stdout
      tesl --local-bindings-json <file> inferred local binding types as JSON to stdout
      tesl --definition-json <file> <line> <col> definition location as JSON to stdout
      tesl --occurrences-json <file> <line> <col> same-file occurrences as JSON to stdout
      tesl --fmt <file>          format source file in place
      tesl --fmt-check <file>    check formatting without modifying
      tesl --lint <file> ...     run the opinionated linter
      tesl --ir <file>           emit API IR JSON
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
|}

(* ── ANSI colours ────────────────────────────────────────────────────────── *)

let use_colour = Unix.isatty Unix.stderr
let col code   = if use_colour then "\027[" ^ code ^ "m" else ""

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
    d.file (d.start_line + 1) (d.start_col + 1)

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
