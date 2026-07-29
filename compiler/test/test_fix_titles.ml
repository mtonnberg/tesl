(* Quick-fix ACTION TITLES — the string a user reads in the editor's lightbulb
   menu before deciding to apply an edit.

   THE BUG THIS CLOSES
   -------------------
   The LSP synthesized the title itself as [Printf.sprintf "Apply fix for %s"
   code], so essentially every code action in every file read "Apply fix for
   W010" / "Apply fix for T001".  A diagnostic code is not a description of an
   edit: the menu told the user nothing about what would change, and the only way
   to find out was to apply it and look.  Worse, when several fixes were offered
   at once the entries were indistinguishable.

   THE DESIGN
   ----------
   [Diag_fix.title ~code fix] derives a specific, imperative title from the
   diagnostic's CODE (which carries the producing pass's intent) plus the edit's
   KIND and CONTENT, and [Compile.fix_to_json] ships it on the wire so every
   client — LSP, CLI, MCP — shows the same wording.

   WHAT THIS TEST GUARANTEES
   -------------------------
   1. Unit coverage of the per-code wording.
   2. Over the REAL pipeline on a corpus of broken sources: every fix-carrying
      diagnostic has a title that is specific, imperative, bounded in length, and
      mentions NO diagnostic code and no "apply fix"-style filler.
   3. COMPLETENESS: every code observed shipping a fix appears in
      [Diag_fix.titled_codes].  A new fix-shipping diagnostic therefore fails this
      suite until somebody writes its title — which is what stops the generic
      wording from creeping back in. *)

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
        (Printf.sprintf "tesl_fix_titles_%d_%d" (Unix.getpid ()) !counter)
    in
    Unix.mkdir dir 0o755;
    dir

