(** test_session_cookie.ml — compiler-level tests for the session-cookie surface
    (Tesl.Http: cookieCap, Http.setSessionCookie, Http.clearSessionCookie,
    Http.sessionToken).

    The POSITIVE end-to-end behaviour — the exact Set-Cookie line, the login →
    protected-endpoint round trip, tampering, two tenants, logout, and "a handler
    that sets a cookie and then fails mints nothing" — is asserted where it can
    actually be observed, in tests/session-cookie-tests.tesl.

    What lives here is everything whose assertion IS a refused compile, plus the
    two structural claims the feature rests on:

      1.  `Http.setSessionCookie someString` is a type error.  This is the whole
          reason the writer takes a `JwtToken`: the type system, not a lesson, is
          what guarantees a session cookie carries a signed value.
      2.  Calling either writer without `cookieCap` in scope is the ordinary
          capability error, and `cookieCap` arrives only by import — declaring an
          `api` or a `server` does not grant it.
      3.  Nothing is ambient: without the import the names are unbound.
      4.  The handler's RETURN TYPE is untouched by setting a cookie, so the
          generated TypeScript and Elm clients are byte-identical to the same
          handler without the call.  That is the property that keeps this feature
          out of every generated client.
      5.  `Http.sessionToken` is ungated (reading request data is not an effect)
          and yields a `Maybe JwtToken`, so `JWT.verify` has to sit between it and
          any fact. *)

(* ── Helpers (same shape as test_jwt.ml) ─────────────────────────────────── *)

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
        if parent = dir then Filename.current_dir_name else find parent
    in
    find (Filename.dirname Sys.executable_name)

let base_imports =
  "import Tesl.Prelude exposing [Int, String, Bool, Unit]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n\
   import Tesl.Dict exposing [Dict, Dict.singleton, Dict.lookup]\n\
   import Tesl.Time exposing [time]\n\
   import Tesl.Crypto exposing [Secret]\n\
   import Tesl.JWT exposing [jwt, JwtToken, JWT.sign, JWT.verify, JWT.renew, Authentic]\n"

let http_import =
  "import Tesl.Http exposing [HttpRequest, cookieCap, Http.setSessionCookie, \
   Http.clearSessionCookie, Http.sessionToken]\n"

let module_ ?(name = "M") ?(exports = "") ?(imports = base_imports ^ http_import) body =
  Printf.sprintf "module %s exposing [%s]\n%s\n%s" name exports imports body

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
  else String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) diags)

let contains needle haystack =
  let n = String.length needle and m = String.length haystack in
  if n > m then false
  else begin
    let found = ref false in
    for i = 0 to m - n do
      if String.sub haystack i n = needle then found := true
    done;
    !found
  end

let check_err_contains name src substr =
  let msg = compile_err name src in
  if not (contains substr msg) then
    Alcotest.failf "%s: expected an error mentioning %S, got:\n%s" name substr msg

(* A tiny signing helper every probe reuses, so no probe writes `Secret "…"`
   inline and trips the SEC003 hardcoded-key lint. *)
let prelude =
  {|
capability sessions implies jwt, time, cookieCap

fn testKey(s: String) -> Secret =
  Secret s

fn sessionKey() -> Secret =
  testKey "compiler-test-key"
|}

(* ── 1. The writer demands a signed value ────────────────────────────────── *)

let test_string_is_a_type_error () =
  let src =
    module_ ~exports:"setIt" (prelude ^ {|
fn setIt(raw: String) -> Bool requires [sessions] =
  let _ = Http.setSessionCookie raw
  True
|})
  in
  (* The message wording is the unifier's; what matters is that it names the two
     types, so a reader is told a String will not do. *)
  check_err_contains "string_is_a_type_error" src "JwtToken"

let test_jwt_token_is_accepted () =
  let src =
    module_ ~exports:"setIt" (prelude ^ {|
fn setIt(userId: String) -> Bool requires [sessions] =
  let token = JWT.sign (Dict.singleton "sub" userId) (sessionKey())
  let _ = Http.setSessionCookie token
  True
|})
  in
  let racket = compile_ok "jwt_token_is_accepted" src in
  if not (contains "Http.setSessionCookie" racket) then
    Alcotest.failf "the setSessionCookie call must reach the emitted Racket:\n%s" racket

(* ── 2. cookieCap gates both writers, and arrives only by import ─────────── *)

let test_set_without_capability () =
  let src =
    module_ ~exports:"setIt" (prelude ^ {|
fn setIt(userId: String) -> Bool requires [jwt, time] =
  let token = JWT.sign (Dict.singleton "sub" userId) (sessionKey())
  let _ = Http.setSessionCookie token
  True
|})
  in
  check_err_contains "set_without_capability" src "cookieCap"

