(** Compiler-owned semantic workspace snapshots. Source coordinates are UTF-8
    byte columns. Clients provide an immutable mirror; this module never edits it.
    Every rename is a checked proposal with whole-workspace preconditions. *)
open Ast
open Compile

type problem = { code : string; file : string; message : string }
type unit_ = { path : string; source : string; ast : module_form; local : definition_env;
               mutable scope : definition_env; mutable dependencies : string list }
type use = { symbol : resolved_symbol; loc : Location.loc; role : string }
type snapshot = { root : string; id : string; inputs : (string * string) list;
                  units : unit_ list; uses : use list; problems : problem list }
type edit = { loc : Location.loc; text : string }

let max_files = 512
let max_bytes = 16 * 1024 * 1024
let max_identifiers = 20000
let excluded = [".git"; "_build"; "node_modules"; ".tesl-stuff"; ".tesl-postgres";
                "compiled"; "artifacts"; "vendor"; "result"; ".direnv"; "_opam"]
let hash text = Digest.to_hex (Digest.string text)
let canonical = Validation_common.canonical_import_path
let within root path = path = root || String.starts_with ~prefix:(root ^ Filename.dir_sep) path
let relative root path = if within root path && path <> root then
  String.sub path (String.length root + 1) (String.length path - String.length root - 1) else path
let kind = function TermSymbol -> "term" | TypeSymbol -> "type" | CtorSymbol -> "constructor"
let same_binding a b = a.symbol_kind = b.symbol_kind && loc_equal a.symbol_loc b.symbol_loc
let symbol_id root s = hash (Printf.sprintf "%s:%s:%s:%d:%d" (relative root s.symbol_loc.file)
  (kind s.symbol_kind) s.symbol_name s.symbol_loc.start.line s.symbol_loc.start.col)
let basename name = List.hd (List.rev (String.split_on_char '.' name))

let root_for filename =
  let directory = Filename.dirname (canonical filename) in
  let rec search path =
    if Sys.file_exists (Filename.concat path "tesl.toml") then Some path
    else let parent = Filename.dirname path in if parent = path then None else search parent
  in Option.value ~default:directory (search directory)

let symbols env =
  let rows make = List.map (fun item -> make item.bound_name item.bound_loc) in
  rows term_symbol env.term_defs @ rows type_symbol env.type_defs @ rows ctor_symbol env.ctor_defs

let local_env ast =
  let env = collect_definition_env ast in
  List.fold_left (fun env -> function
    | DType (TypeNewtype { name; loc; _ }) -> add_ctor_def env name (precise_name_loc loc name)
    | DRecord r -> add_ctor_def env r.name (precise_name_loc r.loc r.name)
    | DEntity e -> add_ctor_def env e.name (precise_name_loc e.loc e.name)
    | _ -> env) env ast.decls

