(** A2 — SQL FromDb provenance soundness (external re-review §3).

    re-review §3.1 A1-OR-BROADEN — a disjunction in a provenance WHERE broadens the result
      set beyond the declared subject.  `where col == subj || col == other` was
      credited by matching one disjunct while the `|| …` rode into the emitted SQL
      (a BOLA on the shipped todo-api).  The {AND,EQ} unifier cannot prove a
      disjunction entails `col == subj` for every row, so a top-level OR in the
      provenance WHERE is now fail-closed.  A narrowing OR nested inside an
      AND-conjunct (`col == subj && (a || b)`) is still accepted — it only narrows.

    re-review §3.2 A1-MASK-NODATAFLOW (read variant) — provenance was credited by ANY
      matching WHERE in the body (a function-wide `matched` bool), so an unused
      sibling `let good = select … where <matching>` laundered a returned value
      from a different, wrong-WHERE select.  Provenance is now tied to the select
      whose result flows to the return (backward closure over `let` definitions);
      a dead sibling can no longer credit.

    (The update/delete-`returning` write variant of re-review §3.2 — verifying a write
    chain's WHERE — is tracked separately in
    roadmap/next/sql_update_returning_provenance.md.) *)

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

let with_src src f =
  let dir = Filename.temp_dir "tesl-a2" "" in
  (* file name must match the `module X` header (kebab-cased) *)
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

let hdr name = Printf.sprintf {|#lang tesl
module %s exposing []
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.DB exposing [dbRead]
import Tesl.Maybe exposing [Maybe(..)]
entity Todo table "todos" primaryKey id {
  id: String
  ownerId: String
  status: String
}
|} name

(* ── re-review §3.1 OR-broaden negatives ────────────────────────────────────────────── *)
let or_pat = "disjunction\\|`||`\\|OR.*broaden\\|broadens"

let neg_or_admin = hdr "OrAdmin" ^ {|
fn listMine(me: String, admin: String) -> List Todo ? ForAll (FromDb (OwnerId == me))
  requires [dbRead] =
  select t from Todo where t.ownerId == me || t.ownerId == admin
|}

let neg_or_status = hdr "OrStatus" ^ {|
fn listMine(me: String) -> List Todo ? ForAll (FromDb (OwnerId == me))
  requires [dbRead] =
  select t from Todo where t.ownerId == me || t.status == "open"
|}

(* matching disjunct written SECOND *)
let neg_or_second = hdr "OrSecond" ^ {|
fn listMine(me: String, admin: String) -> List Todo ? ForAll (FromDb (OwnerId == me))
  requires [dbRead] =
  select t from Todo where t.ownerId == admin || t.ownerId == me
|}

(* single-row select with OR *)
let neg_or_single = hdr "OrSingle" ^ {|
fn getOne(id0: String, other: String) -> Todo ? FromDb (Id == id0)
  requires [dbRead] =
  let r = selectOne t from Todo where t.id == id0 || t.id == other
  case r of
    Nothing -> fail 404 "nf"
    Something t -> t
|}

(* ── re-review §3.1 narrowing OR positive (must compile) ───────────────────────────── *)
let pos_narrowing_or = hdr "NarrowOr" ^ {|
fn listMine(me: String) -> List Todo ? ForAll (FromDb (OwnerId == me))
  requires [dbRead] =
  select t from Todo where t.ownerId == me && (t.status == "open" || t.status == "done")
|}

(* ── re-review §3.2 sibling-mask (read) negatives ──────────────────────────────────── *)
let neg_mask_unused = hdr "MaskUnused" ^ {|
fn getThing(id0: String, other: String) -> Todo ? FromDb (Id == id0)
  requires [dbRead] =
  let good = selectOne t from Todo where t.id == id0
  let bad = selectOne t from Todo where t.ownerId == other
  case bad of
    Nothing -> fail 404 "nf"
    Something b -> b
|}

(* the matching sibling appears FIRST but the returned value is from the wrong one *)
let neg_mask_reorder = hdr "MaskReorder" ^ {|
fn getThing(id0: String, other: String) -> Todo ? FromDb (Id == id0)
  requires [dbRead] =
  let matching = selectOne t from Todo where t.id == id0
  let wrong = selectOne t from Todo where t.status == other
  case wrong of
    Nothing -> fail 404 "nf"
    Something w -> w
|}

(* ── positives (must compile) ────────────────────────────────────────────── *)
let pos_single_select = hdr "SingleSel" ^ {|
fn getThing(id0: String) -> Todo ? FromDb (Id == id0)
  requires [dbRead] =
  let r = selectOne t from Todo where t.id == id0
  case r of
    Nothing -> fail 404 "nf"
    Something t -> t
|}

let pos_list_forall = hdr "ListForAll" ^ {|
fn listMine(me: String) -> List Todo ? ForAll (FromDb (OwnerId == me))
  requires [dbRead] =
  select t from Todo where t.ownerId == me
|}

(* a legit helper select on a different column that is NOT returned must not
   trigger a false rejection now that provenance is return-flow scoped *)
let pos_helper_sibling = hdr "HelperSibling" ^ {|
fn getThing(id0: String, other: String) -> Todo ? FromDb (Id == id0)
  requires [dbRead] =
  let other0 = selectOne t from Todo where t.ownerId == other
  let r = selectOne t from Todo where t.id == id0
  case r of
    Nothing -> fail 404 "nf"
    Something t -> t
|}

let () =
  run "A2-SQL-Provenance" [
    "re-review §3.1 OR-broaden (negatives)", [
      test_case "ownerId == me || ownerId == admin" `Quick
        (fun () -> should_fail ~pat:or_pat "or-admin" neg_or_admin);
      test_case "ownerId == me || status == open" `Quick
        (fun () -> should_fail ~pat:or_pat "or-status" neg_or_status);
      test_case "matching disjunct written second" `Quick
        (fun () -> should_fail ~pat:or_pat "or-second" neg_or_second);
      test_case "single-row select with OR" `Quick
        (fun () -> should_fail ~pat:or_pat "or-single" neg_or_single);
    ];
    "re-review §3.1 narrowing OR (positive)", [
      test_case "col == subj && (a || b) compiles" `Quick
        (fun () -> should_pass "narrowing-or" pos_narrowing_or);
    ];
    "re-review §3.2 sibling-mask read (negatives)", [
      test_case "unused matching sibling masks wrong return" `Quick
        (fun () -> should_fail "mask-unused" neg_mask_unused);
      test_case "matching-first sibling masks wrong return" `Quick
        (fun () -> should_fail "mask-reorder" neg_mask_reorder);
    ];
    "positives (no false rejection)", [
      test_case "single matching select" `Quick
        (fun () -> should_pass "single-select" pos_single_select);
      test_case "list ForAll matching select" `Quick
        (fun () -> should_pass "list-forall" pos_list_forall);
      test_case "helper sibling not returned still compiles" `Quick
        (fun () -> should_pass "helper-sibling" pos_helper_sibling);
    ];
  ]
