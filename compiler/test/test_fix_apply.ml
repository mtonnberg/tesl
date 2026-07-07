(* D9 structured machine-applicable fixes — the apply-and-recompile seam.

   The class this test closes: a diagnostic that *advertises* a machine-
   applicable fix whose edit is wrong, stale, or non-convergent.  Prose hints
   can drift harmlessly; a structured fix that edits the wrong text is worse
   than no fix.  So every fix the compiler ships must survive this loop:

       compile → take a fix-carrying diagnostic → Diag_fix.apply →
       recompile → … → zero errors within a small fuel bound.

   Any future fix-producing diagnostic belongs in [convergence_cases]; a fix
   that deletes the wrong token, lands on the wrong column, or rewrites into a
   new UNfixable error fails the suite instead of shipping.

   Also covers [Diag_fix.apply] itself variant-by-variant (it is the reference
   semantics the LSP TextEdit construction mirrors) and the fail-closed rule:
   no source snapshot → no fix, never a wrong fix. *)

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
        (Printf.sprintf "tesl_fix_apply_%d_%d" (Unix.getpid ()) !counter)
    in
    Unix.mkdir dir 0o755;
    dir

(* Full real pipeline (parser + checker + legacy pass + linter), same entry the
   CLI uses.  The file must live at a real path so folder-tree import
   suggestions and module/file-name validation behave as in production. *)
let diags_at path source =
  write_file path source;
  Compile.check_source path source

let errors_only (diags : Compile.diagnostic list) =
  List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") diags

let show_diags diags =
  String.concat "\n"
    (List.map (fun (d : Compile.diagnostic) ->
         Printf.sprintf "  [%s] %d:%d %s (fix: %s)" d.code d.start_line
           d.start_col
           (String.concat " | " (String.split_on_char '\n' d.message))
           (Compile.fix_to_json d.fix)) diags)

(* The seam loop.  [`Errors] converges on error-severity diagnostics only;
   [`All] additionally drives the linter's warning fixes (W010/W050) to a
   fully clean file — the linter is a separate pass ([Linter.lint_file]), as
   in the CLI. *)
