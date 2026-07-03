(** Regression tests for the soundness holes closed after the 2026-07 FRESH
    formal review (see TESL-REVIEW-TECHNICAL.md).  Each NEGATIVE case was wrongly
    ACCEPTED before the fix and must now be REJECTED; each POSITIVE case is the
    closest legitimate program that must keep compiling.

    Holes closed:
      77.1  FromDb provenance forgery — a discarded `select`/`update` unlocked
            minting `FromDb` on a fabricated record (decide-by-presence gate).
            Fixed by a dataflow check: the RETURNED value must flow from the DB
            site (Validation_common.return_value_flows_from_db_site).
      77.2  Existential laundering — `case scrut of Ctor v -> exists w => v`
            minted an arbitrary proof (incl. FromDb) on unvalidated data via the
            "unseen binder → accept" fail-open.  Fixed by threading case-arm
            binders and deciding by the scrutinee's provenance.
      77.3  Auth clause silently dropped — an api-block `auth …` missing its
            `via <fn>` was dropped by the parser with zero diagnostics, making a
            protected endpoint public.  Fixed to fail the parse closed.
      77.4  Capability laundering by spelling — naming a higher-order param's
            cap-row after a concrete capability (e.g. `time`) stripped it from
            propagation + the emitted runtime grant.  Fixed: a concrete built-in
            capability is never a row variable. *)

open Alcotest

let tesl =
  match Sys.getenv_opt "TESL_BIN" with
  | Some v -> v
  | None ->
    let dir = Filename.dirname Sys.argv.(0) in
    let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
    let candidate2 = Filename.concat dir "../bin/main.exe" in
    if Sys.file_exists candidate then candidate
    else if Sys.file_exists candidate2 then candidate2
    else "tesl"

let check_subcmd =
  if Filename.basename tesl = "main.exe" then "--check" else "check"

let compile_string src =
  let tmp = Filename.temp_file "tesl-r77" ".tesl" in
  let oc = open_out tmp in output_string oc src; close_out oc;
  let cmd = Printf.sprintf "%s %s %s 2>&1" tesl check_subcmd tmp in
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let _ = Unix.close_process_in ic in
  (try Sys.remove tmp with _ -> ());
  out

let has_error out =
  try ignore (Str.search_forward (Str.regexp "error\\[") out 0); true
  with Not_found -> false

let should_pass name src =
  let out = compile_string src in
  if has_error out then Printf.eprintf "[%s] unexpected error:\n%s\n" name out;
  check bool name false (has_error out)

let should_fail name pattern src =
  let out = compile_string src in
  let matched =
    try ignore (Str.search_forward (Str.regexp_case_fold pattern) out 0); true
    with Not_found -> false
  in
  if not matched then Printf.eprintf "[%s] expected /%s/, got:\n%s\n" name pattern out;
  check bool name true (matched && has_error out)

(* ── 77.1  FromDb provenance forgery via a discarded DB site ─────────────── *)

let entity_hdr m =
  Printf.sprintf
    "#lang tesl\nmodule %s exposing []\n\
     import Tesl.Prelude exposing [String, Bool(..)]\n\
     import Tesl.Maybe exposing [Maybe(..)]\n\
     import Tesl.DB exposing [dbRead, dbWrite]\n\
     entity Task table \"tasks\" primaryKey id { id: String  title: String  status: String }\n" m

let r771_discarded_select_forge () =
  should_fail "77.1 discarded-select FromDb forge" "named pack claiming"
    (entity_hdr "R77a" ^ {|
fn forge(id: String, attacker: String) -> Task ? FromDb (Id == id)
  requires [dbRead] =
  let _r = selectOne t from Task where t.id == id
  Task { id: id, title: attacker, status: "pwned" }
|})

let r771_write_discard_forge () =
  should_fail "77.1 discarded-write FromDb forge" "named pack claiming"
    (entity_hdr "R77b" ^ {|
fn forge(id: String, attacker: String) -> Task ? FromDb (Id == id)
  requires [dbWrite] =
  let _r = update t in Task where t.id == id set t.title = attacker returning one
  Task { id: id, title: attacker, status: "pwned" }
|})

let r771_legit_select_return () =
  should_pass "77.1 legit select return"
    (entity_hdr "R77c" ^ {|
fn fetch(id: String) -> Task ? FromDb (Id == id) requires [dbRead] =
  let existing = selectOne t from Task where t.id == id
  case existing of
    Nothing -> fail 404 "not found"
    Something t -> t
|})

let r771_legit_update_returning () =
  should_pass "77.1 legit update returning one"
    (entity_hdr "R77d" ^ {|
fn setTitle(id: String, newTitle: String) -> Task ? FromDb (Id == id)
  requires [dbRead, dbWrite] =
  updateAndReturnOne t in Task
    where t.id == id
    set t.title = newTitle
|})

(* ── 77.2  Existential laundering through a case-arm binder ──────────────── *)

