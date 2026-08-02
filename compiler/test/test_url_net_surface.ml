(** Tesl.Url / Tesl.Net — the compile-time surface contract (GitHub #68).

    The RUNTIME behaviour (which spellings of 127.0.0.1 fold together, which
    URLs are refused) is pinned in tests/url-net-runtime-tests.rkt and
    tests/url-net-tests.tesl.  What is pinned HERE is the part of the design
    that only the compiler can enforce, and that a later edit could quietly
    relax without any runtime test noticing:

      OPAQUE     `Url` has no constructor, so `Url.parse` is the ONLY way to get
                 one.  If `Url "…"` ever became legal, an unnormalized string
                 could pose as a parsed URL and every guarantee `Url.host`
                 makes would be void.
      NO FIELDS  `u.host` is not a record read; it is an unknown-field error
                 carrying the accessor hint.  (A Url that answered `.host`
                 structurally would resolve against whatever record happened to
                 have a `host` field.)
      EXHAUSTIVE `case Net.classifyHost h of …` must be checked against all nine
                 HostClass variants.  This is the entire argument for
                 classifying into an ADT instead of shipping nine predicates:
                 the bug the issue reports IS a forgotten spelling, so a
                 forgotten range has to be a compile error.
      PURE       neither module contributes a capability, so a handler with no
                 `requires` row can validate a URL.
      GATED      the names are import-gated like every other stdlib surface. *)

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
  let code =
    match Unix.close_process_in ic with
    | Unix.WEXITED c -> c
    | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n
  in
  (code, out)

let failf fmt = Printf.ksprintf failwith fmt

(* The module header must match the file name (V001), so the probe file is
   always `probe.tesl` and the module is always `Probe`. *)
let with_probe content f =
  let dir = Filename.temp_dir "tesl-url-net" "" in
  let path = Filename.concat dir "probe.tesl" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      try Unix.rmdir dir with _ -> ())
    (fun () -> f path)

let contains hay needle =
  let n = String.length needle and h = String.length hay in
  let rec go i = i + n <= h && (String.sub hay i n = needle || go (i + 1)) in
  n = 0 || go 0

let should_pass src =
  with_probe src (fun path ->
    let code, out = run_compiler [ "--check"; path ] in
    if code <> 0 then failf "expected clean compile, got (exit %d):\n%s" code out)

let should_fail_containing needle src =
  with_probe src (fun path ->
    let code, out = run_compiler [ "--check"; path ] in
    if code = 0 then failf "expected a rejection, but this compiled clean:\n%s" src;
    if not (contains out needle) then
      failf "expected a diagnostic mentioning %S, got:\n%s" needle out)

let prog imports body =
  Printf.sprintf "module Probe exposing [f]\n%s\n%s\n" imports body

let url_imports =
  "import Tesl.Prelude exposing [String, Bool(..), Int]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n\
   import Tesl.Url exposing [Url, Url.parse, Url.host, Url.port, Url.scheme, \
   Url.userInfo, Url.toString]"

let net_imports =
  "import Tesl.Prelude exposing [String, Bool(..)]\n\
   import Tesl.Net exposing [HostClass(..), Net.classifyHost, \
   Net.isForbiddenHost, Net.normalizeHost]"

(* ── The happy path both modules exist for ────────────────────────────────── *)

let t_parse_then_classify () =
  should_pass
    (prog (url_imports ^ "\n" ^
           "import Tesl.Net exposing [Net.isForbiddenHost]")
       "fn f(raw: String) -> Bool =\n\
       \  case Url.parse raw of\n\
       \    Nothing -> False\n\
       \    Something u -> !(Net.isForbiddenHost (Url.host u))")

let t_pure_no_capability () =
  (* A `requires []` row is the strongest statement that neither module charges
     a capability: adding one later would break this. *)
  should_pass
    (prog url_imports
       "fn f(raw: String) -> Bool requires [] =\n\
       \  case Url.parse raw of\n\
       \    Nothing -> False\n\
       \    Something u -> Url.scheme u == \"https\"")

(* ── Url is opaque ────────────────────────────────────────────────────────── *)

let t_no_url_constructor () =
  should_fail_containing "Url"
    (prog url_imports "fn f(raw: String) -> Url =\n  Url raw")

let t_no_field_access () =
  should_fail_containing "has no field"
    (prog url_imports
       "fn f(raw: String) -> String =\n\
       \  case Url.parse raw of\n\
       \    Nothing -> \"\"\n\
       \    Something u -> u.host")

let t_field_error_names_the_accessors () =
  should_fail_containing "Url.scheme"
    (prog url_imports
       "fn f(raw: String) -> String =\n\
       \  case Url.parse raw of\n\
       \    Nothing -> \"\"\n\
       \    Something u -> u.host")