let canonical_symbol units symbol =
  match List.find_opt (fun unit -> unit.path = symbol.symbol_loc.file) units with
  | None -> symbol
  | Some unit ->
    (* A record/newtype's constructor and type are one renameable declaration. *)
    let available = symbols unit.local in
    let found = List.find_opt (fun candidate -> loc_equal candidate.symbol_loc symbol.symbol_loc
      && (candidate.symbol_kind = symbol.symbol_kind ||
          symbol.symbol_kind = CtorSymbol && candidate.symbol_kind = TypeSymbol)) available in
    Option.value ~default:symbol found

let add_scope env name symbol = match symbol.symbol_kind with
  | TermSymbol -> add_term_def env name symbol.symbol_loc
  | TypeSymbol -> add_type_def env name symbol.symbol_loc
  | CtorSymbol -> add_ctor_def env name symbol.symbol_loc

let exported ast symbol =
  let named name = List.exists (function ExportName n | ExportAdt n -> n = name) ast.exports in
  match symbol.symbol_kind with
  | TermSymbol | TypeSymbol -> named symbol.symbol_name
  | CtorSymbol -> List.exists (function
    | DType (TypeAdt { name; variants; _ }) ->
      List.mem (ExportAdt name) ast.exports && List.exists (fun v -> v.ctor = symbol.symbol_name) variants
    | DType (TypeNewtype { name; _ }) | DRecord { name; _ } | DEntity { name; _ } ->
      name = symbol.symbol_name && named name
    | _ -> false) ast.decls

let import_aliases imported (imp : import_decl) symbol =
  if not (exported imported.ast symbol) then [] else
  let name = symbol.symbol_name in
  let lifted = String.starts_with ~prefix:"Tesl." imp.module_name in
  let qualifier = if lifted then basename imp.module_name else imp.module_name in
  let qualified = qualifier ^ "." ^ name in
  let wanted = match imp.names with
    | ImportAll -> false
    | ImportExposing names ->
      List.mem (if lifted && symbol.symbol_kind = TermSymbol then qualified else name) names
      || List.mem (name ^ "(..)") names
      || symbol.symbol_kind = CtorSymbol && List.exists (function
        | DType (TypeAdt { name = owner; variants; _ }) ->
          List.mem (owner ^ "(..)") names && List.exists (fun v -> v.ctor = name) variants
        | _ -> false) imported.ast.decls
  in
  let qualified_allowed = imp.names = ImportAll || wanted || symbol.symbol_kind = TypeSymbol in
  (if wanted && not (lifted && symbol.symbol_kind = TermSymbol) then [name] else [])
  @ (if qualified_allowed then [qualified] else [])

let byte_offset source pos =
  let rec line offset remaining =
    if remaining = 0 then offset + pos.Location.col
    else match String.index_from_opt source offset '\n' with
      | Some index -> line (index + 1) (remaining - 1)
      | None -> invalid_arg "workspace source position out of bounds"
  in
  let offset = line 0 pos.Location.line in
  if offset < 0 || offset > String.length source then invalid_arg "workspace byte column out of bounds";
  offset

let text_at source loc =
  let first = byte_offset source loc.Location.start and last = byte_offset source loc.stop in
  String.sub source first (last - first)

let suffix_loc source loc name =
  let text = text_at source loc in
  if text = name then Some loc
  else if String.ends_with ~suffix:("." ^ name) text && loc.Location.start.line = loc.stop.line then
    Some { loc with start = { loc.start with col = loc.stop.col - String.length name } }
  else None

let build ?root filename =
  let root = Option.value ~default:(root_for filename) root |> canonical in
  let problems = ref [] and inputs = Hashtbl.create 64 and loaded = Hashtbl.create 64 in
  let bytes = ref 0 and files = ref 0 in
  let problem code file message = problems := { code; file; message } :: !problems in
  let read path =
    match Hashtbl.find_opt inputs path with
    | Some source -> Some source
    | None ->
      try
        let size = (Unix.stat path).Unix.st_size in
        if size > 1024 * 1024 || !bytes + size > max_bytes || !files >= max_files then
          (problem "workspace-limit" path "workspace source budget exceeded"; None)
        else begin
          let source = In_channel.with_open_bin path In_channel.input_all in
          bytes := !bytes + String.length source; incr files;
          Hashtbl.add inputs path source; Some source
        end
      with Sys_error message | Unix.Unix_error (_, _, message) ->
        problem "unreadable-source" path message; None
  in
  let rec load path =
    let path = canonical path in
    if not (Hashtbl.mem loaded path) then begin
      Hashtbl.add loaded path None;
      match read path with
      | None -> ()
      | Some source -> match parse_module path source with
        | Parser.Err error -> problem "parse-error" path error.msg
        | Parser.Ok ast ->
          if module_complexity_diagnostics ast <> [] then problem "workspace-limit" path "module complexity limit exceeded"
          else begin
            set_query_source_lines source;
            let local = local_env ast in
            let unit = { path; source; ast; local; scope = local; dependencies = [] } in
            Hashtbl.replace loaded path (Some unit);
            List.iter (fun (imp : import_decl) ->
              let dependency = if String.starts_with ~prefix:"Tesl." imp.module_name then
                match Validation_common.lifted_stdlib_basename imp.module_name with
                | None -> None
                | Some _ -> (match Validation_common.lifted_stdlib_source_path imp.module_name with
                  | Some path -> Some path
                  | None -> problem "missing-import" path ("missing bundled module " ^ imp.module_name); None)
                else Some (Validation_common.resolve_local_import_path path imp.module_name) in
              match dependency with None -> () | Some dependency ->
                let dependency = canonical dependency in
                unit.dependencies <- dependency :: unit.dependencies;
                load dependency) ast.imports
          end
    end
  in
  let visited = Hashtbl.create 32 in
  let rec scan directory =
    let real = canonical directory in
    if within root real && not (Hashtbl.mem visited real) then begin
      Hashtbl.add visited real ();
      let manifest = Filename.concat directory "tesl.toml" in
      if directory = root || not (Sys.file_exists manifest) then begin
        if Sys.file_exists manifest then ignore (read (canonical manifest));
        try Sys.readdir directory |> Array.to_list |> List.sort String.compare |> List.iter (fun name ->
          let path = Filename.concat directory name in
          if not (List.mem name excluded) && not (String.starts_with ~prefix:"." name) then
            if Sys.is_directory path then scan path else if Filename.check_suffix name ".tesl" then load path)
        with Sys_error message -> problem "unreadable-directory" directory message
      end
    end
  in
  scan root; load filename;
  let units = Hashtbl.fold (fun _ value acc -> match value with Some value -> value :: acc | None -> acc) loaded []
    |> List.sort (fun a b -> String.compare a.path b.path) in
  let import_scope unit (imp : import_decl) =
    let expected = if String.starts_with ~prefix:"Tesl." imp.module_name then
      Validation_common.lifted_stdlib_source_path imp.module_name
      else Some (Validation_common.resolve_local_import_path unit.path imp.module_name) in
    match Option.bind expected (fun path -> List.find_opt (fun dep -> dep.path = canonical path) units) with
    | None -> empty_definition_env
    | Some dep ->
      if not (String.starts_with ~prefix:"Tesl." imp.module_name) && dep.ast.module_name <> imp.module_name then
        problem "module-name-mismatch" unit.path ("imported source does not declare " ^ imp.module_name);
      List.fold_left (fun env symbol ->
        List.fold_left (fun env alias -> add_scope env alias symbol) env (import_aliases dep imp symbol))
        empty_definition_env (symbols dep.local)
  in
  List.iter (fun unit ->
    let imported = ref empty_definition_env in
    List.iter (fun (imp : import_decl) ->
      let scope = import_scope unit imp in
      imported := { term_defs = scope.term_defs @ !imported.term_defs;
                    type_defs = scope.type_defs @ !imported.type_defs;
                    ctor_defs = scope.ctor_defs @ !imported.ctor_defs }) unit.ast.imports;
    let merge local imported = local @ imported in
    unit.scope <- { term_defs = merge unit.local.term_defs !imported.term_defs;
                    type_defs = merge unit.local.type_defs !imported.type_defs;
                    ctor_defs = merge unit.local.ctor_defs !imported.ctor_defs };
    List.iter (fun defs ->
      List.iter (fun item ->
        let same = List.filter (fun other -> other.bound_name = item.bound_name) defs in
        if List.exists (fun other -> not (loc_equal other.bound_loc item.bound_loc)) same then
          problem "ambiguous-binding" unit.path ("ambiguous imported/declaration name " ^ item.bound_name)) defs)
      [unit.scope.term_defs; unit.scope.type_defs; unit.scope.ctor_defs]) units;
  let uses = ref [] in
  let add unit symbol loc role =
    let symbol = canonical_symbol units symbol in
    match suffix_loc unit.source loc (basename symbol.symbol_name) with
    | None -> problem "unsupported-source-span" unit.path "semantic identifier span cannot be edited precisely"
    | Some loc ->
      if not (List.exists (fun item -> same_binding item.symbol symbol && loc_equal item.loc loc) !uses)
      then uses := { symbol; loc; role } :: !uses
  in
  List.iter (fun unit ->
    set_query_source_lines unit.source;
    if not (within root unit.path) then
      List.iter (fun symbol -> add unit symbol symbol.symbol_loc "declaration") (symbols unit.local)
    else begin
    let tokens = Lexer.tokenize unit.path unit.source |> Lexer.semantic_tokens unit.path in
    if List.length tokens > max_identifiers then problem "workspace-limit" unit.path "identifier budget exceeded"
    else begin
      let candidates = ref (symbols unit.scope) in
      List.iter (fun (token : Lexer.full_token) -> match token.tok with
        | Token.IDENT _ | Token.UIDENT _ ->
          (match find_map_list (resolve_symbol_in_top_decl unit.scope token.line token.col) unit.ast.decls with
          | Some symbol -> if not (List.exists (symbol_equal symbol) !candidates) then candidates := symbol :: !candidates
          | None -> ())
        | _ -> ()) tokens;
      List.iter (fun symbol ->
        List.concat_map (collect_occurrences_in_top_decl unit.scope symbol) unit.ast.decls
        |> List.iter (fun loc -> add unit symbol loc (if loc_equal loc symbol.symbol_loc then "declaration" else "read"))) !candidates;
      (* Headers have their own parsed scope: expose clauses name declarations,
         never arbitrary textual matches. The lexer excludes comments/strings. *)
      let header = ref None and exposing = ref false in
      List.iter (fun (token : Lexer.full_token) ->
        match token.tok with
        | Token.MODULE -> header := Some unit.local; exposing := false
        | Token.IMPORT ->
          let imp = List.find_opt (fun (imp : import_decl) -> imp.loc.start.line = token.line) unit.ast.imports in
          header := Option.map (import_scope unit) imp; exposing := false
        | Token.EXPOSING when !header <> None -> exposing := true
        | Token.RBRACKET -> header := None; exposing := false
        | Token.IDENT name | Token.UIDENT name when !exposing ->
          (match !header with None -> () | Some env ->
            let candidates = List.filter (fun symbol -> basename symbol.symbol_name = name) (symbols env) in
            let unique = List.sort_uniq (fun a b -> compare (a.symbol_loc, a.symbol_kind) (b.symbol_loc, b.symbol_kind)) candidates in
            List.iter (fun symbol ->
              add unit symbol (Location.make_loc unit.path token.line token.col token.line (token.col + String.length name)) "exposing") unique)
        | Token.NEWLINE when not !exposing -> header := None
        | _ -> ()) tokens;
      (* A known declaration spelling in a token position not covered by the
         semantic traversal means this index cannot promise complete references.
         Such tokens are never turned into references or rename edits. *)
      let header_line line = List.exists (fun (imp : import_decl) -> imp.loc.start.line <= line && line <= imp.loc.stop.line) unit.ast.imports
        || List.exists (fun (tok : Lexer.full_token) -> tok.line = line && tok.tok = Token.MODULE) tokens in
      List.iter (fun (token : Lexer.full_token) -> match token.tok with
        | Token.IDENT name | Token.UIDENT name when not (header_line token.line) ->
          if List.exists (fun symbol -> basename symbol.symbol_name = name) !candidates
             && not (List.exists (fun (use : use) -> use.loc.file = unit.path && loc_contains_position use.loc token.line token.col) !uses)
          then problem "unsupported-reference-context" unit.path (Printf.sprintf "unresolved semantic context for %s at %d:%d" name token.line token.col)
        | _ -> ()) tokens
    end end) units;
  let inputs = Hashtbl.fold (fun path source acc -> (path, source) :: acc) inputs [] |> List.sort compare in
  let id = hash ("workspace-index-v1\000" ^ String.concat "\000" (List.map (fun (path, source) -> relative root path ^ "\000" ^ hash source) inputs)) in
  { root; id; inputs; units; uses = List.sort (fun (a : use) (b : use) -> compare a.loc b.loc) !uses;
    problems = List.sort_uniq compare !problems }

let at snapshot filename line col =
  let filename = canonical filename in
  List.find_opt (fun (use : use) -> use.loc.file = filename && loc_contains_position use.loc line col) snapshot.uses

let references snapshot symbol = List.filter (fun use -> same_binding use.symbol symbol) snapshot.uses

let json_list f values = "[" ^ String.concat "," (List.map f values) ^ "]"
let loc_json loc = definition_location_to_json (location_to_definition loc)
let problem_json p = Printf.sprintf {|{"code":%s,"file":%s,"message":%s}|}
  (json_encode_string p.code) (json_encode_string p.file) (json_encode_string p.message)
let symbol_json snapshot s = Printf.sprintf {|{"id":%s,"name":%s,"kind":%s,"definition":%s,"read_only":%b}|}
  (json_encode_string (symbol_id snapshot.root s)) (json_encode_string s.symbol_name)
  (json_encode_string (kind s.symbol_kind)) (loc_json s.symbol_loc) (not (within snapshot.root s.symbol_loc.file))
let use_json (use : use) = Printf.sprintf {|{"location":%s,"role":%s}|} (loc_json use.loc) (json_encode_string use.role)
let input_json (file, source) = Printf.sprintf {|{"file":%s,"content_hash":%s}|} (json_encode_string file) (json_encode_string (hash source))

let response snapshot selected extra =
  let refs = match selected with Some use -> references snapshot use.symbol | None -> [] in
  Printf.sprintf {|{"version":1,"workspace_root":%s,"snapshot":%s,"coordinate_encoding":"utf-8","complete":%b,"problems":%s,"inputs":%s,"symbol":%s,"references":%s%s}|}
    (json_encode_string snapshot.root) (json_encode_string snapshot.id) (snapshot.problems = [])
    (json_list problem_json snapshot.problems) (json_list input_json snapshot.inputs)
    (match selected with None -> "null" | Some use -> symbol_json snapshot use.symbol)
    (json_list use_json refs) extra

let rec mkdir path = if not (Sys.file_exists path) then begin
  let parent = Filename.dirname path in if parent <> path then mkdir parent;
  Unix.mkdir path 0o700
end

let rec remove_tree path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  end else Sys.remove path

let with_temporary_directory f =
  let path = Filename.temp_file "tesl-rename-" "" in
  Sys.remove path; Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)