let converge ?(mode = `Errors) ~name source =
  let dir = fresh_dir () in
  let path = Filename.concat dir "main.tesl" in
  let relevant path diags =
    match mode with
    | `Errors -> errors_only diags
    | `All -> diags @ Linter.lint_file path
  in
  let rec go fuel src =
    let diags = relevant path (diags_at path src) in
    if diags = [] then src
    else if fuel = 0 then
      Alcotest.failf "%s: did not converge; remaining:\n%s" name
        (show_diags diags)
    else
      match
        List.find_opt (fun (d : Compile.diagnostic) -> d.fix <> None) diags
      with
      | None ->
        Alcotest.failf "%s: stuck on unfixable diagnostics:\n%s" name
          (show_diags diags)
      | Some d ->
        (match d.fix with
         | Some fix -> go (fuel - 1) (Diag_fix.apply src fix)
         | None -> assert false)
  in
  go 8 source

(* ── Convergence cases ───────────────────────────────────────────────────── *)

let test_return_delete () =
  let final =
    converge ~name:"return"
      "#lang tesl\n\
       module Main exposing [f]\n\
       import Tesl.Prelude exposing [Int]\n\
       fn f(x: Int) -> Int =\n\
      \    return x\n"
  in
  if not (String.length final > 0
          && Str.string_match (Str.regexp ".*\n    x\n") final 0
             || (let re = Str.regexp_string "    x" in
                 try ignore (Str.search_forward re final 0); true
                 with Not_found -> false)) then
    Alcotest.failf "return fix left unexpected body:\n%s" final;
  let re = Str.regexp_string "return" in
  (try
     ignore (Str.search_forward re final 0);
     Alcotest.failf "`return` survived the fix:\n%s" final
   with Not_found -> ())

let test_string_plus () =
  let final =
    converge ~name:"string-plus"
      "#lang tesl\n\
       module Main exposing [g]\n\
       import Tesl.Prelude exposing [String]\n\
       fn g(a: String, b: String) -> String =\n\
      \    a + b\n"
  in
  let re = Str.regexp_string "a ++ b" in
  (try ignore (Str.search_forward re final 0)
   with Not_found ->
     Alcotest.failf "expected `a ++ b` after fix:\n%s" final)

let test_string_plus_chain () =
  (* two `+` errors, two fixes, both must land on their own operator *)
  let final =
    converge ~name:"string-plus-chain"
      "#lang tesl\n\
       module Main exposing [g]\n\
       import Tesl.Prelude exposing [String]\n\
       fn g(a: String, b: String) -> String =\n\
      \    a + b + a\n"
  in
  let re = Str.regexp_string "a ++ b ++ a" in
  (try ignore (Str.search_forward re final 0)
   with Not_found ->
     Alcotest.failf "expected `a ++ b ++ a` after fixes:\n%s" final)

let test_single_line_if () =
  (* the multi-edit fix: splits at `then` AND before `else`, then the else-body
     relocation fires, then the W010 trailing-whitespace fix cleans up — the
     whole chain is machine-applied, ending byte-exact at the canonical form *)
  let final =
    converge ~mode:`All ~name:"single-line-if"
      "#lang tesl\n\
       module Main exposing [h]\n\
       import Tesl.Prelude exposing [Int]\n\
       fn h(n: Int) -> Int =\n\
      \    if n > 0 then 1 else 2\n"
  in
  let expected =
    "#lang tesl\n\
     module Main exposing [h]\n\
     import Tesl.Prelude exposing [Int]\n\
     fn h(n: Int) -> Int =\n\
    \    if n > 0 then\n\
    \        1\n\
    \    else\n\
    \        2\n"
  in
  Alcotest.(check string) "canonical indented form" expected final

let test_single_line_if_nested_indent () =
  (* the indent of the rewrite tracks the `if`'s own column *)
  let final =
    converge ~name:"nested-if"
      "#lang tesl\n\
       module Main exposing [h]\n\
       import Tesl.Prelude exposing [Int]\n\
       fn h(n: Int) -> Int =\n\
      \    let k = 1\n\
      \    if n > k then n else k\n"
  in
  (* `Errors`-mode leaves W010 trailing whitespace behind — strip per line
     before comparing (the `All`-mode case above proves the full clean-up). *)
  let stripped =
    String.concat "\n"
      (List.map (fun l ->
           let n = String.length l in
           let rec e i = if i > 0 && l.[i - 1] = ' ' then e (i - 1) else i in
           String.sub l 0 (e n))
         (String.split_on_char '\n' final))
  in
  let re = Str.regexp_string "    if n > k then\n        n\n    else\n        k" in
  (try ignore (Str.search_forward re stripped 0)
   with Not_found ->
     Alcotest.failf "nested if did not reach indented form:\n%s" final)

let test_legacy_boolean () =
  let final =
    converge ~name:"legacy-boolean"
      "#lang tesl\n\
       module Main exposing [f]\n\
       import Tesl.Prelude exposing [Bool]\n\
       fn f(b: Boolean) -> Bool =\n\
      \    b\n"
  in
  let re = Str.regexp_string "Boolean" in
  (try
     ignore (Str.search_forward re final 0);
     Alcotest.failf "`Boolean` survived:\n%s" final
   with Not_found -> ())

let test_missing_import () =
  (* E1 insert_line/replace_span import fixes ride the same seam *)
  let final =
    converge ~name:"missing-import"
      "#lang tesl\n\
       module Main exposing [f]\n\
       fn f(x: Int) -> Int =\n\
      \    x\n"
  in
  let re = Str.regexp_string "import Tesl.Prelude" in
  (try ignore (Str.search_forward re final 0)
   with Not_found ->
     Alcotest.failf "expected an inserted Prelude import:\n%s" final)

(* ── Fail-closed: no source snapshot → no fix ────────────────────────────── *)

let test_no_source_no_fix () =
  let src =
    "#lang tesl\n\
     module Main exposing [f]\n\
     import Tesl.Prelude exposing [Int]\n\
     fn f(x: Int) -> Int =\n\
    \    return x\n"
  in
  match Parser.parse_module "main.tesl" src with
  | Parser.Err e -> Alcotest.failf "unexpected parse error: %s" e.msg
  | Parser.Ok m ->
    let errs = Checker.check_module m in   (* no ~source_lines *)
    (match
       List.find_opt (fun (e : Type_system.type_error) ->
           let re = Str.regexp_string "return" in
           try ignore (Str.search_forward re e.message 0); true
           with Not_found -> false) errs
     with
     | None -> Alcotest.fail "expected the `return` error"
     | Some e ->
       Alcotest.(check bool) "fix withheld without source" true (e.fix = None))

(* ── Diag_fix.apply reference semantics, variant by variant ──────────────── *)

let doc = "line0\nline1\nline2"

let test_apply_replace_line () =
  Alcotest.(check string) "replace_line" "line0\nX\nline2"
    (Diag_fix.apply doc (Diag_fix.Replace_line { line = 1; replacement = "X" }))

let test_apply_insert_line () =
  Alcotest.(check string) "insert_line" "line0\nNEW\nline1\nline2"
    (Diag_fix.apply doc (Diag_fix.Insert_line { line = 1; text = "NEW" }))

let test_apply_replace_span () =
  Alcotest.(check string) "replace_span replace" "line0\nX"
    (Diag_fix.apply doc
       (Diag_fix.Replace_span { start_line = 1; end_line = 2; replacement = "X" }));
  Alcotest.(check string) "replace_span empty deletes lines" "line0"
    (Diag_fix.apply doc
       (Diag_fix.Replace_span { start_line = 1; end_line = 2; replacement = "" }))

let test_apply_replace_range () =
  Alcotest.(check string) "same-line token" "line0\nliXX1\nline2"
    (Diag_fix.apply doc
       (Diag_fix.Replace_range { start_line = 1; start_col = 2; end_line = 1;
                                 end_col = 4; replacement = "XX" }));
  Alcotest.(check string) "zero-width = insertion" "line0\nli|ne1\nline2"
    (Diag_fix.apply doc
       (Diag_fix.Replace_range { start_line = 1; start_col = 2; end_line = 1;
                                 end_col = 2; replacement = "|" }));
  Alcotest.(check string) "cross-line range" "liREPne2"
    (Diag_fix.apply doc
       (Diag_fix.Replace_range { start_line = 0; start_col = 2; end_line = 2;
                                 end_col = 2; replacement = "REP" }))

let test_apply_multi_ordering () =
  (* two edits on one line, listed front-first: apply must go back-to-front or
     the second edit's columns are stale *)
  let fix =
    Diag_fix.Multi [
      Diag_fix.Replace_range { start_line = 0; start_col = 0; end_line = 0;
                               end_col = 4; replacement = "L" };
      Diag_fix.Replace_range { start_line = 0; start_col = 4; end_line = 0;
                               end_col = 5; replacement = "-ZERO" };
    ]
  in
  Alcotest.(check string) "multi applies back-to-front" "L-ZERO\nline1\nline2"
    (Diag_fix.apply doc fix)

let test_apply_out_of_range_raises () =
  (match
     Diag_fix.apply doc (Diag_fix.Replace_line { line = 99; replacement = "X" })
   with
   | exception Invalid_argument _ -> ()
   | _ -> Alcotest.fail "expected Invalid_argument for out-of-range line")

let () =
  Alcotest.run "fix_apply" [
    "convergence", [
      Alcotest.test_case "return x → x" `Quick test_return_delete;
      Alcotest.test_case "string + → ++" `Quick test_string_plus;
      Alcotest.test_case "chained string + → ++ ++" `Quick test_string_plus_chain;
      Alcotest.test_case "single-line if → canonical form (byte-exact)" `Quick
        test_single_line_if;
      Alcotest.test_case "indent tracks the if column" `Quick
        test_single_line_if_nested_indent;
      Alcotest.test_case "legacy Boolean → Bool" `Quick test_legacy_boolean;
      Alcotest.test_case "missing import inserted (E1)" `Quick
        test_missing_import;
    ];
    "fail-closed", [
      Alcotest.test_case "no source snapshot → no fix" `Quick
        test_no_source_no_fix;
    ];
    "apply", [
      Alcotest.test_case "replace_line" `Quick test_apply_replace_line;
      Alcotest.test_case "insert_line" `Quick test_apply_insert_line;
      Alcotest.test_case "replace_span" `Quick test_apply_replace_span;
      Alcotest.test_case "replace_range" `Quick test_apply_replace_range;
      Alcotest.test_case "multi back-to-front" `Quick test_apply_multi_ordering;
      Alcotest.test_case "out-of-range raises" `Quick
        test_apply_out_of_range_raises;
    ];
  ]
