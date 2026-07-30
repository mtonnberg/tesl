(** Phase 5 — the mandatory adversarial pass, COMPILE-TIME half
    (roadmap/next/ensure_sso_works.md §Login methods + Phase 5 attack list).

    The runtime attack list (state replay, PKCE reuse, iss/aud/mix-up/alg/key
    confusion, SSRF, session fixation, flattened-claims, subject shape, secret
    leakage, …) is exercised against the real runtime in
    tests/sso-adversarial-test.rkt (20) and tests/jws-verify-test.rkt (11).

    This suite is the half the Phase-3 compiler surface newly makes expressible:
    the `loginMethods` bypass negatives — every attempt to mint a session by a
    path OTHER than the SSO callback must NOT COMPILE.  The enforcement sits on
    the unique session-minting chokepoint (`Http.setSessionCookie`) plus the
    `Crypto.checkPassword`/`hashPassword` backstop, so a magic-link handler, an
    API-key login, and a hand-rolled hash compare are all refused for the same
    reason — they reach the chokepoint — rather than by spelling. *)

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

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " quoted ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let code = match Unix.close_process_in ic with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n in
  (code, out)

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-sso-adv" "" in
  let path = Filename.concat dir "probe.tesl" in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected clean compile, got (exit %d):\n%s" code out)

let should_fail pattern src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but it compiled clean" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

