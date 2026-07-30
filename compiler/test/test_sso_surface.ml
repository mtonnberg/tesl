(** Tesl.Sso surface + the `sessionPolicy` server clause
    (roadmap/next/ensure_sso_works.md, Phase 3).  Pins the checker contract for
    the SSO stdlib types/functions (opaque nominal wall, Secret/PasswordHash
    precedent) and the end-to-end emit of the `sessionPolicy` clause (a CLOSED
    keyword set that sets the runtime session policy at boot). *)

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
  let dir = Filename.temp_dir "tesl-sso" "" in
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

(* Emit the Racket (no --check -> compile to stdout) and assert on its text. *)
let emitted src =
  with_temp_file src (fun path ->
    let code, out = run_compiler [path] in
    if code <> 0 then failf "expected a clean emit, got (exit %d):\n%s" code out;
    out)

let should_emit pattern src =
  let out = emitted src in
  let re = Str.regexp pattern in
  try ignore (Str.search_forward re out 0)
  with Not_found -> failf "expected emitted Racket to match %S, got:\n%s" pattern out

let should_not_emit pattern src =
  let out = emitted src in
  let re = Str.regexp pattern in
  match (try Some (Str.search_forward re out 0) with Not_found -> None) with
  | Some _ -> failf "expected emitted Racket NOT to match %S, but it did" pattern
  | None -> ()

(* One module Probe in probe.tesl (Tesl.Sso stdlib surface). *)
let prog ?(exposing = "SsoConnection, SsoSubjectKey, SsoProvider, Github, Sso.defaults, Sso.oidc, Sso.keyText") body =
  Printf.sprintf
    "module Probe exposing [f]\n\
     import Tesl.Prelude exposing [Int, String, Bool]\n\
     import Tesl.Crypto exposing [Secret]\n\
     import Tesl.Sso exposing [%s]\n\
     %s\n"
    exposing body

(* A minimal but complete server program; [clause] goes in the server block. *)
let server_prog clause =
  Printf.sprintf
    "module Probe exposing []\n\
     import Tesl.Prelude exposing [String]\n\
     import Tesl.Database exposing [Database, DatabaseBackend, Memory]\n\
     import Tesl.App exposing [App]\n\
     handler healthCheck() -> String requires [] = \"ok\"\n\
     api HealthApi {\n  get \"/health\" -> String\n}\n\
     server HealthServer for HealthApi {\n  endpoint_0 = healthCheck\n  %s\n}\n\
     database ProbeDb = Database {\n  entities: []\n  backend: Memory\n}\n\
     main() -> App requires [] =\n\
     \  App {\n    database: ProbeDb\n    api: HealthServer\n    port: 8086\n  }\n"
    clause

(* ── Positive: the surface types + functions work as declared ─────────────── *)

let t_builds_a_connection () =
  should_pass
    (prog "fn f(id: String, sec: Secret) -> SsoConnection = Sso.defaults Github id sec")

let t_keytext_returns_string () =
  should_pass (prog "fn f(k: SsoSubjectKey) -> String = Sso.keyText k")

(* ── Opacity: the identity types are a nominal wall ───────────────────────── *)

let t_connection_is_opaque () =
  should_fail "SsoConnection" (prog "fn f() -> SsoConnection = SsoConnection \"x\"")

let t_subject_key_is_opaque () =
  should_fail "SsoSubjectKey" (prog "fn f() -> SsoSubjectKey = SsoSubjectKey \"x\"")

(* ── Typing: the nominal wall stands in both directions ───────────────────── *)

let t_connection_is_not_a_string () =
  should_fail "SsoConnection\\|unify"
    (prog "fn f(id: String, sec: Secret) -> String = Sso.defaults Github id sec")

let t_keytext_needs_a_key () =
  should_fail "SsoSubjectKey\\|unify"
    (prog "fn f(s: String) -> String = Sso.keyText s")

let t_defaults_secret_must_be_a_secret () =
  should_fail "Secret\\|unify"
    (prog "fn f(id: String) -> SsoConnection = Sso.defaults Github id id")

