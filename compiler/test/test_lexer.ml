(** Lexer tests — happy path and adversarial.

    Tests cover: basic tokens, keywords, INDENT/DEDENT generation,
    string interpolation, edge cases, and error recovery. *)

open Token

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let tokenize src = Lexer.tokenize "<test>" src |> List.map (fun t -> t.Lexer.tok)

let tok_list src = tokenize src

let check_toks name src expected =
  let got = tok_list src in
  Alcotest.(check (list (module struct
    type t = Token.t
    let equal a b = (a = b)
    let pp fmt t = Token.pp fmt t
  end))) name expected got

(* ── Basic token tests ───────────────────────────────────────────────────── *)

let test_integers () =
  check_toks "positive int" "42" [INT 42; NEWLINE; EOF];
  check_toks "zero" "0" [INT 0; NEWLINE; EOF];
  check_toks "multiple ints" "1 2 3" [INT 1; INT 2; INT 3; NEWLINE; EOF]

let test_floats () =
  check_toks "basic float" "3.14" [FLOAT 3.14; NEWLINE; EOF]

let test_strings () =
  check_toks "plain string" {|"hello"|} [STRING "hello"; NEWLINE; EOF];
  check_toks "empty string" {|""|} [STRING ""; NEWLINE; EOF];
  check_toks "escaped newline" {|"a\nb"|} [STRING "a\nb"; NEWLINE; EOF];
  check_toks "escaped tab" {|"a\tb"|} [STRING "a\tb"; NEWLINE; EOF];
  check_toks "escaped quote" {|"a\"b"|} [STRING "a\"b"; NEWLINE; EOF];
  check_toks "escaped backslash" {|"a\\b"|} [STRING "a\\b"; NEWLINE; EOF]

let test_interp_string () =
  (* Interpolated strings return INTERP token with raw content *)
  let toks = tok_list {|"Hello, ${name}!"|}  in
  (match toks with
   | [INTERP _raw; NEWLINE; EOF] -> ()
   | _ -> Alcotest.fail (Printf.sprintf "expected INTERP, got %d tokens"
                           (List.length toks)))

let test_booleans () =
  check_toks "true" "true" [TRUE; NEWLINE; EOF];
  check_toks "false" "false" [FALSE; NEWLINE; EOF]

let test_identifiers () =
  check_toks "lowercase ident" "hello" [IDENT "hello"; NEWLINE; EOF];
  check_toks "ident with underscore" "hello_world" [IDENT "hello_world"; NEWLINE; EOF];
  check_toks "ident with digits" "x1" [IDENT "x1"; NEWLINE; EOF]

let test_uidents () =
  check_toks "uppercase ident" "Hello" [UIDENT "Hello"; NEWLINE; EOF];
  check_toks "ADT constructor" "Nothing" [NOTHING; NEWLINE; EOF];
  check_toks "ADT constructor Something" "Something" [SOMETHING; NEWLINE; EOF]

let test_keywords () =
  check_toks "fn" "fn" [FN; NEWLINE; EOF];
  check_toks "handler" "handler" [HANDLER; NEWLINE; EOF];
  check_toks "check" "check" [CHECK; NEWLINE; EOF];
  check_toks "auth" "auth" [AUTH; NEWLINE; EOF];
  check_toks "type" "type" [TYPE; NEWLINE; EOF];
  check_toks "record" "record" [RECORD; NEWLINE; EOF];
  check_toks "entity" "entity" [ENTITY; NEWLINE; EOF];
  check_toks "module" "module" [MODULE; NEWLINE; EOF];
  check_toks "exposing" "exposing" [EXPOSING; NEWLINE; EOF];
  check_toks "import" "import" [IMPORT; NEWLINE; EOF];
  check_toks "case" "case" [CASE; NEWLINE; EOF];
  check_toks "of" "of" [OF; NEWLINE; EOF];
  check_toks "let" "let" [LET; NEWLINE; EOF];
  check_toks "if" "if" [IF; NEWLINE; EOF];
  check_toks "then" "then" [THEN; NEWLINE; EOF];
  check_toks "else" "else" [ELSE; NEWLINE; EOF];
  check_toks "ok" "ok" [OK; NEWLINE; EOF];
  check_toks "fail" "fail" [FAIL; NEWLINE; EOF];
  check_toks "capability" "capability" [CAPABILITY; NEWLINE; EOF];
  check_toks "implies" "implies" [IMPLIES; NEWLINE; EOF];
  check_toks "api-test" "api-test" [API_TEST; NEWLINE; EOF]

