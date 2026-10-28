(** Completion metadata and lexical recovery for unfinished editor buffers.
    The public surface and signatures come from the checker's registries. This
    module never changes the program being checked or treats a suggestion as a
    proof. Source edits always refer to the original buffer. *)
open Ast

type item = {
  ci_label : string;
  ci_detail : string;
  ci_kind : string;
  ci_module : string option;
  ci_documentation : string option;
  ci_requires_import : bool;
  ci_edit : Type_system.diagnostic_fix option;
  ci_import_fix : Type_system.diagnostic_fix option;
  ci_sort_text : string;
}

let make ?module_ ?documentation ?(requires_import=false) ?edit ?import_fix
    ?(rank=0) ~kind label detail = {
  ci_label = label; ci_detail = detail; ci_kind = kind;
  ci_module = module_; ci_documentation = documentation;
  ci_requires_import = requires_import; ci_edit = edit;
  ci_import_fix = import_fix;
  ci_sort_text = Printf.sprintf "%d:%s" rank label;
}

let starts prefix text = String.starts_with ~prefix text
let ident = function 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' -> true | _ -> false
let qualified c = ident c || c = '.'
let tail name = match String.rindex_opt name '.' with
  | None -> name | Some i -> String.sub name (i + 1) (String.length name - i - 1)

type context = {
  line : int; col : int; start_col : int; end_col : int;
  offset : int; prefix : string; before : string; line_text : string;
}

(** Comments and literals must not trigger symbol completion, including an
    unfinished string. The lexer is line-oriented; escaped quotes remain inside
    the literal. Interpolations are conservatively handled as part of strings. *)
let code_at source offset =
  let rec loop i state =
    if i >= offset then state = `Code else
    match state, source.[i] with
    | `Comment, '\n' -> loop (i + 1) `Code
    | `Comment, _ -> loop (i + 1) `Comment
    | `String, '\\' -> loop (min offset (i + 2)) `String
    | `String, '"' -> loop (i + 1) `Code
    | `String, _ -> loop (i + 1) `String
    | `Code, '#' -> loop (i + 1) `Comment
    | `Code, '"' -> loop (i + 1) `String
    | `Code, _ -> loop (i + 1) `Code
  in loop 0 `Code

let context source line col =
  let lines = Array.of_list (String.split_on_char '\n' source) in
  if line < 0 || col < 0 || line >= Array.length lines then None else
  let text = lines.(line) in
  let length = String.length text - (if String.ends_with ~suffix:"\r" text then 1 else 0) in
  if col > length then None else
  let offset = ref col in
  for i = 0 to line - 1 do offset := !offset + String.length lines.(i) + 1 done;
  if not (code_at source !offset) then None else
  let first = ref col and last = ref col in
  while !first > 0 && qualified text.[!first - 1] do decr first done;
  while !last < length && qualified text.[!last] do incr last done;
  Some { line; col; start_col = !first; end_col = !last; offset = !offset;
         prefix = String.sub text !first (col - !first);
         before = String.sub source 0 (!offset - col + !first); line_text = text }

let edit context replacement = Type_system.Replace_range {
  start_line = context.line; start_col = context.start_col;
  end_line = context.line; end_col = context.end_col; replacement;
}

let tokens source =
  try Lexer.tokenize "<completion>" source
      |> List.filter_map (fun (t : Lexer.full_token) -> match t.tok with
          | Token.INDENT | Token.DEDENT | Token.NEWLINE | Token.EOF -> None
          | token -> Some token)
  with Failure _ -> []

let declaration_token = function
  | Token.FN | HANDLER | CHECK | AUTH | ESTABLISH | WORKER | DEAD_WORKER
  | MAIN | TYPE | RECORD | ENTITY | CONST | FACT | TEST | API_TEST | LOAD_TEST
  | DATABASE | API | SERVER | QUEUE | CHANNEL | CACHE | EMAIL | AGENT -> true
  | _ -> false

type mode = Modules | Exports of string | Types | Values

