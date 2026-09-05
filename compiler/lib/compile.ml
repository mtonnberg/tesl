(** Top-level compilation pipeline.
    parse → type-check → emit. *)

open Parser
open Ast

let lexer_failure_prefix = "lexer failure: "

(** Total parser boundary for compiler APIs.  The lexer reports malformed bytes
    and unterminated literals with [Failure]; convert those into the parser's
    normal error channel so every JSON query can still emit its documented
    envelope. *)
let parse_module filename source =
  try Parser.parse_module filename source with
  | Failure message ->
    Parser.Err {
      msg = lexer_failure_prefix ^ message;
      loc = Location.dummy_loc filename;
      fix = None;
    }

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

(** A unified diagnostic that can come from the parser or the type checker.
    The fix type itself lives in {!Type_system} (so type errors can carry one);
    re-exported here so existing [Compile.Replace_line] consumers keep working. *)
type diagnostic_fix = Type_system.diagnostic_fix =
  | Replace_line of { line : int; replacement : string }
  | Insert_line  of { line : int; text : string }
  | Replace_span of { start_line : int; end_line : int; replacement : string }
  | Replace_range of { start_line : int; start_col : int;
                       end_line : int; end_col : int; replacement : string }
  | Multi of diagnostic_fix list

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
  (* B5: pre-resolved manual deep-link anchor ("<section>#<anchor>"), decided by
     the STRUCTURED topic the producing validation pass stamped on the error —
     NOT by sniffing keywords out of [message].  [None] means "no structured
     anchor was resolved here"; the renderer then falls back to the registry's
     code→anchor mapping (which is 1:1 for every non-V001 code).  CLI-render-only:
     deliberately NOT serialized by [diag_to_json] so the JSON wire format stays
     byte-identical for existing consumers. *)
  manual     : string option;
}

type go_compile_result =
  | GoSuccess of Emit_go.artifact list
  | GoFailure of diagnostic list

(* Mutation results are backend-neutral. A failing test marker means the mutant was
   detected; a non-zero process without evidence that tests ran is only an invalid
   mutant, not a kill. *)
let output_lines output = String.split_on_char '\n' output

let output_indicates_failure output =
  List.exists (fun line ->
    line = "FAILURE" || line = "ERROR" || line = "FAIL" ||
    String.length line >= 7 && String.sub line 0 7 = "--- FAIL")
    (output_lines output)

let output_indicates_tests_ran output =
  output_indicates_failure output ||
  List.exists (fun line ->
    line = "PASS" || line = "ok" ||
    String.length line >= 3 && String.sub line 0 3 = "ok " ||
    String.length line >= 12 && String.sub line (String.length line - 12) 12 = " test passed")
    (output_lines output)

let classify_mutant_run ~exit_code ~output =
  exit_code = 0 && not (output_indicates_failure output)

let classify_mutant_outcome ~exit_code ~output =
  if output_indicates_failure output then `Killed
  else if output_indicates_tests_ran output then
    if exit_code = 0 then `Survived else `Killed
  else `Invalid

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
  (* The rejected `#lang tesl` pragma has a dedicated code (E002, repurposed
     from the retired "missing #lang" lint) so `tesl help E002` explains it. *)
  code       = (if String.length e.msg >= 12 && String.sub e.msg 0 12 = "`#lang tesl`"
                then "E002" else "E000");
  message    =
    (if String.length e.msg >= String.length lexer_failure_prefix
        && String.sub e.msg 0 (String.length lexer_failure_prefix) = lexer_failure_prefix
     then String.sub e.msg (String.length lexer_failure_prefix)
            (String.length e.msg - String.length lexer_failure_prefix)
     else e.msg);
  fix        = e.fix;
  source     =
    (if String.length e.msg >= String.length lexer_failure_prefix
        && String.sub e.msg 0 (String.length lexer_failure_prefix) = lexer_failure_prefix
     then "lexer" else "parser");
  manual     = None;
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
  manual     = None;
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
  fix        = e.fix;
  source     = "type-checker";
  manual     = None;
}

let diag_of_validation_error (e : Validation.validation_error) : diagnostic = {
  file       = e.loc.file;
  start_line = e.loc.start.line;
  start_col  = e.loc.start.col;
  end_line   = e.loc.stop.line;
  end_col    = e.loc.stop.col;
  severity   = "error";
  (* get_handlers_do_not_mutate: a pass may stamp its own stable code (SEC005);
     everything else keeps the pass-generic V001. *)
  code       = (if e.code = "" then "V001" else e.code);
  message    = if e.hint = "" then e.message else e.message ^ "\nHint: " ^ e.hint;
  fix        = None;
  source     = "validation";
  (* B5: resolve the deep-link anchor from the STRUCTURED topic the producing
     pass stamped on the error — not from the message text.  main.ml prefers
     this over the (now vestigial) message-based path. *)
  manual     = Error_codes.manual_for ~topic:e.topic
                 ~code:(if e.code = "" then "V001" else e.code) ~message:e.message ();
}

