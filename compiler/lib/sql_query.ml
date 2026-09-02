(* SQL query structure, recovered from the surface expression tree.

   Tesl writes a query as ordinary application syntax — `selectOne t from Task where
   t.id == id` parses as `EApp`/`EBinop`, not as a dedicated node — so the structure has
   to be recovered before anything can act on it.  That recovery lives HERE, once, rather
   than in each backend: it used to sit inside {!Emit_racket}, which meant a second
   backend had to reimplement ~140 lines of fragile pattern matching to emit the same
   queries, and every other consumer (the checker, the index linter, the validators)
   re-derived its own view besides.

   Everything in this module is backend-neutral: it maps Tesl surface syntax to a typed
   description of the query.  Rendering that description — to SQL text, to Racket, to Go —
   belongs to the backend. *)

open Ast

type sql_clause =
  | SqlPred of { field : string; op : binop; value : expr }
  | SqlOr of sql_clause list
  | SqlIsNull of { field : string }
  | SqlIsNotNull of { field : string }
  | SqlIn of { field : string; values : expr list }
  | SqlNotIn of { field : string; values : expr list }
  | SqlLike of { field : string; pattern : expr }
  | SqlILike of { field : string; pattern : expr }

type sql_join = {
  join_entity : string;
  main_field : string;
  join_field : string;
}

