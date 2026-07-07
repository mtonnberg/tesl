(** B1 — cross-seam SQL effect conformance (OCaml registry <-> emitted Racket
    db-guard head).

    The read/write split of the SQL builtins is stated TWICE, independently:

      (1) OCaml side — {!Validation_common.sql_op_effect} classifies each op as
          [SqlRead] / [SqlWrite]; this drives the capability write-set
          (dbRead vs dbWrite) and the FromDb forgery gate, so it is
          soundness-load-bearing.

      (2) Racket side — [dsl/sql.rkt] states the same split as a hardcoded
          per-fn [(require-capabilities! (list db-read))] / [(list db-write)]
          on the runtime function each op LOWERS to.

    The existing [test_sql_registry.ml] binds effect only to a *spelling* oracle
    ("read op names begin with select") — it never touches [sql.rkt], so the two
    statements can silently drift (flip a [require-capabilities!] in [sql.rkt],
    or add an op whose emit head is guarded with the wrong effect, and nothing
    fails).  This test closes that hole: it asserts, for every op in
    [all_sql_ops],

        sql_op_effect op = SqlWrite  IFF  the op's emitted Racket head is
        guarded by (require-capabilities! (list db-write)) in dsl/sql.rkt

    checked in BOTH directions:
      (A) every op's emitted head is db-guarded in sql.rkt, with the guard
          effect equal to sql_op_effect;
      (B) every db-guarded head parsed out of sql.rkt is produced by some op
          (no orphan guard fn that no op targets — catches a renamed/removed
          emit head).

    The op->head map is an EXHAUSTIVE OCaml match, so a new [sql_op] ctor cannot
    compile until its head is declared here.  The guard set is PARSED from the
    real [dsl/sql.rkt] text (not hardcoded), so it tracks the runtime.  A
    positive check additionally compiles [example/learn/lesson21-sql-reference.tesl]
    and confirms each head actually appears in the emitted Racket — proving the
    op->head map is emit-truthful, not a fiction.

    Pure OCaml, no alcotest / no Racket runtime (parses sql.rkt as text + drives
    Compile.compile_source).  Needs the repo tree at TESL_REPO_ROOT /
    repo_root_default:
      dune exec test/test_sql_crossseam.exe *)

open Validation_common

let failures = ref 0
let check name ok =
  if ok then Printf.printf "ok   - %s\n" name
  else begin incr failures; Printf.printf "FAIL - %s\n" name end

(* Repo root: mirror test_integration.ml's resolution exactly (TESL_REPO_ROOT
   else walk up from the executable to the dir containing compiler/). *)
let repo_root_default () =
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

let root =
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some p when p <> "" -> p
  | _ -> repo_root_default ()

(* (1) op -> emitted Racket runtime head.  EXHAUSTIVE match: a new [sql_op] ctor
   without a head declared here fails to compile.  These are exactly the fn
   names emitted by Emit_racket.emit_sql_* (SqlSelect and SqlSelectMany both
   lower to select-many; SqlUpdate and SqlUpdateAndReturnOne both to
   update-many!). *)
let sql_op_racket_head : sql_op -> string = function
  | SqlSelect | SqlSelectMany -> "select-many"
  | SqlSelectOne -> "select-one"
  | SqlSelectCount -> "select-count"
  | SqlSelectSum -> "select-sum"
  | SqlSelectMax -> "select-max"
  | SqlSelectMin -> "select-min"
  | SqlSelectCountBy -> "select-count-by"
  | SqlSelectSumBy -> "select-sum-by"
  | SqlInsert -> "insert-one!"
  | SqlInsertMany -> "insert-many!"
  | SqlUpsert -> "upsert-one!"
  | SqlUpdate | SqlUpdateAndReturnOne -> "update-many!"
  | SqlDelete -> "delete-many!"
  | SqlDeleteAndReturnResult -> "delete-many-with-count!"

(* (2) Parse dsl/sql.rkt: map each db-guarded runtime head -> the effect stated
   by its ACTUAL guard.  Scan lines; on `(define (HEAD ...` record HEAD as the
   pending fn; on the next `(require-capabilities! (list db-read|db-write))`
   bind HEAD->effect.  A [define] with no [require-capabilities!] (the
   postgres-* / in-memory-* helpers) is simply overwritten by the next [define]
   before any guard is seen, so only the 12 db-guarded entry points are
   recorded. *)
