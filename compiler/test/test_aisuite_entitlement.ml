(** AISuite — Entitlement. Agent tools as ordinary proof-carrying functions.

    The thesis of Tesl.Agent is that an LLM tool is just a normal Tesl function:
    its [validateFn]/[dispatchFn] carry the SAME proof obligations any other
    function does, and the SAME static checker enforces them.  An "entitled"
    value — one the model is allowed to mutate or read — must be OBTAINED through
    a scoped query / ownership [check], never fabricated.  These NEGATIVE tests
    prove that an agent tool cannot smuggle an unentitled value past the proof
    system, reusing the existing fact/check/establish + query-proof machinery in
    an agent-tool context.

    Families (all must-NOT-compile, with positive controls that MUST compile):
      OWN   — a mutating tool dispatch fn taking `::: OwnedBy u t` called WITHOUT
              the ownership proof (raw entity straight from tool args).
      CP    — ownership proof obtained for the WRONG user / WRONG entity then
              consumed at the mutating site (cross-parameter subject confusion).
      SCOPE — a data/retrieval tool returning `? ForAll (FromDb (Author == u))`
              whose query is scoped to the WRONG user (or whose WHERE clause
              references the wrong subject); the user-scoping proof is not
              discharged.
      HAND  — hand-constructing an entitled value instead of obtaining it via a
              scoped query: `ok ::: P` inside a `fn` (P001), naming a fact as a
              constructor (T001), or an `establish` whose proof never flows to
              the consumed value (V001).
      CAP   — a tool dispatch fn that reaches for `ask`/`askFor`/`converse`
              without declaring the [aiProvider] entitlement (capability V001).
      POS   — positive companions: the proof obtained correctly compiles.

    Hardening (mirrors the ProofSuite harness): [should_fail] requires a non-zero
    exit AND a case-insensitive regex match AND that the output contains NO
    runtime-leak markers — a static rejection must NOT leak a .rkt / raco trace. *)

open Alcotest

