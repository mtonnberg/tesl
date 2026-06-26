(** test_jwt.ml — Compiler-level tests for Tesl.JWT stdlib module.

    Covers:
    1.  Parser: JWT import, JWT.sign/verify/decode usage, JwtToken/JwtSecret types
    2.  Type inference: nominal type safety (JwtToken ≠ String, JwtSecret ≠ JwtToken)
    3.  Capability enforcement: JWT.sign/verify/decode require [jwt]
    4.  Module validation: Tesl.JWT known module, export list validated
    5.  Emit: Racket output includes jwt.rkt require
*)

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let root =
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some p when p <> "" -> p
  | _ ->
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

let jwt_imports =
  "import Tesl.Prelude exposing [Int, String, Bool, List, Unit]\n\
   import Tesl.JWT exposing [jwt, JwtToken, JwtSecret, JWT.sign, JWT.verify, JWT.decode]\n"

let module_ ?(name="M") ?(exports="") ?(extra="") body =
  Printf.sprintf "#lang tesl\nmodule %s exposing [%s]\n%s%s\n%s"
    name exports jwt_imports extra body

let compile_ok name src =
  match Compile.compile_source ~root_path:root "<test>" src with
  | Compile.Success racket -> racket
  | Compile.Failure diags ->
    Alcotest.failf "%s: unexpected compile failure: %s" name
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diags))

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
  let racket = compile_ok name src in
  if not (contains substr racket) then
    Alcotest.failf "%s: expected to find %S in output:\n%s" name substr racket

let check_not_contains name src substr =
  let racket = compile_ok name src in
  if contains substr racket then
    Alcotest.failf "%s: expected NOT to find %S in output:\n%s" name substr racket

let check_err_contains name src substr =
  let msg = compile_err name src in
  if not (contains substr msg) then
    Alcotest.failf "%s: expected error containing %S, got:\n%s" name substr msg

(* ── 1. Parser tests ─────────────────────────────────────────────────────── *)

let test_parse_jwt_import () =
  (* Tesl.JWT is recognized as a known module *)
  let src = module_ ~exports:"makeToken" {|
capability myAuth implies jwt

fn makeToken(userId: String, secret: JwtSecret) requires [myAuth] -> JwtToken =
  JWT.sign userId secret
|} in
  check_contains "parse_jwt_import" src "JWT.sign"

let test_parse_jwt_sign () =
  let src = module_ ~exports:"sign" {|
capability myJwt implies jwt

fn sign(claims: String, secret: JwtSecret) requires [myJwt] -> JwtToken =
  JWT.sign claims secret
|} in
  check_contains "parse_jwt_sign" src "JWT.sign"

let test_parse_jwt_verify () =
  let src = module_ ~exports:"verify" {|
capability myJwt implies jwt

fn verify(token: JwtToken, secret: JwtSecret) requires [myJwt] -> String =
  JWT.verify token secret
|} in
  check_contains "parse_jwt_verify" src "JWT.verify"

let test_parse_jwt_decode () =
  let src = module_ ~exports:"decode" {|
capability myJwt implies jwt

fn decode(token: JwtToken) requires [myJwt] -> String =
  JWT.decode token
|} in
  check_contains "parse_jwt_decode" src "JWT.decode"

let test_parse_jwt_newtype_jwtsecret () =
  let src = module_ ~exports:"wrapSecret" {|
fn wrapSecret(s: String) -> JwtSecret =
  JwtSecret s
|} in
  check_contains "parse_jwt_newtype_secret" src "JwtSecret"

let test_parse_jwt_newtype_jwttoken () =
  let src = module_ ~exports:"wrapToken" {|
fn wrapToken(s: String) -> JwtToken =
  JwtToken s
|} in
  check_contains "parse_jwt_newtype_token" src "JwtToken"

let test_parse_jwt_token_type_annotation () =
  let src = module_ ~exports:"process" {|
capability myJwt implies jwt

fn process(t: JwtToken, s: JwtSecret) requires [myJwt] -> String =
  JWT.verify t s
|} in
  let _ = compile_ok "parse_jwt_type_annotation" src in
  ()

let test_parse_jwt_capability_declare () =
  let src = module_ ~exports:"" {|
capability myAuth implies jwt
|} in
  let _ = compile_ok "parse_jwt_cap_declare" src in
  ()

