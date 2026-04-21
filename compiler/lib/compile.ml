(** Top-level compilation pipeline.
    parse → type-check → emit. *)

open Parser
open Ast

(** JSON-safe string encoder.
    OCaml's [%S] format uses OCaml escape syntax (\NNN for non-ASCII bytes),
    which is NOT valid JSON.  This function produces a properly quoted JSON
    string: control characters are escaped as \uXXXX; all valid UTF-8 bytes
    (including multi-byte sequences for non-ASCII codepoints) are passed
    through verbatim, as JSON allows any valid Unicode scalar value. *)
let json_encode_string s =
  let buf = Buffer.create (String.length s + 2) in
  Buffer.add_char buf '"';
  String.iter (fun c ->
    match c with
    | '"'  -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\r' -> Buffer.add_string buf "\\r"
    | '\t' -> Buffer.add_string buf "\\t"
    | c when Char.code c < 0x20 ->
      Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
    | c    -> Buffer.add_char buf c
  ) s;
  Buffer.add_char buf '"';
  Buffer.contents buf

(** A unified diagnostic that can come from the parser or the type checker. *)
type diagnostic_fix =
  | Replace_line of { line : int; replacement : string }

type diagnostic = {
  file     : string;
  start_line : int;
  start_col  : int;
  end_line   : int;
  end_col    : int;
  severity   : string;
  code       : string;
  message    : string;
  fix        : diagnostic_fix option;
  source     : string;
}

type compile_result =
  | Success of string            (** Racket source code *)
  | Failure of diagnostic list   (** Parse or type errors *)

type local_binding = {
  file : string;
  line : int;
  col : int;
  end_line : int;
  end_col : int;
  name : string;
  ty : string;
  note : string option;
}

let diag_of_parse_error (e : parse_error) : diagnostic = {
  file       = e.loc.file;
  start_line = e.loc.start.line;
  start_col  = e.loc.start.col;
  end_line   = e.loc.stop.line;
  end_col    = e.loc.stop.col;
  severity   = "error";
  code       = "E000";
  message    = e.msg;
  fix        = None;
  source     = "parser";
}

let diag_of_proof_error (e : Proof_checker.proof_error) : diagnostic = {
  file       = e.loc.file;
  start_line = e.loc.start.line;
  start_col  = e.loc.start.col;
  end_line   = e.loc.stop.line;
  end_col    = e.loc.stop.col;
  severity   = "error";
  code       = "P001";
  message    = e.message;
  fix        = None;
  source     = "proof-checker";
}

let diag_of_type_error (e : Type_system.type_error) : diagnostic = {
  file       = e.loc.file;
  start_line = e.loc.start.line;
  start_col  = e.loc.start.col;
  end_line   = e.loc.stop.line;
  end_col    = e.loc.stop.col;
  severity   = "error";
  code       = "T001";
  message    = e.message;
  fix        = None;
  source     = "type-checker";
}

let diag_of_validation_error (e : Validation.validation_error) : diagnostic = {
  file       = e.loc.file;
  start_line = e.loc.start.line;
  start_col  = e.loc.start.col;
  end_line   = e.loc.stop.line;
  end_col    = e.loc.stop.col;
  severity   = "error";
  code       = "V001";
  message    = if e.hint = "" then e.message else e.message ^ "\nHint: " ^ e.hint;
  fix        = None;
  source     = "validation";
}

let fix_to_json = function
  | None -> "null"
  | Some (Replace_line { line; replacement }) ->
      Printf.sprintf {|{"kind":"replace_line","line":%d,"replacement":%s}|}
        line (json_encode_string replacement)

let diag_to_json (d : diagnostic) : string =
  Printf.sprintf
    {|{"file":%s,"start":{"line":%d,"col":%d},"end":{"line":%d,"col":%d},"severity":%s,"code":%s,"message":%s,"fix":%s,"source":%s}|}
    (json_encode_string d.file)
    d.start_line d.start_col
    d.end_line   d.end_col
    (json_encode_string d.severity)
    (json_encode_string d.code)
    (json_encode_string d.message)
    (fix_to_json d.fix)
    (json_encode_string d.source)

let diagnostics_to_json (diags : diagnostic list) : string =
  Printf.sprintf {|{"version":1,"diagnostics":[%s]}|}
    (String.concat "," (List.map diag_to_json diags))

let local_binding_to_json (b : local_binding) : string =
  let note_field = match b.note with
    | Some note -> Printf.sprintf ",\"note\":%s" (json_encode_string note)
    | None -> ""
  in
  Printf.sprintf
    {|{"file":%s,"line":%d,"col":%d,"end_line":%d,"end_col":%d,"name":%s,"type":%s%s}|}
    (json_encode_string b.file) b.line b.col b.end_line b.end_col
    (json_encode_string b.name) (json_encode_string b.ty) note_field

let local_bindings_to_json (bindings : local_binding list) : string =
  Printf.sprintf {|{"version":1,"bindings":[%s]}|}
    (String.concat "," (List.map local_binding_to_json bindings))

type definition_location = {
  file : string;
  line : int;
  col : int;
  end_line : int;
  end_col : int;
}

let definition_location_to_json (d : definition_location) : string =
  Printf.sprintf
    {|{"file":%s,"line":%d,"col":%d,"end_line":%d,"end_col":%d}|}
    (json_encode_string d.file) d.line d.col d.end_line d.end_col

let definition_to_json = function
  | None -> "null"
  | Some d -> definition_location_to_json d

let definition_response_to_json definition =
  Printf.sprintf {|{"version":1,"definition":%s}|} (definition_to_json definition)

type occurrence_location = definition_location

let occurrence_location_to_json = definition_location_to_json

let occurrences_to_json (occurrences : occurrence_location list) =
  Printf.sprintf "[%s]"
    (String.concat "," (List.map occurrence_location_to_json occurrences))

let occurrences_response_to_json occurrences =
  Printf.sprintf {|{"version":1,"occurrences":%s}|} (occurrences_to_json occurrences)

type type_at_result = {
  file : string;
  line : int;
  col : int;
  end_line : int;
  end_col : int;
  ty : string;
}

let type_at_result_to_json (result : type_at_result) : string =
  Printf.sprintf
    {|{"file":%s,"line":%d,"col":%d,"end_line":%d,"end_col":%d,"type":%s}|}
    (json_encode_string result.file) result.line result.col
    result.end_line result.end_col (json_encode_string result.ty)

let type_at_to_json = function
  | None -> "null"
  | Some result -> type_at_result_to_json result

let type_at_response_to_json result =
  Printf.sprintf {|{"version":1,"type_at":%s}|} (type_at_to_json result)

type field_at_result = {
  far_field       : string;
  far_record_type : string;
  far_field_type  : string;
  far_file        : string;
  far_line        : int;
  far_col         : int;
  far_end_line    : int;
  far_end_col     : int;
}

let field_at_result_to_json (r : field_at_result) : string =
  Printf.sprintf
    {|{"field":%s,"record_type":%s,"field_type":%s,"file":%s,"line":%d,"col":%d,"end_line":%d,"end_col":%d}|}
    (json_encode_string r.far_field) (json_encode_string r.far_record_type)
    (json_encode_string r.far_field_type) (json_encode_string r.far_file)
    r.far_line r.far_col r.far_end_line r.far_end_col

let field_at_to_json = function
  | None -> "null"
  | Some r -> field_at_result_to_json r

let field_at_response_to_json result =
  Printf.sprintf {|{"version":1,"field_at":%s}|} (field_at_to_json result)

type named_loc = {
  bound_name : string;
  bound_loc : Location.loc;
}

type definition_env = {
  term_defs : named_loc list;
  type_defs : named_loc list;
  ctor_defs : named_loc list;
}

type symbol_kind =
  | TermSymbol
  | TypeSymbol
  | CtorSymbol

type resolved_symbol = {
  symbol_kind : symbol_kind;
  symbol_name : string;
  symbol_loc : Location.loc;
}

let term_symbol name loc = { symbol_kind = TermSymbol; symbol_name = name; symbol_loc = loc }
let type_symbol name loc = { symbol_kind = TypeSymbol; symbol_name = name; symbol_loc = loc }
let ctor_symbol name loc = { symbol_kind = CtorSymbol; symbol_name = name; symbol_loc = loc }

let empty_definition_env = {
  term_defs = [];
  type_defs = [];
  ctor_defs = [];
}

let add_term_def env name loc =
  { env with term_defs = { bound_name = name; bound_loc = loc } :: env.term_defs }

let add_type_def env name loc =
  { env with type_defs = { bound_name = name; bound_loc = loc } :: env.type_defs }

let add_ctor_def env name loc =
  { env with ctor_defs = { bound_name = name; bound_loc = loc } :: env.ctor_defs }

let location_to_definition (loc : Location.loc) : definition_location = {
  file = loc.file;
  line = loc.start.line;
  col = loc.start.col;
  end_line = loc.stop.line;
  end_col = loc.stop.col;
}

let position_leq (line1, col1) (line2, col2) =
  line1 < line2 || (line1 = line2 && col1 <= col2)

let position_lt (line1, col1) (line2, col2) =
  line1 < line2 || (line1 = line2 && col1 < col2)

let loc_contains_position (loc : Location.loc) line col =
  position_leq (loc.start.line, loc.start.col) (line, col)
  && position_lt (line, col) (loc.stop.line, loc.stop.col)

let current_query_source_lines : string array ref = ref [||]

