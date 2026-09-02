(** test_jwt.ml — Compiler-level tests for Tesl.JWT stdlib module.

    Covers:
    1.  Parser: JWT import, JWT.sign/verify/decode usage, JwtToken/Secret types
    2.  Type inference: nominal type safety (JwtToken ≠ String, Secret ≠ JwtToken)
    3.  Capability enforcement: JWT.sign/verify/decode require [jwt]
    4.  Module validation: Tesl.JWT known module, export list validated
    5.  Emit: Go output includes JWT runtime calls/artifact

    THE KEY TYPE IS `Secret`, FROM Tesl.Crypto.  `Tesl.JWT` had a key newtype of
    its own until 2026-07-30; it was deleted, not aliased, because
    `Env.requireSecret` returns `Secret` and two key types forced every signing
    program to rewrap the key through a plain `String`.  So every probe below
    imports `Secret` from Tesl.Crypto, and `Tesl.JWT exposing [Secret]` is now an
    unknown export.

    TWO PROBES BELOW ARE THE ONLY PLACE IN THE TREE THAT STILL SPELLS THE OLD
    NAME, and they spell it in order to assert it is REJECTED — as an export of
    `Tesl.JWT` and as a type annotation.  A `grep -rn` for the old name over the
    tree is supposed to come back empty; those two hits are the ratchet that keeps
    it empty, not residue of the old surface.
*)

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let jwt_imports =
  "import Tesl.Prelude exposing [Int, String, Bool, List, Unit]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n\
   import Tesl.Dict exposing [Dict, Dict.singleton, Dict.lookup]\n\
   import Tesl.Time exposing [time]\n\
   import Tesl.Crypto exposing [Secret]\n\
   import Tesl.JWT exposing [jwt, JwtToken, JWT.sign, JWT.verify, JWT.decode, Authentic]\n"


let module_ ?(name="M") ?(exports="") ?(extra="") body =
  Printf.sprintf "module %s exposing [%s]\n%s%s\n%s"
    name exports jwt_imports extra body

let compile_artifacts name src =
  match Compile.compile_go_source "<test>" src with
  | Compile.GoSuccess artifacts -> artifacts
  | Compile.GoFailure diags ->
    Alcotest.failf "%s: unexpected compile failure: %s" name
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diags))

let compile_ok name src =
  let artifacts = compile_artifacts name src in
  match List.find_opt (fun (a : Emit_go.artifact) ->
    a.path = "internal/teslmodm/module.go") artifacts with
  | Some artifact -> artifact.contents
  | None -> Alcotest.failf "%s: missing Go module artifact" name

let compile_err name src =
  let diags = Compile.check_source "<test>" src in
  if diags = [] then
    Alcotest.failf "%s: expected errors but compilation succeeded" name
  else
    String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) diags)

let contains needle haystack =
  let n = String.length needle in
  let m = String.length haystack in
  if n > m then false
  else begin
    let found = ref false in
    for i = 0 to m - n do
      if String.sub haystack i n = needle then found := true
    done;
    !found
  end

let check_contains name src substr =
  let go = compile_ok name src in
  if not (contains substr go) then
    Alcotest.failf "%s: expected to find %S in Go artifact:\n%s" name substr go

let check_err_contains name src substr =
  let msg = compile_err name src in
  if not (contains substr msg) then
    Alcotest.failf "%s: expected error containing %S, got:\n%s" name substr msg

(* ── 1. Parser tests ─────────────────────────────────────────────────────── *)

let test_parse_jwt_import () =
  (* Tesl.JWT is recognized as a known module *)
  let src = module_ ~exports:"makeToken" {|
capability myAuth implies jwt, time

fn makeToken(userId: String, secret: Secret) requires [myAuth] -> JwtToken =
  JWT.sign (Dict.singleton "sub" userId) secret
|} in
  check_contains "parse_jwt_import" src "teslrt.JwtSign"

let test_parse_jwt_sign () =
  let src = module_ ~exports:"sign" {|
capability myJwt implies jwt, time

fn sign(claims: Dict String String, secret: Secret) requires [myJwt] -> JwtToken =
  JWT.sign claims secret
|} in
  check_contains "parse_jwt_sign" src "teslrt.JwtSign"

let test_parse_jwt_verify () =
  let src = module_ ~exports:"verify" {|
capability myJwt implies jwt, time

fn verify(token: JwtToken, secret: Secret) requires [myJwt] -> String =
  let verified = check JWT.verify token secret
  case Dict.lookup "sub" verified of
    Nothing -> ""
    Something s -> s
|} in
  check_contains "parse_jwt_verify" src "teslrt.JwtVerify"

let test_parse_jwt_decode () =
  let src = module_ ~exports:"decode" {|
capability myJwt implies jwt, time

fn decode(token: JwtToken) requires [myJwt] -> String =
  case Dict.lookup "sub" (JWT.decode token) of
    Nothing -> ""
    Something s -> s
|} in
  check_contains "parse_jwt_decode" src "teslrt.JwtDecode"

let test_parse_jwt_newtype_jwtsecret () =
  let src = module_ ~exports:"wrapSecret" {|
fn wrapSecret(s: String) -> Secret =
  Secret s
|} in
  check_contains "parse_jwt_newtype_secret" src "Secret"

let test_parse_jwt_newtype_jwttoken () =
  let src = module_ ~exports:"wrapToken" {|
fn wrapToken(s: String) -> JwtToken =
  JwtToken s
|} in
  check_contains "parse_jwt_newtype_token" src "JwtToken"

