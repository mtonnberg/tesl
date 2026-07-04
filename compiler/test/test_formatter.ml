(** Formatter polish tests (WS7 "delight").

    Two kinds of guarantees are exercised here:

    1. IDEMPOTENCE — the headline property. For a representative corpus of
       Tesl constructs (long signatures, proof annotations, records/entities,
       multi-line handlers, comments, exposing lists, operators, edge cases)
       we assert [format (format x) = format x]. A formatter that is not
       idempotent will rewrite "already formatted" code, which makes
       `tesl --fmt-check` flap and erodes trust in the tool.

       The corpus doubles as a fuzz seed: every case is run through both a
       single pass and a double pass, and the property is also re-checked
       starting from the *unformatted* input so we catch divergence on the
       very first stabilisation step, not just on already-canonical text.

    2. CANONICALISATION — specific output niceties that live in OCaml:
       consistent spacing around [:::], [=>], [->]; canonical exposing lists
       (no inner padding, no stray/trailing commas); leading/trailing blank
       line removal; comment normalisation; string/comment safety.
*)

open Alcotest

let fmt = Formatter.format_source

(* ── 1. Idempotence corpus ──────────────────────────────────────────────── *)

(* Each entry is (label, source). The source is intentionally "messy" in
   several cases so the first pass does real work; idempotence must hold from
   the second pass onward. *)
let corpus = [
  "long_signature",
  "#lang tesl\n\
   fn doSomething(userId: String, action: String, count: Int, timestamp: Int, payload: String) -> String requires [apiTime] =\n\
  \  payload\n";

  "proof_annotation_tight",
  "#lang tesl\ncheck ok(x:Item)->x:Item:::Active x =\n  ok x:::Active x\n";

  "proof_annotation_loose",
  "#lang tesl\nok x   :::   Active x\n";

  "fat_arrow_tight",
  "#lang tesl\nlet p = forall x=>Q x\n";

  "decode_arrow",
  "#lang tesl\nlet r = field \"x\" <-Int\n";

  "record_block",
  "record SendEmail {\nto:String\nsubject:String\nbody:String\n}\n";

  "record_inline",
  "record Item { id:String,active:Bool }\n";

  "record_trailing_comma",
  "record R { id: String, count: Int, }\n";

  "adt",
  "type UserEvent\n= ProfileUpdated bio:String\n| AccountDeleted\n";

  "database_block",
  "database D = Database {\n  schema: \"app\"\n  entities: []\n  backend: Postgres (PostgresConfig {\n    dbName: \"d\"\n    user: \"u\"\n    password: \"\"\n    connection: TcpConnection {\n      host: \"localhost\"\n      port: 5432\n    }\n  })\n}\n";

  "queue_nested_blocks",
  "queue EmailQueue requires [queueRead] = Queue {\n  database: D\n  jobs: [Job SendEmail sendEmailWorker]\n  numberOfWorkers: 2\n  retry: QueueRetryStrategy {\n    maxAttempts: 3\n    backoff: Exponential\n  }\n}\n";

  "worker_with_proof",
  "worker sendEmailWorker(job: SendEmail ::: FromQueue (Id == jobId) job)\n  requires [queueRead] =\n  job\n";

  "multiline_handler",
  "#lang tesl\nendpoint GET \"/users/:id\" -> User\n  requires [dbRead] =\n  dbRead id\n";

  "comment_normalize",
  "#lang tesl\n#a comment\nfn f(x: Int) -> Int = x\n";

  "comment_with_code_chars",
  "#lang tesl\n# this -> has ::: chars , and = signs\nfn f(x: Int) -> Int = x\n";

  "doc_directives_preserved",
  "#lang tesl\n#>foo\n#=bar\nfn f(x: Int) -> Int = x\n";

  "shebang_preserved",
  "#!/usr/bin/env tesl\n#lang tesl\nfn f(x: Int) -> Int = x\n";

  "string_with_op_chars",
  "#lang tesl\nlet s = \"a:b->c:::d,e\"\n";

  "interpolation",
  "#lang tesl\nlet s = \"val ${x+1} and ${y:::z}\"\n";

  "arithmetic",
  "#lang tesl\nlet a = 1+2*3-4/5%6\n";

  "comparison_and_logical",
  "#lang tesl\nlet b = x==1&&y!=2||z<=3&&w>=4\n";

  "pipeline",
  "#lang tesl\nlet c = xs|>filter|>map\n";

  "negative_literals",
  "#lang tesl\nlet x = f a -3\nlet y = (0 - x)\nlet z = -5\n";

  "api_test_hyphen_keyword",
  "#lang tesl\napi-test \"foo\" {\n  load-test concurrent 10\n}\n";

  "loose_arrow_and_equals",
  "#lang tesl\nfn f(x: Int)  ->  Int  =  x\n";

  "exposing_short_inline",
  "#lang tesl\nmodule Short exposing [foo, bar]\nimport Tesl.Prelude exposing [Int]\n";

  "exposing_inner_padding",
  "#lang tesl\nimport M exposing [ a, b, c ]\n";

  "exposing_multiline_collapses",
  "#lang tesl\nimport M exposing [\n  a, b, c\n]\n";

  "exposing_trailing_comma_inline",
  "#lang tesl\nmodule M exposing [a, b, c,]\n";

  "exposing_multiline_with_trailing_comma",
  "#lang tesl\nmodule Foo exposing [\n  alpha,\n  beta,\n  gamma,\n]\nimport Tesl.Prelude exposing [Int]\n";

  "exposing_long_splits",
  "#lang tesl\n\
   module M exposing [aaaaaaaaaa, bbbbbbbbbb, cccccccccc, dddddddddd, eeeeeeeeee, ffffffffff]\n";

  "exposing_dotdot",
  "#lang tesl\nimport Tesl.Prelude exposing [Bool(..), Int, String]\n";

  "leading_blank_lines",
  "\n\n\n#lang tesl\nfn f(x: Int) -> Int = x\n";

  "trailing_blank_lines",
  "#lang tesl\nfn f(x: Int) -> Int = x\n\n\n\n";

  "internal_blank_runs",
  "#lang tesl\nfn f(x: Int) -> Int = x\n\n\n\nfn g(x: Int) -> Int = x\n";

  "crlf_endings",
  "#lang tesl\r\nfn f(x: Int) -> Int = x\r\n";

  "tab_indentation",
  "#lang tesl\nfn f(x: Int) -> Int =\n\tx\n";

  "trailing_whitespace",
  "#lang tesl\nfn f(x: Int) -> Int = x   \n";

  "empty_file",
  "";

  "only_blank_lines",
  "\n\n\n";
]