(* The nested edits of a `multi` fix carry no title of their own — the action is
   titled once, at the top level, from the owning diagnostic's code. *)
let rec fix_edit_to_json = function
  | None -> "null"
  | Some (Replace_line { line; replacement }) ->
      Printf.sprintf {|{"kind":"replace_line","line":%d,"replacement":%s}|}
        line (json_encode_string replacement)
  | Some (Insert_line { line; text }) ->
      Printf.sprintf {|{"kind":"insert_line","line":%d,"text":%s}|}
        line (json_encode_string text)
  | Some (Replace_span { start_line; end_line; replacement }) ->
      Printf.sprintf {|{"kind":"replace_span","start_line":%d,"end_line":%d,"replacement":%s}|}
        start_line end_line (json_encode_string replacement)
  | Some (Replace_range { start_line; start_col; end_line; end_col; replacement }) ->
      Printf.sprintf {|{"kind":"replace_range","start_line":%d,"start_col":%d,"end_line":%d,"end_col":%d,"replacement":%s}|}
        start_line start_col end_line end_col (json_encode_string replacement)
  | Some (Multi edits) ->
      Printf.sprintf {|{"kind":"multi","edits":[%s]}|}
        (String.concat "," (List.map (fun e -> fix_edit_to_json (Some e)) edits))

(* A fix on the wire carries the human code-action TITLE alongside its edit.
   The LSP shows that string in the lightbulb menu; it previously invented
   "Apply fix for <CODE>" itself, which told the user nothing about what applying
   the action would do.  Deriving it here means the compiler — which knows the
   diagnostic's intent — owns the wording, and every client gets the same one. *)
let fix_to_json ?(code = "") (fix : diagnostic_fix option) : string =
  match fix with
  | None -> "null"
  | Some f ->
    let edit = fix_edit_to_json (Some f) in
    (* splice "title" into the edit object *)
    let body = String.sub edit 1 (String.length edit - 2) in
    Printf.sprintf {|{%s,"title":%s}|} body
      (json_encode_string (Diag_fix.title ~code f))

let diag_to_json (d : diagnostic) : string =
  Printf.sprintf
    {|{"file":%s,"start":{"line":%d,"col":%d},"end":{"line":%d,"col":%d},"severity":%s,"code":%s,"message":%s,"fix":%s,"source":%s}|}
    (json_encode_string d.file)
    d.start_line d.start_col
    d.end_line   d.end_col
    (json_encode_string d.severity)
    (json_encode_string d.code)
    (json_encode_string d.message)
    (fix_to_json ~code:d.code d.fix)
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

(* Bound work before recursive semantic passes. The walk itself is iterative,
   so detecting an excessive tree cannot overflow the OCaml stack. *)
let max_expression_depth = 512
let max_expression_nodes = 100_000

let module_expression_roots (m : Ast.module_form) : Ast.expr list =
  let test_roots stmts = List.concat_map Ast.test_stmt_exprs stmts in
  List.concat_map (function
    | Ast.DFunc fd -> [fd.body]
    | Ast.DConst c -> [c.value]
    | Ast.DTest t -> test_roots t.stmts
    | Ast.DApiTest t -> t.seed_stmts @ test_roots t.stmts
    | Ast.DLoadTest t -> t.seed_stmts @ test_roots t.request_stmts
    | Ast.DDatabase d -> Option.to_list d.config_expr
    | Ast.DQueue q -> Option.to_list q.config_expr
    | Ast.DChannel c -> Option.to_list c.config_expr
    | Ast.DCache c -> Option.to_list c.config_expr
    | Ast.DEmail e -> Option.to_list e.config_expr
    | Ast.DAgent a -> Option.to_list a.config_expr
    | Ast.DType _ | Ast.DRecord _ | Ast.DEntity _ | Ast.DFact _ | Ast.DCodec _
    | Ast.DCapability _ | Ast.DWorkers _ | Ast.DCapture _ | Ast.DApi _
    | Ast.DServer _ -> []) m.decls

let module_complexity_diagnostics (m : Ast.module_form) : diagnostic list =
  let stack = Stack.create () in
  List.iter (fun root -> Stack.push (root, 1) stack) (module_expression_roots m);
  let nodes = ref 0 in
  let exceeded = ref None in
  while !exceeded = None && not (Stack.is_empty stack) do
    let expr, depth = Stack.pop stack in
    incr nodes;
    if depth > max_expression_depth then
      exceeded := Some (`Depth depth, Checker.expr_loc expr)
    else if !nodes > max_expression_nodes then
      exceeded := Some (`Nodes !nodes, Checker.expr_loc expr)
    else
      ignore (Ast_visitor.fold_children
        (fun () child -> Stack.push (child, depth + 1) stack) () expr)
  done;
  match !exceeded with
  | None -> []
  | Some (reason, loc) ->
    let detail = match reason with
      | `Depth depth -> Printf.sprintf "expression nesting is %d levels (limit %d)"
                          depth max_expression_depth
      | `Nodes _ -> Printf.sprintf "module contains more than %d expression nodes"
                      max_expression_nodes in
    [{ file = loc.Location.file;
       start_line = loc.Location.start.line; start_col = loc.Location.start.col;
       end_line = loc.Location.stop.line; end_col = loc.Location.stop.col;
       severity = "error"; code = "E003";
       message = Printf.sprintf
         "source complexity budget exceeded: %s; split the expression into named functions or smaller declarations"
         detail;
       fix = None; source = "parser"; manual = None }]

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
   | Ast.ESqlQuery { query; _ } ->
     Ast_visitor.fold_sql_query
       (fun result child ->
         match result with
         | Some _ -> result
         | None -> definition_in_expr env locals line col child)
       None query

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
  | Ast.DType (Ast.TypeNewtype { base_type; _ }) ->
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
          match (ep_body endpoint) with
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
          | None -> definition_in_return_spec env line col (ep_return_spec endpoint)
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
  | Ast.DWorkers _ | Ast.DServer _ | Ast.DFact _ | Ast.DCache _ | Ast.DEmail _
  | Ast.DAgent _ -> None

let collect_definition_env (m : Ast.module_form) =
  List.fold_left (fun env decl ->
    match decl with
    | Ast.DFunc fd -> add_term_def env fd.name (precise_name_loc fd.loc fd.name)
    | Ast.DType (Ast.TypeNewtype { name; loc; _ }) ->
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
    | Ast.DAgent a -> add_term_def env a.name (precise_name_loc a.loc a.name)
  ) empty_definition_env m.decls

let definition_source filename source line col =
  set_query_source_lines source;
  match parse_module filename source with
  | Err _ -> None
  | Ok m ->
    if module_complexity_diagnostics m <> [] then None else
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
  | Ast.EConstructor { name; args; loc } ->
    let ctor_loc = precise_name_loc loc name in
    if loc_contains_position ctor_loc line col then find_ctor_symbol env.ctor_defs name
    else find_map_list (resolve_symbol_in_expr env locals line col) args
   | Ast.ELambda { params; body; _ } ->
     let result = find_map_list (resolve_symbol_in_binding env line col) params in
     (match result with
      | Some _ as found -> found
      | None -> resolve_symbol_in_expr env (extend_locals_with_params locals params) line col body)
   | Ast.ESqlQuery { query; _ } ->
     Ast_visitor.fold_sql_query
       (fun result child ->
         match result with
         | Some _ -> result
         | None -> resolve_symbol_in_expr env locals line col child)
       None query

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
  | Ast.DType (Ast.TypeNewtype { name; base_type; loc; _ }) ->
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
           match (ep_body endpoint) with
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
           | None -> resolve_symbol_in_return_spec env line col (ep_return_spec endpoint)
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
  | Ast.DAgent a -> let name_loc = precise_name_loc a.loc a.name in if loc_contains_position name_loc line col then Some (term_symbol a.name name_loc) else None

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
  | Ast.EConstructor { name; args; loc } ->
    (match find_ctor_symbol env.ctor_defs name with
     | Some symbol when symbol_equal symbol target -> loc :: List.concat_map (collect_occurrences_in_expr env locals target) args
     | _ -> List.concat_map (collect_occurrences_in_expr env locals target) args)
   | Ast.ELambda { params; body; _ } ->
     List.concat_map (collect_occurrences_in_binding env target) params
     @ collect_occurrences_in_expr env (extend_locals_with_params locals params) target body
   | Ast.ESqlQuery { query; _ } ->
     Ast_visitor.fold_sql_query
       (fun acc child ->
         acc @ collect_occurrences_in_expr env locals target child)
       [] query

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
  | Ast.DType (Ast.TypeNewtype { name; base_type; loc; _ }) ->
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
         @ (match (ep_body endpoint) with Some binding -> collect_occurrences_in_binding env target binding | None -> [])
         @ List.concat_map (fun (capture : Ast.api_capture) -> collect_occurrences_in_binding env target capture.binding) endpoint.captures
         @ collect_occurrences_in_return_spec env target (ep_return_spec endpoint)
      ) api.endpoints
  | Ast.DTest test
    when (let p = "doctest: " in
          String.length test.description >= String.length p
          && String.sub test.description 0 (String.length p) = p) ->
    (* T1 (2026-07-04): synthetic doctest decls are parsed by [parse_expr_snippet]
       as standalone snippets, so their expression locs are LOCAL to the snippet
       (line 0), not the real comment position.  Emitting occurrences from them
       makes an LSP rename write a corrupting edit at line 0.  A comment-embedded
       doctest snippet has no reliable editable source position, so exclude it from
       occurrence collection entirely (references/documentHighlight/rename consume
       this list). *)
    []
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
  | Ast.DAgent a -> let name_loc = precise_name_loc a.loc a.name in if symbol_equal (term_symbol a.name name_loc) target then [name_loc] else []

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
    if module_complexity_diagnostics m <> [] then [] else
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
  set_query_source_lines source;
  match parse_module filename source with
  | Err _ -> None
  | Ok m ->
    if module_complexity_diagnostics m <> [] then None
    else
      let bindings, expr_types, _, _, _, _, _ =
        Checker.check_module_with_metadata m in
      let expression =
        List.fold_left (fun best info ->
          if loc_contains_position info.Checker.loc line col && better_expr_type best info
          then Some info
          else best
        ) None expr_types
      in
      match expression with
      | Some info -> Some (type_at_of_checker info)
      | None ->
        List.find_map (fun (binding : Checker.local_binding_info) ->
          let loc = precise_name_loc binding.loc binding.name in
          if loc_contains_position loc line col then
            Some { file = loc.file; line = loc.start.line; col = loc.start.col;
                   end_line = loc.stop.line; end_col = loc.stop.col;
                   ty = binding.display_ty }
          else None) bindings

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
    if module_complexity_diagnostics m <> [] then None
    else
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

(* The source span of a top-level declaration (moved to Ast for E1 reuse). *)
let top_decl_loc = Ast.top_decl_loc

(* ── Config-block context (LSP hover + completion for config fields) ─────────
   Given a cursor position, return the most-specific typed configuration block
   enclosing it (Database / PostgresConfig / Queue / QueueRetryStrategy /
   SseChannel / Cache / Email / SmtpConfig / TelemetryConfig) together with each schema field and
   whether the user already wrote it.  Drives the editor's field completion +
   hover from {!Validation_structural.config_block_schema} so there is one
   source of truth. *)
type config_field_info = {
  cfi_name     : string;
  cfi_type     : string;
  cfi_doc      : string;
  cfi_required : bool;
  cfi_present  : bool;
}
type config_context = { cc_block : string; cc_fields : config_field_info list }

(* A short, human label for a typed-config field's value shape, for the LSP
   hover/completion query.  Sourced from the typed-block schema in
   {!Validation_structural.config_block_schema}. *)
let config_field_type_label (k : Validation_structural.vkind) : string =
  match k with
  | Validation_structural.VStr         -> "String"
  | Validation_structural.VSchemaRef   -> "ModuleRef (VCurrent) | String (legacy)"
  | Validation_structural.VMigrationRef -> "ModuleRef (Migrate prefix)"
  | Validation_structural.VInt         -> "Int"
  | Validation_structural.VPort        -> "Int (port 1..65535)"
  | Validation_structural.VMountPath   -> "String (leading `/`, no trailing `/`)"
  | Validation_structural.VBool        -> "Bool"
  | Validation_structural.VSub sub     -> sub ^ " { … }"
  | Validation_structural.VConn        -> "TcpConnection { … } | SocketConnection { … }"
  | Validation_structural.VBackend     -> "Postgres (PostgresConfig { … }) | Memory"
  | Validation_structural.VBackoff     -> "Exponential | Fixed | Linear"
  | Validation_structural.VDatabaseRef -> "Database"
  | Validation_structural.VEntityList  -> "[Entity]"
  | Validation_structural.VJobList     -> "[JobType]"
  | Validation_structural.VRefList     -> "[Name]"
  | Validation_structural.VTypeRef     -> "Type"
  | Validation_structural.VExpr        -> "expression"

(* The typed-config-record [expr] carried by a config declaration's
   [config_expr] (the `= Database { … }` / `= Email { … }` RHS), if any. *)
let config_decl_expr (d : Ast.top_decl) : Ast.expr option =
  match d with
  | Ast.DDatabase r -> r.config_expr
  | Ast.DQueue r    -> r.config_expr
  | Ast.DChannel r  -> r.config_expr
  | Ast.DCache r    -> r.config_expr
  | Ast.DEmail r    -> r.config_expr
  | Ast.DAgent r    -> r.config_expr
  (* `main`'s trailing `App { … }` record is a typed config block with a full
     schema (see [Validation_structural.config_block_schema] "App"), so the
     LSP's config-context hover/completion covers it like any other — it was
     simply never wired up, leaving the one block every project has with no
     field hints at all. *)
  | Ast.DFunc fd    -> Ast.app_record_of_main fd
  | _ -> None

(* Type name a typed-config record was hinted with (`Database`, `SmtpConfig`,
   …), peeling a constructor application (`Postgres (PostgresConfig { … })`). *)
let rec config_record_type_name (e : Ast.expr) : string option =
  match e with
  | Ast.ERecord { type_hint = Some t; _ } -> Some t
  | Ast.EApp { fn = Ast.EConstructor { name; _ }; arg = Ast.ERecord _; _ } -> Some name
  | Ast.EApp { fn; _ } -> config_record_type_name fn
  | _ -> None

let config_record_fields (e : Ast.expr) : (string * Ast.expr) list =
  match e with
  | Ast.ERecord { fields; _ } -> fields
  | Ast.EApp { arg = Ast.ERecord { fields; _ }; _ } -> fields
  | _ -> []

(* Re-points the LSP `--config-context-json` query to the typed-block schema
   ({!Validation_structural.config_block_schema}).  Finds the config declaration
   under the cursor, descends to the innermost typed record `Type { … }` that
   contains the cursor (so a nested `smtp: SmtpConfig { … }` reports SmtpConfig's
   fields), and lists that block type's fields, marking which are present. *)
let config_context_source filename source line col : config_context option =
  match parse_module filename source with
  | Err _ -> None
  | Ok m ->
    if module_complexity_diagnostics m <> [] then None else
    let under_cursor d =
      config_decl_expr d <> None
      && loc_contains_position (top_decl_loc d) line col
    in
    (match List.find_opt under_cursor m.decls with
     | None -> None
     | Some d ->
       let top_expr = Option.get (config_decl_expr d) in
       (* A typed-config block is either an `ERecord` carrying a type_hint (the
          top-level `= Database { … }` RHS) or a constructor applied to a record
          (`SmtpConfig { … }`, `Postgres (PostgresConfig { … })`).  Collect every
          such block whose record body encloses the cursor, then pick the one with
          the smallest span — the most specific (innermost) block. *)
       let record_loc (e : Ast.expr) : Location.loc option =
         match e with
         | Ast.ERecord { loc; _ } -> Some loc
         | Ast.EApp { arg = Ast.ERecord { loc; _ }; _ } -> Some loc
         | _ -> None
       in
       let span_lines (loc : Location.loc) =
         (loc.stop.line - loc.start.line, loc.stop.col - loc.start.col)
       in
       let candidates = ref [] in
       let rec collect (e : Ast.expr) =
         (match config_record_type_name e, record_loc e with
          | Some t, Some loc when loc_contains_position loc line col ->
            candidates := (t, e, loc) :: !candidates
          | _ -> ());
         (match e with
          | Ast.ERecord { fields; _ } -> List.iter (fun (_, v) -> collect v) fields
          | Ast.EApp { fn; arg; _ } -> collect fn; collect arg
          | Ast.EList { elems; _ } -> List.iter collect elems
          | _ -> ())
       in
       collect top_expr;
       (* The top-level config record always encloses the cursor (the decl loc
          check above guarantees it), so [candidates] is non-empty.  Pick the
          tightest span. *)
       let target =
         match List.sort (fun (_, _, a) (_, _, b) ->
           compare (span_lines a) (span_lines b)) !candidates with
         | (_, e, _) :: _ -> e
         | [] -> top_expr
       in
       (match config_record_type_name target with
        | None -> None
        | Some block_type ->
          (match Validation_structural.config_block_schema block_type with
           | [] -> None
           | schema_fields ->
             let present =
               List.map fst (config_record_fields target) in
             let fields =
               List.map (fun (fname, kind, required) -> {
                 cfi_name     = fname;
                 cfi_type     = config_field_type_label kind;
                 cfi_doc      = Validation_structural.config_field_doc block_type fname;
                 cfi_required = required;
                 cfi_present  = List.mem fname present;
               }) schema_fields
             in
             Some { cc_block = block_type; cc_fields = fields })))

let config_context_response_to_json (cc : config_context option) : string =
  match cc with
  | None -> {|{"version":1,"config_context":null}|}
  | Some c ->
    let field_json (f : config_field_info) =
      Printf.sprintf
        {|{"name":%s,"type":%s,"doc":%s,"required":%b,"present":%b}|}
        (json_encode_string f.cfi_name) (json_encode_string f.cfi_type)
        (json_encode_string f.cfi_doc) f.cfi_required f.cfi_present
    in
    Printf.sprintf {|{"version":1,"config_context":{"block":%s,"fields":[%s]}}|}
      (json_encode_string c.cc_block)
      (String.concat "," (List.map field_json c.cc_fields))

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
    if module_complexity_diagnostics m <> [] then None else
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
    if module_complexity_diagnostics m <> [] then [] else
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
    if module_complexity_diagnostics m <> [] then None else
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

(* Review item 3: one canonical resolver in Validation_common (was a copy). *)
let module_name_to_kebab = Validation_common.module_name_to_kebab
let resolve_local_import_path = Validation_common.resolve_local_import_path

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
  manual     = None;
}

let missing_bool_import_diag (m : module_form) loc ~is_ctor =
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
    fix        = Import_suggest.build_fix m ~target_module:"Tesl.Prelude"
                   ~expose_name:"Bool(..)";
    source     = "validation";
    manual     = None;
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
    | DType (TypeNewtype { base_type; _ }) -> visit_type_expr base_type
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
   | Some loc when not bool_type_imported -> diags := missing_bool_import_diag m loc ~is_ctor:false :: !diags
   | _ -> ());
  (match !first_bool_ctor_use with
   | Some loc when not bool_ctor_imported -> diags := missing_bool_import_diag m loc ~is_ctor:true :: !diags
   | _ -> ());
  List.rev !diags