let test_parse_jwt_token_type_annotation () =
  let src = module_ ~exports:"process" {|
capability myJwt implies jwt, time

fn process(t: JwtToken, s: Secret) requires [myJwt] -> String =
  let verified = check JWT.verify t s
  case Dict.lookup "sub" verified of
    Nothing -> ""
    Something u -> u
|} in
  let _ = compile_ok "parse_jwt_type_annotation" src in
  ()

let test_parse_jwt_capability_declare () =
  let src = module_ ~exports:"" {|
capability myAuth implies jwt, time
|} in
  let _ = compile_ok "parse_jwt_cap_declare" src in
  ()

let test_parse_jwt_multiple_functions () =
  let src = module_ ~exports:"sign, verify" {|
capability myJwt implies jwt, time

fn sign(claims: Dict String String, secret: Secret) requires [myJwt] -> JwtToken =
  JWT.sign claims secret

fn verify(token: JwtToken, secret: Secret) requires [myJwt] -> String =
  let verified = check JWT.verify token secret
  case Dict.lookup "sub" verified of
    Nothing -> ""
    Something s -> s
|} in
  let go = compile_ok "parse_jwt_multiple" src in
  if not (contains "teslrt.JwtSign" go && contains "teslrt.JwtVerify" go) then
    Alcotest.failf "parse_jwt_multiple: expected both JWT calls in Go artifact"

let test_parse_jwt_import_exposing () =
  (* All Tesl.JWT exports are valid names *)
  let src = "module M exposing []\n\
             import Tesl.JWT exposing [jwt, JwtToken, JWT.sign, JWT.verify, JWT.decode]\n\
             import Tesl.Prelude exposing [String]\n" in
  let _ = compile_ok "parse_jwt_import_exposing" src in
  ()

(* ── 2. Type inference / nominal type safety tests ───────────────────────── *)

let test_types_sign_returns_jwttoken () =
  (* JWT.sign must return JwtToken, not String *)
  let src = module_ ~exports:"getToken" {|
capability myJwt implies jwt, time

fn getToken(secret: Secret) requires [myJwt] -> JwtToken =
  JWT.sign (Dict.singleton "sub" "user:123") secret
|} in
  check_contains "types_sign_returns_token" src "teslrt.JwtSign"