type sql_select_kind =
  | SelectMany
  | SelectOne
  | SelectCount
  | SelectSum of string
  | SelectMax of string
  | SelectMin of string
  | SelectCountBy                (* grouped: List (Tuple2 K Int), GitHub #29 *)
  | SelectSumBy of string        (* grouped: List (Tuple2 K V) over the field *)

(* A `groupBy` bucket key (GitHub #29).  Fail-closed structural surface: a bare
   binder field, or one of the five Time.trunc* calendar buckets applied to a
   PosixMillis field (unit, offset-minutes expression, field). *)
type sql_group_key =
  | GField of string
  | GTimeTrunc of string * expr * string

type sql_select_seed = {
  kind : sql_select_kind;
  binder : string;
  entity : string;
  where_field : string option;
  order : (string * string) option;
  limit : int option;
  offset : int option;
  static_clauses : sql_clause list;
  group_by : sql_group_key list;
  joins : sql_join list;
}

(* Time.trunc* head → the runtime bucket unit symbol. *)
let trunc_unit_of_name = function
  | "truncHour" -> Some "hour"
  | "truncDay" -> Some "day"
  | "truncWeek" -> Some "week"
  | "truncMonth" -> Some "month"
  | "truncYear" -> Some "year"
  | _ -> None

type sql_insert = {
  entity : string;
  fields : (string * expr) list;
}

type sql_delete_seed = {
  binder : string;
  entity : string;
  where_field : string option;
  with_result : bool;
}

type sql_update = {
  binder : string;
  entity : string;
  clauses : sql_clause list;
  updates : (string * expr) list;
  returning_one : bool;
}

type sql_upsert = {
  entity   : string;
  fields   : (string * expr) list;
  conflict : string list;    (* onConflict [f1, f2] *)
  do_update: string list;    (* doUpdate [f1, f2] *)
}

let rec flatten_app_expr acc = function
  | EApp { fn; arg; _ } -> flatten_app_expr (arg :: acc) fn
  | other -> (other, acc)

let entity_name_of_expr = function
  | EConstructor { name; args = []; _ } -> Some name
  | EVar { name; _ } -> Some name
  | _ -> None

let field_name_for_binder binder = function
  | EField { obj = EVar { name; _ }; field; _ } when String.equal name binder -> Some field
  | _ -> None

(* Like field_name_for_binder but also accepts EConstructor (uppercase entity names) *)
let field_name_for_entity entity_name = function
  | EField { obj = EVar { name; _ }; field; _ }
  | EField { obj = EConstructor { name; args = []; _ }; field; _ } when String.equal name entity_name -> Some field
  | _ -> None

let int_literal_value = function
  | ELit { lit = LInt n; _ } -> Some n
  | _ -> None

let rec parse_select_tail binder where_field order limit offset group_by static_clauses joins = function
  | [] -> Some (where_field, order, limit, offset, group_by, static_clauses, joins)
  | EVar { name = "where"; _ } :: EVar { name = "isNull"; _ } :: field_expr :: rest ->
    (match field_name_for_binder binder field_expr with
     | Some field ->
       parse_select_tail binder where_field order limit offset group_by
         (static_clauses @ [SqlIsNull { field }]) joins rest
     | None -> None)
  | EVar { name = "where"; _ } :: EVar { name = "isNotNull"; _ } :: field_expr :: rest ->
    (match field_name_for_binder binder field_expr with
     | Some field ->
       parse_select_tail binder where_field order limit offset group_by
         (static_clauses @ [SqlIsNotNull { field }]) joins rest
     | None -> None)
  | EVar { name = "where"; _ } :: EVar { name = "inList"; _ } :: field_expr :: list_expr :: rest ->
    (match field_name_for_binder binder field_expr with
     | Some field ->
       let values = match list_expr with EList { elems; _ } -> elems | _ -> [] in
       parse_select_tail binder where_field order limit offset group_by
         (static_clauses @ [SqlIn { field; values }]) joins rest
     | None -> None)
  | EVar { name = "where"; _ } :: EVar { name = "notInList"; _ } :: field_expr :: list_expr :: rest ->
    (match field_name_for_binder binder field_expr with
     | Some field ->
       let values = match list_expr with EList { elems; _ } -> elems | _ -> [] in
       parse_select_tail binder where_field order limit offset group_by
         (static_clauses @ [SqlNotIn { field; values }]) joins rest
     | None -> None)
  | EVar { name = "where"; _ } :: EVar { name = "like"; _ } :: field_expr :: pattern_expr :: rest ->
    (match field_name_for_binder binder field_expr with
     | Some field ->
       parse_select_tail binder where_field order limit offset group_by
         (static_clauses @ [SqlLike { field; pattern = pattern_expr }]) joins rest
     | None -> None)
  | EVar { name = "where"; _ } :: EVar { name = "ilike"; _ } :: field_expr :: pattern_expr :: rest ->
    (match field_name_for_binder binder field_expr with
     | Some field ->
       parse_select_tail binder where_field order limit offset group_by
         (static_clauses @ [SqlILike { field; pattern = pattern_expr }]) joins rest
     | None -> None)
  | EVar { name = "where"; _ } :: field_expr :: rest ->
    (match field_name_for_binder binder field_expr with
     | Some field -> parse_select_tail binder (Some field) order limit offset group_by static_clauses joins rest
     | None -> None)
  | EVar { name = "order"; _ } :: field_expr :: EVar { name = dir; _ } :: rest
    when String.equal dir "asc" || String.equal dir "desc" ->
    (match field_name_for_binder binder field_expr with
     | Some field -> parse_select_tail binder where_field (Some (field, dir)) limit offset group_by static_clauses joins rest
     | None -> None)
  | EVar { name = "limit"; _ } :: limit_expr :: rest ->
    (match int_literal_value limit_expr with
     | Some n -> parse_select_tail binder where_field order (Some n) offset group_by static_clauses joins rest
     | None -> None)
  | EVar { name = "offset"; _ } :: offset_expr :: rest ->
    (match int_literal_value offset_expr with
     | Some n -> parse_select_tail binder where_field order limit (Some n) group_by static_clauses joins rest
     | None -> None)
  | EVar { name = "groupBy"; _ } :: key_expr :: rest ->
    let key =
      match field_name_for_binder binder key_expr with
      | Some field -> Some (GField field)
      | None ->
        (* Time.truncX offsetExpr binder.field — the calendar bucket key. *)
        (match flatten_app_expr [] key_expr with
         | EField { obj = (EConstructor { name = "Time"; args = []; _ } | EVar { name = "Time"; _ });
                    field = trunc_name; _ }, [off_expr; field_expr] ->
           (match trunc_unit_of_name trunc_name, field_name_for_binder binder field_expr with
            | Some unit, Some field -> Some (GTimeTrunc (unit, off_expr, field))
            | _ -> None)
         | _ -> None)
    in
    (match key with
     | Some key -> parse_select_tail binder where_field order limit offset (group_by @ [key]) static_clauses joins rest
     | None -> None)
  (* innerJoin EntityName on binder.mainField EntityName.joinField *)
  | EVar { name = "innerJoin"; _ } :: join_entity_expr :: EVar { name = "on"; _ } :: main_field_expr :: join_field_expr :: rest ->
    (match entity_name_of_expr join_entity_expr with
     | Some join_entity ->
       let join_opt =
         match field_name_for_binder binder main_field_expr,
               field_name_for_entity join_entity join_field_expr with
         | Some main_field, Some join_field -> Some { join_entity; main_field; join_field }
         | _ ->
           (match field_name_for_entity join_entity main_field_expr,
                  field_name_for_binder binder join_field_expr with
            | Some join_field, Some main_field -> Some { join_entity; main_field; join_field }
            | _ -> None)
       in
       (match join_opt with
        | Some j -> parse_select_tail binder where_field order limit offset group_by static_clauses (joins @ [j]) rest
        | None -> None)
     | None -> None)
  | _ -> None

let parse_select_seed e =
  let parse_plain kind args =
    match args with
    | EVar { name = binder; _ } :: EVar { name = "from"; _ } :: entity_expr :: rest ->
      (match entity_name_of_expr entity_expr, parse_select_tail binder None None None None [] [] [] rest with
       | Some entity, Some (where_field, order, limit, offset, group_by, static_clauses, joins) ->
         Some { kind; binder; entity; where_field; order; limit; offset; static_clauses; group_by; joins }
       | _ -> None)
    | _ -> None
  in
  let parse_sum args =
    match args with
    | field_expr :: EVar { name = "from"; _ } :: entity_expr :: rest ->
      (match field_expr, entity_name_of_expr entity_expr with
       | EField { obj = EVar { name = binder; _ }; field; _ }, Some entity ->
         (match parse_select_tail binder None None None None [] [] [] rest with
          | Some (where_field, order, limit, offset, group_by, static_clauses, joins) ->
            Some { kind = SelectSum field; binder; entity; where_field; order; limit; offset; static_clauses; group_by; joins }
          | None -> None)
       | _ -> None)
    | _ -> None
  in
  let parse_minmax kind args =
    match args with
    | field_expr :: EVar { name = "from"; _ } :: entity_expr :: rest ->
      (match field_expr, entity_name_of_expr entity_expr with
       | EField { obj = EVar { name = binder; _ }; field; _ }, Some entity ->
         (match parse_select_tail binder None None None None [] [] [] rest with
          | Some (where_field, order, limit, offset, group_by, static_clauses, joins) ->
            Some { kind = kind field; binder; entity; where_field; order; limit; offset; static_clauses; group_by; joins }
          | None -> None)
       | _ -> None)
    | _ -> None
  in
  match flatten_app_expr [] e with
  | EVar { name = "selectOne"; _ }, args -> parse_plain SelectOne args
  | EVar { name = "select"; _ }, args -> parse_plain SelectMany args
  | EVar { name = "selectCount"; _ }, args -> parse_plain SelectCount args
  | EVar { name = "selectSum"; _ }, args -> parse_sum args
  | EVar { name = "selectMax"; _ }, args -> parse_minmax (fun f -> SelectMax f) args
  | EVar { name = "selectMin"; _ }, args -> parse_minmax (fun f -> SelectMin f) args
  | EVar { name = "selectCountBy"; _ }, args -> parse_plain SelectCountBy args
  | EVar { name = "selectSumBy"; _ }, args -> parse_minmax (fun f -> SelectSumBy f) args
  | _ -> None

let parse_insert_expr e =
  match flatten_app_expr [] e with
  | EVar { name = "insert"; _ }, entity_expr :: ERecord { fields; _ } :: [] ->
    (match entity_name_of_expr entity_expr with
     | Some entity -> Some { entity; fields }
     | None -> None)
  | _ -> None

let parse_upsert_expr e =
  (* upsert Entity { field: val, ... }
       onConflict [f1, f2]
       doUpdate   [f1, f2]
     The three keyword arguments appear in the flat arg list as:
       EVar "onConflict", EList [EVar f1; ...], EVar "doUpdate", EList [EVar f1; ...]
  *)
  match flatten_app_expr [] e with
  | EVar { name = "upsert"; _ },
    entity_expr :: ERecord { fields; _ }
    :: EVar { name = "onConflict"; _ } :: EList { elems = conflict_elems; _ }
    :: EVar { name = "doUpdate"; _ }   :: EList { elems = update_elems; _ }
    :: [] ->
    (match entity_name_of_expr entity_expr with
     | Some entity ->
       let field_of = function EVar { name; _ } -> Some name | EField { field; _ } -> Some field | _ -> None in
       let conflict = List.filter_map field_of conflict_elems in
       let do_update = List.filter_map field_of update_elems in
       Some { entity; fields; conflict; do_update }
     | None -> None)
  | _ -> None

let parse_insert_many_expr e =
  (* insertMany list_var in Entity *)
  match flatten_app_expr [] e with
  | EVar { name = "insertMany"; _ }, list_expr :: EVar { name = "in"; _ } :: entity_expr :: [] ->
    (match entity_name_of_expr entity_expr with
     | Some entity ->
       (match list_expr with
        | EVar { name = list_var; _ } -> Some (list_var, entity)
        | _ -> None)
     | None -> None)
  | _ -> None

let parse_delete_seed e =
  match flatten_app_expr [] e with
  | EVar { name = (("delete" | "deleteAndReturnResult") as kw); _ }, EVar { name = binder; _ } :: EVar { name = "from"; _ } :: entity_expr :: rest ->
    let with_result = String.equal kw "deleteAndReturnResult" in
    (match entity_name_of_expr entity_expr with
     | Some entity ->
       (match rest with
        | [] -> Some { binder; entity; where_field = None; with_result }
        | [EVar { name = "where"; _ }; field_expr] ->
          (match field_name_for_binder binder field_expr with
           | Some field -> Some { binder; entity; where_field = Some field; with_result }
           | None -> None)
        | _ -> None)
     | None -> None)
  | _ -> None

let parse_update_start e =
  match flatten_app_expr [] e with
  | EVar { name = (("update" | "updateAndReturnOne") as kw); _ }, EVar { name = binder; _ } :: EVar { name = "in"; _ } :: entity_expr :: [] ->
    (match entity_name_of_expr entity_expr with
     | Some entity ->
       let returning_one = String.equal kw "updateAndReturnOne" in
       Some (binder, entity, returning_one)
     | None -> None)
  | _ -> None

let parse_update_set binder e =
  match flatten_app_expr [] e with
  | EVar { name = "set"; _ }, field_expr :: value :: [] ->
    (match field_name_for_binder binder field_expr with
     | Some field -> Some (field, value)
     | None -> None)
  | _ -> None

let parse_update_value_app binder e =
  match flatten_app_expr [] e with
  | field_expr, [value] ->
    (match field_name_for_binder binder field_expr with
     | Some field -> Some (field, value)
     | None -> None)
  | _ -> None

let parse_returning_one e =
  match flatten_app_expr [] e with
  | EVar { name = "returning"; _ }, [EVar { name = "one"; _ }] -> Some true
  | _ -> None

let parse_standalone_where_field binder e =
  match flatten_app_expr [] e with
  | EVar { name = "where"; _ }, [field_expr] -> field_name_for_binder binder field_expr
  | _ -> None

let same_select_identity (a : sql_select_seed) (b : sql_select_seed) =
  a.kind = b.kind
  && String.equal a.binder b.binder
  && String.equal a.entity b.entity
  && a.order = b.order
  && a.limit = b.limit
  && a.offset = b.offset

let same_delete_identity (a : sql_delete_seed) (b : sql_delete_seed) =
  String.equal a.binder b.binder && String.equal a.entity b.entity

let is_sql_comparison = function
  | BEq | BNeq | BLt | BLe | BGt | BGe -> true
  | _ -> false

let clause_of_comparison binder base_field_of_expr op left right =
  match base_field_of_expr left with
  | Some field -> Some (SqlPred { field; op; value = right })
  | None ->
    (match field_name_for_binder binder left with
     | Some field -> Some (SqlPred { field; op; value = right })
     | None -> None)

let rec collect_sql_clauses binder base_field_of_expr expr =
  match expr with
  | EBinop { op = BAnd; left; right; _ } ->
    (match collect_sql_clauses binder base_field_of_expr left,
           collect_sql_clauses binder base_field_of_expr right with
     | Some left_clauses, Some right_clauses -> Some (left_clauses @ right_clauses)
     | _ -> None)
  | EBinop { op = (BOr | BAdd); left; right; _ } ->
    (match collect_sql_or binder base_field_of_expr left,
           collect_sql_or binder base_field_of_expr right with
     | Some left_clauses, Some right_clauses -> Some [SqlOr (left_clauses @ right_clauses)]
     | _ -> None)
  | EBinop { op; left; right; _ } when is_sql_comparison op ->
    Option.map (fun clause -> [clause]) (clause_of_comparison binder base_field_of_expr op left right)
  | EApp _ ->
    (match flatten_app_expr [] expr with
     | EVar { name = "isNull"; _ }, [field_expr] ->
       (match field_name_for_binder binder field_expr with
        | Some field -> Some [SqlIsNull { field }]
        | None ->
          (match base_field_of_expr field_expr with
           | Some field -> Some [SqlIsNull { field }]
           | None -> None))
     | EVar { name = "isNotNull"; _ }, [field_expr] ->
       (match field_name_for_binder binder field_expr with
        | Some field -> Some [SqlIsNotNull { field }]
        | None ->
          (match base_field_of_expr field_expr with
           | Some field -> Some [SqlIsNotNull { field }]
           | None -> None))
     | EVar { name = "inList"; _ }, [field_expr; list_expr] ->
       (match field_name_for_binder binder field_expr with
        | Some field ->
          let values = match list_expr with EList { elems; _ } -> elems | _ -> [] in
          Some [SqlIn { field; values }]
        | None -> None)
     | EVar { name = "notInList"; _ }, [field_expr; list_expr] ->
       (match field_name_for_binder binder field_expr with
        | Some field ->
          let values = match list_expr with EList { elems; _ } -> elems | _ -> [] in
          Some [SqlNotIn { field; values }]
        | None -> None)
     | EVar { name = "like"; _ }, [field_expr; pattern_expr] ->
       (match field_name_for_binder binder field_expr with
        | Some field -> Some [SqlLike { field; pattern = pattern_expr }]
        | None -> None)
     | EVar { name = "ilike"; _ }, [field_expr; pattern_expr] ->
       (match field_name_for_binder binder field_expr with
        | Some field -> Some [SqlILike { field; pattern = pattern_expr }]
        | None -> None)
     | _ -> None)
  | _ when Option.is_some (base_field_of_expr expr) -> Some []
  | _ -> None

and collect_sql_or binder base_field_of_expr expr =
  match expr with
  | EBinop { op = BAdd; left; right; _ } ->
    (match collect_sql_or binder base_field_of_expr left,
           collect_sql_or binder base_field_of_expr right with
     | Some left_clauses, Some right_clauses -> Some (left_clauses @ right_clauses)
     | _ -> None)
  | EBinop { op; left; right; _ } when is_sql_comparison op ->
    Option.map (fun clause -> [clause]) (clause_of_comparison binder base_field_of_expr op left right)
  | _ -> None

(** Collect SQL modifier continuation atoms from an ELet sequence.
    Returns the list of modifier atoms (e.g. [order; user.name; asc; limit; 10])
    by consuming consecutive ELet { name = "_" } whose value starts with a SQL
    modifier keyword (where, order, limit, offset, groupBy, innerJoin).
    Note: `where` only works for functional predicates (isNull, isNotNull,
    inList, notInList, like, ilike) since comparison operators (>, ==, etc.) have
    lower precedence than function application and cannot appear in a flat app chain. *)
let rec collect_sql_continuation_atoms acc = function
  | ELet { name = "_"; value = modifier; body; _ } ->
    let (head, args) = flatten_app_expr [] modifier in
    (match head with
     | EVar { name = ("where" | "order" | "limit" | "offset" | "groupBy" | "innerJoin"); _ } ->
       collect_sql_continuation_atoms (acc @ (head :: args)) body
     | _ -> (acc, body))
  | other -> (acc, other)

let extract_select_query e =
  let rec find_seed = function
    | EBinop { left; right; _ } ->
      (match find_seed left with
       | Some _ as found -> found
       | None -> find_seed right)
    | EApp { fn = _; _ } as app ->
      (* Try parsing the whole EApp first (handles simple EApp chains).
         If that fails (e.g. head is EBinop from a compound-where+order merge),
         recurse into fn to find the embedded select seed. *)
      (match parse_select_seed app with
       | Some _ as found -> found
       | None ->
         let (head, _) = flatten_app_expr [] app in
         (match head with
          | EBinop _ -> find_seed head
          | _ -> None))
    | other -> parse_select_seed other
  in
  match find_seed e with
  | None -> None
  | Some seed ->
    let base_field_of_expr expr =
      match parse_select_seed expr with
      | Some other when same_select_identity seed other -> other.where_field
      | _ -> None
    in
    match e with
    | EApp _ ->
      (match parse_select_seed e with
       | Some same_seed when same_select_identity seed same_seed ->
         (* Top-level EApp: all modifiers (order, limit, etc.) already parsed into seed *)
         Some (same_seed, [])
       | _ ->
         (* EApp wrapping an EBinop (compound where + outer modifiers).
            E.g.: EApp(EApp(EApp(EBinop(BAnd, where_preds), order), p.field), asc)
            Extract order/limit/etc from the outer EApp args, WHERE clauses from the EBinop. *)
         let (head, tail_args) = flatten_app_expr [] e in
         (match head with
          | EBinop _ ->
            (match parse_select_tail seed.binder seed.where_field
                     seed.order seed.limit seed.offset
                     seed.group_by [] seed.joins tail_args with
             | None -> None
             | Some (_, new_order, new_limit, new_offset, new_group_by, new_sc, new_joins) ->
               let updated_seed =
                 { seed with order = new_order; limit = new_limit; offset = new_offset;
                             group_by = new_group_by;
                             static_clauses = seed.static_clauses @ new_sc;
                             joins = seed.joins @ new_joins }
               in
               (match collect_sql_clauses seed.binder base_field_of_expr head with
                | Some where_clauses -> Some (updated_seed, where_clauses)
                | None -> None))
          | _ -> Some (seed, [])))
    | _ ->
      (match collect_sql_clauses seed.binder base_field_of_expr e with
       | Some clauses -> Some (seed, clauses)
       | None -> None)

(** Try to extract a SQL select query from a multi-line ELet chain.
    Handles the case where SQL modifier clauses (order, limit, offset, groupBy,
    innerJoin) appear on separate lines, parsed as separate ELet { name = "_" }
    sequencing expressions rather than as part of the same select EApp tree. *)
let extract_multiline_select_query = function
  | ELet { name = "_"; value = select_e; body; _ } ->
    (match parse_select_seed select_e with
     | Some _ ->
       let (extra_atoms, _) = collect_sql_continuation_atoms [] body in
       (match extra_atoms with
        | [] -> None
        | _ ->
          (* Rebuild: append modifier atoms as individual EApp args to the base select expr *)
          let dummy = Location.dummy_loc "" in
          let combined = List.fold_left
            (fun fn arg -> EApp { fn; arg; loc = dummy })
            select_e extra_atoms in
          extract_select_query combined)
     | None -> None)
  | _ -> None

let extract_delete_query e =
  let rec find_seed = function
    | EBinop { left; right; _ } ->
      (match find_seed left with
       | Some _ as found -> found
       | None -> find_seed right)
    | other -> parse_delete_seed other
  in
  match find_seed e with
  | None -> None
  | Some seed ->
    let base_field_of_expr expr =
      match parse_delete_seed expr with
      | Some other when same_delete_identity seed other -> other.where_field
      | _ -> None
    in
    let clauses =
      match e with
      | EApp _ -> Some []
      | _ -> collect_sql_clauses seed.binder base_field_of_expr e
    in
    Option.map (fun sql_clauses -> (seed, sql_clauses)) clauses

let flatten_underscore_seq e =
  let rec loop acc = function
    | ELet { name = "_"; value; body; _ } -> loop (value :: acc) body
    | last -> List.rev (last :: acc)
  in
  loop [] e

let extract_update e =
  match flatten_underscore_seq e with
  | first :: rest ->
    (match parse_update_start first with
     | None -> None
     | Some (binder, entity, initial_returning_one) ->
       let rec loop clauses updates returning_one = function
         | [] when updates <> [] -> Some { binder; entity; clauses; updates; returning_one }
         | [] -> None
         | expr :: tl ->
           (match parse_returning_one expr with
            | Some flag ->
              if tl = [] && updates <> [] then Some { binder; entity; clauses; updates; returning_one = flag }
              else None
            | None ->
              match parse_update_set binder expr with
              | Some update -> loop clauses (updates @ [update]) returning_one tl
              | None ->
                match collect_sql_clauses binder (parse_standalone_where_field binder) expr with
                | Some new_clauses when new_clauses <> [] -> loop (clauses @ new_clauses) updates returning_one tl
                | _ -> None)
       in
       loop [] [] initial_returning_one rest)
  | [] -> None

(* Multi-line delete: `delete b from Entity` on one line with `where …` clauses on
   subsequent indented lines.  The parser lowers this to an underscore-`let` chain
   `ELet{_, <delete head>, <where>, …}` (just like multi-line update), so flatten
   the chain and collect the where clauses from the continuation statements.  The
   single-line form (`delete b from Entity where …`) is handled separately by
   extract_delete_query on the EApp/EBinop shape. *)
let extract_delete e =
  match flatten_underscore_seq e with
  | first :: (_ :: _ as rest) ->
    (match parse_delete_seed first with
     | Some seed when seed.where_field = None ->
       let rec loop clauses = function
         | [] -> Some (seed, clauses)
         | expr :: tl ->
           (match collect_sql_clauses seed.binder
                    (parse_standalone_where_field seed.binder) expr with
            | Some new_clauses when new_clauses <> [] -> loop (clauses @ new_clauses) tl
            | _ -> None)
       in
       loop [] rest
     | _ -> None)
  | _ -> None