let set_query_source_lines source =
  current_query_source_lines := Array.of_list (String.split_on_char '
' source)

let query_source_line line =
  let lines = !current_query_source_lines in
  if line >= 0 && line < Array.length lines then Some lines.(line) else None

let is_ident_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false

let find_identifier_col line ~from_col name =
  let len = String.length line in
  let name_len = String.length name in
  let rec loop col =
    if col + name_len > len then None
    else if String.sub line col name_len = name
            && (col = 0 || not (is_ident_char line.[col - 1]))
            && (col + name_len = len || not (is_ident_char line.[col + name_len]))
    then Some col
    else loop (col + 1)
  in
  loop (max 0 from_col)

let precise_name_loc ?after_col (fallback_loc : Location.loc) name =
  match query_source_line fallback_loc.start.line with
  | None -> fallback_loc
  | Some line ->
    let from_col = match after_col with Some col -> col | None -> fallback_loc.start.col in
    match find_identifier_col line ~from_col name with
    | None -> fallback_loc
    | Some start_col ->
      {
        fallback_loc with
        start = { fallback_loc.start with col = start_col };
        stop = { fallback_loc.start with col = start_col + String.length name };
      }

let binding_name_loc (b : Ast.binding) =
  precise_name_loc b.loc b.name

let sequential_name_locs fallback_loc names =
  let rec loop after_col acc = function
    | [] -> List.rev acc
    | name :: rest ->
      let loc = precise_name_loc ~after_col fallback_loc name in
      loop loc.stop.col (loc :: acc) rest
  in
  loop fallback_loc.start.col [] names

let precise_name_loc_from_line_start fallback_loc name =
  precise_name_loc ~after_col:0 fallback_loc name

let sequential_name_locs_from after_col fallback_loc names =
  let rec loop after_col acc = function
    | [] -> List.rev acc
    | name :: rest ->
      let loc = precise_name_loc ~after_col fallback_loc name in
      loop loc.stop.col (loc :: acc) rest
  in
  loop after_col [] names

let codec_name_loc (c : Ast.codec_form) =
  precise_name_loc_from_line_start c.loc c.name

let codec_target_type_loc (c : Ast.codec_form) =
  precise_name_loc_from_line_start c.loc c.type_name

let codec_encode_entry_codec_loc (entry : Ast.codec_encode_entry) =
  precise_name_loc_from_line_start entry.loc entry.codec

let codec_decode_field_codec_loc loc codec =
  precise_name_loc_from_line_start loc codec

let codec_decode_field_via_locs loc codec via =
  let codec_loc = codec_decode_field_codec_loc loc codec in
  sequential_name_locs_from codec_loc.stop.col loc via

let codec_cross_check_loc loc checker =
  precise_name_loc_from_line_start loc checker

let capture_name_loc (capture : Ast.capture_form) =
  precise_name_loc_from_line_start capture.loc capture.name

let capture_parser_loc (capture : Ast.capture_form) =
  precise_name_loc_from_line_start capture.loc capture.parser

let capture_checker_loc (capture : Ast.capture_form) checker =
  precise_name_loc_from_line_start capture.loc checker

let find_named_loc defs name =
  List.find_map (fun { bound_name; bound_loc } ->
    if bound_name = name then Some bound_loc else None
  ) defs

let find_named_symbol mk defs name =
  List.find_map (fun { bound_name; bound_loc } ->
    if bound_name = name then Some (mk bound_name bound_loc) else None
  ) defs

let find_term_symbol defs name = find_named_symbol term_symbol defs name
let find_type_symbol defs name = find_named_symbol type_symbol defs name
let find_ctor_symbol defs name = find_named_symbol ctor_symbol defs name

let term_definition_at_precise_loc defs line col loc name =
  let name_loc = precise_name_loc_from_line_start loc name in
  if loc_contains_position name_loc line col then find_named_loc defs name else None

let type_definition_at_precise_loc defs line col loc name =
  let name_loc = precise_name_loc_from_line_start loc name in
  if loc_contains_position name_loc line col then find_named_loc defs name else None

let loc_equal (a : Location.loc) (b : Location.loc) =
  a.file = b.file
  && a.start.line = b.start.line
  && a.start.col = b.start.col
  && a.stop.line = b.stop.line
  && a.stop.col = b.stop.col

let symbol_equal a b =
  a.symbol_kind = b.symbol_kind
  && a.symbol_name = b.symbol_name
  && loc_equal a.symbol_loc b.symbol_loc

let location_list_to_occurrences (locs : Location.loc list) : occurrence_location list =
  let rec go (seen : occurrence_location list) = function
    | [] -> List.rev seen
    | loc :: rest ->
      let occurrence : occurrence_location = location_to_definition loc in
      if List.exists (fun (existing : occurrence_location) ->
        existing.file = occurrence.file
        && existing.line = occurrence.line
        && existing.col = occurrence.col
        && existing.end_line = occurrence.end_line
        && existing.end_col = occurrence.end_col
      ) seen
      then go seen rest
      else go (occurrence :: seen) rest
  in
  go [] locs

let rec find_map_list f = function
  | [] -> None
  | x :: xs ->
    match f x with
    | Some _ as result -> result
    | None -> find_map_list f xs

let rec definition_in_type_expr env line col (te : Ast.type_expr) =
  match te with
  | Ast.TName { name; loc } ->
    let name_loc = precise_name_loc loc name in
    if loc_contains_position name_loc line col then find_named_loc env.type_defs name else None
  | Ast.TVar _ -> None
  | Ast.TApp { head; arg; _ } ->
    (match definition_in_type_expr env line col head with
     | Some _ as result -> result
     | None -> definition_in_type_expr env line col arg)
  | Ast.TFun { dom; cod; _ } ->
    (match definition_in_type_expr env line col dom with
     | Some _ as result -> result
     | None -> definition_in_type_expr env line col cod)
  | Ast.TTuple { elems; _ } ->
    find_map_list (definition_in_type_expr env line col) elems

let definition_in_binding env line col (b : Ast.binding) =
  definition_in_type_expr env line col b.type_expr

let rec definition_in_return_spec env line col (ret : Ast.return_spec) =
  match ret with
  | Ast.RetPlain { ty; _ } -> definition_in_type_expr env line col ty
  | Ast.RetAttached { binding; _ } -> definition_in_binding env line col binding
  | Ast.RetNamedPack { ty; _ } -> definition_in_type_expr env line col ty
  | Ast.RetForAll { elem_ty; _ }
  | Ast.RetMaybeForAll { elem_ty; _ }
  | Ast.RetSetForAll { elem_ty; _ }
  | Ast.RetMaybeSetForAll { elem_ty; _ } ->
    definition_in_type_expr env line col elem_ty
  | Ast.RetForAllDictValues { key_ty; val_ty; _ }
  | Ast.RetForAllDictKeys   { key_ty; val_ty; _ } ->
    (match definition_in_type_expr env line col key_ty with
     | Some _ as r -> r
     | None -> definition_in_type_expr env line col val_ty)
  | Ast.RetMaybeAttached { binding; _ } ->
    definition_in_binding env line col binding
  | Ast.RetExists { binding; body; _ } ->
    (match definition_in_binding env line col binding with
     | Some _ as result -> result
     | None -> definition_in_return_spec env line col body)

let pattern_defs (pat : Ast.pattern) fallback_loc =
  match pat with
  | Ast.PVar name -> [{ bound_name = name; bound_loc = precise_name_loc fallback_loc name }]
  | Ast.PWild | Ast.PNullary _ | Ast.PLit _ -> []
  | Ast.PCon { fields; loc; _ } ->
    let rec collect_vars = function
      | Ast.PVar name -> [name]
      | Ast.PCon { fields; _ } -> List.concat_map (fun (_, sub) -> collect_vars sub) fields
      | _ -> []
    in
    let names = List.concat_map (fun (_, sub) -> collect_vars sub) fields in
    List.map2 (fun name bound_loc -> { bound_name = name; bound_loc }) names (sequential_name_locs loc names)

let extend_locals_with_bindings locals bindings =
  List.rev_append bindings locals

let extend_locals_with_params locals params =
  List.rev_append
    (List.map (fun (b : Ast.binding) -> { bound_name = b.name; bound_loc = binding_name_loc b }) params)
    locals

let rec definition_in_expr env locals line col (expr : Ast.expr) =
  let recurse = definition_in_expr env locals line col in
  match expr with
  | Ast.ELit { lit = Ast.LInterp parts; _ } ->
    find_map_list (function Ast.IExpr e -> recurse e | Ast.ILiteral _ -> None) parts
  | Ast.ELit _ -> None
  | Ast.EVar { name; loc } ->
    let name_loc = precise_name_loc loc name in
    if loc_contains_position name_loc line col then
      match find_named_loc locals name with
      | Some loc -> Some loc
      | None -> find_named_loc env.term_defs name
    else
      None
  | Ast.EField { obj; _ } ->
    definition_in_expr env locals line col obj
  | Ast.EApp { fn; arg; _ } ->
    (match definition_in_expr env locals line col fn with
     | Some _ as result -> result
     | None -> definition_in_expr env locals line col arg)
  | Ast.EBinop { left; right; _ } ->
    (match definition_in_expr env locals line col left with
     | Some _ as result -> result
     | None -> definition_in_expr env locals line col right)
  | Ast.EUnop { arg; _ } ->
    definition_in_expr env locals line col arg
  | Ast.EIf { cond; then_; else_; _ } ->
    (match definition_in_expr env locals line col cond with
     | Some _ as result -> result
     | None ->
       match definition_in_expr env locals line col then_ with
       | Some _ as result -> result
       | None -> definition_in_expr env locals line col else_)
  | Ast.ECase { scrut; arms; _ } ->
    (match definition_in_expr env locals line col scrut with
     | Some _ as result -> result
     | None ->
       find_map_list (fun (arm : Ast.case_arm) ->
         let locals' = extend_locals_with_bindings locals (pattern_defs arm.pattern arm.loc) in
         match arm.guard with
         | Some guard ->
           (match definition_in_expr env locals' line col guard with
            | Some _ as result -> result
            | None -> definition_in_expr env locals' line col arm.body)
         | None -> definition_in_expr env locals' line col arm.body
       ) arms)
  | Ast.ELet { name; declared_type; value; body; loc; declared_proof = _ } ->
    (match declared_type with
     | Some ty ->
       (match definition_in_type_expr env line col ty with
        | Some _ as result -> result
        | None ->
          match definition_in_expr env locals line col value with
          | Some _ as result -> result
          | None ->
            definition_in_expr env ({ bound_name = name; bound_loc = loc } :: locals) line col body)
     | None ->
       match definition_in_expr env locals line col value with
       | Some _ as result -> result
       | None -> definition_in_expr env ({ bound_name = name; bound_loc = loc } :: locals) line col body)
  | Ast.ELetProof { value_name; proof_name; value; body; loc; _ } ->
    (match definition_in_expr env locals line col value with
     | Some _ as result -> result
     | None ->
       definition_in_expr env
         ({ bound_name = proof_name; bound_loc = loc } :: { bound_name = value_name; bound_loc = loc } :: locals)
         line col body)
  | Ast.ERecord { fields; _ } ->
    find_map_list (fun (_, value) -> definition_in_expr env locals line col value) fields
  | Ast.EList { elems; _ } ->
    find_map_list (definition_in_expr env locals line col) elems
  | Ast.EOk { value; _ } ->
    definition_in_expr env locals line col value
  | Ast.EFail { message; _ } ->
    definition_in_expr env locals line col message
  | Ast.ETelemetry { fields; _ } ->
    find_map_list (fun (_, value) -> definition_in_expr env locals line col value) fields
  | Ast.EEnqueue { payload; _ } ->
    definition_in_expr env locals line col payload
  | Ast.EPublish { key; payload; _ } ->
    (match key with
     | Some key ->
       (match definition_in_expr env locals line col key with
        | Some _ as result -> result
        | None ->
          (match payload with
           | Some payload -> definition_in_expr env locals line col payload
           | None -> None))
     | None ->
       (match payload with
        | Some payload -> definition_in_expr env locals line col payload
        | None -> None))
  | Ast.EStartWorkers _ -> None
  | Ast.EWithDatabase { body; _ }
  | Ast.EWithCapabilities { body; _ }
  | Ast.EWithTransaction { body; _ } ->
    definition_in_expr env locals line col body
  | Ast.EServe { port; _ } ->
    definition_in_expr env locals line col port
  | Ast.EConstructor { name; args; loc } ->
    let ctor_loc = precise_name_loc loc name in
    if loc_contains_position ctor_loc line col then
      find_named_loc env.ctor_defs name
    else
      find_map_list (definition_in_expr env locals line col) args
  | Ast.ELambda { params; body; _ } ->
    let result = find_map_list (definition_in_binding env line col) params in
    (match result with
     | Some _ as found -> found
     | None ->
       definition_in_expr env (extend_locals_with_params locals params) line col body)

let rec definition_in_test_stmts env locals line col (stmts : Ast.test_stmt list) =
  match stmts with
  | [] -> None
  | stmt :: rest ->
    let next_locals =
      match stmt with
      | Ast.TsLet { name; loc; _ } -> { bound_name = name; bound_loc = precise_name_loc loc name } :: locals
      | Ast.TsLetProof { value_name; proof_names; loc; _ } ->
        let l = if value_name <> "_" then { bound_name = value_name; bound_loc = precise_name_loc loc value_name } :: locals else locals in
        List.fold_left (fun acc pn -> { bound_name = pn; bound_loc = precise_name_loc loc pn } :: acc) l proof_names
      | _ -> locals
    in
    match definition_in_test_stmt env locals line col stmt with
    | Some _ as result -> result
    | None -> definition_in_test_stmts env next_locals line col rest

and definition_in_test_stmt env locals line col (stmt : Ast.test_stmt) =
  match stmt with
  | Ast.TsLet { declared_type; value; _ } ->
    (match declared_type with
     | Some ty ->
       (match definition_in_type_expr env line col ty with
        | Some _ as result -> result
        | None -> definition_in_expr env locals line col value)
     | None -> definition_in_expr env locals line col value)
  | Ast.TsExpect { left; right; _ } ->
    (match definition_in_expr env locals line col left with
     | Some _ as result -> result
     | None ->
       match right with
       | Some right -> definition_in_expr env locals line col right
       | None -> None)
  | Ast.TsExpectFail { fn; arg; _ }
  | Ast.TsExpectHasProof { fn; arg; _ } ->
    (match definition_in_expr env locals line col fn with
     | Some _ as result -> result
     | None -> definition_in_expr env locals line col arg)
  | Ast.TsProperty { params; body; _ } ->
    let result = find_map_list (fun (param : Ast.property_param) ->
      match definition_in_binding env line col param.binding with
      | Some _ as found -> found
      | None ->
        match param.where_clause with
        | Some guard -> definition_in_expr env locals line col guard
        | None -> None
    ) params in
    (match result with
     | Some _ as found -> found
     | None ->
       definition_in_expr env (extend_locals_with_params locals (List.map (fun (p : Ast.property_param) -> p.binding) params)) line col body)
  | Ast.TsIf { cond; then_stmts; else_stmts; _ } ->
    (match definition_in_expr env locals line col cond with
     | Some _ as result -> result
     | None ->
       match definition_in_test_stmts env locals line col then_stmts with
       | Some _ as result -> result
       | None -> definition_in_test_stmts env locals line col else_stmts)
  | Ast.TsCase { scrut; arms; _ } ->
    (match definition_in_expr env locals line col scrut with
     | Some _ as result -> result
     | None ->
       find_map_list (fun (arm : Ast.ts_case_arm) ->
         let arm_locals = extend_locals_with_bindings locals
           (pattern_defs arm.ts_pattern arm.ts_loc) in
         let guard_result = match arm.ts_guard with
           | Some g -> definition_in_expr env arm_locals line col g
           | None -> None
         in
         match guard_result with
         | Some _ as r -> r
         | None -> definition_in_test_stmts env arm_locals line col arm.ts_body
       ) arms)
  | Ast.TsLetProof { value; _ } ->
    definition_in_expr env locals line col value
  | Ast.TsExpr { e; _ } ->
    definition_in_expr env locals line col e

let definition_in_top_decl env line col (decl : Ast.top_decl) =
  match decl with
  | Ast.DFunc fd ->
    let result = find_map_list (definition_in_binding env line col) fd.params in
    (match result with
     | Some _ as found -> found
     | None ->
       match definition_in_return_spec env line col fd.return_spec with
       | Some _ as found -> found
       | None -> definition_in_expr env (extend_locals_with_params [] fd.params) line col fd.body)
  | Ast.DType (Ast.TypeNewtype { base_type; _ })
  | Ast.DType (Ast.TypeAlias { base_type; _ }) ->
    definition_in_type_expr env line col base_type
  | Ast.DType (Ast.TypeAdt { variants; _ }) ->
    find_map_list (fun (variant : Ast.adt_variant) ->
      find_map_list (fun (field : Ast.field_def) -> definition_in_type_expr env line col field.type_expr) variant.fields
    ) variants
  | Ast.DRecord r ->
    find_map_list (fun (field : Ast.field_def) -> definition_in_type_expr env line col field.type_expr) r.fields
  | Ast.DEntity e ->
    find_map_list (fun (field : Ast.field_def) -> definition_in_type_expr env line col field.type_expr) e.fields
  | Ast.DConst c ->
    definition_in_expr env [] line col c.value
  | Ast.DCapture capture ->
    (match definition_in_binding env line col capture.binding with
     | Some _ as result -> result
     | None ->
       match term_definition_at_precise_loc env.term_defs line col capture.loc capture.parser with
       | Some _ as result -> result
       | None ->
         match capture.checker with
         | Some checker ->
           (match term_definition_at_precise_loc env.term_defs line col capture.loc checker with
            | Some _ as result -> result
            | None -> None)
         | None -> None)
  | Ast.DChannel channel ->
    (match definition_in_type_expr env line col channel.payload with
     | Some _ as result -> result
     | None -> find_map_list (definition_in_binding env line col) channel.key_params)
  | Ast.DApi api ->
    find_map_list (fun (endpoint : Ast.api_endpoint) ->
      let auth_result =
        match endpoint.auth with
        | Some auth -> definition_in_binding env line col auth.binding
        | None -> None
      in
      match auth_result with
      | Some _ as result -> result
      | None ->
        let body_result =
          match endpoint.body with
          | Some binding -> definition_in_binding env line col binding
          | None -> None
        in
        match body_result with
        | Some _ as result -> result
        | None ->
          let capture_result =
            find_map_list (fun (capture : Ast.api_capture) -> definition_in_binding env line col capture.binding) endpoint.captures
          in
          match capture_result with
          | Some _ as result -> result
          | None -> definition_in_return_spec env line col endpoint.return_spec
    ) api.endpoints
  | Ast.DTest test ->
    definition_in_test_stmts env [] line col test.stmts
  | Ast.DApiTest test ->
    (match find_map_list (definition_in_expr env [] line col) test.seed_stmts with
     | Some _ as result -> result
     | None -> definition_in_test_stmts env [] line col test.stmts)
  | Ast.DLoadTest test ->
    find_map_list (definition_in_expr env [] line col) test.seed_stmts
  | Ast.DCodec c ->
    let to_json_result =
      match c.to_json with
      | Ast.ToJsonForbidden | Ast.ToJsonAdt -> None
      | Ast.ToJsonFields entries ->
        find_map_list (fun (entry : Ast.codec_encode_entry) ->
          term_definition_at_precise_loc env.term_defs line col entry.loc entry.codec
        ) entries
    in
    (match to_json_result with
     | Some _ as result -> result
     | None ->
       let from_json_result =
         match c.from_json with
         | Ast.FromJsonForbidden | Ast.FromJsonAdt -> None
         | Ast.FromJsonAlts alts ->
           find_map_list (fun (alt : Ast.codec_decode_alt) ->
             find_map_list (function
               | Ast.DecodeField { codec; via; loc; _ } ->
                 (match term_definition_at_precise_loc env.term_defs line col loc codec with
                  | Some _ as result -> result
                  | None ->
                    let via_locs = codec_decode_field_via_locs loc codec via in
                    let rec find_via names locs =
                      match names, locs with
                      | name :: names', loc :: locs' ->
                        (match term_definition_at_precise_loc env.term_defs line col loc name with
                         | Some _ as result -> result
                         | None -> find_via names' locs')
                      | _ -> None
                    in
                    find_via via via_locs)
               | Ast.DecodeCrossCheck { checker; loc } ->
                 term_definition_at_precise_loc env.term_defs line col loc checker
               | Ast.DecodeDefault _ -> None
             ) alt
           ) alts
       in
       match from_json_result with
       | Some _ as result -> result
       | None ->
         match type_definition_at_precise_loc env.type_defs line col c.loc c.type_name with
         | Some _ as result -> result
         | None -> None)
  | Ast.DDatabase _ | Ast.DCapability _ | Ast.DQueue _
  | Ast.DWorkers _ | Ast.DServer _ | Ast.DFact _ -> None

let collect_definition_env (m : Ast.module_form) =
  List.fold_left (fun env decl ->
    match decl with
    | Ast.DFunc fd -> add_term_def env fd.name (precise_name_loc fd.loc fd.name)
    | Ast.DType (Ast.TypeNewtype { name; loc; _ })
    | Ast.DType (Ast.TypeAlias { name; loc; _ }) ->
      add_type_def env name (precise_name_loc loc name)
    | Ast.DType (Ast.TypeAdt { name; params = _; variants; loc }) ->
      let env = add_type_def env name (precise_name_loc loc name) in
      List.fold_left (fun env (variant : Ast.adt_variant) -> add_ctor_def env variant.ctor (precise_name_loc variant.loc variant.ctor)) env variants
    | Ast.DRecord r -> add_type_def env r.name (precise_name_loc r.loc r.name)
    | Ast.DEntity e -> add_type_def env e.name (precise_name_loc e.loc e.name)
    | Ast.DCodec c -> add_term_def env c.name (codec_name_loc c)
    | Ast.DDatabase d -> add_term_def env d.name (precise_name_loc d.loc d.name)
    | Ast.DCapability c -> add_term_def env c.name (precise_name_loc c.loc c.name)
    | Ast.DConst c -> add_term_def env c.name (precise_name_loc c.loc c.name)
    | Ast.DQueue q -> add_term_def env q.name (precise_name_loc q.loc q.name)
    | Ast.DChannel c -> add_term_def env c.name (precise_name_loc c.loc c.name)
    | Ast.DWorkers w -> add_term_def env w.name (precise_name_loc w.loc w.name)
    | Ast.DCapture c -> add_term_def env c.name (precise_name_loc c.loc c.name)
    | Ast.DApi a -> add_term_def env a.name (precise_name_loc a.loc a.name)
    | Ast.DServer s -> add_term_def env s.name (precise_name_loc s.loc s.name)
    | Ast.DTest _ | Ast.DApiTest _ | Ast.DLoadTest _ | Ast.DFact _ -> env
  ) empty_definition_env m.decls

let definition_source filename source line col =
  set_query_source_lines source;
  match parse_module filename source with
  | Err _ -> None
  | Ok m ->
    let env = collect_definition_env m in
    find_map_list (definition_in_top_decl env line col) m.decls
    |> Option.map location_to_definition

let definition_file filename line col =
  let source = In_channel.with_open_text filename In_channel.input_all in
  definition_source filename source line col

let resolve_term_symbol locals env name =
  match find_term_symbol locals name with
  | Some symbol -> Some symbol
  | None -> find_term_symbol env.term_defs name

let resolve_term_symbol_at_precise_loc locals env line col loc name =
  let name_loc = precise_name_loc_from_line_start loc name in
  if loc_contains_position name_loc line col then resolve_term_symbol locals env name else None

let resolve_type_symbol_at_precise_loc env line col loc name =
  let name_loc = precise_name_loc_from_line_start loc name in
  if loc_contains_position name_loc line col then find_type_symbol env.type_defs name else None

let term_occurrence_at_precise_loc locals env target loc name =
  let name_loc = precise_name_loc_from_line_start loc name in
  match resolve_term_symbol locals env name with
  | Some symbol when symbol_equal symbol target -> [name_loc]
  | _ -> []

let type_occurrence_at_precise_loc env target loc name =
  let name_loc = precise_name_loc_from_line_start loc name in
  match find_type_symbol env.type_defs name with
  | Some symbol when symbol_equal symbol target -> [name_loc]
  | _ -> []

let rec resolve_symbol_in_type_expr env line col (te : Ast.type_expr) =
  match te with
  | Ast.TName { name; loc } ->
    let name_loc = precise_name_loc loc name in
    if loc_contains_position name_loc line col then find_type_symbol env.type_defs name else None
  | Ast.TVar _ -> None
  | Ast.TApp { head; arg; _ } ->
    (match resolve_symbol_in_type_expr env line col head with
     | Some _ as result -> result
     | None -> resolve_symbol_in_type_expr env line col arg)
  | Ast.TFun { dom; cod; _ } ->
    (match resolve_symbol_in_type_expr env line col dom with
     | Some _ as result -> result
     | None -> resolve_symbol_in_type_expr env line col cod)
  | Ast.TTuple { elems; _ } ->
    find_map_list (resolve_symbol_in_type_expr env line col) elems

let resolve_symbol_in_binding env line col (b : Ast.binding) =
  let name_loc = binding_name_loc b in
  match resolve_symbol_in_type_expr env line col b.type_expr with
  | Some _ as result -> result
  | None -> if loc_contains_position name_loc line col then Some (term_symbol b.name name_loc) else None

let rec resolve_symbol_in_return_spec env line col (ret : Ast.return_spec) =
  match ret with
  | Ast.RetPlain { ty; _ } -> resolve_symbol_in_type_expr env line col ty
  | Ast.RetAttached { binding; _ } -> resolve_symbol_in_binding env line col binding
  | Ast.RetNamedPack { ty; _ } -> resolve_symbol_in_type_expr env line col ty
  | Ast.RetForAll { elem_ty; _ }
  | Ast.RetMaybeForAll { elem_ty; _ }
  | Ast.RetSetForAll { elem_ty; _ }
  | Ast.RetMaybeSetForAll { elem_ty; _ } -> resolve_symbol_in_type_expr env line col elem_ty
  | Ast.RetForAllDictValues { key_ty; val_ty; _ }
  | Ast.RetForAllDictKeys   { key_ty; val_ty; _ } ->
    (match resolve_symbol_in_type_expr env line col key_ty with
     | Some _ as r -> r
     | None -> resolve_symbol_in_type_expr env line col val_ty)
  | Ast.RetMaybeAttached { binding; _ } ->
    resolve_symbol_in_binding env line col binding
  | Ast.RetExists { binding; body; _ } ->
    (match resolve_symbol_in_binding env line col binding with
     | Some _ as result -> result
     | None -> resolve_symbol_in_return_spec env line col body)

let resolve_symbol_in_pattern env line col (pat : Ast.pattern) =
  match pat with
  | Ast.PNullary { ctor; loc }
  | Ast.PCon { ctor; loc; _ } ->
    let ctor_loc = precise_name_loc loc ctor in
    if loc_contains_position ctor_loc line col then find_ctor_symbol env.ctor_defs ctor else None
  | Ast.PVar _ | Ast.PWild | Ast.PLit _ -> None

let rec resolve_symbol_in_expr env locals line col (expr : Ast.expr) =
  let recurse = resolve_symbol_in_expr env locals line col in
  match expr with
  | Ast.ELit { lit = Ast.LInterp parts; _ } ->
    find_map_list (function Ast.IExpr e -> recurse e | Ast.ILiteral _ -> None) parts
  | Ast.ELit _ -> None
  | Ast.EVar { name; loc } ->
    let name_loc = precise_name_loc loc name in
    if loc_contains_position name_loc line col then resolve_term_symbol locals env name else None
  | Ast.EField { obj; _ } -> resolve_symbol_in_expr env locals line col obj
  | Ast.EApp { fn; arg; _ } ->
    (match resolve_symbol_in_expr env locals line col fn with
     | Some _ as result -> result
     | None -> resolve_symbol_in_expr env locals line col arg)
  | Ast.EBinop { left; right; _ } ->
    (match resolve_symbol_in_expr env locals line col left with
     | Some _ as result -> result
     | None -> resolve_symbol_in_expr env locals line col right)
  | Ast.EUnop { arg; _ } -> resolve_symbol_in_expr env locals line col arg
  | Ast.EIf { cond; then_; else_; _ } ->
    (match resolve_symbol_in_expr env locals line col cond with
     | Some _ as result -> result
     | None ->
       match resolve_symbol_in_expr env locals line col then_ with
       | Some _ as result -> result
       | None -> resolve_symbol_in_expr env locals line col else_)
  | Ast.ECase { scrut; arms; _ } ->
    (match resolve_symbol_in_expr env locals line col scrut with
     | Some _ as result -> result
     | None ->
       find_map_list (fun (arm : Ast.case_arm) ->
         let locals' = extend_locals_with_bindings locals (pattern_defs arm.pattern arm.loc) in
         match resolve_symbol_in_pattern env line col arm.pattern with
         | Some _ as result -> result
         | None ->
           match arm.guard with
           | Some guard ->
             (match resolve_symbol_in_expr env locals' line col guard with
              | Some _ as result -> result
              | None -> resolve_symbol_in_expr env locals' line col arm.body)
           | None -> resolve_symbol_in_expr env locals' line col arm.body
       ) arms)
  | Ast.ELet { name; declared_type; value; body; loc; declared_proof = _ } ->
    let name_loc = precise_name_loc loc name in
    (match declared_type with
     | Some ty ->
       (match resolve_symbol_in_type_expr env line col ty with
        | Some _ as result -> result
        | None ->
          match resolve_symbol_in_expr env locals line col value with
          | Some _ as result -> result
          | None ->
            match resolve_symbol_in_expr env ({ bound_name = name; bound_loc = name_loc } :: locals) line col body with
            | Some _ as result -> result
            | None -> if loc_contains_position name_loc line col then Some (term_symbol name name_loc) else None)
     | None ->
       match resolve_symbol_in_expr env locals line col value with
       | Some _ as result -> result
       | None ->
         match resolve_symbol_in_expr env ({ bound_name = name; bound_loc = name_loc } :: locals) line col body with
         | Some _ as result -> result
         | None -> if loc_contains_position name_loc line col then Some (term_symbol name name_loc) else None)
  | Ast.ELetProof { value_name; proof_name; value; body; loc; _ } ->
    let value_loc, proof_loc =
      match sequential_name_locs loc [value_name; proof_name] with
      | [value_loc; proof_loc] -> (value_loc, proof_loc)
      | _ -> (precise_name_loc loc value_name, precise_name_loc ~after_col:(precise_name_loc loc value_name).stop.col loc proof_name)
    in
    (match resolve_symbol_in_expr env locals line col value with
     | Some _ as result -> result
     | None ->
       resolve_symbol_in_expr env
         ({ bound_name = proof_name; bound_loc = proof_loc } :: { bound_name = value_name; bound_loc = value_loc } :: locals)
         line col body)
  | Ast.ERecord { fields; _ } ->
    find_map_list (fun (_, value) -> resolve_symbol_in_expr env locals line col value) fields
  | Ast.EList { elems; _ } -> find_map_list (resolve_symbol_in_expr env locals line col) elems
  | Ast.EOk { value; _ } -> resolve_symbol_in_expr env locals line col value
  | Ast.EFail { message; _ } -> resolve_symbol_in_expr env locals line col message
  | Ast.ETelemetry { fields; _ } ->
    find_map_list (fun (_, value) -> resolve_symbol_in_expr env locals line col value) fields
  | Ast.EEnqueue { payload; _ } -> resolve_symbol_in_expr env locals line col payload
  | Ast.EPublish { key; payload; _ } ->
    (match key with
     | Some key ->
       (match resolve_symbol_in_expr env locals line col key with
        | Some _ as result -> result
        | None ->
          (match payload with
           | Some payload -> resolve_symbol_in_expr env locals line col payload
           | None -> None))
     | None ->
       (match payload with
        | Some payload -> resolve_symbol_in_expr env locals line col payload
        | None -> None))
  | Ast.EStartWorkers _ -> None
  | Ast.EWithDatabase { body; _ }
  | Ast.EWithCapabilities { body; _ }
  | Ast.EWithTransaction { body; _ } -> resolve_symbol_in_expr env locals line col body
  | Ast.EServe { port; _ } -> resolve_symbol_in_expr env locals line col port
  | Ast.EConstructor { name; args; loc } ->
    let ctor_loc = precise_name_loc loc name in
    if loc_contains_position ctor_loc line col then find_ctor_symbol env.ctor_defs name
    else find_map_list (resolve_symbol_in_expr env locals line col) args
  | Ast.ELambda { params; body; _ } ->
    let result = find_map_list (resolve_symbol_in_binding env line col) params in
    (match result with
     | Some _ as found -> found
     | None -> resolve_symbol_in_expr env (extend_locals_with_params locals params) line col body)

let rec resolve_symbol_in_test_stmts env locals line col (stmts : Ast.test_stmt list) =
  match stmts with
  | [] -> None
  | stmt :: rest ->
    let next_locals =
      match stmt with
      | Ast.TsLet { name; loc; _ } -> { bound_name = name; bound_loc = precise_name_loc loc name } :: locals
      | _ -> locals
    in
    match resolve_symbol_in_test_stmt env locals line col stmt with
    | Some _ as result -> result
    | None -> resolve_symbol_in_test_stmts env next_locals line col rest

and resolve_symbol_in_test_stmt env locals line col (stmt : Ast.test_stmt) =
  match stmt with
  | Ast.TsLet { name; declared_type; value; loc; _ } ->
    let name_loc = precise_name_loc loc name in
    (match declared_type with
     | Some ty ->
       (match resolve_symbol_in_type_expr env line col ty with
        | Some _ as result -> result
        | None ->
          match resolve_symbol_in_expr env locals line col value with
          | Some _ as result -> result
          | None -> if loc_contains_position name_loc line col then Some (term_symbol name name_loc) else None)
     | None ->
       match resolve_symbol_in_expr env locals line col value with
       | Some _ as result -> result
       | None -> if loc_contains_position name_loc line col then Some (term_symbol name name_loc) else None)
  | Ast.TsExpect { left; right; _ } ->
    (match resolve_symbol_in_expr env locals line col left with
     | Some _ as result -> result
     | None ->
       match right with
       | Some right -> resolve_symbol_in_expr env locals line col right
       | None -> None)
  | Ast.TsExpectFail { fn; arg; _ }
  | Ast.TsExpectHasProof { fn; arg; _ } ->
    (match resolve_symbol_in_expr env locals line col fn with
     | Some _ as result -> result
     | None -> resolve_symbol_in_expr env locals line col arg)
  | Ast.TsProperty { params; body; _ } ->
    let result = find_map_list (fun (param : Ast.property_param) ->
      match resolve_symbol_in_binding env line col param.binding with
      | Some _ as found -> found
      | None ->
        match param.where_clause with
        | Some guard -> resolve_symbol_in_expr env locals line col guard
        | None -> None
    ) params in
    (match result with
     | Some _ as found -> found
     | None ->
       resolve_symbol_in_expr env (extend_locals_with_params locals (List.map (fun (p : Ast.property_param) -> p.binding) params)) line col body)
  | Ast.TsIf { cond; then_stmts; else_stmts; _ } ->
    (match resolve_symbol_in_expr env locals line col cond with
     | Some _ as result -> result
     | None ->
       match resolve_symbol_in_test_stmts env locals line col then_stmts with
       | Some _ as result -> result
       | None -> resolve_symbol_in_test_stmts env locals line col else_stmts)
  | Ast.TsCase { scrut; arms; _ } ->
    (match resolve_symbol_in_expr env locals line col scrut with
     | Some _ as result -> result
     | None ->
       find_map_list (fun (arm : Ast.ts_case_arm) ->
         let arm_locals = extend_locals_with_bindings locals
           (pattern_defs arm.ts_pattern arm.ts_loc) in
         let guard_result = match arm.ts_guard with
           | Some g -> resolve_symbol_in_expr env arm_locals line col g
           | None -> None
         in
         match guard_result with
         | Some _ as r -> r
         | None -> resolve_symbol_in_test_stmts env arm_locals line col arm.ts_body
       ) arms)
  | Ast.TsLetProof { value; _ } ->
    resolve_symbol_in_expr env locals line col value
  | Ast.TsExpr { e; _ } -> resolve_symbol_in_expr env locals line col e

let resolve_symbol_in_top_decl env line col (decl : Ast.top_decl) =
  match decl with
  | Ast.DFunc fd ->
    let name_loc = precise_name_loc fd.loc fd.name in
    let result = find_map_list (resolve_symbol_in_binding env line col) fd.params in
    (match result with
     | Some _ as found -> found
     | None ->
       match resolve_symbol_in_return_spec env line col fd.return_spec with
       | Some _ as found -> found
       | None ->
         match resolve_symbol_in_expr env (extend_locals_with_params [] fd.params) line col fd.body with
         | Some _ as found -> found
         | None -> if loc_contains_position name_loc line col then Some (term_symbol fd.name name_loc) else None)
  | Ast.DType (Ast.TypeNewtype { name; base_type; loc })
  | Ast.DType (Ast.TypeAlias { name; base_type; loc }) ->
    let name_loc = precise_name_loc loc name in
    (match resolve_symbol_in_type_expr env line col base_type with
     | Some _ as result -> result
     | None -> if loc_contains_position name_loc line col then Some (type_symbol name name_loc) else None)
  | Ast.DType (Ast.TypeAdt { name; params = _; variants; loc }) ->
    let name_loc = precise_name_loc loc name in
    (match find_map_list (fun (variant : Ast.adt_variant) ->
       let ctor_loc = precise_name_loc variant.loc variant.ctor in
       match find_map_list (fun (field : Ast.field_def) -> resolve_symbol_in_type_expr env line col field.type_expr) variant.fields with
       | Some _ as result -> result
       | None -> if loc_contains_position ctor_loc line col then Some (ctor_symbol variant.ctor ctor_loc) else None
     ) variants with
     | Some _ as result -> result
     | None -> if loc_contains_position name_loc line col then Some (type_symbol name name_loc) else None)
  | Ast.DRecord r ->
    let name_loc = precise_name_loc r.loc r.name in
    (match find_map_list (fun (field : Ast.field_def) -> resolve_symbol_in_type_expr env line col field.type_expr) r.fields with
     | Some _ as result -> result
     | None -> if loc_contains_position name_loc line col then Some (type_symbol r.name name_loc) else None)
  | Ast.DEntity e ->
    let name_loc = precise_name_loc e.loc e.name in
    (match find_map_list (fun (field : Ast.field_def) -> resolve_symbol_in_type_expr env line col field.type_expr) e.fields with
     | Some _ as result -> result
     | None -> if loc_contains_position name_loc line col then Some (type_symbol e.name name_loc) else None)
  | Ast.DConst c ->
    (match resolve_symbol_in_expr env [] line col c.value with
     | Some _ as result -> result
     | None -> let name_loc = precise_name_loc c.loc c.name in if loc_contains_position name_loc line col then Some (term_symbol c.name name_loc) else None)
  | Ast.DCapture capture ->
    (match resolve_symbol_in_binding env line col capture.binding with
     | Some _ as result -> result
     | None ->
       (match resolve_term_symbol_at_precise_loc [] env line col capture.loc capture.parser with
        | Some _ as result -> result
        | None ->
          match capture.checker with
          | Some checker ->
            (match resolve_term_symbol_at_precise_loc [] env line col capture.loc checker with
             | Some _ as result -> result
             | None -> let name_loc = capture_name_loc capture in if loc_contains_position name_loc line col then Some (term_symbol capture.name name_loc) else None)
          | None -> let name_loc = capture_name_loc capture in if loc_contains_position name_loc line col then Some (term_symbol capture.name name_loc) else None))
  | Ast.DChannel channel ->
    (match resolve_symbol_in_type_expr env line col channel.payload with
     | Some _ as result -> result
     | None ->
       match find_map_list (resolve_symbol_in_binding env line col) channel.key_params with
       | Some _ as result -> result
       | None -> let name_loc = precise_name_loc channel.loc channel.name in if loc_contains_position name_loc line col then Some (term_symbol channel.name name_loc) else None)
  | Ast.DApi api ->
    (match find_map_list (fun (endpoint : Ast.api_endpoint) ->
       let auth_result =
         match endpoint.auth with
         | Some auth -> resolve_symbol_in_binding env line col auth.binding
         | None -> None
       in
       match auth_result with
       | Some _ as result -> result
       | None ->
         let body_result =
           match endpoint.body with
           | Some binding -> resolve_symbol_in_binding env line col binding
           | None -> None
         in
         match body_result with
         | Some _ as result -> result
         | None ->
           let capture_result =
             find_map_list (fun (capture : Ast.api_capture) -> resolve_symbol_in_binding env line col capture.binding) endpoint.captures
           in
           match capture_result with
           | Some _ as result -> result
           | None -> resolve_symbol_in_return_spec env line col endpoint.return_spec
     ) api.endpoints with
     | Some _ as result -> result
     | None -> let name_loc = precise_name_loc api.loc api.name in if loc_contains_position name_loc line col then Some (term_symbol api.name name_loc) else None)
  | Ast.DTest test -> resolve_symbol_in_test_stmts env [] line col test.stmts
  | Ast.DApiTest test ->
    (match find_map_list (resolve_symbol_in_expr env [] line col) test.seed_stmts with
     | Some _ as result -> result
     | None -> resolve_symbol_in_test_stmts env [] line col test.stmts)
  | Ast.DLoadTest test ->
    (match find_map_list (resolve_symbol_in_expr env [] line col) test.seed_stmts with
     | Some _ as result -> result
     | None -> resolve_symbol_in_test_stmts env [] line col test.request_stmts)
  | Ast.DCodec c ->
    let to_json_result =
      match c.to_json with
      | Ast.ToJsonForbidden | Ast.ToJsonAdt -> None
      | Ast.ToJsonFields entries ->
        find_map_list (fun (entry : Ast.codec_encode_entry) ->
          resolve_term_symbol_at_precise_loc [] env line col entry.loc entry.codec
        ) entries
    in
    (match to_json_result with
     | Some _ as result -> result
     | None ->
       let from_json_result =
         match c.from_json with
         | Ast.FromJsonForbidden | Ast.FromJsonAdt -> None
         | Ast.FromJsonAlts alts ->
           find_map_list (fun (alt : Ast.codec_decode_alt) ->
             find_map_list (function
               | Ast.DecodeField { codec; via; loc; _ } ->
                 (match resolve_term_symbol_at_precise_loc [] env line col loc codec with
                  | Some _ as result -> result
                  | None ->
                    let via_locs = codec_decode_field_via_locs loc codec via in
                    let rec find_via names locs =
                      match names, locs with
                      | name :: names', loc :: locs' ->
                        (match resolve_term_symbol_at_precise_loc [] env line col loc name with
                         | Some _ as result -> result
                         | None -> find_via names' locs')
                      | _ -> None
                    in
                    find_via via via_locs)
               | Ast.DecodeCrossCheck { checker; loc } ->
                 resolve_term_symbol_at_precise_loc [] env line col loc checker
               | Ast.DecodeDefault _ -> None
             ) alt
           ) alts
       in
       match from_json_result with
       | Some _ as result -> result
       | None ->
         (match resolve_type_symbol_at_precise_loc env line col c.loc c.type_name with
          | Some _ as result -> result
          | None -> let name_loc = codec_name_loc c in if loc_contains_position name_loc line col then Some (term_symbol c.name name_loc) else None))
  | Ast.DDatabase d -> let name_loc = precise_name_loc d.loc d.name in if loc_contains_position name_loc line col then Some (term_symbol d.name name_loc) else None
  | Ast.DCapability c -> let name_loc = precise_name_loc c.loc c.name in if loc_contains_position name_loc line col then Some (term_symbol c.name name_loc) else None
  | Ast.DQueue q -> let name_loc = precise_name_loc q.loc q.name in if loc_contains_position name_loc line col then Some (term_symbol q.name name_loc) else None
  | Ast.DWorkers w -> let name_loc = precise_name_loc w.loc w.name in if loc_contains_position name_loc line col then Some (term_symbol w.name name_loc) else None
  | Ast.DServer s -> let name_loc = precise_name_loc s.loc s.name in if loc_contains_position name_loc line col then Some (term_symbol s.name name_loc) else None
  | Ast.DFact f -> let name_loc = precise_name_loc f.loc f.name in if loc_contains_position name_loc line col then Some (type_symbol f.name name_loc) else None

let rec collect_occurrences_in_type_expr env target (te : Ast.type_expr) =
  match te with
  | Ast.TName { name; loc } ->
    let name_loc = precise_name_loc loc name in
    (match find_type_symbol env.type_defs name with
     | Some symbol when symbol_equal symbol target -> [name_loc]
     | _ -> [])
  | Ast.TVar _ -> []
  | Ast.TApp { head; arg; _ } -> collect_occurrences_in_type_expr env target head @ collect_occurrences_in_type_expr env target arg
  | Ast.TFun { dom; cod; _ } -> collect_occurrences_in_type_expr env target dom @ collect_occurrences_in_type_expr env target cod
  | Ast.TTuple { elems; _ } -> List.concat_map (collect_occurrences_in_type_expr env target) elems

let collect_occurrences_in_binding env target (b : Ast.binding) =
  let name_loc = binding_name_loc b in
  let def_occ = if symbol_equal (term_symbol b.name name_loc) target then [name_loc] else [] in
  def_occ @ collect_occurrences_in_type_expr env target b.type_expr

let collect_occurrence_pattern_defs target bindings =
  List.filter_map (fun { bound_name; bound_loc } ->
    if symbol_equal (term_symbol bound_name bound_loc) target then Some bound_loc else None
    ) bindings

let collect_occurrences_in_pattern env target (pat : Ast.pattern) =
  match pat with
  | Ast.PNullary { ctor; loc }
  | Ast.PCon { ctor; loc; _ } ->
    let ctor_loc = precise_name_loc loc ctor in
    let ctor_occ =
      match find_ctor_symbol env.ctor_defs ctor with
      | Some symbol when symbol_equal symbol target -> [ctor_loc]
      | _ -> []
    in
    ctor_occ
  | Ast.PVar _ | Ast.PWild | Ast.PLit _ -> []

let rec collect_occurrences_in_expr env locals target (expr : Ast.expr) =
  let recurse = collect_occurrences_in_expr env locals target in
  match expr with
  | Ast.ELit { lit = Ast.LInterp parts; _ } ->
    List.concat_map (function Ast.IExpr e -> recurse e | Ast.ILiteral _ -> []) parts
  | Ast.ELit _ -> []
  | Ast.EVar { name; loc } ->
    let name_loc = precise_name_loc loc name in
    (match resolve_term_symbol locals env name with
     | Some symbol when symbol_equal symbol target -> [name_loc]
     | _ -> [])
  | Ast.EField { obj; _ } -> collect_occurrences_in_expr env locals target obj
  | Ast.EApp { fn; arg; _ } -> collect_occurrences_in_expr env locals target fn @ collect_occurrences_in_expr env locals target arg
  | Ast.EBinop { left; right; _ } -> collect_occurrences_in_expr env locals target left @ collect_occurrences_in_expr env locals target right
  | Ast.EUnop { arg; _ } -> collect_occurrences_in_expr env locals target arg
  | Ast.EIf { cond; then_; else_; _ } ->
    collect_occurrences_in_expr env locals target cond
    @ collect_occurrences_in_expr env locals target then_
    @ collect_occurrences_in_expr env locals target else_
  | Ast.ECase { scrut; arms; _ } ->
    collect_occurrences_in_expr env locals target scrut
    @ List.concat_map (fun (arm : Ast.case_arm) ->
        let bindings = pattern_defs arm.pattern arm.loc in
        let locals' = extend_locals_with_bindings locals bindings in
        collect_occurrences_in_pattern env target arm.pattern
        @ collect_occurrence_pattern_defs target bindings
        @ (match arm.guard with
           | Some guard -> collect_occurrences_in_expr env locals' target guard
           | None -> [])
        @ collect_occurrences_in_expr env locals' target arm.body
      ) arms
  | Ast.ELet { name; declared_type; value; body; loc; declared_proof = _ } ->
    let name_loc = precise_name_loc loc name in
    (if symbol_equal (term_symbol name name_loc) target then [name_loc] else [])
    @ (match declared_type with
       | Some ty -> collect_occurrences_in_type_expr env target ty
       | None -> [])
    @ collect_occurrences_in_expr env locals target value
    @ collect_occurrences_in_expr env ({ bound_name = name; bound_loc = name_loc } :: locals) target body
  | Ast.ELetProof { value_name; proof_name; value; body; loc; _ } ->
    let value_loc, proof_loc =
      match sequential_name_locs loc [value_name; proof_name] with
      | [value_loc; proof_loc] -> (value_loc, proof_loc)
      | _ -> (precise_name_loc loc value_name, precise_name_loc ~after_col:(precise_name_loc loc value_name).stop.col loc proof_name)
    in
    (if symbol_equal (term_symbol value_name value_loc) target then [value_loc] else [])
    @ (if symbol_equal (term_symbol proof_name proof_loc) target then [proof_loc] else [])
    @ collect_occurrences_in_expr env locals target value
    @ collect_occurrences_in_expr env ({ bound_name = proof_name; bound_loc = proof_loc } :: { bound_name = value_name; bound_loc = value_loc } :: locals) target body
  | Ast.ERecord { fields; _ } -> List.concat_map (fun (_, value) -> collect_occurrences_in_expr env locals target value) fields
  | Ast.EList { elems; _ } -> List.concat_map (collect_occurrences_in_expr env locals target) elems
  | Ast.EOk { value; _ } -> collect_occurrences_in_expr env locals target value
  | Ast.EFail { message; _ } -> collect_occurrences_in_expr env locals target message
  | Ast.ETelemetry { fields; _ } -> List.concat_map (fun (_, value) -> collect_occurrences_in_expr env locals target value) fields
  | Ast.EEnqueue { payload; _ } -> collect_occurrences_in_expr env locals target payload
  | Ast.EPublish { key; payload; _ } ->
    (match key with Some key -> collect_occurrences_in_expr env locals target key | None -> [])
    @ (match payload with Some payload -> collect_occurrences_in_expr env locals target payload | None -> [])
  | Ast.EStartWorkers _ -> []
  | Ast.EWithDatabase { body; _ }
  | Ast.EWithCapabilities { body; _ }
  | Ast.EWithTransaction { body; _ } -> collect_occurrences_in_expr env locals target body
  | Ast.EServe { port; _ } -> collect_occurrences_in_expr env locals target port
  | Ast.EConstructor { name; args; loc } ->
    (match find_ctor_symbol env.ctor_defs name with
     | Some symbol when symbol_equal symbol target -> loc :: List.concat_map (collect_occurrences_in_expr env locals target) args
     | _ -> List.concat_map (collect_occurrences_in_expr env locals target) args)
  | Ast.ELambda { params; body; _ } ->
    List.concat_map (collect_occurrences_in_binding env target) params
    @ collect_occurrences_in_expr env (extend_locals_with_params locals params) target body

let rec collect_occurrences_in_test_stmts env locals target (stmts : Ast.test_stmt list) =
  match stmts with
  | [] -> []
  | stmt :: rest ->
    let next_locals =
      match stmt with
      | Ast.TsLet { name; loc; _ } -> { bound_name = name; bound_loc = loc } :: locals
      | _ -> locals
    in
    collect_occurrences_in_test_stmt env locals target stmt
    @ collect_occurrences_in_test_stmts env next_locals target rest

and collect_occurrences_in_test_stmt env locals target (stmt : Ast.test_stmt) =
  match stmt with
  | Ast.TsLet { name; declared_type; value; loc; _ } ->
    let name_loc = precise_name_loc loc name in
    (if symbol_equal (term_symbol name name_loc) target then [name_loc] else [])
    @ (match declared_type with Some ty -> collect_occurrences_in_type_expr env target ty | None -> [])
    @ collect_occurrences_in_expr env locals target value
  | Ast.TsExpect { left; right; _ } ->
    collect_occurrences_in_expr env locals target left
    @ (match right with Some right -> collect_occurrences_in_expr env locals target right | None -> [])
  | Ast.TsExpectFail { fn; arg; _ }
  | Ast.TsExpectHasProof { fn; arg; _ } ->
    collect_occurrences_in_expr env locals target fn @ collect_occurrences_in_expr env locals target arg
  | Ast.TsProperty { params; body; _ } ->
    List.concat_map (fun (param : Ast.property_param) ->
      collect_occurrences_in_binding env target param.binding
      @ (match param.where_clause with Some guard -> collect_occurrences_in_expr env locals target guard | None -> [])
    ) params
    @ collect_occurrences_in_expr env (extend_locals_with_params locals (List.map (fun (p : Ast.property_param) -> p.binding) params)) target body
  | Ast.TsIf { cond; then_stmts; else_stmts; _ } ->
    collect_occurrences_in_expr env locals target cond
    @ collect_occurrences_in_test_stmts env locals target then_stmts
    @ collect_occurrences_in_test_stmts env locals target else_stmts
  | Ast.TsCase { scrut; arms; _ } ->
    collect_occurrences_in_expr env locals target scrut
    @ List.concat_map (fun (arm : Ast.ts_case_arm) ->
        let arm_locals = extend_locals_with_bindings locals
          (pattern_defs arm.ts_pattern arm.ts_loc) in
        (match arm.ts_guard with
         | Some g -> collect_occurrences_in_expr env arm_locals target g
         | None -> [])
        @ collect_occurrences_in_test_stmts env arm_locals target arm.ts_body
      ) arms
  | Ast.TsLetProof { value; _ } ->
    collect_occurrences_in_expr env locals target value
  | Ast.TsExpr { e; _ } -> collect_occurrences_in_expr env locals target e

let rec collect_occurrences_in_top_decl env target (decl : Ast.top_decl) =
  match decl with
  | Ast.DFunc fd ->
    let name_loc = precise_name_loc fd.loc fd.name in
    (if symbol_equal (term_symbol fd.name name_loc) target then [name_loc] else [])
    @ List.concat_map (collect_occurrences_in_binding env target) fd.params
    @ collect_occurrences_in_return_spec env target fd.return_spec
    @ collect_occurrences_in_expr env (extend_locals_with_params [] fd.params) target fd.body
  | Ast.DType (Ast.TypeNewtype { name; base_type; loc })
  | Ast.DType (Ast.TypeAlias { name; base_type; loc }) ->
    let name_loc = precise_name_loc loc name in
    (if symbol_equal (type_symbol name name_loc) target then [name_loc] else [])
    @ collect_occurrences_in_type_expr env target base_type
  | Ast.DType (Ast.TypeAdt { name; params = _; variants; loc }) ->
    let name_loc = precise_name_loc loc name in
    (if symbol_equal (type_symbol name name_loc) target then [name_loc] else [])
    @ List.concat_map (fun (variant : Ast.adt_variant) ->
         let ctor_loc = precise_name_loc variant.loc variant.ctor in
         (if symbol_equal (ctor_symbol variant.ctor ctor_loc) target then [ctor_loc] else [])
         @ List.concat_map (fun (field : Ast.field_def) -> collect_occurrences_in_type_expr env target field.type_expr) variant.fields
      ) variants
  | Ast.DRecord r ->
    let name_loc = precise_name_loc r.loc r.name in
    (if symbol_equal (type_symbol r.name name_loc) target then [name_loc] else [])
    @ List.concat_map (fun (field : Ast.field_def) -> collect_occurrences_in_type_expr env target field.type_expr) r.fields
  | Ast.DEntity e ->
    let name_loc = precise_name_loc e.loc e.name in
    (if symbol_equal (type_symbol e.name name_loc) target then [name_loc] else [])
    @ List.concat_map (fun (field : Ast.field_def) -> collect_occurrences_in_type_expr env target field.type_expr) e.fields
  | Ast.DConst c ->
    let name_loc = precise_name_loc c.loc c.name in
    (if symbol_equal (term_symbol c.name name_loc) target then [name_loc] else [])
    @ collect_occurrences_in_expr env [] target c.value
  | Ast.DCapture capture ->
    let name_loc = capture_name_loc capture in
    (if symbol_equal (term_symbol capture.name name_loc) target then [name_loc] else [])
    @ collect_occurrences_in_binding env target capture.binding
    @ term_occurrence_at_precise_loc [] env target capture.loc capture.parser
    @ (match capture.checker with Some checker -> term_occurrence_at_precise_loc [] env target capture.loc checker | None -> [])
  | Ast.DChannel channel ->
    let name_loc = precise_name_loc channel.loc channel.name in
    (if symbol_equal (term_symbol channel.name name_loc) target then [name_loc] else [])
    @ collect_occurrences_in_type_expr env target channel.payload
    @ List.concat_map (collect_occurrences_in_binding env target) channel.key_params
  | Ast.DApi api ->
    let name_loc = precise_name_loc api.loc api.name in
    (if symbol_equal (term_symbol api.name name_loc) target then [name_loc] else [])
    @ List.concat_map (fun (endpoint : Ast.api_endpoint) ->
         (match endpoint.auth with Some auth -> collect_occurrences_in_binding env target auth.binding | None -> [])
         @ (match endpoint.body with Some binding -> collect_occurrences_in_binding env target binding | None -> [])
         @ List.concat_map (fun (capture : Ast.api_capture) -> collect_occurrences_in_binding env target capture.binding) endpoint.captures
         @ collect_occurrences_in_return_spec env target endpoint.return_spec
      ) api.endpoints
  | Ast.DTest test -> collect_occurrences_in_test_stmts env [] target test.stmts
  | Ast.DApiTest test ->
    List.concat_map (collect_occurrences_in_expr env [] target) test.seed_stmts
    @ collect_occurrences_in_test_stmts env [] target test.stmts
  | Ast.DLoadTest test ->
    List.concat_map (collect_occurrences_in_expr env [] target) test.seed_stmts
    @ collect_occurrences_in_test_stmts env [] target test.request_stmts
  | Ast.DCodec c ->
    let name_loc = codec_name_loc c in
    let type_loc = codec_target_type_loc c in
    (if symbol_equal (term_symbol c.name name_loc) target then [name_loc] else [])
    @ (if symbol_equal (type_symbol c.type_name type_loc) target then [type_loc] else [])
    @ (match c.to_json with
       | Ast.ToJsonForbidden | Ast.ToJsonAdt -> []
       | Ast.ToJsonFields entries ->
         List.concat_map (fun (entry : Ast.codec_encode_entry) ->
           term_occurrence_at_precise_loc [] env target entry.loc entry.codec
         ) entries)
    @ (match c.from_json with
       | Ast.FromJsonForbidden | Ast.FromJsonAdt -> []
       | Ast.FromJsonAlts alts ->
         List.concat_map (fun (alt : Ast.codec_decode_alt) ->
           List.concat_map (function
             | Ast.DecodeField { codec; via; loc; _ } ->
               term_occurrence_at_precise_loc [] env target loc codec
               @ (let via_locs = codec_decode_field_via_locs loc codec via in
                  let rec collect_via names locs =
                    match names, locs with
                    | name :: names', loc :: locs' ->
                      let occs =
                        match resolve_term_symbol [] env name with
                        | Some symbol when symbol_equal symbol target -> [loc]
                        | _ -> []
                      in
                      occs @ collect_via names' locs'
                    | _ -> []
                  in
                  collect_via via via_locs)
             | Ast.DecodeCrossCheck { checker; loc } ->
               term_occurrence_at_precise_loc [] env target loc checker
             | Ast.DecodeDefault _ -> []
           ) alt
         ) alts)
  | Ast.DDatabase d -> let name_loc = precise_name_loc d.loc d.name in if symbol_equal (term_symbol d.name name_loc) target then [name_loc] else []
  | Ast.DCapability c -> let name_loc = precise_name_loc c.loc c.name in if symbol_equal (term_symbol c.name name_loc) target then [name_loc] else []
  | Ast.DQueue q -> let name_loc = precise_name_loc q.loc q.name in if symbol_equal (term_symbol q.name name_loc) target then [name_loc] else []
  | Ast.DWorkers w -> let name_loc = precise_name_loc w.loc w.name in if symbol_equal (term_symbol w.name name_loc) target then [name_loc] else []
  | Ast.DServer s -> let name_loc = precise_name_loc s.loc s.name in if symbol_equal (term_symbol s.name name_loc) target then [name_loc] else []
  | Ast.DFact f -> let name_loc = precise_name_loc f.loc f.name in if symbol_equal (type_symbol f.name name_loc) target then [name_loc] else []

and collect_occurrences_in_return_spec env target ret =
  match ret with
  | Ast.RetPlain { ty; _ } -> collect_occurrences_in_type_expr env target ty
  | Ast.RetAttached { binding; _ } -> collect_occurrences_in_binding env target binding
  | Ast.RetNamedPack { ty; _ } -> collect_occurrences_in_type_expr env target ty
  | Ast.RetForAll { elem_ty; _ }
  | Ast.RetMaybeForAll { elem_ty; _ }
  | Ast.RetSetForAll { elem_ty; _ }
  | Ast.RetMaybeSetForAll { elem_ty; _ } -> collect_occurrences_in_type_expr env target elem_ty
  | Ast.RetForAllDictValues { key_ty; val_ty; _ }
  | Ast.RetForAllDictKeys   { key_ty; val_ty; _ } ->
    collect_occurrences_in_type_expr env target key_ty
    @ collect_occurrences_in_type_expr env target val_ty
  | Ast.RetMaybeAttached { binding; _ } -> collect_occurrences_in_binding env target binding
  | Ast.RetExists { binding; body; _ } -> collect_occurrences_in_binding env target binding @ collect_occurrences_in_return_spec env target body

let occurrences_source filename source line col =
  set_query_source_lines source;
  match parse_module filename source with
  | Err _ -> []
  | Ok m ->
    let env = collect_definition_env m in
    match find_map_list (resolve_symbol_in_top_decl env line col) m.decls with
    | None -> []
    | Some target ->
      List.concat_map (collect_occurrences_in_top_decl env target) m.decls
      |> location_list_to_occurrences

let occurrences_file filename line col =
  let source = In_channel.with_open_text filename In_channel.input_all in
  occurrences_source filename source line col

let loc_specificity_key (loc : Location.loc) =
  let line_span = loc.stop.line - loc.start.line in
  let col_span = if loc.stop.line = loc.start.line then loc.stop.col - loc.start.col else max_int in
  (line_span, col_span, -loc.start.line, -loc.start.col)

let better_expr_type current candidate =
  match current with
  | None -> true
  | Some (best : Checker.expr_type_info) ->
    compare (loc_specificity_key candidate.Checker.loc) (loc_specificity_key best.Checker.loc) < 0

let type_at_of_checker (info : Checker.expr_type_info) : type_at_result = {
  file = info.loc.file;
  line = info.loc.start.line;
  col = info.loc.start.col;
  end_line = info.loc.stop.line;
  end_col = info.loc.stop.col;
  ty = info.display_ty;
}

let type_at_source filename source line col =
  match parse_module filename source with
  | Err _ -> None
  | Ok m ->
    let expr_types, _ = Checker.check_module_with_expr_types m in
    List.fold_left (fun best info ->
      if loc_contains_position info.Checker.loc line col && better_expr_type best info
      then Some info
      else best
    ) None expr_types
    |> Option.map type_at_of_checker

let type_at_file filename line col =
  let source = In_channel.with_open_text filename In_channel.input_all in
  type_at_source filename source line col

let better_field_access (current : Checker.field_access_info option) (candidate : Checker.field_access_info) =
  match current with
  | None -> true
  | Some best ->
    compare (loc_specificity_key candidate.Checker.fa_loc) (loc_specificity_key best.Checker.fa_loc) < 0

let field_at_of_checker (fa : Checker.field_access_info) : field_at_result = {
  far_field       = fa.Checker.fa_field;
  far_record_type = fa.Checker.fa_record_type;
  far_field_type  = fa.Checker.fa_field_type;
  far_file        = fa.Checker.fa_loc.file;
  far_line        = fa.Checker.fa_loc.start.line;
  far_col         = fa.Checker.fa_loc.start.col;
  far_end_line    = fa.Checker.fa_loc.stop.line;
  far_end_col     = fa.Checker.fa_loc.stop.col;
}

let field_at_source filename source line col =
  match parse_module filename source with
  | Err _ -> None
  | Ok m ->
    let field_accesses, _ = Checker.check_module_with_field_accesses m in
    List.fold_left (fun best (fa : Checker.field_access_info) ->
      if loc_contains_position fa.Checker.fa_loc line col && better_field_access best fa
      then Some fa
      else best
    ) None field_accesses
    |> Option.map field_at_of_checker

let field_at_file filename line col =
  let source = In_channel.with_open_text filename In_channel.input_all in
  field_at_source filename source line col

let starts_with ~prefix s =
  let prefix_len = String.length prefix in
  String.length s >= prefix_len && String.sub s 0 prefix_len = prefix

let is_tesl_stdlib_module_name name =
  starts_with ~prefix:"Tesl." name

let module_name_to_kebab name =
  let buf = Buffer.create (String.length name + 4) in
  String.iteri (fun i c ->
    if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
    else if c >= 'A' && c <= 'Z' then begin
      Buffer.add_char buf '-';
      Buffer.add_char buf (Char.lowercase_ascii c)
    end else
      Buffer.add_char buf c
  ) name;
  Buffer.contents buf

let resolve_local_import_path source_file module_name =
  let dir = Filename.dirname source_file in
  let kebab_path = Filename.concat dir (module_name_to_kebab module_name ^ ".tesl") in
  if Sys.file_exists kebab_path then kebab_path
  else Filename.concat dir (module_name ^ ".tesl")

let strip_dotdot raw_name =
  let n = String.length raw_name in
  if n > 4 && String.sub raw_name (n - 4) 4 = "(..)"
  then String.sub raw_name 0 (n - 4)
  else raw_name

let import_includes_bool_type (imp : import_decl) =
  match imp.names with
  | ImportAll -> true
  | ImportExposing names ->
      List.exists (fun raw_name -> strip_dotdot raw_name = "Bool") names

let import_includes_bool_ctors (imp : import_decl) =
  match imp.names with
  | ImportAll -> true
  | ImportExposing names ->
      List.exists (fun raw_name ->
        raw_name = "Bool(..)" ||
        let stripped = strip_dotdot raw_name in
        stripped = "Bool" || stripped = "True" || stripped = "False"
      ) names

let has_prelude_bool_type_import (m : module_form) =
  List.exists (fun (imp : import_decl) -> imp.module_name = "Tesl.Prelude" && import_includes_bool_type imp) m.imports

let has_prelude_bool_ctor_import (m : module_form) =
  List.exists (fun (imp : import_decl) -> imp.module_name = "Tesl.Prelude" && import_includes_bool_ctors imp) m.imports

let single_line_replace_fix (source_lines : string array) loc ~old_text replacement =
  if loc.Location.start.line <> loc.Location.stop.line then None
  else if loc.Location.start.line < 0 || loc.Location.start.line >= Array.length source_lines then None
  else
    let line = source_lines.(loc.Location.start.line) in
    let len = String.length line in
    let start_col = max 0 (min len loc.Location.start.col) in
    let expected_end = start_col + String.length old_text in
    let end_col =
      if expected_end <= len && String.sub line start_col (String.length old_text) = old_text
      then expected_end
      else max start_col (min len loc.Location.stop.col)
    in
    let new_line =
      String.sub line 0 start_col ^ replacement ^ String.sub line end_col (len - end_col)
    in
    Some (Replace_line { line = loc.Location.start.line; replacement = new_line })

let legacy_bool_diag source_lines loc ~old_text ~replacement ~message = {
  file       = loc.Location.file;
  start_line = loc.Location.start.line;
  start_col  = loc.Location.start.col;
  end_line   = loc.Location.stop.line;
  end_col    = loc.Location.stop.col;
  severity   = "error";
  code       = "VBOOL001";
  message    = message;
  fix        = single_line_replace_fix source_lines loc ~old_text replacement;
  source     = "validation";
}

let missing_bool_import_diag loc ~is_ctor =
  let message =
    if is_ctor then
      "`True`/`False` come from `Tesl.Prelude`; add `import Tesl.Prelude exposing [Bool(..)]`"
    else
      "`Bool` comes from `Tesl.Prelude`; add `import Tesl.Prelude exposing [Bool(..)]`"
  in
  {
    file       = loc.Location.file;
    start_line = loc.Location.start.line;
    start_col  = loc.Location.start.col;
    end_line   = loc.Location.stop.line;
    end_col    = loc.Location.stop.col;
    severity   = "error";
    code       = "VBOOL002";
    message;
    fix        = None;
    source     = "validation";
  }

let legacy_bool_diagnostics _filename source (m : module_form) =
  let source_lines = Array.of_list (String.split_on_char '
' source) in
  let bool_type_imported = has_prelude_bool_type_import m in
  let bool_ctor_imported = has_prelude_bool_ctor_import m in
  let diags = ref [] in
  let first_bool_type_use = ref None in
  let first_bool_ctor_use = ref None in
  let note_bool_type_use loc = if !first_bool_type_use = None then first_bool_type_use := Some loc in
  let note_bool_ctor_use loc = if !first_bool_ctor_use = None then first_bool_ctor_use := Some loc in
  let rec visit_type_expr = function
    | TName { name = "Boolean"; loc } ->
        diags := legacy_bool_diag source_lines loc ~old_text:"Boolean" ~replacement:"Bool"
          ~message:"use `Bool`, not `Boolean`" :: !diags
    | TName { name = "Bool"; loc } ->
        note_bool_type_use loc
    | TVar { name = "bool"; loc } ->
        diags := legacy_bool_diag source_lines loc ~old_text:"bool" ~replacement:"Bool"
          ~message:"use `Bool`, not `bool`" :: !diags
    | TApp { head; arg; _ } ->
        visit_type_expr head; visit_type_expr arg
    | TFun { dom; cod; _ } ->
        visit_type_expr dom; visit_type_expr cod
    | TTuple { elems; _ } ->
        List.iter visit_type_expr elems
    | _ -> ()
  in
  let rec visit_binding (b : binding) =
    visit_type_expr b.type_expr
  and visit_field_def (f : field_def) =
    visit_type_expr f.type_expr
  and visit_return_spec = function
    | RetPlain { ty; _ } -> visit_type_expr ty
    | RetAttached { binding; _ } -> visit_binding binding
    | RetNamedPack { ty; _ } -> visit_type_expr ty
    | RetForAll { elem_ty; _ }
    | RetMaybeForAll { elem_ty; _ }
    | RetSetForAll { elem_ty; _ }
    | RetMaybeSetForAll { elem_ty; _ } -> visit_type_expr elem_ty
    | RetForAllDictValues { key_ty; val_ty; _ }
    | RetForAllDictKeys   { key_ty; val_ty; _ } ->
      visit_type_expr key_ty; visit_type_expr val_ty
    | RetMaybeAttached { binding; _ } -> visit_binding binding
    | RetExists { binding; body; _ } -> visit_binding binding; visit_return_spec body
  and visit_expr = function
    | ELit { lit = LBool true; loc } ->
        diags := legacy_bool_diag source_lines loc ~old_text:"true" ~replacement:"True"
          ~message:"use `True`, not `true`" :: !diags
    | ELit { lit = LBool false; loc } ->
        diags := legacy_bool_diag source_lines loc ~old_text:"false" ~replacement:"False"
          ~message:"use `False`, not `false`" :: !diags
    | ELit _ | EVar _ | EFail _ | EStartWorkers _ -> ()
    | EField { obj; _ } -> visit_expr obj
    | EApp { fn; arg; _ } -> visit_expr fn; visit_expr arg
    | EBinop { left; right; _ } -> visit_expr left; visit_expr right
    | EUnop { arg; _ } -> visit_expr arg
    | EIf { cond; then_; else_; _ } -> visit_expr cond; visit_expr then_; visit_expr else_
    | ECase { scrut; arms; _ } ->
        visit_expr scrut;
        List.iter (fun arm -> Option.iter visit_expr arm.guard; visit_expr arm.body) arms
    | ELet { value; body; _ } -> visit_expr value; visit_expr body
    | ELetProof { value; body; _ } -> visit_expr value; visit_expr body
    | ERecord { fields; _ } -> List.iter (fun (_, e) -> visit_expr e) fields
    | EList { elems; _ } -> List.iter visit_expr elems
    | EOk { value; _ } -> visit_expr value
    | ETelemetry { fields; _ } -> List.iter (fun (_, e) -> visit_expr e) fields
    | EEnqueue { payload; _ } -> visit_expr payload
    | EPublish { key; payload; _ } -> Option.iter visit_expr key; Option.iter visit_expr payload
    | EWithDatabase { body; _ }
    | EWithCapabilities { body; _ }
    | EWithTransaction { body; _ } -> visit_expr body
    | EServe { port; _ } -> visit_expr port
    | EConstructor { name = ("True" | "False"); args = []; loc } ->
        note_bool_ctor_use loc
    | EConstructor { args; _ } -> List.iter visit_expr args
    | ELambda { params; body; _ } -> List.iter visit_binding params; visit_expr body
  in
  let rec visit_test_stmt = function
    | TsLetProof { value; _ } -> visit_expr value
    | TsLet { value; _ } -> visit_expr value
    | TsExpect { left; right; _ } -> visit_expr left; Option.iter visit_expr right
    | TsExpectFail { fn; arg; _ } -> visit_expr fn; visit_expr arg
    | TsExpectHasProof { fn; arg; _ } -> visit_expr fn; visit_expr arg
    | TsProperty { body; _ } -> visit_expr body
    | TsIf { cond; then_stmts; else_stmts; _ } ->
        visit_expr cond;
        List.iter visit_test_stmt then_stmts;
        List.iter visit_test_stmt else_stmts
    | TsCase { scrut; arms; _ } ->
        visit_expr scrut;
        List.iter (fun arm -> List.iter visit_test_stmt arm.ts_body) arms
    | TsExpr { e; _ } -> visit_expr e
  in
  List.iter (function
    | DFunc fd ->
        List.iter visit_binding fd.params;
        visit_return_spec fd.return_spec;
        visit_expr fd.body
    | DRecord r -> List.iter visit_field_def r.fields
    | DEntity e -> List.iter visit_field_def e.fields
    | DType (TypeNewtype { base_type; _ })
    | DType (TypeAlias { base_type; _ }) -> visit_type_expr base_type
    | DType (TypeAdt { variants; _ }) ->
        List.iter (fun (v : adt_variant) -> List.iter visit_field_def v.fields) variants
    | DConst c -> visit_expr c.value
    | DTest test ->
        List.iter visit_test_stmt test.stmts
    | DApiTest test ->
        List.iter visit_expr test.seed_stmts;
        List.iter visit_test_stmt test.stmts
    | DLoadTest test ->
        List.iter visit_expr test.seed_stmts;
        List.iter visit_test_stmt test.request_stmts
    | _ -> ()
  ) m.decls;
  (match !first_bool_type_use with
   | Some loc when not bool_type_imported -> diags := missing_bool_import_diag loc ~is_ctor:false :: !diags
   | _ -> ());
  (match !first_bool_ctor_use with
   | Some loc when not bool_ctor_imported -> diags := missing_bool_import_diag loc ~is_ctor:true :: !diags
   | _ -> ());
  List.rev !diags

let parse_module_file path =
  try
    let source = In_channel.with_open_text path In_channel.input_all in
    match parse_module path source with
    | Ok m -> Some m
    | Err _ -> None
  with Sys_error _ -> None

let build_local_import_graph entry_path =
  let graph : (string, string list) Hashtbl.t = Hashtbl.create 16 in
  let rec visit path =
    if Hashtbl.mem graph path then ()
    else begin
      let deps =
        match parse_module_file path with
        | None -> []
        | Some m ->
          List.filter_map (fun (imp : Ast.import_decl) ->
            if is_tesl_stdlib_module_name imp.module_name then None
            else Some (resolve_local_import_path m.source_file imp.module_name)
          ) m.imports
      in
      Hashtbl.add graph path deps;
      List.iter visit deps
    end
  in
  visit entry_path;
  graph

let tarjan_sccs (graph : (string, string list) Hashtbl.t) =
  let index = ref 0 in
  let stack : string Stack.t = Stack.create () in
  let indices : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let lowlinks : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let on_stack : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  let sccs = ref [] in
  let rec strongconnect v =
    Hashtbl.replace indices v !index;
    Hashtbl.replace lowlinks v !index;
    incr index;
    Stack.push v stack;
    Hashtbl.replace on_stack v ();
    let neighbors = match Hashtbl.find_opt graph v with Some xs -> xs | None -> [] in
    List.iter (fun w ->
      if not (Hashtbl.mem indices w) then begin
        strongconnect w;
        let low_v = Hashtbl.find lowlinks v in
        let low_w = Hashtbl.find lowlinks w in
        Hashtbl.replace lowlinks v (min low_v low_w)
      end else if Hashtbl.mem on_stack w then begin
        let low_v = Hashtbl.find lowlinks v in
        let idx_w = Hashtbl.find indices w in
        Hashtbl.replace lowlinks v (min low_v idx_w)
      end
    ) neighbors;
    if Hashtbl.find lowlinks v = Hashtbl.find indices v then begin
      let component = ref [] in
      let continue = ref true in
      while !continue do
        let w = Stack.pop stack in
        Hashtbl.remove on_stack w;
        component := w :: !component;
        if w = v then continue := false
      done;
      sccs := !component :: !sccs
    end
  in
  Hashtbl.iter (fun v _ ->
    if not (Hashtbl.mem indices v) then strongconnect v
  ) graph;
  !sccs

let cyclic_local_import_paths_for_entry entry_path =
  let graph = build_local_import_graph entry_path in
  let sccs = tarjan_sccs graph in
  match List.find_opt (fun component -> List.mem entry_path component) sccs with
  | Some component when List.length component > 1 -> component
  | _ -> []

(** Produce a diagnostic for each pair of files involved in an import cycle.
    Returns [] if the file is synthetic (empty path, <test>, etc.). *)
(** Run the full check pipeline on a parsed module; returns diagnostics. *)
let check_module source (m : Ast.module_form) : diagnostic list =
  let source_lines = Array.of_list (String.split_on_char '\n' source) in
  let _, _, _, bare_hints, type_errors = Checker.check_module_with_metadata m in
  let type_diags = List.map (fun (e : Type_system.type_error) ->
    let base = diag_of_type_error e in
    if starts_with ~prefix:"bare record literal" e.message then
      match List.find_opt (fun (loc, _) ->
        loc.Location.start.line = e.loc.start.line
        && loc.Location.start.col = e.loc.start.col
      ) bare_hints with
      | Some (hint_loc, type_name) ->
        let fix = single_line_replace_fix source_lines hint_loc
          ~old_text:"{" (type_name ^ " {") in
        { base with fix }
      | None -> base
    else base
  ) type_errors in
  legacy_bool_diagnostics m.source_file source m
  @ type_diags
  @ List.map diag_of_proof_error (Proof_checker.check_module m)
  @ List.map diag_of_validation_error (Validation.check_module m)

let default_root_path () =
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some p when p <> "" -> p
  | _ ->
    let rec find dir =
      let candidate = Filename.concat dir "compiler" in
      if (try Sys.file_exists candidate && Sys.is_directory candidate with _ -> false)
      then dir
      else
        let parent = Filename.dirname dir in
        if parent = dir then Filename.current_dir_name
        else find parent
    in
    find (Filename.dirname Sys.executable_name)

(** Compile a source string: parse + (optional) type-check + emit Racket.
    When type_check=true (the default), returns Failure if any errors exist — no
    Racket is emitted for a module that would fail `tesl check`. *)
let compile_source ?(root_path=default_root_path ()) ?(type_check=true) filename source =
  match parse_module filename source with
  | Err e -> Failure [diag_of_parse_error e]
  | Ok m ->
    let diags = if type_check then check_module source m else [] in
    if diags <> [] then Failure diags
    else
      let racket = Emit_racket.compile_to_string ~root_path m in
      Success racket

let compile_file ?(root_path=default_root_path ()) ?(type_check=true) filename =
  let source = In_channel.with_open_text filename In_channel.input_all in
  match parse_module filename source with
  | Err e -> Failure [diag_of_parse_error e]
  | Ok m ->
    let diags = if type_check then check_module source m else [] in
    if diags <> [] then Failure diags
    else
      let cyclic_local_import_paths =
        if m.source_file = "" || m.source_file = "<test>" then []
        else cyclic_local_import_paths_for_entry m.source_file
      in
      let racket =
        Emit_racket.compile_to_string
          ~root_path
          ~cyclic_local_import_paths
          m
      in
      Success racket

(** Check only — return diagnostics without emitting Racket. *)
let local_binding_of_checker (b : Checker.local_binding_info) : local_binding = {
  file = b.loc.file;
  line = b.loc.start.line;
  col = b.loc.start.col;
  end_line = b.loc.stop.line;
  end_col = b.loc.stop.col;
  name = b.name;
  ty = b.display_ty;
  note = b.hover_note;
}

let local_bindings_source filename source =
  match parse_module filename source with
  | Err _ -> []
  | Ok m ->
    let bindings, _ = Checker.check_module_with_local_bindings m in
    List.map local_binding_of_checker bindings

type completion_item = {
  ci_label  : string;
  ci_detail : string;
  ci_kind   : string;
}

let completion_item_to_json (item : completion_item) : string =
  Printf.sprintf {|{"label":%s,"detail":%s,"kind":%s}|}
    (json_encode_string item.ci_label)
    (json_encode_string item.ci_detail)
    (json_encode_string item.ci_kind)

let completions_response_to_json (items : completion_item list) : string =
  Printf.sprintf {|{"version":1,"completions":[%s]}|}
    (String.concat "," (List.map completion_item_to_json items))

let completions_source filename source line col =
  match parse_module filename source with
  | Err _ -> []
  | Ok m ->
    let src_lines = Array.of_list (String.split_on_char '\n' source) in
    let char_at l c =
      if l >= 0 && l < Array.length src_lines then
        let s = src_lines.(l) in
        if c >= 0 && c < String.length s then Some s.[c] else None
      else None
    in
    let is_dot_completion = match char_at line (col - 1) with Some '.' -> true | _ -> false in
    if is_dot_completion then begin
      let expr_types, _ = Checker.check_module_with_expr_types m in
      let pre_dot = col - 2 in
      let best = List.fold_left (fun best info ->
        let ok =
          loc_contains_position info.Checker.loc line pre_dot
          || (info.Checker.loc.Location.stop.line = line
              && info.Checker.loc.Location.stop.col = col - 1)
        in
        if ok && better_expr_type best info then Some info else best
      ) None expr_types in
      match best with
      | None -> []
      | Some info ->
        let record_name = match info.Checker.ty with
          | Type_system.TCon n -> Some n
          | Type_system.TApp (Type_system.TCon n, _) -> Some n
          | _ -> None
        in
        (match record_name with
         | None -> []
         | Some name ->
           let ctx0 = Checker.make_ctx ~filename ~env:[] in
           let ctx1 = Checker.collect_type_defs ctx0 m.decls in
           match List.assoc_opt name ctx1.Checker.records with
           | None -> []
           | Some rd ->
             List.map (fun (fname, fty) -> {
               ci_label  = fname;
               ci_detail = Type_system.pp_ty fty;
               ci_kind   = "field";
             }) rd.Checker.rd_fields)
    end else begin
      let ctx0 = Checker.make_ctx ~filename ~env:(Type_system.make_stdlib_env ()) in
      let ctx1 = Checker.collect_type_defs ctx0 m.decls in
      let env = Checker.load_imported_func_sigs m @ ctx1.Checker.env in
      let ctx = Checker.collect_func_sigs { ctx1 with Checker.env = env } m.decls in
      List.filter_map (fun (name, sch) ->
        if String.length name > 0 && name.[0] <> '#' then
          let kind = match sch.Type_system.mono with
            | Type_system.TFun _ -> "function"
            | _ -> "variable"
          in
          Some { ci_label = name; ci_detail = Type_system.pp_ty sch.Type_system.mono; ci_kind = kind }
        else None
      ) ctx.Checker.env
    end

let completions_file filename line col =
  let source = In_channel.with_open_text filename In_channel.input_all in
  completions_source filename source line col

let local_bindings_file filename =
  let source = In_channel.with_open_text filename In_channel.input_all in
  local_bindings_source filename source

let check_source filename source =
  try
    match parse_module filename source with
    | Err e -> [diag_of_parse_error e]
    | Ok m  -> check_module source m
  with Failure msg -> [{
    file       = filename;
    start_line = 1; start_col = 1;
    end_line   = 1; end_col   = 1;
    severity   = "error";
    code       = "E000";
    message    = msg;
    fix        = None;
    source     = "lexer";
  }]

let check_file filename =
  let source = In_channel.with_open_text filename In_channel.input_all in
  check_source filename source

(** Legacy: format errors (parse errors only) as JSON. *)
let errors_to_json filename errors =
  let diags = List.map (fun (e : parse_error) ->
    let l = e.loc in
    Printf.sprintf
      {|{"file":%s,"start":{"line":%d,"col":%d},"end":{"line":%d,"col":%d},"severity":"error","code":"E001","message":%s,"fix":null,"source":"parser"}|}
      (json_encode_string filename)
      l.start.line l.start.col
      l.stop.line  l.stop.col
      (json_encode_string e.msg)
  ) errors in
  Printf.sprintf {|{"version":1,"diagnostics":[%s]}|} (String.concat "," diags)

(* ── IR-1 semantic snapshot ─────────────────────────────────────────────── *)
(** `--semantic-json`: dump the full module semantic snapshot.
    This is the concrete first step toward a retained semantic layer (roadmap
    Item 03). The snapshot captures every declaration-level semantic fact the
    checker produces, serialised to JSON so downstream tooling (editor, CLI
    scripts, codegen) can query without recompiling.

    Schema version 1.  All line/col values are 0-based (same as other
    compiler JSON outputs).  The snapshot is keyed by content hash so callers
    can cache invalidation on file mtime. *)

let json_str s = json_encode_string s
let json_arr elems = Printf.sprintf "[%s]" (String.concat "," elems)
let json_obj pairs =
  Printf.sprintf "{%s}"
    (String.concat "," (List.map (fun (k,v) -> Printf.sprintf "%s:%s" (json_encode_string k) v) pairs))

let loc_json (l : Location.loc) =
  json_obj [
    "file",       json_str l.file;
    "start_line", string_of_int l.start.line;
    "start_col",  string_of_int l.start.col;
    "end_line",   string_of_int l.stop.line;
    "end_col",    string_of_int l.stop.col;
  ]

let ty_json (ty : Type_system.ty) =
  json_str (Type_system.pp_ty ty)

let scheme_json (sch : Type_system.scheme) =
  json_str (Type_system.pp_ty sch.Type_system.mono)

(** Collect all top-level semantic info from a parsed + checked module. *)
let semantic_json_of_module (m : Ast.module_form) : string =
  let source_text = (try In_channel.with_open_text m.source_file (fun ic -> In_channel.input_all ic) with _ -> "") in
  (* Run the checker to obtain the full context. *)
  let local_bindings, expr_types, _field_accesses, _bare_hints, _errors = Checker.check_module_with_metadata m in

  (* Build the checker context for declaration-level info. *)
  let ctx0 = Checker.make_ctx ~filename:m.source_file ~env:[] in
  let ctx1 = Checker.collect_type_defs ctx0 m.decls in
  let env   = Checker.load_imported_func_sigs m @ ctx1.env in
  let ctx   = { ctx1 with Checker.env = env } in

  (* ── Records ── *)
  let records_json = json_arr (List.map (fun (name, rd) ->
    let fields_json = json_arr (List.map (fun (fname, fty) ->
      json_obj ["name", json_str fname; "type", ty_json fty]
    ) rd.Checker.rd_fields) in
    json_obj ["name", json_str name; "fields", fields_json]
  ) ctx.Checker.records) in

  (* ── ADTs ── *)
  let adts_json = json_arr (List.map (fun (name, ad) ->
    let variants_json = json_arr (List.map (fun (ctor, fields) ->
      let fields_j = json_arr (List.map (fun (fname, fty) ->
        json_obj ["name", json_str fname; "type", ty_json fty]
      ) fields) in
      json_obj ["constructor", json_str ctor; "fields", fields_j]
    ) ad.Checker.ad_variants) in
    json_obj ["name", json_str name;
              "params", json_arr (List.map json_str ad.Checker.ad_params);
              "variants", variants_json]
  ) ctx.Checker.adts) in

  (* ── Functions / handlers / workers / checks / auth / establish ── *)
  (* Use the AST param+return types — these are the declared signatures, which
     for top-level decls equals the inferred type.  This avoids needing to
     expose the full post-check env from check_module_with_metadata. *)
  let functions_json = json_arr (List.filter_map (function
    | Ast.DFunc fd ->
      let param_tys = List.map (fun (b : Ast.binding) ->
        Type_system.pp_ty (Checker.ty_of_type_expr b.type_expr)) fd.params in
      let ret_ty = Type_system.pp_ty (Checker.ret_spec_type fd.return_spec) in
      let sig_str = match param_tys with
        | [] -> ret_ty
        | ps -> String.concat " -> " ps ^ " -> " ^ ret_ty
      in
      let kind_str = (match fd.kind with
        | Ast.FnKind        -> "fn"
        | Ast.HandlerKind   -> "handler"
        | Ast.WorkerKind    -> "worker"
        | Ast.DeadWorkerKind -> "worker"
        | Ast.CheckKind     -> "check"
        | Ast.AuthKind      -> "auth"
        | Ast.EstablishKind -> "establish"
        | Ast.MainKind      -> "main") in
      Some (json_obj [
        "name", json_str fd.name;
        "kind", json_str kind_str;
        "type", json_str sig_str;
        "loc",  loc_json fd.loc;
      ])
    | Ast.DConst c ->
      Some (json_obj ["name", json_str c.name; "kind", json_str "const"; "type", json_str "unknown"; "loc", loc_json c.loc])
    | _ -> None
  ) m.decls) in

  (* ── Local bindings (for hover/tooling) ── *)
  let locals_json = json_arr (List.map (fun (b : Checker.local_binding_info) ->
    json_obj ([
      "name",       json_str b.name;
      "type",       json_str b.display_ty;
      "loc",        loc_json b.loc;
    ] @ (match b.hover_note with Some note -> ["note", json_str note] | None -> []))
  ) local_bindings) in

  (* ── Expression types (for hover/type-at) ── *)
  let expr_types_json = json_arr (List.map (fun (e : Checker.expr_type_info) ->
    json_obj [
      "type",       json_str e.display_ty;
      "loc",        loc_json e.loc;
    ]
  ) expr_types) in

  (* Content hash for cache invalidation *)
  let hash = Digest.to_hex (Digest.string source_text) in

  json_obj [
    "version",      "1";
    "file",         json_str m.source_file;
    "module_name",  json_str m.module_name;
    "content_hash", json_str hash;
    "records",      records_json;
    "adts",         adts_json;
    "functions",    functions_json;
    "local_bindings", locals_json;
    "expr_types",   expr_types_json;
  ]

let semantic_json_source filename source =
  match parse_module filename source with
  | Err _ -> None
  | Ok m  -> Some (semantic_json_of_module m)

let semantic_json_file filename =
  let source = In_channel.with_open_text filename In_channel.input_all in
  semantic_json_source filename source

(* ── Built-in mutation testing ──────────────────────────────────────────── *)

type mutate_result =
  | MutateOk of Mutate.mutation_report
  | MutateErr of string

(** Collect DTest declarations from a list of extra test source files.
    Returns an error string on parse failure, or the list of test decls. *)
let collect_extra_test_decls test_files =
  let rec go acc = function
    | [] -> `Ok (List.rev acc)
    | path :: rest ->
      (match (try `Ok (In_channel.with_open_text path In_channel.input_all)
              with Sys_error msg -> `Err msg) with
       | `Err msg -> `Err msg
       | `Ok src ->
         match parse_module path src with
         | Err e -> `Err (Printf.sprintf "parse error in %s:%d: %s" path (e.loc.start.line + 1) e.msg)
         | Ok m ->
           let tests = List.filter (function Ast.DTest _ -> true | _ -> false) m.decls in
           go (List.rev tests @ acc) rest)
  in
  go [] test_files

(** Run mutation testing on [filename].  Returns a [Mutate.mutation_report]
    or an error string if the file doesn't parse / type-check.
    [extra_test_files] provides additional .tesl files whose test blocks are
    merged into each mutant, enabling cross-file mutation testing. *)
let mutate_file ?(root_path=default_root_path ()) ?(extra_test_files=[]) filename : mutate_result =
  let source = In_channel.with_open_text filename In_channel.input_all in
  match parse_module filename source with
  | Err e ->
    MutateErr (Printf.sprintf "parse error at %s:%d: %s"
                 e.loc.file (e.loc.start.line + 1) e.msg)
  | Ok m  ->
    let diags = check_module source m in
    (match List.filter (fun (d : diagnostic) -> d.severity = "error") diags with
     | d :: _ -> MutateErr (Printf.sprintf "type error: %s" d.message)
     | [] ->
       (* Collect extra test declarations from companion test files *)
       (match collect_extra_test_decls extra_test_files with
        | `Err msg -> MutateErr msg
        | `Ok extra_test_decls ->
       let mutants = Mutate.generate_mutants m in
       let results = List.map (fun (mut : Mutate.mutant) ->
         let result =
           (* Merge extra tests into this mutant's module before emitting *)
           let module_with_tests =
             if extra_test_decls = [] then mut.module_
             else { mut.module_ with decls = mut.module_.decls @ extra_test_decls }
           in
           (* Emit without type-checking — the mutant may be semantically
              invalid from the proof perspective, but Racket will still run
              the runtime checks and tests. *)
           let racket_str =
             match (try Some (Emit_racket.compile_to_string ~root_path module_with_tests)
                    with _ -> None)
             with
             | None   -> `Err "emit error"
             | Some r -> `Ok r
           in
           match racket_str with
           | `Err msg -> Mutate.Error msg
           | `Ok r ->
             let has_test = List.exists (function Ast.DTest _ -> true | _ -> false) module_with_tests.decls in
             if not has_test then Mutate.NoTests
             else begin
               let tmp = Filename.temp_file "tesl_mutant_" ".rkt" in
               Fun.protect
                 ~finally:(fun () -> (try Sys.remove tmp with Sys_error _ -> ()))
                 (fun () ->
                   Out_channel.with_open_text tmp
                     (fun oc -> Out_channel.output_string oc r);
                   let cmd = Printf.sprintf "raco test --quiet %s 2>/dev/null"
                               (Filename.quote tmp) in
                   let exit_code = Sys.command cmd in
                   if exit_code = 0 then Mutate.Survived
                   else Mutate.Killed)
             end
         in
         (mut, result)
       ) mutants in
       let killed   = List.length (List.filter (fun (_, r) -> r = Mutate.Killed)   results) in
       let survived = List.length (List.filter (fun (_, r) -> r = Mutate.Survived) results) in
       let errors   = List.length (List.filter (fun (_, r) -> match r with Mutate.Error _ -> true | _ -> false) results) in
       MutateOk { Mutate.total = List.length mutants; killed; survived; errors; results }))