let exists_hdr m =
  Printf.sprintf
    "#lang tesl\nmodule %s exposing []\n\
     import Tesl.Prelude exposing [String, Fact]\n\
     import Tesl.Maybe exposing [Maybe(..)]\n\
     import Tesl.DB exposing [dbRead, dbWrite]\n\
     entity Widget table \"widgets\" primaryKey id { id: String  name: String }\n" m

let r772_case_arm_launder () =
  should_fail "77.2 case-arm existential launder" "unwrapped from a value"
    (exists_hdr "R77e" ^ {|
type Wrap
  = W Widget
fn forge(rawId: String, rawName: String)
  -> exists w: String => Widget ? FromDb (Id == w) requires [] =
  case W (Widget { id: rawId, name: rawName }) of
    W wid -> exists w => wid
|})

let r772_legit_case_select () =
  should_pass "77.2 legit case-over-select existential"
    (exists_hdr "R77f" ^ {|
fn fetch(id: String) -> exists w: String => Widget ? FromDb (Id == w) requires [dbRead] =
  case selectOne x from Widget where x.id == id of
    Nothing -> fail 404 "no"
    Something wgt -> exists w => wgt
|})

(* A let-ESTABLISHED existential (the idiomatic form, cf. lesson19) must keep
   compiling: the packed value is a let binder whose value carries the proof. *)
let r772_legit_let_established () =
  should_pass "77.2 legit let-established existential"
    (exists_hdr "R77g" ^ {|
fn insertWidget(rawName: String) -> exists w: String => Widget ? FromDb (Id == w)
  requires [dbRead, dbWrite] =
  let created = insert Widget { id: rawName, name: rawName }
  exists created =>
    created
|})

(* ── 77.3  Auth clause silently dropped by the parser ───────────────────── *)

let auth_hdr m =
  Printf.sprintf
    "#lang tesl\nmodule %s exposing []\n\
     import Tesl.Prelude exposing [Bool(..), Fact, String]\n\
     import Tesl.Http exposing [HttpRequest]\n\
     import Tesl.Maybe exposing [Maybe(..)]\n\
     import Tesl.Dict exposing [Dict.lookup]\n\
     capability readCookie\n\
     record User { id: String }\n\
     fact Authenticated (req: User)\n\
     auth cookieAuth(request: HttpRequest) -> requestUser: User ::: Authenticated requestUser\n\
     \  requires [readCookie] =\n\
     \  case Dict.lookup \"user\" request.cookies of\n\
     \    Something userId -> ok (User { id: userId }) ::: Authenticated requestUser\n\
     \    Nothing -> fail 401 \"no cookie\"\n\
     handler getSecret() -> String = \"top-secret\"\n" m

let r773_auth_missing_via () =
  should_fail "77.3 auth clause missing via" "auth clause requires"
    (auth_hdr "R77h" ^ {|
api Api {
  get "/secret"
    auth requestUser: User ::: Authenticated requestUser
    -> String
}
|})

(* ── 77.4  Capability laundering by name collision ──────────────────────── *)

let r774_cap_spelling_launder () =
  should_fail "77.4 capability launder-by-spelling"
    "privileged operations and callees requiring"
    ({|#lang tesl
module R77i exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Time exposing [nowMillis, PosixMillis, time]
fn double(x: Int) -> Int = x + x
fn runIt(f: (Int -> Int requires time), x: Int) -> PosixMillis requires [time] =
  nowMillis()
fn caller() -> PosixMillis requires [] =
  runIt double 5
|})

let r774_legit_polymorphic_row () =
  should_pass "77.4 legit polymorphic cap-row variable"
    ({|#lang tesl
module R77j exposing []
import Tesl.Prelude exposing [Int]
fn applyIt(f: (Int -> Int requires c), x: Int) -> Int requires c =
  f x
|})

let () =
  run "Review77-SoundnessFixes"
    [ ("77.1 FromDb provenance dataflow",
       [ test_case "discarded select forge → reject" `Quick r771_discarded_select_forge;
         test_case "discarded write forge → reject" `Quick r771_write_discard_forge;
         test_case "legit select return → accept" `Quick r771_legit_select_return;
         test_case "legit update returning → accept" `Quick r771_legit_update_returning ]);
      ("77.2 existential case-arm laundering",
       [ test_case "case-arm launder → reject" `Quick r772_case_arm_launder;
         test_case "legit case-over-select → accept" `Quick r772_legit_case_select;
         test_case "legit let-established → accept" `Quick r772_legit_let_established ]);
      ("77.3 auth clause drop",
       [ test_case "missing via → parse error" `Quick r773_auth_missing_via ]);
      ("77.4 capability spelling launder",
       [ test_case "concrete cap as row var → reject" `Quick r774_cap_spelling_launder;
         test_case "generic row var → accept" `Quick r774_legit_polymorphic_row ]) ]