let test_clear_without_capability () =
  let src =
    module_ ~exports:"logout" (prelude ^ {|
fn logout() -> Bool =
  let _ = Http.clearSessionCookie()
  True
|})
  in
  check_err_contains "clear_without_capability" src "cookieCap"

let test_capability_is_import_gated () =
  (* `cookieCap` named in a capability declaration WITHOUT importing it from
     Tesl.Http is not a capability that exists — the emailCap precedent. *)
  let src =
    module_
      ~imports:(base_imports ^ "import Tesl.Http exposing [HttpRequest]\n")
      ~exports:"noop"
      {|
capability sneaky implies cookieCap

fn noop() -> Bool requires [sneaky] =
  True
|}
  in
  check_err_contains "capability_is_import_gated" src "cookieCap"

(* ── 3. Nothing is ambient ───────────────────────────────────────────────── *)

let test_names_need_the_import () =
  let src =
    module_ ~imports:base_imports ~exports:"setIt" (prelude ^ {|
fn setIt(userId: String) -> Bool requires [sessions] =
  let token = JWT.sign (Dict.singleton "sub" userId) (sessionKey())
  let _ = Http.setSessionCookie token
  True
|})
  in
  check_err_contains "names_need_the_import" src "Http.setSessionCookie"

let test_unknown_http_export_is_rejected () =
  (* Tesl.Http gained a REAL export list with this feature; before that its
     imports were validated loosely and any name was accepted, which also hid its
     names from the stdlib binding-existence seam test. *)
  let src =
    module_
      ~imports:(base_imports ^ "import Tesl.Http exposing [HttpRequest, Http.setAnyHeader]\n")
      ~exports:"noop" {|
fn noop() -> Bool =
  True
|}
  in
  check_err_contains "unknown_http_export_is_rejected" src "Http.setAnyHeader"

(* ── 4. The reader is pure and yields a Maybe ────────────────────────────── *)

let test_reader_needs_no_capability () =
  let src =
    module_ ~exports:"peek" (prelude ^ {|
fn peek(request: HttpRequest) -> Bool =
  case Http.sessionToken request of
    Nothing -> False
    Something _ -> True
|})
  in
  ignore (compile_ok "reader_needs_no_capability" src)

let test_reader_result_is_not_a_token () =
  (* `Maybe JwtToken`, not `JwtToken`: the caller must destructure, which is what
     puts `JWT.verify` between the cookie and any fact. *)
  let src =
    module_ ~exports:"peek" (prelude ^ {|
fn peek(request: HttpRequest) -> Bool requires [sessions] =
  let _ = Http.setSessionCookie (Http.sessionToken request)
  True
|})
  in
  check_err_contains "reader_result_is_not_a_token" src "Maybe"

(* ── 5. Generated clients are untouched ──────────────────────────────────── *)

(* The same api/server twice, differing only in whether the handler sets a
   cookie.  The generated TS and Elm must be byte-identical: the handler's return
   type is what the client is generated from, and setting a cookie does not
   change it.  This is the property that keeps the whole feature invisible to
   every consumer of a Tesl API. *)
let client_program ~with_cookie =
  let cookie_line =
    if with_cookie then
      "  let _ = Http.setSessionCookie (JWT.sign (Dict.singleton \"sub\" \
       body.user) (sessionKey()))\n"
    else ""
  in
  String.concat ""
    [ "module ClientGen exposing [LoginSrv]\n";
      base_imports;
      http_import;
      "import Tesl.Json exposing [stringCodec, boolCodec]\n";
      prelude;
      "\nrecord LoginReq {\n  user: String\n}\n\n";
      "codec LoginReq {\n  toJson_forbidden\n\
      \  fromJson [ { user <- \"user\" with_codec stringCodec } ]\n}\n\n";
      "record LoginRes {\n  granted: Bool\n}\n\n";
      "codec LoginRes {\n  toJson {\n\
      \    granted -> \"granted\" with_codec boolCodec\n  }\n\
      \  fromJson_forbidden\n}\n\n";
      "handler doLogin(body: LoginReq) -> LoginRes requires [sessions] =\n";
      cookie_line;
      "  LoginRes { granted: True }\n\n";
      "api LoginApi {\n  post \"/login\"\n    body body: LoginReq\n\
      \    -> LoginRes\n}\n\n";
      "server LoginSrv for LoginApi {\n  doLogin = doLogin\n}\n" ]

(* Both generators run off the PARSED module (that is what `tesl generate ts`
   does after gating on the full checker — compiler/bin/main.ml:1229-1235), so the
   probe is: check both programs compile, then compare the emitted clients. *)