let test_operators () =
  check_toks "proof annot" ":::" [PROOF_ANNOT; NEWLINE; EOF];
  check_toks "arrow" "->" [ARROW; NEWLINE; EOF];
  check_toks "fat arrow" "=>" [FAT_ARROW; NEWLINE; EOF];
  check_toks "double colon" "::" [DOUBLE_COLON; NEWLINE; EOF];
  check_toks "colon" ":" [COLON; NEWLINE; EOF];
  check_toks "eq eq" "==" [EQ_EQ; NEWLINE; EOF];
  check_toks "eq" "=" [EQ; NEWLINE; EOF];
  check_toks "neq" "!=" [NEQ; NEWLINE; EOF];
  check_toks "le" "<=" [LE; NEWLINE; EOF];
  check_toks "lt" "<" [LT; NEWLINE; EOF];
  check_toks "ge" ">=" [GE; NEWLINE; EOF];
  check_toks "gt" ">" [GT; NEWLINE; EOF];
  check_toks "double amp" "&&" [DOUBLE_AMP; NEWLINE; EOF];
  check_toks "backarrow" "<-" [BACKARROW; NEWLINE; EOF];
  check_toks "dotdot" ".." [DOTDOT; NEWLINE; EOF]

let test_star_raw_access () =
  check_toks "star ident" "*x" [STAR; IDENT "x"; NEWLINE; EOF];
  check_toks "star in expr" "*port + *y"
    [STAR; IDENT "port"; PLUS; STAR; IDENT "y"; NEWLINE; EOF]

(* ── INDENT/DEDENT tests ─────────────────────────────────────────────────── *)

let test_simple_indent () =
  (* A function body indented by 2 spaces *)
  let src = "fn add =\n  42" in
  let toks = tok_list src in
  (* Should contain INDENT before 42 and DEDENT after *)
  let has_indent = List.mem INDENT toks in
  let has_dedent = List.mem DEDENT toks in
  Alcotest.(check bool) "has INDENT" true has_indent;
  Alcotest.(check bool) "has DEDENT" true has_dedent

let test_nested_indent () =
  let src = "fn f =\n  case x of\n    A -> 1\n    B -> 2" in
  let toks = tok_list src in
  let indent_count = List.length (List.filter (fun t -> t = INDENT) toks) in
  let dedent_count = List.length (List.filter (fun t -> t = DEDENT) toks) in
  Alcotest.(check bool) "at least 2 indents" true (indent_count >= 2);
  Alcotest.(check bool) "dedents = indents" true (indent_count = dedent_count)

let test_blank_lines_ignored () =
  (* Blank lines should not affect indentation *)
  let src = "fn f =\n  42\n\n  99" in
  let toks = tok_list src in
  let indent_count = List.length (List.filter (fun t -> t = INDENT) toks) in
  Alcotest.(check int) "one INDENT level" 1 indent_count

let test_comment_lines_ignored () =
  let src = "# This is a comment\nfn add =\n  # body comment\n  42" in
  let toks = tok_list src in
  let has_fn = List.mem FN toks in
  Alcotest.(check bool) "has fn keyword" true has_fn;
  (* Comments should not produce tokens *)
  Alcotest.(check bool) "no IDENT 'This'" false (List.mem (IDENT "This") toks)

