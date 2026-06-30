(** Tesl source linter.

    Line-level checks — no AST dependency needed.
    All rules match the Python compiler's behaviour.

    Error codes:
      E001  empty file
      E002  missing #lang tesl
      E010  tab character
      E030  receiver-style .length
      E031  receiver-style .startsWith
      E032  receiver-style .isEmpty
      W001  module header not on line 2
      W002  trailing blank lines
      W003  multiple consecutive blank lines
      W010  trailing whitespace
      W011  indentation not a multiple of 2
      W020  module name not UpperCamelCase
      W021  type name not UpperCamelCase
      W022  function name not lowerCamelCase
      W040  single-line ADT-looking type alias (footgun: use multi-line syntax)
      W041  unparenthesized lambda in argument position
      W050  unused import
      W060  unused `let` binding (skips proof half of a proof-decompose)
      W061  unused function parameter
      W062  unreachable code after `fail`
      W063  redundant re-check of an already-validated value (proof footgun)
      W064  discarded `check`/`auth` validation result (proof footgun)
      W070  email declared but startEmailWorker never called
      W080  exported function references unexported type or proof predicate
      W090  bare `print` call bypasses telemetry capability
*)

(* A lint diagnostic uses the same type as Compile.diagnostic so it can
   be printed with the same print_diagnostic function in main.ml. *)
type lint_diag = {
  file    : string;
  line    : int;   (** 0-based *)
  col     : int;   (** 0-based *)
  severity : string;
  code    : string;
  message : string;
  fix     : Compile.diagnostic_fix option;
}

open Validation_common

(* ── Regex helpers ───────────────────────────────────────────────────────── *)

(* OCaml's Str module is available via the tesl_compiler_lib; we use it for
   simple patterns.  For portability we use Re or hand-rolled matching where
   Str is awkward. *)

let starts_with s prefix =
  let pl = String.length prefix in
  String.length s >= pl && String.sub s 0 pl = prefix

let string_contains s sub =
  let sl = String.length s in
  let pl = String.length sub in
  if pl = 0 then true
  else
    let rec loop i =
      if i + pl > sl then false
      else if String.sub s i pl = sub then true
      else loop (i + 1)
    in
    loop 0

(** Find the first occurrence of [sub] in [s], returning the 0-based index. *)
let string_index_of s sub =
  let sl = String.length s in
  let pl = String.length sub in
  if pl = 0 then Some 0
  else
    let rec loop i =
      if i + pl > sl then None
      else if String.sub s i pl = sub then Some i
      else loop (i + 1)
    in
    loop 0

(** Leading whitespace length (spaces only) *)
let leading_spaces s =
  let i = ref 0 in
  while !i < String.length s && s.[!i] = ' ' do incr i done;
  !i

(** Is [s] all whitespace? *)
let is_blank s = String.trim s = ""

let replace_line_fix line replacement =
  Some (Compile.Replace_line { line; replacement })

let trim_trailing_whitespace_fix line_number line trimmed_len =
  replace_line_fix line_number (String.sub line 0 trimmed_len)

let normalize_indentation_fix line_number line indent =
  let even_indent = max 0 (indent - 1) in
  replace_line_fix line_number
    (String.make even_indent ' ' ^ String.sub line indent (String.length line - indent))

(** First word after [prefix] in [stripped], or "". *)
let first_word_after prefix stripped =
  let rest = String.trim (String.sub stripped (String.length prefix)
               (String.length stripped - String.length prefix)) in
  match String.split_on_char ' ' rest with
  | w :: _ when w <> "" -> w
  | _ ->
    match String.split_on_char '\t' rest with
    | w :: _ -> w
    | [] -> ""

(** True if [c] is a letter, digit, or underscore. *)
let is_ident_char c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') || c = '_'

(** Extract identifier starting at position [i] in [s]. *)
let ident_at s i =
  let len = String.length s in
  let j = ref i in
  while !j < len && is_ident_char s.[!j] do incr j done;
  if !j > i then Some (String.sub s i (!j - i)) else None

(** First identifier in [s] at or after position [start]. *)
let first_ident_after s start =
  let len = String.length s in
  let i = ref start in
  while !i < len && not (is_ident_char s.[!i]) do incr i done;
  ident_at s !i

(* ── Individual checks ───────────────────────────────────────────────────── *)

