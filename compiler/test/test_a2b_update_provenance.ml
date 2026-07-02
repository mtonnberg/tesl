(** A2b — SQL FromDb provenance of row-returning WRITES (review §3.2 write variant).

    {!Validation_capabilities.check_pk_match} unifies a declared
    `FromDb (col == subj)` against the WHERE of the SQL that PRODUCES the returned
    value.  A2 closed this for `select`/`selectOne` (and the OR-broaden /
    sibling-mask cases).  It did NOT verify a row-producing WRITE —
    `update … where … set … returning one`, `updateAndReturnOne … where … set …`,
    or `deleteAndReturnResult … where …` — because a multi-line write's WHERE is
    lowered by the parser to a SIBLING `let _ = <where …>` statement, so it never
    reaches a select-head spine and no unification ran.  A read-only-looking
    handler could therefore write to (and "prove ownership of") rows it does not
    own: a forged write provenance (BOLA-write).

    This suite pins the write-variant fix:

    NEGATIVES (rejected)
      - wrong-column returning-update  (`update … returning one`)
      - wrong-column updateAndReturnOne
      - where-LESS returning-update / where-less updateAndReturnOne
      - `||` (disjunction) in a returning-update / updateAndReturnOne WHERE
      - wrong-SUBJECT (right column, wrong rhs variable)
      - guard-select-matches-but-returned-update-wrong (write sibling mask)
      - mixed-path: a matching SELECT on one branch must not launder a
        wrong-column WRITE on another (the write path is checked independently)
      - deleteAndReturnResult wrong-column / where-less / `||`

    POSITIVES (compile)
      - correct-column `update … returning one`
      - correct-column updateAndReturnOne
      - correct-column deleteAndReturnResult
      - compound WHERE where the pk conjunct is present (pk not first)
      - a select-derived FromDb still verifies (no regression)
      - a DEAD wrong-column write sibling that is never returned (no over-reject)

    (Read variant + OR-broaden + read sibling-mask are pinned by
    test_a2_sql_provenance.ml; the select/insert unification by
    test_fromdb_where_unification.ml.) *)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    (match Sys.getenv_opt "TESL_BIN" with
     | Some v when Filename.basename v = "main.exe" && Sys.file_exists v -> v
     | _ ->
       let dir = Filename.dirname Sys.argv.(0) in
       let c1 = Filename.concat (Filename.dirname dir) "bin/main.exe" in
       let c2 = Filename.concat dir "../bin/main.exe" in
       if Sys.file_exists c1 then c1 else if Sys.file_exists c2 then c2 else "tesl")

let run_cc args =
  let q = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " q ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let st = Unix.close_process_in ic in
  let code = match st with Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128+n in
  (code, out)

let failf fmt = Printf.ksprintf failwith fmt

(* file name must match the `module X` header (kebab-cased) so the module-vs-file
   check never fires and masks the FromDb/WHERE diagnostic under test. *)