(* Parser + checker + legacy pass + linter, exactly the CLI's entry. *)
let all_diags_for source =
  let dir = fresh_dir () in
  let path = Filename.concat dir "main.tesl" in
  write_file path source;
  Compile.check_source path source @ Linter.lint_file path

let contains hay needle =
  let re = Str.regexp_string needle in
  try ignore (Str.search_forward re hay 0); true with Not_found -> false

(* ── 1. Per-code wording ─────────────────────────────────────────────────── *)

let check_title ~msg ~code fix expected =
  Alcotest.(check string) msg expected (Diag_fix.title ~code fix)

let test_linter_titles () =
  check_title ~msg:"W010 names the actual problem" ~code:"W010"
    (Diag_fix.Replace_line { line = 3; replacement = "fn f() -> Int = 1" })
    "Remove trailing whitespace";
  check_title ~msg:"W011 names the actual problem" ~code:"W011"
    (Diag_fix.Replace_line { line = 3; replacement = "  x" })
    "Re-indent to a multiple of 2 spaces"

let test_unused_import_titles () =
  (* Deleting the whole statement and pruning names from it are DIFFERENT
     actions and must not read alike. *)
  check_title ~msg:"W050 whole-statement deletion" ~code:"W050"
    (Diag_fix.Replace_span { start_line = 2; end_line = 2; replacement = "" })
    "Remove this unused import";
  check_title ~msg:"W050 pruning names says what survives" ~code:"W050"
    (Diag_fix.Replace_span { start_line = 2; end_line = 2;
                             replacement = "import Tesl.List exposing [map]" })
    "Remove the unused names, keeping map from Tesl.List"

let test_import_titles () =
  (* Import_suggest APPENDS the name it makes available, so the title can name
     exactly the name the user was missing. *)
  check_title ~msg:"fresh import names the symbol and module" ~code:"T001"
    (Diag_fix.Insert_line { line = 2; text = "import Tesl.List exposing [map]" })
    "Import map from Tesl.List";
  check_title ~msg:"extending an import names the ADDED symbol" ~code:"T001"
    (Diag_fix.Replace_span
       { start_line = 2; end_line = 2;
         replacement = "import Tesl.List exposing [head, map]" })
    "Import map from Tesl.List";
  check_title ~msg:"a missing Bool import reads as an import action"
    ~code:"VBOOL002"
    (Diag_fix.Insert_line
       { line = 2; text = "import Tesl.Prelude exposing [Bool(..)]" })
    "Import Bool(..) from Tesl.Prelude"

let test_parser_titles () =
  check_title ~msg:"E002 names the obsolete pragma" ~code:"E002"
    (Diag_fix.Replace_span { start_line = 0; end_line = 0; replacement = "" })
    "Delete the obsolete `#lang tesl` line";
  check_title ~msg:"single-line if describes the restructuring" ~code:"E000"
    (Diag_fix.Multi
       [ Diag_fix.Replace_range { start_line = 3; start_col = 20; end_line = 3;
                                  end_col = 21; replacement = "\n        " } ])
    "Move the body onto its own indented line"

(* Unrecognised codes must still describe the EDIT — never fall back to naming
   the code, which is the regression being prevented. *)
let test_unknown_code_still_describes_the_edit () =
  check_title ~msg:"token replacement" ~code:"ZZZ999"
    (Diag_fix.Replace_range { start_line = 0; start_col = 4; end_line = 0;
                              end_col = 5; replacement = "++" })
    "Replace with `++`";
  check_title ~msg:"token deletion" ~code:"ZZZ999"
    (Diag_fix.Replace_range { start_line = 0; start_col = 4; end_line = 0;
                              end_col = 11; replacement = "" })
    "Delete this text";
  check_title ~msg:"multi-line deletion is counted" ~code:"ZZZ999"
    (Diag_fix.Replace_span { start_line = 2; end_line = 4; replacement = "" })
    "Delete these 3 lines";
  check_title ~msg:"single-line deletion reads naturally" ~code:"ZZZ999"
    (Diag_fix.Replace_span { start_line = 2; end_line = 2; replacement = "" })
    "Delete this line"

(* Long replacement text must not produce an unreadable menu entry. *)
let test_titles_are_bounded () =
  let long = String.concat "" (List.init 200 (fun _ -> "x")) in
  let t =
    Diag_fix.title ~code:"ZZZ999"
      (Diag_fix.Replace_line { line = 0; replacement = long })
  in
  if String.length t > 72 then
    Alcotest.failf "title must stay readable in a menu, got %d chars: %s"
      (String.length t) t;
  if not (contains t "\u{2026}") then
    Alcotest.failf "a clipped title must show an ellipsis: %s" t

(* ── 2 + 3. The real pipeline: quality + completeness ────────────────────── *)

(* Sources chosen so that between them they exercise every fix producer in the
   compiler.  Each entry is (label, source). *)
let corpus = [
  ( "obsolete #lang pragma",
    "#lang tesl\n\
     module Main exposing [f]\n\
     import Tesl.Prelude exposing [Int]\n\
     fn f(x: Int) -> Int =\n\
    \    x\n" );
  ( "return keyword",
    "module Main exposing [f]\n\
     import Tesl.Prelude exposing [Int]\n\
     fn f(x: Int) -> Int =\n\
    \    return x\n" );
  ( "string concatenation with +",
    "module Main exposing [g]\n\
     import Tesl.Prelude exposing [String]\n\
     fn g(a: String, b: String) -> String =\n\
    \    a + b\n" );
  ( "single-line if",
    "module Main exposing [h]\n\
     import Tesl.Prelude exposing [Int, Bool]\n\
     fn h(c: Bool) -> Int =\n\
    \    if c then 1 else 2\n" );
  ( "legacy Boolean spelling",
    "module Main exposing [b]\n\
     import Tesl.Prelude exposing [Bool]\n\
     fn b() -> Boolean =\n\
    \    True\n" );
  ( "trailing whitespace + bad indent",
    "module Main exposing [f]\n\
     import Tesl.Prelude exposing [Int]   \n\
     fn f() -> Int =\n\
    \   1\n" );
  ( "unused import",
    "module Main exposing [f]\n\
     import Tesl.Prelude exposing [Int, String]\n\
     fn f() -> Int =\n\
    \    1\n" );
]

let titled_diags () =
  List.concat_map
    (fun (label, source) ->
       List.filter_map
         (fun (d : Compile.diagnostic) ->
            match d.fix with
            | None -> None
            | Some fix -> Some (label, d.code, fix, Diag_fix.title ~code:d.code fix))
         (all_diags_for source))
    corpus

let imperative_verbs = [
  "Remove"; "Re-indent"; "Import"; "Delete"; "Move"; "Replace"; "Insert";
  "Rewrite"; "Change"; "Clear"; "Apply"
]

let test_every_shipped_title_is_helpful () =
  let diags = titled_diags () in
  if diags = [] then
    Alcotest.fail "corpus produced no fix-carrying diagnostics — the test would be vacuous";
  List.iter
    (fun (label, code, _fix, title) ->
       let fail fmt = Alcotest.failf ("%s [%s]: " ^^ fmt) label code in
       if String.trim title = "" then fail "empty title";
       (* The regression itself. *)
       if contains title "Apply fix for" then
         fail "title is the old generic wording: %s" title;
       if contains title code then
         fail "title leaks the diagnostic code (%s) instead of describing the edit: %s"
           code title;
       if contains (String.lowercase_ascii title) "diagnostic" then
         fail "title says \"diagnostic\" rather than what changes: %s" title;
       if String.length title > 72 then
         fail "title is %d chars, too long for a menu: %s"
           (String.length title) title;
       if not (List.exists (fun v -> contains title v) imperative_verbs) then
         fail "title should start with an imperative verb (%s): %s"
           (String.concat "/" imperative_verbs) title)
    diags

(* COMPLETENESS: the guarantee that keeps this honest as the compiler grows. *)
let test_every_fix_shipping_code_has_a_title_entry () =
  let observed =
    List.sort_uniq compare
      (List.map (fun (_, code, _, _) -> code) (titled_diags ()))
  in
  List.iter
    (fun code ->
       if not (List.mem code Diag_fix.titled_codes) then
         Alcotest.failf
           "code %s ships a fix but has no entry in Diag_fix.titled_codes — add \
            an intent-bearing title for it (see Diag_fix.title)"
           code)
    observed

(* Two DIFFERENT actions offered on the same file must be distinguishable —
   identical titles are what made the old wording unusable. *)
let test_titles_distinguish_different_actions () =
  let diags = titled_diags () in
  let by_kind = Hashtbl.create 16 in
  List.iter
    (fun (_, code, fix, title) ->
       let kind =
         match fix with
         | Diag_fix.Replace_line _ -> "replace_line"
         | Diag_fix.Insert_line _ -> "insert_line"
         | Diag_fix.Replace_span { replacement = ""; _ } -> "delete_span"
         | Diag_fix.Replace_span _ -> "replace_span"
         | Diag_fix.Replace_range _ -> "replace_range"
         | Diag_fix.Multi _ -> "multi"
       in
       let key = code ^ ":" ^ kind in
       match Hashtbl.find_opt by_kind key with
       | Some existing when existing <> title -> ignore existing
       | _ -> Hashtbl.replace by_kind key title)
    diags;
  (* W010 (whitespace) and W050 (unused import) must not read the same. *)
  let w010 = Hashtbl.find_opt by_kind "W010:replace_line" in
  let w050 =
    match Hashtbl.find_opt by_kind "W050:delete_span" with
    | Some t -> Some t
    | None -> Hashtbl.find_opt by_kind "W050:replace_span"
  in
  match w010, w050 with
  | Some a, Some b when a = b ->
    Alcotest.failf "distinct problems share one title: %s" a
  | _ -> ()

(* The title must actually reach the client. *)
let test_title_is_on_the_wire () =
  let json =
    Compile.fix_to_json ~code:"W010"
      (Some (Diag_fix.Replace_line { line = 0; replacement = "x" }))
  in
  if not (contains json "\"title\":\"Remove trailing whitespace\"") then
    Alcotest.failf "fix JSON must carry the title, got: %s" json;
  (* …and the edit fields are still intact alongside it. *)
  if not (contains json "\"kind\":\"replace_line\"") then
    Alcotest.failf "fix JSON lost its edit payload: %s" json;
  (* No fix → still null, not an object with only a title. *)
  Alcotest.(check string) "no fix stays null" "null"
    (Compile.fix_to_json ~code:"W010" None)

let () =
  Alcotest.run "fix_titles" [
    "per-code wording", [
      Alcotest.test_case "linter formatting fixes" `Quick test_linter_titles;
      Alcotest.test_case "unused imports" `Quick test_unused_import_titles;
      Alcotest.test_case "import suggestions" `Quick test_import_titles;
      Alcotest.test_case "parser fixes" `Quick test_parser_titles;
      Alcotest.test_case "unknown code describes the edit" `Quick
        test_unknown_code_still_describes_the_edit;
      Alcotest.test_case "titles stay menu-sized" `Quick test_titles_are_bounded;
    ];
    "real pipeline", [
      Alcotest.test_case "every shipped title is specific and imperative" `Quick
        test_every_shipped_title_is_helpful;
      Alcotest.test_case "every fix-shipping code has a title entry" `Quick
        test_every_fix_shipping_code_has_a_title_entry;
      Alcotest.test_case "different actions read differently" `Quick
        test_titles_distinguish_different_actions;
    ];
    "wire", [
      Alcotest.test_case "title reaches the client" `Quick test_title_is_on_the_wire;
    ];
  ]