let generated name f =
  let of_src s =
    (match Compile.compile_source ~root_path:root "ClientGen.tesl" s with
     | Compile.Success _ -> ()
     | Compile.Failure diags ->
       Alcotest.failf "%s: probe program failed to compile: %s" name
         (String.concat "; "
            (List.map (fun (d : Compile.diagnostic) -> d.message) diags)));
    match Parser.parse_module "ClientGen.tesl" s with
    | Ok m -> f (Compile.merge_imported_client_decls m)
    | Err e -> Alcotest.failf "%s: probe program failed to parse: %s" name e.msg
  in
  (of_src (client_program ~with_cookie:false),
   of_src (client_program ~with_cookie:true))

let test_ts_client_unchanged () =
  let a, b = generated "ts_client_unchanged" Emit_ts.emit_ts in
  Alcotest.(check string)
    "setting a session cookie must not change the generated TypeScript" a b

let test_elm_client_unchanged () =
  let a, b = generated "elm_client_unchanged" (Emit_elm.emit_elm ?module_name_override:None) in
  Alcotest.(check string)
    "setting a session cookie must not change the generated Elm" a b

(* ── 5b. Sliding renewal (JWT.renew) ─────────────────────────────────────── *)

(* The blessed sliding-session shape: verify to get the claims, renew to get a
   fresh token, set the cookie.  All three inside one `auth` block, which is only
   possible because the cookie accumulator is scoped around the whole request
   rather than just the handler. *)
let test_sliding_auth_compiles () =
  let src =
    module_ ~exports:"slidingOwner"
      (prelude ^ {|
fact Authenticated (user: String)

fn subjectOf(claims: Dict String String) -> String =
  case Dict.lookup "sub" claims of
    Nothing -> ""
    Something s -> s

auth slidingOwner(request: HttpRequest) -> user: String ::: Authenticated user
  requires [sessions] =
  case Http.sessionToken request of
    Nothing -> fail 401 "no session"
    Something token ->
      let claims = check JWT.verify token (sessionKey())
      let fresh = check JWT.renew token (sessionKey())
      let _ = Http.setSessionCookie fresh
      ok (subjectOf claims) ::: Authenticated user
|})
  in
  let racket = compile_ok "sliding_auth_compiles" src in
  if not (contains "JWT.renew" racket) then
    Alcotest.failf "the JWT.renew call must reach the emitted Racket:\n%s" racket

(* `JWT.renew` is check-shaped, so it inherits the argument-position rule: passing
   it straight into another call is refused, because on the failure path the raw
   check-fail struct would become that call's argument.  Here that is the shape
   that matters most in the whole feature — a rejection being written into a
   `Set-Cookie` header — so it is worth pinning explicitly rather than trusting
   that JWT.renew was added to the right registry.

   NOT asserted here, because the language does not enforce it: a plain
   `let fresh = JWT.renew token key` with no `check` compiles. That gap is
   PRE-EXISTING and general — `let claims = JWT.verify token key` compiles too —
   so it is not something renewal introduced, and closing it belongs to whoever
   takes on the check-binding rule as a whole. The runtime is fail-closed in the
   meantime: `Http.setSessionCookie` validates that its argument is a well-formed
   JWT and raises on anything else, so a check-fail cannot reach a header. *)
let test_renew_in_argument_position_is_refused () =
  let src =
    module_ ~exports:"slide"
      (prelude ^ {|
fn slide(token: JwtToken) -> Bool requires [sessions] =
  let _ = Http.setSessionCookie (JWT.renew token (sessionKey()))
  True
|})
  in
  let msg = compile_err "renew_in_argument_position_is_refused" src in
  if not (contains "JWT.renew" msg && contains "argument position" msg) then
    Alcotest.failf
      "expected the check-shaped argument-position error naming JWT.renew, got:\n%s"
      msg

(* It signs, so it charges `time` as well as `jwt` — the JWT.sign rule.  A
   capability set with only `jwt` (and cookieCap for the writer) must be refused. *)
let test_renew_needs_time () =
  let src =
    module_ ~exports:"slide"
      (prelude ^ {|
fn slide(token: JwtToken) -> Bool requires [jwt, cookieCap] =
  let fresh = check JWT.renew token (sessionKey())
  let _ = Http.setSessionCookie fresh
  True
|})
  in
  check_err_contains "renew_needs_time" src "time"

(* A renewed token is a JwtToken, so it satisfies the cookie writer's parameter
   without any unwrapping — the two halves compose by type. *)
let test_renew_yields_a_token () =
  let src =
    module_ ~exports:"slide"
      (prelude ^ {|
fn slide(token: JwtToken) -> Bool requires [sessions] =
  let fresh = check JWT.renew token (sessionKey())
  let _ = Http.setSessionCookie fresh
  True
|})
  in
  ignore (compile_ok "renew_yields_a_token" src)

(* Renewal mints NO fact.  Demanding `Authentic` on the renewed token must fail:
   the fact belongs on JWT.verify's CLAIMS, where "this was verified" is the
   useful thing to prove, not on a fresh credential heading out to the browser. *)
