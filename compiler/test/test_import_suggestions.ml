(* E1 import ergonomics — guided unbound-name errors + structured import fixes.

   Covers the suggestion engine (lib/import_suggest.ml) end-to-end through the
   real diagnostic pipeline:
   - "unknown name" errors name the module that exports the name — stdlib or a
     sibling .tesl module found by scanning the importing file's folder tree —
     and carry a machine-applicable fix (insert_line / replace_span);
   - stdlib fn / type-not-in-scope / proof-predicate errors carry the same fix;
   - W050 unused-import warnings carry the pruned-import (or delete) edit.

   Folder-tree suggestions only activate for modules that exist on disk, so the
   local-module tests build real fixture trees in a temp dir. *)

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

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
        (Printf.sprintf "tesl_import_sug_%d_%d" (Unix.getpid ()) !counter)
    in
    Unix.mkdir dir 0o755;
    dir

(* Check a source that lives at a real path (so the folder scan can run). *)
let check_at path source =
  write_file path source;
  Compile.check_source path source

let find_diag ?code ~msg_sub (diags : Compile.diagnostic list) =
  match
    List.find_opt (fun (d : Compile.diagnostic) ->
      (match code with Some c -> d.code = c | None -> true)
      && (let re = Str.regexp_string msg_sub in
          try ignore (Str.search_forward re d.message 0); true
          with Not_found -> false)
    ) diags
  with
  | Some d -> d
  | None ->
    Alcotest.failf "no diagnostic matching %S; got:\n%s" msg_sub
      (String.concat "\n"
         (List.map (fun (d : Compile.diagnostic) ->
              Printf.sprintf "  [%s] %s" d.code d.message) diags))

let check_insert_line ~line ~text (d : Compile.diagnostic) =
  match d.fix with
  | Some (Compile.Insert_line f) ->
    Alcotest.(check int) "insert line" line f.line;
    Alcotest.(check string) "insert text" text f.text
  | other ->
    Alcotest.failf "expected Insert_line fix, got %s"
      (Compile.fix_to_json other)

let check_replace_span ~start_line ~end_line ~replacement (d : Compile.diagnostic) =
  match d.fix with
  | Some (Compile.Replace_span f) ->
    Alcotest.(check int) "span start" start_line f.start_line;
    Alcotest.(check int) "span end" end_line f.end_line;
    Alcotest.(check string) "span replacement" replacement f.replacement
  | other ->
    Alcotest.failf "expected Replace_span fix, got %s"
      (Compile.fix_to_json other)

(* ── Stdlib suggestions ──────────────────────────────────────────────────── *)

(* No import of Tesl.List at all → the fix INSERTS a new import after the last
   existing one (0-based line 3). *)
let test_stdlib_fn_insert_import () =
  let dir = fresh_dir () in
  let src = "#lang tesl\n\
             module Main exposing [go]\n\
             import Tesl.Prelude exposing [Int]\n\
             \n\
             fn go(x: Int) -> Int =\n\
             \  List.length [1]\n" in
  let diags = check_at (Filename.concat dir "main.tesl") src in
  let d = find_diag ~code:"T001" ~msg_sub:"function `List.length` requires" diags in
  check_insert_line ~line:3 ~text:"import Tesl.List exposing [List.length]" d

(* Tesl.List already imported with an exposing list → the fix REWRITES that
   import statement in place with the name appended. *)
let test_stdlib_fn_extend_existing_import () =
  let dir = fresh_dir () in
  let src = "#lang tesl\n\
             module Main exposing [go]\n\
             import Tesl.Prelude exposing [Int]\n\
             import Tesl.List exposing [List.map]\n\
             \n\
             fn go(x: Int) -> Int =\n\
             \  List.length (List.map (identity) [1])\n" in
  let diags = check_at (Filename.concat dir "main.tesl") src in
  let d = find_diag ~code:"T001" ~msg_sub:"function `List.length` requires" diags in
  check_replace_span ~start_line:3 ~end_line:3
    ~replacement:"import Tesl.List exposing [List.map, List.length]" d

(* A type name that only exists in the stdlib export table (not the old
   hardcoded 17-name hint list) now gets a module hint + fix too. *)
let test_type_not_in_scope_suggests_module () =
  let dir = fresh_dir () in
  let src = "#lang tesl\n\
             module Main exposing [go]\n\
             import Tesl.Prelude exposing [Int]\n\
             \n\
             fn go(x: Maybe Int) -> Int =\n\
             \  0\n" in
  let diags = check_at (Filename.concat dir "main.tesl") src in
  let d = find_diag ~code:"T001" ~msg_sub:"type `Maybe` is not in scope" diags in
  let _ = find_diag ~code:"T001" ~msg_sub:"import Tesl.Maybe exposing [Maybe]" diags in
  check_insert_line ~line:3 ~text:"import Tesl.Maybe exposing [Maybe]" d