let apply_edits source edits =
  let edits = List.sort (fun a b -> compare b.loc.start a.loc.start) edits in
  List.fold_left (fun source edit ->
    let first = byte_offset source edit.loc.start and last = byte_offset source edit.loc.stop in
    String.sub source 0 first ^ edit.text ^ String.sub source last (String.length source - last)) source edits

let position_at source offset =
  let line = ref 0 and start = ref 0 in
  for index = 0 to offset - 1 do
    if source.[index] = '\n' then begin incr line; start := index + 1 end
  done;
  { Location.line = !line; col = offset - !start }

let translate_loc snapshot candidate_root edits loc =
  if not (within snapshot.root loc.Location.file) then loc else
  let source = List.assoc loc.file snapshot.inputs in
  let relevant = List.filter (fun edit -> edit.loc.file = loc.file) edits in
  let changed = apply_edits source relevant in
  let offset position =
    let old = byte_offset source position in
    old + List.fold_left (fun delta edit ->
      let first = byte_offset source edit.loc.start and last = byte_offset source edit.loc.stop in
      if last <= old then delta + String.length edit.text - (last - first) else delta) 0 relevant
  in
  { Location.file = Filename.concat candidate_root (relative snapshot.root loc.file);
    start = position_at changed (offset loc.start); stop = position_at changed (offset loc.stop) }