let mode context =
  let ts = tokens context.before in
  let recent = List.fold_left (fun acc token ->
    if declaration_token token || token = Token.IMPORT then [token]
    else token :: acc) [] ts |> List.rev in
  match recent with
  | Token.IMPORT :: rest ->
    let rec module_name acc = function
      | Token.UIDENT n :: xs | Token.IDENT n :: xs -> module_name (acc ^ n) xs
      | Token.DOT :: xs -> module_name (acc ^ ".") xs
      | Token.EXPOSING :: _ -> Exports acc
      | _ -> Modules
    in module_name "" rest
  | first :: rest ->
    let header = match first with
      | Token.FN | HANDLER | CHECK | AUTH | ESTABLISH | WORKER | DEAD_WORKER
      | MAIN | RECORD | ENTITY | TYPE | CONST -> true | _ -> false in
    let in_type = List.fold_left (fun active -> function
      | Token.COLON | Token.ARROW when header -> true
      | Token.EQ | Token.PROOF_ANNOT | Token.REQUIRES | Token.COMMA -> false
      | _ -> active) false rest in
    (* Once an expression starts, record-value colons are not annotations. *)
    if in_type && (not (List.mem Token.EQ rest) || first = Token.TYPE)
    then Types else Values
  | [] -> Values

let recovered_module filename source context =
  let parse s = try match Parser.parse_module filename s with
    | Parser.Ok m -> Some m | Parser.Err _ -> None with Failure _ -> None in
  match parse source with
  | Some m -> Some m, true, source
  | None ->
    (* Fill only the member/name under the cursor. This preserves import and
       earlier binding locations, and allows receiver types to be queried. *)
    let insertion = if context.prefix = "" || String.ends_with ~suffix:"." context.prefix
      then "teslCompletionHole" else "" in
    let repaired = String.sub source 0 context.offset ^ insertion
      ^ String.sub source context.offset (String.length source - context.offset) in
    match parse repaired with
    | Some m -> Some m, true, repaired
    | None ->
      let partial = try Parser.parse_module_recover filename repaired with Failure _ -> None in
      partial, false, repaired

let available m module_ name =
  if List.mem name Type_system.always_available_stdlib_names || name = "Fact" then true
  else match m with None -> false | Some m ->
    List.exists (fun (imp : import_decl) ->
      imp.module_name = module_ && match imp.names with
      | ImportAll -> true
      | ImportExposing names -> List.exists (fun exposed ->
          Import_suggest.strip_dotdot exposed = name ||
          (String.ends_with ~suffix:"(..)" exposed &&
           List.assoc_opt name Type_system.stdlib_ctor_owner_type =
             Some (Import_suggest.strip_dotdot exposed))) names) m.imports