(* ── Compiler-path resolution ────────────────────────────────────────────── *)

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
    | Unix.WEXITED c -> c | Unix.WSIGNALED n -> 128 + n | Unix.WSTOPPED n -> 128 + n
  in (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

(* Derive the on-disk filename from the module header so the compiler's
   "module header does not match file name" diagnostic never confounds the real
   proof error we are probing. *)
let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-aiEnt" "" in
  let name =
    let re = Str.regexp "\\(module\\|library\\)[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 2 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then
          (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
        else Buffer.add_char buf c) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

(* Markers that a rejection escaped to RUNTIME rather than being caught
   statically. *)
let runtime_leak_re =
  Str.regexp_case_fold
    "raise-user-error\\|raise-argument-error\\|application: not a procedure\\|\
     racket/[A-Za-z_./-]*\\.rkt:[0-9]\\|^ *context\\.\\.\\.:\\|contract violation"

let assert_no_runtime_leak ctx out =
  try
    ignore (Str.search_forward runtime_leak_re out 0);
    failf "%s: rejection leaked to RUNTIME (found runtime-net marker), \
           expected a STATIC compile error.\nOutput:\n%s" ctx out
  with Not_found -> ()

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected static failure matching %S, but compiled\nOutput:\n%s" pat out;
    assert_no_runtime_leak "should_fail" out;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let[@warning "-32"] known_gap ~what src =
  with_temp_file src (fun path ->
    let code, _ = run_compiler ["--check"; path] in
    if code <> 0 then
      failf "KNOWN GAP CLOSED — `%s` is now statically rejected; \
             promote this case from known_gap to should_fail." what)

(* ── Shared TESL fragments ───────────────────────────────────────────────── *)

(* Header for the agentic ownership tools.  Imports the agent surface so the
   proof error is probed in a real Tesl.Agent context, not a bare module.  The
   `supportBot` capability satisfies the aiProvider entitlement so the only
   error in scope is the PROOF error we are asserting. *)
let agent_hdr modname = Printf.sprintf
  "#lang tesl\nmodule %s exposing []\n\
   import Tesl.Prelude exposing [Int, String, Bool(..), List, Unit, Fact]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n\
   import Tesl.Json exposing [stringCodec]\n\
   import Tesl.Agent exposing [aiProvider, Agent, LlmProvider, Tool, tool, withTools, \
   defineAgent, mockProvider, ask, askReply, replyText]\n\
   capability supportBot implies aiProvider\n"
  modname

(* The ownership entitlement model: a two-subject OwnedBy fact, a check that is
   the ONLY way to obtain it, a mutating dispatch fn that requires it, and a
   record carrying the tool's validated args. *)
let owned_lib = {|
record Doc { id: String ownerId: String body: String }
fact OwnedBy (u: String) (t: Doc)
check checkOwned(u: String, t: Doc) -> t: Doc ::: OwnedBy u t =
  if t.ownerId == u then
    ok t ::: OwnedBy u t
  else
    fail 403 "not the owner"
record DocArgs { docId: String }
codec DocArgs {
  toJson_forbidden
  fromJson [
    {
      docId <- "docId" with_codec stringCodec
    }
  ]
}
fn applyDelete(u: String, t: Doc ::: OwnedBy u t) -> String = t.id
fn applyRename(u: String, t: Doc ::: OwnedBy u t, name: String) -> String = name
fn applyArchive(u: String, t: Doc ::: OwnedBy u t) -> String = t.body
fn applyShare(u: String, t: Doc ::: OwnedBy u t, withWhom: String) -> String = withWhom
fn applyPublish(u: String, t: Doc ::: OwnedBy u t) -> String = t.id
fn applyTransfer(u: String, t: Doc ::: OwnedBy u t, toUser: String) -> String = toUser
|}

(* DB header for the data-retrieval (ForAll user-scoping) tools. *)
let db_hdr modname = Printf.sprintf
  "#lang tesl\nmodule %s exposing []\n\
   import Tesl.Prelude exposing [Int, String, List, Unit]\n\
   import Tesl.DB exposing [dbRead]\n\
   import Tesl.Agent exposing [aiProvider, Agent, defineAgent, mockProvider, ask]\n\
   capability supportBot implies aiProvider\n\
   entity Note table \"notes\" primaryKey id { id: String authorId: String body: String }\n"
  modname

(* Regexes for each rejection class. *)
let satisfy_re = "does not.*statically.*satisfy\\|different subject\\|not trackable\\|V001"
let scope_re = "WHERE clause uses\\|does not.*statically.*satisfy\\|do not match\\|V001"
let hand_p001_re = "proof construction is not allowed\\|P001"
let hand_ctor_re = "unknown constructor\\|T001"
let cap_re = "aiProvider\\|requires \\[\\|privileged\\|V001"

(* ══════════════════════════════════════════════════════════════════════════
   OWN — a mutating tool dispatch fn requiring `::: OwnedBy u t` is called with
   the raw entity (straight from validated tool args) and NO ownership proof.
   Matrix: mutating operation × the "caller" identity expression used.
   ══════════════════════════════════════════════════════════════════════════ *)

(* Each op: the proof-requiring fn name and the trailing args after the entity. *)
let mutating_ops =
  [ ("applyDelete",   "");
    ("applyArchive",  "");
    ("applyPublish",  "");
    ("applyRename",   " \"new name\"");
    ("applyShare",    " \"bob\"");
    ("applyTransfer", " \"bob\""); ]

(* Each caller-identity: how the dispatch fn names the acting user. *)
let caller_users =
  [ "actor"; "caller"; "u"; "requestUser"; "agentUser"; "sessionUser";
    "principal"; "subject"; "who"; "uid"; "currentUser"; "me" ]

let own_no_proof opidx (opfn, optail) uidx user =
  let m = Printf.sprintf "OwnNp%02d%02d" opidx uidx in
  let test () =
    should_fail satisfy_re
      (agent_hdr m ^ owned_lib ^ Printf.sprintf {|
fn dispatch%s(%s: String, raw: Doc) -> String =
  %s %s raw%s
|} m user opfn user optail)
  in
  (Printf.sprintf "OWN-NP-%02d-%02d %s with raw entity (user=%s)" opidx uidx opfn user,
   test)

let own_no_proof_cases =
  List.concat
    (List.mapi (fun oi op ->
      List.mapi (fun ui u -> own_no_proof (oi + 1) op (ui + 1) u) caller_users)
      mutating_ops)

(* OWN, but the raw entity is hand-built inside the dispatch fn from tool args
   (the model "knows" the doc id but ownership is never verified). *)
let own_built_entity opidx (opfn, optail) =
  let m = Printf.sprintf "OwnBe%02d" opidx in
  let test () =
    should_fail satisfy_re
      (agent_hdr m ^ owned_lib ^ Printf.sprintf {|
fn dispatch%s(args: DocArgs) -> String =
  let raw = Doc { id: args.docId, ownerId: "victim", body: "x" }
  %s "attacker" raw%s
|} m opfn optail)
  in
  (Printf.sprintf "OWN-BE-%02d %s on tool-args-built entity" opidx opfn, test)

let own_built_cases = List.mapi (fun i op -> own_built_entity (i + 1) op) mutating_ops

(* ══════════════════════════════════════════════════════════════════════════
   CP — ownership proof obtained for the WRONG user / WRONG entity, then
   consumed at the mutating site.  Cross-parameter subject confusion in a tool.
   ══════════════════════════════════════════════════════════════════════════ *)

(* checked-for one user, consumed requiring a DIFFERENT user. *)
let cp_wrong_user opidx (opfn, optail) widx wrong =
  let m = Printf.sprintf "CpU%02d%02d" opidx widx in
  let test () =
    should_fail satisfy_re
      (agent_hdr m ^ owned_lib ^ Printf.sprintf {|
fn dispatch%s(owner: String, %s: String, raw: Doc) -> String =
  let t = check checkOwned owner raw
  %s %s t%s
|} m wrong opfn wrong optail)
  in
  (Printf.sprintf "CP-U-%02d-%02d %s checked owner consume %s" opidx widx opfn wrong,
   test)

let cp_wrong_users =
  [ "attacker"; "other"; "victim"; "stranger"; "intruder"; "guest";
    "rival"; "u2"; "alt"; "someoneElse"; "admin2"; "ghost" ]

let cp_wrong_user_cases =
  List.concat
    (List.mapi (fun oi op ->
      List.mapi (fun wi w -> cp_wrong_user (oi + 1) op (wi + 1) w) cp_wrong_users)
      mutating_ops)

(* checked one entity, consumed a DIFFERENT entity (same user). *)
let cp_wrong_entity opidx (opfn, optail) eidx other =
  let m = Printf.sprintf "CpE%02d%02d" opidx eidx in
  let test () =
    should_fail satisfy_re
      (agent_hdr m ^ owned_lib ^ Printf.sprintf {|
fn dispatch%s(owner: String, rawA: Doc, %s: Doc) -> String =
  let t = check checkOwned owner rawA
  %s owner %s%s
|} m other opfn other optail)
  in
  (Printf.sprintf "CP-E-%02d-%02d %s checked rawA consume %s" opidx eidx opfn other,
   test)

let cp_wrong_entities =
  [ "rawB"; "otherDoc"; "decoy"; "attackerDoc"; "rawC"; "sibling"; "fake"; "rawD" ]

let cp_wrong_entity_cases =
  List.concat
    (List.mapi (fun oi op ->
      List.mapi (fun ei e -> cp_wrong_entity (oi + 1) op (ei + 1) e) cp_wrong_entities)
      mutating_ops)

(* ══════════════════════════════════════════════════════════════════════════
   SCOPE — a data/retrieval tool returns `? ForAll (FromDb (AuthorId == u))`
   but the query is scoped to the WRONG subject; the scoping proof is not
   discharged.
   ══════════════════════════════════════════════════════════════════════════ *)

(* The WHERE clause references a parameter that is NOT the one the return spec
   scopes by — the canonical "agent leaked another user's rows" bug. *)
let scope_wrong_where idx ~scope ~where_var =
  let m = Printf.sprintf "ScopeW%02d" idx in
  let test () =
    should_fail scope_re
      (db_hdr m ^ Printf.sprintf {|
fn dispatchList(%s: String, %s: String) -> List Note ? ForAll (FromDb (AuthorId == %s))
  requires [dbRead] =
  select note from Note where note.authorId == %s
|} scope where_var scope where_var)
  in
  (Printf.sprintf "SCOPE-W-%02d scope %s where %s" idx scope where_var, test)

let scope_where_cases =
  List.mapi (fun i (s, w) -> scope_wrong_where (i + 1) ~scope:s ~where_var:w)
    [ ("requestUser", "attacker"); ("requestUser", "other");
      ("agentUser", "victim");     ("agentUser", "stranger");
      ("u", "intruder");           ("principal", "rival");
      ("sessionUser", "guest");    ("requestUser", "everyone");
      ("caller", "someoneElse");   ("subject", "ghost"); ]

(* A scoped result for user A consumed at a fn requiring scoping to user B — the
   under-/mis-scoped list does not satisfy the consumer's ForAll proof. *)
let scope_consume_wrong idx wrong =
  let m = Printf.sprintf "ScopeC%02d" idx in
  let test () =
    should_fail scope_re
      (db_hdr m ^ Printf.sprintf {|
fn needsScoped(requestUser: String, xs: List Note ::: ForAll (FromDb (AuthorId == requestUser)) xs) -> Int =
  0
fn dispatchList(requestUser: String, %s: String) -> Int
  requires [dbRead] =
  let xs = select note from Note where note.authorId == %s
  needsScoped requestUser xs
|} wrong wrong)
  in
  (Printf.sprintf "SCOPE-C-%02d consume rows scoped to %s" idx wrong, test)

let scope_consume_cases =
  List.mapi (fun i w -> scope_consume_wrong (i + 1) w)
    [ "attacker"; "other"; "victim"; "stranger"; "intruder"; "rival";
      "guest"; "alt"; "ghost"; "u2"; "decoyUser"; "leaker" ]

(* Bare (unscoped) select consumed at a ForAll site — no per-row provenance. *)
let scope_bare_consume idx =
  let m = Printf.sprintf "ScopeB%02d" idx in
  let test () =
    should_fail scope_re
      (db_hdr m ^ Printf.sprintf {|
fn needsScoped%d(requestUser: String, xs: List Note ::: ForAll (FromDb (AuthorId == requestUser)) xs) -> Int =
  0
fn dispatchList%d(requestUser: String) -> Int
  requires [dbRead] =
  let xs = select note from Note
  needsScoped%d requestUser xs
|} idx idx idx)
  in
  (Printf.sprintf "SCOPE-B-%02d bare select at ForAll consumer" idx, test)

let scope_bare_cases = List.init 6 (fun i -> scope_bare_consume (i + 1))

(* ══════════════════════════════════════════════════════════════════════════
   HAND — hand-construct an entitled value rather than obtaining it via a scoped
   query / ownership check.
   ══════════════════════════════════════════════════════════════════════════ *)

(* `ok value ::: P` inside a plain `fn` (proof construction is fn-forbidden). *)
let hand_ok_in_fn opidx (opfn, optail) =
  let m = Printf.sprintf "HandOk%02d" opidx in
  let test () =
    should_fail hand_p001_re
      (agent_hdr m ^ owned_lib ^ Printf.sprintf {|
fn dispatch%s(u: String, raw: Doc) -> String =
  let t = ok raw ::: OwnedBy u raw
  %s u t%s
|} m opfn optail)
  in
  (Printf.sprintf "HAND-OK-%02d ok::: in fn for %s" opidx opfn, test)

let hand_ok_cases = List.mapi (fun i op -> hand_ok_in_fn (i + 1) op) mutating_ops

(* Naming the fact as if it were a value constructor. *)
let hand_ctor opidx (opfn, optail) =
  let m = Printf.sprintf "HandCtor%02d" opidx in
  let test () =
    should_fail hand_ctor_re
      (agent_hdr m ^ owned_lib ^ Printf.sprintf {|
fn dispatch%s(u: String, raw: Doc) -> String =
  let _fake = OwnedBy u raw
  %s u raw%s
|} m opfn optail)
  in
  (Printf.sprintf "HAND-CTOR-%02d fact-as-constructor for %s" opidx opfn, test)

let hand_ctor_cases = List.mapi (fun i op -> hand_ctor (i + 1) op) mutating_ops

(* An establish that "verifies" ownership but whose proof (bound to a fresh
   case subject) never flows to the consumed value — the consumed `raw` still
   lacks the proof. *)
let hand_establish opidx (opfn, optail) =
  let m = Printf.sprintf "HandEst%02d" opidx in
  let test () =
    should_fail satisfy_re
      (agent_hdr m ^
       owned_lib ^ Printf.sprintf {|
establish estOwned(u: String, t: Doc) -> Maybe (Fact (OwnedBy u t)) =
  Something (OwnedBy u t)
fn dispatch%s(u: String, raw: Doc) -> String =
  case estOwned u raw of
    Nothing -> "denied"
    Something p -> %s u raw%s
|} m opfn optail)
  in
  (Printf.sprintf "HAND-EST-%02d establish proof not flowing to value for %s" opidx opfn,
   test)

let hand_establish_cases = List.mapi (fun i op -> hand_establish (i + 1) op) mutating_ops

(* ══════════════════════════════════════════════════════════════════════════
   CAP — a tool dispatch fn reaches for an agent op without the aiProvider
   entitlement.  The provider capability is itself an entitlement on the tool.
   ══════════════════════════════════════════════════════════════════════════ *)

let cap_missing idx op =
  let m = Printf.sprintf "Cap%02d" idx in
  let test () =
    should_fail cap_re
      (Printf.sprintf
        "#lang tesl\nmodule %s exposing []\n\
         import Tesl.Prelude exposing [Int, String]\n\
         import Tesl.Agent exposing [aiProvider, Agent, defineAgent, mockProvider, \
         ask, askReply, replyText]\n%s"
        m
        (Printf.sprintf {|
fn dispatch%s(input: String) -> String =
  let agent = defineAgent (mockProvider ["x"]) "sys" 64
  %s
|} m op))
  in
  (Printf.sprintf "CAP-%02d tool op `%s` without aiProvider" idx
     (String.sub op 0 (min 18 (String.length op))), test)

let cap_cases =
  List.mapi (fun i op -> cap_missing (i + 1) op)
    [ "ask agent input";
      "let r = askReply agent input\n  replyText r";
      "let _ = ask agent input\n  ask agent \"again\"";
      "replyText (askReply agent input)"; ]

(* ══════════════════════════════════════════════════════════════════════════
   POS — positive companions.  The entitled value obtained the RIGHT way.
   ══════════════════════════════════════════════════════════════════════════ *)

(* A mutating tool dispatch that obtains ownership via the check, for each op. *)
let pos_owned_ok opidx (opfn, optail) =
  let m = Printf.sprintf "PosOwn%02d" opidx in
  let test () =
    should_pass
      (agent_hdr m ^ owned_lib ^ Printf.sprintf {|
fn dispatch%s(u: String, raw: Doc) -> String =
  let t = check checkOwned u raw
  %s u t%s
|} m opfn optail)
  in
  (Printf.sprintf "POS-OWN-%02d %s after ownership check" opidx opfn, test)

let pos_owned_cases = List.mapi (fun i op -> pos_owned_ok (i + 1) op) mutating_ops

let pos_scope_ok idx scope =
  let m = Printf.sprintf "PosScope%02d" idx in
  let test () =
    should_pass
      (db_hdr m ^ Printf.sprintf {|
fn dispatchList(%s: String) -> List Note ? ForAll (FromDb (AuthorId == %s))
  requires [dbRead] =
  select note from Note where note.authorId == %s
|} scope scope scope)
  in
  (Printf.sprintf "POS-SCOPE-%02d list scoped to %s" idx scope, test)

let pos_scope_cases =
  List.mapi (fun i s -> pos_scope_ok (i + 1) s)
    [ "requestUser"; "agentUser"; "u"; "principal"; "sessionUser"; "caller" ]

(* Once obtained, the entitlement proof is REUSABLE: a single ownership check
   discharges the obligation for several mutating ops on the same value. *)
let pos_proof_reuse () =
  should_pass
    (agent_hdr "PosReuse01" ^
     owned_lib ^ {|
fn dispatchDeleteThenArchive(u: String, raw: Doc) -> String =
  let t = check checkOwned u raw
  let _ = applyArchive u t
  applyDelete u t
|})

let pos_cap_ok () =
  should_pass
    (agent_hdr "PosCap01" ^ {|
fn dispatchSummarize(input: String) -> String requires [aiProvider] =
  let agent = defineAgent (mockProvider ["ok"]) "sys" 64
  ask agent input
|})

(* A full tool() wired to a proof-discharging dispatch — the entitlement model
   end to end in a real agent. *)
let pos_full_tool () =
  should_pass
    (agent_hdr "PosTool01" ^ owned_lib ^ {|
fn validateDoc(argsJson: String) -> Doc =
  Doc { id: argsJson, ownerId: argsJson, body: "" }
fn dispatchDelete(t: Doc) -> String = t.id
test "delete tool wires up" requires [supportBot] {
  let delTool = tool "delete_doc" "Delete a document" "{}" validateDoc dispatchDelete
  let agent = withTools (defineAgent (mockProvider ["done"]) "sys" 64) [delTool]
  expect (ask agent "delete it") == "done"
}
|})

(* ── Registration ────────────────────────────────────────────────────────── *)

let to_cases lst = List.map (fun (name, fn) -> test_case name `Quick fn) lst

let () =
  run "AISuite-Entitlement" [
    "OWN-no-ownership-proof", to_cases (own_no_proof_cases @ own_built_cases);
    "CP-wrong-subject",       to_cases (cp_wrong_user_cases @ cp_wrong_entity_cases);
    "SCOPE-user-scoping",     to_cases (scope_where_cases @ scope_consume_cases @ scope_bare_cases);
    "HAND-fabricated-value",  to_cases (hand_ok_cases @ hand_ctor_cases @ hand_establish_cases);
    "CAP-missing-aiProvider", to_cases cap_cases;
    "POS-companions", (
      to_cases (pos_owned_cases @ pos_scope_cases) @ [
        test_case "POS ownership proof reused across ops" `Quick pos_proof_reuse;
        test_case "POS tool dispatch with aiProvider" `Quick pos_cap_ok;
        test_case "POS full tool() wired to dispatch" `Quick pos_full_tool;
      ]);
  ]