(* Property: a single format pass must be a fixed point of a second pass. *)
let idempotent_after_one_pass (_label, src) =
  let once = fmt src in
  let twice = fmt once in
  once = twice, once, twice

let test_idempotent_corpus () =
  List.iter (fun ((label, _) as case) ->
    let ok, once, twice = idempotent_after_one_pass case in
    if not ok then
      Printf.eprintf "[%s] not idempotent:\n--- pass1 ---\n%s\n--- pass2 ---\n%s\n"
        label once twice;
    check bool (Printf.sprintf "idempotent: %s" label) true ok
  ) corpus

(* Stronger: three consecutive passes must all agree (catches oscillation
   that a 2-pass check could miss if the fixed point had period 2). *)
let test_no_oscillation () =
  List.iter (fun (label, src) ->
    let p1 = fmt src in
    let p2 = fmt p1 in
    let p3 = fmt p2 in
    let ok = p1 = p2 && p2 = p3 in
    if not ok then
      Printf.eprintf "[%s] oscillates:\n1:%S\n2:%S\n3:%S\n" label p1 p2 p3;
    check bool (Printf.sprintf "stable: %s" label) true ok
  ) corpus

(* ── 2. Canonicalisation behaviour ──────────────────────────────────────── *)

let test_proof_annotation_spacing () =
  let out = fmt "#lang tesl\ncheck ok(x:Item)->x:Item:::Active x = ok x:::Active x\n" in
  check string "::: and -> and : get canonical spacing"
    "#lang tesl\ncheck ok(x: Item) -> x: Item ::: Active x = ok x ::: Active x\n" out

let test_proof_annotation_collapses_extra_spaces () =
  let out = fmt "#lang tesl\nok x   :::   Active x\n" in
  check string "::: collapses surrounding runs to single spaces"
    "#lang tesl\nok x ::: Active x\n" out

(* T2 (2026-07-04): fmt OWNS indentation — an odd indent is rounded to even so
   `fmt` then `--lint` is a W011 fixpoint (the linter uses the same indent-1 fix). *)
let test_normalizes_odd_indentation () =
  let out = fmt "#lang tesl\nfn f(x: Int) -> Int =\n   x\n" in
  check string "3-space body indent normalised to 2"
    "#lang tesl\nfn f(x: Int) -> Int =\n  x\n" out

