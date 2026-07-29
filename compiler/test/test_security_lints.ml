(** The `Security` diagnostic category and its lints (SEC0xx) —
    roadmap/completed/crypto_phase0_security_lints.md.

    THE GOVERNING RULE, WHICH IS WHAT THIS SUITE ACTUALLY GUARDS.

      > A security lint ships only if it is ACTIONABLE (one obvious fix),
      > PRECISE (a clean codebase is COMPLETELY silent) and ABOUT SOMETHING TESL
      > CAN ENFORCE.  Anything failing those belongs in documentation.

    A noisy security lint is worse than none: it trains people to ignore the
    whole category, and there is no suppression mechanism in Tesl, so a false
    positive cannot be silenced at all — only the whole linter can be turned off.

    So every check below comes in a PAIR: a positive fixture that must fire, and
    a negative fixture — the honest version of the same program — that must be
    completely silent.  A ratchet with only the positive half is satisfied by a
    lint that fires on everything.

    And the third group is the one that matters most in practice: the WHOLE
    SHIPPED CORPUS (example/, templates/, tests/) must produce ZERO SEC
    diagnostics.  That is the precision claim, stated as a test rather than as a
    measurement someone took once. *)

open Alcotest

(* ── Harness ─────────────────────────────────────────────────────────────── *)

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let fresh_dir =
  let counter = ref 0 in
  fun () ->
    incr counter;
    let dir =
      Filename.concat (Filename.get_temp_dir_name ())
        (Printf.sprintf "tesl_sec_lints_%d_%d" (Unix.getpid ()) !counter)
    in
    (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    dir

let lint_source source : Compile.diagnostic list =
  let dir = fresh_dir () in
  let path = Filename.concat dir "main.tesl" in
  write_file path source;
  Linter.lint_file path

let sec_codes (ds : Compile.diagnostic list) : string list =
  List.filter_map
    (fun (d : Compile.diagnostic) ->
       if String.length d.code >= 3 && String.sub d.code 0 3 = "SEC"
       then Some d.code else None)
    ds
  |> List.sort compare

let expect_codes ~msg expected source =
  let got = sec_codes (lint_source source) in
  check (list string) msg expected got

let expect_silent ~msg source =
  let got = sec_codes (lint_source source) in
  if got <> [] then
    failf "%s — expected NO security diagnostics, got: %s"
      msg (String.concat ", " got)

(* ── The category itself ─────────────────────────────────────────────────── *)

(* `tesl help codes` builds its index from a hand-written category list that the
   compiler does NOT force to be exhaustive (Error_codes.index's `cats`).  A
   category omitted there is invisible in the index while `tesl explain SEC001`
   keeps working — a silent hole, so pin it. *)
let test_category_is_in_the_help_index () =
  let index = Error_codes.index () in
  let contains hay needle =
    let n = String.length needle and h = String.length hay in
    let rec at i =
      i + n <= h && (String.sub hay i n = needle || at (i + 1)) in
    at 0
  in
  check bool "`tesl help codes` names the SECURITY group" true
    (contains index "SECURITY:");
  List.iter
    (fun code ->
       check bool (Printf.sprintf "%s appears in the index" code) true
         (contains index code))
    [ "SEC001"; "SEC003"; "SEC004" ]

let test_every_sec_code_explains_and_deep_links () =
  let secs =
    List.filter
      (fun (e : Error_codes.entry) -> e.category = Error_codes.Security)
      Error_codes.registry
  in
  check bool "the Security category is non-empty" true (secs <> []);
  List.iter
    (fun (e : Error_codes.entry) ->
       check bool (Printf.sprintf "%s: `tesl explain` renders" e.code) true
         (Error_codes.explain e.code <> None);
       (* test_error_codes.ml checks that the anchor RESOLVES; here we only
          require that a security code has one at all, since the explanation is
          the actionable half of the lint. *)
       check bool (Printf.sprintf "%s: has a manual deep-link" e.code) true
         (e.manual <> None);
       check bool (Printf.sprintf "%s: code is SEC-prefixed" e.code) true
         (String.length e.code > 3 && String.sub e.code 0 3 = "SEC"))
    secs

(* ── SEC001 — request data compared against a string literal in an `auth` ── *)

let sec001_positive = {|module M exposing [adminAuth]
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Dict exposing [Dict.lookup]

fact IsAdmin (n: String)

auth adminAuth(request: HttpRequest) -> String ? IsAdmin =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "admin only"
    Something userId ->
      if userId == "admin" then
        ok userId ::: IsAdmin userId
      else
        fail 401 "admin only"
|}

(* The same shape via a header and via `!=`, plus a value laundered through one
   more `let` — the taint must survive both. *)
let sec001_positive_header = {|module M exposing [hdrAuth]
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Dict exposing [Dict.lookup]

fact IsAdmin (n: String)

auth hdrAuth(request: HttpRequest) -> String ? IsAdmin =
  case Dict.lookup "x-user" request.headers of
    Nothing -> fail 401 "no"
    Something raw ->
      let who = raw
      if who != "root" then
        fail 401 "no"
      else
        ok who ::: IsAdmin who
|}

(* The honest version: the identity is the VERIFIED payload of a signed session.
   Note that it still reads cookies, still does a `case`, and still returns a
   fact — everything the shipped lint deliberately does NOT key on. *)
let sec001_negative = {|module M exposing [sessionAuth]
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Env exposing [requireEnv, envRead]
import Tesl.Crypto exposing [Secret, Crypto.checkSignature, Crypto.signatureFromHex]

fact IsAdmin (n: String)

auth sessionAuth(request: HttpRequest) -> String ? IsAdmin
  requires [envRead] =
  case Dict.lookup "session" request.cookies of
    Nothing -> fail 401 "admin only"
    Something payload ->
      case Dict.lookup "sessionSig" request.cookies of
        Nothing -> fail 401 "admin only"
        Something sigHex ->
          let key = Secret (requireEnv "ADMIN_SESSION_KEY")
          let who = check Crypto.checkSignature key (Crypto.signatureFromHex sigHex) payload
          ok who ::: IsAdmin who
|}

(* Comparing an ALREADY-VERIFIED value against a literal is correct
   authorization and must stay silent — otherwise the lint fires on its own
   recommended fix, which is the fastest way to get a category ignored. *)
let sec001_negative_verified_compare = {|module M exposing [adminAuth]
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Env exposing [requireEnv, envRead]
import Tesl.Crypto exposing [Secret, Crypto.checkSignature, Crypto.signatureFromHex]

fact IsAdmin (n: String)

auth adminAuth(request: HttpRequest) -> String ? IsAdmin
  requires [envRead] =
  case Dict.lookup "session" request.cookies of
    Nothing -> fail 401 "admin only"
    Something payload ->
      case Dict.lookup "sessionSig" request.cookies of
        Nothing -> fail 401 "admin only"
        Something sigHex ->
          let key = Secret (requireEnv "ADMIN_SESSION_KEY")
          let who = check Crypto.checkSignature key (Crypto.signatureFromHex sigHex) payload
          if who == "admin" then
            ok who ::: IsAdmin who
          else
            fail 403 "admin only"
|}

(* A literal comparison on request data OUTSIDE an `auth` is ordinary business
   logic (a filter, a feature flag, a route branch) and must stay silent. *)
let sec001_negative_not_an_auth = {|module M exposing [wantsJson]
import Tesl.Prelude exposing [Bool(..), String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Dict exposing [Dict.lookup]

fn wantsJson(request: HttpRequest) -> Bool =
  case Dict.lookup "accept" request.headers of
    Nothing -> False
    Something a -> a == "application/json"
|}

let test_sec001 () =
  expect_codes ~msg:"cookie value compared with a literal inside `auth`"
    [ "SEC001" ] sec001_positive;
  expect_codes ~msg:"header value, `!=`, one `let` of laundering"
    [ "SEC001" ] sec001_positive_header;
  expect_silent ~msg:"signed session verified with Crypto.checkSignature"
    sec001_negative;
  expect_silent ~msg:"comparing an already-verified value with a literal"
    sec001_negative_verified_compare;
  expect_silent ~msg:"literal comparison on request data outside an `auth`"
    sec001_negative_not_an_auth

(* ── SEC003 — a string literal used as key material ──────────────────────── *)

let sec003_positive = {|module M exposing [sign]
import Tesl.Prelude exposing [String]
import Tesl.Crypto exposing [Secret, Signature, Crypto.signWith]

fn sign(payload: String) -> Signature =
  Crypto.signWith (Secret "s3cr3t-signing-key") payload
|}

let sec003_positive_fingerprint = {|module M exposing [fp]
import Tesl.Prelude exposing [String]
import Tesl.Crypto exposing [Crypto.keyFingerprint]

fn fp() -> String =
  Crypto.keyFingerprint "s3cr3t-signing-key"
|}

let sec003_negative = {|module M exposing [sign]
import Tesl.Prelude exposing [String]
import Tesl.Env exposing [requireEnv, envRead]
import Tesl.Crypto exposing [Secret, Signature, Crypto.signWith]

fn sign(payload: String) -> Signature
  requires [envRead] =
  Crypto.signWith (Secret (requireEnv "SESSION_SIGNING_KEY")) payload
|}

(* Deliberately NOT a hit: an ordinary string literal, and a literal in a
   NON-key position.  SEC003 is structural (a literal in a key position), never
   entropy guessing — the known-answer vectors a crypto test suite needs would
   light an entropy lint up permanently. *)
let sec003_negative_ordinary_literals = {|module M exposing [tag]
import Tesl.Prelude exposing [String]
import Tesl.Env exposing [requireEnv, envRead]
import Tesl.Crypto exposing [Secret, Signature, Crypto.signWith, Crypto.fingerprint]

fn tag() -> Signature
  requires [envRead] =
  let etag = Crypto.fingerprint "a1b2c3d4e5f60718293a4b5c6d7e8f90"
  Crypto.signWith (Secret (requireEnv "K")) etag
|}

let test_sec003 () =
  expect_codes ~msg:"`Secret \"literal\"`" [ "SEC003" ] sec003_positive;
  expect_codes ~msg:"literal in Crypto.keyFingerprint's key position"
    [ "SEC003" ] sec003_positive_fingerprint;
  expect_silent ~msg:"key read from the environment" sec003_negative;
  expect_silent ~msg:"literals in non-key positions (no entropy guessing)"
    sec003_negative_ordinary_literals

(* ── SEC004 — timing-unsafe MAC comparison ───────────────────────────────── *)

let sec004_positive_direct = {|module M exposing [ok_]
import Tesl.Prelude exposing [Bool(..), String]
import Tesl.Crypto exposing [Secret, Crypto.signWith, Crypto.signatureHex]

fn ok_(key: Secret, payload: String, provided: String) -> Bool =
  Crypto.signatureHex (Crypto.signWith key payload) == provided
|}

let sec004_positive_via_let = {|module M exposing [ok_]
import Tesl.Prelude exposing [Bool(..), String]
import Tesl.Crypto exposing [Secret, Crypto.signWith, Crypto.signatureHex]

fn ok_(key: Secret, payload: String, provided: String) -> Bool =
  let mine = Crypto.signatureHex (Crypto.signWith key payload)
  mine != provided
|}

(* The honest version, and the legitimate use of signatureHex beside it:
   transporting a tag OUT (into a header value) is what the function is for. *)
let sec004_negative = {|module M exposing [verify, headerValue]
import Tesl.Prelude exposing [String]
import Tesl.Crypto exposing [
  Secret,
  Signature,
  Authentic,
  Crypto.signWith,
  Crypto.signatureHex,
  Crypto.signatureFromHex,
  Crypto.checkSignature,
]

fn headerValue(key: Secret, payload: String) -> String =
  Crypto.signatureHex (Crypto.signWith key payload)

check verify(key: Secret, provided: String, payload: String)
  -> payload: String ::: Authentic payload =
  let verified = check Crypto.checkSignature key (Crypto.signatureFromHex provided) payload
  ok verified ::: Authentic verified
|}

let test_sec004 () =
  expect_codes ~msg:"signatureHex result compared directly"
    [ "SEC004" ] sec004_positive_direct;
  expect_codes ~msg:"signatureHex result compared through a `let`"
    [ "SEC004" ] sec004_positive_via_let;
  expect_silent ~msg:"checkSignature, plus signatureHex used for transport"
    sec004_negative

(* ── The precision claim, over the whole shipped corpus ──────────────────── *)

(* Walk up from the test's cwd to the repository root (the directory that has
   both `example/learn` and `templates`).  Self-skips when the corpus is not
   reachable rather than failing, so the suite still runs in a bare sandbox. *)
let repo_root () : string option =
  let rec up dir depth =
    if depth > 8 then None
    else if Sys.file_exists (Filename.concat dir "example/learn")
         && Sys.file_exists (Filename.concat dir "templates")
    then Some dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then None else up parent (depth + 1)
  in
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some r when Sys.file_exists (Filename.concat r "example/learn") -> Some r
  | _ -> up (Sys.getcwd ()) 0

let tesl_files dir =
  if not (Sys.file_exists dir) then []
  else
    Sys.readdir dir |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".tesl")
    |> List.sort compare
    |> List.map (Filename.concat dir)

let test_corpus_is_completely_silent () =
  match repo_root () with
  | None -> ()   (* corpus not reachable from here — nothing to assert *)
  | Some root ->
    let j = Filename.concat root in
    let files =
      tesl_files (j "example")
      @ tesl_files (j "example/learn")
      @ tesl_files (j "example/chat")
      @ tesl_files (j "templates/minimal")
      @ tesl_files (j "templates/api")
      @ tesl_files (j "tests")
    in
    check bool "the corpus sweep actually found files" true
      (List.length files > 50);
    let offenders =
      List.concat_map
        (fun f ->
           List.map (fun c -> Printf.sprintf "%s: %s" (Filename.basename f) c)
             (sec_codes (Linter.lint_file f)))
        files
    in
    if offenders <> [] then
      failf
        "the shipped corpus must be COMPLETELY silent under SEC (a security \
         lint that fires on clean code trains people to ignore the whole \
         category, and Tesl has no suppression mechanism). Offenders:\n  %s"
        (String.concat "\n  " offenders)

let () =
  run "security lints (SEC0xx)"
    [ ( "category",
        [ test_case "SECURITY group is in `tesl help codes`" `Quick
            test_category_is_in_the_help_index;
          test_case "every SEC code explains and deep-links" `Quick
            test_every_sec_code_explains_and_deep_links ] );
      ( "checks",
        [ test_case "SEC001 auth literal comparison" `Quick test_sec001;
          test_case "SEC003 hardcoded key material" `Quick test_sec003;
          test_case "SEC004 timing-unsafe MAC comparison" `Quick test_sec004 ] );
      ( "precision",
        [ test_case "shipped corpus is completely silent" `Quick
            test_corpus_is_completely_silent ] ) ]