(* A full SSO program: extra [imports], top-level [defs], a [server_extra] line
   inside the server block (after the mandatory sso/publicOrigin/sessionKey),
   and main's granted [caps]. *)
let sso_prog ?(imports = "") ?(defs = "") ~server_extra ~caps () =
  Printf.sprintf
    "module Probe exposing []\n\
     import Tesl.Prelude exposing [String, Bool(..), Unit]\n\
     %s\n\
     import Tesl.Sso exposing [SsoConnection, SsoIdentity, Github, Sso.defaults, Sso.subject]\n\
     import Tesl.Env exposing [envRead, requireEnv, requireSecret]\n\
     import Tesl.HttpClient exposing [httpClient]\n\
     import Tesl.Database exposing [Database, DatabaseBackend, Memory]\n\
     import Tesl.App exposing [App]\n\
     fn githubConn() -> SsoConnection requires [envRead] = Sso.defaults Github (requireEnv \"I\") (requireSecret \"S\")\n\
     fn linkUser(identity: SsoIdentity) -> String = Sso.subject identity\n\
     handler healthCheck() -> String requires [] = \"ok\"\n\
     %s\n\
     api AppApi {\n  get \"/health\" -> String\n}\n\
     server AppServer for AppApi {\n  endpoint_0 = healthCheck\n  \
     sso \"github\" connection githubConn onIdentity linkUser\n  \
     publicOrigin \"https://app.example.com\"\n  sessionKey \"SESSION_KEY\"\n  %s\n}\n\
     database ProbeDb = Database {\n  entities: []\n  backend: Memory\n}\n\
     main() -> App requires [%s] = App {\n  database: ProbeDb\n  api: AppServer\n  port: 8080\n}\n"
    imports defs server_extra caps

let cookie_imports =
  "import Tesl.JWT exposing [JwtToken]\n\
   import Tesl.Http exposing [Http.setSessionCookie, cookieCap]"

(* ── Bypass negatives: nothing but the SSO callback may mint a session ─────── *)

let t_direct_set_cookie_refused () =
  should_fail "no method in this server"
    (sso_prog ~imports:cookie_imports
       ~defs:"fn mint(t: JwtToken) -> Unit requires [cookieCap] = Http.setSessionCookie t"
       ~server_extra:"loginMethods [Sso]" ~caps:"envRead, httpClient" ())

let t_magic_link_mint_refused () =
  (* A magic-link handler mints a session with no password call at all — caught
     because it reaches the chokepoint, not by spelling. *)
  should_fail "no method in this server"
    (sso_prog ~imports:cookie_imports
       ~defs:"handler magicLink(t: JwtToken) -> Unit requires [cookieCap] = Http.setSessionCookie t"
       ~server_extra:"loginMethods [Sso]" ~caps:"envRead, httpClient" ())

let t_apikey_mint_refused () =
  should_fail "no method in this server"
    (sso_prog ~imports:cookie_imports
       ~defs:"handler apiKeyLogin(t: JwtToken) -> Unit requires [cookieCap] = Http.setSessionCookie t"
       ~server_extra:"loginMethods [Sso]" ~caps:"envRead, httpClient" ())

let t_hashpassword_backstop_refused () =
  should_fail "no method in this server"
    (sso_prog ~imports:"import Tesl.Crypto exposing [PasswordHash, Crypto.hashPassword]"
       ~defs:"fn store(p: String) -> PasswordHash = Crypto.hashPassword p"
       ~server_extra:"loginMethods [Sso]" ~caps:"envRead, httpClient" ())

let t_checkpassword_backstop_refused () =
  should_fail "no method in this server"
    (sso_prog
       ~imports:"import Tesl.Maybe exposing [Maybe(..)]\n\
                 import Tesl.Crypto exposing [PasswordHash, Crypto.checkPassword]"
       ~defs:"fn verify(h: Maybe PasswordHash, p: String) -> Maybe PasswordHash = Crypto.checkPassword h p"
       ~server_extra:"loginMethods [Sso]" ~caps:"envRead, httpClient" ())

let t_afterlogin_offorigin_refused () =
  should_fail "afterLogin"
    (sso_prog ~server_extra:"afterLogin \"https://evil.example.com/\"" ~caps:"envRead, httpClient" ())

(* ── Positive controls: the sanctioned shape still compiles ────────────────── *)

let t_sso_only_clean_compiles () =
  should_pass
    (sso_prog ~server_extra:"loginMethods [Sso]" ~caps:"envRead, httpClient" ())

let t_mixed_mode_minting_deferred_compiles () =
  (* Mixed mode names a policy fn; the witness-gated per-site attribution is a
     documented deferral, so a minting site is not (yet) rejected here. *)
  should_pass
    (sso_prog ~imports:cookie_imports
       ~defs:"fn ssoRequired(_id: String) -> Bool requires [] = False\n\
              fn mint(t: JwtToken) -> Unit requires [cookieCap] = Http.setSessionCookie t"
       ~server_extra:"loginMethods [Sso, Password via ssoRequired]" ~caps:"envRead, httpClient" ())

(* ── Item A: ProxyBound kernel-minted evidence (#50.2) ─────────────────────── *)

let proxy_prog body =
  "module Probe exposing []\n" ^
  "import Tesl.Prelude exposing [String]\n" ^
  "import Tesl.Crypto exposing [Secret]\n" ^
  "import Tesl.Proxy exposing [ProxyBound, Proxy.verifyBinding]\n" ^
  "fn useBinding(presented: String ::: ProxyBound presented) -> String = presented\n" ^
  body ^ "\n"

(* A ProxyBound obtained by ACTUALLY running the check is usable downstream. *)
let t_proxybound_verified_compiles () =
  should_pass
    (proxy_prog
       ("fn gate(config: Secret, presented: String) -> String =\n" ^
        "  let bound = check Proxy.verifyBinding config presented\n" ^
        "  useBinding bound"))

(* Fact ownership: no hand-written function may DECLARE it mints ProxyBound. *)
let t_proxybound_forge_refused () =
  should_fail "ProxyBound"
    (proxy_prog
       "fn forge(presented: String) -> presented: String ::: ProxyBound presented = presented")

(* And the fact cannot be conjured: demanding it without the check is refused. *)
let t_proxybound_skip_check_refused () =
  should_fail "does not statically satisfy"
    (proxy_prog
       "fn skip(config: Secret, presented: String) -> String = useBinding presented")

let () =
  run "sso-adversarial" [
    "minting-chokepoint", [
      test_case "a direct Http.setSessionCookie is refused under [Sso]" `Quick
        t_direct_set_cookie_refused;
      test_case "a magic-link mint is refused under [Sso]" `Quick t_magic_link_mint_refused;
      test_case "an API-key login mint is refused under [Sso]" `Quick t_apikey_mint_refused;
    ];
    "password-call-backstop", [
      test_case "Crypto.hashPassword is refused under [Sso]" `Quick
        t_hashpassword_backstop_refused;
      test_case "Crypto.checkPassword is refused under [Sso]" `Quick
        t_checkpassword_backstop_refused;
    ];
    "redirect", [
      test_case "an off-origin afterLogin is refused" `Quick t_afterlogin_offorigin_refused;
    ];
    "positive-controls", [
      test_case "SSO-only with no minting site compiles" `Quick t_sso_only_clean_compiles;
      test_case "mixed mode with a minting site compiles (deferred)" `Quick
        t_mixed_mode_minting_deferred_compiles;
    ];
    "proxy-bound-evidence", [
      test_case "check Proxy.verifyBinding yields a usable ProxyBound" `Quick
        t_proxybound_verified_compiles;
      test_case "a hand-declared ProxyBound is refused (fact ownership)" `Quick
        t_proxybound_forge_refused;
      test_case "demanding ProxyBound without the check is refused" `Quick
        t_proxybound_skip_check_refused;
    ];
  ]