let with_src src f =
  let dir = Filename.temp_dir "tesl-a2b" "" in
  let re = Str.regexp "module[ \t]+\\([A-Z][A-Za-z0-9_]*\\)" in
  ignore (Str.search_forward re src 0);
  let m = Str.matched_group 1 src in
  let buf = Buffer.create 16 in
  String.iteri (fun i c ->
    if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
    else if c >= 'A' && c <= 'Z' then (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
    else Buffer.add_char buf c) m;
  let path = Filename.concat dir (Buffer.contents buf ^ ".tesl") in
  let oc = open_out path in output_string oc src; close_out oc;
  Fun.protect ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_fail ?(pat="") label src =
  with_src src (fun p ->
    let code, out = run_cc ["--check"; p] in
    if code = 0 then failf "%s: expected rejection but COMPILED:\n%s" label src;
    if pat <> "" then
      (try ignore (Str.search_forward (Str.regexp_case_fold pat) out 0)
       with Not_found -> failf "%s: rejected but message !~ %S:\n%s" label pat out))

let should_pass label src =
  with_src src (fun p ->
    let code, out = run_cc ["--check"; p] in
    if code <> 0 then failf "%s: expected COMPILE but failed:\n%s" label out)

(* Header: `dbRead`/`dbWrite` so the write's capability requirement is satisfied
   and only the FromDb-WHERE diagnostic can fire. *)
let hdr name = Printf.sprintf {|#lang tesl
module %s exposing []
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.DB exposing [dbRead, dbWrite, DeleteResult(..)]
import Tesl.Maybe exposing [Maybe(..)]
entity Todo table "todos" primaryKey id {
  id: String
  ownerId: String
  status: String
}
|} name

(* messages emitted by the write path *)
let col_pat = "returning write constrains column"
let subj_pat = "does not match\\|WHERE clause uses"
let nowhere_pat = "does not constrain\\|not established by any WHERE"
let or_pat = "disjunction\\|`||`\\|broaden"

(* ── NEGATIVES ────────────────────────────────────────────────────────────── *)

(* wrong-column `update … returning one` — the shipped completeTodo BOLA-write *)
let neg_update_wrong_col = hdr "UpdWrongCol" ^ {|
fn complete(id: String, owner: String) -> Todo ? FromDb (Id == id)
  requires [dbRead, dbWrite] =
  update t in Todo
    where t.ownerId == owner
    set t.status = "done"
    returning one
|}

(* wrong-column updateAndReturnOne *)
let neg_uaro_wrong_col = hdr "UaroWrongCol" ^ {|
fn complete(id: String, owner: String) -> Todo ? FromDb (Id == id)
  requires [dbRead, dbWrite] =
  updateAndReturnOne t in Todo
    where t.ownerId == owner
    set t.status = "done"
|}

(* where-LESS `update … returning one` *)
let neg_update_no_where = hdr "UpdNoWhere" ^ {|
fn complete(id: String) -> Todo ? FromDb (Id == id)
  requires [dbRead, dbWrite] =
  update t in Todo
    set t.status = "done"
    returning one
|}

(* where-LESS updateAndReturnOne *)
let neg_uaro_no_where = hdr "UaroNoWhere" ^ {|
fn complete(id: String) -> Todo ? FromDb (Id == id)
  requires [dbRead, dbWrite] =
  updateAndReturnOne t in Todo
    set t.status = "done"
|}

(* `||` in a returning-update WHERE — a disjunction broadens the rows written *)
let neg_update_or = hdr "UpdOr" ^ {|
fn complete(id: String, other: String) -> Todo ? FromDb (Id == id)
  requires [dbRead, dbWrite] =
  update t in Todo
    where t.id == id || t.id == other
    set t.status = "done"
    returning one
|}

(* `||` in an updateAndReturnOne WHERE *)
let neg_uaro_or = hdr "UaroOr" ^ {|
fn complete(id: String, other: String) -> Todo ? FromDb (Id == id)
  requires [dbRead, dbWrite] =
  updateAndReturnOne t in Todo
    where t.id == id || t.ownerId == other
    set t.status = "done"
|}

(* right column, WRONG subject variable *)
let neg_update_wrong_subj = hdr "UpdWrongSubj" ^ {|
fn complete(id: String, other: String) -> Todo ? FromDb (Id == id)
  requires [dbRead, dbWrite] =
  updateAndReturnOne t in Todo
    where t.id == other
    set t.status = "done"
|}

(* guard select matches `id == id`, but the RETURNED update filters the wrong
   column — the matching guard must NOT launder the returned write. *)
let neg_guard_masks_update = hdr "GuardMask" ^ {|
fn complete(id: String, owner: String) -> Todo ? FromDb (Id == id)
  requires [dbRead, dbWrite] =
  let guard = selectOne t from Todo where t.id == id
  case guard of
    Nothing -> fail 404 "nf"
    Something _ ->
      updateAndReturnOne t in Todo
        where t.ownerId == owner
        set t.status = "done"
|}

(* mixed path: one branch returns a matching SELECT, the other a wrong-column
   WRITE.  The write must be rejected independently of the select's match. *)
let neg_mixed_path = hdr "MixedPath" ^ {|
fn get(id: String, owner: String, flag: Bool) -> Todo ? FromDb (Id == id)
  requires [dbRead, dbWrite] =
  if flag then
    let r = selectOne t from Todo where t.id == id
    case r of
      Nothing -> fail 404 "nf"
      Something t -> t
  else
    updateAndReturnOne t in Todo
      where t.ownerId == owner
      set t.status = "done"
|}

(* deleteAndReturnResult wrong-column (single-line, WHERE fused into the spine) *)
let neg_delete_wrong_col = hdr "DelWrongCol" ^ {|
fn del(id: String, owner: String) -> DeleteResult ? FromDb (Id == id)
  requires [dbRead, dbWrite] =
  deleteAndReturnResult t from Todo where t.ownerId == owner
|}

(* where-less deleteAndReturnResult *)
let neg_delete_no_where = hdr "DelNoWhere" ^ {|
fn del(id: String) -> DeleteResult ? FromDb (Id == id)
  requires [dbRead, dbWrite] =
  deleteAndReturnResult t from Todo
|}

(* `||` in a deleteAndReturnResult WHERE *)
let neg_delete_or = hdr "DelOr" ^ {|
fn del(id: String, owner: String) -> DeleteResult ? FromDb (Id == id)
  requires [dbRead, dbWrite] =
  deleteAndReturnResult t from Todo where t.id == id || t.ownerId == owner
|}

(* ── POSITIVES ────────────────────────────────────────────────────────────── *)

(* correct-column `update … returning one` (the shipped completeTodo shape) *)
let pos_update = hdr "PosUpd" ^ {|
fn complete(id: String) -> Todo ? FromDb (Id == id)
  requires [dbRead, dbWrite] =
  update t in Todo
    where t.id == id
    set t.status = "done"
    returning one
|}

(* correct-column updateAndReturnOne *)
let pos_uaro = hdr "PosUaro" ^ {|
fn complete(id: String, n: String) -> Todo ? FromDb (Id == id)
  requires [dbRead, dbWrite] =
  updateAndReturnOne t in Todo
    where t.id == id
    set t.status = n
|}

(* correct-column deleteAndReturnResult *)
let pos_delete = hdr "PosDel" ^ {|
fn del(id: String) -> DeleteResult ? FromDb (Id == id)
  requires [dbRead, dbWrite] =
  deleteAndReturnResult t from Todo where t.id == id
|}

(* compound WHERE, pk conjunct present but NOT first — must still find it *)
let pos_compound = hdr "PosCompound" ^ {|
fn complete(id: String, owner: String) -> Todo ? FromDb (Id == id)
  requires [dbRead, dbWrite] =
  updateAndReturnOne t in Todo
    where t.ownerId == owner && t.id == id
    set t.status = "done"
|}

(* a select-derived FromDb still verifies (no regression from the write walk) *)
let pos_select = hdr "PosSelect" ^ {|
fn get(id: String) -> Todo ? FromDb (Id == id)
  requires [dbRead] =
  let r = selectOne t from Todo where t.id == id
  case r of
    Nothing -> fail 404 "nf"
    Something t -> t
|}

(* a DEAD wrong-column write sibling that is never returned must NOT be flagged
   (the correct write is the one that flows to the result). *)
let pos_dead_sibling = hdr "PosDeadSibling" ^ {|
fn complete(id: String, owner: String) -> Todo ? FromDb (Id == id)
  requires [dbRead, dbWrite] =
  let bad = updateAndReturnOne t in Todo where t.ownerId == owner set t.status = "x"
  updateAndReturnOne t in Todo
    where t.id == id
    set t.status = "done"
|}

let () =
  run "A2b-Update-Returning-Provenance" [
    "negatives — update / updateAndReturnOne", [
      test_case "wrong-column update…returning one" `Quick
        (fun () -> should_fail ~pat:col_pat "update-wrong-col" neg_update_wrong_col);
      test_case "wrong-column updateAndReturnOne" `Quick
        (fun () -> should_fail ~pat:col_pat "uaro-wrong-col" neg_uaro_wrong_col);
      test_case "where-less update…returning one" `Quick
        (fun () -> should_fail ~pat:nowhere_pat "update-no-where" neg_update_no_where);
      test_case "where-less updateAndReturnOne" `Quick
        (fun () -> should_fail ~pat:nowhere_pat "uaro-no-where" neg_uaro_no_where);
      test_case "OR in update…returning one WHERE" `Quick
        (fun () -> should_fail ~pat:or_pat "update-or" neg_update_or);
      test_case "OR in updateAndReturnOne WHERE" `Quick
        (fun () -> should_fail ~pat:or_pat "uaro-or" neg_uaro_or);
      test_case "wrong-subject updateAndReturnOne" `Quick
        (fun () -> should_fail ~pat:subj_pat "update-wrong-subj" neg_update_wrong_subj);
    ];
    "negatives — sibling / mixed path", [
      test_case "guard select matches but returned update wrong-column" `Quick
        (fun () -> should_fail ~pat:col_pat "guard-mask" neg_guard_masks_update);
      test_case "matching select branch cannot launder wrong write branch" `Quick
        (fun () -> should_fail ~pat:col_pat "mixed-path" neg_mixed_path);
    ];
    "negatives — deleteAndReturnResult", [
      test_case "wrong-column deleteAndReturnResult" `Quick
        (fun () -> should_fail ~pat:col_pat "delete-wrong-col" neg_delete_wrong_col);
      test_case "where-less deleteAndReturnResult" `Quick
        (fun () -> should_fail ~pat:nowhere_pat "delete-no-where" neg_delete_no_where);
      test_case "OR in deleteAndReturnResult WHERE" `Quick
        (fun () -> should_fail ~pat:or_pat "delete-or" neg_delete_or);
    ];
    "positives (no false rejection)", [
      test_case "correct-column update…returning one" `Quick
        (fun () -> should_pass "update-ok" pos_update);
      test_case "correct-column updateAndReturnOne" `Quick
        (fun () -> should_pass "uaro-ok" pos_uaro);
      test_case "correct-column deleteAndReturnResult" `Quick
        (fun () -> should_pass "delete-ok" pos_delete);
      test_case "compound WHERE with pk conjunct (not first)" `Quick
        (fun () -> should_pass "compound-ok" pos_compound);
      test_case "select-derived FromDb still verifies" `Quick
        (fun () -> should_pass "select-ok" pos_select);
      test_case "dead wrong-column write sibling not returned" `Quick
        (fun () -> should_pass "dead-sibling-ok" pos_dead_sibling);
    ];
  ]
