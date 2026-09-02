(** GitHub issue #73 — an `exists` return type could not be FORWARDED through a
    plain `fn`, and the compiler's own successive hints led nowhere.

    A `fn` declaring `-> exists id: String => Thing ? FromDb (Id == id)` could
    not return an already-packed value of that exact type from a callee with the
    identical signature:

      1. the direct form was rejected — "declares exists return type but body has
         no exists expression";
      2. the hinted workaround (unpack the witness, re-pack) was rejected — "the
         packed value must carry the proof … attach an existing proof with
         `value ::: proofVar`";
      3. following THAT hint hit P001 — "`ok ::: proof` construction is not
         allowed in `fn`".

    So the second hint recommended a fix that is categorically unavailable in the
    exact context it fires in, and the only working shape was to re-derive the
    fact with a fresh `insert`/`select` inside every caller.

    The rule
    ------------------------------------------------------------------------
    A packed existential IS a value of the declared type: if every TAIL of the
    body is a call to a function whose own return spec is the same existential —
    the same single witness name/type, and a proof that entails the declared one
    after substituting the callee's parameters at the call site — the
    package the caller receives is bit-for-bit the callee's.  Nothing is minted,
    so nothing can be forged.

    It stays fail-CLOSED: an unresolved callee, a non-existential callee, a
    callee carrying a DIFFERENT fact, a fabricated branch, or an argument passed
    into the wrong proof-subject slot are all still rejected.

    Go erases proof packages after static discharge. Emit tests therefore pin
    that forwarding remains direct and a renamed witness returns the checked
    value rather than its unchecked local source.

    The runtime companions live in tests/exists-forwarding-tests.tesl. *)

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

let failf fmt = Printf.ksprintf failwith fmt

let run_cc args =
  let q = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " q ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let st = Unix.close_process_in ic in
  let code = match st with Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n in
  (code, out)

(* Imports resolve by file name, so a temp file must be named after its module
   header (V001). *)
let kebab_of_module m =
  let buf = Buffer.create 16 in
  String.iteri (fun i c ->
    if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
    else if c >= 'A' && c <= 'Z' then begin
      Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c)
    end else Buffer.add_char buf c) m;
  Buffer.contents buf

(* Write [(module_name, source)] files into one temp dir and run [args @ [main]]
   where [main] is the LAST module's path. *)
let with_modules mods f =
  let dir = Filename.temp_dir "tesl-issue73" "" in
  let paths =
    List.map (fun (m, src) ->
      let p = Filename.concat dir (kebab_of_module m ^ ".tesl") in
      Out_channel.with_open_text p (fun oc -> Out_channel.output_string oc src);
      p) mods
  in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun p -> try Sys.remove p with _ -> ()) paths;
      try Unix.rmdir dir with _ -> ())
    (fun () -> f (List.nth paths (List.length paths - 1)))

