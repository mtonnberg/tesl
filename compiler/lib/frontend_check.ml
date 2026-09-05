(** Shared frontend judgment, independent of emission and migration planning.
    Inventories and ordinary compiler queries use the same parsing, type, proof,
    validation and dependency checks. Keep those checks here so a migration cannot
    gain a weaker checking path merely to avoid a module dependency cycle. *)

open Parser
open Ast

let lexer_failure_prefix = Parser.lexer_failure_prefix

(** Total parser boundary for compiler APIs.  The lexer reports malformed bytes
    and unterminated literals with [Failure]; convert those into the parser's
    normal error channel so every JSON query can still emit its documented
    envelope. *)
let parse_module_uncached (filename, source) = Parser.parse_module filename source

let cached_parse_module = Query_cache.memo ~limit:32 ~max_weight:(2 * 1024 * 1024)
  ~weight:(fun (_, source) -> String.length source) parse_module_uncached
let parse_module filename source = cached_parse_module (filename, source)


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
    let source = Source_input.read_text path in
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

let build_local_import_graph ?(lifted=[]) ?entry entry_path =
  let graph : (string, string list) Hashtbl.t = Hashtbl.create 16 in
  let entry_canon = canonical_import_path entry_path in
  let rec visit path =
    if Hashtbl.mem graph path then ()
    else begin
      let deps =
        match (if path = entry_canon && entry <> None then entry else parse_module_file path) with
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
  visit entry_canon;
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

(** Attach edits using the exact source checked by this module's judgment,
    including editor buffers and the separate source of an imported library. *)
let validation_diags_of source (m : Ast.module_form) =
  List.map (fun error ->
    let diagnostic = diag_of_validation_error error in
    if diagnostic.code <> "MIG015" then diagnostic
    else
      let imported = List.find_opt (fun (imp : Ast.import_decl) ->
        imp.loc = error.Validation_common.loc) m.imports in
      let fix = match imported with
        | Some imp ->
          (match String.split_on_char '.' imp.module_name with
           | family :: before :: _ ->
             Migration_source.version_fix ~family ~before ~after:"VCurrent" source
           | _ -> None)
        | None -> None in
      { diagnostic with fix }) (Validation.check_module m)

(** The full per-module check pipeline, reused by the cross-module graph walk
    so dependency diagnostics and fixes stay anchored at their own source. *)
let module_local_diags ?(additional = fun _ _ -> []) source (m : Ast.module_form) : diagnostic list =
  match module_complexity_diagnostics m with
  | _ :: _ as diagnostics -> diagnostics
  | [] ->
    legacy_bool_diagnostics m.source_file source m
    @ regex_literal_diagnostics m
    @ type_diags_of source m
    @ List.map diag_of_proof_error (Proof_checker.check_module m)
    @ validation_diags_of source m
    @ additional source m

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

let cross_module_diags ?(additional = fun _ _ -> []) ?(skip_dep_body : string -> bool = fun _ -> false)
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
                  (try Some (Source_input.read_text spelling)
                   with Sys_error _ -> None)
                with
                | Some dep_source ->
                  diags := List.rev_append
                             (module_local_diags ~additional dep_source dep_m) !diags
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
let check_module ?(additional = fun _ _ -> []) ?skip_dep_body source (m : Ast.module_form) : diagnostic list =
  match module_local_diags ~additional source m with
  | ({ code = "E003"; _ } :: _) as diagnostics -> diagnostics
  | diagnostics -> diagnostics @ cross_module_diags ~additional ?skip_dep_body m