let test_renew_mints_no_fact () =
  let src =
    module_ ~exports:"slide"
      (prelude ^ {|
fn needsAuthentic(t: JwtToken ::: Authentic t) -> Bool =
  True

fn slide(token: JwtToken) -> Bool requires [sessions] =
  let fresh = check JWT.renew token (sessionKey())
  needsAuthentic fresh
|})
  in
  check_err_contains "renew_mints_no_fact" src "Authentic"

let test_renew_charges_jwt_and_time () =
  match Type_system.stdlib_capabilities_of "JWT.renew" with
  | [ "jwt"; "time" ] -> ()
  | caps ->
    Alcotest.failf "JWT.renew must charge [jwt; time], got [%s]"
      (String.concat "; " caps)

(* ── 6. The registration seams ───────────────────────────────────────────── *)

let test_capability_provider_row () =
  match List.assoc_opt "Tesl.Http" Validation_common.tesl_stdlib_cap_map with
  | Some caps when List.mem_assoc "cookieCap" caps -> ()
  | _ ->
    Alcotest.fail
      "Tesl.Http must provide cookieCap in Validation_common.tesl_stdlib_cap_map, \
       or `capability X implies cookieCap` silently loses the capability (the \
       emailCap bug)"

let test_builtin_capability_name () =
  if not (List.mem "cookieCap" Ast.builtin_capability_names) then
    Alcotest.fail
      "cookieCap must be in Ast.builtin_capability_names, or it is treated as a \
       capability ROW VARIABLE rather than a concrete capability"

let test_writers_are_gated_in_the_table () =
  List.iter (fun fn ->
    match Type_system.stdlib_capabilities_of fn with
    | caps when List.mem "cookieCap" caps -> ()
    | caps ->
      Alcotest.failf "%s must charge cookieCap, got [%s]" fn (String.concat "; " caps))
    [ "Http.setSessionCookie"; "Http.clearSessionCookie" ]

let test_reader_is_not_gated_in_the_table () =
  match Type_system.stdlib_capabilities_of "Http.sessionToken" with
  | [] -> ()
  | caps ->
    Alcotest.failf
      "Http.sessionToken must be ungated (reading request data is not an \
       effect), got [%s]"
      (String.concat "; " caps)

let () =
  Alcotest.run "Session-Cookie"
    [ ( "types",
        [ Alcotest.test_case "a String is not a session cookie" `Quick
            test_string_is_a_type_error;
          Alcotest.test_case "a JwtToken is" `Quick test_jwt_token_is_accepted;
          Alcotest.test_case "the reader yields Maybe, not a token" `Quick
            test_reader_result_is_not_a_token ] );
      ( "capability",
        [ Alcotest.test_case "setSessionCookie needs cookieCap" `Quick
            test_set_without_capability;
          Alcotest.test_case "clearSessionCookie needs cookieCap" `Quick
            test_clear_without_capability;
          Alcotest.test_case "cookieCap is import-gated" `Quick
            test_capability_is_import_gated;
          Alcotest.test_case "the reader needs none" `Quick
            test_reader_needs_no_capability ] );
      ( "imports",
        [ Alcotest.test_case "nothing is ambient" `Quick test_names_need_the_import;
          Alcotest.test_case "Tesl.Http's export list is strict" `Quick
            test_unknown_http_export_is_rejected ] );
      ( "renew",
        [ Alcotest.test_case "the sliding auth block compiles" `Quick
            test_sliding_auth_compiles;
          Alcotest.test_case "renew is refused in argument position" `Quick
            test_renew_in_argument_position_is_refused;
          Alcotest.test_case "renew charges time as well as jwt" `Quick
            test_renew_needs_time;
          Alcotest.test_case "renew yields a JwtToken the writer accepts" `Quick
            test_renew_yields_a_token;
          Alcotest.test_case "renew mints no Authentic fact" `Quick
            test_renew_mints_no_fact;
          Alcotest.test_case "the capability table agrees" `Quick
            test_renew_charges_jwt_and_time ] );
      ( "clients",
        [ Alcotest.test_case "generated TypeScript is unchanged" `Quick
            test_ts_client_unchanged;
          Alcotest.test_case "generated Elm is unchanged" `Quick
            test_elm_client_unchanged ] );
      ( "seams",
        [ Alcotest.test_case "Tesl.Http provides cookieCap" `Quick
            test_capability_provider_row;
          Alcotest.test_case "cookieCap is a builtin capability name" `Quick
            test_builtin_capability_name;
          Alcotest.test_case "both writers charge cookieCap" `Quick
            test_writers_are_gated_in_the_table;
          Alcotest.test_case "the reader charges nothing" `Quick
            test_reader_is_not_gated_in_the_table ] ) ]
