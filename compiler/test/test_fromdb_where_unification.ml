(** A1 soundness regression: SQL FromDb proof unified against the resolved WHERE.

    A `select`/`selectOne` grants a `FromDb (Col == subject)` proof, but the
    validation layer historically checked only the RHS *subject* spelling — never
    the COLUMN — and never required a WHERE at all.  So `-> Todo ? FromDb (Id ==
    todoId)` compiled even when the body filtered by `ownerId` (wrong column), and
    `-> List Todo ? ForAll (FromDb (OwnerId == owner))` compiled with a body that
    `select`ed EVERY row (no WHERE) — a BOLA (broken object-level authorization):
    every user gets every row, with a proof that falsely claims each is theirs.

    {!Validation_capabilities.check_pk_match} now unifies the declared FromDb
    (column, subject) against the resolved WHERE equality:
      - the COLUMN is resolved through the single {!Ir.entity_field_fact_name}
        field→column mapping (honoring an explicit `first_field_fact`);
      - ALL `&&` conjuncts of a compound WHERE are searched;
      - `PredAnd` is descended for the FromDb conjunct in a ForAll grant;
      - a field-access RHS (`requestUser.id`) is compared by full dotted string;
      - a select-derived grant with NO matching WHERE is REJECTED.

    The must-have-a-matching-WHERE requirement is scoped to select/selectOne
    heads: insert- and update-returning-derived FromDb grants (no select WHERE
    for the pk) stay valid.

    Negatives — HOLE-A (column mismatch), HOLE-B (ForAll no WHERE), HOLE-C (ForAll
    wrong column).  Positives / cross-seam — field-access RHS, insert grant,
    update-returning grant, compound WHERE with the pk conjunct present. *)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    (match Sys.getenv_opt "TESL_BIN" with
     | Some v when Filename.basename v = "main.exe" && Sys.file_exists v -> v
     | _ ->
       let dir = Filename.dirname Sys.argv.(0) in
       let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
       let candidate2 = Filename.concat dir "../bin/main.exe" in
       if Sys.file_exists candidate then candidate
       else if Sys.file_exists candidate2 then candidate2
       else "tesl")

let run_command cmd =
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  let code = match status with
    | Unix.WEXITED c -> c
    | Unix.WSIGNALED n -> 128 + n
    | Unix.WSTOPPED n -> 128 + n
  in
  (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

(* Write [content] to a temp file whose name is derived from the `module` header
   (kebab-case), so the module-header-vs-filename check never fires and masks the
   FromDb/WHERE diagnostics we are actually asserting. *)
let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-a1fromdb" "" in
  let name =
    let re = Str.regexp "module[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 1 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then begin
          Buffer.add_char buf '-';
          Buffer.add_char buf (Char.lowercase_ascii c)
        end else
          Buffer.add_char buf c
      ) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_fail pattern src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

(* Shared header: entities + subject facts.  User (for Authenticated) and Todo. *)
let header modname = Printf.sprintf {|#lang tesl
module %s exposing []

import Tesl.Prelude exposing [String, List]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Random exposing [random]
import Tesl.Id exposing [generatePrefixedId]

fact TodoId (id: String)
check checkTodoId(id: String) -> id: String ::: TodoId id = ok id ::: TodoId id

fact Authenticated (u: User)

entity Todo table "todos" primaryKey id {
  id: String
  ownerId: String @db(text)
  title: String
}

entity User table "users" primaryKey id {
  id: String
  name: String
}
|} modname

(* ── HOLE-A — named-pack COLUMN mismatch (right var, wrong column) ────────── *)

let test_holeA_named_pack_column_mismatch () =
  (* `-> Todo ? FromDb (Id == todoId)` but the body selects by `ownerId`. The
     RHS variable (`todoId`) matches; only the COLUMN is forged. Must reject. *)
  should_fail "Id.*ownerId\\|ownerId.*Id\\|OwnerId.*Id\\|Id.*OwnerId\\|not established"
    (header "HoleA" ^ {|
fn getTodo(todoId: String ::: TodoId todoId) -> Todo ? FromDb (Id == todoId)
  requires [dbRead] =
  let e = selectOne t from Todo where t.ownerId == todoId
  case e of
    Nothing -> fail 404 "x"
    Something t -> t
|})

(* ── HOLE-B — ForAll grant with NO WHERE at all ──────────────────────────── *)

let test_holeB_forall_no_where () =
  (* `-> List Todo ? ForAll (FromDb (OwnerId == owner))` but the body returns
     EVERY row (`select t from Todo`, no WHERE). Must reject: the per-row
     provenance is not established by any WHERE clause. *)
  should_fail "not established by any WHERE\\|does not constrain"
    (header "HoleB" ^ {|
fn listAll(owner: String) -> List Todo ? ForAll (FromDb (OwnerId == owner))
  requires [dbRead] =
  select t from Todo
|})