let t_names_need_the_import () =
  should_fail "Sso.defaults\\|exposing\\|not in scope"
    (prog ~exposing:"SsoConnection, SsoSubjectKey"
       "fn f(id: String, sec: Secret) -> SsoConnection = Sso.defaults \"github\" id sec")

(* ── The provider is an ADT, not a String (Phase 4) ───────────────────────── *)

let t_provider_not_a_string () =
  should_fail "SsoProvider\\|unify"
    (prog "fn f(id: String, sec: Secret) -> SsoConnection = Sso.defaults \"github\" id sec")

let t_provider_ctor_builds () =
  should_pass
    (prog "fn f(id: String, sec: Secret) -> SsoConnection = Sso.defaults Github id sec")

let t_oidc_builds_connection () =
  (* The generic OIDC connection takes an issuer URL (String), not a provider. *)
  should_pass
    (prog "fn f(id: String, sec: Secret) -> SsoConnection = Sso.oidc \"https://idp.example.com\" id sec")

(* ── Capabilities of the SSO-referenced fns flow to main (Phase 4) ─────────── *)

let t_sso_flow_requires_httpclient () =
  (* An sso server needs main to grant httpClient for the runtime flow. *)
  should_fail "httpClient"
    (Printf.sprintf
      "module Probe exposing []\n\
       import Tesl.Prelude exposing [String]\n\
       import Tesl.Database exposing [Database, DatabaseBackend, Memory]\n\
       import Tesl.App exposing [App]\n\
       handler healthCheck() -> String requires [] = \"ok\"\n\
       fn githubConn() -> String requires [] = \"c\"\n\
       fn linkUser() -> String requires [] = \"u\"\n\
       api HealthApi {\n  get \"/health\" -> String\n}\n\
       server HealthServer for HealthApi {\n  endpoint_0 = healthCheck\n  \
       sso \"github\" connection githubConn onIdentity linkUser\n  \
       publicOrigin \"https://app.example.com\"\n  sessionKey \"K\"\n}\n\
       database ProbeDb = Database {\n  entities: []\n  backend: Memory\n}\n\
       main() -> App requires [] =\n  App {\n    database: ProbeDb\n    api: HealthServer\n    port: 8086\n  }\n")

(* ── The `sessionPolicy` server clause (Phase 3) ──────────────────────────── *)

let t_short_session_sets_the_policy () =
  should_emit "current-session-policy.*short-session"
    (server_prog "sessionPolicy ShortSession")

let t_standard_session_sets_the_policy () =
  should_emit "current-session-policy.*standard-session"
    (server_prog "sessionPolicy StandardSession")

let t_no_clause_sets_no_policy () =
  should_not_emit "current-session-policy" (server_prog "")

let t_unknown_policy_takes_no_effect () =
  (* CLOSED keyword set — an unrecognised name cannot turn the policy the unsafe
     way; it simply does not take effect. *)
  should_not_emit "current-session-policy" (server_prog "sessionPolicy Forever")

(* ── The `publicOrigin` server clause (Phase 3) ───────────────────────────── *)

let t_public_origin_is_set () =
  should_emit "current-public-origin.*https://app.example.com"
    (server_prog "publicOrigin \"https://app.example.com\"")

let t_no_public_origin_sets_none () =
  should_not_emit "current-public-origin" (server_prog "")

let t_both_clauses_coexist () =
  let out =
    emitted (server_prog "sessionPolicy ShortSession\n  publicOrigin \"https://app.example.com\"") in
  (if not (Str.string_match (Str.regexp ".*short-session") out 0)
      && (try ignore (Str.search_forward (Str.regexp "short-session") out 0); false
          with Not_found -> true)
   then failf "expected short-session in:\n%s" out);
  (try ignore (Str.search_forward (Str.regexp "current-public-origin") out 0)
   with Not_found -> failf "expected current-public-origin in:\n%s" out)