let validation_errors snapshot =
  List.concat_map (fun unit -> if within snapshot.root unit.path then
    check_source unit.path unit.source |> List.filter (fun diagnostic -> diagnostic.severity = "error")
    else []) snapshot.units

let validate_rename snapshot selected new_name expected =
  let fail reason = Error reason in
  let valid_name = match Lexer.tokenize "rename" new_name with
    | [{ Lexer.tok = (Token.IDENT _ | Token.UIDENT _); _ }; { Lexer.tok = Token.NEWLINE; _ }; { Lexer.tok = Token.EOF; _ }] -> true
    | _ -> false in
  if expected <> snapshot.id then fail "stale workspace snapshot"
  else if snapshot.problems <> [] then fail "workspace index is incomplete"
  else match selected with
  | None -> fail "no semantic symbol at this position"
  | Some selected ->
    let symbol = selected.symbol in
    if not (within snapshot.root symbol.symbol_loc.file) then fail "dependency declarations are read-only"
    else if not valid_name || String.length new_name > 128 then fail "new name must be one non-keyword identifier"
    else if new_name = symbol.symbol_name then fail "new name is unchanged"
    else if (new_name.[0] >= 'A' && new_name.[0] <= 'Z') <>
            (symbol.symbol_name.[0] >= 'A' && symbol.symbol_name.[0] <= 'Z') then fail "new name changes identifier namespace"
    else if validation_errors snapshot <> [] then fail "workspace has existing type/proof errors; safe rename is unavailable"
    else
      let edits = references snapshot symbol |> List.map (fun (use : use) -> { loc = use.loc; text = new_name }) in
      if List.exists (fun edit -> not (within snapshot.root edit.loc.file)) edits then fail "rename would edit a read-only dependency"
      else with_temporary_directory (fun candidate_root ->
        List.iter (fun (path, source) -> if within snapshot.root path then begin
          let path' = Filename.concat candidate_root (relative snapshot.root path) in
          mkdir (Filename.dirname path');
          let source = apply_edits source (List.filter (fun edit -> edit.loc.file = path) edits) in
          Out_channel.with_open_bin path' (fun output -> output_string output source)
        end) snapshot.inputs;
        let selected_path = Filename.concat candidate_root (relative snapshot.root selected.loc.file) in
        let candidate = build ~root:candidate_root selected_path in
        if candidate.problems <> [] then fail "renamed snapshot has ambiguous or incomplete semantic bindings"
        else
          let expected_uses = List.map (fun (use : use) ->
            let loc = translate_loc snapshot candidate_root edits use.loc in
            let declaration = translate_loc snapshot candidate_root edits use.symbol.symbol_loc in
            use, loc, declaration) snapshot.uses in
          let preserved = List.for_all (fun (use, loc, declaration) ->
            List.exists (fun (after : use) -> loc_equal after.loc loc && loc_equal after.symbol.symbol_loc declaration
              && after.symbol.symbol_kind = use.symbol.symbol_kind) candidate.uses) expected_uses in
          let no_capture = List.for_all (fun (after : use) ->
            List.exists (fun (_, loc, _) -> loc_equal loc after.loc) expected_uses) candidate.uses in
          if not preserved || not no_capture then fail "rename changes binding identity or captures another name"
          else if validation_errors candidate <> [] then fail "renamed snapshot introduces type/proof errors"
          else Ok edits)

let rename_json snapshot selected new_name expected =
  let result = try validate_rename snapshot selected new_name expected
    with Failure reason | Invalid_argument reason -> Error reason in
  let edits, safe, reason = match result with
    | Error reason -> [], false, json_encode_string reason
    | Ok edits -> edits, true, "null" in
  let files = List.sort_uniq String.compare (List.map (fun edit -> edit.loc.file) edits) in
  let file_json file =
    Printf.sprintf {|{"file":%s,"content_hash":%s,"edits":%s}|}
      (json_encode_string file) (json_encode_string (hash (List.assoc file snapshot.inputs)))
      (json_list (fun edit -> Printf.sprintf {|{"location":%s,"new_text":%s}|}
        (loc_json edit.loc) (json_encode_string edit.text)) (List.filter (fun edit -> edit.loc.file = file) edits)) in
  Printf.sprintf {|,"rename":{"safe":%b,"new_name":%s,"expected_snapshot":%s,"reason":%s,"files":%s,"checked":"binding-identity-and-type-proof-check"}|}
    safe (json_encode_string new_name) (json_encode_string expected) reason (json_list file_json files)

(* Reuse the graph across targeted queries in the same immutable session mirror.
   Query_cache.clear invalidates this together with all other semantic caches. *)
let cached_snapshot = Query_cache.memo ~limit:2 ~max_weight:(2 * max_bytes)
  ~weight:(fun _ -> 0)
  ~value_weight:(fun snapshot -> List.fold_left (fun total (_, source) -> total + String.length source) 0 snapshot.inputs)
  build

let run ~filename flag arguments =
  let line, col, rename = match arguments with
    | [line; col] when flag <> "--workspace-rename-json" -> int_of_string line, int_of_string col, None
    | [line; col; name; expected] when flag = "--workspace-rename-json" -> int_of_string line, int_of_string col, Some (name, expected)
    | _ -> invalid_arg "invalid workspace query arguments" in
  if line < 0 || col < 0 then invalid_arg "negative workspace position";
  let snapshot = cached_snapshot filename in
  let selected = at snapshot filename line col in
  let extra = match rename with None -> "" | Some (name, expected) -> rename_json snapshot selected name expected in
  (* One-shot clients have no mirror lock: reject concurrent input changes rather
     than returning edits checked against a different on-disk revision. *)
  let current = build ~root:snapshot.root filename in
  let snapshot = if current.id = snapshot.id then snapshot else
    { snapshot with problems = { code = "stale-snapshot"; file = filename; message = "workspace changed during query" } :: snapshot.problems } in
  let extra = if current.id = snapshot.id then extra else
    {|,"rename":{"safe":false,"reason":"workspace changed during query","files":[]}|} in
  response snapshot selected extra
