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

(* An occurrence is a definition_location plus a [kind] tag describing the
   role the occurrence plays:
     "write" — the binding/definition site of the symbol (where it is bound)
     "read"  — a use site (reference) of the symbol
     "text"  — an unresolved textual match (no semantic backing)
   The [kind] field is ADDITIVE: existing consumers that read only file/line/col
   continue to work unchanged.  The bare location record stays as
   [occurrence_location] so the definition machinery can keep sharing it. *)
type occurrence_location = definition_location

type occurrence_kind = OccWrite | OccRead | OccText

let occurrence_kind_to_string = function
  | OccWrite -> "write"
  | OccRead  -> "read"
  | OccText  -> "text"

type occurrence = {
  occ_loc  : occurrence_location;
  occ_kind : occurrence_kind;
}

let occurrence_location_to_json = definition_location_to_json

let occurrence_to_json (o : occurrence) : string =
  Printf.sprintf
    {|{"file":%s,"line":%d,"col":%d,"end_line":%d,"end_col":%d,"kind":%s}|}
    (json_encode_string o.occ_loc.file) o.occ_loc.line o.occ_loc.col
    o.occ_loc.end_line o.occ_loc.end_col
    (json_encode_string (occurrence_kind_to_string o.occ_kind))

let occurrences_to_json (occurrences : occurrence list) =
  Printf.sprintf "[%s]"
    (String.concat "," (List.map occurrence_to_json occurrences))

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

(* Deduplicate raw locations and classify each as a write or read occurrence.
   [write_loc] is the symbol's definition/binding site (from the resolved
   target): an occurrence whose source span equals it is the "write" site;
   every other occurrence is a "read".  Backward compatible — callers that
   ignore [occ_kind] see the same set of locations as before. *)
