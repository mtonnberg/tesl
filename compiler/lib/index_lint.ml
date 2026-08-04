(** Whole-program missing-index lint (W092) and unused-index lint (W093).

    Phase 3 of `roadmap/completed/database_indexes.md`.  Declaring an index has
    been possible since Phases 1–2, but nothing told a developer they had
    forgotten one.  Every other language leaves that to production latency
    graphs, because a compiler that sees one query at a time cannot know the
    program's query set.  Tesl does know it: every `where`, `order`, `groupBy`
    and `innerJoin` column of every query is already resolved at compile time,
    and so is every declared index.  Comparing the two is the point of having
    indexes in the language rather than in a migration folder.

    {2 The queries are read through the EMITTER}

    Query shapes are extracted with {!Emit_racket.extract_select_query} and its
    siblings — the same functions that produce the SQL.  A private re-parse
    would drift, and then the lint would be reasoning about a query the program
    does not actually run.  Anything those functions decline to parse is simply
    not linted (see under-reporting below).

    {2 Deliberately conservative}

    False positives are the whole risk here: a noisy W092 gets suppressed
    wholesale and then the real ones are invisible.  So every uncertainty
    resolves toward saying nothing:

    - {b Only PostgreSQL-backed entities.}  An entity is linted only when this
      file declares both the entity and a `database` with a Postgres backend
      listing it.  A `Memory` backend has nothing to index (every query is a
      scan), and an entity whose database lives in another module cannot be
      judged from here.
    - {b Only `fn`/`handler` bodies.}  Queries inside `test` blocks are not
      production access paths and must not demand an index.
    - {b `like`/`ilike` columns do not count.}  A default-collation B-tree does
      not serve them, so suggesting an index would be bad advice — and counting
      them as "used" would wrongly justify an index that cannot help.
    - {b `groupBy (Time.truncDay …)` does not count.}  It groups by an
      expression, which a plain column index cannot serve.
    - {b An index counts as serving a query when its LEADING column is one the
      query constrains.}  That is the PostgreSQL prefix rule, and it means only
      the no-index-at-all case is reported — never "your index could be better
      ordered", which the compiler cannot know without table statistics.

    {2 Known limit: W093 is file-scoped}

    "No query uses this index" is a whole-program question, and the linter runs
    per file.  W093 therefore only fires when this file both declares the index
    and contains at least one query on that entity — so the common layout of a
    `Db.tesl` holding entities with queries living in sibling modules stays
    silent instead of being told all its indexes are dead.  A file that queries
    an entity through only some of its indexes can still produce a false
    positive; it is a warning, and the message says where to look. *)

open Ast

type finding = {
  code    : string;
  loc     : Location.loc;
  message : string;
}

(* ── Columns a query constrains in a way a B-tree index can serve ─────────── *)

(* `like`/`ilike` are excluded on purpose: see the module header. *)
let rec clause_fields (c : Emit_racket.sql_clause) : string list =
  match c with
  | Emit_racket.SqlPred { field; _ } -> [ field ]
  | Emit_racket.SqlOr cs -> List.concat_map clause_fields cs
  | Emit_racket.SqlIsNull { field } -> [ field ]
  | Emit_racket.SqlIsNotNull { field } -> [ field ]
  | Emit_racket.SqlIn { field; _ } -> [ field ]
  | Emit_racket.SqlNotIn { field; _ } -> [ field ]
  | Emit_racket.SqlLike _ -> []
  | Emit_racket.SqlILike _ -> []

let group_key_fields (k : Emit_racket.sql_group_key) : string list =
  match k with
  | Emit_racket.GField f -> [ f ]
  | Emit_racket.GTimeTrunc _ -> []

(* One entity's worth of constrained columns at one source location.  A query
   with an `innerJoin` produces several: the join column on the main entity and
   the join column on the joined entity each want their own index. *)