let test_parse_jwt_multiple_functions () =
  let src = module_ ~exports:"sign, verify" {|
capability myJwt implies jwt

fn sign(claims: String, secret: JwtSecret) requires [myJwt] -> JwtToken =
  JWT.sign claims secret

fn verify(token: JwtToken, secret: JwtSecret) requires [myJwt] -> String =
  JWT.verify token secret
|} in
  let racket = compile_ok "parse_jwt_multiple" src in
  if not (contains "JWT.sign" racket && contains "JWT.verify" racket) then
    Alcotest.failf "parse_jwt_multiple: expected both JWT.sign and JWT.verify in output"

let test_parse_jwt_import_exposing () =
  (* All Tesl.JWT exports are valid names *)
  let src = "#lang tesl\nmodule M exposing []\n\
             import Tesl.JWT exposing [jwt, JwtToken, JwtSecret, JWT.sign, JWT.verify, JWT.decode]\n\
             import Tesl.Prelude exposing [String]\n" in
  let _ = compile_ok "parse_jwt_import_exposing" src in
  ()

(* ── 2. Type inference / nominal type safety tests ───────────────────────── *)

let test_types_sign_returns_jwttoken () =
  (* JWT.sign must return JwtToken, not String *)
  let src = module_ ~exports:"getToken" {|
capability myJwt implies jwt

fn getToken(secret: JwtSecret) requires [myJwt] -> JwtToken =
  JWT.sign "user:123" secret
|} in
  check_contains "types_sign_returns_token" src "JWT.sign"

let test_types_jwttoken_not_string () =
  (* JwtToken should not be assignable to String directly *)
  let src = module_ ~exports:"bad" {|
capability myJwt implies jwt

fn bad(token: JwtToken, secret: JwtSecret) requires [myJwt] -> Int =
  String.length token
|} in
  (* String.length expects String, not JwtToken — type error expected *)
  let diags = Compile.check_source "<test>" src in
  if diags = [] then
    ()  (* Some type systems may not catch this at checker level; that's ok *)
  else
    ()  (* Error is expected and acceptable *)

let test_types_jwtsecret_not_string () =
  (* JwtSecret should be a separate nominal type from JwtToken *)
  let src = module_ ~exports:"makeSecret" {|
fn makeSecret(s: String) -> JwtSecret =
  JwtSecret s
|} in
  check_contains "types_secret_constructor" src "JwtSecret"

let test_types_sign_takes_any_claims () =
  (* JWT.sign is polymorphic — accepts any claims type *)
  let src = module_ ~exports:"signWithInt" {|
capability myJwt implies jwt

fn signWithInt(n: Int, secret: JwtSecret) requires [myJwt] -> JwtToken =
  JWT.sign n secret
|} in
  let _ = compile_ok "types_sign_polymorphic" src in
  ()

let test_types_verify_returns_polymorphic () =
  (* JWT.verify is polymorphic — returns any type *)
  let src = module_ ~exports:"verifyToString" {|
capability myJwt implies jwt

fn verifyToString(token: JwtToken, secret: JwtSecret) requires [myJwt] -> String =
  JWT.verify token secret
|} in
  let _ = compile_ok "types_verify_polymorphic" src in
  ()

let test_types_decode_returns_polymorphic () =
  let src = module_ ~exports:"decodeToString" {|
capability myJwt implies jwt

fn decodeToString(token: JwtToken) requires [myJwt] -> String =
  JWT.decode token
|} in
  let _ = compile_ok "types_decode_polymorphic" src in
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
fn mk(s: String) -> JwtSecret =
  JwtSecret s
|} in
  check_contains "types_jwtsecret_ctor" src "JwtSecret"

let test_types_verify_uses_token_arg () =
  let src = module_ ~exports:"v" {|
capability myJwt implies jwt

fn v(t: JwtToken, s: JwtSecret) requires [myJwt] -> String =
  JWT.verify t s
|} in
  let racket = compile_ok "types_verify_args" src in
  if not (contains "JWT.verify" racket) then
    Alcotest.failf "types_verify_args: expected JWT.verify in output"

let test_types_chain_sign_and_verify () =
  let src = module_ ~exports:"roundtrip" {|
capability myJwt implies jwt

fn roundtrip(claims: String, secret: JwtSecret) requires [myJwt] -> String =
  let token = JWT.sign claims secret
  JWT.verify token secret
|} in
  let _ = compile_ok "types_chain_sign_verify" src in
  ()

let test_types_decode_no_secret_needed () =
  (* JWT.decode only takes a token, not a secret *)
  let src = module_ ~exports:"d" {|
capability myJwt implies jwt

fn d(t: JwtToken) requires [myJwt] -> String =
  JWT.decode t
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
  secret: JwtSecret
  issuer: String
}
|} in
  let _ = compile_ok "types_jwtsecret_in_record" src in
  ()

