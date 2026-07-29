(** Tesl.Regex — the compile-time pattern contract.

    `Tesl.Regex` is unusual for a regex library: the pattern is not data the
    program happens to hand a matcher at runtime, it is part of the program and
    is checked when the program is checked.  These tests pin the four rules that
    make that true, because every one of them is a rule a future change could
    quietly relax:

      VREGEX001  the pattern must parse in Tesl's subset of `pregexp`;
      VREGEX002  the pattern must be a string LITERAL at the call site — there
                 is no dynamic-pattern form, so a pattern can never come from
                 request data;
      VREGEX003  the pattern must not be able to backtrack catastrophically
                 (audit gap L6 — resource exhaustion);
      VREGEX004  every capture group must participate in every successful
                 match, which is what makes `Regex.captures : … -> Maybe (List
                 String)` honest without an inner `Maybe`.

    Rule 003's *soft* half — the ambiguity a syntactic rule cannot see — is
    bounded at runtime instead, and that bound is tested in
    tests/regex-runtime-tests.rkt (a pathological pattern against hostile input
    must not hang the process). *)

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

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-regex" "" in
  let path = Filename.concat dir "probe.tesl" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      try Unix.rmdir dir with _ -> ())
    (fun () -> f path)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler [ "--check"; path ] in
    if code <> 0 then failf "expected clean compile, got (exit %d):\n%s" code out)