let t_url_is_not_a_string () =
  should_fail_containing "cannot unify"
    (prog url_imports "fn f(raw: String) -> String =\n  Url.host raw")

(* ── HostClass is an exhaustively-checked ADT ─────────────────────────────── *)

let all_arms =
  "    Loopback -> \"lo\"\n\
  \    PrivateIp -> \"priv\"\n\
  \    LinkLocal -> \"ll\"\n\
  \    Cgnat -> \"cgnat\"\n\
  \    Multicast -> \"mc\"\n\
  \    Unspecified -> \"unspec\"\n\
  \    PublicIp -> \"pub\"\n\
  \    DomainName -> \"name\"\n\
  \    InvalidHost -> \"bad\""

let t_exhaustive_case_compiles () =
  should_pass
    (prog net_imports
       (Printf.sprintf
          "fn f(h: String) -> String =\n  case Net.classifyHost h of\n%s" all_arms))

let t_missing_range_is_an_error () =
  (* The regression the ADT exists to prevent: one range silently unhandled. *)
  should_fail_containing "non-exhaustive case"
    (prog net_imports
       "fn f(h: String) -> String =\n\
       \  case Net.classifyHost h of\n\
       \    Loopback -> \"lo\"\n\
       \    PrivateIp -> \"priv\"\n\
       \    LinkLocal -> \"ll\"\n\
       \    Cgnat -> \"cgnat\"\n\
       \    Multicast -> \"mc\"\n\
       \    Unspecified -> \"unspec\"\n\
       \    PublicIp -> \"pub\"\n\
       \    DomainName -> \"name\"")

let t_missing_range_names_it () =
  should_fail_containing "InvalidHost"
    (prog net_imports
       "fn f(h: String) -> String =\n\
       \  case Net.classifyHost h of\n\
       \    Loopback -> \"lo\"\n\
       \    PrivateIp -> \"priv\"\n\
       \    LinkLocal -> \"ll\"\n\
       \    Cgnat -> \"cgnat\"\n\
       \    Multicast -> \"mc\"\n\
       \    Unspecified -> \"unspec\"\n\
       \    PublicIp -> \"pub\"\n\
       \    DomainName -> \"name\"")

(* ── Import gating ────────────────────────────────────────────────────────── *)

let t_url_names_are_import_gated () =
  should_fail_containing "import Tesl.Url"
    (prog "import Tesl.Prelude exposing [String]"
       "fn f(raw: String) -> String =\n  Url.host raw")

let t_net_names_are_import_gated () =
  should_fail_containing "import Tesl.Net"
    (prog "import Tesl.Prelude exposing [String, Bool(..)]"
       "fn f(h: String) -> Bool =\n  Net.isForbiddenHost h")

(* ── Result shapes the type checker must keep honest ──────────────────────── *)

let t_parse_returns_maybe () =
  should_fail_containing "cannot unify"
    (prog url_imports "fn f(raw: String) -> Url =\n  Url.parse raw")

let t_port_returns_maybe_int () =
  should_pass
    (prog url_imports
       "fn f(raw: String) -> Maybe Int =\n\
       \  case Url.parse raw of\n\
       \    Nothing -> Nothing\n\
       \    Something u -> Url.port u")

let t_normalize_returns_maybe_string () =
  should_pass
    (prog net_imports
       "fn f(h: String) -> String =\n\
       \  case Net.normalizeHost h of\n\
       \    Nothing -> \"\"\n\
       \    Something n -> n")

let () =
  run "Url-Net-Surface"
    [ ( "happy-path",
        [ test_case "parse then classify" `Quick t_parse_then_classify;
          test_case "pure: no capability charged" `Quick t_pure_no_capability ] );
      ( "url-opaque",
        [ test_case "no Url constructor" `Quick t_no_url_constructor;
          test_case "no structural field read" `Quick t_no_field_access;
          test_case "the field error names the accessors" `Quick
            t_field_error_names_the_accessors;
          test_case "a String is not a Url" `Quick t_url_is_not_a_string ] );
      ( "hostclass-exhaustive",
        [ test_case "all nine arms compile" `Quick t_exhaustive_case_compiles;
          test_case "a missing range is rejected" `Quick t_missing_range_is_an_error;
          test_case "the missing range is named" `Quick t_missing_range_names_it ] );
      ( "import-gating",
        [ test_case "Url names need their import" `Quick t_url_names_are_import_gated;
          test_case "Net names need their import" `Quick t_net_names_are_import_gated ] );
      ( "result-shapes",
        [ test_case "parse returns Maybe Url" `Quick t_parse_returns_maybe;
          test_case "port returns Maybe Int" `Quick t_port_returns_maybe_int;
          test_case "normalizeHost returns Maybe String" `Quick
            t_normalize_returns_maybe_string ] ) ]