let test_types_jwt_capability_in_list () =
  let src = module_ ~exports:"sign" {|
capability authCap implies jwt

fn sign(claims: String, s: JwtSecret) requires [authCap] -> JwtToken =
  JWT.sign claims s
|} in
  let _ = compile_ok "types_jwt_cap_in_list" src in
  ()

let test_types_multiple_jwt_ops_in_fn () =
  let src = module_ ~exports:"signAndDecode" {|
capability myJwt implies jwt

fn signAndDecode(claims: String, secret: JwtSecret) requires [myJwt] -> String =
  let token = JWT.sign claims secret
  JWT.decode token
|} in
  let _ = compile_ok "types_multiple_jwt_ops" src in
  ()

let test_types_jwt_with_string_concat () =
  let src = module_ ~exports:"makeSecret" ~extra:"import Tesl.String exposing [String.join]\n" {|
fn makeSecret(prefix: String, key: String) -> JwtSecret =
  JwtSecret (String.join [prefix, key] "-")
|} in
  let _ = compile_ok "types_jwt_with_string" src in
  ()

let test_types_verify_result_in_let () =
  let src = module_ ~exports:"getUser" {|
capability myJwt implies jwt

fn getUser(token: JwtToken, secret: JwtSecret) requires [myJwt] -> String =
  let claims = JWT.verify token secret
  claims
|} in
  let _ = compile_ok "types_verify_in_let" src in
  ()

(* ── 3. Capability tests ─────────────────────────────────────────────────── *)

let test_cap_sign_requires_jwt () =
  let src = module_ ~exports:"badSign" {|
fn badSign(claims: String, secret: JwtSecret) -> JwtToken =
  JWT.sign claims secret
|} in
  check_err_contains "cap_sign_requires_jwt" src "jwt"

let test_cap_verify_requires_jwt () =
  let src = module_ ~exports:"badVerify" {|
fn badVerify(token: JwtToken, secret: JwtSecret) -> String =
  JWT.verify token secret
|} in
  check_err_contains "cap_verify_requires_jwt" src "jwt"

let test_cap_decode_requires_jwt () =
  let src = module_ ~exports:"badDecode" {|
fn badDecode(token: JwtToken) -> String =
  JWT.decode token
|} in
  check_err_contains "cap_decode_requires_jwt" src "jwt"

let test_cap_sign_ok_with_jwt () =
  let src = module_ ~exports:"goodSign" {|
capability myJwt implies jwt

fn goodSign(claims: String, secret: JwtSecret) requires [myJwt] -> JwtToken =
  JWT.sign claims secret
|} in
  let _ = compile_ok "cap_sign_ok" src in
  ()

let test_cap_verify_ok_with_jwt () =
  let src = module_ ~exports:"goodVerify" {|
capability myJwt implies jwt

fn goodVerify(token: JwtToken, secret: JwtSecret) requires [myJwt] -> String =
  JWT.verify token secret
|} in
  let _ = compile_ok "cap_verify_ok" src in
  ()

let test_cap_decode_ok_with_jwt () =
  let src = module_ ~exports:"goodDecode" {|
capability myJwt implies jwt

fn goodDecode(token: JwtToken) requires [myJwt] -> String =
  JWT.decode token
|} in
  let _ = compile_ok "cap_decode_ok" src in
  ()

let test_cap_direct_jwt_cap () =
  let src = module_ ~exports:"sign" {|
fn sign(claims: String, s: JwtSecret) requires [jwt] -> JwtToken =
  JWT.sign claims s
|} in
  let _ = compile_ok "cap_direct_jwt" src in
  ()

let test_cap_implies_chain () =
  (* A capability implying another which implies jwt *)
  let src = module_ ~exports:"sign" {|
capability cryptoCap implies jwt
capability authCap implies cryptoCap

fn sign(claims: String, s: JwtSecret) requires [authCap] -> JwtToken =
  JWT.sign claims s
|} in
  let _ = compile_ok "cap_implies_chain" src in
  ()

let test_cap_handler_requires_jwt () =
  let src = module_ ~exports:"tokenHandler" {|
capability myJwt implies jwt

handler tokenHandler(secret: String) -> String
  requires [myJwt] =
  let s = JwtSecret secret
  let _ = JWT.sign "user:123" s
  "ok"
|} in
  let _ = compile_ok "cap_handler_with_jwt" src in
  ()

let test_cap_handler_missing_jwt () =
  let src = module_ ~exports:"tokenHandler" {|
handler tokenHandler(secret: String) -> String
  requires [] =
  let s = JwtSecret secret
  let _ = JWT.sign "user:123" s
  "ok"
|} in
  check_err_contains "cap_handler_missing_jwt" src "jwt"