(* ── HOLE-C — ForAll grant with the WRONG column ─────────────────────────── *)

let test_holeC_forall_wrong_column () =
  (* `-> List Todo ? ForAll (FromDb (OwnerId == owner))` but the body filters by
     `id`, not `ownerId`. Column forged. Must reject. *)
  should_fail "OwnerId\\|not established\\|does not constrain"
    (header "HoleC" ^ {|
fn listByWrong(owner: String) -> List Todo ? ForAll (FromDb (OwnerId == owner))
  requires [dbRead] =
  select t from Todo where t.id == owner
|})

(* ── POSITIVE — field-access RHS still compiles (todo-api listMyTodos) ────── *)

let test_pos_field_access_rhs () =
  (* `ForAll (FromDb (OwnerId == requestUser.id))` with `where t.ownerId ==
     requestUser.id` matches on BOTH column (OwnerId) and dotted subject. Must
     stay green — this pattern was previously UNCHECKED and must not regress into
     a false rejection now that field-access subjects are unified. *)
  should_pass (header "PosFieldAccess" ^ {|
fn listMine(requestUser: User ::: Authenticated requestUser)
  -> List Todo ? ForAll (FromDb (OwnerId == requestUser.id))
  requires [dbRead] =
  select t from Todo where t.ownerId == requestUser.id
|})

(* ── CROSS-SEAM — insert-derived FromDb grant stays valid (no select WHERE) ─ *)

let test_pos_insert_grant () =
  (* An existential insert grant carries `FromDb (Id == tid)` with no select
     WHERE — owned by check_insert_pk_match, exempt from the must-have-WHERE
     requirement which is scoped to select-derived grants. *)
  should_pass (header "PosInsert" ^ {|
fn create(title: String) -> exists tid: String => Todo ? FromDb (Id == tid)
  requires [dbWrite, random] =
  let tid = generatePrefixedId "todo"
  exists tid =>
    insert Todo { id: tid, ownerId: "me", title: title }
|})

(* ── CROSS-SEAM — update-returning-one FromDb grant stays valid ───────────── *)

let test_pos_update_returning_grant () =
  (* `updateAndReturnOne ... where t.id == id` returns `FromDb (Id == id)` with no
     `select` head, so the must-have-WHERE requirement (scoped to select heads)
     does not fire. Must stay green. *)
  should_pass (header "PosUpdate" ^ {|
fn rename(id: String, newTitle: String) -> Todo ? FromDb (Id == id)
  requires [dbRead, dbWrite] =
  updateAndReturnOne t in Todo
    where t.id == id
    set t.title = newTitle
|})

(* ── POSITIVE — compound WHERE with the pk conjunct present ───────────────── *)

let test_pos_compound_where_pk_conjunct () =
  (* `-> Todo ? FromDb (Id == id)` with `where t.id == id && t.ownerId == owner`.
     The pk (column+subject) match is found among the AND conjuncts. Must stay
     green (guards over-rejection when the pk is one conjunct among many). *)
  should_pass (header "PosCompound" ^ {|
fn get2(id: String, owner: String) -> Todo ? FromDb (Id == id)
  requires [dbRead] =
  let e = selectOne t from Todo where t.id == id && t.ownerId == owner
  case e of
    Nothing -> fail 404 "x"
    Something t -> t
|})

(* ── POSITIVE — compound WHERE where the pk is NOT the first conjunct ─────── *)

let test_pos_compound_where_pk_not_first () =
  (* Same as above but with the conjuncts swapped so the select head sits on the
     `ownerId` conjunct and the pk `id == id` is a LATER conjunct — the search
     must still find it (the entity binder is only on the first conjunct). *)
  should_pass (header "PosCompound2" ^ {|
fn get3(id: String, owner: String) -> Todo ? FromDb (Id == id)
  requires [dbRead] =
  let e = selectOne t from Todo where t.ownerId == owner && t.id == id
  case e of
    Nothing -> fail 404 "x"
    Something t -> t
|})

let () =
  run "A1-FromDb-WHERE-unification" [
    "negatives", [
      test_case "HOLE-A named-pack column mismatch rejected" `Quick test_holeA_named_pack_column_mismatch;
      test_case "HOLE-B ForAll no-WHERE rejected" `Quick test_holeB_forall_no_where;
      test_case "HOLE-C ForAll wrong-column rejected" `Quick test_holeC_forall_wrong_column;
    ];
    "positives", [
      test_case "field-access RHS compiles" `Quick test_pos_field_access_rhs;
      test_case "insert grant compiles" `Quick test_pos_insert_grant;
      test_case "update-returning grant compiles" `Quick test_pos_update_returning_grant;
      test_case "compound WHERE (pk first) compiles" `Quick test_pos_compound_where_pk_conjunct;
      test_case "compound WHERE (pk not first) compiles" `Quick test_pos_compound_where_pk_not_first;
    ];
  ]