let location_list_to_occurrences ?(write_loc : Location.loc option)
    (locs : Location.loc list) : occurrence list =
  let is_write (loc : Location.loc) =
    match write_loc with
    | Some w -> loc_equal loc w
    | None -> false
  in
  let rec go (seen : occurrence list) = function
    | [] -> List.rev seen
    | loc :: rest ->
      let occ_loc : occurrence_location = location_to_definition loc in
      let occurrence = {
        occ_loc;
        occ_kind = if is_write loc then OccWrite else OccRead;
      } in
      if List.exists (fun (existing : occurrence) ->
        existing.occ_loc.file = occ_loc.file
        && existing.occ_loc.line = occ_loc.line
        && existing.occ_loc.col = occ_loc.col
        && existing.occ_loc.end_line = occ_loc.end_line
        && existing.occ_loc.end_col = occ_loc.end_col
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
  | Ast.ECacheGet { key; _ } ->
    definition_in_expr env locals line col key
  | Ast.ECacheSet { key; value; ttl; _ } ->
    let r = definition_in_expr env locals line col key in
    (match r with Some _ -> r | None ->
      let r2 = definition_in_expr env locals line col value in
      match r2 with Some _ -> r2 | None ->
        match ttl with Some e -> definition_in_expr env locals line col e | None -> None)
  | Ast.ECacheDelete { key; _ } ->
    definition_in_expr env locals line col key
  | Ast.ECacheInvalidate { prefix; _ } ->
    definition_in_expr env locals line col prefix
  | Ast.ESendEmail { to_; subject; body; _ } ->
    (match definition_in_expr env locals line col to_ with
     | Some _ as r -> r
     | None ->
       match definition_in_expr env locals line col subject with
       | Some _ as r -> r
       | None ->
         definition_in_expr env locals line col body)
  | Ast.EStartEmailWorker _ -> None
  | Ast.ERuntimeCall { segments; _ } ->
    List.find_map (function Ast.RLit _ -> None | Ast.RArg e -> recurse e) segments
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
  | Ast.DWorkers _ | Ast.DServer _ | Ast.DFact _ | Ast.DCache _ | Ast.DEmail _ -> None

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
    | Ast.DTest _ | Ast.DApiTest _ | Ast.DLoadTest _ -> env
    | Ast.DFact f ->
      (* Facts / proof predicates are renameable TYPE-level names: register them
         so proof-position predicate occurrences (e.g. `::: Authenticated x`)
         resolve to the same symbol as the declaration. *)
      add_type_def env f.name (precise_name_loc f.loc f.name)
    | Ast.DCache c -> add_term_def env c.name (precise_name_loc c.loc c.name)
    | Ast.DEmail e -> add_term_def env e.name (precise_name_loc e.loc e.name)
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

(* [proof_name_locs] is defined later (it lives with the occurrence helpers);
   forward-declare via a ref so resolve-side can share the same span recovery. *)
let proof_name_locs_ref : (Ast.proof_expr -> (bool * string * Location.loc) list) ref =
  ref (fun _ -> [])

(* When the caret sits on a name inside a proof annotation, resolve the symbol so
   prepare/rename/find-references can start there: predicate names resolve as the
   fact/type symbol, argument names as ordinary term references. *)
let resolve_symbol_in_proof ?(locals = []) env line col (p : Ast.proof_expr) =
  find_map_list (fun (is_pred, name, name_loc) ->
    if loc_contains_position name_loc line col then
      (if is_pred then find_type_symbol env.type_defs name
       else resolve_term_symbol locals env name)
    else None
  ) (!proof_name_locs_ref p)

let resolve_symbol_in_proof_opt ?locals env line col = function
  | Some p -> resolve_symbol_in_proof ?locals env line col p
  | None -> None

let resolve_symbol_in_binding ?(locals = []) env line col (b : Ast.binding) =
  let name_loc = binding_name_loc b in
  match resolve_symbol_in_type_expr env line col b.type_expr with
  | Some _ as result -> result
  | None ->
    match resolve_symbol_in_proof_opt ~locals env line col b.proof_ann with
    | Some _ as result -> result
    | None -> if loc_contains_position name_loc line col then Some (term_symbol b.name name_loc) else None

let rec resolve_symbol_in_return_spec ?(locals = []) env line col (ret : Ast.return_spec) =
  let in_proof = resolve_symbol_in_proof ~locals env line col in
  let in_proof_opt = function Some p -> in_proof p | None -> None in
  match ret with
  | Ast.RetPlain { ty; _ } -> resolve_symbol_in_type_expr env line col ty
  | Ast.RetAttached { binding; _ } -> resolve_symbol_in_binding ~locals env line col binding
  | Ast.RetNamedPack { ty; entity_proof; other_proof; _ } ->
    (match resolve_symbol_in_type_expr env line col ty with
     | Some _ as r -> r
     | None ->
       match in_proof_opt entity_proof with
       | Some _ as r -> r
       | None -> in_proof_opt other_proof)
  | Ast.RetForAll { elem_ty; proof; _ }
  | Ast.RetMaybeForAll { elem_ty; proof; _ }
  | Ast.RetSetForAll { elem_ty; proof; _ }
  | Ast.RetMaybeSetForAll { elem_ty; proof; _ } ->
    (match resolve_symbol_in_type_expr env line col elem_ty with
     | Some _ as r -> r
     | None -> in_proof proof)
  | Ast.RetForAllDictValues { key_ty; val_ty; proof; _ }
  | Ast.RetForAllDictKeys   { key_ty; val_ty; proof; _ } ->
    (match resolve_symbol_in_type_expr env line col key_ty with
     | Some _ as r -> r
     | None ->
       match resolve_symbol_in_type_expr env line col val_ty with
       | Some _ as r -> r
       | None -> in_proof proof)
  | Ast.RetMaybeAttached { binding; _ } ->
    resolve_symbol_in_binding ~locals env line col binding
  | Ast.RetExists { binding; body; _ } ->
    (match resolve_symbol_in_binding ~locals env line col binding with
     | Some _ as result -> result
     | None -> resolve_symbol_in_return_spec ~locals env line col body)

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
  | Ast.ELet { name; declared_type; value; body; loc; declared_proof } ->
    let name_loc = precise_name_loc loc name in
    let after_type () =
      match resolve_symbol_in_proof_opt ~locals env line col declared_proof with
      | Some _ as result -> result
      | None ->
        match resolve_symbol_in_expr env locals line col value with
        | Some _ as result -> result
        | None ->
          match resolve_symbol_in_expr env ({ bound_name = name; bound_loc = name_loc } :: locals) line col body with
          | Some _ as result -> result
          | None -> if loc_contains_position name_loc line col then Some (term_symbol name name_loc) else None
    in
    (match declared_type with
     | Some ty ->
       (match resolve_symbol_in_type_expr env line col ty with
        | Some _ as result -> result
        | None -> after_type ())
     | None -> after_type ())
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
  | Ast.EOk { value; proof; _ } ->
    (match resolve_symbol_in_expr env locals line col value with
     | Some _ as result -> result
     | None -> resolve_symbol_in_proof ~locals env line col proof)
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
  | Ast.ECacheGet { key; _ } -> resolve_symbol_in_expr env locals line col key
  | Ast.ECacheSet { key; value; ttl; _ } ->
    let r = resolve_symbol_in_expr env locals line col key in
    (match r with Some _ -> r | None ->
      let r2 = resolve_symbol_in_expr env locals line col value in
      match r2 with Some _ -> r2 | None ->
        match ttl with Some e -> resolve_symbol_in_expr env locals line col e | None -> None)
  | Ast.ECacheDelete { key; _ } -> resolve_symbol_in_expr env locals line col key
  | Ast.ECacheInvalidate { prefix; _ } -> resolve_symbol_in_expr env locals line col prefix
  | Ast.ESendEmail { to_; subject; body; _ } ->
    (match resolve_symbol_in_expr env locals line col to_ with
     | Some _ as r -> r
     | None ->
       match resolve_symbol_in_expr env locals line col subject with
       | Some _ as r -> r
       | None ->
         resolve_symbol_in_expr env locals line col body)
  | Ast.EStartEmailWorker _ -> None
  | Ast.ERuntimeCall { segments; _ } ->
    List.find_map (function Ast.RLit _ -> None | Ast.RArg e -> recurse e) segments
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
    let param_locals = extend_locals_with_params [] fd.params in
    let result = find_map_list (resolve_symbol_in_binding ~locals:param_locals env line col) fd.params in
    (match result with
     | Some _ as found -> found
     | None ->
       match resolve_symbol_in_return_spec ~locals:param_locals env line col fd.return_spec with
       | Some _ as found -> found
       | None ->
         match resolve_symbol_in_expr env param_locals line col fd.body with
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
  | Ast.DCache c -> let name_loc = precise_name_loc c.loc c.name in if loc_contains_position name_loc line col then Some (term_symbol c.name name_loc) else None
  | Ast.DEmail e -> let name_loc = precise_name_loc e.loc e.name in if loc_contains_position name_loc line col then Some (term_symbol e.name name_loc) else None

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

(* Forward reference filled in below once [collect_occurrences_in_proof] is in
   scope; [collect_occurrences_in_binding] is defined before the proof helper. *)
let collect_occurrences_in_binding_proof_ref :
  (definition_env -> named_loc list -> resolved_symbol -> Ast.proof_expr -> Location.loc list) ref =
  ref (fun _ _ _ _ -> [])

let collect_occurrences_in_binding ?(locals = []) env target (b : Ast.binding) =
  let name_loc = binding_name_loc b in
  let def_occ = if symbol_equal (term_symbol b.name name_loc) target then [name_loc] else [] in
  def_occ
  @ collect_occurrences_in_type_expr env target b.type_expr
  @ (match b.proof_ann with
     | Some p -> !collect_occurrences_in_binding_proof_ref env locals target p
     | None -> [])

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

(* ── Proof-position occurrences ──────────────────────────────────────────────
   A proof annotation [::: Authenticated reqUser] mentions the predicate name
   ([Authenticated]) followed by zero or more argument NAMES ([reqUser]) that
   refer to value bindings in scope.  These are real references and must be
   included by rename / find-references, otherwise renaming [reqUser] silently
   leaves the proof referring to the old name.

   [proof_expr] only carries a single [loc] per [PredApp] (the whole predicate
   span) — individual names have no stored loc.  We recover each name's precise
   span with [sequential_name_locs] over the predicate's source line. *)
(* [is_pred] marks the predicate name (resolves as a fact/type symbol) versus an
   argument name (resolves as an ordinary value reference). *)
let proof_name_locs (p : Ast.proof_expr) : (bool * string * Location.loc) list =
  let rec go (p : Ast.proof_expr) =
    match p with
    | Ast.PredApp { pred; args; loc } ->
      (match sequential_name_locs loc (pred :: args) with
       | pred_loc :: arg_locs ->
         (true, pred, pred_loc)
         :: List.map2 (fun a l -> (false, a, l)) args arg_locs
       | [] -> [])
    | Ast.PredAnd { left; right; _ } -> go left @ go right
  in
  go p

let () = proof_name_locs_ref := proof_name_locs

(* Collect occurrences of [target] mentioned inside a proof annotation.
   - The predicate name resolves as a fact/proof-predicate name, classified as a
     TYPE symbol (see [resolve_symbol_in_top_decl] / [DFact]); matches a
     type-symbol rename target.
   - Each argument name resolves as an ordinary term reference (local binding or
     top-level term). *)
let collect_occurrences_in_proof env locals target (p : Ast.proof_expr) =
  List.filter_map (fun (is_pred, name, name_loc) ->
    if is_pred then
      match find_type_symbol env.type_defs name with
      | Some symbol when symbol_equal symbol target -> Some name_loc
      | _ -> None
    else
      match resolve_term_symbol locals env name with
      | Some symbol when symbol_equal symbol target -> Some name_loc
      | _ -> None
  ) (proof_name_locs p)

let collect_occurrences_in_proof_opt env locals target = function
  | Some p -> collect_occurrences_in_proof env locals target p
  | None -> []

let () = collect_occurrences_in_binding_proof_ref := collect_occurrences_in_proof

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
  | Ast.ELet { name; declared_type; value; body; loc; declared_proof } ->
    let name_loc = precise_name_loc loc name in
    (if symbol_equal (term_symbol name name_loc) target then [name_loc] else [])
    @ (match declared_type with
       | Some ty -> collect_occurrences_in_type_expr env target ty
       | None -> [])
    @ collect_occurrences_in_proof_opt env locals target declared_proof
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
  | Ast.EOk { value; proof; _ } ->
    collect_occurrences_in_expr env locals target value
    @ collect_occurrences_in_proof env locals target proof
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
  | Ast.ECacheGet { key; _ } -> collect_occurrences_in_expr env locals target key
  | Ast.ECacheSet { key; value; ttl; _ } ->
    collect_occurrences_in_expr env locals target key
    @ collect_occurrences_in_expr env locals target value
    @ (match ttl with Some e -> collect_occurrences_in_expr env locals target e | None -> [])
  | Ast.ECacheDelete { key; _ } -> collect_occurrences_in_expr env locals target key
  | Ast.ECacheInvalidate { prefix; _ } -> collect_occurrences_in_expr env locals target prefix
  | Ast.ESendEmail { to_; subject; body; _ } ->
    collect_occurrences_in_expr env locals target to_
    @ collect_occurrences_in_expr env locals target subject
    @ collect_occurrences_in_expr env locals target body
  | Ast.EStartEmailWorker _ -> []
  | Ast.ERuntimeCall { segments; _ } ->
    List.concat_map (function Ast.RLit _ -> [] | Ast.RArg e -> recurse e) segments
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
    let param_locals = extend_locals_with_params [] fd.params in
    (if symbol_equal (term_symbol fd.name name_loc) target then [name_loc] else [])
    @ List.concat_map (collect_occurrences_in_binding ~locals:param_locals env target) fd.params
    @ collect_occurrences_in_return_spec ~locals:param_locals env target fd.return_spec
    @ collect_occurrences_in_expr env param_locals target fd.body
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
  | Ast.DCache c -> let name_loc = precise_name_loc c.loc c.name in if symbol_equal (term_symbol c.name name_loc) target then [name_loc] else []
  | Ast.DEmail e -> let name_loc = precise_name_loc e.loc e.name in if symbol_equal (term_symbol e.name name_loc) target then [name_loc] else []

and collect_occurrences_in_return_spec ?(locals = []) env target ret =
  let in_proof = collect_occurrences_in_proof env locals target in
  let in_proof_opt = function Some p -> in_proof p | None -> [] in
  match ret with
  | Ast.RetPlain { ty; _ } -> collect_occurrences_in_type_expr env target ty
  | Ast.RetAttached { binding; _ } -> collect_occurrences_in_binding ~locals env target binding
  | Ast.RetNamedPack { ty; entity_proof; other_proof; _ } ->
    collect_occurrences_in_type_expr env target ty
    @ in_proof_opt entity_proof @ in_proof_opt other_proof
  | Ast.RetForAll { elem_ty; proof; _ }
  | Ast.RetMaybeForAll { elem_ty; proof; _ }
  | Ast.RetSetForAll { elem_ty; proof; _ }
  | Ast.RetMaybeSetForAll { elem_ty; proof; _ } ->
    collect_occurrences_in_type_expr env target elem_ty @ in_proof proof
  | Ast.RetForAllDictValues { key_ty; val_ty; proof; _ }
  | Ast.RetForAllDictKeys   { key_ty; val_ty; proof; _ } ->
    collect_occurrences_in_type_expr env target key_ty
    @ collect_occurrences_in_type_expr env target val_ty
    @ in_proof proof
  | Ast.RetMaybeAttached { binding; _ } -> collect_occurrences_in_binding ~locals env target binding
  | Ast.RetExists { binding; body; _ } -> collect_occurrences_in_binding ~locals env target binding @ collect_occurrences_in_return_spec ~locals env target body

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
      |> location_list_to_occurrences ~write_loc:target.symbol_loc

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

(* ── Shared module-walking helpers for the position queries below ───────────── *)

(* The source span of a top-level declaration. *)
let top_decl_loc (decl : Ast.top_decl) : Location.loc =
  match decl with
  | Ast.DFunc fd -> fd.loc
  | Ast.DType (Ast.TypeNewtype { loc; _ })
  | Ast.DType (Ast.TypeAlias { loc; _ })
  | Ast.DType (Ast.TypeAdt { loc; _ }) -> loc
  | Ast.DRecord r -> r.loc
  | Ast.DEntity e -> e.loc
  | Ast.DFact f -> f.loc
  | Ast.DCodec c -> c.loc
  | Ast.DDatabase d -> d.loc
  | Ast.DCapability c -> c.loc
  | Ast.DConst c -> c.loc
  | Ast.DQueue q -> q.loc
  | Ast.DChannel c -> c.loc
  | Ast.DWorkers w -> w.loc
  | Ast.DCache c -> c.loc
  | Ast.DEmail e -> e.loc
  | Ast.DCapture c -> c.loc
  | Ast.DApi a -> a.loc
  | Ast.DServer s -> s.loc
  | Ast.DTest t -> t.loc
  | Ast.DApiTest t -> t.loc
  | Ast.DLoadTest t -> t.loc

(* Fold [f] over every top-level expression ROOT in a module: function bodies,
   const initialisers, capture/channel sub-expressions and the expressions that
   live inside test statements.  Callers descend each root recursively via
   {!Ast_visitor.iter}.  This covers every place a function call can appear. *)
let fold_module_expr_roots (f : 'a -> Ast.expr -> 'a) (acc : 'a)
    (m : Ast.module_form) : 'a =
  let rec fold_test_stmts acc (stmts : Ast.test_stmt list) =
    List.fold_left fold_test_stmt acc stmts
  and fold_test_stmt acc (stmt : Ast.test_stmt) =
    match stmt with
    | Ast.TsLet { value; _ } | Ast.TsLetProof { value; _ } -> f acc value
    | Ast.TsExpect { left; right; _ } ->
      let acc = f acc left in
      (match right with Some r -> f acc r | None -> acc)
    | Ast.TsExpectFail { fn; arg; _ }
    | Ast.TsExpectHasProof { fn; arg; _ } -> f (f acc fn) arg
    | Ast.TsProperty { params; body; _ } ->
      let acc =
        List.fold_left (fun acc (p : Ast.property_param) ->
          match p.where_clause with Some g -> f acc g | None -> acc
        ) acc params
      in
      f acc body
    | Ast.TsIf { cond; then_stmts; else_stmts; _ } ->
      let acc = f acc cond in
      let acc = fold_test_stmts acc then_stmts in
      fold_test_stmts acc else_stmts
    | Ast.TsCase { scrut; arms; _ } ->
      let acc = f acc scrut in
      List.fold_left (fun acc (arm : Ast.ts_case_arm) ->
        let acc = match arm.ts_guard with Some g -> f acc g | None -> acc in
        fold_test_stmts acc arm.ts_body
      ) acc arms
    | Ast.TsExpr { e; _ } -> f acc e
  in
  List.fold_left (fun acc decl ->
    match decl with
    | Ast.DFunc fd -> f acc fd.body
    | Ast.DConst c -> f acc c.value
    | Ast.DTest t -> fold_test_stmts acc t.stmts
    | Ast.DApiTest t ->
      let acc = List.fold_left f acc t.seed_stmts in
      fold_test_stmts acc t.stmts
    | Ast.DLoadTest t ->
      let acc = List.fold_left f acc t.seed_stmts in
      fold_test_stmts acc t.request_stmts
    | _ -> acc
  ) acc m.decls

(* ── Signature help ──────────────────────────────────────────────────────────
   {"version":1, "signature": {label, parameters:[{label,type}], active_parameter} | null}
   When the cursor is inside the argument list of a function call, report the
   callee's declared parameter labels + types and which parameter is active. *)

type signature_param = {
  sp_label : string;
  sp_type  : string;
}

type signature_info = {
  si_label            : string;
  si_parameters       : signature_param list;
  si_active_parameter : int;
}

let signature_param_to_json (p : signature_param) : string =
  Printf.sprintf {|{"label":%s,"type":%s}|}
    (json_encode_string p.sp_label) (json_encode_string p.sp_type)

let signature_info_to_json (s : signature_info) : string =
  Printf.sprintf
    {|{"label":%s,"parameters":[%s],"active_parameter":%d}|}
    (json_encode_string s.si_label)
    (String.concat "," (List.map signature_param_to_json s.si_parameters))
    s.si_active_parameter

let signature_to_json = function
  | None -> "null"
  | Some s -> signature_info_to_json s

let signature_help_response_to_json sig_ =
  Printf.sprintf {|{"version":1,"signature":%s}|} (signature_to_json sig_)

(* Map a function declaration to its parameter labels + rendered types and a
   human-readable label "name p1: T1 p2: T2". *)
let signature_of_func_decl (fd : Ast.func_decl) : signature_info =
  let parameters =
    List.map (fun (b : Ast.binding) -> {
      sp_label = b.name;
      sp_type  = Validation_common.pp_type_expr b.type_expr;
    }) fd.params
  in
  let label =
    let params_str =
      String.concat " "
        (List.map (fun p -> Printf.sprintf "%s: %s" p.sp_label p.sp_type) parameters)
    in
    if params_str = "" then fd.name else fd.name ^ " " ^ params_str
  in
  { si_label = label; si_parameters = parameters; si_active_parameter = 0 }

(* Collect every callable function declaration by name (last definition wins). *)
let func_decls_by_name (m : Ast.module_form) : (string * Ast.func_decl) list =
  List.filter_map (function
    | Ast.DFunc fd -> Some (fd.name, fd)
    | _ -> None
  ) m.decls

(* Find the innermost function-application expression that contains the cursor.
   We walk every top-level expression root in the module, descend into every
   sub-expression (pre-order, via {!Ast_visitor.iter}), and keep the
   smallest-span EApp chain whose head is a plain variable naming a function and
   whose overall span contains the position. *)
let signature_help_source filename source line col : signature_info option =
  set_query_source_lines source;
  match parse_module filename source with
  | Err _ -> None
  | Ok m ->
    let funcs = func_decls_by_name m in
    (* best = innermost (smallest span) matching call site *)
    let best : (string * Ast.expr list * Location.loc) option ref = ref None in
    let consider (e : Ast.expr) =
      match e with
      | Ast.EApp _ ->
        let head, args = Checker.flatten_app_expr [] e in
        let call_loc = Checker.expr_loc e in
        (match head with
         | Ast.EVar { name; _ } when List.mem_assoc name funcs ->
           if loc_contains_position call_loc line col then begin
             let better =
               match !best with
               | None -> true
               | Some (_, _, prev) ->
                 compare (loc_specificity_key call_loc) (loc_specificity_key prev) < 0
             in
             if better then best := Some (name, args, call_loc)
           end
         | _ -> ())
      | _ -> ()
    in
    fold_module_expr_roots (fun () e -> Ast_visitor.iter consider e) () m;
    match !best with
    | None -> None
    | Some (name, args, _call_loc) ->
      let fd = List.assoc name funcs in
      let sig_ = signature_of_func_decl fd in
      (* active parameter = how many fully-typed args precede the cursor.
         An argument is "before the cursor" if it ends at/strictly before the
         position; the active param is the count of such complete args, clamped
         to the last parameter index. *)
      let completed =
        List.fold_left (fun acc arg ->
          let aloc = Checker.expr_loc arg in
          if position_leq (aloc.Location.stop.line, aloc.Location.stop.col) (line, col)
             && not (loc_contains_position aloc line col)
          then acc + 1 else acc
        ) 0 args
      in
      let nparams = List.length sig_.si_parameters in
      let active =
        if nparams = 0 then 0 else min completed (nparams - 1)
      in
      Some { sig_ with si_active_parameter = active }

let signature_help_file filename line col =
  let source = In_channel.with_open_text filename In_channel.input_all in
  signature_help_source filename source line col

(* ── Selection range ─────────────────────────────────────────────────────────
   {"version":1, "ranges":[{line,col,end_line,end_col}, ...]}  innermost-first.
   The nested chain of AST node spans covering the cursor (expr → enclosing
   expr/stmt → block → decl). *)

type selection_range = {
  sr_line     : int;
  sr_col      : int;
  sr_end_line : int;
  sr_end_col  : int;
}

let selection_range_of_loc (loc : Location.loc) : selection_range = {
  sr_line     = loc.start.line;
  sr_col      = loc.start.col;
  sr_end_line = loc.stop.line;
  sr_end_col  = loc.stop.col;
}

let selection_range_to_json (r : selection_range) : string =
  Printf.sprintf {|{"line":%d,"col":%d,"end_line":%d,"end_col":%d}|}
    r.sr_line r.sr_col r.sr_end_line r.sr_end_col

let selection_ranges_response_to_json (ranges : selection_range list) : string =
  Printf.sprintf {|{"version":1,"ranges":[%s]}|}
    (String.concat "," (List.map selection_range_to_json ranges))

let selection_range_source filename source line col : selection_range list =
  match parse_module filename source with
  | Err _ -> []
  | Ok m ->
    (* Gather every AST node loc that contains the cursor: every expression
       span (via the recursive expr walk), every top-level declaration span,
       and the enclosing module span itself. *)
    let acc : Location.loc list ref = ref [] in
    let add (loc : Location.loc) =
      if loc_contains_position loc line col then acc := loc :: !acc
    in
    fold_module_expr_roots (fun () root ->
      Ast_visitor.iter (fun e -> add (Checker.expr_loc e)) root
    ) () m;
    List.iter (fun decl -> add (top_decl_loc decl)) m.decls;
    (* Dedup identical spans, then sort innermost (smallest span) first. *)
    let uniq =
      List.fold_left (fun seen loc ->
        if List.exists (loc_equal loc) seen then seen else loc :: seen
      ) [] !acc
    in
    let sorted =
      List.sort (fun a b ->
        compare (loc_specificity_key a) (loc_specificity_key b)
      ) uniq
    in
    List.map selection_range_of_loc sorted

let selection_range_file filename line col =
  let source = In_channel.with_open_text filename In_channel.input_all in
  selection_range_source filename source line col

(* ── Type definition ─────────────────────────────────────────────────────────
   {"version":1, "type_definition": {file,line,col,end_line,end_col} | null}
   Location of the DEFINITION OF THE TYPE of the symbol at the cursor — the
   record / adt / newtype / entity declaration, distinct from --definition-json
   (which goes to the value's binding site). *)

let type_definition_response_to_json (loc : definition_location option) : string =
  Printf.sprintf {|{"version":1,"type_definition":%s}|}
    (match loc with None -> "null" | Some d -> definition_location_to_json d)

(* Strip a rendered type string down to its head type-constructor name so we can
   look it up in the module's type declarations.  e.g. "List Item" -> "List",
   "Maybe User" -> "Maybe", "UserId" -> "UserId". *)
let head_type_name (display_ty : string) : string option =
  let s = String.trim display_ty in
  if s = "" then None
  else
    (* take up to the first space / non-identifier char *)
    let n = String.length s in
    let rec take i =
      if i < n && is_ident_char s.[i] then take (i + 1) else i
    in
    let stop = take 0 in
    if stop = 0 then None else Some (String.sub s 0 stop)

let type_definition_source filename source line col : definition_location option =
  set_query_source_lines source;
  match parse_module filename source with
  | Err _ -> None
  | Ok m ->
    let type_env = collect_definition_env m in
    (* 1. Try expression types from the checker: the type of the expr under the
          cursor, mapped to its declaring record/adt/newtype/entity. *)
    let expr_types, _ = Checker.check_module_with_expr_types m in
    let best =
      List.fold_left (fun best info ->
        if loc_contains_position info.Checker.loc line col && better_expr_type best info
        then Some info else best
      ) None expr_types
    in
    let from_expr_type =
      match best with
      | None -> None
      | Some info ->
        (match head_type_name info.Checker.display_ty with
         | None -> None
         | Some tname -> find_named_loc type_env.type_defs tname)
    in
    match from_expr_type with
    | Some loc -> Some (location_to_definition loc)
    | None ->
      (* 2. Fall back: cursor is itself on a type name / value whose declared
            type we can resolve via the same symbol resolver. *)
      (match find_map_list (resolve_symbol_in_top_decl type_env line col) m.decls with
       | Some { symbol_kind = TypeSymbol; symbol_name; _ } ->
         (match find_named_loc type_env.type_defs symbol_name with
          | Some loc -> Some (location_to_definition loc)
          | None -> None)
       | _ -> None)

let type_definition_file filename line col =
  let source = In_channel.with_open_text filename In_channel.input_all in
  type_definition_source filename source line col

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
  and visit_expr e =
    (* Only the legacy-bool-bearing variants get bespoke handling; the
       structural recursion into every other variant's children is delegated to
       {!Ast_visitor.iter_children}, the single shared traversal.  This is what
       fixes the historical bug where [EFail _ -> ()] never descended into
       [EFail.message] (an expr): the structural default now visits it, so a
       legacy `true`/`false`/`Boolean` inside a fail message is diagnosed too.
       ELambda additionally needs its parameter *types* walked for `Boolean`/
       `bool` annotations — bindings carry type_expr, which the expr visitor
       (correctly) does not traverse — so that arm is kept explicit. *)
    match e with
    | ELit { lit = LBool true; loc } ->
        diags := legacy_bool_diag source_lines loc ~old_text:"true" ~replacement:"True"
          ~message:"use `True`, not `true`" :: !diags
    | ELit { lit = LBool false; loc } ->
        diags := legacy_bool_diag source_lines loc ~old_text:"false" ~replacement:"False"
          ~message:"use `False`, not `false`" :: !diags
    | EConstructor { name = ("True" | "False"); args = []; loc } ->
        note_bool_ctor_use loc
    | ELambda { params; body; _ } ->
        List.iter visit_binding params; visit_expr body
    | _ -> Ast_visitor.iter_children visit_expr e
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

(* ── WS1: opt-in per-phase wall-clock timing ────────────────────────────────
   When the environment variable [TESL_PHASE_TIMING=1] is set, each compiler
   phase (parse / typecheck / proof / validation / emit) prints its wall-clock
   duration in milliseconds to *stderr* so it never pollutes the emitted Racket
   on stdout.  When the flag is unset the cost is a single [Sys.getenv_opt]
   lookup per [compile_source] call and the phase thunks run unwrapped — no
   timing, no allocation, no stderr writes. *)
let phase_timing_enabled () =
  match Sys.getenv_opt "TESL_PHASE_TIMING" with
  | Some ("1" | "true" | "TRUE" | "yes" | "YES" | "on" | "ON") -> true
  | _ -> false

(** Run [f ()], and when [enabled] print "[phase-timing] <label>: <ms> ms" to
    stderr.  Returns [f]'s result unchanged.  When [enabled] is false, [f] is
    called directly with no timing overhead. *)
let time_phase enabled label (f : unit -> 'a) : 'a =
  if not enabled then f ()
  else begin
    let t0 = Unix.gettimeofday () in
    let result = f () in
    let elapsed_ms = (Unix.gettimeofday () -. t0) *. 1000.0 in
    Printf.eprintf "[phase-timing] %-10s %8.3f ms\n%!" label elapsed_ms;
    result
  end

(* Typecheck → diagnostics, factored out of [check_module] so the timed
   pipeline in [compile_source] can reuse the *identical* diagnostic-building
   logic (including the bare-record-literal quick-fix) without duplicating it. *)
let type_diags_of source (m : Ast.module_form) : diagnostic list =
  let source_lines = Array.of_list (String.split_on_char '\n' source) in
  let _, _, _, bare_hints, type_errors = Checker.check_module_with_metadata m in
  List.map (fun (e : Type_system.type_error) ->
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
  ) type_errors

(** Produce a diagnostic for each pair of files involved in an import cycle.
    Returns [] if the file is synthetic (empty path, <test>, etc.). *)
(** Run the full check pipeline on a parsed module; returns diagnostics. *)
let check_module source (m : Ast.module_form) : diagnostic list =
  legacy_bool_diagnostics m.source_file source m
  @ type_diags_of source m
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
let compile_source ?(root_path=default_root_path ()) ?(type_check=true) ?(debug=false) filename source =
  (* Read the timing flag exactly once per compile; [time_phase] is a no-op
     wrapper when it is false, so the non-timing path is unchanged. *)
  let timing = phase_timing_enabled () in
  match time_phase timing "parse" (fun () -> parse_module filename source) with
  | Err e -> Failure [diag_of_parse_error e]
  | Ok m ->
    let diags =
      if not type_check then []
      else
        (* Same phases, same order as [check_module]; split here only so each
           wall-clock segment can be reported independently.  The list built is
           byte-identical to [check_module source m]. *)
        let type_diags =
          time_phase timing "typecheck" (fun () ->
            legacy_bool_diagnostics m.source_file source m
            @ type_diags_of source m)
        in
        let proof_diags =
          time_phase timing "proof" (fun () ->
            List.map diag_of_proof_error (Proof_checker.check_module m))
        in
        let validation_diags =
          time_phase timing "validation" (fun () ->
            List.map diag_of_validation_error (Validation.check_module m))
        in
        type_diags @ proof_diags @ validation_diags
    in
    if diags <> [] then Failure diags
    else begin
      Emit_racket.set_debug_mode debug;
      (* Desugar AFTER all enforcement/diagnostics ran on the surface forms,
         BEFORE emit.  Identity-preserving today (see Desugar). *)
      let m = time_phase timing "desugar" (fun () -> Desugar.desugar_module m) in
      let racket =
        time_phase timing "emit" (fun () ->
          Emit_racket.compile_to_string ~root_path m)
      in
      Emit_racket.set_debug_mode false;
      Success racket
    end

let compile_file ?(root_path=default_root_path ()) ?(type_check=true) filename =
  (* WS1: same opt-in per-phase timing as [compile_source].  This is the entry
     point the CLI file-compile path (`tesl <file>`) actually uses, so timing
     must live here too.  No-op when TESL_PHASE_TIMING is unset. *)
  let timing = phase_timing_enabled () in
  let source = In_channel.with_open_text filename In_channel.input_all in
  match time_phase timing "parse" (fun () -> parse_module filename source) with
  | Err e -> Failure [diag_of_parse_error e]
  | Ok m ->
    let diags =
      if not type_check then []
      else
        let type_diags =
          time_phase timing "typecheck" (fun () ->
            legacy_bool_diagnostics m.source_file source m
            @ type_diags_of source m)
        in
        let proof_diags =
          time_phase timing "proof" (fun () ->
            List.map diag_of_proof_error (Proof_checker.check_module m))
        in
        let validation_diags =
          time_phase timing "validation" (fun () ->
            List.map diag_of_validation_error (Validation.check_module m))
        in
        type_diags @ proof_diags @ validation_diags
    in
    if diags <> [] then Failure diags
    else
      (* Desugar AFTER enforcement/diagnostics, BEFORE emit (identity today). *)
      let m = time_phase timing "desugar" (fun () -> Desugar.desugar_module m) in
      let racket =
        time_phase timing "emit" (fun () ->
          let cyclic_local_import_paths =
            if m.source_file = "" || m.source_file = "<test>" then []
            else cyclic_local_import_paths_for_entry m.source_file
          in
          Emit_racket.compile_to_string
            ~root_path
            ~cyclic_local_import_paths
            m)
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

(* ── WS4: whole-project / batch checking ─────────────────────────────────────
   A normal `tesl --check f1 f2 ...` already checks N files in one OS process,
   so it pays the process-spawn cost once instead of N times.  These helpers go
   one step further: they share the imported-module parse cache
   ([Checker.import_parse_cache]) across every file in the run, so a project
   whose files share local imports (e.g. several modules all importing a common
   `Db`/`Auth` module) parses each imported module *once* for the whole batch
   instead of once per consumer.

   Per-file results are returned as an ordered association list so callers can
   report a per-file pass/fail summary.  Each file is checked independently:
   the diagnostics for one file are exactly what `check_file` would produce for
   it on its own (the cache only avoids redundant *imported-module* parses, it
   never shares the primary module's check state), so batch output is identical
   to running the files separately. *)

(** Check each of [filenames] in one process, sharing the imported-module parse
    cache.  Returns [(filename, diagnostics)] in input order. *)
let check_files_batch (filenames : string list) : (string * diagnostic list) list =
  List.map (fun filename ->
    let diags =
      try check_file filename
      with Sys_error msg ->
        [{ file = filename; start_line = 0; start_col = 0;
           end_line = 0; end_col = 0; severity = "error";
           code = "E000"; message = msg; fix = None; source = "io" }]
    in
    (filename, diags)
  ) filenames

(** Recursively collect every `.tesl` file under [dir] (sorted, deterministic).
    A plain file path is returned as-is if it ends in `.tesl`. *)
let collect_tesl_files (dir : string) : string list =
  let acc = ref [] in
  let rec walk path =
    match (try Some (Sys.is_directory path) with Sys_error _ -> None) with
    | Some true ->
      let entries = try Sys.readdir path with Sys_error _ -> [||] in
      Array.sort compare entries;
      Array.iter (fun name -> walk (Filename.concat path name)) entries
    | Some false ->
      if Filename.check_suffix path ".tesl" then acc := path :: !acc
    | None -> ()
  in
  walk dir;
  List.rev !acc

(** `--check-all <dir>`: recursively find and batch-check every `.tesl` file
    under [dir].  Returns [(filename, diagnostics)] in sorted path order. *)
let check_all_in_dir (dir : string) : (string * diagnostic list) list =
  check_files_batch (collect_tesl_files dir)

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
  | Ok m  -> Some (semantic_json_of_module m)
  | Err _ ->
    (* Resilient path (editor/LSP): the buffer has a syntax error, but the
       parser's top-level recovery can still salvage the declarations that did
       parse.  Emit a best-effort snapshot of those rather than [None], so
       completion/hover/documentSymbol degrade gracefully mid-edit.  The full
       checker may itself raise on a partial module, so guard it. *)
    (match Parser.parse_module_recover filename source with
     | None -> None
     | Some m -> (try Some (semantic_json_of_module m) with _ -> None))

let semantic_json_file filename =
  let source = In_channel.with_open_text filename In_channel.input_all in
  semantic_json_source filename source

(* ── AC1: agent-context snapshot ─────────────────────────────────────────── *)
(** `--agent-context-json <file>` (alias `tesl agent-context <file>`): a
    token-economical compiler/linter snapshot designed to be re-read by an AI
    coding agent after each edit, instead of the [--semantic-json] firehose.

    DELIBERATELY SMALL: top-level symbol signatures ONLY (no bodies), the
    diagnostics (errors ranked first, then warnings), and the outstanding proof
    obligations.  NO [expr_types] array, NO local bindings, NO bodies — so the
    payload stays a tiny fraction of [--semantic-json].

    Schema version 1.  Line/col values are 0-based, matching every other
    compiler JSON output.  The [content_hash] is computed identically to
    [--semantic-json] ([Digest.to_hex (Digest.string source)]) so an agent can
    reuse one cache key across both outputs.

    PROOF-OBLIGATION SOURCE: the compiler has no separate "outstanding
    obligation" stream; an unproven obligation surfaces as a diagnostic from the
    proof checker.  So [proof_obligations] is derived from exactly the
    diagnostics whose [source] is ["proof-checker"] (stable code ["P001"]) — see
    [is_proof_obligation_diag].  This is stated in the [notes] of the structured
    report. *)

(* Cap any list at this many entries to keep the snapshot small; the surplus
   count is reported in an "omitted" field so an agent knows the list is
   truncated rather than complete. *)
let agent_context_cap = 50

(* A diagnostic is a (proof/capability) obligation iff it came from the proof
   checker.  Proof errors carry code "P001" and source "proof-checker"
   ([diag_of_proof_error]); capability requirements that go unsatisfied are
   reported through the same proof-checker stream. *)
let is_proof_obligation_diag (d : diagnostic) = d.source = "proof-checker"

(* Stable error-first ordering: error severities sort before everything else,
   then by (line, col), so the most actionable items lead.  [List.stable_sort]
   keeps the original relative order within a severity bucket. *)
let severity_rank = function
  | "error" -> 0
  | "warning" | "warn" -> 1
  | _ -> 2

let rank_diagnostics_errors_first (diags : diagnostic list) : diagnostic list =
  List.stable_sort (fun a b ->
    let c = compare (severity_rank a.severity) (severity_rank b.severity) in
    if c <> 0 then c
    else
      let c = compare a.start_line b.start_line in
      if c <> 0 then c else compare a.start_col b.start_col
  ) diags

(* Take the first [cap] elements; return them with the omitted surplus count. *)
let cap_list cap xs =
  let n = List.length xs in
  if n <= cap then (xs, 0)
  else
    let rec take k = function
      | x :: rest when k > 0 -> x :: take (k - 1) rest
      | _ -> []
    in
    (take cap xs, n - cap)

(* Compact diagnostic record for the agent snapshot: the stable code, severity,
   message, 0-based span, and a machine-applicable fix when one is available.
   Distinct from [diag_to_json] (which also carries file/source) — this trims
   redundant fields the agent already knows (the file) to save tokens. *)
let agent_diag_json (d : diagnostic) : string =
  let base = [
    "code",       json_str d.code;
    "severity",   json_str d.severity;
    "message",    json_str d.message;
    "line",       string_of_int d.start_line;
    "col",        string_of_int d.start_col;
    "end_line",   string_of_int d.end_line;
    "end_col",    string_of_int d.end_col;
  ] in
  let with_fix = match d.fix with
    | None -> base
    | Some _ -> base @ ["fix", fix_to_json d.fix]
  in
  json_obj with_fix

(* One outstanding proof obligation: location, message, and stable code. *)
let agent_obligation_json (d : diagnostic) : string =
  json_obj [
    "line",    string_of_int d.start_line;
    "col",     string_of_int d.start_col;
    "message", json_str d.message;
    "code",    json_str d.code;
  ]

(* Top-level symbol: name, kind, and signature/type ONLY — never a body. *)
let agent_symbol_json ~name ~kind ~signature : string =
  json_obj [
    "name",      json_str name;
    "kind",      json_str kind;
    "signature", json_str signature;
  ]

(* Build the top-level symbol list from the parsed module's declarations.
   Mirrors the declared-signature approach in [semantic_json_of_module]: for
   functions we render the param/return arrow type; for types/records/entities
   we render a compact structural signature.  No bodies, no expr types. *)
let agent_symbols_of_module (m : Ast.module_form) : string list =
  let field_sig (f : Ast.field_def) =
    Printf.sprintf "%s: %s" f.name (Type_system.pp_ty (Checker.ty_of_type_expr f.type_expr))
  in
  List.filter_map (function
    | Ast.DFunc fd ->
      let param_tys = List.map (fun (b : Ast.binding) ->
        Type_system.pp_ty (Checker.ty_of_type_expr b.type_expr)) fd.params in
      let ret_ty = Type_system.pp_ty (Checker.ret_spec_type fd.return_spec) in
      let signature = match param_tys with
        | [] -> ret_ty
        | ps -> String.concat " -> " ps ^ " -> " ^ ret_ty
      in
      let kind = (match fd.kind with
        | Ast.FnKind         -> "fn"
        | Ast.HandlerKind    -> "handler"
        | Ast.WorkerKind     -> "worker"
        | Ast.DeadWorkerKind -> "worker"
        | Ast.CheckKind      -> "check"
        | Ast.AuthKind       -> "auth"
        | Ast.EstablishKind  -> "establish"
        | Ast.MainKind       -> "main") in
      Some (agent_symbol_json ~name:fd.name ~kind ~signature)
    | Ast.DType (Ast.TypeNewtype { name; base_type; _ }) ->
      Some (agent_symbol_json ~name ~kind:"newtype"
              ~signature:(Type_system.pp_ty (Checker.ty_of_type_expr base_type)))
    | Ast.DType (Ast.TypeAlias { name; base_type; _ }) ->
      Some (agent_symbol_json ~name ~kind:"alias"
              ~signature:(Type_system.pp_ty (Checker.ty_of_type_expr base_type)))
    | Ast.DType (Ast.TypeAdt { name; variants; _ }) ->
      let ctors = List.map (fun (v : Ast.adt_variant) -> v.ctor) variants in
      Some (agent_symbol_json ~name ~kind:"type"
              ~signature:(String.concat " | " ctors))
    | Ast.DRecord r ->
      let sig_str = "{ " ^ String.concat ", " (List.map field_sig r.fields) ^ " }" in
      Some (agent_symbol_json ~name:r.name ~kind:"record" ~signature:sig_str)
    | Ast.DEntity e ->
      let sig_str = "{ " ^ String.concat ", " (List.map field_sig e.fields) ^ " }" in
      Some (agent_symbol_json ~name:e.name ~kind:"entity" ~signature:sig_str)
    | Ast.DConst c ->
      Some (agent_symbol_json ~name:c.name ~kind:"const" ~signature:"unknown")
    | _ -> None
  ) m.decls

(* Render the full agent-context object from already-computed pieces. *)
let agent_context_to_json
    ~file ~content_hash ~(diagnostics : diagnostic list) ~symbols : string =
  let ranked = rank_diagnostics_errors_first diagnostics in
  let n_errors = List.length (List.filter (fun d -> severity_rank d.severity = 0) ranked) in
  let n_warnings = List.length (List.filter (fun d -> severity_rank d.severity = 1) ranked) in
  let obligations = List.filter is_proof_obligation_diag ranked in
  let n_oblig = List.length obligations in
  let ok = n_errors = 0 in
  let summary =
    Printf.sprintf "%d error%s, %d warning%s; %d unproven obligation%s"
      n_errors  (if n_errors = 1 then "" else "s")
      n_warnings (if n_warnings = 1 then "" else "s")
      n_oblig   (if n_oblig = 1 then "" else "s")
  in
  let diags_capped, diags_omitted = cap_list agent_context_cap ranked in
  let symbols_capped, symbols_omitted = cap_list agent_context_cap symbols in
  let oblig_capped, oblig_omitted = cap_list agent_context_cap obligations in
  (* The three lists are plain arrays (matching the documented shape).  When any
     list is truncated, a sibling "omitted" object names the surplus counts; it
     is present only when something was actually capped, so the common
     (uncapped) snapshot carries no extra bytes. *)
  let omitted_pairs =
    List.filter_map (fun (k, n) -> if n = 0 then None else Some (k, string_of_int n))
      ["diagnostics", diags_omitted;
       "symbols", symbols_omitted;
       "proof_obligations", oblig_omitted]
  in
  let base = [
    "version",      "1";
    "file",         json_str file;
    "content_hash", json_str content_hash;
    "ok",           if ok then "true" else "false";
    "summary",      json_str summary;
    "diagnostics",  json_arr (List.map agent_diag_json diags_capped);
    "symbols",      json_arr symbols_capped;
    "proof_obligations", json_arr (List.map agent_obligation_json oblig_capped);
  ] in
  json_obj (if omitted_pairs = [] then base else base @ ["omitted", json_obj omitted_pairs])

(** Produce the agent-context JSON for [source] under [filename].  Always
    returns a snapshot: on a parse error the diagnostics carry the parse error
    and [symbols] is empty (best-effort, so an agent still gets the error). *)
let agent_context_source filename source : string =
  let content_hash = Digest.to_hex (Digest.string source) in
  let diagnostics = check_source filename source in
  let symbols =
    match parse_module filename source with
    | Ok m -> agent_symbols_of_module m
    | Err _ ->
      (match Parser.parse_module_recover filename source with
       | Some m -> (try agent_symbols_of_module m with _ -> [])
       | None -> [])
  in
  agent_context_to_json ~file:filename ~content_hash ~diagnostics ~symbols

let agent_context_file filename : string =
  let source = In_channel.with_open_text filename In_channel.input_all in
  agent_context_source filename source

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

(** Per-mutant wall-clock budget (seconds) for one [raco test] run.  Generous
    enough for a real DSL test suite to warm up and run, but bounded so a mutant
    that introduces a non-terminating loop cannot hang the whole session. *)
let mutant_timeout_secs =
  (* Per-mutant wall-clock ceiling (DSL warmed, so runs are fast — this only
     bounds hangs).  Honors TESL_MUTATE_TIMEOUT (main's knob); default 120s. *)
  match Sys.getenv_opt "TESL_MUTATE_TIMEOUT" with
  | Some s -> (try int_of_string s with _ -> 120)
  | None   -> 120

(** Shell prefix that bounds a command's wall-clock time, when the coreutils
    [timeout] utility is available; empty otherwise (so the command still runs,
    just unbounded).  Computed once.  [timeout] exits 124 when the budget is
    exceeded, which [classify_mutant_run] treats as a kill. *)
let timeout_prefix = lazy (
  if Sys.command "command -v timeout >/dev/null 2>&1" = 0
  then Printf.sprintf "timeout %d " mutant_timeout_secs
  else "")

(** Run [cmd] via the shell, capturing its combined stdout+stderr and exit code.
    Output is redirected to a temporary file and read back, so this depends only
    on [Sys.command] (whose result is the shell exit code, already decoded — a
    process killed by a signal surfaces as a non-zero [128 + signo] code, and
    [timeout] surfaces as 124).  Callers that treat "non-zero ⇒ failure" thus
    handle test failures, crashes, and timeouts uniformly.  Returns
    [(exit_code, output)]. *)
let run_capture cmd : int * string =
  let out_tmp = Filename.temp_file "tesl_mutant_out_" ".txt" in
  Fun.protect
    ~finally:(fun () -> (try Sys.remove out_tmp with Sys_error _ -> ()))
    (fun () ->
       let full = Printf.sprintf "%s > %s 2>&1" cmd (Filename.quote out_tmp) in
       let exit_code = Sys.command full in
       let output =
         try In_channel.with_open_text out_tmp In_channel.input_all
         with Sys_error _ -> ""
       in
       (exit_code, output))

(** [true] when [output] contains a rackunit failure/error marker.  rackunit
    prints a "FAILURE" banner for every failed check ([exn:test:check]) and an
    "ERROR" banner for any other raised exception, each on its own line.  This
    mirrors the failure detection in [tests/example-test-batch.rkt]. *)
let output_indicates_failure output =
  (* Implemented with a plain line scan rather than [Str]: this predicate runs
     on worker domains during parallel mutant evaluation, and [Str]'s matcher
     keeps global, non-reentrant match state that is unsafe to touch from
     several domains at once.  A line scan is allocation-light and trivially
     thread-safe.  Equivalent to the regex "(^|\n)(FAILURE|ERROR)(\n|$)": true
     iff some line of [output] is exactly "FAILURE" or exactly "ERROR". *)
  List.exists (fun line -> line = "FAILURE" || line = "ERROR")
    (String.split_on_char '\n' output)

(** Classify a single mutant's [raco test] run.  Returns [true] when the mutant
    SURVIVED (the test suite demonstrably ran and passed), [false] when it was
    KILLED.

    A mutant is a survivor ONLY when the run exited 0 AND produced no rackunit
    failure/error marker.  Any non-zero exit (test failure, raised exception,
    module load/expansion error, crash, or a timeout — [timeout] exits 124) is
    a kill.  Crucially, an exit of 0 that is nonetheless accompanied by a
    "FAILURE"/"ERROR" marker is ALSO a kill: this guards against the case where
    [raco test] reports success without actually exercising the test suite to a
    clean pass, which previously caused genuinely-killed mutants to be reported
    as false survivors. *)
let classify_mutant_run ~exit_code ~output =
  exit_code = 0 && not (output_indicates_failure output)

(** Number of mutant [raco test] processes to run concurrently.  Defaults to
    the machine's available parallelism (≈ [nproc]), capped at 16 so a very
    large core count doesn't spawn an unreasonable number of Racket processes,
    and floored at 1.  [TESL_MUTATE_JOBS] overrides it (1 ⇒ fully serial, which
    is handy for A/B'ing the parallel path against the historical behaviour). *)
let mutate_jobs =
  let detected =
    let n = Domain.recommended_domain_count () in
    if n < 1 then 1 else if n > 16 then 16 else n
  in
  match Sys.getenv_opt "TESL_MUTATE_JOBS" with
  | Some s -> (match int_of_string_opt s with Some n when n >= 1 -> n | _ -> detected)
  | None   -> detected

(** Run [f 0], …, [f (n-1)] across a bounded pool of at most [jobs] worker
    domains and return their results in an array indexed by [i] (so the output
    order is independent of which worker ran which item).

    Each worker repeatedly claims the next index via a single mutex-guarded
    counter and stores [f i] at [results.(i)].  This is the canonical
    "shared work queue" pattern: the only mutable state shared across domains is
    the [next] counter (protected by [mu]) and disjoint cells of [results]
    (each written by exactly one worker), so there are no data races and the
    collated result array is deterministic.  [f] is expected to do its heavy
    lifting in an external process (here, [raco test]), so blocking workers
    simply let the OS schedule those subprocesses concurrently.

    With [jobs <= 1] (or [n <= 1]) it runs inline on the calling domain, so the
    fully-serial path spawns no domains at all. *)
let parallel_map ~jobs (n : int) (f : int -> 'a) : 'a array =
  if n = 0 then [||]
  else begin
    (* Results land in an [option] array so the array can be allocated before
       any element is computed without needing a dummy ['a] value; each cell is
       filled exactly once (by the worker that claimed that index) and unwrapped
       at the end. *)
    let results : 'a option array = Array.make n None in
    let store i v = results.(i) <- Some v in
    if jobs <= 1 || n = 1 then
      for i = 0 to n - 1 do store i (f i) done
    else begin
      let mu = Mutex.create () in
      let next = ref 0 in
      let claim () =
        Mutex.lock mu;
        let i = !next in
        if i < n then incr next;
        Mutex.unlock mu;
        if i < n then Some i else None
      in
      let worker () =
        let rec loop () =
          match claim () with
          | None   -> ()
          | Some i -> store i (f i); loop ()
        in
        loop ()
      in
      let pool = min jobs n in
      let domains = List.init pool (fun _ -> Domain.spawn worker) in
      List.iter Domain.join domains
    end;
    Array.map (function Some v -> v | None -> assert false) results
  end

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
       (* Warm the Tesl DSL bytecode ONCE before timing any mutant.  The first
          per-mutant `raco test` otherwise cold-compiles the whole DSL (~10-13s),
          which can exceed [timeout_secs] and misclassify a genuinely-killed mutant
          as [Error] (124).  Compiling the original module's emitted .rkt with
          `raco make` builds the shared DSL .zo so each subsequent `raco test` just
          loads it.  Best-effort: any failure here is harmless (mutants still run). *)
       (let base_module =
          if extra_test_decls = [] then m
          else { m with decls = m.decls @ extra_test_decls }
        in
        match (try Some (Emit_racket.compile_to_string ~root_path base_module)
               with _ -> None) with
        | None -> ()
        | Some r ->
          let warm = Filename.temp_file "tesl_mutant_warm_" ".rkt" in
          Fun.protect
            ~finally:(fun () -> (try Sys.remove warm with Sys_error _ -> ()))
            (fun () ->
              Out_channel.with_open_text warm
                (fun oc -> Out_channel.output_string oc r);
              ignore (Sys.command
                (Printf.sprintf "raco make %s >/dev/null 2>&1" (Filename.quote warm)))));
       (* ── Phase 1 (SERIAL): emit + prepare every mutant ─────────────────────
          [Emit_racket.compile_to_string] mutates module-level tables
          (qualified imports, queue map, …), so it is NOT safe to call from
          several domains at once; doing so could corrupt the emitted Racket and
          silently change which mutants are killed.  We therefore emit all
          mutants here, in deterministic order, on the calling domain.  Emission
          is pure OCaml and cheap relative to a `raco test` run, so keeping it
          serial costs little.  Each mutant becomes either a *final* result
          (emit failure ⇒ [Error]; no test block ⇒ [NoTests]) or a [`Run]
          carrying the temp `.rkt` path whose `raco test` must still run.

          DB stub: infrastructure-touching test blocks (Postgres DB / server /
          queue / cache / email) are stripped from each mutant via
          [Mutate.strip_infra_tests] so they cannot hang a DB-less mutant run.
          Files with no such tests (lesson42, lesson44, …) are unaffected, so
          their mutation score is identical to the un-stubbed serial run. *)
       let arr = Array.of_list mutants in
       let n = Array.length arr in
       let prepared = Array.map (fun (mut : Mutate.mutant) ->
         (* Merge extra tests into this mutant's module, then strip the
            infrastructure-touching ones before emitting. *)
         let module_with_tests =
           let merged =
             if extra_test_decls = [] then mut.module_
             else { mut.module_ with decls = mut.module_.decls @ extra_test_decls }
           in
           Mutate.strip_infra_tests merged
         in
         (* Emit without type-checking — the mutant may be semantically
            invalid from the proof perspective, but Racket will still run
            the runtime checks and tests. *)
         match (try Some (Emit_racket.compile_to_string ~root_path module_with_tests)
                with _ -> None)
         with
         | None   -> `Done (Mutate.Error "emit error")
         | Some r ->
           let has_test = List.exists (function Ast.DTest _ -> true | _ -> false) module_with_tests.decls in
           if not has_test then `Done Mutate.NoTests
           else begin
             let tmp = Filename.temp_file "tesl_mutant_" ".rkt" in
             Out_channel.with_open_text tmp
               (fun oc -> Out_channel.output_string oc r);
             `Run tmp
           end
       ) arr in
       (* ── Phase 2 (PARALLEL): run the `raco test` of each prepared mutant ────
          Only the external [raco test] subprocess is parallelized, across a
          bounded pool of [mutate_jobs] worker domains.  Classification is
          byte-for-byte identical to the serial path: a mutant SURVIVES only on
          exit 0 with no rackunit FAILURE/ERROR marker; exit 124 (timeout, e.g.
          an unavailable DB) is [Error]; everything else is KILLED.  Results are
          collated by mutant index, so the report order — and thus the score —
          is independent of which worker ran which mutant. *)
       (* Force the [lazy] timeout prefix ONCE here, on the calling domain:
          [Lazy.force] is not safe to evaluate concurrently from several domains
          (it raises [CamlinternalLazy.Undefined]), so resolve it before the
          pool starts and pass the plain string to the workers. *)
       let timeout_pfx = Lazy.force timeout_prefix in
       let run_one i =
         match prepared.(i) with
         | `Done result -> result
         | `Run tmp ->
           Fun.protect
             ~finally:(fun () -> (try Sys.remove tmp with Sys_error _ -> ()))
             (fun () ->
               let cmd = Printf.sprintf "%sraco test --quiet %s"
                           timeout_pfx (Filename.quote tmp) in
               let exit_code, output = run_capture cmd in
               if exit_code = 124 then Mutate.Error "raco test timed out (no DB?)"
               else if classify_mutant_run ~exit_code ~output then Mutate.Survived
               else Mutate.Killed)
       in
       let result_arr = parallel_map ~jobs:mutate_jobs n run_one in
       let results = List.mapi (fun i mut -> (mut, result_arr.(i))) mutants in
       let killed   = List.length (List.filter (fun (_, r) -> r = Mutate.Killed)   results) in
       let survived = List.length (List.filter (fun (_, r) -> r = Mutate.Survived) results) in
       let errors   = List.length (List.filter (fun (_, r) -> match r with Mutate.Error _ -> true | _ -> false) results) in
       MutateOk { Mutate.total = List.length mutants; killed; survived; errors; results }))

(* ── WS6: standalone-executable build (`tesl --exe`) ─────────────────────────
   Emit the program's Racket *exactly* as `tesl <file>` would (byte-identical
   — this reuses [compile_file], so the distribution path never changes the
   emitted source) and then bundle it into a standalone native executable with
   `raco exe`.

   The `.rkt` is written next to the source file (`<src>.rkt`), not to a temp
   dir, because emitted local-import requires use *relative* `(file "X.rkt")`
   paths resolved against the requiring module's own directory.  Writing in
   place lets those resolve against the sibling emitted `.rkt` files (the same
   layout `tesl <file> > <file>.rkt` already produces).  `raco exe` then
   inlines every required module — including the `tesl/...` DSL collection — so
   the resulting binary starts without paying the Racket source cold-start and
   needs no `raco link`.  (Data files referenced at runtime, e.g. a server's
   `#:static-dir`, are not bundled by `raco exe`; that is a `raco distribute`
   concern, out of scope here.) *)
type build_result =
  | BuildOk      of string          (** path to the produced executable *)
  | BuildDiags   of diagnostic list (** compile/type errors — nothing emitted *)
  | BuildErr     of string          (** raco/IO failure with combined output *)

(** Compile [filename] and bundle it into a standalone executable.
    [out] overrides the executable path (default: source basename without the
    `.tesl` suffix).  Requires `raco` on PATH. *)
let build_exe ?(root_path=default_root_path ()) ?out filename : build_result =
  if not (Sys.file_exists filename) then
    BuildErr (Printf.sprintf "%s: No such file" filename)
  else
    match compile_file ~root_path ~type_check:true filename with
    | Failure diags -> BuildDiags diags
    | Success racket ->
      (* Emit the .rkt next to the source so relative (file ...) requires of
         sibling modules resolve (identical layout to `tesl <file> > x.rkt`). *)
      let stem =
        if Filename.check_suffix filename ".tesl"
        then Filename.chop_suffix filename ".tesl"
        else filename
      in
      let rkt_path = stem ^ ".rkt" in
      let exe_path = match out with Some p -> p | None -> stem in
      (try
         Out_channel.with_open_text rkt_path
           (fun oc -> Out_channel.output_string oc racket);
         let cmd =
           Printf.sprintf "raco exe -o %s %s"
             (Filename.quote exe_path) (Filename.quote rkt_path)
         in
         let exit_code, output = run_capture cmd in
         if exit_code = 0 then BuildOk exe_path
         else BuildErr
             (Printf.sprintf "raco exe failed (exit %d):\n%s" exit_code output)
       with Sys_error msg -> BuildErr msg)

(* ── AC2: headless `tesl debug-inspect` ──────────────────────────────────────
   Compile a .tesl with debug instrumentation, then run it headlessly to a single
   breakpoint via the Racket driver dsl/debug/headless-inspect.rkt, which dumps the
   paused runtime state (locals + live domain registry + SQL capture) as ONE JSON
   object on stdout.  No DAP client, no interactive protocol.

   The compiled .rkt bakes its breakpointable source positions from the path
   handed to the parser, so we compile with the COMPLETE (absolute) path and hand
   that SAME absolute path to the driver — only then does the breakpoint line we
   register match the file string in the emitted thsl-src! checkpoints. *)
type debug_inspect_result =
  | InspectDiags of diagnostic list   (* compile failed *)
  | InspectErr of string              (* setup/exec failure *)
  (* InspectOk never returns: a successful run execs the racket driver, which
     streams its JSON to stdout and exits — replacing this process. *)

(** Locate the `racket` executable: honour TESL_RACKET, else search PATH. *)
let find_racket_binary () : string option =
  match Sys.getenv_opt "TESL_RACKET" with
  | Some p when p <> "" -> Some p
  | _ ->
    let exit_code, out = run_capture "command -v racket" in
    if exit_code = 0 then
      (match String.trim out with "" -> None | s -> Some s)
    else None

(** Run [file] to the FIRST matching breakpoint and dump the paused runtime state
    as JSON.  [breakpoints] is a list of [(line, condition, hit)] triples — the
    agent's requested breakpoints, each a 1-based [line] with an optional boolean
    [condition] string (evaluated over the paused frame's locals) and/or an
    optional [hit] hit-condition string (e.g. ["%3"] / [">=5"]).  Multiple
    breakpoints are all registered; the inspector stops at whichever fires first
    and the JSON's "breakpoint" field reports which.  [mode] is "program" (run the
    `main` block) or "test" (run the `test` blocks).  On success this execs the
    Racket driver and never returns; the JSON appears on the inherited stdout. *)
let debug_inspect ?(root_path=default_root_path ()) ~breakpoints ~mode filename
  : debug_inspect_result =
  if not (Sys.file_exists filename) then
    InspectErr (Printf.sprintf "%s: No such file" filename)
  else begin
    (* Absolute source path — must match the file string the emitter bakes into
       the thsl-src! checkpoints so the registered breakpoint line lines up. *)
    let abs_src =
      let p = if Filename.is_relative filename
              then Filename.concat (Sys.getcwd ()) filename
              else filename in
      (try Unix.realpath p with _ -> p)
    in
    (* Compile with debug instrumentation, parsing under the absolute path. *)
    let source = In_channel.with_open_text abs_src In_channel.input_all in
    match compile_source ~root_path ~type_check:true ~debug:true abs_src source with
    | Failure diags -> InspectDiags diags
    | Success racket ->
      (try
         let tmp_rkt = Filename.temp_file "tesl-debug-inspect-" ".rkt" in
         Out_channel.with_open_text tmp_rkt
           (fun oc -> Out_channel.output_string oc racket);
         let driver =
           let primary = Filename.concat root_path "dsl/debug/headless-inspect.rkt" in
           if Sys.file_exists primary then primary
           else
             (* Installed (no repo checkout): the inspector ships inside the
                tesl-racket collections, located via TESL_COLLECTIONS_DIR (set by
                the Nix wrappers to <store>/share/tesl-collections/tesl). *)
             (match Sys.getenv_opt "TESL_COLLECTIONS_DIR" with
              | Some d when d <> "" ->
                let c = Filename.concat d "dsl/debug/headless-inspect.rkt" in
                if Sys.file_exists c then c else primary
              | _ -> primary)
         in
         if not (Sys.file_exists driver) then
           InspectErr (Printf.sprintf
             "headless inspector not found at %s (set TESL_REPO_ROOT or TESL_COLLECTIONS_DIR)" driver)
         else
           (match find_racket_binary () with
            | None -> InspectErr "racket not found; set TESL_RACKET or install Racket"
            | Some racket_bin ->
              (* TESL_DEBUG must be set so the driver's in-process expansion of the
                 debuggee keeps its thsl-src! checkpoints.  Forward the existing env
                 (including any PLTCOLLECTS a dev worktree set to repoint the `tesl`
                 collection) and add TESL_DEBUG=1. *)
              Unix.putenv "TESL_DEBUG" "1";
              (* Encode the requested breakpoints as a JSON array the driver
                 parses: [{"line":N,"condition":STR?,"hit":STR?}, ...].  The driver
                 distinguishes this STRUCTURED form (argv[2]=mode, argv[3]=json)
                 from the LEGACY single-line form (argv[2]=number) by argv[2]. *)
              let bp_json =
                let one (line, cond_opt, hit_opt) =
                  let fields =
                    (Printf.sprintf {|"line":%d|} line)
                    :: (match cond_opt with
                        | Some c -> [Printf.sprintf {|"condition":%s|} (json_encode_string c)]
                        | None -> [])
                    @  (match hit_opt with
                        | Some h -> [Printf.sprintf {|"hit":%s|} (json_encode_string h)]
                        | None -> [])
                  in
                  "{" ^ String.concat "," fields ^ "}"
                in
                "[" ^ String.concat "," (List.map one breakpoints) ^ "]"
              in
              let argv =
                [| racket_bin; driver; tmp_rkt; abs_src; mode; bp_json |]
              in
              flush stdout; flush stderr;
              (* exec replaces this process: the driver's single JSON object is
                 written straight to our inherited stdout, then it exits 0. *)
              (try Unix.execv racket_bin argv
               with Unix.Unix_error (e, _, _) ->
                 InspectErr (Printf.sprintf "exec racket failed: %s"
                               (Unix.error_message e))))
       with Sys_error msg -> InspectErr msg)
  end