let should_fail_with code_expected src =
  with_temp_file src (fun path ->
    let code, out = run_compiler [ "--check"; path ] in
    if code = 0 then
      failf "expected %s, but the program compiled clean:\n%s" code_expected src;
    let re = Str.regexp_string ("error[" ^ code_expected ^ "]") in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected %s, got:\n%s" code_expected out)

(* One `Regex.matches` call in a plain fn — the shape every rule is stated on. *)
let prog body =
  Printf.sprintf
    "module Probe exposing [f]\n\
     import Tesl.Prelude exposing [Bool(..), String, Int, List]\n\
     import Tesl.Maybe exposing [Maybe(..)]\n\
     import Tesl.List exposing [List.length]\n\
     import Tesl.Regex exposing [Regex.matches, Regex.find, Regex.findAll, \
     Regex.captures, Regex.replace, Regex.split]\n\
     %s\n"
    body

(** How a pattern is SPELLED inside a Tesl string literal.  Tesl string literals
    process escapes (LANGUAGE-SPEC.md §8.5), so a regex backslash is written
    doubled — `"\\d+"` in Tesl source is the pattern `\d+`.  The tests carry the
    pattern (what the validator sees) and derive the source spelling here, so a
    single list can drive both the end-to-end and the unit checks. *)
let tesl_spelling (pat : string) : string =
  String.concat "" (List.map (function '\\' -> "\\\\" | c -> String.make 1 c)
                      (List.init (String.length pat) (String.get pat)))

let matches_pat pat =
  prog
    (Printf.sprintf "fn f(s: String) -> Bool =\n  Regex.matches \"%s\" s"
       (tesl_spelling pat))

let accepts pat () = should_pass (matches_pat pat)
let rejects code pat () = should_fail_with code (matches_pat pat)

(* ── Patterns that must be accepted ───────────────────────────────────────── *)

let accepted_patterns =
  [ ("a plain anchored class", "^[a-z]+$");
    ("an email-shaped pattern", "^[^@ ]+@[^@ ]+[.][a-z]{2,}$");
    ("the slug idiom (distinguished separator)", "^[a-z0-9]+(?:-[a-z0-9]+)*$");
    ("the dotted-label idiom", "^[a-z]+(?:[.][a-z]+)+$");
    ("alternation not under a quantifier", "^(?:cat|dog)$");
    ("an unquantified capture group", "^([a-z]+)@([a-z]+)$");
    ("an optional group with a quantified body", "^a(?:bc+)?d$");
    ("exact and open repetition bounds", "^[0-9]{3}-[0-9]{2,}$");
    ("word-boundary anchors", "\\bcat\\b");
    ("escaped metacharacters", "^[a-z]+\\?$");
    ("class escapes", "^\\d+\\s\\w+$");
    ("a negated class", "^[^0-9]+$") ]

(* ── VREGEX001: malformed / outside the subset ────────────────────────────── *)

let malformed_patterns =
  [ ("unterminated class", "[a-z");
    ("unterminated group", "(abc");
    ("unmatched close paren", "abc)");
    ("unmatched close brace", "abc}");
    ("empty class", "[]");
    ("empty pattern", "");
    ("reversed repetition bounds", "a{2,1}");
    ("reversed character range", "[z-a]");
    ("repetition bound over the limit", "x{1001}");
    ("quantifier with nothing to repeat", "*a");
    ("double quantifier", "a**");
    ("lazy quantifier", "a+?b");
    ("lookahead", "(?=abc)x");
    ("lookbehind", "(?<=a)b");
    ("inline flags", "(?i:abc)");
    ("named group", "(?<name>a)");
    ("POSIX bracket class", "[[:alpha:]]+");
    ("quantified anchor", "^*a");
    ("unsupported escape", "\\Qabc") ]

(* ── VREGEX003: catastrophic backtracking ─────────────────────────────────── *)

let unsafe_patterns =
  [ ("the classic (a+)+", "^(?:a+)+$");
    ("overlapping nested repetition", "^(?:aa+)+$");
    ("alternation under a quantifier", "^(?:a|a)*$");
    ("nullable body under a quantifier", "^(?:x*)*$");
    ("a repeated group whose body repeats", "^(?:[a-z]+[.])+[a-z]+$");
    ("adjacent overlapping repetitions", "^[0-9]+[0-9]*$") ]

(* ── VREGEX004: a capture group that may not participate ──────────────────── *)

let capture_rule_patterns =
  [ ("optional capture group", "^(a)?b$");
    ("repeated capture group", "^(ab)+$");
    ("capture inside an alternation branch", "^(a)|(b)$");
    ("capture nested in a repeated group", "^(?:(ab))+$") ]

(* ── VREGEX002: the pattern must be a literal ─────────────────────────────── *)

let t_pattern_from_a_parameter () =
  should_fail_with "VREGEX002"
    (prog "fn f(p: String, s: String) -> Bool =\n  Regex.matches p s")

let t_pattern_from_a_local_binding () =
  (* Even a name bound to a literal one line up is rejected: the rule is
     "written at the call site", so there is exactly one shape to look for and
     no constant folding to trust.  Name the predicate, not the pattern. *)
  should_fail_with "VREGEX002"
    (prog
       "fn f(s: String) -> Bool =\n\
       \  let p = \"^[a-z]+$\"\n\
       \  Regex.matches p s")

let t_pattern_from_an_interpolation () =
  should_fail_with "VREGEX002"
    (prog
       "fn f(part: String, s: String) -> Bool =\n\
       \  Regex.matches \"^${part}$\" s")

let t_pattern_from_a_concatenation () =
  should_fail_with "VREGEX002"
    (prog "fn f(part: String, s: String) -> Bool =\n  Regex.matches (\"^\" ++ part) s")

(* A `$` in a Tesl string lexes as an interpolation even with no `${…}` hole,
   so an ANCHORED pattern only works if the literal check sees through that. *)
let t_dollar_anchor_is_still_a_literal () =
  should_pass (matches_pat "^abc$")

(* ── The rule holds in every expression position, not just `fn` bodies ────── *)

let t_rule_holds_inside_a_test_block () =
  should_fail_with "VREGEX003"
    (prog
       "test \"t\" {\n\
       \  expect Regex.matches \"^(?:a+)+$\" \"aaa\" == True\n\
        }")

let t_rule_holds_inside_a_lambda () =
  should_fail_with "VREGEX001"
    (prog
       "import Tesl.List exposing [List.filter]\n\
        fn f(xs: List String) -> List String =\n\
       \  List.filter (fn(x: String) -> Regex.matches \"[a-z\" x) xs")

let t_rule_holds_in_a_check_function () =
  should_fail_with "VREGEX003"
    (prog
       "fact ValidThing (s: String)\n\
        check requireThing(raw: String) -> raw: String ::: ValidThing raw =\n\
       \  if Regex.matches \"^(?:a+)+$\" raw then\n\
       \    ok raw ::: ValidThing raw\n\
       \  else\n\
       \    fail 400 \"nope\"")

(* ── The whole surface is reachable and typed ─────────────────────────────── *)

let t_every_function_typechecks () =
  should_pass
    (prog
       "fn f(s: String) -> Bool =\n\
       \  Regex.matches \"^[a-z]+$\" s\n\
        fn g(s: String) -> Maybe String =\n\
       \  Regex.find \"[0-9]+\" s\n\
        fn h(s: String) -> Int =\n\
       \  List.length (Regex.findAll \"[0-9]+\" s)\n\
        fn i(s: String) -> Maybe (List String) =\n\
       \  Regex.captures \"^([a-z]+)-([a-z]+)$\" s\n\
        fn j(s: String) -> String =\n\
       \  Regex.replace \"[0-9]\" s \"#\"\n\
        fn k(s: String) -> List String =\n\
       \  Regex.split \"[,;]\" s")

let t_names_need_the_import () =
  with_temp_file
    "module Probe exposing [f]\n\
     import Tesl.Prelude exposing [Bool(..), String]\n\
     fn f(s: String) -> Bool = Regex.matches \"^a$\" s\n"
    (fun path ->
      let code, out = run_compiler [ "--check"; path ] in
      if code = 0 then
        failf "Regex.matches resolved without `import Tesl.Regex`:\n%s" out)

(* ── Table-level invariants (no shelling out) ─────────────────────────────── *)

let regex_exports () =
  match List.assoc_opt "Tesl.Regex" Type_system.tesl_module_exports with
  | Some names -> names
  | None -> failf "Tesl.Regex has no export row in tesl_module_exports"

let t_every_export_has_a_scheme () =
  let env = Type_system.make_stdlib_env () in
  let missing = List.filter (fun n -> not (List.mem_assoc n env)) (regex_exports ()) in
  if missing <> [] then
    failf
      "Tesl.Regex export(s) with no stdlib_env signature (they would type-check \
       as anything): %s"
      (String.concat ", " missing)

let t_exports_match_the_lint_table () =
  (* The literal/safety rules are keyed on Regex_lint.regex_functions.  A
     function exported but absent from that table would take its pattern
     UNCHECKED — the fail-open shape this whole feature exists to avoid. *)
  let exported = List.sort compare (regex_exports ()) in
  let linted = List.sort compare (List.map fst Regex_lint.regex_functions) in
  if exported <> linted then
    failf
      "Tesl.Regex exports and Regex_lint.regex_functions disagree.\n  exports: \
       %s\n  linted:  %s"
      (String.concat ", " exported)
      (String.concat ", " linted)

let t_pattern_is_always_argument_one () =
  List.iter
    (fun (name, idx) ->
      if idx <> 0 then
        failf
          "%s takes its pattern at argument %d; the whole surface promises \
           argument 1 so the rule can be stated once"
          name idx)
    Regex_lint.regex_functions

let t_captures_has_no_inner_maybe () =
  (* The VREGEX004 rule is what buys this signature; if the return type ever
     drifts to `Maybe (List (Maybe String))` the rule has stopped paying. *)
  let env = Type_system.make_stdlib_env () in
  match List.assoc_opt "Regex.captures" env with
  | None -> failf "Regex.captures has no stdlib_env scheme"
  | Some sch ->
    let _args, ret = Type_system.split_fun_type sch.Type_system.mono in
    let rendered = Type_system.pp_ty ret in
    if rendered <> "Maybe (List String)" then
      failf "Regex.captures returns %s, expected `Maybe (List String)`" rendered

(* ── The validator itself, without the compiler round-trip ────────────────── *)

let t_validator_agrees_with_the_codes () =
  let expect_code want pat =
    match Regex_lint.validate_pattern pat with
    | Ok () -> failf "pattern %S was accepted, expected %s" pat want
    | Error r ->
      if r.Regex_lint.code <> want then
        failf "pattern %S gave %s (%s), expected %s" pat r.Regex_lint.code
          r.Regex_lint.message want
  in
  List.iter (fun (_, p) -> expect_code "VREGEX001" p) malformed_patterns;
  List.iter (fun (_, p) -> expect_code "VREGEX003" p) unsafe_patterns;
  List.iter (fun (_, p) -> expect_code "VREGEX004" p) capture_rule_patterns;
  List.iter
    (fun (label, p) ->
      match Regex_lint.validate_pattern p with
      | Ok () -> ()
      | Error r ->
        failf "%s (%S) was rejected as %s: %s" label p r.Regex_lint.code
          r.Regex_lint.message)
    accepted_patterns

let t_capture_count_matches_the_pattern () =
  List.iter
    (fun (pat, want) ->
      let got = Regex_lint.capture_count pat in
      if got <> want then
        failf "capture_count %S = %d, expected %d" pat got want)
    [ ("^[a-z]+$", 0);
      ("^([a-z]+)$", 1);
      ("^([a-z]+)@([a-z]+)$", 2);
      ("^(?:[a-z]+)@([a-z]+)$", 1) ]

(* ── Every registered code is a real registry entry ───────────────────────── *)

let t_codes_are_registered () =
  List.iter
    (fun c ->
      if Error_codes.lookup c = None then
        failf "%s is emitted but missing from the Error_codes registry" c)
    [ "VREGEX001"; "VREGEX002"; "VREGEX003"; "VREGEX004" ]

let () =
  run "regex-surface"
    [ ( "accepted",
        List.map (fun (label, p) -> test_case label `Quick (accepts p))
          accepted_patterns );
      ( "VREGEX001-malformed",
        List.map
          (fun (label, p) -> test_case label `Quick (rejects "VREGEX001" p))
          malformed_patterns );
      ( "VREGEX003-backtracking",
        List.map
          (fun (label, p) -> test_case label `Quick (rejects "VREGEX003" p))
          unsafe_patterns );
      ( "VREGEX004-capture-participation",
        List.map
          (fun (label, p) -> test_case label `Quick (rejects "VREGEX004" p))
          capture_rule_patterns );
      ( "VREGEX002-literal-only",
        [ test_case "a pattern from a parameter" `Quick t_pattern_from_a_parameter;
          test_case "a pattern from a local binding" `Quick
            t_pattern_from_a_local_binding;
          test_case "an interpolated pattern" `Quick t_pattern_from_an_interpolation;
          test_case "a concatenated pattern" `Quick t_pattern_from_a_concatenation;
          test_case "a `$` anchor is still a literal" `Quick
            t_dollar_anchor_is_still_a_literal ] );
      ( "positions",
        [ test_case "inside a test block" `Quick t_rule_holds_inside_a_test_block;
          test_case "inside a lambda" `Quick t_rule_holds_inside_a_lambda;
          test_case "inside a check function" `Quick t_rule_holds_in_a_check_function ] );
      ( "surface",
        [ test_case "every function typechecks" `Quick t_every_function_typechecks;
          test_case "the names are import-gated" `Quick t_names_need_the_import ] );
      ( "tables",
        [ test_case "every export has a stdlib_env scheme" `Quick
            t_every_export_has_a_scheme;
          test_case "exports match the lint table" `Quick t_exports_match_the_lint_table;
          test_case "the pattern is argument 1 everywhere" `Quick
            t_pattern_is_always_argument_one;
          test_case "Regex.captures has no inner Maybe" `Quick
            t_captures_has_no_inner_maybe;
          test_case "the VREGEX codes are registered" `Quick t_codes_are_registered ] );
      ( "validator",
        [ test_case "the validator agrees with the codes" `Quick
            t_validator_agrees_with_the_codes;
          test_case "capture_count matches the pattern" `Quick
            t_capture_count_matches_the_pattern ] )
    ]