type usage = {
  u_entity : string;
  u_binder : string;   (** the query's row binder — part of the query identity *)
  u_fields : string list;
  u_loc    : Location.loc;
  (* Usages that mark an index as USED but are never themselves reported as a
     missing index.  An `onConflict` list is the case: it needs a unique index,
     and a missing one is already a hard compile error
     (Validation_structural.check_upsert_conflict_target), so warning here would
     duplicate it. *)
  u_demands_index : bool;
}

(* A rebuilt or synthesised node carries `Location.dummy_loc`.  The multi-line
   clause form goes through exactly such a rebuild
   ({!Emit_racket.extract_multiline_select_query}), so its usage arrives with no
   position and must not be reported at 1:1 — nor counted as a second, separate
   query.  Both are handled by keying usages on query identity and then choosing
   the earliest REAL location among them. *)
let is_dummy (l : Location.loc) =
  l.start.line = 0 && l.start.col = 0 && l.stop.line = 0 && l.stop.col = 0

let earlier (a : Location.loc) (b : Location.loc) =
  if (a.start.line, a.start.col) <= (b.start.line, b.start.col) then a else b

let dedup lst =
  List.rev
    (List.fold_left (fun acc x -> if List.mem x acc then acc else x :: acc) [] lst)

let select_usages (seed : Emit_racket.sql_select_seed)
                  (dyn : Emit_racket.sql_clause list) loc : usage list =
  let own =
    (match seed.where_field with Some f -> [ f ] | None -> [])
    @ List.concat_map clause_fields seed.static_clauses
    @ List.concat_map clause_fields dyn
    @ (match seed.order with Some (f, _) -> [ f ] | None -> [])
    @ List.concat_map group_key_fields seed.group_by
    @ List.map (fun (j : Emit_racket.sql_join) -> j.main_field) seed.joins
  in
  { u_entity = seed.entity; u_binder = seed.binder; u_fields = dedup own;
    u_loc = loc; u_demands_index = true }
  :: List.map (fun (j : Emit_racket.sql_join) ->
         { u_entity = j.join_entity; u_binder = seed.binder ^ "/join";
           u_fields = [ j.join_field ]; u_loc = loc; u_demands_index = true })
       seed.joins

let usages_of_expr (e : expr) : usage list =
  let loc = Parser.expr_loc e in
  let selects =
    match Emit_racket.extract_select_query e with
    | Some (seed, dyn) -> select_usages seed dyn loc
    | None ->
      (match Emit_racket.extract_multiline_select_query e with
       | Some (seed, dyn) -> select_usages seed dyn loc
       | None -> [])
  in
  let deletes =
    let of_seed (seed : Emit_racket.sql_delete_seed) dyn =
      [ { u_entity = seed.entity; u_binder = seed.binder;
          u_fields = dedup ((match seed.where_field with Some f -> [ f ] | None -> [])
                            @ List.concat_map clause_fields dyn);
          u_loc = loc; u_demands_index = true } ]
    in
    match Emit_racket.extract_delete_query e with
    | Some (seed, dyn) -> of_seed seed dyn
    | None ->
      (match Emit_racket.extract_delete e with
       | Some (seed, dyn) -> of_seed seed dyn
       | None -> [])
  in
  let updates =
    match Emit_racket.extract_update e with
    | Some u ->
      [ { u_entity = u.entity; u_binder = u.binder;
          u_fields = dedup (List.concat_map clause_fields u.clauses);
          u_loc = loc; u_demands_index = true } ]
    | None -> []
  in
  (* `onConflict` marks the unique index as used; it never demands a new one. *)
  let upserts =
    match Emit_racket.parse_upsert_expr e with
    | Some u when u.conflict <> [] ->
      [ { u_entity = u.entity; u_binder = "#upsert"; u_fields = dedup u.conflict;
          u_loc = loc; u_demands_index = false } ]
    | _ -> []
  in
  selects @ deletes @ updates @ upserts

(* ── Entity / database facts from this file ───────────────────────────────── *)

(* An entity is linted only when THIS file declares a Postgres-backed database
   listing it.  `backend = ""` is the default-postgres spelling. *)
let postgres_backed_entities (m : module_form) : string list =
  List.concat_map (function
      | DDatabase db ->
        let db = Desugar.desugar_database_config db in
        if db.backend = "memory" then [] else db.entities
      | _ -> []) m.decls
  |> dedup

(* Columns that already have an index leading with them: the primary key plus
   the first column of every declared index. *)
let indexed_leading_columns (e : entity_form) : string list =
  (if e.primary_key = "" then [] else [ e.primary_key ])
  @ List.filter_map (fun (ix : entity_index) ->
        match ix.ix_fields with f :: _ -> Some f | [] -> None) e.indexes

let index_label (ix : entity_index) =
  Printf.sprintf "%sindex [%s]"
    (if ix.ix_unique then "unique " else "")
    (String.concat ", " ix.ix_fields)

(* ── The passes ───────────────────────────────────────────────────────────── *)

let lint_module (m : module_form) : finding list =
  let entities =
    List.filter_map (function DEntity e -> Some e | _ -> None) m.decls in
  match entities with
  | [] -> []
  | _ ->
    let pg = postgres_backed_entities m in
    let linted name = List.mem name pg in
    let entity_of name =
      List.find_opt (fun (e : entity_form) -> e.name = name) entities in
    (* Only fn/handler bodies: a query in a `test` block is not a production
       access path. *)
    (* Usages are keyed on QUERY IDENTITY — the enclosing function, the entity
       and the row binder — not on a source line.

       Two things force that.  The nested applications of one query's own spine
       each match the extractor with a partial clause list, so a line-keyed
       grouping would judge `where i.orgId == orgId order i.createdAt desc` twice
       and suggest the weaker index.  And the multi-line clause form arrives
       through a rebuild with no location at all, which no line can group.
       Keying on identity and unioning the columns judges each query once, on
       everything it constrains; the reported position is then the earliest real
       location seen for that query, falling back to the function itself.

       The trade-off: two queries on the same entity, in the same function, with
       the same binder merge into one finding over the union of their columns.
       That errs toward one broader suggestion instead of two warnings, which is
       the right direction for a lint nobody can suppress yet. *)
    let usages =
      List.concat_map (function
          | DFunc fd ->
            let acc = ref [] in
            Ast_visitor.iter (fun node -> acc := usages_of_expr node @ !acc) fd.body;
            List.map (fun u -> (fd.name, fd.loc, u)) !acc
          | _ -> []) m.decls
    in
    let usages =
      List.filter (fun (_, _, u) -> u.u_fields <> [] && linted u.u_entity) usages in
    let grouped :
      (string * string * string, string list * Location.loc option * Location.loc * bool)
        Hashtbl.t = Hashtbl.create 16 in
    List.iter (fun (fname, floc, u) ->
        let key = (fname, u.u_entity, u.u_binder) in
        let this_real = if is_dummy u.u_loc then None else Some u.u_loc in
        match Hashtbl.find_opt grouped key with
        | None -> Hashtbl.replace grouped key (u.u_fields, this_real, floc, u.u_demands_index)
        | Some (fields, best, floc0, demands) ->
          let best = match best, this_real with
            | Some a, Some b -> Some (earlier a b)
            | Some a, None -> Some a
            | None, x -> x
          in
          Hashtbl.replace grouped key
            (dedup (fields @ u.u_fields), best, floc0, demands || u.u_demands_index))
      usages;
    let queries =
      Hashtbl.fold (fun (_, entity, _) (fields, best, floc, demands) acc ->
          (entity, fields, (match best with Some l -> l | None -> floc), demands) :: acc)
        grouped []
      |> List.sort (fun (_, _, (a : Location.loc), _) (_, _, (b : Location.loc), _) ->
             compare (a.start.line, a.start.col) (b.start.line, b.start.col))
    in
    (* W092 — a query no declared index (nor the primary key) can serve.
       Reported once per MISSING INDEX rather than once per call site: the
       actionable unit is "add this line to the entity", and three copies of the
       same instruction is how a lint teaches people to ignore it.  The count of
       affected queries is carried in the message instead. *)
    let unserved =
      List.filter (fun (entity, fields, _, demands) ->
          demands
          && (match entity_of entity with
              | None -> false
              | Some e ->
                let leading = indexed_leading_columns e in
                not (List.exists (fun f -> List.mem f leading) fields)))
        queries
    in
    let missing =
      List.filter_map (fun (entity, fields, (loc : Location.loc), _) ->
          let same =
            List.filter (fun (e, fs, _, _) -> e = entity && fs = fields) unserved in
          (* Emit for the first occurrence only. *)
          match same with
          | (_, _, (first_loc : Location.loc), _) :: _
            when (first_loc.start.line, first_loc.start.col) = (loc.start.line, loc.start.col) ->
            let n = List.length same in
            Some {
              code = "W092";
              loc;
              message = Printf.sprintf
                "%s on `%s` %s %s, but no index on `%s` can serve it — \
                 every matching row is found by scanning the whole table; add \
                 `index [%s]` to the entity"
                (if n = 1 then "a query" else Printf.sprintf "%d queries" n)
                entity
                (if n = 1 then "constrains" else "constrain")
                (match fields with
                 | [ f ] -> Printf.sprintf "`%s`" f
                 | fs -> "(" ^ String.concat ", " (List.map (Printf.sprintf "`%s`") fs) ^ ")")
                entity
                (String.concat ", " fields);
            }
          | _ -> None) unserved
    in
    (* W093 — a declared index no query in this file uses.  Scoped to entities
       this file actually queries, so a schema-only module is not told its
       indexes are all dead (see the module header). *)
    let queried_entities =
      dedup (List.map (fun (entity, _, _, _) -> entity) queries) in
    let used_columns entity =
      dedup (List.concat_map
               (fun (e, fields, _, _) -> if e = entity then fields else [])
               queries)
    in
    let unused =
      List.concat_map (fun (e : entity_form) ->
          if not (linted e.name) || not (List.mem e.name queried_entities) then []
          else
            let used = used_columns e.name in
            List.filter_map (fun (ix : entity_index) ->
                match ix.ix_fields with
                | [] -> None
                | leading :: _ ->
                  if List.mem leading used then None
                  else
                    Some {
                      code = "W093";
                      loc = ix.ix_loc;
                      message = Printf.sprintf
                        "`%s` on `%s` is not used by any query in this file — an \
                         unused index costs write throughput on every insert and \
                         update; remove it, or check whether the queries that \
                         need it live in another module"
                        (index_label ix) e.name;
                    }) e.indexes) entities
    in
    missing @ unused