(* ── Regex pattern literals (VREGEX001-4) ──────────────────────────────────
   `Tesl.Regex` patterns are validated where the program is validated: see
   regex_lint.ml for the subset, the literal-only rule, and the
   backtracking/capture-participation rules.  Runs alongside the other surface
   passes so `tesl check`, `--check-json` and `agent-context` all report it. *)
let regex_literal_diagnostics (m : module_form) : diagnostic list =
  List.map (fun (loc, code, message) -> {
    file       = loc.Location.file;
    start_line = loc.Location.start.line;
    start_col  = loc.Location.start.col;
    end_line   = loc.Location.stop.line;
    end_col    = loc.Location.stop.col;
    severity   = "error";
    code;
    message;
    fix        = None;
    source     = "validation";
    manual     = Error_codes.manual_for ~code ~message ();
  }) (Regex_lint.module_diagnostics m)

let parse_module_file path =
  try
    let source = In_channel.with_open_text path In_channel.input_all in
    match parse_module path source with
    | Ok m -> Some m
    | Err _ -> None
  with Sys_error _ -> None

(* Graph nodes are CANONICAL paths (Validation_common.canonical_import_path):
   [resolve_local_import_path] spells the same file differently depending on
   the importing file (`main.tesl` on the CLI vs `./main.tesl` reached through
   a dep's back-edge), and raw-string nodes made the SCC containing the entry
   invisible — the emitter then fell back to plain requires and `go-tool make`
   died with a raw "cycle in loading" (2026-07-08 audit). *)
let canonical_import_path = Validation_common.canonical_import_path

(* The ONE lifted stdlib module the Go backend compiles from its Tesl SOURCE rather than
   binding to a runtime file.  `Tesl.CivilTime` has no Go runtime of its own and is ordinary
   Tesl — ADTs, opaque types, checks, proof-carrying returns — so compiling it is both the
   smallest way to have it and the most demanding thing the backend is asked to do.

   `Tesl.List` and `Tesl.Either` are lifted too and are deliberately NOT here: their leaves
   bind to `teslrt` functions, and compiling them as well would give a program two of each. *)
let go_lifted_module_names = ["Tesl.CivilTime"]

let build_local_import_graph ?(lifted=[]) entry_path =
  let graph : (string, string list) Hashtbl.t = Hashtbl.create 16 in
  let rec visit path =
    if Hashtbl.mem graph path then ()
    else begin
      let deps =
        match parse_module_file path with
        | None -> []
        | Some m ->
          List.filter_map (fun (imp : Ast.import_decl) ->
            if List.mem imp.module_name lifted then
              Option.map canonical_import_path
                (Validation_common.lifted_stdlib_source_path imp.module_name)
            else if is_tesl_stdlib_module_name imp.module_name then None
            else Some (canonical_import_path
                         (resolve_local_import_path m.source_file imp.module_name))
          ) m.imports
      in
      Hashtbl.add graph path deps;
      List.iter visit deps
    end
  in
  visit (canonical_import_path entry_path);
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
  let entry_canon = canonical_import_path entry_path in
  let graph = build_local_import_graph entry_path in
  let sccs = tarjan_sccs graph in
  match List.find_opt (fun component -> List.mem entry_canon component) sccs with
  | Some component when List.length component > 1 -> component
  | _ -> []

(* ── WS1: opt-in per-phase wall-clock timing ────────────────────────────────
   When the environment variable [TESL_PHASE_TIMING=1] is set, each compiler
   phase (parse / typecheck / proof / validation / emit) prints its wall-clock
   duration in milliseconds to *stderr* so it never pollutes the emitted code
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
  let _, _, _, bare_hints, _, _, type_errors = Checker.check_module_with_metadata ~source_lines m in
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

(** The full PER-MODULE check pipeline (everything `--check <file>` runs except
    the cross-module graph walk below): legacy-Bool lint, type check, proof
    check, validations.  Factored out so [cross_module_diags] can run the exact
    `--check dep.tesl` judgment on every transitively imported module — same
    passes, same order, diagnostics anchored at the DEP's own file via its
    parse locations. *)
let module_local_diags source (m : Ast.module_form) : diagnostic list =
  match module_complexity_diagnostics m with
  | _ :: _ as diagnostics -> diagnostics
  | [] ->
    legacy_bool_diagnostics m.source_file source m
    @ regex_literal_diagnostics m
    @ type_diags_of source m
    @ List.map diag_of_proof_error (Proof_checker.check_module m)
    @ List.map diag_of_validation_error (Validation.check_module m)

(* ── Cross-module structural validation (2026-07-08 multi-module audit) ─────
   `--check <entrypoint>` historically validated the entrypoint plus module
   INTERFACES only, so two classes of dependency errors surfaced one phase too
   late (at that module's own emit, or as a raw runtime error at `go-tool make`):

   1. EXPORT LOCALITY — a dependency whose `exposing` list re-exports an
      imported name passed the whole-program check, then its emit failed T001.
   2. IMPORT CYCLES the emitter cannot lower — the cyclic-SCC inliner supports
      only pure declarations (fn/type/record/entity/const/fact/tests/capturers);
      a cycle containing config decls (server/database/queue/sseChannel/api/
      codec/capability/agent/email/cache/workers/`main`) emitted provides with
      no definition, and `go-tool make` rejected the require graph with a raw
      "standard-module-name-resolver: cycle in loading".

   3. (2026-07-09, the systemic hole behind both) MODULE BODIES — the
      entrypoint check never type-checked imported modules' bodies at all: a
      dependency with a hard type error (`cannot unify String with Int`), an
      out-of-scope type, a proof error or a failing validation passed
      `--check main.tesl` silently and only died when THAT module was emitted
      ("check green, build red"; --generate-elm/-ts shipped clients for broken
      programs).  The walk now runs the FULL per-module check pipeline
      ([module_local_diags] — exactly `--check dep.tesl` semantics, which the
      audit confirmed rejects these bodies) on every transitively imported
      local module, each diagnostic anchored at that module's own file:line.
      A dep that fails to PARSE is reported the same way.

   This walk loads the transitive local-import graph (memoized parse) and
   rejects all of the above at CHECK time with .tesl-anchored diagnostics.
   Cycles made only of pure declarations remain legal — mutually recursive
   modules are supported by the SCC inliner (example/sandbox*.tesl) — but a
   module importing ITSELF is always rejected (the inliner never fires for a
   single-node SCC, so the emitted file would require itself).

   [skip_dep_body canon] (canonical path): when true, the dep's PER-MODULE
   check is skipped — used by `--check f1 f2`/`--check-batch`/`--check-all` so
   a module that is ITSELF a CLI argument is body-checked exactly once (its
   own per-file run), never re-reported under each consumer.  The graph is
   still traversed through skipped modules (their deps may not be CLI args),
   and cycle/self-import detection is unaffected. *)
let cycle_unsafe_decl_reason (d : Ast.top_decl) : string option =
  match d with
  | Ast.DFunc fd when fd.kind = Ast.MainKind -> Some "`main()`"
  | Ast.DFunc _ | Ast.DType _ | Ast.DRecord _ | Ast.DEntity _ | Ast.DConst _
  | Ast.DFact _ | Ast.DTest _ | Ast.DApiTest _ | Ast.DLoadTest _
  | Ast.DCapture _ -> None
  | Ast.DCodec c      -> Some (Printf.sprintf "codec `%s`" c.name)
  | Ast.DDatabase db  -> Some (Printf.sprintf "database `%s`" db.name)
  | Ast.DCapability c -> Some (Printf.sprintf "capability `%s`" c.name)
  | Ast.DQueue q      -> Some (Printf.sprintf "queue `%s`" q.name)
  | Ast.DChannel c    -> Some (Printf.sprintf "sseChannel `%s`" c.name)
  | Ast.DWorkers w    -> Some (Printf.sprintf "workers `%s`" w.name)
  | Ast.DCache c      -> Some (Printf.sprintf "cache `%s`" c.name)
  | Ast.DAgent a      -> Some (Printf.sprintf "agent `%s`" a.name)
  | Ast.DEmail e      -> Some (Printf.sprintf "email `%s`" e.name)
  | Ast.DApi a        -> Some (Printf.sprintf "api `%s`" a.name)
  | Ast.DServer s     -> Some (Printf.sprintf "server `%s`" s.name)

let cross_module_diags ?(skip_dep_body : string -> bool = fun _ -> false)
    (m : Ast.module_form) : diagnostic list =
  let entry = m.Ast.source_file in
  if entry = "" || entry = "<test>" then []
  else begin
    let mk_diag ~(source : string) (loc : Location.loc) message : diagnostic = {
      file       = loc.Location.file;
      start_line = loc.Location.start.line;
      start_col  = loc.Location.start.col;
      end_line   = loc.Location.stop.line;
      end_col    = loc.Location.stop.col;
      severity   = "error";
      code       = (if source = "type-checker" then "T001" else "V001");
      message;
      fix        = None;
      source;
      manual     = None;
    } in
    let diags : diagnostic list ref = ref [] in
    let entry_canon = canonical_import_path entry in
    (* Parse cache keyed by canonical path; the entry uses the ALREADY-parsed
       [m] (check_source may be validating an in-memory buffer).  Parse ERRORS
       are kept (not collapsed to None) so a dep that fails to parse is
       reported like any other dep-check failure; the underlying reads go
       through [Checker.parse_local_import_module], the import cache shared
       with the checker's own import loading (and across a batch run). *)
    let parsed : (string, Ast.module_form Parser.result option) Hashtbl.t =
      Hashtbl.create 16 in
    Hashtbl.replace parsed entry_canon (Some (Parser.Ok m));
    let parse_at ~spelling ~canon : Ast.module_form Parser.result option =
      match Hashtbl.find_opt parsed canon with
      | Some r -> r
      | None ->
        let r = Checker.parse_local_import_module spelling in
        Hashtbl.replace parsed canon r; r
    in
    let visited : (string, unit) Hashtbl.t = Hashtbl.create 16 in
    let reported_cycles : (string, unit) Hashtbl.t = Hashtbl.create 4 in
    (* Every successfully parsed module of the transitive closure (deps only;
       the entry [m] is prepended below) — input to the name-wired resolution
       check after the walk. *)
    let closure_mods : Ast.module_form list ref = ref [] in
    (* [stack]: modules on the current DFS path, HEAD = the module whose
       imports are being walked; used to reconstruct the cycle path. *)
    let rec dfs (canon : string) (im : Ast.module_form)
                (stack : (string * Ast.module_form) list) : unit =
      let stack = (canon, im) :: stack in
      List.iter (fun (imp : Ast.import_decl) ->
        if not (is_tesl_stdlib_module_name imp.module_name) then begin
          let spelling = resolve_local_import_path im.Ast.source_file imp.Ast.module_name in
          let dep_canon = canonical_import_path spelling in
          if dep_canon = canon then begin
            (* Self-import: never lowerable — the emitted module would require
               itself.  Always rejected.  The name-based
               [Validation_names.check_self_imports] already reports the
               `import Self` spelling; this PATH-based variant only reports
               when the import is spelled differently but still resolves to
               the module's own file. *)
            if imp.Ast.module_name <> im.Ast.module_name then
              diags := mk_diag ~source:"validation" imp.Ast.loc
                (Printf.sprintf
                   "module `%s` imports itself (import `%s` resolves to this \
                    module's own file) — remove this import; a module's own \
                    declarations are already in scope"
                   im.Ast.module_name imp.Ast.module_name)
                :: !diags
          end
          else if List.mem_assoc dep_canon stack then begin
            (* Back edge: an import cycle.  Reconstruct the path
               dep -> ... -> current -> dep for the diagnostic. *)
            let rec take_until acc = function
              | [] -> acc
              | (c, mf) :: rest ->
                if c = dep_canon then (c, mf) :: acc
                else take_until ((c, mf) :: acc) rest
            in
            let members = take_until [] stack in  (* dep first, current last *)
            let key = String.concat "\x00"
                        (List.sort String.compare (List.map fst members)) in
            if not (Hashtbl.mem reported_cycles key) then begin
              Hashtbl.replace reported_cycles key ();
              let offender =
                List.find_map (fun (_, mf) ->
                  List.find_map (fun d ->
                    match cycle_unsafe_decl_reason d with
                    | Some reason -> Some (mf.Ast.module_name, reason)
                    | None -> None
                  ) mf.Ast.decls
                ) members
              in
              match offender with
              | None -> ()  (* pure SCC: supported via inline (sandbox class) *)
              | Some (offender_name, reason) ->
                let path_str =
                  String.concat " -> "
                    (List.map (fun (_, mf) -> mf.Ast.module_name) members
                     @ [ (match members with (_, first) :: _ -> first.Ast.module_name
                                           | [] -> imp.Ast.module_name) ])
                in
                diags := mk_diag ~source:"validation" imp.Ast.loc
                  (Printf.sprintf
                     "import cycle detected: %s — module `%s` declares %s, so \
                      this cycle cannot be compiled (modules in an import cycle \
                      may only contain fn (non-main)/type/record/entity/const/\
                      fact/test/api-test/load-test/capture declarations, which \
                      the compiler inlines). Break the cycle by moving the \
                      shared declarations into a separate module imported by \
                      both sides."
                     path_str offender_name reason)
                  :: !diags
            end
          end
          else if not (Hashtbl.mem visited dep_canon) then begin
            (* Mark BEFORE descending: a diamond re-reaches the dep only after
               this subtree completes (during it, the stack check fires), so
               every module is body-checked at most once per invocation. *)
            Hashtbl.replace visited dep_canon ();
            match parse_at ~spelling ~canon:dep_canon with
            | None -> ()   (* unresolvable import: the entry's own checker
                              reports it at the import site *)
            | Some (Parser.Err e) ->
              (* A dep that fails to PARSE is a whole-program check failure,
                 anchored at the dep's own file (previously silent here; the
                 entry only saw "unbound name" fallout at best). *)
              if not (skip_dep_body dep_canon) then
                diags := diag_of_parse_error e :: !diags
            | Some (Parser.Ok dep_m) ->
              closure_mods := dep_m :: !closure_mods;
              (* THE WHOLE-PROGRAM CHECK: run the full `--check dep.tesl`
                 pipeline on the dependency (types, proofs, validations,
                 export locality — the checker returns all of these), so a
                 broken body can no longer hide behind a clean interface.
                 Diagnostics carry the dep's own file/lines via its parse
                 locations. *)
              if not (skip_dep_body dep_canon) then begin
                match
                  (try Some (In_channel.with_open_text spelling
                               In_channel.input_all)
                   with Sys_error _ -> None)
                with
                | Some dep_source ->
                  diags := List.rev_append
                             (module_local_diags dep_source dep_m) !diags
                | None -> ()
              end;
              dfs dep_canon dep_m stack
          end
        end
      ) im.Ast.imports
    in
    dfs entry_canon m [];
    diags := List.rev_append
      (List.map diag_of_validation_error
         (Migration_schema.check_ownership (m :: List.rev !closure_mods))) !diags;
    (* ── Entrypoint-closure name-wired resolution (issue #41 class) ─────────
       Cache / email / publish / subscribe / enqueue sites resolve their NAME
       through the process-wide domain registry at runtime when the declaring
       block is in another module.  The registry only ever holds specs from
       modules that are actually part of the program, so a name declared
       NOWHERE in the entry's transitive import closure can NEVER resolve —
       the runtime lookup is fail-closed, but only fires at first call.  When
       the entry is a PROGRAM ROOT (it declares `main()`, a server, or an
       api-test/load-test — the module IS the program), reject at check time
       with the use anchored at its own site.  A plain library checked
       standalone is exempt by design: its declaring module may legitimately
       be a downstream importer (the importer-declares pattern #41 chose the
       registry for). *)
    let is_program_root =
      List.exists (function
        | Ast.DFunc fd -> fd.Ast.kind = Ast.MainKind
        | Ast.DServer _ | Ast.DApiTest _ | Ast.DLoadTest _ -> true
        | _ -> false
      ) m.Ast.decls
    in
    if is_program_root then begin
      let closure = m :: List.rev !closure_mods in
      (* (kind, name, declaring module, decl loc) for every name-wired
         declaration in the closure — the loc/module carry the duplicate
         diagnostic below; the (kind, name) projection feeds the
         declared-nowhere check. *)
      let declared_with_locs =
        List.concat_map (fun (cm : Ast.module_form) ->
          List.concat_map (fun d ->
            match d with
            | Ast.DCache (c : Ast.cache_form) ->
              [ (Desugar.UseCache, c.Ast.name, cm.Ast.module_name, c.Ast.loc) ]
            | Ast.DEmail (em : Ast.email_form) ->
              [ (Desugar.UseEmail, em.Ast.name, cm.Ast.module_name, em.Ast.loc) ]
            | Ast.DChannel (ch : Ast.channel_form) ->
              [ (Desugar.UseChannel, ch.Ast.name, cm.Ast.module_name, ch.Ast.loc) ]
            | Ast.DQueue (q : Ast.queue_form) ->
              List.map (fun jt ->
                (Desugar.UseJobType, jt, cm.Ast.module_name, q.Ast.loc))
                (Desugar.queue_job_types q)
            | _ -> []
          ) cm.Ast.decls
        ) closure
      in
      let declared =
        List.map (fun (k, n, _, _) -> (k, n)) declared_with_locs in
      let declared_mem kind name =
        List.exists (fun (k, n) -> k = kind && n = name) declared in
      (* Item 13 (review 2026-07-09): 'declared more than once' is as illegal
         as 'declared nowhere' — the runtime lookups (cache-for-name /
         email-for-name / channel-for-name / queue-for-job) fail closed on
         multiplicity ("declared exactly once per program") but only at first
         cross-module call or module instantiation.  Surface it at check time,
         anchored at the second declaration, naming every declaring module. *)
      let dup_reported : (Desugar.wired_use_kind * string, unit) Hashtbl.t =
        Hashtbl.create 4 in
      List.iter (fun (kind, name, _, _) ->
        if not (Hashtbl.mem dup_reported (kind, name)) then begin
          let dups =
            List.filter (fun (k, n, _, _) -> k = kind && n = name)
              declared_with_locs in
          if List.length dups > 1 then begin
            Hashtbl.replace dup_reported (kind, name) ();
            let modules =
              List.map (fun (_, _, mn, _) -> Printf.sprintf "`%s`" mn) dups in
            let (_, _, _, anchor_loc) = List.nth dups 1 in
            let msg = match kind with
              | Desugar.UseCache ->
                Printf.sprintf
                  "cache `%s` is declared %d times in this program (modules \
                   %s) — a cache name must be declared exactly once per \
                   program; remove or rename the duplicate declarations"
                  name (List.length dups) (String.concat ", " modules)
              | Desugar.UseEmail ->
                Printf.sprintf
                  "email `%s` is declared %d times in this program (modules \
                   %s) — an email name must be declared exactly once per \
                   program; remove or rename the duplicate declarations"
                  name (List.length dups) (String.concat ", " modules)
              | Desugar.UseChannel ->
                Printf.sprintf
                  "sseChannel `%s` is declared %d times in this program \
                   (modules %s) — an sseChannel name must be declared exactly \
                   once per program; remove or rename the duplicate \
                   declarations"
                  name (List.length dups) (String.concat ", " modules)
              | Desugar.UseJobType ->
                Printf.sprintf
                  "job type `%s` is declared by %d queues in this program \
                   (modules %s) — a job type must belong to exactly one \
                   queue per program; remove it from the duplicate `jobs:` \
                   lists"
                  name (List.length dups) (String.concat ", " modules)
            in
            diags := mk_diag ~source:"validation" anchor_loc msg :: !diags
          end
        end
      ) declared_with_locs;
      List.iter (fun cm ->
        List.iter (fun ((kind : Desugar.wired_use_kind), name, loc) ->
          if not (declared_mem kind name) then begin
            let msg = match kind with
              | Desugar.UseCache ->
                Printf.sprintf
                  "no cache named `%s` is declared anywhere in this program — \
                   declare `cache %s = Cache { … }` in this module or one of \
                   the entrypoint's (transitive) imports" name name
              | Desugar.UseEmail ->
                Printf.sprintf
                  "no email named `%s` is declared anywhere in this program — \
                   declare `email %s = Email { … }` in this module or one of \
                   the entrypoint's (transitive) imports" name name
              | Desugar.UseChannel ->
                Printf.sprintf
                  "no sseChannel named `%s` is declared anywhere in this \
                   program — declare `sseChannel %s(…) = SseChannel { … }` in \
                   this module or one of the entrypoint's (transitive) imports"
                  name name
              | Desugar.UseJobType ->
                Printf.sprintf
                  "no queue declares job type `%s` anywhere in this program — \
                   add `%s` to a queue's `jobs:` list in this module or one of \
                   the entrypoint's (transitive) imports" name name
            in
            diags := mk_diag ~source:"validation" loc msg :: !diags
          end
        ) (Desugar.collect_name_wired_uses cm)
      ) closure
    end;
    List.rev !diags
  end

(** Run the full check pipeline on a parsed module; returns diagnostics.
    Whole-program: [cross_module_diags] runs the same per-module pipeline on
    every transitively imported local module, so a dependency's errors fail
    the entrypoint check with dep-anchored diagnostics.  [skip_dep_body]
    (canonical path predicate) suppresses the dep-body re-check for modules
    that are themselves being checked in the same CLI invocation. *)
let check_module ?skip_dep_body source (m : Ast.module_form) : diagnostic list =
  match module_local_diags source m with
  | ({ code = "E003"; _ } :: _) as diagnostics -> diagnostics
  | diagnostics -> diagnostics @ cross_module_diags ?skip_dep_body m

let default_root_path () =
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some path when path <> "" -> path
  | _ ->
    let rec find dir =
      if Sys.file_exists (Filename.concat dir "compiler") then dir
      else
        let parent = Filename.dirname dir in
        if parent = dir then Filename.current_dir_name else find parent
    in
    find (Filename.dirname Sys.executable_name)

let diag_of_go_emit_error (error : Emit_go.emit_error) : diagnostic = {
  file       = error.loc.file;
  start_line = error.loc.start.line;
  start_col  = error.loc.start.col;
  end_line   = error.loc.stop.line;
  end_col    = error.loc.stop.col;
  severity   = "error";
  code       = "V001";
  message    = error.message;
  fix        = None;
  source     = "go-emitter";
  manual     = None;
}

(** Compile a checked Tesl module into a complete standalone Go module tree.
    Go receives the surface AST *)
(* An import CYCLE collapses into ONE Go module: Go files in the same package reference each other
   freely — no ordering, no forward declarations — so mutual recursion needs no inlining
   at all, just a shared package.
   Merging the members into one synthetic module reuses the whole single-module path,
   including the two-phase type registration that makes A's type visible to B and back.
   Source mapping survives because every emitted declaration carries its OWN
   `//line <file>:<n>`, so a merged file still points each declaration at the .tesl it
   came from.
   Merging would lose per-member scoping, so colliding declarations and their uses are
   owner-alpha-renamed in the Go-only AST before this step. *)
(* Two imports of the SAME module merge into one carrying the union of the exposed
   names.  Both callers need this: merging a cycle unions its members' outside imports
   (two members may import one module with different exposed lists), and rewriting an
   outside importer's references to collapsed members turns several imports into one. *)
let merge_exposed_imports (left : Ast.import_decl) (right : Ast.import_decl) =
  match left.names, right.names with
  (* ImportAll is rejected by the Go emitter with its own message; keep it visible rather
     than silently widening or narrowing the import. *)
  | Ast.ImportAll, _ | _, Ast.ImportAll -> { left with names = Ast.ImportAll }
  | Ast.ImportExposing ours, Ast.ImportExposing theirs ->
    { left with names = Ast.ImportExposing
                  (ours @ List.filter (fun name -> not (List.mem name ours)) theirs) }

let rec add_merged_import acc (imp : Ast.import_decl) =
  match acc with
  | [] -> [imp]
  | (existing : Ast.import_decl) :: rest when existing.module_name = imp.module_name ->
    merge_exposed_imports existing imp :: rest
  | existing :: rest -> existing :: add_merged_import rest imp

(* Go collapses an SCC into one package. Preserve the source module namespaces by
   alpha-renaming only the copied emission AST. '$' cannot occur in a Tesl identifier,
   and [Emit_go.go_ident] escapes it deterministically. *)
let alpha_rename_cycle_members ~(targets : Ast.module_form list)
    (members : Ast.module_form list) =
  let member_names = List.map (fun (m : Ast.module_form) -> m.module_name) members in
  let symbols (m : Ast.module_form) =
    List.concat_map (function
      | Ast.DFunc f -> [f.name]
      | Ast.DConst c -> [c.name]
      | Ast.DRecord r -> [r.name]
      | Ast.DEntity e -> [e.name]
      | Ast.DFact f -> [f.name]
      | Ast.DCapture c -> [c.name]
      | Ast.DType (Ast.TypeNewtype { name; _ }) -> [name]
      | Ast.DType (Ast.TypeAdt { name; variants; _ }) ->
        name :: List.map (fun (v : Ast.adt_variant) -> v.ctor) variants
      | _ -> []) m.decls
  in
  let owners = Hashtbl.create 16 in
  List.iter (fun (m : Ast.module_form) -> List.iter (fun name ->
    let prior = Option.value (Hashtbl.find_opt owners name) ~default:[] in
    if not (List.mem m.module_name prior) then
      Hashtbl.replace owners name (m.module_name :: prior)) (symbols m)) members;
  let renamed = Hashtbl.create 16 in
  List.iter (fun (m : Ast.module_form) -> List.iter (fun name ->
    if List.length (Option.value (Hashtbl.find_opt owners name) ~default:[]) > 1 then
      Hashtbl.replace renamed (m.module_name, name)
        (Printf.sprintf "Scc$%s$%s" m.module_name name)) (symbols m)) members;
  let adt_constructors (m : Ast.module_form) type_name =
    List.find_map (function
      | Ast.DType (Ast.TypeAdt { name; variants; _ }) when name = type_name ->
        Some (List.map (fun (v : Ast.adt_variant) -> v.ctor) variants)
      | _ -> None) m.decls
    |> Option.value ~default:[]
  in
  let imported_ctor_owner module_name exposed_type ctor =
    List.find_opt (fun (owner : Ast.module_form) -> owner.module_name = module_name)
      members
    |> Option.map (fun owner -> List.mem ctor (adt_constructors owner exposed_type))
    |> Option.value ~default:false
  in
  let local_owner (m : Ast.module_form) name =
    if List.mem name (symbols m) then Some m.module_name
    else List.find_map (fun (imp : Ast.import_decl) ->
      match imp.names with
      | Ast.ImportAll -> None
      | Ast.ImportExposing names ->
        let exposes item =
          item = name || item = name ^ "(..)"
          || (String.length item >= 4
              && String.sub item (String.length item - 4) 4 = "(..)"
              && imported_ctor_owner imp.module_name
                   (String.sub item 0 (String.length item - 4)) name)
        in
        if List.exists exposes names then Some imp.module_name else None) m.imports
  in
  let split_qualified name =
    match String.rindex_opt name '.' with
    | None -> None
    | Some i -> Some (String.sub name 0 i,
                       String.sub name (i + 1) (String.length name - i - 1))
  in
  let rename m name =
    let owner, bare = match split_qualified name with
      | Some pair -> pair
      | None -> Option.value (local_owner m name) ~default:m.Ast.module_name, name
    in
    match Hashtbl.find_opt renamed (owner, bare) with
    | Some generated -> generated
    | None when List.mem owner member_names -> bare
    | None -> name
  in
  let rec ty m = function
    | Ast.TName ({ name; _ } as n) -> Ast.TName { n with name = rename m name }
    | Ast.TVar _ as t -> t
    | Ast.TApp ({ head; arg; _ } as t) -> Ast.TApp { t with head = ty m head; arg = ty m arg }
    | Ast.TFun ({ dom; cod; _ } as t) -> Ast.TFun { t with dom = ty m dom; cod = ty m cod }
    | Ast.TTuple ({ elems; _ } as t) -> Ast.TTuple { t with elems = List.map (ty m) elems }
  in
  let proof m =
    let rec go = function
      | Ast.PredApp ({ pred; _ } as p) -> Ast.PredApp { p with pred = rename m pred }
      | Ast.PredAnd ({ left; right; _ } as p) ->
        Ast.PredAnd { p with left = go left; right = go right }
    in go
  in
  let binding m (b : Ast.binding) =
    { b with type_expr = ty m b.type_expr; proof_ann = Option.map (proof m) b.proof_ann }
  in
  let field m (f : Ast.field_def) =
    { f with type_expr = ty m f.type_expr; proof_ann = Option.map (proof m) f.proof_ann }
  in
  let rec ret m = function
    | Ast.RetPlain ({ ty = t; _ } as r) -> Ast.RetPlain { r with ty = ty m t }
    | Ast.RetAttached ({ binding = b; _ } as r) -> Ast.RetAttached { r with binding = binding m b }
    | Ast.RetNamedPack ({ ty = t; entity_proof; other_proof; _ } as r) ->
      Ast.RetNamedPack { r with ty = ty m t; entity_proof = Option.map (proof m) entity_proof;
                               other_proof = Option.map (proof m) other_proof }
    | Ast.RetForAll ({ elem_ty; proof = p; _ } as r) -> Ast.RetForAll { r with elem_ty = ty m elem_ty; proof = proof m p }
    | Ast.RetMaybeForAll ({ elem_ty; proof = p; _ } as r) -> Ast.RetMaybeForAll { r with elem_ty = ty m elem_ty; proof = proof m p }
    | Ast.RetSetForAll ({ elem_ty; proof = p; _ } as r) -> Ast.RetSetForAll { r with elem_ty = ty m elem_ty; proof = proof m p }
    | Ast.RetMaybeSetForAll ({ elem_ty; proof = p; _ } as r) -> Ast.RetMaybeSetForAll { r with elem_ty = ty m elem_ty; proof = proof m p }
    | Ast.RetForAllDictValues ({ key_ty; val_ty; proof = p; _ } as r) -> Ast.RetForAllDictValues { r with key_ty = ty m key_ty; val_ty = ty m val_ty; proof = proof m p }
    | Ast.RetForAllDictKeys ({ key_ty; val_ty; proof = p; _ } as r) -> Ast.RetForAllDictKeys { r with key_ty = ty m key_ty; val_ty = ty m val_ty; proof = proof m p }
    | Ast.RetMaybeAttached ({ outer_ty; binding = b; _ } as r) -> Ast.RetMaybeAttached { r with outer_ty = Option.map (ty m) outer_ty; binding = binding m b }
    | Ast.RetExists ({ binding = b; body; _ } as r) -> Ast.RetExists { r with binding = binding m b; body = ret m body }
  in
  let rec pattern m = function
    | Ast.PCon ({ ctor; fields; _ } as p) -> Ast.PCon { p with ctor = rename m ctor; fields = List.map (fun (n, p) -> n, pattern m p) fields }
    | Ast.PNullary ({ ctor; _ } as p) -> Ast.PNullary { p with ctor = rename m ctor }
    | (Ast.PVar _ | Ast.PWild | Ast.PLit _) as p -> p
  in
  let rec expr m e =
    let e = Ast_visitor.map_children (expr m) e in
    match e with
    | Ast.EVar ({ name; _ } as v) -> Ast.EVar { v with name = rename m name }
    | Ast.EField { obj = Ast.EConstructor { name = owner; args = []; _ }; field = name; loc }
      when Hashtbl.mem renamed (owner, name) ->
        Ast.EVar { name = Hashtbl.find renamed (owner, name); loc }
    | Ast.EField { obj = Ast.EConstructor c; field; loc }
      when c.args = [] && List.mem c.name member_names ->
        Ast.EVar { name = field; loc }
    | Ast.EConstructor ({ name; _ } as c) -> Ast.EConstructor { c with name = rename m name }
    | Ast.EEnqueue ({ job_type; _ } as q) ->
      Ast.EEnqueue { q with job_type = rename m job_type }
    | Ast.EPublish ({ event_ctor; _ } as p) ->
      Ast.EPublish { p with event_ctor = rename m event_ctor }
    | Ast.ERecord ({ type_hint; _ } as r) -> Ast.ERecord { r with type_hint = Option.map (rename m) type_hint }
    | Ast.ELet ({ declared_type; declared_proof; _ } as l) ->
      Ast.ELet { l with declared_type = Option.map (ty m) declared_type;
                        declared_proof = Option.map (proof m) declared_proof }
    | Ast.EOk ({ proof = p; _ } as ok) -> Ast.EOk { ok with proof = proof m p }
    | Ast.ELambda ({ params; _ } as l) ->
      Ast.ELambda { l with params = List.map (binding m) params }
    | Ast.ECase ({ arms; _ } as c) -> Ast.ECase { c with arms = List.map (fun (a : Ast.case_arm) -> { a with pattern = pattern m a.pattern }) arms }
    | other -> other
  in
  let rec test_stmts m stmts = List.map (function
    | Ast.TsLet ({ declared_type; value; declared_proof; _ } as s) -> Ast.TsLet { s with declared_type = Option.map (ty m) declared_type; value = expr m value; declared_proof = Option.map (proof m) declared_proof }
    | Ast.TsLetProof ({ value; _ } as s) -> Ast.TsLetProof { s with value = expr m value }
    | Ast.TsExpect ({ left; right; _ } as s) -> Ast.TsExpect { s with left = expr m left; right = Option.map (expr m) right }
    | Ast.TsExpectFail ({ fn; arg; _ } as s) -> Ast.TsExpectFail { s with fn = expr m fn; arg = expr m arg }
    | Ast.TsExpectHasProof ({ fn; arg; _ } as s) -> Ast.TsExpectHasProof { s with fn = expr m fn; arg = expr m arg }
    | Ast.TsProperty ({ params; body; _ } as s) -> Ast.TsProperty { s with params = List.map (fun (p : Ast.property_param) -> { p with binding = binding m p.binding; where_clause = Option.map (expr m) p.where_clause; generator = Option.map (rename m) p.generator }) params; body = expr m body }
    | Ast.TsIf ({ cond; then_stmts; else_stmts; _ } as s) -> Ast.TsIf { s with cond = expr m cond; then_stmts = test_stmts m then_stmts; else_stmts = test_stmts m else_stmts }
    | Ast.TsCase ({ scrut; arms; _ } as s) -> Ast.TsCase { s with scrut = expr m scrut; arms = List.map (fun (a : Ast.ts_case_arm) -> { a with ts_pattern = pattern m a.ts_pattern; ts_guard = Option.map (expr m) a.ts_guard; ts_body = test_stmts m a.ts_body }) arms }
    | Ast.TsExpr ({ e; _ } as s) -> Ast.TsExpr { s with e = expr m e }) stmts
  in
  let decl m = function
    | Ast.DFunc f -> Ast.DFunc { f with name = rename m f.name; params = List.map (binding m) f.params; return_spec = ret m f.return_spec; body = expr m f.body }
    | Ast.DConst c -> Ast.DConst { c with name = rename m c.name; value = expr m c.value }
    | Ast.DRecord r -> Ast.DRecord { r with name = rename m r.name; fields = List.map (field m) r.fields;
      invariant = Option.map (fun (i : Ast.record_invariant) -> { i with proof_text = proof m i.proof_text;
        checker_name = Option.map (rename m) i.checker_name }) r.invariant }
    | Ast.DEntity e -> Ast.DEntity { e with name = rename m e.name; fields = List.map (field m) e.fields }
    | Ast.DDatabase d ->
      let merged = List.hd (List.sort String.compare member_names) in
      let entity name = match split_qualified name with
        | Some (owner, _) when List.mem owner member_names -> merged ^ "." ^ rename m name
        | _ -> rename m name in
      Ast.DDatabase { d with entities = List.map entity d.entities;
        config_expr = Option.map (expr m) d.config_expr }
    | Ast.DFact f -> Ast.DFact { f with name = rename m f.name; params = List.map (binding m) f.params }
    | Ast.DCapture c -> Ast.DCapture { c with name = rename m c.name;
      binding = binding m c.binding; parser = rename m c.parser;
      checker = Option.map (rename m) c.checker }
    | Ast.DType (Ast.TypeNewtype t) -> Ast.DType (Ast.TypeNewtype { t with name = rename m t.name; base_type = ty m t.base_type })
    | Ast.DType (Ast.TypeAdt t) -> Ast.DType (Ast.TypeAdt { t with name = rename m t.name; variants = List.map (fun (v : Ast.adt_variant) -> { v with ctor = rename m v.ctor; fields = List.map (field m) v.fields }) t.variants })
    | Ast.DTest t -> Ast.DTest { t with stmts = test_stmts m t.stmts }
    | Ast.DApiTest t -> Ast.DApiTest { t with seed_stmts = List.map (expr m) t.seed_stmts; stmts = test_stmts m t.stmts }
    | Ast.DLoadTest t -> Ast.DLoadTest { t with seed_stmts = List.map (expr m) t.seed_stmts; request_stmts = test_stmts m t.request_stmts }
    | d -> d
  in
  List.map (fun (m : Ast.module_form) ->
    let import (i : Ast.import_decl) = match i.names with
      | Ast.ImportAll -> i
      | Ast.ImportExposing names -> { i with names = Ast.ImportExposing (List.map (fun name ->
          let suffix = if String.length name >= 4 && String.sub name (String.length name - 4) 4 = "(..)" then "(..)" else "" in
          let bare = if suffix = "" then name else String.sub name 0 (String.length name - 4) in
          Option.value (Hashtbl.find_opt renamed (i.module_name, bare)) ~default:bare ^ suffix) names) }
    in
    { m with decls = List.map (decl m) m.decls; imports = List.map import m.imports;
             exports = List.map (function Ast.ExportName n -> Ast.ExportName (rename m n) | Ast.ExportAdt n -> Ast.ExportAdt (rename m n)) m.exports }) targets

let merge_cycle_members (members : Ast.module_form list) =
  match List.sort (fun (left : Ast.module_form) (right : Ast.module_form) ->
          String.compare left.module_name right.module_name) members with
  | [] -> Error "Go backend found an empty import cycle"
  | [single] -> Ok single
  | first :: _ as sorted ->
    let names = List.map (fun (m : Ast.module_form) -> m.module_name) sorted in
    Ok { first with
            (* Deliberately keeps the first member's name and source_file: the package is
               named after it, and the file is only used for whole-module diagnostics. *)
            decls = List.concat_map (fun (m : Ast.module_form) -> m.decls) sorted;
            exports = List.concat_map (fun (m : Ast.module_form) -> m.exports) sorted;
            imports =
              (* An import of a fellow member disappears with the boundary; everything
                 else is kept once. *)
               List.fold_left (fun acc (m : Ast.module_form) ->
                List.fold_left (fun acc (imp : Ast.import_decl) ->
                  if List.mem imp.module_name names then acc
                   else add_merged_import acc imp) acc m.imports) [] sorted }

(* Every LOCAL module the entry imports, transitively, parsed and checked.  Import
   resolution is this module's job, not the emitter's: `build_local_import_graph` already
   knows how a module name becomes a file path, and it canonicalises so the same file
   reached two ways is one node.  A cyclic SCC collapses into ONE Go package. *)
type go_dependencies =
  (* The collapsed graph handed to the emitter, plus the ORIGINAL per-file modules.  Both
     are needed: the emitter wants one node per SCC, while checking must run per file,
     because a merged module's decls come from several source texts. *)
  (* [entry_emit] is the module the ENTRY landed in: after collapsing it may be a merged
     module named after a different member, and the emitter needs that one to derive the
     Go module path. *)
  | GoDeps of { emit : Ast.module_form list; originals : Ast.module_form list;
                entry_emit : Ast.module_form }
  | GoDepsError of string

let local_dependency_modules entry_path (entry : Ast.module_form) =
  if entry_path = "" || Filename.check_suffix entry_path ">" then GoDeps { emit = [entry]; originals = [entry]; entry_emit = entry }
  else
    let graph = build_local_import_graph ~lifted:go_lifted_module_names entry_path in
    let entry_canon = canonical_import_path entry_path in
    (* One node per SCC: a cycle becomes ONE Go package, so the emitter never sees the
       members separately. *)
    let components = tarjan_sccs graph in
    let failed = ref None in
    let parsed path =
      if path = entry_canon then Some entry
      else match parse_module_file path with
        | Some m -> Some m
        | None ->
          if !failed = None then
            failed := Some (Printf.sprintf "Go backend could not parse imported module %s"
                              (Filename.basename path));
          None
    in
    let component_modules = List.map (List.filter_map parsed) components in
    let originals = List.concat component_modules in
    let ownership_modules = List.map (fun original ->
      match Migration_schema.lower_module ~modules:originals original with
      | Ok lowered -> lowered
      | Error errors ->
        if !failed = None then failed := Some (String.concat "\n"
          (List.map (fun (e : Validation_common.validation_error) -> e.message) errors));
        original) originals in
    (* Rewrite consumers too: after an SCC import target is collapsed, an outside
       module must ask that package for the generated owner-specific export. *)
    let emit_modules = List.fold_left (fun targets members ->
      if List.length members > 1 then alpha_rename_cycle_members ~targets members
      else targets) ownership_modules component_modules in
    let emitted_member (original : Ast.module_form) =
      List.find (fun (candidate : Ast.module_form) ->
        candidate.module_name = original.module_name) emit_modules
    in
    let collapsed = List.filter_map (fun members ->
      if members = [] then None
      else begin
        let emit_members = List.map emitted_member members in
        match merge_cycle_members emit_members with
        | Ok merged ->
          Some (merged, List.map (fun (m : Ast.module_form) -> m.module_name) members)
        | Error message ->
          if !failed = None then failed := Some message;
          None
       end) component_modules in
    (* A module OUTSIDE the cycle imports a MEMBER by name, but the merged module answers
       to only one name.  Rewriting those references here is what keeps the emitter free
       of any cycle concept: after this, no module name refers to a collapsed member. *)
    let rename_table = List.concat_map (fun ((merged : Ast.module_form), members) ->
      List.filter_map (fun member ->
        if member = merged.module_name then None else Some (member, merged.module_name))
        members) collapsed in
    let rewrite (m : Ast.module_form) =
      { m with imports = List.fold_left (fun acc (imp : Ast.import_decl) ->
          let target = match List.assoc_opt imp.module_name rename_table with
            | Some merged_name -> merged_name
            | None -> imp.module_name
          in
          (* A member importing its own merged self is the cycle boundary disappearing. *)
          if target = m.module_name then acc
          else add_merged_import acc { imp with module_name = target }) [] m.imports }
    in
    (match !failed with
     | Some message -> GoDepsError message
     | None ->
       let emit = List.map (fun (merged, members) -> (rewrite merged, members)) collapsed in
       let entry_emit =
         match List.find_opt (fun (_, members) -> List.mem entry.module_name members) emit with
         | Some (merged, _) -> merged
         | None -> entry
       in
       GoDeps { emit = List.map fst emit; originals; entry_emit })

let go_project_diag file message = {
  file; start_line = 1; start_col = 1; end_line = 1; end_col = 1;
  severity = "error"; code = "V001"; message; fix = None; source = "go-emitter";
  manual = None;
}

(* Keep Go's unsupported-export boundary observable even when the frontend also
   rejects an import name.  The checker remains authoritative for --check; Go
   callers additionally get the backend diagnostic that explains why emission
   cannot proceed. *)
let go_import_boundary_diags (filename : string) (m : Ast.module_form) =
  let strip_ctor_suffix name =
    let n = String.length name in
    if n > 4 && String.sub name (n - 4) 4 = "(..)" then
      String.sub name 0 (n - 4)
    else name
  in
  List.concat_map (fun (imp : Ast.import_decl) ->
    match imp.names, Type_system.tesl_module_export_set imp.module_name with
    | ImportExposing names, Some exports ->
      List.filter_map (fun raw_name ->
        let name = strip_ctor_suffix raw_name in
        if List.mem name exports then None
        else Some (go_project_diag filename
          (Printf.sprintf
             "Go backend does not emit the `%s` export `%s`: module `%s` does not export `%s`"
             imp.module_name name imp.module_name name))) names
    | _ -> []) m.imports

let compile_go_source ?(debug=false) ?(path="") filename source =
  match parse_module filename source with
  | Err error -> GoFailure [diag_of_parse_error error]
  | Ok m ->
    let diags = check_module source m in
    if diags <> [] then GoFailure (diags @ go_import_boundary_diags filename m)
    else
      (match local_dependency_modules path m with
       | GoDepsError message -> GoFailure [go_project_diag filename message]
       | GoDeps { emit = modules; originals; entry_emit } ->
         (* Each dependency is checked in its own right: an importer only sees names its
            dependency exports, so a dependency that does not compile must not be
            emitted as if it did. *)
         let dependency_diags = List.concat_map (fun (dependency : Ast.module_form) ->
           if dependency.source_file = m.source_file then []
           else
             match In_channel.with_open_text dependency.source_file In_channel.input_all with
             | dependency_source -> check_module dependency_source dependency
             | exception Sys_error _ -> []) originals in
         if dependency_diags <> [] then GoFailure dependency_diags
         else
            let mode = if debug then Emit_go.Debug else Emit_go.Release in
            match Emit_go.compile_project ~mode ~entry:entry_emit modules with
           | Ok artifacts -> GoSuccess artifacts
           | Error errors -> GoFailure (List.map diag_of_go_emit_error errors))

let compile_go_file ?(debug=false) filename =
  let source = In_channel.with_open_text filename In_channel.input_all in
  compile_go_source ~debug ~path:filename filename source

type compile_result =
  | Success of string
  | Failure of diagnostic list

let artifacts_text artifacts =
  String.concat "\n" (List.map (fun (artifact : Emit_go.artifact) -> artifact.contents) artifacts)

let compile_source ?(root_path=default_root_path ()) ?(type_check=true) ?(debug=false) filename source =
  ignore root_path;
  ignore type_check;
  match compile_go_source ~debug ~path:filename filename source with
  | GoSuccess artifacts -> Success (artifacts_text artifacts)
  | GoFailure diagnostics -> Failure diagnostics

let compile_file ?(root_path=default_root_path ()) ?(type_check=true) filename =
  let source = In_channel.with_open_text filename In_channel.input_all in
  compile_source ~root_path ~type_check filename source

(** Check only — return diagnostics without emitting code. *)
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
    if module_complexity_diagnostics m <> [] then []
    else
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
    if module_complexity_diagnostics m <> [] then [] else
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
           let ctx0 = Checker.make_ctx ~filename ~env:[] () in
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
      let ctx0 = Checker.make_ctx ~filename ~env:(Type_system.make_stdlib_env ()) () in
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

let check_source ?skip_dep_body filename source =
  try
    match parse_module filename source with
    | Err e -> [diag_of_parse_error e]
    | Ok m  -> check_module ?skip_dep_body source m
  with Failure msg -> [{
    file       = filename;
    start_line = 1; start_col = 1;
    end_line   = 1; end_col   = 1;
    severity   = "error";
    code       = "E000";
    message    = msg;
    fix        = None;
    source     = "lexer";
    manual     = None;
  }]

let check_file ?skip_dep_body filename =
  let source = In_channel.with_open_text filename In_channel.input_all in
  check_source ?skip_dep_body filename source

(** Canonical-path membership predicate over a CLI file list.  Used by every
    multi-file check driver so the whole-program dep walk skips the body
    re-check of any module that is ITSELF an argument of the same invocation:
    that module's own per-file check reports its diagnostics exactly once
    (dedupe by [Validation_common.canonical_import_path], which unifies
    `lib.tesl` / `./lib.tesl` / symlinked spellings). *)
let cli_skip_predicate (filenames : string list) : string -> bool =
  let set = Hashtbl.create 16 in
  List.iter (fun f -> Hashtbl.replace set (canonical_import_path f) ()) filenames;
  fun canon -> Hashtbl.mem set canon

(** `--check f1 f2 …`: whole-program check of each file; a dep that is also a
    CLI argument here is reported only under its own entry. *)
let check_files (filenames : string list) : diagnostic list =
  let skip = cli_skip_predicate filenames in
  List.concat_map (fun f -> check_file ~skip_dep_body:skip f) filenames

(* ── Client-generation module merge (#36) ────────────────────────────────── *)

(* The Elm/TS client generators receive one [module_form], but the entrypoint's
   endpoint signatures reference imported-module types by bare name (a request-
   body record, a fact used as a `Proven` phantom).  Emitting only the
   entrypoint's decls therefore produced clients that reference types they
   never define.  Merge every transitively imported local module's CLIENT-
   RELEVANT decls into the entrypoint before emitting: type definitions plus
   the check/auth/establish functions the emitters consult to classify facts
   (client-side validator vs server-only).  Runtime/API surface decls (api,
   server, database, queue, …) are NOT merged — only the entrypoint defines
   the client's endpoints.  Names already defined by the entrypoint win. *)
let merge_imported_client_decls (entry : Ast.module_form) : Ast.module_form =
  let is_client_decl = function
    | Ast.DFact _ | Ast.DType _ | Ast.DRecord _ | Ast.DEntity _
    | Ast.DCodec _ | Ast.DFunc _ -> true
    | _ -> false
  in
  let decl_key = function
    | Ast.DFact (f : Ast.fact_form) -> Some ("fact:" ^ f.name)
    | Ast.DType (Ast.TypeAdt { name; _ })
    | Ast.DType (Ast.TypeNewtype { name; _ }) -> Some ("type:" ^ name)
    | Ast.DRecord (r : Ast.record_form) -> Some ("type:" ^ r.name)
    | Ast.DEntity (e : Ast.entity_form) -> Some ("type:" ^ e.name)
    | Ast.DCodec (c : Ast.codec_form) -> Some ("codec:" ^ c.name)
    | Ast.DFunc (f : Ast.func_decl) -> Some ("fn:" ^ f.name)
    | _ -> None
  in
  let seen_files = Hashtbl.create 8 in
  Hashtbl.replace seen_files entry.Ast.source_file ();
  let seen_names = Hashtbl.create 32 in
  List.iter (fun d ->
    match decl_key d with
    | Some k -> Hashtbl.replace seen_names k ()
    | None -> ()
  ) entry.Ast.decls;
  let rec walk (m : Ast.module_form) : Ast.top_decl list =
    List.concat_map (fun (imp : Ast.import_decl) ->
      let path =
        Checker.resolve_local_import_path m.Ast.source_file imp.Ast.module_name
      in
      if Hashtbl.mem seen_files path || not (Sys.file_exists path) then []
      else begin
        Hashtbl.replace seen_files path ();
        try
          let source = In_channel.with_open_text path In_channel.input_all in
          match Parser.parse_module path source with
          | Err _ -> []   (* the full-checker gate already reported it *)
          | Ok im ->
            let own =
              List.filter (fun d ->
                is_client_decl d
                && (match decl_key d with
                    | Some k when Hashtbl.mem seen_names k -> false
                    | Some k -> Hashtbl.replace seen_names k (); true
                    | None -> false)
              ) im.Ast.decls
            in
            own @ walk im
        with Sys_error _ -> []
      end
    ) m.Ast.imports
  in
  { entry with Ast.decls = entry.Ast.decls @ walk entry }

(* ── WS4: whole-project / batch checking ─────────────────────────────────────
   A normal `tesl --check f1 f2 ...` already checks N files in one OS process,
   so it pays the process-spawn cost once instead of N times.  These helpers go
   one step further: they share the imported-module parse cache
   ([Checker.import_parse_cache]) across every file in the run, so a project
   whose files share local imports (e.g. several modules all importing a common
   `Db`/`Auth` module) parses each imported module *once* for the whole batch
   instead of once per consumer.

   Per-file results are returned as an ordered association list so callers can
   report a per-file pass/fail summary.  Each file is checked independently
   (the cache only avoids redundant *imported-module* parses, it never shares
   the primary module's check state).  The whole-program dep walk skips the
   body re-check of deps that are THEMSELVES batch members ([cli_skip_predicate]),
   so a broken shared module fails its own row exactly once instead of being
   re-reported under every consumer. *)

(** Check each of [filenames] in one process, sharing the imported-module parse
    cache.  Returns [(filename, diagnostics)] in input order. *)
let check_files_batch (filenames : string list) : (string * diagnostic list) list =
  let skip = cli_skip_predicate filenames in
  List.map (fun filename ->
    let diags =
      try check_file ~skip_dep_body:skip filename
      with Sys_error msg ->
        [{ file = filename; start_line = 0; start_col = 0;
           end_line = 0; end_col = 0; severity = "error";
           code = "E000"; message = msg; fix = None; source = "io"; manual = None }]
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
  let local_bindings, expr_types, _field_accesses, _bare_hints, _server_tools_sites, _human_actions_sites, _errors = Checker.check_module_with_metadata m in

  (* Build the checker context for declaration-level info. *)
  let ctx0 = Checker.make_ctx ~filename:m.source_file ~env:[] () in
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
  | Ok m when module_complexity_diagnostics m = [] -> Some (semantic_json_of_module m)
  | Ok m ->
    Some (json_obj [
      "version", "1"; "file", json_str filename;
      "module_name", json_str m.module_name;
      "content_hash", json_str (Digest.to_hex (Digest.string source));
      "records", "[]"; "adts", "[]"; "functions", "[]";
      "local_bindings", "[]"; "expr_types", "[]";
    ])
  | Err _ ->
    (* Resilient path (editor/LSP): the buffer has a syntax error, but the
       parser's top-level recovery can still salvage the declarations that did
       parse.  Emit a best-effort snapshot of those rather than [None], so
       completion/hover/documentSymbol degrade gracefully mid-edit.  The full
       checker may itself raise on a partial module, so guard it. *)
    (match (try Parser.parse_module_recover filename source with Failure _ -> None) with
     | Some m -> (try Some (semantic_json_of_module m) with _ -> None)
     | None ->
       Some (json_obj [
         "version", "1"; "file", json_str filename;
         "module_name", json_str "";
         "content_hash", json_str (Digest.to_hex (Digest.string source));
         "records", "[]"; "adts", "[]"; "functions", "[]";
         "local_bindings", "[]"; "expr_types", "[]";
       ]))

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
   Distinct from [diag_to_json] (which also carries source): this omits the
   redundant requested-file path but retains a path for imported diagnostics. *)
let agent_diag_json ~requested_file (d : diagnostic) : string =
  let base = [
    "code",       json_str d.code;
    "severity",   json_str d.severity;
    "message",    json_str d.message;
    "line",       string_of_int d.start_line;
    "col",        string_of_int d.start_col;
    "end_line",   string_of_int d.end_line;
    "end_col",    string_of_int d.end_col;
  ] in
  let with_file =
    if d.file = requested_file then base else base @ ["file", json_str d.file] in
  let with_fix = match d.fix with
    | None -> with_file
    | Some _ ->
      (* ~code is REQUIRED here.  Without it [fix_to_json] falls back to
         [Diag_fix.content_title], which describes the EDIT ("Replace with
         `TodoApi`") instead of the INTENT ("Change the module name to
         `TodoApi`").  This was silently wrong on the agent-context surface only
         — [diag_to_json] two hundred lines up passes ~code correctly — so every
         quick-fix an AI agent saw had generic wording while the same fix shown
         to the LSP had the real title.  For a language positioned around its
         agent surface, that is the wrong half to degrade. *)
      with_file @ ["fix", fix_to_json ~code:d.code d.fix]
  in
  json_obj with_fix

(* One outstanding proof obligation: location, message, and stable code. *)
let agent_obligation_json ~requested_file (d : diagnostic) : string =
  json_obj ([
    "line",    string_of_int d.start_line;
    "col",     string_of_int d.start_col;
    "message", json_str d.message;
    "code",    json_str d.code;
  ] @ if d.file = requested_file then [] else ["file", json_str d.file])

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
    "diagnostics",  json_arr (List.map (agent_diag_json ~requested_file:file) diags_capped);
    "symbols",      json_arr symbols_capped;
    "proof_obligations", json_arr (List.map (agent_obligation_json ~requested_file:file) oblig_capped);
  ] in
  json_obj (if omitted_pairs = [] then base else base @ ["omitted", json_obj omitted_pairs])

(** Produce the agent-context JSON for [source] under [filename].  Always
    returns a snapshot: on a parse error the diagnostics carry the parse error
    and [symbols] is empty (best-effort, so an agent still gets the error). *)
(* [extra_diags] carries linter findings supplied by the caller (main.ml), which
   depends on both Compile and Linter; Compile cannot reference Linter directly
   (module ordering).  Review 2026-07 (TOOL-AGENTCTX): agent-context — the
   documented primary agent loop — previously dropped ALL linter warnings
   because it only ran [check_source] (the checker emits none), so its "N
   warnings" count was effectively always 0.  Folding [extra_diags] in makes it
   report the same diagnostic set as --check-json. *)
type agent_context_result = {
  json : string;
  ok : bool;
  diagnostics : diagnostic list;
}

let agent_context_result_source ?(extra_diags = []) filename source : agent_context_result =
  let content_hash = Digest.to_hex (Digest.string source) in
  let checked, symbols =
    match parse_module filename source with
    | Ok m -> check_module source m, agent_symbols_of_module m
    | Err error ->
      let diagnostics = [diag_of_parse_error error] in
      let symbols =
        match (try Parser.parse_module_recover filename source with Failure _ -> None) with
        | Some m -> (try agent_symbols_of_module m with _ -> [])
        | None -> [] in
      diagnostics, symbols
  in
  let diagnostics = checked @ extra_diags in
  let ok = not (List.exists (fun d -> d.severity = "error") diagnostics) in
  { json = agent_context_to_json ~file:filename ~content_hash ~diagnostics ~symbols;
    ok; diagnostics }

let agent_context_source ?(extra_diags = []) filename source : string =
  (agent_context_result_source ~extra_diags filename source).json

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
            if List.exists (function Ast.DApiTest _ | Ast.DLoadTest _ -> true | _ -> false) m.decls then
              `Err (Printf.sprintf
                "mutation testing does not support api-test/load-test from extra file %s yet; refusing to skip them"
                path)
            else
              let tests = List.filter (function Ast.DTest _ -> true | _ -> false) m.decls in
              go (List.rev tests @ acc) rest)
  in
  go [] test_files

let mutant_timeout_secs =
  match Sys.getenv_opt "TESL_MUTATE_TIMEOUT" with
  | Some value -> (try int_of_string value with _ -> 120)
  | None -> 120

let timeout_prefix = lazy (
  if Sys.command "command -v timeout >/dev/null 2>&1" = 0
  then Printf.sprintf "timeout %d " mutant_timeout_secs
  else "")

let run_capture cmd : int * string =
  let output_file = Filename.temp_file "tesl_process_" ".txt" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove output_file with Sys_error _ -> ())
    (fun () ->
       let full = Printf.sprintf "%s > %s 2>&1" cmd (Filename.quote output_file) in
       let exit_code = Sys.command full in
       let output =
         try In_channel.with_open_text output_file In_channel.input_all
         with Sys_error _ -> ""
       in
       exit_code, output)

let mutation_test_count (m : module_form) =
  List.fold_left (fun count -> function
    | DTest _ | DApiTest _ | DLoadTest _ -> count + 1
    | _ -> count) 0 m.decls

let prepare_mutation_suite extra_test_decls (m : module_form) =
  let merged =
    if extra_test_decls = [] then m
    else { m with decls = m.decls @ extra_test_decls }
  in
  let stripped = Mutate.strip_infra_tests merged in
  let removed = mutation_test_count merged - mutation_test_count stripped in
  if removed > 0 then
    Result.Error (Printf.sprintf
      "mutation testing would skip %d infrastructure/api/load test block(s); refusing to report a partial score"
      removed)
  else Result.Ok stripped

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end else Sys.remove path

let fresh_temp_dir prefix =
  Filename.temp_dir prefix ""

let rec mkdir_p path =
  if path = "" || path = Filename.current_dir_name then ()
  else if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let write_go_artifacts root (artifacts : Emit_go.artifact list) =
  List.iter (fun (artifact : Emit_go.artifact) ->
    if not (Filename.is_relative artifact.path)
       || List.mem ".." (String.split_on_char '/' artifact.path) then
      invalid_arg ("unsafe Go artifact path: " ^ artifact.path);
    let path = Filename.concat root artifact.path in
    mkdir_p (Filename.dirname path);
    Out_channel.with_open_bin path (fun channel ->
      output_string channel artifact.contents)) artifacts

type go_test_outcome =
  | GoTestsPassed
  | GoTestsFailed of string
  | GoBuildFailed of string
  | GoTestsTimedOut of string
  | GoTestRunnerFailed of string

let string_contains value needle =
  try ignore (Str.search_forward (Str.regexp_string needle) value 0); true
  with Not_found -> false

let classify_go_test_run ~exit_code ~output =
  let started = string_contains output "TESL_GO_TESTS_STARTED" in
  let failed_test = string_contains output "--- FAIL:" in
  if exit_code = 0 && started then GoTestsPassed
  else if exit_code <> 0 && started && failed_test then GoTestsFailed output
  else GoTestRunnerFailed output

let classify_go_build_run ~exit_code ~output =
  if exit_code = 0 then None
  else if exit_code = 124 then Some (GoTestsTimedOut output)
  else Some (GoBuildFailed output)

let run_go_test_artifacts artifacts =
  let test_artifact = List.find_opt (fun (artifact : Emit_go.artifact) ->
    Filename.check_suffix artifact.path "_test.go") artifacts in
  match test_artifact with
  | None -> GoBuildFailed "emitted project has no Go test package"
  | Some test_artifact ->
    let timeout_pfx = Lazy.force timeout_prefix in
    if timeout_pfx = "" then GoTestRunnerFailed "Go mutation testing requires `timeout` on PATH"
    else
    let root = fresh_temp_dir "tesl_go_mutant_" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      write_go_artifacts root artifacts;
      let package = "./" ^ Filename.dirname test_artifact.path in
      let binary = Filename.concat root "tesl-tests" in
       let build_cmd = Printf.sprintf "cd %s && %sgo test -c -o %s %s"
         (Filename.quote root) timeout_pfx (Filename.quote binary) (Filename.quote package) in
       let build_code, build_output = run_capture build_cmd in
       match classify_go_build_run ~exit_code:build_code ~output:build_output with
       | Some outcome -> outcome
       | None ->
         let run_cmd = Printf.sprintf "%s%s -test.v"
           timeout_pfx (Filename.quote binary) in
        let run_code, run_output = run_capture run_cmd in
        if run_code = 124 then GoTestsTimedOut run_output
        else classify_go_test_run ~exit_code:run_code ~output:run_output)

(** Go mutation runner. Mutation generation remains backend-neutral: each
    surface-AST mutant passes through [Emit_go], is compiled first, then its test
    binary runs. A Go compile failure is invalid and can never inflate kills. *)
let mutate_go_file ?(extra_test_files=[]) filename : mutate_result =
  let timeout_pfx = Lazy.force timeout_prefix in
  if timeout_pfx = "" then
    MutateErr "Go mutation testing requires `timeout` on PATH"
  else if fst (run_capture (timeout_pfx ^ "go version")) <> 0 then
    MutateErr "Go mutation testing requires `go` on PATH"
  else
    let source = In_channel.with_open_text filename In_channel.input_all in
    match parse_module filename source with
    | Err error ->
      MutateErr (Printf.sprintf "parse error at %s:%d: %s"
        error.loc.file (error.loc.start.line + 1) error.msg)
    | Ok m ->
      let diags = check_module source m in
      (match List.filter (fun (d : diagnostic) -> d.severity = "error") diags with
       | diagnostic :: _ -> MutateErr ("type error: " ^ diagnostic.message)
       | [] ->
         (match collect_extra_test_decls extra_test_files with
           | `Err message -> MutateErr message
           | `Ok extra_test_decls ->
             (match prepare_mutation_suite extra_test_decls m with
              | Error message -> MutateErr message
              | Ok baseline ->
             let suite_diags = check_module source baseline in
             (match List.filter (fun (d : diagnostic) -> d.severity = "error") suite_diags with
              | diagnostic :: _ -> MutateErr ("mutation test suite error: " ^ diagnostic.message)
              | [] ->
             let with_tests module_ =
               if extra_test_decls = [] then module_
               else { module_ with decls = module_.decls @ extra_test_decls }
             in
            let has_tests = List.exists (function DTest _ -> true | _ -> false) baseline.decls in
            if not has_tests then MutateErr "Go mutation baseline has NO TESTS (no runnable tests)"
            else
              (match Emit_go.compile_module ~mode:Emit_go.Release baseline with
               | Error (error :: _) -> MutateErr ("Go mutation baseline emit failed: " ^ error.message)
               | Error [] -> MutateErr "Go mutation baseline emit failed"
               | Ok (artifacts, _exports) ->
                 (match run_go_test_artifacts artifacts with
                  | GoBuildFailed output -> MutateErr ("Go mutation baseline did not compile:\n" ^ output)
                  | GoTestsFailed output -> MutateErr ("Go mutation baseline tests fail:\n" ^ output)
                  | GoTestsTimedOut output -> MutateErr ("Go mutation baseline timed out:\n" ^ output)
                  | GoTestRunnerFailed output -> MutateErr ("Go mutation baseline runner failed:\n" ^ output)
                  | GoTestsPassed ->
                    let mutants = Mutate.generate_mutants m in
                    let results = List.map (fun (mutant : Mutate.mutant) ->
                      let module_ = with_tests mutant.module_ in
                      let result =
                        match Emit_go.compile_module ~mode:Emit_go.Release module_ with
                        | Error (error :: _) -> Mutate.Error ("Go emit failed: " ^ error.message)
                        | Error [] -> Mutate.Error "Go emit failed"
                        | Ok (artifacts, _exports) ->
                          (match run_go_test_artifacts artifacts with
                           | GoTestsPassed -> Mutate.Survived
                           | GoTestsFailed _ -> Mutate.Killed
                           | GoBuildFailed output -> Mutate.Invalid output
                           | GoTestsTimedOut output -> Mutate.Error ("Go test timed out: " ^ output)
                           | GoTestRunnerFailed output -> Mutate.Error ("Go test runner failed: " ^ output))
                      in
                      mutant, result) mutants in
                    let count predicate = List.length (List.filter predicate results) in
                    let killed = count (fun (_, result) -> result = Mutate.Killed) in
                    let survived = count (fun (_, result) -> result = Mutate.Survived) in
                    let invalid = count (fun (_, result) -> match result with Mutate.Invalid _ -> true | _ -> false) in
                    let errors = count (fun (_, result) -> match result with Mutate.Error _ -> true | _ -> false) in
                    MutateOk {
                      Mutate.total = List.length mutants;
                      killed;
                      survived;
                      invalid;
                      errors;
                      results;
                    }))))))