let test_hash_lang () =
  let src = "#lang tesl\nmodule Foo exposing []" in
  let toks = tok_list src in
  (* #lang tesl should produce HASH_LANG TESL *)
  let has_hash_lang = List.mem HASH_LANG toks in
  let has_tesl = List.mem TESL toks in
  Alcotest.(check bool) "has HASH_LANG" true has_hash_lang;
  Alcotest.(check bool) "has TESL after #lang" true has_tesl

(* ── Full module tokenization ────────────────────────────────────────────── *)

let test_hello_world_tokens () =
  let src = {|#lang tesl
module HelloWorld exposing [greet, add]
import Tesl.Prelude exposing [Int, String]

fn greet(name: String) -> String =
  "Hello, ${name}!"

fn add(x: Int, y: Int) -> Int =
  x + y
|} in
  let toks = tok_list src in
  Alcotest.(check bool) "has MODULE" true (List.mem MODULE toks);
  Alcotest.(check bool) "has FN" true (List.mem FN toks);
  Alcotest.(check bool) "has IMPORT" true (List.mem IMPORT toks);
  Alcotest.(check bool) "has ARROW" true (List.mem ARROW toks);
  Alcotest.(check bool) "has PROOF_ANNOT" false (List.mem PROOF_ANNOT toks);
  (* The interpolated string should be an INTERP token *)
  let has_interp = List.exists (function INTERP _ -> true | _ -> false) toks in
  Alcotest.(check bool) "has INTERP for ${name}" true has_interp

let test_check_function_tokens () =
  let src = {|check isValidPort(port: Int) -> port: Int::: ValidPort port =
  if 1 <= port && port <= 65535 then
    ok port::: ValidPort port
  else
    fail 400 "port must be between 1 and 65535"
|} in
  let toks = tok_list src in
  Alcotest.(check bool) "has CHECK" true (List.mem CHECK toks);
  Alcotest.(check bool) "has PROOF_ANNOT" true (List.mem PROOF_ANNOT toks);
  Alcotest.(check bool) "has OK" true (List.mem OK toks);
  Alcotest.(check bool) "has FAIL" true (List.mem FAIL toks);
  Alcotest.(check bool) "has DOUBLE_AMP" true (List.mem DOUBLE_AMP toks)

(* ── Adversarial tests ────────────────────────────────────────────────────── *)

let test_empty_source () =
  let toks = tok_list "" in
  Alcotest.(check (list (module struct
    type t = Token.t
    let equal a b = (a = b)
    let pp fmt t = Token.pp fmt t
  end))) "empty produces only EOF" [EOF] toks

let test_only_comments () =
  let src = "# comment 1\n# comment 2\n" in
  let toks = tok_list src in
  Alcotest.(check (list (module struct
    type t = Token.t
    let equal a b = (a = b)
    let pp fmt t = Token.pp fmt t
  end))) "only comments produces only EOF" [EOF] toks

let test_deeply_nested () =
  let src = {|fn f =
  if a then
    if b then
      if c then
        42
      else
        0
    else
      0
  else
    0
|} in
  let toks = tok_list src in
  let indent_count = List.length (List.filter (fun t -> t = INDENT) toks) in
  let dedent_count = List.length (List.filter (fun t -> t = DEDENT) toks) in
  Alcotest.(check bool) "balanced indents" true (indent_count = dedent_count)

let test_string_with_special_chars () =
  check_toks "string with newline escape" {|"line1\nline2"|}
    [STRING "line1\nline2"; NEWLINE; EOF];
  check_toks "string with tab" {|"col1\tcol2"|}
    [STRING "col1\tcol2"; NEWLINE; EOF]

let test_operator_sequence () =
  check_toks "::: operator" "x::: Proof" [IDENT "x"; PROOF_ANNOT; UIDENT "Proof"; NEWLINE; EOF];
  check_toks "-> operator" "Int -> String" [UIDENT "Int"; ARROW; UIDENT "String"; NEWLINE; EOF]

let test_dotdot_in_export () =
  check_toks "dotdot" "Color(..)" [UIDENT "Color"; LPAREN; DOTDOT; RPAREN; NEWLINE; EOF]

let test_qualified_names () =
  check_toks "Dict.lookup" "Dict.lookup"
    [UIDENT "Dict"; DOT; IDENT "lookup"; NEWLINE; EOF]

let test_record_literal_tokens () =
  let src = {|{ id: "task-1", title: body.title }|} in
  let toks = tok_list src in
  Alcotest.(check bool) "has LBRACE" true (List.mem LBRACE toks);
  Alcotest.(check bool) "has RBRACE" true (List.mem RBRACE toks);
  Alcotest.(check bool) "has COLON" true (List.mem COLON toks)

let test_codec_tokens () =
  let src = {|codec Task {
  toJson {
    id -> "id" with_codec stringCodec
  }
  fromJson_forbidden
}|} in
  let toks = tok_list src in
  Alcotest.(check bool) "has CODEC" true (List.mem CODEC toks);
  Alcotest.(check bool) "has TO_JSON" true (List.mem TO_JSON toks);
  Alcotest.(check bool) "has FROM_JSON_FORBIDDEN" true (List.mem FROM_JSON_FORBIDDEN toks);
  Alcotest.(check bool) "has WITH_CODEC" true (List.mem WITH_CODEC toks);
  Alcotest.(check bool) "has BACKARROW" false (List.mem BACKARROW toks)

let test_api_test_compound_token () =
  let src = "api-test \"name\" for Server {}" in
  let toks = tok_list src in
  Alcotest.(check bool) "api-test is single token" true (List.mem API_TEST toks);
  Alcotest.(check bool) "api-test not API + MINUS" false
    (List.mem MINUS toks)

let test_underscore_wildcard () =
  check_toks "underscore" "_" [UNDERSCORE; NEWLINE; EOF];
  check_toks "underscore in case" "_ -> 0"
    [UNDERSCORE; ARROW; INT 0; NEWLINE; EOF]

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Lexer" [
    "integers", [
      Alcotest.test_case "basic integers" `Quick test_integers;
    ];
    "floats", [
      Alcotest.test_case "basic floats" `Quick test_floats;
    ];
    "strings", [
      Alcotest.test_case "plain strings" `Quick test_strings;
      Alcotest.test_case "interpolated strings" `Quick test_interp_string;
    ];
    "literals", [
      Alcotest.test_case "booleans" `Quick test_booleans;
    ];
    "identifiers", [
      Alcotest.test_case "lowercase idents" `Quick test_identifiers;
      Alcotest.test_case "uppercase idents" `Quick test_uidents;
    ];
    "keywords", [
      Alcotest.test_case "all keywords" `Quick test_keywords;
    ];
    "operators", [
      Alcotest.test_case "operator tokens" `Quick test_operators;
      Alcotest.test_case "star raw access" `Quick test_star_raw_access;
    ];
    "indentation", [
      Alcotest.test_case "simple INDENT/DEDENT" `Quick test_simple_indent;
      Alcotest.test_case "nested INDENT/DEDENT" `Quick test_nested_indent;
      Alcotest.test_case "blank lines ignored" `Quick test_blank_lines_ignored;
      Alcotest.test_case "comment lines ignored" `Quick test_comment_lines_ignored;
      Alcotest.test_case "deeply nested" `Quick test_deeply_nested;
    ];
    "full-source", [
      Alcotest.test_case "#lang tesl header" `Quick test_hash_lang;
      Alcotest.test_case "hello-world module" `Quick test_hello_world_tokens;
      Alcotest.test_case "check function" `Quick test_check_function_tokens;
    ];
    "adversarial", [
      Alcotest.test_case "empty source" `Quick test_empty_source;
      Alcotest.test_case "only comments" `Quick test_only_comments;
      Alcotest.test_case "special chars in strings" `Quick test_string_with_special_chars;
      Alcotest.test_case "operator sequences" `Quick test_operator_sequence;
      Alcotest.test_case "dotdot in export" `Quick test_dotdot_in_export;
      Alcotest.test_case "qualified names" `Quick test_qualified_names;
      Alcotest.test_case "record literal tokens" `Quick test_record_literal_tokens;
      Alcotest.test_case "codec tokens" `Quick test_codec_tokens;
      Alcotest.test_case "api-test compound token" `Quick test_api_test_compound_token;
      Alcotest.test_case "underscore wildcard" `Quick test_underscore_wildcard;
    ];
  ]