(* OQ11: `publicOrigin fromEnv "VAR"` reads the origin from the env var at boot. *)
let t_public_origin_from_env_is_set () =
  should_emit "current-public-origin.*public-origin-from-env.*PUBLIC_ORIGIN"
    (server_prog "publicOrigin fromEnv \"PUBLIC_ORIGIN\"")

(* OQ11: a loopback http origin is accepted (dev). *)
let t_public_origin_loopback_http_ok () =
  should_emit "current-public-origin.*http://localhost:8080"
    (server_prog "publicOrigin \"http://localhost:8080\"")

(* OQ11: an invalid literal origin (no scheme / a path / a query) is rejected
   at compile time by the same rule the env form is validated with at boot. *)
let t_public_origin_invalid_literal_rejected () =
  should_fail "has an invalid .publicOrigin"
    (server_prog "publicOrigin \"app.example.com\"")

(* #51: the `trustedProxies [ ... ]` edge declaration sets the runtime trusted
   proxy set at boot (enables a trustworthy request.clientAddress). *)
let t_trusted_proxies_is_set () =
  should_emit "current-trusted-proxies.*10[.]0[.]0[.]1"
    (server_prog "trustedProxies [ \"10.0.0.1\", \"10.0.0.2\" ]")

let t_no_trusted_proxies_sets_none () =
  should_not_emit "current-trusted-proxies" (server_prog "")

(* Risk 50/60: the healthProbePath clause sets the Host-validation-exempt path. *)
let t_health_probe_path_is_set () =
  should_emit "current-health-probe-path.*/healthz"
    (server_prog "healthProbePath \"/healthz\"")