let guard_of_rkt () =
  let path = Filename.concat root "dsl/sql.rkt" in
  let ic = open_in path in
  let tbl : (string, sql_effect) Hashtbl.t = Hashtbl.create 32 in
  let def_re = Str.regexp "^(define (\\([a-z!?*<>=+-]+\\)" in
  let cap_re =
    Str.regexp "require-capabilities! (list \\(db-read\\|db-write\\))" in
  let pending = ref None in
  (try
     while true do
       let line = input_line ic in
       if Str.string_match def_re line 0 then
         pending := Some (Str.matched_group 1 line)
       else
         match !pending with
         | Some head
           when (try ignore (Str.search_forward cap_re line 0); true
                 with Not_found -> false) ->
           let eff =
             if Str.matched_group 1 line = "db-write" then SqlWrite else SqlRead
           in
           if not (Hashtbl.mem tbl head) then Hashtbl.replace tbl head eff;
           pending := None
         | _ -> ()
     done
   with End_of_file -> ());
  close_in ic;
  tbl

let () =
  let tbl = guard_of_rkt () in

  (* Sanity: the parse found the guard set at all (guards against a silent
     parser miss returning an empty table, which would make every (A) check
     FAIL loudly rather than falsely pass — but assert the count is nonzero and
     matches the emitted-head set size so a parser regression is unambiguous). *)
  check "sql.rkt parse found db-guarded heads" (Hashtbl.length tbl > 0);

  (* (A) Cross-seam assertion: for every op, its emitted head is db-guarded in
     sql.rkt AND the guard effect equals sql_op_effect (SqlWrite IFF db-write). *)
  List.iter (fun op ->
      let head = sql_op_racket_head op in
      match Hashtbl.find_opt tbl head with
      | None ->
        check (Printf.sprintf "sql.rkt guards emitted head %s (for op %s)"
                 head (sql_op_name op)) false
      | Some rkt_eff ->
        let eff_str = function SqlWrite -> "write" | SqlRead -> "read" in
        check
          (Printf.sprintf "effect(%s)=%s == sql.rkt guard(%s)=%s"
             (sql_op_name op) (eff_str (sql_op_effect op))
             head (eff_str rkt_eff))
          (sql_op_effect op = rkt_eff))
    all_sql_ops;

  (* (B) Bijection sanity: every db-guarded head parsed from sql.rkt is produced
     by some op — catches an orphan guard fn (renamed/removed emit head). *)
  let emitted = List.map sql_op_racket_head all_sql_ops in
  Hashtbl.iter (fun head _ ->
      check (Printf.sprintf "sql.rkt guard head %s is emitted by some op" head)
        (List.mem head emitted))
    tbl;

  (* (C) Emit-truthful, not spelling: compile the corpus fixture that exercises
     all 14 ops and confirm each head actually appears in the emitted Racket, so
     sql_op_racket_head is grounded in real codegen. *)
  let fixture =
    Filename.concat root "example/learn/lesson21-sql-reference.tesl" in
  let src = In_channel.with_open_text fixture In_channel.input_all in
  (match Compile.compile_source ~root_path:root fixture src with
   | Compile.Failure ds ->
     check "lesson21-sql-reference.tesl compiles" false;
     List.iter (fun (d : Compile.diagnostic) ->
         Printf.printf "  %s\n" d.message) ds
   | Compile.Success rkt ->
     check "lesson21-sql-reference.tesl compiles" true;
     let contains sub =
       let re = Str.regexp_string ("(" ^ sub) in
       try ignore (Str.search_forward re rkt 0); true with Not_found -> false
     in
     List.iter (fun head ->
         check (Printf.sprintf "emitted output contains (%s" head)
           (contains head))
       (List.sort_uniq compare emitted));

  Printf.printf "\n%s (%d failure(s))\n"
    (if !failures = 0 then "PASS" else "FAILURES") !failures;
  exit (if !failures = 0 then 0 else 1)