(* Insert into the source list, rather than re-rendering the import AST: comments
   and the user's layout belong to the buffer and must survive autocomplete. *)
let extend_import source (imp : import_decl) name =
  let lines = Array.of_list (String.split_on_char '\n' source) in
  let start_line = imp.loc.start.line and end_line = imp.loc.stop.line in
  let fragment = Array.sub lines start_line (end_line - start_line + 1)
    |> Array.to_list |> String.concat "\n" in
  let ts = Lexer.tokenize "<import>" fragment |> List.filter (fun (t : Lexer.full_token) ->
    match t.tok with Token.NEWLINE | INDENT | DEDENT | EOF -> false | _ -> true) in
  let rec closing previous = function
    | (close : Lexer.full_token) :: _ when close.tok = Token.RBRACKET ->
      Option.map (fun previous -> previous, close) previous
    | t :: rest -> closing (Some t) rest
    | [] -> None in
  match closing None ts with
  | None -> None
  | Some (previous, close) ->
    let fragment_lines = Array.of_list (String.split_on_char '\n' fragment) in
    let offset line col =
      let at = ref col in
      for i = 0 to line - 1 do at := !at + String.length fragment_lines.(i) + 1 done;
      !at in
    let previous_line = fragment_lines.(previous.line) in
    let stop = ref (previous.col + 1) in
    if ident previous_line.[previous.col] then
      while !stop < String.length previous_line && ident previous_line.[!stop] do incr stop done;
    let width = !stop - previous.col in
    let last = offset previous.line (previous.col + width) in
    let bracket = offset close.line close.col in
    let comma = match previous.tok with Token.COMMA | LBRACKET -> "" | _ -> "," in
    let before_close = String.sub fragment_lines.(close.line) 0 close.col in
    let multiline = close.line > previous.line && String.trim before_close = "" in
    let insertion = if multiline then offset close.line 0 else bracket in
    let addition = if multiline then before_close ^ "  " ^ name ^ ",\n"
      else (if previous.tok = Token.LBRACKET then "" else " ") ^ name in
    let replacement = String.sub fragment 0 last ^ comma
      ^ String.sub fragment last (insertion - last) ^ addition
      ^ String.sub fragment insertion (String.length fragment - insertion) in
    Some (Type_system.Replace_span { start_line; end_line; replacement })

let import_fix source m module_ name =
  match List.find_opt (fun (imp : import_decl) -> imp.module_name = module_) m.imports with
  | Some ({ names = ImportExposing _; _ } as imp) -> extend_import source imp name
  | _ ->
  match Import_suggest.build_fix m ~target_module:module_ ~expose_name:name with
  | Some (Type_system.Insert_line { line; text }) ->
    let lines = Array.of_list (String.split_on_char '\n' source) in
    if line < Array.length lines then Some (Type_system.Insert_line { line; text })
    else
      let last = Array.length lines - 1 in
      let col = String.length lines.(last) in
      Some (Type_system.Replace_range { start_line = last; start_col = col;
        end_line = last; end_col = col;
        replacement = (if col = 0 then "" else "\n") ^ text ^ "\n" })
  | fix -> fix

let public_names = lazy (
  let pairs = List.concat_map (fun (m, names) ->
      List.filter_map (fun n -> if Type_system.go_backend_export_available m n
        then Some (n, m) else None) names) Type_system.tesl_module_exports
    @ List.map (fun (n, m) -> n, m) Type_system.stdlib_bare_home_module
    @ List.map (fun n -> n, "") Type_system.always_available_stdlib_names in
  List.sort_uniq compare pairs)

let documentation_entry name module_ =
  let entries = Stdlib_docs.lookup name in
  match List.find_opt (fun (entry : Stdlib_docs.entry) -> entry.module_ = module_) entries with
  | Some entry -> Some entry | None -> List.nth_opt entries 0

let kind name (entry : Stdlib_docs.entry) =
  if List.mem_assoc name Type_system.stdlib_ctor_owner_type then Some "constructor"
  else match entry.kind with
  | Stdlib_docs.KFunction _ -> Some "function"
  | KValue -> Some "variable"
  | KType _ when entry.name = name && not (Stdlib_config_names.is_rejected_in_type_position name)
      -> Some "type"
  | KCapability -> Some "capability"
  | KFact _ -> Some "fact"
  | KType _ | KSyntax _ | KConfig | KFamily _ -> None

let matches prefix label =
  let lower = String.lowercase_ascii in
  starts (lower prefix) (lower label) ||
  (not (String.contains prefix '.') && starts (lower prefix) (lower (tail label)))

let library_items source context m safe_imports =
  let mode = mode context in
  match mode with
  | Modules ->
    Type_system.tesl_known_module_names
    |> List.filter (matches context.prefix)
    |> List.sort_uniq compare
    |> List.map (fun name -> make ~kind:"module" ~edit:(edit context name) name
         ("Standard-library module " ^ name))
  | Values | Types | Exports _ ->
    Lazy.force public_names |> List.filter_map (fun (name, module_) ->
      if not (matches context.prefix name) || not (ident name.[0]) then None else
      match mode with Exports expected when module_ <> expected -> None | _ ->
      match documentation_entry name module_ with None -> None | Some entry ->
      match kind name entry with None -> None | Some kind ->
      if mode = Types && kind <> "type" then None else
      let in_scope = available m module_ name in
      let requires_import = mode <> Exports module_ && not in_scope && module_ <> "" in
      let detail = match List.assoc_opt name Type_system.stdlib_env with
        | Some scheme when kind <> "type" -> Type_system.pp_ty scheme.Type_system.mono
            ^ Stdlib_docs.requires_suffix name
        | _ -> (match Stdlib_docs.render entry with Ok s -> s | Error _ -> name) in
      let import = if requires_import && safe_imports then
          Option.bind m (fun m -> import_fix source m module_ name) else None in
      Some (make ~kind ~module_ ~documentation:entry.doc ~requires_import
        ~edit:(edit context name) ?import_fix:import
        ~rank:(if requires_import then 2 else 1) name detail))

let finish context items =
  items |> List.filter (fun item -> matches context.prefix item.ci_label)
  |> List.sort (fun a b -> compare a.ci_sort_text b.ci_sort_text)
  |> List.fold_left (fun acc item ->
      if List.exists (fun x -> x.ci_label = item.ci_label &&
          (not x.ci_requires_import || x.ci_module = item.ci_module)) acc
      then acc else item :: acc) []
  |> List.rev

let local_types context m =
  List.filter_map (function
    | DType (TypeAdt { name; params; _ }) ->
      Some (make ~kind:"type" ~edit:(edit context name) name
        ("type " ^ String.concat " " (name :: params)))
    | DType (TypeNewtype { name; _ }) | DRecord { name; _ } | DEntity { name; _ } ->
      Some (make ~kind:"type" ~edit:(edit context name) name ("type " ^ name))
    | _ -> None) m.decls

let local_functions context m =
  List.filter_map (function
    | DFunc fd ->
      let scheme = Checker.decl_scheme fd in
      Some (make ~kind:"function" ?documentation:fd.doc ~edit:(edit context fd.name)
        fd.name (Type_system.pp_ty scheme.Type_system.mono))
    | _ -> None) m.decls

(* Project types use the compiler's own local-module resolver and export
   declarations. Only resolvable sibling modules are offered with automatic
   edits. Discovery is bounded independently of parser recovery. *)
let project_types source context m safe_imports =
  if not (Source_input.exists m.source_file) then [] else
  let directory = Filename.dirname m.source_file in
  let files = try Source_input.readdir directory |> Array.to_list |> List.sort compare
    with Sys_error _ -> [] in
  let remaining = ref 200 and bytes = ref (8 * 1024 * 1024) in
  List.concat_map (fun file ->
    let path = Filename.concat directory file in
    if !remaining <= 0 || !bytes <= 0 || path = m.source_file
       || not (Filename.check_suffix file ".tesl") then [] else
    try
      let stat = Unix.lstat path in
      if stat.Unix.st_kind <> Unix.S_REG || stat.st_size > 1024 * 1024
         || stat.st_size > !bytes then [] else
      (decr remaining; bytes := !bytes - stat.st_size;
      let input = Source_input.read path in
      match Parser.parse_module path input with
      | Err _ -> []
      | Ok imported ->
        if Checker.resolve_local_import_path m.source_file imported.module_name <> path
          || String.starts_with ~prefix:"Tesl." imported.module_name then [] else
        let exported name = List.exists (function ExportName n | ExportAdt n -> n = name) imported.exports in
        local_types context imported |> List.filter_map (fun item ->
          if not (exported item.ci_label) || not (matches context.prefix item.ci_label) then None else
          let in_scope = List.exists (fun (imp : import_decl) ->
            imp.module_name = imported.module_name && match imp.names with
            | ImportAll -> true
            | ImportExposing names -> List.exists (fun name ->
                Import_suggest.strip_dotdot name = item.ci_label) names) m.imports in
          let import = if not in_scope && safe_imports then
              import_fix source m imported.module_name item.ci_label else None in
          Some { item with ci_module = Some imported.module_name;
            ci_requires_import = not in_scope; ci_import_fix = import;
            ci_sort_text = Printf.sprintf "%d:%s:%s" (if in_scope then 0 else 2)
              item.ci_label imported.module_name }))
    with Sys_error _ | Unix.Unix_error _ | Failure _ -> []) files