(* OQ17/#50.1: the contentSecurityPolicy clause sets the server default CSP. *)
let t_content_security_policy_is_set () =
  should_emit "current-content-security-policy.*default-src"
    (server_prog "contentSecurityPolicy \"default-src 'self'\"")

(* A server program with extra top-level fn definitions [defs] and a server-block
   [clause] (e.g. an `sso` clause referencing those fns). *)
let sso_server_prog defs clause =
  Printf.sprintf
    "module Probe exposing []\n\
     import Tesl.Prelude exposing [String]\n\
     import Tesl.HttpClient exposing [httpClient]\n\
     import Tesl.Database exposing [Database, DatabaseBackend, Memory]\n\
     import Tesl.App exposing [App]\n\
     handler healthCheck() -> String requires [] = \"ok\"\n\
     %s\n\
     api HealthApi {\n  get \"/health\" -> String\n}\n\
     server HealthServer for HealthApi {\n  endpoint_0 = healthCheck\n  %s\n}\n\
     database ProbeDb = Database {\n  entities: []\n  backend: Memory\n}\n\
     main() -> App requires [httpClient] =\n  App {\n    database: ProbeDb\n    api: HealthServer\n    port: 8086\n  }\n"
    defs clause

let two_fns =
  "fn githubConn() -> String requires [] = \"c\"\n\
   fn linkUser() -> String requires [] = \"u\""

let t_connection_cap_flows_to_main () =
  (* githubConn needs envRead; sso_server_prog's main grants only httpClient. *)
  should_fail "does not grant"
    (sso_server_prog
       "fn githubConn() -> String requires [envRead] = \"c\"\n\
        fn linkUser() -> String requires [] = \"u\""
       "sso \"github\" connection githubConn onIdentity linkUser\n  \
        publicOrigin \"https://app.example.com\"\n  sessionKey \"K\"")

(* ── The flagship `sso` server clause (Phase 3): parse + fail-closed checks ── *)

let t_sso_clause_validates () =
  (* A genuinely well-formed sso server: the flagship clause PLUS the two
     companion clauses the validator requires (publicOrigin + sessionKey). *)
  should_pass
    (sso_server_prog two_fns
       "sso \"github\" connection githubConn onIdentity linkUser\n  \
        publicOrigin \"https://app.example.com\"\n  sessionKey \"SESSION_KEY\"")

let t_sso_unknown_connection () =
  should_fail "unknown connection function"
    (sso_server_prog "fn linkUser() -> String requires [] = \"u\""
       "sso \"github\" connection missingConn onIdentity linkUser")

let t_sso_unknown_on_identity () =
  should_fail "unknown onIdentity function"
    (sso_server_prog "fn githubConn() -> String requires [] = \"c\""
       "sso \"github\" connection githubConn onIdentity missingId")

let t_sso_duplicate_segment () =
  should_fail "two .sso. clauses for segment"
    (sso_server_prog two_fns
       "sso \"github\" connection githubConn onIdentity linkUser\n  sso \"github\" connection githubConn onIdentity linkUser")

(* ── The `sessionRevoked` server clause (Phase 3) ─────────────────────────── *)

(* Like sso_server_prog, but imports Bool(..) and PosixMillis for the revocation
   predicate `(String, PosixMillis) -> Bool`. *)
let revoked_prog defs clause =
  Printf.sprintf
    "module Probe exposing []\n\
     import Tesl.Prelude exposing [String, Bool(..)]\n\
     import Tesl.Time exposing [PosixMillis]\n\
     import Tesl.Database exposing [Database, DatabaseBackend, Memory]\n\
     import Tesl.App exposing [App]\n\
     handler healthCheck() -> String requires [] = \"ok\"\n\
     %s\n\
     api HealthApi {\n  get \"/health\" -> String\n}\n\
     server HealthServer for HealthApi {\n  endpoint_0 = healthCheck\n  %s\n}\n\
     database ProbeDb = Database {\n  entities: []\n  backend: Memory\n}\n\
     main() -> App requires [] =\n  App {\n    database: ProbeDb\n    api: HealthServer\n    port: 8086\n  }\n"
    defs clause

let revoked_fn =
  "fn revoked(_s: String, _iat: PosixMillis) -> Bool = False"

let t_session_revoked_sets_hook () =
  should_emit "current-session-revoked-hook.*revoked.*Time.secondsToPosix"
    (revoked_prog revoked_fn "sessionRevoked revoked")

let t_no_session_revoked_sets_none () =
  should_not_emit "current-session-revoked-hook" (revoked_prog "" "")

let t_session_revoked_unknown_fn () =
  should_fail "no such function is defined"
    (revoked_prog "" "sessionRevoked nope")

(* ── The `sessionPreviousKey` server clause (Phase 3): key rotation ───────────── *)

let t_previous_key_sets_the_param () =
  (* Sets current-previous-session-key at boot, wrapped in the bootstrap-trust
     marker (a load-time provider read).  Requires a current key too. *)
  should_emit "with-env-bootstrap.*current-previous-session-key.*PREV"
    (server_prog "sessionKey \"CUR\"\n  sessionPreviousKey \"PREV\"")

let t_no_previous_key_sets_none () =
  should_not_emit "current-previous-session-key" (server_prog "")

let t_previous_key_requires_current () =
  (* A previous key with no current key is a misconfiguration (fail-closed). *)
  should_fail "without an .sessionKey"
    (server_prog "sessionPreviousKey \"PREV\"")

(* ── The `listenAddress` server clause (Phase 3): bind interface ──────────── *)

let t_loopback_registers_127 () =
  should_emit "register-listen-address!.*HealthServer.*127.0.0.1"
    (server_prog "listenAddress Loopback")

let t_all_interfaces_registers_false () =
  should_emit "register-listen-address!.*HealthServer.*#f"
    (server_prog "listenAddress AllInterfaces")

let t_no_listen_address_registers_nothing () =
  should_not_emit "register-listen-address!" (server_prog "")

let t_unknown_listen_address_takes_no_effect () =
  (* CLOSED keyword set — an unrecognised name registers nothing. *)
  should_not_emit "register-listen-address!" (server_prog "listenAddress Elsewhere")

(* ── The `loginMethods` server clause (Phase 3): fail-closed allowlist ────── *)

(* A server program that DOES contain the session-minting chokepoint
   (`Http.setSessionCookie`), plus optional extra [defs] (e.g. a password policy
   fn) and the server-block [clause]. *)
let minting_server_prog defs clause =
  Printf.sprintf
    "module Probe exposing []\n\
     import Tesl.Prelude exposing [String, Bool(..), Unit]\n\
     import Tesl.JWT exposing [JwtToken]\n\
     import Tesl.Http exposing [Http.setSessionCookie, cookieCap]\n\
     import Tesl.Database exposing [Database, DatabaseBackend, Memory]\n\
     import Tesl.App exposing [App]\n\
     handler healthCheck() -> String requires [] = \"ok\"\n\
     fn mint(t: JwtToken) -> Unit requires [cookieCap] = Http.setSessionCookie t\n\
     %s\n\
     api HealthApi {\n  get \"/health\" -> String\n}\n\
     server HealthServer for HealthApi {\n  endpoint_0 = healthCheck\n  %s\n}\n\
     database ProbeDb = Database {\n  entities: []\n  backend: Memory\n}\n\
     main() -> App requires [] =\n  App {\n    database: ProbeDb\n    api: HealthServer\n    port: 8086\n  }\n"
    defs clause

let t_login_sso_only_compiles () =
  (* No session-minting site → SSO-only is satisfied. *)
  should_pass (server_prog "loginMethods [Sso]")

let t_login_sso_rejects_minting () =
  should_fail "no method in this server"
    (minting_server_prog "" "loginMethods [Sso]")

let t_login_mixed_mode_defers_attribution () =
  (* Mixed mode: the policy fn must exist; the witness-gated per-site
     attribution is deferred, so a minting site is NOT (yet) rejected. *)
  should_pass
    (minting_server_prog
       "fn ssoRequired(_id: String) -> Bool requires [] = False"
       "loginMethods [Sso, Password via ssoRequired]")

let t_login_password_needs_via () =
  should_fail "without .via"
    (server_prog "loginMethods [Sso, Password]")

let t_login_password_unknown_fn () =
  should_fail "unknown function"
    (server_prog "loginMethods [Sso, Password via nope]")

let t_login_unknown_method () =
  should_fail "unknown loginMethods entry"
    (server_prog "loginMethods [Sso, Frobnicate]")

let t_login_requires_sso () =
  should_fail "without .Sso"
    (server_prog "loginMethods [Proxy]")

(* #50.2: a Machine credential (a per-installation bearer token the app verifies
   against stored material) licenses the app-side session-minting site, like
   Password. *)
let t_login_machine_licenses_minting () =
  should_pass (minting_server_prog "" "loginMethods [Sso, Machine]")

let () =
  run "sso-surface" [
    "positive", [
      test_case "Sso.defaults builds an SsoConnection" `Quick t_builds_a_connection;
      test_case "Sso.keyText returns a String" `Quick t_keytext_returns_string;
    ];
    "opacity", [
      test_case "SsoConnection cannot be constructed on the surface" `Quick t_connection_is_opaque;
      test_case "SsoSubjectKey cannot be constructed on the surface" `Quick t_subject_key_is_opaque;
    ];
    "typing", [
      test_case "an SsoConnection is not a String" `Quick t_connection_is_not_a_string;
      test_case "Sso.keyText rejects a non-key" `Quick t_keytext_needs_a_key;
      test_case "Sso.defaults rejects a String where a Secret is required" `Quick
        t_defaults_secret_must_be_a_secret;
    ];
    "import-gating", [
      test_case "the dotted Sso.* names need the import" `Quick t_names_need_the_import;
    ];
    "provider-adt", [
      test_case "a String provider is rejected (must be SsoProvider)" `Quick
        t_provider_not_a_string;
      test_case "the Github constructor builds a connection" `Quick t_provider_ctor_builds;
      test_case "Sso.oidc builds a connection from an issuer URL" `Quick t_oidc_builds_connection;
    ];
    "capability-flow", [
      test_case "an SSO connection fn's caps must flow to main" `Quick
        t_connection_cap_flows_to_main;
      test_case "an sso server forces main to grant httpClient" `Quick
        t_sso_flow_requires_httpclient;
    ];
    "session-policy-clause", [
      test_case "sessionPolicy ShortSession sets the runtime policy" `Quick
        t_short_session_sets_the_policy;
      test_case "sessionPolicy StandardSession sets the runtime policy" `Quick
        t_standard_session_sets_the_policy;
      test_case "no clause sets no policy (default)" `Quick t_no_clause_sets_no_policy;
      test_case "an unknown policy name takes no effect (closed set)" `Quick
        t_unknown_policy_takes_no_effect;
    ];
    "public-origin-clause", [
      test_case "publicOrigin sets the runtime public origin" `Quick t_public_origin_is_set;
      test_case "no clause sets no public origin" `Quick t_no_public_origin_sets_none;
      test_case "sessionPolicy and publicOrigin coexist" `Quick t_both_clauses_coexist;
      test_case "publicOrigin fromEnv reads the origin from an env var" `Quick
        t_public_origin_from_env_is_set;
      test_case "a loopback http origin is accepted" `Quick t_public_origin_loopback_http_ok;
      test_case "an invalid literal origin is a compile error" `Quick
        t_public_origin_invalid_literal_rejected;
      test_case "trustedProxies sets the runtime trusted proxy set" `Quick
        t_trusted_proxies_is_set;
      test_case "no trustedProxies clause emits none" `Quick t_no_trusted_proxies_sets_none;
      test_case "healthProbePath sets the exempt path" `Quick t_health_probe_path_is_set;
      test_case "contentSecurityPolicy sets the server default CSP" `Quick t_content_security_policy_is_set;
    ];
    "sso-clause", [
      test_case "a well-formed sso clause validates" `Quick t_sso_clause_validates;
      test_case "an unknown connection fn is a compile error" `Quick t_sso_unknown_connection;
      test_case "an unknown onIdentity fn is a compile error" `Quick t_sso_unknown_on_identity;
      test_case "duplicate route segments are a compile error" `Quick t_sso_duplicate_segment;
    ];
    "session-revoked-clause", [
      test_case "sessionRevoked installs the renewal revocation hook" `Quick
        t_session_revoked_sets_hook;
      test_case "no clause installs no hook" `Quick t_no_session_revoked_sets_none;
      test_case "sessionRevoked naming an unknown fn is a compile error" `Quick
        t_session_revoked_unknown_fn;
    ];
    "sso-previous-key-clause", [
      test_case "sessionPreviousKey sets the previous session key at boot" `Quick
        t_previous_key_sets_the_param;
      test_case "no clause sets no previous key" `Quick t_no_previous_key_sets_none;
      test_case "sessionPreviousKey without sessionKey is a compile error" `Quick
        t_previous_key_requires_current;
    ];
    "listen-address-clause", [
      test_case "listenAddress Loopback binds 127.0.0.1" `Quick t_loopback_registers_127;
      test_case "listenAddress AllInterfaces binds all (#f)" `Quick
        t_all_interfaces_registers_false;
      test_case "no clause registers no bind address" `Quick
        t_no_listen_address_registers_nothing;
      test_case "an unknown bind name takes no effect (closed set)" `Quick
        t_unknown_listen_address_takes_no_effect;
    ];
    "login-methods-clause", [
      test_case "loginMethods [Sso] with no minting site compiles" `Quick
        t_login_sso_only_compiles;
      test_case "loginMethods [Sso] rejects an Http.setSessionCookie site" `Quick
        t_login_sso_rejects_minting;
      test_case "mixed mode requires the policy fn (attribution deferred)" `Quick
        t_login_mixed_mode_defers_attribution;
      test_case "Password without `via` is a compile error" `Quick
        t_login_password_needs_via;
      test_case "Password via an unknown fn is a compile error" `Quick
        t_login_password_unknown_fn;
      test_case "an unknown method keyword is a compile error" `Quick
        t_login_unknown_method;
      test_case "Machine licenses a session-minting site" `Quick
        t_login_machine_licenses_minting;
      test_case "loginMethods without Sso is a compile error" `Quick
        t_login_requires_sso;
    ];
  ]