(* Continuation lines (prev line ends with `,`/`(`/`[`) are left alone, matching
   the linter's W011 predicate — an argument-list continuation keeps its indent. *)
let test_indentation_skips_continuation () =
  let src = "#lang tesl\nfn f(\n   x: Int) -> Int =\n  x\n" in
  check string "continuation line indent untouched" src (fmt src)

let test_fat_arrow_spacing () =
  let out = fmt "#lang tesl\nlet p = forall x=>Q x\n" in
  check string "=> gets surrounding spaces"
    "#lang tesl\nlet p = forall x => Q x\n" out

let test_arrow_spacing_collapses () =
  let out = fmt "#lang tesl\nfn f(x: Int)  ->  Int  =  x\n" in
  check string "-> and = canonicalised to single spaces"
    "#lang tesl\nfn f(x: Int) -> Int = x\n" out

let test_exposing_short_stays_inline () =
  let out = fmt "#lang tesl\nmodule Short exposing [foo, bar]\n" in
  check string "short exposing stays on one line, no padding"
    "#lang tesl\nmodule Short exposing [foo, bar]\n" out

let test_exposing_inner_padding_removed () =
  let out = fmt "#lang tesl\nimport M exposing [ a, b, c ]\n" in
  check string "inner padding inside exposing brackets removed"
    "#lang tesl\nimport M exposing [a, b, c]\n" out

let test_exposing_multiline_collapses_clean () =
  let out = fmt "#lang tesl\nimport M exposing [\n  a, b, c\n]\n" in
  check string "short multi-line exposing collapses to clean single line"
    "#lang tesl\nimport M exposing [a, b, c]\n" out

let test_exposing_trailing_comma_dropped () =
  let out = fmt "#lang tesl\nmodule M exposing [a, b, c,]\n" in
  check string "trailing comma dropped in single-line exposing"
    "#lang tesl\nmodule M exposing [a, b, c]\n" out

let test_exposing_stray_commas_normalised () =
  let out = fmt "#lang tesl\nmodule M exposing [a,, b]\n" in
  check string "doubled commas normalised away"
    "#lang tesl\nmodule M exposing [a, b]\n" out

let test_exposing_leading_comma_normalised () =
  let out = fmt "#lang tesl\nmodule M exposing [, a, b]\n" in
  check string "leading comma normalised away"
    "#lang tesl\nmodule M exposing [a, b]\n" out

let test_exposing_long_splits_with_trailing_comma () =
  let out = fmt
    "#lang tesl\nmodule M exposing [aaaaaaaaaa, bbbbbbbbbb, cccccccccc, dddddddddd, eeeeeeeeee, ffffffffff]\n" in
  check string "over-width exposing splits one item per line with trailing comma"
    "#lang tesl\n\
     module M exposing [\n\
    \  aaaaaaaaaa,\n\
    \  bbbbbbbbbb,\n\
    \  cccccccccc,\n\
    \  dddddddddd,\n\
    \  eeeeeeeeee,\n\
    \  ffffffffff,\n\
     ]\n" out

let test_exposing_dotdot_preserved () =
  let out = fmt "#lang tesl\nimport Tesl.Prelude exposing [ Bool(..), Int ]\n" in
  check string "(..) re-export marker preserved through canonicalisation"
    "#lang tesl\nimport Tesl.Prelude exposing [Bool(..), Int]\n" out

let test_leading_blank_lines_removed () =
  let out = fmt "\n\n\n#lang tesl\nfn f(x: Int) -> Int = x\n" in
  check string "file never starts with a blank line"
    "#lang tesl\nfn f(x: Int) -> Int = x\n" out

let test_trailing_blank_lines_removed () =
  let out = fmt "#lang tesl\nfn f(x: Int) -> Int = x\n\n\n\n" in
  check string "file ends with exactly one newline"
    "#lang tesl\nfn f(x: Int) -> Int = x\n" out

let test_internal_blank_runs_collapsed () =
  let out = fmt "#lang tesl\nfn f(x: Int) -> Int = x\n\n\n\nfn g(x: Int) -> Int = x\n" in
  check string "internal blank runs collapse to a single blank line"
    "#lang tesl\nfn f(x: Int) -> Int = x\n\nfn g(x: Int) -> Int = x\n" out

let test_tabs_become_spaces () =
  let out = fmt "#lang tesl\nfn f(x: Int) -> Int =\n\tx\n" in
  check string "tab indentation becomes two spaces"
    "#lang tesl\nfn f(x: Int) -> Int =\n  x\n" out

let test_crlf_normalised () =
  let out = fmt "#lang tesl\r\nfn f(x: Int) -> Int = x\r\n" in
  check string "CRLF endings normalised to LF"
    "#lang tesl\nfn f(x: Int) -> Int = x\n" out

let test_comment_normalised () =
  let out = fmt "#lang tesl\n#a comment\nfn f(x: Int) -> Int = x\n" in
  check string "#comment gets a space after the hash"
    "#lang tesl\n# a comment\nfn f(x: Int) -> Int = x\n" out

let test_string_contents_untouched () =
  (* Operator characters inside string literals must NOT be re-spaced. *)
  let src = "#lang tesl\nlet s = \"a:b->c:::d,e==f\"\n" in
  let out = fmt src in
  check string "string literal contents preserved verbatim" src out

let test_doc_directives_untouched () =
  let src = "#lang tesl\n#>foo\n#=bar\n" in
  let out = fmt src in
  check string "#> and #= doc directives preserved" src out

let test_empty_file () =
  check string "empty file formats to a single newline" "\n" (fmt "")

(* Regression: the canonical output of an already-formatted file must be the
   file itself. This is the exact invariant `tesl --fmt-check` relies on. *)
let test_fmt_check_invariant () =
  (* A genuinely canonical file: short exposing list stays inline, blocks are
     separated by a single blank line, all spacing already normalised. A short
     list does NOT get expanded — the compact single-line form is canonical —
     so we use a deliberately over-width list to exercise the multi-line
     fixed point as well. *)
  let already_formatted =
    "#lang tesl\n\
     module Foo exposing [\n\
    \  alphaItemOne,\n\
    \  betaItemTwo,\n\
    \  gammaItemThree,\n\
    \  deltaItemFour,\n\
    \  epsilonItemFive,\n\
     ]\n\
     import Tesl.Prelude exposing [Bool(..), Int]\n\
     \n\
     fn alphaItemOne(x: Int) -> Int = x\n\
     \n\
     fn betaItemTwo(x: Int) -> Int = x\n\
     \n\
     fn gammaItemThree(x: Int) -> Int = x\n\
     \n\
     fn deltaItemFour(x: Int) -> Int = x\n\
     \n\
     fn epsilonItemFive(x: Int) -> Int = x\n"
  in
  check string "already-formatted file is a fixed point"
    already_formatted (fmt already_formatted);
  (* And the compact form of a short list is its own fixed point too. *)
  let short_canonical =
    "#lang tesl\n\
     module Bar exposing [foo, bar]\n\
     \n\
     fn foo(x: Int) -> Int = x\n"
  in
  check string "short-list canonical file is a fixed point"
    short_canonical (fmt short_canonical)

(* ── Suite registration ─────────────────────────────────────────────────── *)

let () =
  run "formatter" [
    "idempotence", [
      test_case "format(format(x)) == format(x) over corpus" `Quick test_idempotent_corpus;
      test_case "three passes agree (no oscillation)"        `Quick test_no_oscillation;
      test_case "fmt-check fixed-point invariant"            `Quick test_fmt_check_invariant;
    ];
    "spacing", [
      test_case "proof annotation + colon + arrow spacing"   `Quick test_proof_annotation_spacing;
      test_case "::: collapses extra spaces"                 `Quick test_proof_annotation_collapses_extra_spaces;
      test_case "=> fat arrow spacing"                       `Quick test_fat_arrow_spacing;
      test_case "normalizes odd indentation (T2)"            `Quick test_normalizes_odd_indentation;
      test_case "indentation skips continuation (T2)"        `Quick test_indentation_skips_continuation;
      test_case "-> and = collapse extra spaces"             `Quick test_arrow_spacing_collapses;
    ];
    "exposing-lists", [
      test_case "short list stays inline"                    `Quick test_exposing_short_stays_inline;
      test_case "inner padding removed"                      `Quick test_exposing_inner_padding_removed;
      test_case "short multi-line collapses clean"           `Quick test_exposing_multiline_collapses_clean;
      test_case "trailing comma dropped (single line)"       `Quick test_exposing_trailing_comma_dropped;
      test_case "doubled commas normalised"                  `Quick test_exposing_stray_commas_normalised;
      test_case "leading comma normalised"                   `Quick test_exposing_leading_comma_normalised;
      test_case "long list splits with trailing comma"       `Quick test_exposing_long_splits_with_trailing_comma;
      test_case "(..) re-export preserved"                   `Quick test_exposing_dotdot_preserved;
    ];
    "blank-lines", [
      test_case "leading blank lines removed"                `Quick test_leading_blank_lines_removed;
      test_case "trailing blank lines removed"               `Quick test_trailing_blank_lines_removed;
      test_case "internal blank runs collapsed"              `Quick test_internal_blank_runs_collapsed;
      test_case "empty file -> single newline"               `Quick test_empty_file;
    ];
    "line-cleanup", [
      test_case "tabs become spaces"                         `Quick test_tabs_become_spaces;
      test_case "CRLF normalised to LF"                      `Quick test_crlf_normalised;
      test_case "comment gets space after hash"              `Quick test_comment_normalised;
    ];
    "safety", [
      test_case "string contents untouched"                 `Quick test_string_contents_untouched;
      test_case "doc directives untouched"                  `Quick test_doc_directives_untouched;
    ];
  ]