let lint_file_structure (file : string) (lines : string array) (out : lint_diag list ref) =
  let emit ?(fix=None) line col severity code message =
    out := { file; line; col; severity; code; message; fix } :: !out
  in
  if Array.length lines = 0 then
    emit 0 0 "error" "E001" "empty file"
  else begin
    (* #lang tesl must be the first non-empty line — we check line 0 *)
    if not (starts_with (String.trim lines.(0)) "#lang tesl") then
      emit 0 0 "error" "E002" "file must start with `#lang tesl`";
    (* W001: module header must exist and be the first non-blank, non-comment
       line after `#lang tesl`.  Comments (# ...) and blank lines are
       allowed between the lang pragma and the module declaration. *)
    let first_real_line_after_lang =
      let result = ref (-1) in
      Array.iteri (fun i line ->
        if i > 0 && !result = -1 then begin
          let stripped = String.trim line in
          if stripped <> "" && not (starts_with stripped "#") then
            result := i
        end
      ) lines;
      !result
    in
    if first_real_line_after_lang >= 0 then begin
      let l = String.trim lines.(first_real_line_after_lang) in
      if not (starts_with l "module ") then
        emit first_real_line_after_lang 0 "warning" "W001"
          "first non-comment declaration should be a module header"
    end else if Array.length lines >= 2 then begin
      (* All remaining lines are blank/comments — still no module header *)
      emit 1 0 "warning" "W001"
        "first non-comment declaration should be a module header"
    end;
    (* No more than one consecutive blank line *)
    let blank_run = ref 0 in
    Array.iteri (fun i line ->
      if is_blank line then begin
        incr blank_run;
        if !blank_run > 1 then
          emit i 0 "warning" "W003" "no more than one blank line between declarations"
      end else
        blank_run := 0
    ) lines;
    (* No trailing blank lines (last 2 lines both blank) *)
    let n = Array.length lines in
    if n >= 2 && is_blank lines.(n-1) && is_blank lines.(n-2) then
      emit (n-1) 0 "warning" "W002" "file should not end with multiple blank lines"
  end

let lint_whitespace (file : string) (lines : string array) (out : lint_diag list ref) =
  Array.iteri (fun i line ->
    let emit ?(fix=None) col severity code message =
      out := { file; line = i; col; severity; code; message; fix } :: !out
    in
    (* Trailing whitespace *)
    let rlen = ref (String.length line) in
    while !rlen > 0 && (line.[!rlen - 1] = ' ' || line.[!rlen - 1] = '\r') do decr rlen done;
    if !rlen < String.length line then
      emit ~fix:(trim_trailing_whitespace_fix i line !rlen)
        !rlen "warning" "W010" "trailing whitespace";
    (* Tabs *)
    (match string_index_of line "\t" with
     | Some idx -> emit idx "error" "E010" "tabs are not allowed; use spaces"
     | None -> ());
    (* W011: Odd indentation — only on non-blank, non-comment, non-#lang lines.
       Skip continuation lines: those whose preceding non-blank line ends with
       `,`, `(`, `[`, or `->` (multi-line signatures / argument lists). *)
    let stripped = String.trim line in
    if stripped <> "" && not (starts_with stripped "#") then begin
      let ind = leading_spaces line in
      if ind mod 2 <> 0 then begin
        (* Find previous non-blank line *)
        let is_continuation =
          let prev_idx = ref (i - 1) in
          while !prev_idx >= 0 && is_blank lines.(!prev_idx) do decr prev_idx done;
          if !prev_idx < 0 then false
          else begin
            let prev = String.trim lines.(!prev_idx) in
            let len = String.length prev in
            if len = 0 then false
            else
              let last = prev.[len - 1] in
              last = ',' || last = '(' || last = '['
          end
        in
        if not is_continuation then
          emit ~fix:(normalize_indentation_fix i line ind)
            0 "warning" "W011"
            (Printf.sprintf "indentation should be a multiple of 2 spaces (found %d)" ind)
      end
    end
  ) lines

let lint_naming (file : string) (lines : string array) (out : lint_diag list ref) =
  let emit ?(fix=None) line col severity code message =
    out := { file; line; col; severity; code; message; fix } :: !out
  in
  Array.iteri (fun i line ->
    let stripped = String.trim line in
    if stripped = "" || starts_with stripped "#" then ()
    else begin
      (* Module name: UpperCamelCase *)
      if starts_with stripped "module " then begin
        let name = first_word_after "module " stripped in
        (* Check each dot-separated part *)
        let parts = String.split_on_char '.' name in
        let bad = List.exists (fun part ->
          part <> "" && not (part.[0] >= 'A' && part.[0] <= 'Z')
        ) parts in
        if bad then
          emit i 0 "warning" "W020"
            (Printf.sprintf "module name `%s` should be UpperCamelCase" name)
      end;
      (* Type/record/entity names: UpperCamelCase *)
      List.iter (fun kw ->
        if starts_with stripped kw then begin
          let name = first_word_after kw stripped in
          if name <> "" && not (name.[0] >= 'A' && name.[0] <= 'Z') then
            emit i 0 "warning" "W021"
              (Printf.sprintf "type name `%s` should be UpperCamelCase" name)
        end
      ) ["record "; "entity "; "type "];
      (* Function names: lowerCamelCase or snake_case *)
      List.iter (fun kw ->
        if starts_with stripped kw then begin
          let rest = String.trim (String.sub stripped (String.length kw)
                       (String.length stripped - String.length kw)) in
          match first_ident_after rest 0 with
          | Some fname when fname.[0] >= 'A' && fname.[0] <= 'Z' ->
            emit i 0 "warning" "W022"
              (Printf.sprintf "function name `%s` should be lowerCamelCase" fname)
          | _ -> ()
        end
      ) ["fn "; "establish "; "check "; "auth "; "handler "; "worker "; "deadWorker "]
    end
  ) lines

let lint_deprecated_syntax (file : string) (lines : string array) (out : lint_diag list ref) =
  Array.iteri (fun i line ->
    let stripped = String.trim line in
    if stripped = "" || starts_with stripped "#" then ()
    else begin
      let emit ?(fix=None) col code message =
        out := { file; line = i; col; severity = "error"; code; message; fix } :: !out
      in
      (* .length receiver syntax *)
      if string_contains stripped ".length" then begin
        (* Check it's an identifier before .length, not a module qualifier *)
        let len = String.length stripped in
        let dot_pos = ref (-1) in
        let i_s = ref 0 in
        while !i_s + 7 <= len do
          if String.sub stripped !i_s 7 = ".length" then begin
            (* Make sure the character before is an ident char (not e.g. "String") *)
            if !i_s > 0 && is_ident_char stripped.[!i_s - 1] then begin
              (* Make sure character before is lowercase (not a module name) *)
              let start = ref (!i_s - 1) in
              while !start > 0 && is_ident_char stripped.[!start - 1] do decr start done;
              if stripped.[!start] >= 'a' && stripped.[!start] <= 'z' then
                dot_pos := !i_s
            end
          end;
          incr i_s
        done;
        if !dot_pos >= 0 then
          emit !dot_pos "E030"
            "receiver-style `.length` is not supported; use `String.length name`"
      end;
      (* .startsWith( *)
      (match string_index_of stripped ".startsWith(" with
       | Some pos when pos > 0 && is_ident_char stripped.[pos - 1] ->
         let start = ref (pos - 1) in
         while !start > 0 && is_ident_char stripped.[!start - 1] do decr start done;
         if stripped.[!start] >= 'a' && stripped.[!start] <= 'z' then
           emit pos "E031"
             "receiver-style `.startsWith(...)` is not supported; use `String.startsWith name prefix`"
       | _ -> ());
      (* ).isEmpty *)
      (match string_index_of stripped ").isEmpty" with
       | Some pos -> emit pos "E032"
           "receiver-style `(expr).isEmpty` is not supported; use `List.isEmpty expr`"
       | None -> ())
    end
  ) lines

(** W040: Detect single-line type X = UIDENT | ... which looks like an ADT but
    is parsed as a type alias.  The multi-line form is required for real ADTs. *)
let lint_adt_footgun (file : string) (lines : string array) (out : lint_diag list ref) =
  (* A type alias that looks like an ADT:  type Foo = Bar | Baz  (single line).
     Pattern: `type UIDENT = UIDENT (| UIDENT)*` — all on one line. *)
  let uident_re = Str.regexp "^[A-Z][A-Za-z0-9_]*$" in
  let is_uident s = Str.string_match uident_re s 0 in
  let emit ?(fix=None) line col message =
    out := { file; line; col; severity = "error"; code = "W040"; message; fix } :: !out
  in
  Array.iteri (fun i line ->
    let stripped = String.trim line in
    if starts_with stripped "type " then begin
      (* Extract the part after "type " *)
      let rest = String.trim (String.sub stripped 5 (String.length stripped - 5)) in
      (* Look for: UIDENT = UIDENT (| UIDENT)* — all on one line, no record syntax *)
      let parts = String.split_on_char '=' rest in
      match parts with
      | [name_part; rhs] ->
        let name = String.trim name_part in
        let rhs  = String.trim rhs in
        (* Name must be a plain UIDENT (no type params) *)
        if is_uident name then begin
          (* RHS must look like UIDENT | UIDENT | ... *)
          let alts = List.map String.trim (String.split_on_char '|' rhs) in
          if List.length alts >= 2 && List.for_all (fun a -> a <> "" && is_uident a) alts then
            emit i 0
              (Printf.sprintf
                 "type `%s` looks like an ADT but is on one line — \
                  this is a type alias, not an ADT.\n\
                  Use multi-line form:\n\
                  type %s\n  = %s"
                 name name (String.concat "\n  | " alts))
        end
      | _ -> ()
    end
  ) lines

(** W041: Detect unparenthesized lambda in function application position.
    `f fn(n) -> body arg` is parsed as `f (fn(n) -> body arg)` — the lambda
    body greedily consumes `arg`. Write `f (fn(n) -> body) arg` instead. *)
let lint_lambda_in_arg_position (file : string) (lines : string array) (out : lint_diag list ref) =
  (* Detect the pattern: identifier whitespace fn( — a lambda appearing as an
     unparenthesized argument in a function call, without a preceding '(' or '='. *)
  let re = Str.regexp "\\([a-z_A-Z.][a-zA-Z0-9_.]*[ \t]+\\)fn(" in
  Array.iteri (fun i line ->
    let trimmed = String.trim line in
    (* Skip lines that are function declarations (start with 'fn') or assignments *)
    let is_decl = starts_with trimmed "fn " || starts_with trimmed "check " ||
                  starts_with trimmed "auth " || starts_with trimmed "establish " ||
                  starts_with trimmed "worker " || starts_with trimmed "handler " in
    if not is_decl then begin
      try
        let pos = Str.search_forward re line 0 in
        (* Only warn when not inside parens — check that the char before the
           matched identifier is not '(' *)
        let before_pos =
          let start = Str.match_beginning () in
          if start > 0 then Some line.[start - 1] else None
        in
        let preceded_by_paren = match before_pos with
          | Some '(' | Some '=' | Some ',' | Some '[' -> true
          | _ -> false
        in
        if not preceded_by_paren then
          out := { file; line = i; col = pos; severity = "warning"; code = "W041";
            message = "unparenthesized lambda in argument position: \
                       `fn(params) -> body` greedily consumes subsequent tokens as its body. \
                       If this lambda is an argument, wrap it in parens: `(fn(params) -> body)`";
            fix = None } :: !out
      with Not_found -> ()
    end
  ) lines

(* ── AST-based unused import/variable detection ──────────────────────────── *)

(** Collect all names referenced in an expression (recursively).

    Only the variants that contribute MORE than their child expressions — a
    referenced identifier, a qualified name, a capability/effect marker, an
    embedded type or proof annotation, or a pattern's constructor name — are
    matched explicitly.  Each of those still recurses into its child exprs via
    {!Ast_visitor.fold_children}, the single shared structural traversal, and
    the purely-mechanical variants (application, operators, conditionals,
    lists, [fail], [with database]/[transaction], plain/interpolated
    literals) fall through to it directly.  Sharing one traversal means a new
    {!Ast.expr} variant cannot silently escape unused-name analysis.

    Order is irrelevant downstream: the result is only ever consulted with
    [List.mem], so delegating recursion to [fold_children] (which also threads
    left-to-right) preserves behaviour exactly. *)
let rec collect_expr_names acc (e : Ast.expr) =
  match e with
  | EVar { name; _ } -> name :: acc
  | EField { obj; field; _ } ->
    let acc = collect_expr_names acc obj in
    (* Qualified name: Module.field *)
    let qname = match obj with
      | EVar { name = m; _ } | EConstructor { name = m; args = []; _ } ->
        m ^ "." ^ field
      | _ -> field
    in
    qname :: field :: acc
  | ECase { scrut; arms; _ } ->
    let acc = collect_expr_names acc scrut in
    List.fold_left (fun a (arm : Ast.case_arm) ->
      let a = collect_pattern_names a arm.pattern in
      let a = match arm.guard with
        | Some g -> collect_expr_names a g | None -> a in
      collect_expr_names a arm.body
    ) acc arms
  | ELet { declared_type; _ } ->
    let acc = match declared_type with
      | Some te -> collect_type_expr_names acc te | None -> acc in
    Ast_visitor.fold_children collect_expr_names acc e
  | EOk { value; proof; _ } ->
    let acc = collect_expr_names acc value in
    (* Proof annotations reference identifiers too — e.g. in
       `let reattached = rawScore ::: scoreProof`, `scoreProof` is a
       USE of the proof variable declared by a preceding ELetProof.
       Without this walk, the linter spuriously flags `scoreProof`
       as unused. *)
    collect_proof_names acc proof
  | ETelemetry _ ->
    Ast_visitor.fold_children collect_expr_names ("telemetry" :: acc) e
  | EEnqueue _ ->
    Ast_visitor.fold_children collect_expr_names ("queueWrite" :: acc) e
  | EPublish _ ->
    Ast_visitor.fold_children collect_expr_names ("pubsub" :: acc) e
  | EStartWorkers { capabilities; _ } ->
    List.fold_left (fun a c -> c :: a) acc capabilities
  | EWithCapabilities { capabilities; _ } ->
    let acc = List.fold_left (fun a c -> c :: a) acc capabilities in
    Ast_visitor.fold_children collect_expr_names acc e
  | EServe { capabilities; _ } ->
    let acc = List.fold_left (fun a c -> c :: a) acc capabilities in
    Ast_visitor.fold_children collect_expr_names acc e
  | EConstructor { name; _ } ->
    Ast_visitor.fold_children collect_expr_names (name :: acc) e
  | ERecord { type_hint = Some tn; _ } ->
    (* A type-hinted record literal `TypeName { … }` references TypeName (e.g. an
       `agent X = Agent { … }` block, whose RHS is stored as ERecord type_hint
       "Agent"). Credit it so the type's import isn't falsely flagged W050-unused.
       The constructor-application form `TypeName { … }` is credited via EConstructor. *)
    Ast_visitor.fold_children collect_expr_names (tn :: acc) e
  | ELambda { params; _ } ->
    let acc = List.fold_left (fun a (b : Ast.binding) ->
      collect_type_expr_names a b.type_expr
    ) acc params in
    Ast_visitor.fold_children collect_expr_names acc e
  | ECacheGet { cache_name; _ }
  | ECacheSet { cache_name; _ }
  | ECacheDelete { cache_name; _ }
  | ECacheInvalidate { cache_name; _ } ->
    Ast_visitor.fold_children collect_expr_names (cache_name :: acc) e
  | ESendEmail { email_name; _ } ->
    Ast_visitor.fold_children collect_expr_names (email_name :: acc) e
  | EStartEmailWorker { email_name; _ } -> email_name :: acc
  (* Purely-mechanical variants: recurse into child exprs only.  This includes
     EApp, EBinop, EUnop, EIf, ELetProof, ERecord, EList, EFail (now correctly
     descends into its message expr), EWithDatabase, EWithTransaction, and
     plain/interpolated literals. *)
  | _ -> Ast_visitor.fold_children collect_expr_names acc e

and collect_proof_names (acc : string list) (p : Ast.proof_expr) : string list =
  match p with
  | Ast.PredApp { pred; args; _ } ->
    (* Treat both the predicate name and its argument names as references.
       `pred` usually points at a fact / proof variable (e.g. `scoreProof`)
       and each `arg` is a subject name in scope. *)
    let acc = pred :: acc in
    List.fold_left (fun a n -> n :: a) acc args
  | Ast.PredAnd { left; right; _ } ->
    collect_proof_names (collect_proof_names acc left) right

and collect_pattern_names acc (p : Ast.pattern) =
  match p with
  | PVar _ | PWild | PLit _ -> acc
  | PCon { ctor; _ } -> ctor :: acc
  | PNullary { ctor; _ } -> ctor :: acc

and collect_type_expr_names acc (te : Ast.type_expr) =
  match te with
  | TName n -> n.name :: acc
  | TVar _ -> acc
  | TApp { head; arg; _ } ->
    collect_type_expr_names (collect_type_expr_names acc head) arg
  | TFun { dom; cod; _ } ->
    collect_type_expr_names (collect_type_expr_names acc dom) cod
  | TTuple { elems; _ } ->
    List.fold_left collect_type_expr_names acc elems

let collect_proof_names acc (p : Ast.proof_expr) =
  let rec go a = function
    | Ast.PredApp { pred; args; _ } -> pred :: args @ a
    | Ast.PredAnd { left; right; _ } -> go (go a left) right
  in
  go acc p

let collect_binding_names acc (b : Ast.binding) =
  let acc = collect_type_expr_names acc b.type_expr in
  match b.proof_ann with Some p -> collect_proof_names acc p | None -> acc

let rec collect_return_spec_names acc (rs : Ast.return_spec) =
  match rs with
  | Ast.RetPlain { ty; _ } -> collect_type_expr_names acc ty
  | Ast.RetAttached { binding; _ } -> collect_binding_names acc binding
  | Ast.RetNamedPack { ty; entity_proof; other_proof; _ } ->
    let acc = collect_type_expr_names acc ty in
    let acc = match entity_proof with
      | Some p -> collect_proof_names acc p | None -> acc in
    (match other_proof with
     | Some p -> collect_proof_names acc p | None -> acc)
  | Ast.RetForAll { elem_ty; proof; _ }
  | Ast.RetMaybeForAll { elem_ty; proof; _ }
  | Ast.RetSetForAll { elem_ty; proof; _ }
  | Ast.RetMaybeSetForAll { elem_ty; proof; _ } ->
    collect_proof_names (collect_type_expr_names acc elem_ty) proof
  | Ast.RetForAllDictValues { key_ty; val_ty; proof; _ }
  | Ast.RetForAllDictKeys   { key_ty; val_ty; proof; _ } ->
    collect_proof_names
      (collect_type_expr_names (collect_type_expr_names acc key_ty) val_ty)
      proof
  | Ast.RetMaybeAttached { binding; _ } -> collect_binding_names acc binding
  | Ast.RetExists { binding; body; _ } ->
    collect_return_spec_names (collect_binding_names acc binding) body

let rec collect_test_stmt_names acc (ts : Ast.test_stmt) =
  match ts with
  | TsLetProof { value; _ } -> collect_expr_names acc value
  | TsLet { declared_type; value; _ } ->
    let acc = match declared_type with
      | Some te -> collect_type_expr_names acc te | None -> acc in
    collect_expr_names acc value
  | TsExpect { left; right; _ } ->
    let acc = collect_expr_names acc left in
    (match right with Some r -> collect_expr_names acc r | None -> acc)
  | TsExpectFail { fn; arg; _ } ->
    collect_expr_names (collect_expr_names acc fn) arg
  | TsExpectHasProof { fn; arg; _ } ->
    collect_expr_names (collect_expr_names acc fn) arg
  | TsProperty { body; _ } -> collect_expr_names acc body
  | TsIf { cond; then_stmts; else_stmts; _ } ->
    let acc = collect_expr_names acc cond in
    let acc = List.fold_left collect_test_stmt_names acc then_stmts in
    List.fold_left collect_test_stmt_names acc else_stmts
  | TsCase { scrut; arms; _ } ->
    let acc = collect_expr_names acc scrut in
    List.fold_left (fun acc (arm : Ast.ts_case_arm) ->
      let acc = (match arm.ts_guard with Some g -> collect_expr_names acc g | None -> acc) in
      List.fold_left collect_test_stmt_names acc arm.ts_body
    ) acc arms
  | TsExpr { e; _ } -> collect_expr_names acc e

(** Collect all names used in a top-level declaration. *)
let collect_decl_names acc (d : Ast.top_decl) =
  match d with
  | DFunc fd ->
    let acc = List.fold_left (fun a c -> c :: a) acc fd.capabilities in
    let acc = List.fold_left collect_binding_names acc fd.params in
    let acc = collect_return_spec_names acc fd.return_spec in
    collect_expr_names acc fd.body
  | DType (TypeAdt { variants; _ }) ->
    List.fold_left (fun a (v : Ast.adt_variant) ->
      List.fold_left (fun a2 (f : Ast.field_def) ->
        collect_type_expr_names a2 f.type_expr
      ) a v.fields
    ) acc variants
  | DType (TypeNewtype { base_type; _ }) | DType (TypeAlias { base_type; _ }) ->
    collect_type_expr_names acc base_type
  | DRecord rf ->
    List.fold_left (fun a (f : Ast.field_def) ->
      collect_type_expr_names a f.type_expr
    ) acc rf.fields
  | DEntity ef ->
    List.fold_left (fun a (f : Ast.field_def) ->
      collect_type_expr_names a f.type_expr
    ) acc ef.fields
  | DFact { params; _ } ->
    List.fold_left collect_binding_names acc params
  | DCodec cf ->
    let acc = match cf.to_json with
      | ToJsonForbidden | ToJsonAdt -> acc
      | ToJsonFields entries ->
        List.fold_left (fun a (e : Ast.codec_encode_entry) ->
          e.codec :: a
        ) acc entries
    in
    (match cf.from_json with
     | FromJsonForbidden | FromJsonAdt -> acc
     | FromJsonAlts alts ->
       List.fold_left (fun a entries ->
         List.fold_left (fun a2 entry ->
           match entry with
           | Ast.DecodeField { codec; _ } -> codec :: a2
           | Ast.DecodeCrossCheck { checker; _ } -> checker :: a2
           | Ast.DecodeDefault _ -> a2
         ) a entries
       ) acc alts)
  | DTest tf ->
    let acc = List.fold_left (fun a c -> c :: a) acc tf.capabilities in
    List.fold_left collect_test_stmt_names acc tf.stmts
  | DApiTest atf ->
    let acc = List.fold_left (fun a c -> c :: a) acc atf.capabilities in
    List.fold_left collect_test_stmt_names acc atf.stmts
  | DLoadTest ltf ->
    let acc = List.fold_left (fun a c -> c :: a) acc ltf.capabilities in
    let acc = List.fold_left (fun a e -> collect_expr_names a e) acc ltf.seed_stmts in
    List.fold_left collect_test_stmt_names acc ltf.request_stmts
  | DApi af ->
    List.fold_left (fun a (ep : Ast.api_endpoint) ->
      let a = match ep.auth with
        | Some auth -> collect_binding_names (auth.via_fn :: a) auth.binding
        | None -> a in
      let a = List.fold_left (fun a (cap : Ast.api_capture) ->
        collect_binding_names (cap.via_fn :: a) cap.binding
      ) a ep.captures in
      let a = match ep.body with Some b -> collect_binding_names a b | None -> a in
      let a = match ep.body_wire_type with Some t -> t :: a | None -> a in
      let a = match ep.body_via with Some v -> v :: a | None -> a in
      let a = match ep.body_decoder with Some c -> c :: a | None -> a in
      let a = match ep.response_wire_type with Some t -> t :: a | None -> a in
      let a = match ep.response_encoder with Some c -> c :: a | None -> a in
      collect_return_spec_names a ep.return_spec
    ) acc af.endpoints
  | DCapture cf ->
    let acc = match cf.checker with Some c -> c :: acc | None -> acc in
    let acc = cf.parser :: acc in
    collect_binding_names acc cf.binding
  | DServer sf ->
    List.fold_left (fun a (_, handler) -> handler :: a) acc sf.bindings
  | DDatabase df ->
    (* Entity names listed in `entities [...]` are references to imported types. *)
    let acc = List.fold_left (fun a e -> e :: a) acc df.entities in
    (* The `Database { … }` RHS references Database/DatabaseBackend/Postgres/
       PostgresConfig + env(…) calls — credit it so those imports aren't falsely
       flagged W050-unused (same fix as DQueue/DAgent). *)
    let acc = match df.config_expr with Some e -> collect_expr_names acc e | None -> acc in
    (* Extract function names from connection-param values like env("X") or envInt("X",5432). *)
    List.fold_left (fun a (_, v) ->
      match String.index_opt v '(' with
      | Some i when i > 0 -> String.sub v 0 i :: a
      | _ -> a
    ) acc df.postgres
  | DAgent af ->
    (* A declarative `agent X requires [C] = Agent { provider: …, tools: [asTool fn] }`
       references its capabilities and every name in the `Agent { … }` RHS (the
       provider constructor like `anthropic`/`requireEnv` and the `asTool`-wrapped
       tool fns). Descend so those imports aren't falsely flagged W050-unused. *)
    let acc = List.fold_left (fun a c -> c :: a) acc af.capabilities in
    (match af.config_expr with Some e -> collect_expr_names acc e | None -> acc)
  | DConst cf -> collect_expr_names acc cf.value
  | DQueue qf ->
    (* `queue X requires [C] = Queue { database: D, jobs: [Job J w], retry: … }`
       references its capabilities, the database, the job/worker names, and every
       name in the `Queue { … }` RHS (Queue/Job/QueueRetryStrategy/Exponential …).
       Descend so those imports aren't falsely flagged W050-unused. *)
    let acc = List.fold_left (fun a c -> c :: a) acc qf.capabilities in
    let acc = qf.database :: List.fold_left (fun a j -> j :: a) acc qf.jobs in
    (match qf.config_expr with Some e -> collect_expr_names acc e | None -> acc)
  | DChannel chf ->
    let acc = chf.database :: collect_type_expr_names acc chf.payload in
    (match chf.config_expr with Some e -> collect_expr_names acc e | None -> acc)
  | DCache caf ->
    let acc = caf.database :: collect_type_expr_names acc caf.value_type in
    (match caf.config_expr with Some e -> collect_expr_names acc e | None -> acc)
  | DEmail ef ->
    let acc = ef.database :: acc in
    (match ef.config_expr with Some e -> collect_expr_names acc e | None -> acc)
  | DWorkers wf ->
    let acc = wf.queue_name :: acc in
    List.fold_left (fun a (_, fn) -> fn :: a) acc wf.bindings
  | DCapability cf ->
    List.fold_left (fun a c -> c :: a) acc cf.implies

(** Lint unused imports by parsing the source and checking name references. *)
let lint_unused_imports filename (source : string) (out : lint_diag list ref) =
  match Parser.parse_module filename source with
  | Err _ -> ()
  | Ok m ->
    let all_used = List.fold_left collect_decl_names [] m.decls in
    let used_set = Hashtbl.create 128 in
    List.iter (fun n -> Hashtbl.replace used_set n ()) all_used;
    (* Collect all explicitly listed (non-(..) ) names across all imports. *)
    let explicit_names = Hashtbl.create 128 in
    List.iter (fun (imp : Ast.import_decl) ->
      match imp.names with
      | ImportAll -> ()
      | ImportExposing names ->
        List.iter (fun raw ->
          let n = String.length raw in
          if not (n > 4 && String.sub raw (n - 4) 4 = "(..)")
          then Hashtbl.replace explicit_names raw ()
        ) names
    ) m.imports;
    (* Collect locally defined ADT constructor names (uppercase). *)
    let local_ctors = Hashtbl.create 32 in
    List.iter (fun d ->
      match d with
      | Ast.DType (TypeAdt { variants; _ }) ->
        List.iter (fun (v : Ast.adt_variant) ->
          Hashtbl.replace local_ctors v.ctor ()
        ) variants
      | _ -> ()
    ) m.decls;
    (* An "orphan constructor" is an uppercase name that is used in code but is
       neither explicitly imported from any module nor locally defined.  Its only
       possible source is a Name(..) import that brings constructors into scope.
       If orphan constructors exist we must not warn about Name(..) imports,
       because we cannot statically map each constructor back to its parent type
       without loading module definitions. *)
    let has_orphan_ctors = Hashtbl.fold (fun name () found ->
      found || (
        String.length name > 0 &&
        Char.uppercase_ascii name.[0] = name.[0] &&
        not (Hashtbl.mem explicit_names name) &&
        not (Hashtbl.mem local_ctors name)
      )
    ) used_set false in
    List.iter (fun (imp : Ast.import_decl) ->
      match imp.names with
      | ImportAll -> ()
      | ImportExposing names ->
        List.iter (fun raw_name ->
          let n = String.length raw_name in
          let is_dot_dot = n > 4 && String.sub raw_name (n - 4) 4 = "(..)" in
          let name =
            if is_dot_dot then String.sub raw_name 0 (n - 4)
            else raw_name
          in
          (* For Name(..) imports: if any orphan constructors are present we
             cannot determine which import provides them, so suppress the
             warning to avoid false positives (e.g. Bool(..) when only
             True/False are used in expression position). *)
          if not (Hashtbl.mem used_set name)
             && not (is_dot_dot && has_orphan_ctors)
             && not (starts_with name "Is")
             && not (starts_with name "Has")
             && not (starts_with name "From")
             && not (starts_with name "Float")
             && name <> "Fact"
          then
            out := {
              file     = filename;
              line     = imp.loc.start.line;
              col      = imp.loc.start.col;
              severity = "warning";
              code     = "W050";
              message  = Printf.sprintf
                "unused import: `%s` from `%s` is never referenced"
                name imp.module_name;
              fix      = None;
            } :: !out
        ) names
    ) m.imports

(** R51_F05 / R51_F06 — warn about unused `let` bindings and unused function
    parameters. We reuse the same {!collect_expr_names} helper to know which
    names a body references, then emit a warning for each bound name that
    never appears outside its own binding site. The check intentionally
    skips names starting with `_` (the Elm / Haskell convention for
    deliberately-unused names). *)
let rec collect_let_names (acc : (string * Location.loc) list) (e : Ast.expr) =
  match e with
  | Ast.ELet { name; value; body; loc; _ } ->
    let acc = if name <> "_" && not (String.length name > 0 && name.[0] = '_')
              then (name, loc) :: acc else acc in
    collect_let_names (collect_let_names acc value) body
  | Ast.ELetProof { value_name; proof_name = _; value; body; loc; _ } ->
    (* Only the VALUE half of a proof-decompose is checked for being unused.
       The PROOF half (the detached fact `let (v ::: p) = x`) is intentionally
       left unbound-to-a-use in idiomatic code: extracting a proof you do not
       immediately re-attach is the decompose analogue of `detachFact`, and the
       learning corpus ships it that way (e.g. lesson08 `showAge`, lesson09
       `decomposeBoth`). Flagging `p` there is a false positive, so we skip it. *)
    let acc =
      if value_name <> "_" && not (String.length value_name > 0 && value_name.[0] = '_')
      then (value_name, loc) :: acc else acc
    in
    collect_let_names (collect_let_names acc value) body
  | Ast.EIf { cond; then_; else_; _ } ->
    collect_let_names
      (collect_let_names (collect_let_names acc cond) then_) else_
  | Ast.ECase { scrut; arms; _ } ->
    let acc = collect_let_names acc scrut in
    List.fold_left (fun a (arm : Ast.case_arm) ->
      let a = match arm.guard with Some g -> collect_let_names a g | None -> a in
      collect_let_names a arm.body
    ) acc arms
  | Ast.EApp { fn; arg; _ } -> collect_let_names (collect_let_names acc fn) arg
  | Ast.EBinop { left; right; _ } ->
    collect_let_names (collect_let_names acc left) right
  | Ast.EUnop { arg; _ } -> collect_let_names acc arg
  | Ast.ERecord { fields; _ } ->
    List.fold_left (fun a (_, e) -> collect_let_names a e) acc fields
  | Ast.EList { elems; _ } -> List.fold_left collect_let_names acc elems
  | Ast.EWithDatabase { body; _ } | Ast.EWithCapabilities { body; _ }
  | Ast.EWithTransaction { body; _ } -> collect_let_names acc body
  | Ast.ETelemetry { fields; _ } ->
    List.fold_left (fun a (_, e) -> collect_let_names a e) acc fields
  | Ast.EEnqueue { payload; _ } -> collect_let_names acc payload
  | Ast.EPublish { key; payload; _ } ->
    let acc = match key with Some k -> collect_let_names acc k | None -> acc in
    (match payload with Some p -> collect_let_names acc p | None -> acc)
  | Ast.EOk { value; _ } -> collect_let_names acc value
  | Ast.EFail { message; _ } -> collect_let_names acc message
  | Ast.EServe { port; _ } -> collect_let_names acc port
  | Ast.ELambda { body; _ } -> collect_let_names acc body
  | _ -> acc

(** R51_F07 — dead code after `fail`. When a statement sequence contains a
    `fail 400 "..."` as the value of a `let` body (non-terminal position),
    anything after it is unreachable. The parser represents a `fail` that
    is not the tail expression as the *value* of an ELet whose body is the
    sequel — so we look for that pattern. *)
let rec find_dead_after_fail (acc : Location.loc list) (e : Ast.expr) =
  match e with
  | Ast.ELet { value = Ast.EFail { loc = fail_loc; _ }; body; _ } ->
    (* The `fail` is the value of a `let _ = fail ...`, and `body` is the
       sequel. Anything non-trivial in `body` is dead code. *)
    (match body with
     | Ast.ELit { lit = Ast.LInt 0; _ } | Ast.EVar _ -> acc  (* stub rhs *)
     | _ -> fail_loc :: acc)
  | Ast.ELet { value; body; _ } ->
    find_dead_after_fail (find_dead_after_fail acc value) body
  | Ast.EIf { cond; then_; else_; _ } ->
    find_dead_after_fail
      (find_dead_after_fail (find_dead_after_fail acc cond) then_) else_
  | Ast.ECase { scrut; arms; _ } ->
    let acc = find_dead_after_fail acc scrut in
    List.fold_left (fun a (arm : Ast.case_arm) ->
      find_dead_after_fail a arm.body) acc arms
  | Ast.EWithDatabase { body; _ } | Ast.EWithCapabilities { body; _ }
  | Ast.EWithTransaction { body; _ } -> find_dead_after_fail acc body
  | _ -> acc

(** Recognise the expression form of a validating call written with the
    `check`/`auth` keyword.

    In expression position (e.g. `let v = check checkScore n`), the keyword is
    parsed as a head identifier applied to the checker and then the value:
    [EApp { fn = EApp { fn = EVar "check"; arg = checker }; arg = value }].
    Returns [(keyword, checker_name, value_expr)] for the single-checker shape
    where [checker] is a plain identifier.  Compound `(checkA && checkB)`
    checkers and other shapes return [None] (kept deliberately narrow so the
    footgun rules below stay false-positive-free). *)
let check_call_shape (e : Ast.expr) :
  (string * string * Ast.expr) option =
  match e with
  | Ast.EApp { fn = Ast.EApp { fn = Ast.EVar { name = kw; _ };
                               arg = Ast.EVar { name = checker; _ }; _ };
               arg = value; _ }
    when kw = "check" || kw = "auth" ->
    Some (kw, checker, value)
  | _ -> None

(** W063 / W064 — proof-validation footguns that the type checker does *not*
    reject (it happily accepts both, because proofs only ever accumulate):

    - W063 redundant re-check: validating a binding that was already produced
      by the *same* checker. Re-running an HTTP-boundary validator on an
      already-proven value is wasted work and, per lesson54's "scattered
      re-validation" anti-pattern, scatters spurious failure paths through
      business logic.
    - W064 discarded validation result: `let _ = check … ` / `_`-prefixed.
      A `check`/`auth` call is the only way to mint a proof; binding its result
      to `_` throws that proof away while keeping the can-fail side effect. The
      idiomatic "validate but rename" form keeps the proof
      (`let (_ ::: p) = check …`), so a fully-discarded result is suspect.

    We walk the let-chain carrying an environment mapping each binding to the
    checker that produced it (when it was produced by a single-checker
    `check`/`auth`). *)
let rec find_proof_footguns
    (env : (string * string) list)   (* var_name -> checker_name *)
    (acc : lint_diag list)
    (filename : string)
    (e : Ast.expr) : lint_diag list =
  let emit acc (loc : Location.loc) severity code message =
    { file = filename; line = loc.start.line; col = loc.start.col;
      severity; code; message; fix = None } :: acc
  in
  (* Inspect a bound value: flag W063 if it re-checks an already-checked
     binding, and report the checker name it establishes (for env tracking). *)
  let inspect_value acc value : lint_diag list * string option =
    let acc = find_proof_footguns env acc filename value in
    match check_call_shape value with
    | Some (_, checker, Ast.EVar { name = arg_name; loc = arg_loc }) ->
      let acc =
        match List.assoc_opt arg_name env with
        | Some prev when prev = checker ->
          emit acc arg_loc "warning" "W063"
            (Printf.sprintf
               "redundant re-check: `%s` was already validated by `%s`, so \
                checking it again attaches no new proof. Drop this `check` \
                (proofs accumulate — the existing value already carries it)."
               arg_name checker)
        | _ -> acc
      in
      acc, Some checker
    | Some (_, checker, _) -> acc, Some checker
    | None -> acc, None
  in
  match e with
  | Ast.ELet { name; value; body; loc; _ } ->
    let acc, produced = inspect_value acc value in
    (* W064: a fully-discarded validation result. *)
    let acc =
      if (name = "_" || (String.length name > 0 && name.[0] = '_'))
         && produced <> None
      then
        emit acc loc "warning" "W064"
          "discarded validation result — a `check`/`auth` call is the only way \
           to mint a proof, and binding it to `_` throws that proof away while \
           keeping the failure path. Bind the result, or keep just the proof \
           with `let (_ ::: p) = …`."
      else acc
    in
    let env' = match produced with
      | Some checker when name <> "_" -> (name, checker) :: env
      | _ -> env
    in
    find_proof_footguns env' acc filename body
  | Ast.ELetProof { value_name; value; body; _ } ->
    let acc, produced = inspect_value acc value in
    let env' = match produced with
      | Some checker when value_name <> "_" -> (value_name, checker) :: env
      | _ -> env
    in
    find_proof_footguns env' acc filename body
  | Ast.EIf { cond; then_; else_; _ } ->
    let acc = find_proof_footguns env acc filename cond in
    let acc = find_proof_footguns env acc filename then_ in
    find_proof_footguns env acc filename else_
  | Ast.ECase { scrut; arms; _ } ->
    let acc = find_proof_footguns env acc filename scrut in
    List.fold_left (fun acc (arm : Ast.case_arm) ->
      let acc = match arm.guard with
        | Some g -> find_proof_footguns env acc filename g | None -> acc in
      find_proof_footguns env acc filename arm.body
    ) acc arms
  | Ast.EApp { fn; arg; _ } ->
    let acc = find_proof_footguns env acc filename fn in
    find_proof_footguns env acc filename arg
  | Ast.EBinop { left; right; _ } ->
    let acc = find_proof_footguns env acc filename left in
    find_proof_footguns env acc filename right
  | Ast.EUnop { arg; _ } -> find_proof_footguns env acc filename arg
  | Ast.ERecord { fields; _ } ->
    List.fold_left (fun acc (_, v) -> find_proof_footguns env acc filename v) acc fields
  | Ast.EList { elems; _ } ->
    List.fold_left (fun acc v -> find_proof_footguns env acc filename v) acc elems
  | Ast.EWithDatabase { body; _ } | Ast.EWithCapabilities { body; _ }
  | Ast.EWithTransaction { body; _ } -> find_proof_footguns env acc filename body
  | Ast.EOk { value; _ } -> find_proof_footguns env acc filename value
  | Ast.EFail { message; _ } -> find_proof_footguns env acc filename message
  | Ast.ELambda { body; _ } ->
    (* Lambdas open a fresh scope; the outer check-bindings do not flow in via
       parameters, but captured bindings still do, so keep the env. *)
    find_proof_footguns env acc filename body
  | _ -> acc

let lint_unused_locals_and_dead_code filename (source : string) (out : lint_diag list ref) =
  match Parser.parse_module filename source with
  | Err _ -> ()
  | Ok m ->
    List.iter (function
      | Ast.DFunc fd ->
        (* 1. Unused `let` bindings inside the body. *)
        let bound = collect_let_names [] fd.body in
        (* Uses: strip bound names themselves — we only care whether each
           binding is referenced elsewhere. So gather ALL names referenced
           in the body, and compare cardinalities. *)
        let names_in_body = collect_expr_names [] fd.body in
        List.iter (fun (name, (loc : Location.loc)) ->
          (* Count how many times the name appears in body.
             Definition appears once at the `let`; any further reference
             is a use. *)
          let count = List.fold_left (fun c n -> if n = name then c + 1 else c)
            0 names_in_body in
          (* The definition site does NOT add the name to names_in_body;
             only references do. So count = 0 means genuinely unused. *)
          if count = 0 then
            out := {
              file     = filename;
              line     = loc.start.line;
              col      = loc.start.col;
              severity = "warning";
              code     = "W060";
              message  = Printf.sprintf
                "unused `let` binding `%s` — reference it or rename to `_` / `_%s`"
                name name;
              fix      = None;
            } :: !out
        ) bound;
        (* 2. Unused function parameters. *)
        let names_in_param_proofs =
          List.fold_left (fun acc (b : Ast.binding) ->
            match b.proof_ann with
            | None -> acc
            | Some p ->
              let rec go a = function
                | Ast.PredApp { pred; args; _ } -> pred :: args @ a
                | Ast.PredAnd { left; right; _ } -> go (go a left) right
              in go acc p
          ) [] fd.params
        in
        let names_in_return_spec = collect_return_spec_names [] fd.return_spec in
        let all_used_names = names_in_body @ names_in_param_proofs @ names_in_return_spec in
        List.iter (fun (param : Ast.binding) ->
          if param.name <> "_"
             && not (String.length param.name > 0 && param.name.[0] = '_')
             && not (List.mem param.name all_used_names) then
            out := {
              file     = filename;
              line     = param.loc.start.line;
              col      = param.loc.start.col;
              severity = "warning";
              code     = "W061";
              message  = Printf.sprintf
                "unused parameter `%s` — remove it or rename to `_` / `_%s`"
                param.name param.name;
              fix      = None;
            } :: !out
        ) fd.params;
        (* 3. Dead code after fail. *)
        let dead_locs = find_dead_after_fail [] fd.body in
        List.iter (fun (loc : Location.loc) ->
          out := {
            file     = filename;
            line     = loc.start.line;
            col      = loc.start.col;
            severity = "warning";
            code     = "W062";
            message  = "unreachable code after `fail` — everything after a `fail` statement is dead";
            fix      = None;
          } :: !out
        ) dead_locs;
        (* 4. Proof-validation footguns (W063 redundant re-check, W064 discarded
           validation result). *)
        let footguns = find_proof_footguns [] [] filename fd.body in
        List.iter (fun d -> out := d :: !out) footguns
      | _ -> ()
    ) m.decls

(** W070 — email declared but never started.
    For every [DEmail] declaration in a module, check that at least one
    [EStartEmailWorker] call with that email name appears somewhere in the
    module (any function body).  If not, queued emails will never be
    delivered. *)

let rec collect_start_email_workers (acc : string list) (e : Ast.expr) : string list =
  match e with
  | Ast.EStartEmailWorker { email_name; _ } -> email_name :: acc
  | Ast.ELet { value; body; _ } ->
    collect_start_email_workers (collect_start_email_workers acc value) body
  | Ast.ELetProof { value; body; _ } ->
    collect_start_email_workers (collect_start_email_workers acc value) body
  | Ast.EIf { cond; then_; else_; _ } ->
    collect_start_email_workers
      (collect_start_email_workers (collect_start_email_workers acc cond) then_) else_
  | Ast.ECase { scrut; arms; _ } ->
    let acc = collect_start_email_workers acc scrut in
    List.fold_left (fun a (arm : Ast.case_arm) ->
      collect_start_email_workers a arm.body) acc arms
  | Ast.EApp { fn; arg; _ } ->
    collect_start_email_workers (collect_start_email_workers acc fn) arg
  | Ast.EBinop { left; right; _ } ->
    collect_start_email_workers (collect_start_email_workers acc left) right
  | Ast.EUnop { arg; _ } -> collect_start_email_workers acc arg
  | Ast.EWithDatabase { body; _ } | Ast.EWithCapabilities { body; _ }
  | Ast.EWithTransaction { body; _ } -> collect_start_email_workers acc body
  | Ast.EServe _ | Ast.ETelemetry _ | Ast.EEnqueue _ | Ast.EPublish _
  | Ast.EStartWorkers _ | Ast.ESendEmail _ | Ast.ECacheGet _
  | Ast.ECacheSet _ | Ast.ECacheDelete _ | Ast.ECacheInvalidate _
  | Ast.ELambda _ | Ast.ERecord _ | Ast.EList _ | Ast.EOk _ | Ast.EFail _
  | Ast.EConstructor _ | Ast.EField _ | Ast.EVar _ | Ast.ELit _
  | Ast.ERuntimeCall _ -> acc

let lint_missing_email_worker filename (source : string) (out : lint_diag list ref) =
  match Parser.parse_module filename source with
  | Err _ -> ()
  | Ok m ->
    (* 1. Collect all DEmail declaration names + locations. *)
    let email_decls = List.filter_map (function
      | Ast.DEmail ef -> Some (ef.name, ef.loc)
      | _ -> None
    ) m.decls in
    if email_decls <> [] then begin
      (* 2. Walk every function body to find EStartEmailWorker calls. *)
      let started_names = List.fold_left (fun acc decl ->
        match decl with
        | Ast.DFunc fd -> collect_start_email_workers acc fd.body
        | _ -> acc
      ) [] m.decls in
      (* 3. Warn for each email that is never started. *)
      List.iter (fun (name, (loc : Location.loc)) ->
        if not (List.mem name started_names) then
          out := {
            file     = filename;
            line     = loc.start.line;
            col      = loc.start.col;
            severity = "warning";
            code     = "W070";
            message  = Printf.sprintf
              "email `%s` is declared but `startEmailWorker %s` is never called — \
queued emails will not be delivered; add `startEmailWorker %s` in your \
`main` function or server setup"
              name name name;
            fix      = None;
          } :: !out
      ) email_decls
    end

(** W080 — exported function references a locally-defined type or proof
    predicate that is not also exported.

    For library modules this is also a compile error (E090); for regular
    modules it remains advisory: the consumer may still be able to import the
    type from its original source, and app modules are never imported at all. *)
let lint_unexported_signature_names filename (source : string) (out : lint_diag list ref) =
  match Parser.parse_module filename source with
  | Err _ -> ()
  | Ok m ->
    let locally_defined = List.filter_map (function
      | Ast.DRecord r -> Some r.name
      | Ast.DType (Ast.TypeAdt { name; _ }) -> Some name
      | Ast.DType (Ast.TypeNewtype { name; _ }) -> Some name
      | Ast.DType (Ast.TypeAlias { name; _ }) -> Some name
      | Ast.DFact f -> Some f.name
      | Ast.DCapability cap -> Some cap.name
      | _ -> None
    ) m.decls in
    let exported_set = List.filter_map (function
      | Ast.ExportName n | Ast.ExportAdt n -> Some n) m.exports in
    List.iter (function
      | Ast.DFunc fd when List.mem fd.name exported_set ->
        let seen = Hashtbl.create 4 in
        List.iter (fun (name, (loc : Location.loc)) ->
          if not (Hashtbl.mem seen name)
          && List.mem name locally_defined
          && not (List.mem name exported_set) then begin
            Hashtbl.add seen name ();
            out := {
              file     = filename;
              line     = loc.start.line;
              col      = loc.start.col;
              severity = "warning";
              code     = "W080";
              message  = Printf.sprintf
                "`%s` is exported but `%s` (used in its signature) is not — \
                 consumers who import `%s` may not be able to call it; \
                 add `%s` to the `exposing [...]` list"
                fd.name name fd.name name;
              fix = None;
            } :: !out
          end
        ) (func_sig_refs fd)
      | _ -> ()
    ) m.decls

(** W090 — bare `print` call bypasses the telemetry capability.

    `print` is available via Racket interop and returns Unit, but it is an
    uncontrolled side effect that bypasses Tesl's `telemetry` capability guard.
    Use `telemetry` events instead, or add `telemetry` to the function's
    `requires [...]` clause and wrap the call appropriately.

    This fires when `print` appears as a function call in any function body. *)
let rec collect_print_calls (acc : Location.loc list) (e : Ast.expr) : Location.loc list =
  match e with
  | Ast.EApp { fn = Ast.EVar { name = "print"; loc; _ }; arg; _ } ->
    let acc = loc :: acc in
    collect_print_calls acc arg
  | Ast.EApp { fn; arg; _ } ->
    collect_print_calls (collect_print_calls acc fn) arg
  | Ast.ELet { value; body; _ } | Ast.ELetProof { value; body; _ } ->
    collect_print_calls (collect_print_calls acc value) body
  | Ast.EIf { cond; then_; else_; _ } ->
    collect_print_calls (collect_print_calls (collect_print_calls acc cond) then_) else_
  | Ast.ECase { scrut; arms; _ } ->
    let acc = collect_print_calls acc scrut in
    List.fold_left (fun a (arm : Ast.case_arm) -> collect_print_calls a arm.body) acc arms
  | Ast.EBinop { left; right; _ } ->
    collect_print_calls (collect_print_calls acc left) right
  | Ast.EUnop { arg; _ } | Ast.EField { obj = arg; _ } ->
    collect_print_calls acc arg
  | Ast.EList { elems; _ } -> List.fold_left collect_print_calls acc elems
  | Ast.EOk { value; _ } -> collect_print_calls acc value
  | Ast.ERecord { fields; _ } ->
    List.fold_left (fun a (_, v) -> collect_print_calls a v) acc fields
  | Ast.ELambda { body; _ }
  | Ast.EWithDatabase { body; _ } | Ast.EWithCapabilities { body; _ }
  | Ast.EWithTransaction { body; _ } -> collect_print_calls acc body
  | Ast.EConstructor { args; _ } -> List.fold_left collect_print_calls acc args
  | Ast.EFail _ | Ast.EVar _ | Ast.ELit _ | Ast.EServe _ | Ast.EStartWorkers _
  | Ast.ETelemetry _ | Ast.EEnqueue _ | Ast.EPublish _ | Ast.ECacheGet _
  | Ast.ECacheSet _ | Ast.ECacheDelete _ | Ast.ECacheInvalidate _
  | Ast.ESendEmail _ | Ast.EStartEmailWorker _ | Ast.ERuntimeCall _ -> acc

let lint_bare_print filename (source : string) (out : lint_diag list ref) =
  match Parser.parse_module filename source with
  | Err _ -> ()
  | Ok m ->
    List.iter (function
      | Ast.DFunc fd ->
        let locs = collect_print_calls [] fd.body in
        List.iter (fun (loc : Location.loc) ->
          out := {
            file     = filename;
            line     = loc.start.line;
            col      = loc.start.col;
            severity = "warning";
            code     = "W090";
            message  =
              "bare `print` call bypasses Tesl's telemetry capability — \
               use `telemetry` events for observable output, or remove for production";
            fix = None;
          } :: !out
        ) locs
      | _ -> ()
    ) m.decls

(* ── Public API ──────────────────────────────────────────────────────────── *)

(** Run all lint checks and return diagnostics as [Compile.diagnostic] values
    so they can be printed by the same [print_diagnostic] in main.ml. *)
let lint_file (filename : string) : Compile.diagnostic list =
  let src =
    try In_channel.with_open_text filename In_channel.input_all
    with Sys_error _ -> ""
  in
  let lines = Array.of_list (String.split_on_char '\n' src) in
  let out = ref [] in
  lint_file_structure    filename lines out;
  lint_whitespace        filename lines out;
  lint_naming            filename lines out;
  lint_deprecated_syntax filename lines out;
  lint_adt_footgun             filename lines out;
  lint_lambda_in_arg_position  filename lines out;
  lint_unused_imports          filename src out;
  lint_unused_locals_and_dead_code filename src out;
  lint_missing_email_worker    filename src out;
  lint_unexported_signature_names filename src out;
  lint_bare_print                 filename src out;
  (* Sort by line then col *)
  let sorted = List.sort (fun a b ->
    let c = compare a.line b.line in
    if c <> 0 then c else compare a.col b.col
  ) (List.rev !out) in
  List.map (fun d -> {
    Compile.file       = d.file;
    start_line         = d.line;
    start_col          = d.col;
    end_line           = d.line;
    end_col            = d.col;
    severity           = d.severity;
    code               = d.code;
    message            = d.message;
    fix                = d.fix;
    source             = "lint";
  }) sorted