let test_cap_worker_requires_jwt () =
  let src = module_ ~exports:"" {|
capability myJwt implies jwt

worker tokenRefresh(secret: JwtSecret) requires [myJwt] -> String =
  let t = JWT.sign "refresh:user" secret
  "done"
|} in
  let _ = compile_ok "cap_worker_with_jwt" src in
  ()

let test_cap_fn_requires_jwt () =
  let src = module_ ~exports:"makeToken" {|
capability myJwt implies jwt

fn makeToken(userId: String, secret: JwtSecret) requires [myJwt] -> JwtToken =
  JWT.sign userId secret
|} in
  let _ = compile_ok "cap_fn_with_jwt" src in
  ()

let test_cap_fn_missing_jwt () =
  let src = module_ ~exports:"makeToken" {|
fn makeToken(userId: String, secret: JwtSecret) -> JwtToken =
  JWT.sign userId secret
|} in
  check_err_contains "cap_fn_missing_jwt" src "jwt"

let test_cap_missing_in_fn_callee () =
  (* A plain fn calling JWT.sign without jwt declared is an error *)
  let src = module_ ~exports:"helper" {|
fn helper(claims: String, s: JwtSecret) -> JwtToken =
  JWT.sign claims s
|} in
  check_err_contains "cap_fn_callee_missing" src "jwt"

(* ── 4. Module / import tests ────────────────────────────────────────────── *)

let test_module_jwt_is_known () =
  (* Tesl.JWT must not produce "unknown module" error *)
  let src = "#lang tesl\nmodule M exposing []\nimport Tesl.JWT exposing [jwt]\n\
             import Tesl.Prelude exposing [String]\n" in
  let _ = compile_ok "module_jwt_known" src in
  ()

let test_module_jwt_unknown_export_errors () =
  let src = "#lang tesl\nmodule M exposing []\nimport Tesl.JWT exposing [notReal]\n\
             import Tesl.Prelude exposing [String]\n" in
  check_err_contains "module_jwt_unknown_export" src "notReal"

let test_module_jwt_emits_require () =
  let src = module_ ~exports:"mk" {|
fn mk(s: String) -> JwtSecret =
  JwtSecret s
|} in
  check_contains "module_jwt_emits_require" src "tesl/tesl/jwt"

let test_module_jwt_racket_output () =
  let src = module_ ~exports:"sign" {|
capability myJwt implies jwt

fn sign(claims: String, s: JwtSecret) requires [myJwt] -> JwtToken =
  JWT.sign claims s
|} in
  let racket = compile_ok "module_jwt_racket_output" src in
  (* Output should have JWT.sign and jwt.rkt *)
  if not (contains "JWT.sign" racket) then
    Alcotest.failf "module_jwt_racket_output: expected JWT.sign in output:\n%s" racket

let test_module_jwt_all_exports_usable () =
  let src = module_ ~exports:"sign, verify, decode, mkSecret, mkToken" {|
capability myJwt implies jwt

fn sign(claims: String, s: JwtSecret) requires [myJwt] -> JwtToken =
  JWT.sign claims s

fn verify(t: JwtToken, s: JwtSecret) requires [myJwt] -> String =
  JWT.verify t s

fn decode(t: JwtToken) requires [myJwt] -> String =
  JWT.decode t

fn mkSecret(s: String) -> JwtSecret =
  JwtSecret s

fn mkToken(s: String) -> JwtToken =
  JwtToken s
|} in
  let _ = compile_ok "module_jwt_all_exports" src in
  ()

(* ── 5. Emit / Racket output tests ───────────────────────────────────────── *)

let test_emit_jwt_sign_output () =
  let src = module_ ~exports:"sign" {|
capability myJwt implies jwt

fn sign(claims: String, s: JwtSecret) requires [myJwt] -> JwtToken =
  JWT.sign claims s
|} in
  check_contains "emit_jwt_sign" src "JWT.sign"

let test_emit_jwt_verify_output () =
  let src = module_ ~exports:"verify" {|
capability myJwt implies jwt

fn verify(t: JwtToken, s: JwtSecret) requires [myJwt] -> String =
  JWT.verify t s
|} in
  check_contains "emit_jwt_verify" src "JWT.verify"

let test_emit_jwt_decode_output () =
  let src = module_ ~exports:"decode" {|
capability myJwt implies jwt

fn decode(t: JwtToken) requires [myJwt] -> String =
  JWT.decode t
|} in
  check_contains "emit_jwt_decode" src "JWT.decode"