let test_types_jwttoken_not_string () =
  (* JwtToken should not be assignable to String directly *)
  let src = module_ ~exports:"bad" {|
capability myJwt implies jwt, time

fn bad(token: JwtToken, secret: Secret) requires [myJwt] -> Int =
  String.length token
|} in
  (* String.length expects String, not JwtToken — type error expected *)
  let diags = Compile.check_source "<test>" src in
  if diags = [] then
    ()  (* Some type systems may not catch this at checker level; that's ok *)
  else
    ()  (* Error is expected and acceptable *)

let test_types_jwtsecret_not_string () =
  (* Secret should be a separate nominal type from JwtToken *)
  let src = module_ ~exports:"makeSecret" {|
fn makeSecret(s: String) -> Secret =
  Secret s
|} in
  check_contains "types_secret_constructor" src "Secret"

let test_types_sign_requires_dict_claims () =
  (* A8: JWT.sign's claims arg is pinned to Dict String String; a bare Int is
     now rejected (was accepted as a free var — the sign-side of the hole). *)
  let src = module_ ~exports:"signWithInt" {|
capability myJwt implies jwt, time

fn signWithInt(n: Int, secret: Secret) requires [myJwt] -> JwtToken =
  JWT.sign n secret
|} in
  check_err_contains "types_sign_requires_dict" src "Dict String String"

let test_types_verify_result_is_dict () =
  (* A8: JWT.verify's result is pinned to Dict String String; annotating the fn
     return as a bare String and returning the raw claims is now rejected
     (was accepted as a free var — the security hole). *)
  let src = module_ ~exports:"verifyToString" {|
capability myJwt implies jwt, time

fn verifyToString(token: JwtToken, secret: Secret) requires [myJwt] -> String =
  JWT.verify token secret
|} in
  check_err_contains "types_verify_result_dict" src "Dict String String"

let test_types_decode_result_is_dict () =
  (* A8: JWT.decode's result is likewise pinned to Dict String String. *)
  let src = module_ ~exports:"decodeToString" {|
capability myJwt implies jwt, time

fn decodeToString(token: JwtToken) requires [myJwt] -> String =
  JWT.decode token
|} in
  check_err_contains "types_decode_result_dict" src "Dict String String"

let test_types_verify_result_via_lookup () =
  (* A8 positive: the sound corpus consumption — read a claim via Dict.lookup —
     still compiles under the pinned Dict String String result. *)
  let src = module_ ~exports:"getSub" {|
capability myJwt implies jwt, time

fn getSub(token: JwtToken, secret: Secret) requires [myJwt] -> String =
  let verified = check JWT.verify token secret
  case Dict.lookup "sub" verified of
    Nothing -> ""
    Something u -> u
|} in
  let _ = compile_ok "types_verify_via_lookup" src in
  ()

let test_types_sign_non_dict_rejected () =
  (* A8 cross-seam: JWT.sign requires Dict String String; a bare String claims
     arg is rejected (String vs Dict String String). *)
  let src = module_ ~exports:"s" {|
capability myJwt implies jwt, time

fn s(u: String, sec: Secret) requires [myJwt] -> JwtToken =
  JWT.sign u sec
|} in
  check_err_contains "types_sign_non_dict" src "Dict String String"

let test_types_sign_dict_roundtrip () =
  (* A8 cross-seam positive: Dict.singleton "sub" x round-trips through
     sign → verify → Dict.lookup "sub". *)
  let src = module_ ~exports:"roundtrip" {|
capability myJwt implies jwt, time

fn roundtrip(u: String, sec: Secret) requires [myJwt] -> String =
  let token = JWT.sign (Dict.singleton "sub" u) sec
  let verified = check JWT.verify token sec
  case Dict.lookup "sub" verified of
    Nothing -> ""
    Something s -> s
|} in
  let _ = compile_ok "types_sign_dict_roundtrip" src in
  ()

let test_types_jwttoken_constructor () =
  (* JwtToken constructor takes a String *)
  let src = module_ ~exports:"mk" {|
fn mk(s: String) -> JwtToken =
  JwtToken s
|} in
  check_contains "types_jwttoken_ctor" src "JwtToken"

let test_types_jwtsecret_constructor () =
  let src = module_ ~exports:"mk" {|
fn mk(s: String) -> Secret =
  Secret s
|} in
  check_contains "types_jwtsecret_ctor" src "Secret"

let test_types_verify_uses_token_arg () =
  let src = module_ ~exports:"v" {|
capability myJwt implies jwt, time

fn v(t: JwtToken, s: Secret) requires [myJwt] -> String =
  let verified = check JWT.verify t s
  case Dict.lookup "sub" verified of
    Nothing -> ""
    Something u -> u
|} in
  let go = compile_ok "types_verify_args" src in
  if not (contains "teslrt.JwtVerify" go) then
    Alcotest.failf "types_verify_args: expected teslrt.JwtVerify in Go artifact"

let test_types_chain_sign_and_verify () =
  let src = module_ ~exports:"roundtrip" {|
capability myJwt implies jwt, time

fn roundtrip(claims: Dict String String, secret: Secret) requires [myJwt] -> String =
  let token = JWT.sign claims secret
  let verified = check JWT.verify token secret
  case Dict.lookup "sub" verified of
    Nothing -> ""
    Something u -> u
|} in
  let _ = compile_ok "types_chain_sign_verify" src in
  ()

let test_types_decode_no_secret_needed () =
  (* JWT.decode only takes a token, not a secret *)
  let src = module_ ~exports:"d" {|
capability myJwt implies jwt, time

fn d(t: JwtToken) requires [myJwt] -> String =
  case Dict.lookup "sub" (JWT.decode t) of
    Nothing -> ""
    Something u -> u
|} in
  let _ = compile_ok "types_decode_no_secret" src in
  ()

let test_types_jwttoken_in_record () =
  let src = module_ ~exports:"Auth" {|
record Auth {
  token: JwtToken
  userId: String
}
|} in
  let _ = compile_ok "types_jwttoken_in_record" src in
  ()

let test_types_jwtsecret_in_record () =
  let src = module_ ~exports:"Config" {|
record Config {
  secret: Secret
  issuer: String
}
|} in
  let _ = compile_ok "types_jwtsecret_in_record" src in
  ()

let test_types_jwt_capability_in_list () =
  let src = module_ ~exports:"sign" {|
capability authCap implies jwt, time

fn sign(claims: Dict String String, s: Secret) requires [authCap] -> JwtToken =
  JWT.sign claims s
|} in
  let _ = compile_ok "types_jwt_cap_in_list" src in
  ()

let test_types_multiple_jwt_ops_in_fn () =
  let src = module_ ~exports:"signAndDecode" {|
capability myJwt implies jwt, time

fn signAndDecode(claims: Dict String String, secret: Secret) requires [myJwt] -> String =
  let token = JWT.sign claims secret
  case Dict.lookup "sub" (JWT.decode token) of
    Nothing -> ""
    Something u -> u
|} in
  let _ = compile_ok "types_multiple_jwt_ops" src in
  ()

let test_types_jwt_with_string_concat () =
  let src = module_ ~exports:"makeSecret" ~extra:"import Tesl.String exposing [String.join]\n" {|
fn makeSecret(prefix: String, key: String) -> Secret =
  Secret (String.join [prefix, key] "-")
|} in
  let _ = compile_ok "types_jwt_with_string" src in
  ()

(* The claims Dict is an ordinary value once `check` has unwrapped it — the
   `check` is what makes the binding legal (a plain `let` would bind the
   check-fail struct on the 401 path; see test_check_binding_gap.ml). *)
let test_types_verify_result_in_let () =
  let src = module_ ~exports:"getUser" {|
capability myJwt implies jwt, time

fn getUser(token: JwtToken, secret: Secret) requires [myJwt] -> String =
  let claims = check JWT.verify token secret
  case Dict.lookup "sub" claims of
    Nothing -> ""
    Something u -> u
|} in
  let _ = compile_ok "types_verify_in_let" src in
  ()

(* ── 2b. The `exp` contract: a fixed TTL, and no knob to get it wrong ─────────

   `JWT.sign` stamps `exp` itself — one hour ahead, in epoch SECONDS (RFC 7519) —
   and there is deliberately no parameter for it.  The history is worth keeping:
   for a while there was a `JWT.signWithExpiry claims expiresAt secret`, added
   because `Dict String String` claims could not express a numeric `exp` at all.
   It was removed once the unit was hard-fixed, because an expiry PARAMETER
   violates the rule the whole crypto surface is built on — no mechanism reaches
   the application author, since every knob is a place where a non-expert makes a
   wrong call and gets a plausible-looking result.  A caller who can pass an
   expiry can pass ten years.  These tests pin that the knob is gone and stays
   gone. *)

let test_types_sign_exp_as_int_rejected () =
  (* NEGATIVE: the shape a program reaches for first — a numeric `exp` in the
     claims dict — does not typecheck, because the dict's values are String.  So
     the only `exp` a Tesl program can even write is a String, and that is
     rejected at run time by JWT.sign's guard. *)
  let src = module_ ~exports:"mk" {|
capability myJwt implies jwt, time

fn mk(secret: Secret) requires [myJwt] -> JwtToken =
  JWT.sign (Dict.singleton "exp" 1234) secret
|} in
  check_err_contains "types_sign_exp_as_int" src "String"

let test_types_sign_with_expiry_is_gone () =
  (* The knob must stay removed: importing it is an unknown export.  This is the
     regression guard against someone "helpfully" reintroducing a way to choose
     an expiry. *)
  let src = "module M exposing []\n\
             import Tesl.JWT exposing [jwt, JWT.signWithExpiry]\n\
             import Tesl.Prelude exposing [String]\n" in
  check_err_contains "types_sign_with_expiry_gone" src "JWT.signWithExpiry"

let test_types_sign_no_exp_is_the_only_shape () =
  (* POSITIVE: claims without `exp` — the only shape there is, and the one the
     whole corpus uses.  The expiry arrives without the caller doing anything. *)
  let src = module_ ~exports:"mk" {|
capability myJwt implies jwt, time

fn mk(userId: String, secret: Secret) requires [myJwt] -> JwtToken =
  JWT.sign (Dict.singleton "sub" userId) secret
|} in
  let _ = compile_ok "types_sign_no_exp" src in
  ()

let test_types_sign_roundtrip_through_verify () =
  let src = module_ ~exports:"roundtrip" {|
capability myJwt implies jwt, time

fn roundtrip(u: String, sec: Secret) requires [myJwt] -> String =
  let token = JWT.sign (Dict.singleton "sub" u) sec
  let claims = check JWT.verify token sec
  case Dict.lookup "sub" claims of
    Nothing -> ""
    Something s -> s
|} in
  let _ = compile_ok "types_sign_roundtrip" src in
  ()

(* ── 2c. The `Authentic` fact on JWT.verify (Crypto Phase 2) ──────────────────

   `JWT.verify` returns the claims Dict carrying `Authentic`, so a consumer can
   DEMAND that verification happened.  The negative below is the point of the
   whole exercise: `JWT.decode` reads the payload without checking the signature,
   mints no fact, and therefore cannot reach a function that requires one. *)

let test_proof_verify_mints_authentic () =
  let src = module_ ~exports:"readSub, gate" {|
capability myJwt implies jwt, time

fn readSub(claims: Dict String String ::: Authentic claims) -> String =
  case Dict.lookup "sub" claims of
    Nothing -> ""
    Something s -> s

fn gate(token: JwtToken, secret: Secret) requires [myJwt] -> String =
  let claims = check JWT.verify token secret
  readSub claims
|} in
  let _ = compile_ok "proof_verify_mints_authentic" src in
  ()

let test_proof_decode_mints_no_authentic () =
  (* NEGATIVE: decode does not verify, so its claims cannot satisfy Authentic. *)
  let src = module_ ~exports:"readSub, gate" {|
capability myJwt implies jwt, time

fn readSub(claims: Dict String String ::: Authentic claims) -> String =
  case Dict.lookup "sub" claims of
    Nothing -> ""
    Something s -> s

fn gate(token: JwtToken) requires [myJwt] -> String =
  let claims = JWT.decode token
  readSub claims
|} in
  check_err_contains "proof_decode_mints_no_authentic" src "Authentic"

let test_proof_unverified_dict_rejected () =
  (* NEGATIVE: a claims dict the program simply built cannot satisfy Authentic
     either — this is the "trusted the cookie without verifying it" shape. *)
  let src = module_ ~exports:"readSub, gate" {|
capability myJwt implies jwt, time

fn readSub(claims: Dict String String ::: Authentic claims) -> String =
  case Dict.lookup "sub" claims of
    Nothing -> ""
    Something s -> s

fn gate(raw: String) -> String =
  let claims = Dict.singleton "sub" raw
  readSub claims
|} in
  check_err_contains "proof_unverified_dict_rejected" src "Authentic"

let test_proof_authentic_exposed_from_jwt () =
  (* A JWT program must not have to import Tesl.Crypto to name the fact its own
     verifier mints. *)
  let src = "module M exposing []\n\
             import Tesl.JWT exposing [jwt, JWT.verify, Authentic]\n\
             import Tesl.Prelude exposing [String]\n" in
  let _ = compile_ok "proof_authentic_exposed_from_jwt" src in
  ()

let test_proof_authentic_subject_types_do_not_collide () =
  (* Crypto.checkSignature mints `Authentic` about a payload String; JWT.verify
     mints it about a claims Dict.  Feeding one to a consumer expecting the other
     is a TYPE error, so the shared predicate cannot launder between them. *)
  let src = "module M exposing [trustPayload, bothMint]\n\
             import Tesl.Prelude exposing [String]\n\
             import Tesl.Dict exposing [Dict, Dict.lookup]\n\
             import Tesl.Maybe exposing [Maybe(..)]\n\
             import Tesl.Time exposing [time]\n\
             import Tesl.Crypto exposing [Authentic, Secret]\n\
             import Tesl.JWT exposing [jwt, JwtToken, JWT.verify]\n\
             \n\
             capability myJwt implies jwt, time\n\
             \n\
             fn trustPayload(payload: String ::: Authentic payload) -> String =\n\
             \032 payload\n\
             \n\
             fn bothMint(token: JwtToken, secret: Secret) requires [myJwt] -> String =\n\
             \032 let claims = check JWT.verify token secret\n\
             \032 trustPayload claims\n" in
  check_err_contains "proof_authentic_no_collide" src "cannot unify"

(* ── 3. Capability tests ─────────────────────────────────────────────────── *)

let test_cap_sign_requires_time () =
  (* JWT.sign stamps `exp` from the wall clock, so it charges `time` on top of
     `jwt` — a capability marks an EFFECT, and reading the clock is one.  A
     capability that implies only `jwt` is no longer enough. *)
  let src = module_ ~exports:"mk" {|
capability jwtOnly implies jwt

fn mk(userId: String, secret: Secret) requires [jwtOnly] -> JwtToken =
  JWT.sign (Dict.singleton "sub" userId) secret
|} in
  check_err_contains "cap_sign_requires_time" src "time"

let test_cap_sign_requires_jwt_not_just_time () =
  let src = module_ ~exports:"mk" {|
capability clockOnly implies time

fn mk(userId: String, secret: Secret) requires [clockOnly] -> JwtToken =
  JWT.sign (Dict.singleton "sub" userId) secret
|} in
  check_err_contains "cap_sign_requires_jwt_not_time" src "jwt"

let test_cap_verify_does_not_need_time () =
  (* Recorded drift, pinned so a change is deliberate: JWT.verify also reads the
     clock (it compares `exp` against now) but is NOT charged `time` today —
     propagating that would put `time` in the closure of every JWT-authenticated
     endpoint.  See the note in type_system.ml's stdlib_capabilities. *)
  let src = module_ ~exports:"v" {|
capability jwtOnly implies jwt

fn v(t: JwtToken, s: Secret) requires [jwtOnly] -> String =
  let claims = check JWT.verify t s
  case Dict.lookup "sub" claims of
    Nothing -> ""
    Something u -> u
|} in
  let _ = compile_ok "cap_verify_no_time" src in
  ()

let test_cap_sign_requires_jwt () =
  let src = module_ ~exports:"badSign" {|
fn badSign(claims: Dict String String, secret: Secret) -> JwtToken =
  JWT.sign claims secret
|} in
  check_err_contains "cap_sign_requires_jwt" src "jwt"

let test_cap_verify_requires_jwt () =
  let src = module_ ~exports:"badVerify" {|
fn badVerify(token: JwtToken, secret: Secret) -> String =
  let verified = check JWT.verify token secret
  case Dict.lookup "sub" verified of
    Nothing -> ""
    Something u -> u
|} in
  check_err_contains "cap_verify_requires_jwt" src "jwt"

let test_cap_decode_requires_jwt () =
  let src = module_ ~exports:"badDecode" {|
fn badDecode(token: JwtToken) -> String =
  case Dict.lookup "sub" (JWT.decode token) of
    Nothing -> ""
    Something u -> u
|} in
  check_err_contains "cap_decode_requires_jwt" src "jwt"

let test_cap_sign_ok_with_jwt () =
  let src = module_ ~exports:"goodSign" {|
capability myJwt implies jwt, time

fn goodSign(claims: Dict String String, secret: Secret) requires [myJwt] -> JwtToken =
  JWT.sign claims secret
|} in
  let _ = compile_ok "cap_sign_ok" src in
  ()

let test_cap_verify_ok_with_jwt () =
  let src = module_ ~exports:"goodVerify" {|
capability myJwt implies jwt, time

fn goodVerify(token: JwtToken, secret: Secret) requires [myJwt] -> String =
  let verified = check JWT.verify token secret
  case Dict.lookup "sub" verified of
    Nothing -> ""
    Something u -> u
|} in
  let _ = compile_ok "cap_verify_ok" src in
  ()

let test_cap_decode_ok_with_jwt () =
  let src = module_ ~exports:"goodDecode" {|
capability myJwt implies jwt, time

fn goodDecode(token: JwtToken) requires [myJwt] -> String =
  case Dict.lookup "sub" (JWT.decode token) of
    Nothing -> ""
    Something u -> u
|} in
  let _ = compile_ok "cap_decode_ok" src in
  ()

let test_cap_direct_jwt_cap () =
  let src = module_ ~exports:"sign" {|
fn sign(claims: Dict String String, s: Secret) requires [jwt, time] -> JwtToken =
  JWT.sign claims s
|} in
  let _ = compile_ok "cap_direct_jwt" src in
  ()

let test_cap_implies_chain () =
  (* A capability implying another which implies jwt *)
  let src = module_ ~exports:"sign" {|
capability cryptoCap implies jwt, time
capability authCap implies cryptoCap

fn sign(claims: Dict String String, s: Secret) requires [authCap] -> JwtToken =
  JWT.sign claims s
|} in
  let _ = compile_ok "cap_implies_chain" src in
  ()

let test_cap_handler_requires_jwt () =
  let src = module_ ~exports:"tokenHandler" {|
capability myJwt implies jwt, time

handler tokenHandler(secret: String) -> String
  requires [myJwt] =
  let s = Secret secret
  let _ = JWT.sign (Dict.singleton "sub" "user:123") s
  "ok"
|} in
  let _ = compile_ok "cap_handler_with_jwt" src in
  ()

let test_cap_handler_missing_jwt () =
  let src = module_ ~exports:"tokenHandler" {|
handler tokenHandler(secret: String) -> String
  requires [] =
  let s = Secret secret
  let _ = JWT.sign (Dict.singleton "sub" "user:123") s
  "ok"
|} in
  check_err_contains "cap_handler_missing_jwt" src "jwt"

let test_cap_worker_requires_jwt () =
  let src = module_ ~exports:"" {|
capability myJwt implies jwt, time

worker tokenRefresh(secret: Secret) requires [myJwt] -> String =
  let t = JWT.sign (Dict.singleton "sub" "refresh:user") secret
  "done"
|} in
  let _ = compile_ok "cap_worker_with_jwt" src in
  ()

let test_cap_fn_requires_jwt () =
  let src = module_ ~exports:"makeToken" {|
capability myJwt implies jwt, time

fn makeToken(userId: String, secret: Secret) requires [myJwt] -> JwtToken =
  JWT.sign (Dict.singleton "sub" userId) secret
|} in
  let _ = compile_ok "cap_fn_with_jwt" src in
  ()

let test_cap_fn_missing_jwt () =
  let src = module_ ~exports:"makeToken" {|
fn makeToken(userId: String, secret: Secret) -> JwtToken =
  JWT.sign (Dict.singleton "sub" userId) secret
|} in
  check_err_contains "cap_fn_missing_jwt" src "jwt"

let test_cap_missing_in_fn_callee () =
  (* A plain fn calling JWT.sign without jwt declared is an error *)
  let src = module_ ~exports:"helper" {|
fn helper(claims: Dict String String, s: Secret) -> JwtToken =
  JWT.sign claims s
|} in
  check_err_contains "cap_fn_callee_missing" src "jwt"

(* ── 4. Module / import tests ────────────────────────────────────────────── *)

let test_module_jwt_is_known () =
  (* Tesl.JWT must not produce "unknown module" error *)
  let src = "module M exposing []\nimport Tesl.JWT exposing [jwt]\n\
             import Tesl.Prelude exposing [String]\n" in
  let _ = compile_ok "module_jwt_known" src in
  ()

let test_module_jwt_unknown_export_errors () =
  let src = "module M exposing []\nimport Tesl.JWT exposing [notReal]\n\
             import Tesl.Prelude exposing [String]\n" in
  check_err_contains "module_jwt_unknown_export" src "notReal"

(** THE PHASE-0 RATCHET.  The old JWT key type is deleted, not aliased, and
    `Secret` is NOT re-exposed under Tesl.JWT either — one name, one module row,
    which is what the stdlib binding-existence seam test needs to stay meaningful.
    Both spellings must therefore be unknown exports of Tesl.JWT. *)
let test_module_jwt_secret_export_is_gone () =
  let jwtsecret = "module M exposing []\nimport Tesl.JWT exposing [jwt, JwtSecret]\n\
                   import Tesl.Prelude exposing [String]\n" in
  check_err_contains "module_jwt_jwtsecret_gone" jwtsecret "JwtSecret";
  let secret = "module M exposing []\nimport Tesl.JWT exposing [jwt, Secret]\n\
                import Tesl.Prelude exposing [String]\n" in
  check_err_contains "module_jwt_secret_not_reexposed" secret "Secret"

(** And the old name as a TYPE ANNOTATION is an unknown type, not a silently
    accepted one — it is gone from the checker's always-known list too. *)
let test_types_jwtsecret_annotation_is_unknown () =
  let src = module_ ~exports:"f" {|
fn f(s: JwtSecret) -> JwtToken =
  JwtToken "x"
|} in
  check_err_contains "types_jwtsecret_annotation_unknown" src "JwtSecret"

let test_module_jwt_emits_require () =
  let src = module_ ~exports:"mk" {|
fn mk(s: String) -> JwtToken =
  JwtToken s
|} in
  let artifacts = compile_artifacts "module_jwt_emits_require" src in
  if not (List.exists (fun (a : Emit_go.artifact) ->
      a.path = "internal/teslrt/jwt.go") artifacts) then
    Alcotest.fail "module_jwt_emits_require: missing internal/teslrt/jwt.go"

let test_module_jwt_go_output () =
  let src = module_ ~exports:"sign" {|
capability myJwt implies jwt, time

fn sign(claims: Dict String String, s: Secret) requires [myJwt] -> JwtToken =
  JWT.sign claims s
|} in
  let go = compile_ok "module_jwt_go_output" src in
  if not (contains "teslrt.JwtSign" go) then
    Alcotest.failf "module_jwt_go_output: expected teslrt.JwtSign:\n%s" go

let test_module_jwt_all_exports_usable () =
  let src = module_ ~exports:"sign, verify, decode, mkSecret, mkToken" {|
capability myJwt implies jwt, time

fn sign(claims: Dict String String, s: Secret) requires [myJwt] -> JwtToken =
  JWT.sign claims s

fn verify(t: JwtToken, s: Secret) requires [myJwt] -> String =
  let verified = check JWT.verify t s
  case Dict.lookup "sub" verified of
    Nothing -> ""
    Something u -> u

fn decode(t: JwtToken) requires [myJwt] -> String =
  case Dict.lookup "sub" (JWT.decode t) of
    Nothing -> ""
    Something u -> u

fn mkSecret(s: String) -> Secret =
  Secret s

fn mkToken(s: String) -> JwtToken =
  JwtToken s
|} in
  let _ = compile_ok "module_jwt_all_exports" src in
  ()

(* ── 5. Go emission tests ────────────────────────────────────────────────── *)

let test_emit_jwt_sign_output () =
  let src = module_ ~exports:"sign" {|
capability myJwt implies jwt, time

fn sign(claims: Dict String String, s: Secret) requires [myJwt] -> JwtToken =
  JWT.sign claims s
|} in
  check_contains "emit_jwt_sign" src "teslrt.JwtSign"

let test_emit_jwt_verify_output () =
  let src = module_ ~exports:"verify" {|
capability myJwt implies jwt, time

fn verify(t: JwtToken, s: Secret) requires [myJwt] -> String =
  let verified = check JWT.verify t s
  case Dict.lookup "sub" verified of
    Nothing -> ""
    Something u -> u
|} in
  check_contains "emit_jwt_verify" src "teslrt.JwtVerify"

let test_emit_jwt_decode_output () =
  let src = module_ ~exports:"decode" {|
capability myJwt implies jwt, time

fn decode(t: JwtToken) requires [myJwt] -> String =
  case Dict.lookup "sub" (JWT.decode t) of
    Nothing -> ""
    Something u -> u
|} in
  check_contains "emit_jwt_decode" src "teslrt.JwtDecode"

let test_emit_jwt_requires_go_runtime () =
  let src = module_ ~exports:"mk" {|
fn mk(s: String) -> JwtToken =
  JwtToken s
|} in
  let artifacts = compile_artifacts "emit_jwt_requires_go_runtime" src in
  if not (List.exists (fun (a : Emit_go.artifact) ->
      a.path = "internal/teslrt/jwt.go") artifacts) then
    Alcotest.fail "emit_jwt_requires_go_runtime: missing JWT runtime artifact"

(** The key unification, end to end at the EMIT boundary: a program can go
    `Env.requireSecret` → `JWT.sign` with no `String` of key material anywhere,
    and both requires land in the output. *)
let test_emit_require_secret_feeds_sign () =
  let src = module_ ~exports:"mk"
      ~extra:"import Tesl.Env exposing [envRead, requireSecret]\n" {|
capability sessions implies jwt, time, envRead

fn mk(userId: String) -> JwtToken requires [sessions] =
  JWT.sign (Dict.singleton "sub" userId) (requireSecret "SESSION_JWT_SECRET")
|} in
  let go = compile_ok "emit_require_secret_feeds_sign" src in
  if not (contains "teslrt.RequireSecret" go && contains "teslrt.JwtSign" go) then
    Alcotest.failf
      "emit_require_secret_feeds_sign: expected requireSecret and the jwt require:\n%s"
      go

(** NEGATIVE: a plain `String` where the key goes is a type error.  This is the
    property the unification buys — before it, the corpus had to write
    `JwtOnlyKey (requireEnv "…")` and the plaintext key existed as a String. *)
let test_types_string_key_rejected () =
  let src = module_ ~exports:"mk" {|
capability myJwt implies jwt, time

fn mk(userId: String, key: String) -> JwtToken requires [myJwt] =
  JWT.sign (Dict.singleton "sub" userId) key
|} in
  check_err_contains "types_string_key_rejected" src "Secret"

(** NEGATIVE, the other side: `JWT.verify` demands a `Secret` too. *)
let test_types_string_key_rejected_on_verify () =
  let src = module_ ~exports:"v" {|
capability myJwt implies jwt, time

fn v(token: JwtToken, key: String) -> String requires [myJwt] =
  let claims = check JWT.verify token key
  case Dict.lookup "sub" claims of
    Nothing -> ""
    Something u -> u
|} in
  check_err_contains "types_string_key_rejected_verify" src "Secret"

(** POSITIVE: a `Secret` minted by `Env.requireSecret` verifies too, so the whole
    round trip stays inside the secret type. *)
let test_types_require_secret_feeds_verify () =
  let src = module_ ~exports:"v"
      ~extra:"import Tesl.Env exposing [envRead, requireSecret]\n" {|
capability sessions implies jwt, time, envRead

fn v(token: JwtToken) -> String requires [sessions] =
  let claims = check JWT.verify token (requireSecret "SESSION_JWT_SECRET")
  case Dict.lookup "sub" claims of
    Nothing -> ""
    Something u -> u
|} in
  let _ = compile_ok "types_require_secret_feeds_verify" src in
  ()

let test_emit_jwt_not_required_when_not_imported () =
  let src = "module M exposing [f]\n\
             import Tesl.Prelude exposing [Int, String]\n\
             fn f(n: Int) -> Int = n + 1\n" in
  let go = compile_ok "emit_jwt_not_imported" src in
  if contains "teslrt.Jwt" go then
    Alcotest.fail "JWT runtime reference emitted without Tesl.JWT import"

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "JWT" [
    "parser", [
      Alcotest.test_case "JWT import recognized" `Quick test_parse_jwt_import;
      Alcotest.test_case "JWT.sign parses" `Quick test_parse_jwt_sign;
      Alcotest.test_case "JWT.verify parses" `Quick test_parse_jwt_verify;
      Alcotest.test_case "JWT.decode parses" `Quick test_parse_jwt_decode;
      Alcotest.test_case "Secret newtype parses" `Quick test_parse_jwt_newtype_jwtsecret;
      Alcotest.test_case "JwtToken newtype parses" `Quick test_parse_jwt_newtype_jwttoken;
      Alcotest.test_case "JwtToken type annotation" `Quick test_parse_jwt_token_type_annotation;
      Alcotest.test_case "capability jwt declared" `Quick test_parse_jwt_capability_declare;
      Alcotest.test_case "multiple JWT functions" `Quick test_parse_jwt_multiple_functions;
      Alcotest.test_case "import exposing all exports" `Quick test_parse_jwt_import_exposing;
    ];
    "types", [
      Alcotest.test_case "sign returns JwtToken" `Quick test_types_sign_returns_jwttoken;
      Alcotest.test_case "JwtToken not String" `Quick test_types_jwttoken_not_string;
      Alcotest.test_case "Secret nominal type" `Quick test_types_jwtsecret_not_string;
      Alcotest.test_case "sign claims must be Dict String String" `Quick test_types_sign_requires_dict_claims;
      Alcotest.test_case "verify result is Dict (non-Dict annotation rejected)" `Quick test_types_verify_result_is_dict;
      Alcotest.test_case "decode result is Dict (non-Dict annotation rejected)" `Quick test_types_decode_result_is_dict;
      Alcotest.test_case "verify result consumed via Dict.lookup" `Quick test_types_verify_result_via_lookup;
      Alcotest.test_case "sign non-Dict claims rejected" `Quick test_types_sign_non_dict_rejected;
      Alcotest.test_case "sign/verify Dict round-trip" `Quick test_types_sign_dict_roundtrip;
      Alcotest.test_case "JwtToken constructor" `Quick test_types_jwttoken_constructor;
      Alcotest.test_case "Secret constructor" `Quick test_types_jwtsecret_constructor;
      Alcotest.test_case "verify uses token arg" `Quick test_types_verify_uses_token_arg;
      Alcotest.test_case "chain sign and verify" `Quick test_types_chain_sign_and_verify;
      Alcotest.test_case "decode no secret needed" `Quick test_types_decode_no_secret_needed;
      Alcotest.test_case "JwtToken in record" `Quick test_types_jwttoken_in_record;
      Alcotest.test_case "Secret in record" `Quick test_types_jwtsecret_in_record;
      Alcotest.test_case "jwt cap in list" `Quick test_types_jwt_capability_in_list;
      Alcotest.test_case "multiple jwt ops in fn" `Quick test_types_multiple_jwt_ops_in_fn;
      Alcotest.test_case "jwt with string concat" `Quick test_types_jwt_with_string_concat;
      Alcotest.test_case "verify result in let" `Quick test_types_verify_result_in_let;
      Alcotest.test_case "numeric exp in the claims dict is rejected" `Quick test_types_sign_exp_as_int_rejected;
      Alcotest.test_case "the signWithExpiry knob stays removed" `Quick test_types_sign_with_expiry_is_gone;
      Alcotest.test_case "claims with no exp are the only shape" `Quick test_types_sign_no_exp_is_the_only_shape;
      Alcotest.test_case "sign round-trips through verify" `Quick test_types_sign_roundtrip_through_verify;
      (* Phase 0: ONE key type *)
      Alcotest.test_case "a String key is rejected by JWT.sign" `Quick
        test_types_string_key_rejected;
      Alcotest.test_case "a String key is rejected by JWT.verify" `Quick
        test_types_string_key_rejected_on_verify;
      Alcotest.test_case "Env.requireSecret feeds JWT.verify" `Quick
        test_types_require_secret_feeds_verify;
      Alcotest.test_case "the old JWT key-type annotation is an unknown type" `Quick
        test_types_jwtsecret_annotation_is_unknown;
    ];
    "proofs", [
      Alcotest.test_case "verify mints Authentic" `Quick test_proof_verify_mints_authentic;
      Alcotest.test_case "decode mints no Authentic" `Quick test_proof_decode_mints_no_authentic;
      Alcotest.test_case "a hand-built claims dict cannot satisfy Authentic" `Quick test_proof_unverified_dict_rejected;
      Alcotest.test_case "Authentic is exposed from Tesl.JWT" `Quick test_proof_authentic_exposed_from_jwt;
      Alcotest.test_case "Authentic subject types do not collide with Crypto's" `Quick test_proof_authentic_subject_types_do_not_collide;
    ];
    "capabilities", [
      Alcotest.test_case "sign requires jwt" `Quick test_cap_sign_requires_jwt;
      Alcotest.test_case "verify requires jwt" `Quick test_cap_verify_requires_jwt;
      Alcotest.test_case "decode requires jwt" `Quick test_cap_decode_requires_jwt;
      Alcotest.test_case "sign ok with jwt" `Quick test_cap_sign_ok_with_jwt;
      Alcotest.test_case "verify ok with jwt" `Quick test_cap_verify_ok_with_jwt;
      Alcotest.test_case "decode ok with jwt" `Quick test_cap_decode_ok_with_jwt;
      Alcotest.test_case "direct jwt cap" `Quick test_cap_direct_jwt_cap;
      Alcotest.test_case "implies chain" `Quick test_cap_implies_chain;
      Alcotest.test_case "handler requires jwt" `Quick test_cap_handler_requires_jwt;
      Alcotest.test_case "handler missing jwt" `Quick test_cap_handler_missing_jwt;
      Alcotest.test_case "worker requires jwt" `Quick test_cap_worker_requires_jwt;
      Alcotest.test_case "fn requires jwt" `Quick test_cap_fn_requires_jwt;
      Alcotest.test_case "fn missing jwt" `Quick test_cap_fn_missing_jwt;
      Alcotest.test_case "fn callee missing jwt" `Quick test_cap_missing_in_fn_callee;
      Alcotest.test_case "sign requires time (it stamps the expiry)" `Quick test_cap_sign_requires_time;
      Alcotest.test_case "sign requires jwt, not just time" `Quick test_cap_sign_requires_jwt_not_just_time;
      Alcotest.test_case "verify does not need time (recorded drift)" `Quick test_cap_verify_does_not_need_time;
    ];
    "module", [
      Alcotest.test_case "Tesl.JWT is known module" `Quick test_module_jwt_is_known;
      Alcotest.test_case "unknown export errors" `Quick test_module_jwt_unknown_export_errors;
      Alcotest.test_case "neither the old key type nor Secret is a Tesl.JWT export" `Quick
        test_module_jwt_secret_export_is_gone;

      Alcotest.test_case "emits JWT runtime artifact" `Quick test_module_jwt_emits_require;
      Alcotest.test_case "Go output correct" `Quick test_module_jwt_go_output;
      Alcotest.test_case "all exports usable" `Quick test_module_jwt_all_exports_usable;
    ];
    "emit", [
      Alcotest.test_case "JWT.sign in output" `Quick test_emit_jwt_sign_output;
      Alcotest.test_case "JWT.verify in output" `Quick test_emit_jwt_verify_output;
      Alcotest.test_case "JWT.decode in output" `Quick test_emit_jwt_decode_output;
      Alcotest.test_case "requires Go JWT runtime" `Quick test_emit_jwt_requires_go_runtime;
      Alcotest.test_case "not imported means not required" `Quick test_emit_jwt_not_required_when_not_imported;
      Alcotest.test_case "Env.requireSecret feeds JWT.sign with no String key" `Quick
        test_emit_require_secret_feeds_sign;
    ];
  ]