let check_modules mods = with_modules mods (fun main -> run_cc ["--check"; main])
let emit_modules mods = with_modules mods (fun main ->
  let module_name, _ = List.nth mods (List.length mods - 1) in
  let package_dir = "teslmod" ^ String.lowercase_ascii module_name in
  match Compile.compile_go_file main with
  | Compile.GoFailure diagnostics ->
    (1, String.concat "\n"
          (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  | Compile.GoSuccess artifacts ->
    match List.find_opt (fun (a : Emit_go.artifact) ->
      Filename.basename a.path = "module.go"
      && Filename.basename (Filename.dirname a.path) = package_dir) artifacts with
    | Some artifact -> (0, artifact.contents)
    | None -> (1, "Go emit did not produce the root module.go"))

let contains hay needle =
  try ignore (Str.search_forward (Str.regexp_string needle) hay 0); true
  with Not_found -> false

let should_pass label mods =
  let code, out = check_modules mods in
  if code <> 0 then failf "%s: expected a clean check, got exit %d:\n%s" label code out

let should_fail label ~expect mods =
  let code, out = check_modules mods in
  if code = 0 then failf "%s: expected REJECTION, but the check passed" label;
  if not (contains out expect) then
    failf "%s: rejected, but not for the expected reason (wanted %S):\n%s" label expect out

(* ── Corpus ──────────────────────────────────────────────────────────────── *)

(* The issue's own repro: a DB-backed existential with a `FromDb` provenance
   proof, which no user code can mint. *)
let db_prelude = {|module Db73 exposing []
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Time exposing [PosixMillis, nowMillis, time]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Id exposing [generatePrefixedId]
import Tesl.Random exposing [random]

entity Thing table "things" primaryKey id {
  id: String
  name: String
  createdAt: PosixMillis
}

database ProbeDatabase = Database {
  schema: "probe"
  entities: [Thing]
  backend: Postgres (PostgresConfig {
    dbName:   env "TESL_POSTGRES_DATABASE"
    user:     env "TESL_POSTGRES_USER"
    password: env "TESL_POSTGRES_PASSWORD"
    connection: TcpConnection { host: env "TESL_POSTGRES_HOST", port: envInt "TESL_POSTGRES_PORT" 5432 }
  })
}

fn core(name: String) -> exists id: String => Thing ? FromDb (Id == id)
  requires [dbWrite, time, random] =
  let id = generatePrefixedId "thing"
  exists id =>
    insert Thing { id: id, name: name, createdAt: nowMillis() }

fn plainThing(name: String) -> Thing requires [time] =
  Thing { id: "x", name: name, createdAt: nowMillis() }
|}

let db src = [("Db73", db_prelude ^ src)]

(* A capability-free existential over a check-established fact, for the shapes
   that do not need a database. *)
let tok_prelude = {|module Tok73 exposing []
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.String exposing [String.length]
import Tesl.Random exposing [random]
import Tesl.Id exposing [generatePrefixedId]

fact TaggedWith (tag: String) (s: String)

check checkTagged(tag: String, s: String) -> s: String ::: TaggedWith tag s =
  if String.length s > 3 then
    ok s ::: TaggedWith tag s
  else
    fail 400 "bad token"

capability idGen implies random

fn core(tag: String, other: String)
  -> exists tok: String => tok: String ::: TaggedWith tag tok
  requires [idGen] =
  let tok = generatePrefixedId "tok"
  let validated = check checkTagged tag tok
  exists tok =>
    validated
|}

let tok src = [("Tok73", tok_prelude ^ src)]

(* ── Positives ───────────────────────────────────────────────────────────── *)

let test_forward_direct () =
  should_pass "direct forwarding (the issue's repro)"
    (db {|
fn wrapper(name: String) -> exists id: String => Thing ? FromDb (Id == id)
  requires [dbWrite, time, random] =
  core name
|})

let test_forward_via_let () =
  should_pass "forwarding a let-bound package"
    (db {|
fn wrapper(name: String) -> exists id: String => Thing ? FromDb (Id == id)
  requires [dbWrite, time, random] =
  let packed = core name
  packed
|})

let test_forward_via_let_bound_if () =
  should_pass "forwarding every branch through a let-bound package"
    (db {|
fn wrapper(name: String, flag: Bool) -> exists id: String => Thing ? FromDb (Id == id)
  requires [dbWrite, time, random] =
  let packed = if flag then
    core name
  else
    core "fallback"
  packed
|})

let test_forward_via_let_bound_if_or_fail () =
  should_pass "forwarding through a let-bound branch that may fail"
    (db {|
fn wrapper(name: String, flag: Bool) -> exists id: String => Thing ? FromDb (Id == id)
  requires [dbWrite, time, random] =
  let packed = if flag then
    core name
  else
    fail 503 "unavailable"
  packed
|})

let test_forward_via_long_alias_chain () =
  should_pass "forwarding through more than eight aliases"
    (db {|
fn wrapper(name: String) -> exists id: String => Thing ? FromDb (Id == id)
  requires [dbWrite, time, random] =
  let a = core name
  let b = a
  let c = b
  let d = c
  let e = d
  let f = e
  let g = f
  let h = g
  let i = h
  let j = i
  j
|})

let test_forward_every_branch () =
  should_pass "every branch forwards"
    (db {|
fn wrapper(name: String, flag: Bool) -> exists id: String => Thing ? FromDb (Id == id)
  requires [dbWrite, time, random] =
  if flag then
    core name
  else
    core "fallback"
|})

let test_forward_renamed_parameters () =
  should_pass "parameters renamed at the call site still line up"
    (tok {|
fn wrapper(a: String, b: String)
  -> exists tok: String => tok: String ::: TaggedWith a tok
  requires [idGen] =
  core a b
|})

let test_forward_via_argument_alias () =
  should_pass "proof subjects resolve through argument aliases"
    (tok {|
fn wrapper(tag: String, other: String)
  -> exists tok: String => tok: String ::: TaggedWith tag tok
  requires [idGen] =
  let alias = tag
  core alias other
|})

let test_forward_cross_module () =
  should_pass "forwarding an IMPORTED existential"
    [ ("Core73", {|module Core73 exposing [generateToken, IsTokenId, idGen]
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.length]
import Tesl.Random exposing [random]
import Tesl.Id exposing [generatePrefixedId]

fact IsTokenId (s: String)

check checkTokenId(s: String) -> s: String ::: IsTokenId s =
  if String.length s > 3 then
    ok s ::: IsTokenId s
  else
    fail 400 "bad token"

capability idGen implies random

fn generateToken() -> exists tokenId: String => tokenId: String ::: IsTokenId tokenId
  requires [idGen] =
  let tokenId = generatePrefixedId "tok"
  let validated = check checkTokenId tokenId
  exists tokenId =>
    validated
|});
      ("User73", {|module User73 exposing []
import Tesl.Prelude exposing [String]
import Core73 exposing [generateToken, IsTokenId, idGen]

fn forwarded() -> exists tokenId: String => tokenId: String ::: IsTokenId tokenId
  requires [idGen] =
  generateToken()
|}) ]

(* ── Negatives (the rule must stay fail-closed) ──────────────────────────── *)

let test_reject_wrong_fact () =
  (* The callee packs a locally-established fact; the wrapper claims `FromDb`.
     Accepting this would forge DB provenance on fabricated data. *)
  should_fail "laundering a different fact as FromDb"
    ~expect:"does not return the same `exists` type"
    (db {|
fact Fabricated (t: Thing)

establish fakeIt(t: Thing) -> Fact (Fabricated t) =
  Fabricated t

fn faker(name: String) -> exists id: String => Thing ? Fabricated
  requires [time] =
  let t = Thing { id: "x", name: name, createdAt: nowMillis() }
  let p = fakeIt t
  exists id =>
    t ::: p

fn launder(name: String) -> exists id: String => Thing ? FromDb (Id == id)
  requires [time] =
  faker name
|})

let test_reject_non_exists_callee () =
  should_fail "forwarding a plain (non-existential) function"
    ~expect:"does not return the same `exists` type"
    (db {|
fn wrapper(name: String) -> exists id: String => Thing ? FromDb (Id == id)
  requires [time] =
  plainThing name
|})

let test_reject_fabricated_tail () =
  should_fail "a record literal tail is still not a pack"
    ~expect:"does not produce a top-level `exists` pack"
    (db {|
fn wrapper(name: String) -> exists id: String => Thing ? FromDb (Id == id)
  requires [time] =
  Thing { id: "x", name: name, createdAt: nowMillis() }
|})

let test_reject_mixed_branches () =
  (* One branch forwards honestly; the other fabricates.  EVERY tail must be a
     valid forwarding site, so the whole function is rejected. *)
  should_fail "one honest branch does not license a fabricated one"
    ~expect:"does not return the same `exists` type"
    (db {|
fn wrapper(name: String, flag: Bool) -> exists id: String => Thing ? FromDb (Id == id)
  requires [dbWrite, time, random] =
  if flag then
    core name
  else
    plainThing name
|})

let test_reject_swapped_subjects () =
  (* `core b a` packs a token tagged with `b`, but the signature claims `a`. *)
  should_fail "an argument in the wrong proof-subject slot"
    ~expect:"does not return the same `exists` type"
    (tok {|
fn wrapper(a: String, b: String)
  -> exists tok: String => tok: String ::: TaggedWith a tok
  requires [idGen] =
  core b a
|})

let test_reject_unknown_callee () =
  should_fail "an unresolved callee is not a forwarding site"
    ~expect:"does not produce a top-level `exists` pack"
    (db {|
fn wrapper(name: String) -> exists id: String => Thing ? FromDb (Id == id)
  requires [time] =
  name
|})

(* ── Emit: the package must reach the caller intact ──────────────────────── *)

let emit_of label mods =
  let code, out = emit_modules mods in
  if code <> 0 then failf "%s: emit failed (exit %d):\n%s" label code out;
  out

let test_emit_forward_not_raw_valued () =
  let out =
    emit_of "forwarded tail"
      (db {|
fn wrapper(name: String) -> exists id: String => Thing ? FromDb (Id == id)
  requires [dbWrite, time, random] =
  core name
|})
  in
  if not (contains out "return core(name)") then
    failf "expected the bare forwarded call in tail position:\n%s" out

let test_emit_pack_in_branch_not_raw_valued () =
  let out =
    emit_of "pack in an if branch"
      (db {|
fn branchy(name: String, flag: Bool) -> exists id: String => Thing ? FromDb (Id == id)
  requires [dbWrite, time, random] =
  let id = generatePrefixedId "thing"
  if flag then
    exists id =>
      insert Thing { id: id, name: name, createdAt: nowMillis() }
  else
    exists id =>
      insert Thing { id: id, name: "x", createdAt: nowMillis() }
|})
  in
  if contains out "RawValue(" then
    failf "a pack in a branch tail was unwrapped:\n%s" out

let test_emit_witness_uses_declared_name () =
  (* The witness name is proof-only in Go. The checked value must survive
     erasure; returning [internal] would bypass the check result. *)
  let out =
    emit_of "renamed witness"
      (tok {|
fn renamed(tag: String) -> exists tok: String => tok: String ::: TaggedWith tag tok
  requires [idGen] =
  let internal = generatePrefixedId "tok"
  let validated = check checkTagged tag internal
  exists internal =>
    validated
|})
  in
  if not (contains out "return validated") then
    failf "expected the checked witness value to be returned:\n%s" out;
  if contains out "return internal" then
    failf "the unchecked witness source escaped instead of the checked value:\n%s" out

let () =
  run "issue-73 existential forwarding" [
    "forward", [
      test_case "direct tail call"            `Quick test_forward_direct;
      test_case "let-bound package"           `Quick test_forward_via_let;
      test_case "let-bound branching package" `Quick test_forward_via_let_bound_if;
      test_case "let-bound forward-or-fail"    `Quick test_forward_via_let_bound_if_or_fail;
      test_case "long alias chain"            `Quick test_forward_via_long_alias_chain;
      test_case "every branch forwards"       `Quick test_forward_every_branch;
      test_case "renamed parameters"          `Quick test_forward_renamed_parameters;
      test_case "argument alias"              `Quick test_forward_via_argument_alias;
      test_case "imported callee"             `Quick test_forward_cross_module;
    ];
    "fail-closed", [
      test_case "wrong fact laundered"        `Quick test_reject_wrong_fact;
      test_case "non-existential callee"      `Quick test_reject_non_exists_callee;
      test_case "fabricated record tail"      `Quick test_reject_fabricated_tail;
      test_case "one fabricated branch"       `Quick test_reject_mixed_branches;
      test_case "swapped proof subjects"      `Quick test_reject_swapped_subjects;
      test_case "unresolved tail"             `Quick test_reject_unknown_callee;
    ];
    "emit", [
      test_case "forwarded call not raw-valued" `Quick test_emit_forward_not_raw_valued;
      test_case "branch pack not raw-valued"    `Quick test_emit_pack_in_branch_not_raw_valued;
      test_case "renamed witness returns checked value" `Quick
        test_emit_witness_uses_declared_name;
    ];
  ]