(* A module with NO imports at all: the new import lands before the first
   declaration. *)
let test_insert_with_no_imports () =
  let dir = fresh_dir () in
  let src = "#lang tesl\n\
             module Main exposing [go]\n\
             \n\
             fn go(x: Maybe Int) -> Int =\n\
             \  0\n" in
  let diags = check_at (Filename.concat dir "main.tesl") src in
  let d = find_diag ~code:"T001" ~msg_sub:"type `Maybe` is not in scope" diags in
  (match d.fix with
   | Some (Compile.Insert_line f) ->
     Alcotest.(check int) "insert before first decl" 3 f.line
   | other ->
     Alcotest.failf "expected Insert_line fix, got %s" (Compile.fix_to_json other))

(* Proof predicates: the existing message keeps its wording but now carries the
   quickfix that adds the predicate to the module's exposing list. *)
let test_proof_predicate_fix () =
  let dir = fresh_dir () in
  let src = "#lang tesl\n\
             module Main exposing [go]\n\
             import Tesl.Prelude exposing [Int, String]\n\
             import Tesl.String exposing [String.trim]\n\
             \n\
             fn go(s: String ::: IsTrimmed s) -> Int =\n\
             \  0\n" in
  let diags = check_at (Filename.concat dir "main.tesl") src in
  let d = find_diag ~code:"T001" ~msg_sub:"proof predicate `IsTrimmed` is not in scope" diags in
  check_replace_span ~start_line:3 ~end_line:3
    ~replacement:"import Tesl.String exposing [String.trim, IsTrimmed]" d

(* ── Folder-tree suggestions ─────────────────────────────────────────────── *)

let helper_module = "#lang tesl\n\
                     module Helper exposing [greet, Widget(..)]\n\
                     import Tesl.Prelude exposing [Int, String]\n\
                     \n\
                     type Widget =\n\
                     \  | Round\n\
                     \  | Square\n\
                     \n\
                     fn greet(n: String) -> String =\n\
                     \  n\n"

(* Same directory: actionable — hint names the module and the fix inserts the
   resolving import. *)
let test_local_same_dir_suggestion () =
  let dir = fresh_dir () in
  write_file (Filename.concat dir "helper.tesl") helper_module;
  let src = "#lang tesl\n\
             module Main exposing [go]\n\
             import Tesl.Prelude exposing [Int, String]\n\
             \n\
             fn go(x: Int) -> String =\n\
             \  greet \"hi\"\n" in
  let diags = check_at (Filename.concat dir "main.tesl") src in
  let d = find_diag ~code:"T001" ~msg_sub:"unknown name: greet" diags in
  let _ = find_diag ~code:"T001"
      ~msg_sub:"module `Helper` (helper.tesl) exports it" diags in
  check_insert_line ~line:3 ~text:"import Helper exposing [greet]" d

(* An exported ADT's constructor resolves to the `Type(..)` import form. *)
let test_local_ctor_suggests_dotdot_import () =
  let dir = fresh_dir () in
  write_file (Filename.concat dir "helper.tesl") helper_module;
  let src = "#lang tesl\n\
             module Main exposing [go]\n\
             import Tesl.Prelude exposing [Int]\n\
             \n\
             fn go(x: Int) -> Int =\n\
             \  let w = Round\n\
             \  x\n" in
  let diags = check_at (Filename.concat dir "main.tesl") src in
  let d = find_diag ~code:"T001" ~msg_sub:"unknown constructor: Round" diags in
  check_insert_line ~line:3 ~text:"import Helper exposing [Widget(..)]" d

(* Subdirectory: local imports cannot resolve it, so the error explains that
   instead of proposing an edit that would not compile. *)
let test_local_subdir_hint_no_fix () =
  let dir = fresh_dir () in
  Unix.mkdir (Filename.concat dir "sub") 0o755;
  write_file (Filename.concat dir "sub/deep.tesl")
    "#lang tesl\n\
     module Deep exposing [deepFn]\n\
     import Tesl.Prelude exposing [Int]\n\
     \n\
     fn deepFn(n: Int) -> Int =\n\
     \  n\n";
  let src = "#lang tesl\n\
             module Main exposing [go]\n\
             import Tesl.Prelude exposing [Int]\n\
             \n\
             fn go(x: Int) -> Int =\n\
             \  deepFn x\n" in
  let diags = check_at (Filename.concat dir "main.tesl") src in
  let d = find_diag ~code:"T001" ~msg_sub:"unknown name: deepFn" diags in
  let _ = find_diag ~code:"T001" ~msg_sub:"sub/deep.tesl" diags in
  (match d.fix with
   | None -> ()
   | Some f ->
     Alcotest.failf "deep-tree suggestion must not carry a fix, got %s"
       (Compile.fix_to_json (Some f)))

(* A name nothing exports stays a plain unknown-name error. *)
let test_unknown_name_without_candidate_is_plain () =
  let dir = fresh_dir () in
  let src = "#lang tesl\n\
             module Main exposing [go]\n\
             import Tesl.Prelude exposing [Int]\n\
             \n\
             fn go(x: Int) -> Int =\n\
             \  frobnicateXyz x\n" in
  let diags = check_at (Filename.concat dir "main.tesl") src in
  let d = find_diag ~code:"T001" ~msg_sub:"unknown name: frobnicateXyz" diags in
  Alcotest.(check string) "no hint appended"
    "unknown name: frobnicateXyz" d.message;
  (match d.fix with
   | None -> ()
   | Some f ->
     Alcotest.failf "expected no fix, got %s" (Compile.fix_to_json (Some f)))

(* ── #34: bare top-level constants across the module boundary ────────────── *)

(* A literal-valued exported constant now binds in the importing module — with
   its real type, not a unify-with-anything fresh var. *)
let test_const_import_binds () =
  let dir = fresh_dir () in
  write_file (Filename.concat dir "consts.tesl")
    "#lang tesl\n\
     module Consts exposing [kMax, kName]\n\
     import Tesl.Prelude exposing [Int, String]\n\
     \n\
     kMax = 5\n\
     \n\
     kName = \"tesl\"\n";
  let src = "#lang tesl\n\
             module Main exposing [go]\n\
             import Tesl.Prelude exposing [Int, String]\n\
             import Consts exposing [kMax, kName]\n\
             \n\
             fn go(x: Int) -> Int =\n\
             \  x + kMax\n\
             \n\
             fn name() -> String =\n\
             \  kName\n" in
  let diags = check_at (Filename.concat dir "main.tesl") src in
  (match diags with
   | [] -> ()
   | ds ->
     Alcotest.failf "expected clean check, got:\n%s"
       (String.concat "\n"
          (List.map (fun (d : Compile.diagnostic) ->
               Printf.sprintf "  [%s] %s" d.code d.message) ds)))

(* The imported constant carries its literal type: using an Int constant where
   a String is required must be a TYPE error, not accepted via a fresh var. *)
let test_const_import_is_really_typed () =
  let dir = fresh_dir () in
  write_file (Filename.concat dir "consts.tesl")
    "#lang tesl\n\
     module Consts exposing [kMax]\n\
     import Tesl.Prelude exposing [Int]\n\
     \n\
     kMax = 5\n";
  let src = "#lang tesl\n\
             module Main exposing [go]\n\
             import Tesl.Prelude exposing [String]\n\
             import Consts exposing [kMax]\n\
             \n\
             fn go() -> String =\n\
             \  kMax\n" in
  let diags = check_at (Filename.concat dir "main.tesl") src in
  (match diags with
   | [] -> Alcotest.fail "Int constant accepted as String — const import is untyped"
   | _ -> ())

(* A constant whose value has no syntactically evident type cannot cross the
   boundary; the error must explain the zero-arg-fn wrap, and must NOT suggest
   adding the import that is already present (the old misleading hint). *)
let test_opaque_const_hint_no_duplicate_import () =
  let dir = fresh_dir () in
  write_file (Filename.concat dir "consts.tesl")
    "#lang tesl\n\
     module Consts exposing [kPair]\n\
     import Tesl.Prelude exposing [Int, String]\n\
     \n\
     kPair = { a: 1, b: \"x\" }\n";
  let src = "#lang tesl\n\
             module Main exposing [go]\n\
             import Tesl.Prelude exposing [Int]\n\
             import Consts exposing [kPair]\n\
             \n\
             fn go(x: Int) -> Int =\n\
             \  let p = kPair\n\
             \  x\n" in
  let diags = check_at (Filename.concat dir "main.tesl") src in
  let d = find_diag ~code:"T001" ~msg_sub:"wrap it in a zero-arg function" diags in
  (* the old hint suggested `add import Consts exposing [kPair]` verbatim *)
  (let re = Str.regexp_string "add `import" in
   if (try ignore (Str.search_forward re d.message 0); true
       with Not_found -> false)
   then Alcotest.failf "hint still suggests re-adding the import: %s" d.message);
  (match d.fix with
   | None -> ()
   | Some f ->
     Alcotest.failf "opaque-const hint must not carry an import fix, got %s"
       (Compile.fix_to_json (Some f)))

(* ── W050 unused-import fixes ────────────────────────────────────────────── *)

let lint_at path source =
  write_file path source;
  Linter.lint_file path

let w050_fix_of (diags : Compile.diagnostic list) name =
  let d = find_diag ~code:"W050" ~msg_sub:(Printf.sprintf "`%s`" name) diags in
  d.fix

(* One unused name in a multi-name import → the import is rewritten without it. *)
let test_w050_prunes_single_name () =
  let dir = fresh_dir () in
  let src = "#lang tesl\n\
             module Main exposing [go]\n\
             import Tesl.Prelude exposing [Int, String]\n\
             \n\
             fn go(x: Int) -> Int =\n\
             \  x\n" in
  let diags = lint_at (Filename.concat dir "main.tesl") src in
  match w050_fix_of diags "String" with
  | Some (Compile.Replace_span f) ->
    Alcotest.(check int) "span start" 2 f.start_line;
    Alcotest.(check int) "span end" 2 f.end_line;
    Alcotest.(check string) "pruned import"
      "import Tesl.Prelude exposing [Int]" f.replacement
  | other ->
    Alcotest.failf "expected Replace_span, got %s" (Compile.fix_to_json other)

(* Every name of a MULTI-LINE import unused → the whole statement is deleted
   (empty replacement over its full line span), and both W050s carry the
   identical edit so the LSP can dedupe them in fixAll/organizeImports. *)
let test_w050_deletes_multiline_import () =
  let dir = fresh_dir () in
  let src = "#lang tesl\n\
             module Main exposing [go]\n\
             import Tesl.Prelude exposing [Int]\n\
             import Tesl.Dict exposing [\n\
             \  Dict.empty,\n\
             \  Dict.insert,\n\
             ]\n\
             \n\
             fn go(x: Int) -> Int =\n\
             \  x\n" in
  let diags = lint_at (Filename.concat dir "main.tesl") src in
  let check_delete = function
    | Some (Compile.Replace_span f) ->
      Alcotest.(check int) "span start" 3 f.start_line;
      Alcotest.(check int) "span end" 6 f.end_line;
      Alcotest.(check string) "deletion" "" f.replacement
    | other ->
      Alcotest.failf "expected Replace_span, got %s" (Compile.fix_to_json other)
  in
  let fix_empty = w050_fix_of diags "Dict.empty" in
  let fix_insert = w050_fix_of diags "Dict.insert" in
  check_delete fix_empty;
  check_delete fix_insert;
  Alcotest.(check bool) "sibling W050s share one edit" true
    (fix_empty = fix_insert)

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "import_suggestions" [
    "stdlib", [
      Alcotest.test_case "missing import → insert_line" `Quick
        test_stdlib_fn_insert_import;
      Alcotest.test_case "existing import → replace_span extend" `Quick
        test_stdlib_fn_extend_existing_import;
      Alcotest.test_case "type not in scope names its module" `Quick
        test_type_not_in_scope_suggests_module;
      Alcotest.test_case "no imports → insert before first decl" `Quick
        test_insert_with_no_imports;
      Alcotest.test_case "proof predicate carries fix" `Quick
        test_proof_predicate_fix;
    ];
    "folder-tree", [
      Alcotest.test_case "same-dir module → hint + fix" `Quick
        test_local_same_dir_suggestion;
      Alcotest.test_case "exported ADT ctor → Type(..) import" `Quick
        test_local_ctor_suggests_dotdot_import;
      Alcotest.test_case "subdir module → hint, no fix" `Quick
        test_local_subdir_hint_no_fix;
      Alcotest.test_case "no candidate → plain error" `Quick
        test_unknown_name_without_candidate_is_plain;
    ];
    "const-exports", [
      Alcotest.test_case "literal const binds across modules (#34)" `Quick
        test_const_import_binds;
      Alcotest.test_case "imported const carries its real type (#34)" `Quick
        test_const_import_is_really_typed;
      Alcotest.test_case "opaque const → wrap hint, no duplicate import (#34)" `Quick
        test_opaque_const_hint_no_duplicate_import;
    ];
    "w050", [
      Alcotest.test_case "prunes one unused name" `Quick
        test_w050_prunes_single_name;
      Alcotest.test_case "deletes fully-unused multiline import" `Quick
        test_w050_deletes_multiline_import;
    ];
  ]