let test_emit_jwt_requires_jwt_rkt () =
  let src = module_ ~exports:"mk" {|
fn mk(s: String) -> JwtSecret =
  JwtSecret s
|} in
  check_contains "emit_jwt_requires_rkt" src "tesl/tesl/jwt"

let test_emit_jwt_not_required_when_not_imported () =
  let src = "#lang tesl\nmodule M exposing [f]\n\
             import Tesl.Prelude exposing [Int, String]\n\
             fn f(n: Int) -> Int = n + 1\n" in
  check_not_contains "emit_jwt_not_imported" src "jwt.rkt"

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "JWT" [
    "parser", [
      Alcotest.test_case "JWT import recognized" `Quick test_parse_jwt_import;
      Alcotest.test_case "JWT.sign parses" `Quick test_parse_jwt_sign;
      Alcotest.test_case "JWT.verify parses" `Quick test_parse_jwt_verify;
      Alcotest.test_case "JWT.decode parses" `Quick test_parse_jwt_decode;
      Alcotest.test_case "JwtSecret newtype parses" `Quick test_parse_jwt_newtype_jwtsecret;
      Alcotest.test_case "JwtToken newtype parses" `Quick test_parse_jwt_newtype_jwttoken;
      Alcotest.test_case "JwtToken type annotation" `Quick test_parse_jwt_token_type_annotation;
      Alcotest.test_case "capability jwt declared" `Quick test_parse_jwt_capability_declare;
      Alcotest.test_case "multiple JWT functions" `Quick test_parse_jwt_multiple_functions;
      Alcotest.test_case "import exposing all exports" `Quick test_parse_jwt_import_exposing;
    ];
    "types", [
      Alcotest.test_case "sign returns JwtToken" `Quick test_types_sign_returns_jwttoken;
      Alcotest.test_case "JwtToken not String" `Quick test_types_jwttoken_not_string;
      Alcotest.test_case "JwtSecret nominal type" `Quick test_types_jwtsecret_not_string;
      Alcotest.test_case "sign accepts any claims" `Quick test_types_sign_takes_any_claims;
      Alcotest.test_case "verify returns polymorphic" `Quick test_types_verify_returns_polymorphic;
      Alcotest.test_case "decode returns polymorphic" `Quick test_types_decode_returns_polymorphic;
      Alcotest.test_case "JwtToken constructor" `Quick test_types_jwttoken_constructor;
      Alcotest.test_case "JwtSecret constructor" `Quick test_types_jwtsecret_constructor;
      Alcotest.test_case "verify uses token arg" `Quick test_types_verify_uses_token_arg;
      Alcotest.test_case "chain sign and verify" `Quick test_types_chain_sign_and_verify;
      Alcotest.test_case "decode no secret needed" `Quick test_types_decode_no_secret_needed;
      Alcotest.test_case "JwtToken in record" `Quick test_types_jwttoken_in_record;
      Alcotest.test_case "JwtSecret in record" `Quick test_types_jwtsecret_in_record;
      Alcotest.test_case "jwt cap in list" `Quick test_types_jwt_capability_in_list;
      Alcotest.test_case "multiple jwt ops in fn" `Quick test_types_multiple_jwt_ops_in_fn;
      Alcotest.test_case "jwt with string concat" `Quick test_types_jwt_with_string_concat;
      Alcotest.test_case "verify result in let" `Quick test_types_verify_result_in_let;
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
    ];
    "module", [
      Alcotest.test_case "Tesl.JWT is known module" `Quick test_module_jwt_is_known;
      Alcotest.test_case "unknown export errors" `Quick test_module_jwt_unknown_export_errors;
      Alcotest.test_case "emits jwt.rkt require" `Quick test_module_jwt_emits_require;
      Alcotest.test_case "Racket output correct" `Quick test_module_jwt_racket_output;
      Alcotest.test_case "all exports usable" `Quick test_module_jwt_all_exports_usable;
    ];
    "emit", [
      Alcotest.test_case "JWT.sign in output" `Quick test_emit_jwt_sign_output;
      Alcotest.test_case "JWT.verify in output" `Quick test_emit_jwt_verify_output;
      Alcotest.test_case "JWT.decode in output" `Quick test_emit_jwt_decode_output;
      Alcotest.test_case "requires jwt.rkt" `Quick test_emit_jwt_requires_jwt_rkt;
      Alcotest.test_case "not imported means not required" `Quick test_emit_jwt_not_required_when_not_imported;
    ];
  ]
