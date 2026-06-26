(** ProofSuite Family F — ForAll lists + filterCheck/allCheck + Dict quantifiers.

    Negative (must-NOT-compile) proofs that the *static* checker enforces the
    ForAll / ForAllValues / ForAllKeys discipline WITHOUT the runtime net, plus
    [should_pass] positive companions.

    Families covered:
      ARG   — wrong first argument to filterCheck/allCheck/Dict.* (lambda, plain
              fn, establish): "must be a declared check function".
      MISS  — return type promises ForAll (P && Q) but the check covers only P.
      PRED  — feed a ForAll P list to a fn requiring ForAll Q (predicate clash).
      CTR   — ForAllValues/ForAllKeys applied to a non-Dict container.
      MAP   — a proof-requiring fn passed to List.map as a plain callback.
      POS   — positive companions that MUST compile (expansion, Dict variants).

    Hardening: [should_fail] requires non-zero exit AND a regex match AND that
    the output contains NO runtime-leak markers (rejection must be STATIC). *)

open Alcotest

(* ── Compiler-path resolution ────────────────────────────────────────────── *)

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    (match Sys.getenv_opt "TESL_BIN" with
     | Some v when Filename.basename v = "main.exe" && Sys.file_exists v -> v
     | _ ->
       let dir = Filename.dirname Sys.argv.(0) in
       let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
       let candidate2 = Filename.concat dir "../bin/main.exe" in
       if Sys.file_exists candidate then candidate
       else if Sys.file_exists candidate2 then candidate2
       else "tesl")

let run_command cmd =
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  let code = match status with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n -> 128 + n | Unix.WSTOPPED n -> 128 + n
  in (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-psF" "" in
  let name =
    let re = Str.regexp "\\(module\\|library\\)[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 2 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then
          (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
        else Buffer.add_char buf c) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

(* Markers that a rejection escaped to RUNTIME rather than being caught
   statically.  NB: the compiler's own *static* error text legitimately quotes
   the tokens `check-ok`/`check-fail` when explaining why a lambda is invalid,
   so those bare words must NOT be treated as leak markers — we match only
   forms that indicate an actually-thrown runtime error. *)
let runtime_leak_re =
  Str.regexp_case_fold
    "raise-user-error\\|raise-argument-error\\|application: not a procedure\\|\
     racket/[A-Za-z_./-]*\\.rkt:[0-9]\\|^ *context\\.\\.\\.:\\|contract violation"

let assert_no_runtime_leak ctx out =
  try
    ignore (Str.search_forward runtime_leak_re out 0);
    failf "%s: rejection leaked to RUNTIME, expected STATIC compile error.\n%s" ctx out
  with Not_found -> ()

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected static failure matching %S, but compiled\n%s" pat out;
    assert_no_runtime_leak "should_fail" out;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let[@warning "-32"] known_gap ~what src =
  with_temp_file src (fun path ->
    let code, _ = run_compiler ["--check"; path] in
    if code <> 0 then
      failf "KNOWN GAP CLOSED — `%s` is now rejected; promote to should_fail." what)

(* ── Shared TESL fragments ───────────────────────────────────────────────── *)

let list_hdr modname = Printf.sprintf
  "#lang tesl\nmodule %s exposing []\n\
   import Tesl.Prelude exposing [Int, String, Bool(..), List, Fact]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n\
   import Tesl.List exposing [List.filterCheck, List.allCheck, List.length, List.map]\n"
  modname

let dict_hdr modname = Printf.sprintf
  "#lang tesl\nmodule %s exposing []\n\
   import Tesl.Prelude exposing [Int, String, Bool(..), List, Fact]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n\
   import Tesl.Dict exposing [Dict, Dict.filterCheckValues, Dict.filterCheckKeys]\n\
   import Tesl.String exposing [String.length, String.isEmpty]\n"
  modname

(* Two single-subject Int checks plus the facts they produce. *)
let int_checks = {|
fact IsPos (n: Int)
fact IsSmall (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPos n =
  if n > 0 then
    ok n ::: IsPos n
  else
    fail 400 "not positive"
check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "too big"
|}

let check_arg_re =
  "must be a declared .check. function\\|not a .check. function\\|\
   declared .check. function or"

(* ══════════════════════════════════════════════════════════════════════════
   ARG — wrong first argument to a filterCheck / allCheck family function.
   Matrix:  fn_name × bad_argument_kind.
   ══════════════════════════════════════════════════════════════════════════ *)

(* Each bad-argument fragment defines a binding of the wrong kind (or none, for
   the inline lambda) and yields the expression text to pass to the consumer. *)
let bad_args = [
  ("lambda",
   "",
   "(fn(n: Int) -> n ::: IsPos n)");
  ("lambda-bool",
   "",
   "(fn(n: Int) -> n > 0)");
  ("plainfn",
   "fn plainArg(n: Int) -> Int = n + 1\n",
   "plainArg");
  ("plainfn-id",
   "fn idArg(n: Int) -> Int = n\n",
   "idArg");
  ("establish",
   "establish estArg(n: Int) -> Maybe (Fact (IsPos n)) =\n\
   \  if n > 0 then\n    Something (IsPos n)\n  else\n    Nothing\n",
   "estArg");
]

(* List.filterCheck with each bad argument. *)
let arg_list_filtercheck idx (label, decl, expr) =
  let m = Printf.sprintf "ArgLf%02d" idx in
  let test () =
    should_fail check_arg_re
      (list_hdr m ^ int_checks ^ decl ^ Printf.sprintf {|
fn bad(xs: List Int) -> List Int ? ForAll (IsPos) requires [] =
  List.filterCheck %s xs
|} expr)
  in
  (Printf.sprintf "ARG-LF-%02d filterCheck given %s" idx label, test)

(* List.allCheck with each bad argument. *)
let arg_list_allcheck idx (label, decl, expr) =
  let m = Printf.sprintf "ArgAc%02d" idx in
  let test () =
    should_fail check_arg_re
      (list_hdr m ^ int_checks ^ decl ^ Printf.sprintf {|
fn bad(xs: List Int) -> Maybe (List Int) requires [] =
  List.allCheck %s xs
|} expr)
  in
  (Printf.sprintf "ARG-AC-%02d allCheck given %s" idx label, test)

let arg_list_cases =
  List.concat (List.mapi (fun i ba ->
    [ arg_list_filtercheck (i + 1) ba; arg_list_allcheck (i + 1) ba ]) bad_args)

(* Dict facts/checks (values are Int, keys are String). *)
let dict_facts = {|
fact IsPos (n: Int)
fact IsNonEmpty (s: String)
check checkPos(n: Int) -> n: Int ::: IsPos n =
  if n > 0 then
    ok n ::: IsPos n
  else
    fail 400 "not positive"
check checkNonEmpty(s: String) -> s: String ::: IsNonEmpty s =
  if String.isEmpty s then
    fail 400 "empty"
  else
    ok s ::: IsNonEmpty s
|}

let arg_dict_values idx (label, decl, expr) =
  let m = Printf.sprintf "ArgDv%02d" idx in
  let test () =
    should_fail check_arg_re
      (dict_hdr m ^ dict_facts ^ decl ^ Printf.sprintf {|
fn bad(raw: Dict String Int) -> Dict String Int ::: ForAllValues IsPos =
  Dict.filterCheckValues %s raw
|} expr)
  in
  (Printf.sprintf "ARG-DV-%02d filterCheckValues given %s" idx label, test)

let arg_dict_keys idx label decl expr =
  let m = Printf.sprintf "ArgDk%02d" idx in
  let test () =
    should_fail check_arg_re
      (dict_hdr m ^ dict_facts ^ decl ^ Printf.sprintf {|
fn bad(raw: Dict String Int) -> Dict String Int ::: ForAllKeys IsNonEmpty =
  Dict.filterCheckKeys %s raw
|} expr)
  in
  (Printf.sprintf "ARG-DK-%02d filterCheckKeys given %s" idx label, test)

let arg_dict_cases =
  [ arg_dict_values 1 ("lambda", "", "(fn(n: Int) -> n ::: IsPos n)");
    arg_dict_values 2 ("lambda-bool", "", "(fn(n: Int) -> n > 0)");
    arg_dict_values 3 ("plainfn", "fn plainArg(n: Int) -> Int = n + 1\n", "plainArg");
    arg_dict_values 4 ("plainfn-id", "fn idArg(n: Int) -> Int = n\n", "idArg");
    arg_dict_values 5
      ("establish",
       "establish estArg(n: Int) -> Maybe (Fact (IsPos n)) =\n\
       \  if n > 0 then\n    Something (IsPos n)\n  else\n    Nothing\n",
       "estArg");
    arg_dict_keys 1 "lambda" "" "(fn(s: String) -> s ::: IsNonEmpty s)";
    arg_dict_keys 2 "lambda-bool" "" "(fn(s: String) -> String.isEmpty s)";
    arg_dict_keys 3 "plainfn" "fn plainKeyArg(s: String) -> String = s\n" "plainKeyArg";
    arg_dict_keys 4 "plainfn-up"
      "fn upKeyArg(s: String) -> String = s\n" "upKeyArg"; ]

(* ══════════════════════════════════════════════════════════════════════════
   MISS — return promises ForAll (P && Q) but the check covers only one.
   ══════════════════════════════════════════════════════════════════════════ *)

let miss_re = "missing\\|requires.*\\[\\|produces.*\\[\\|does not\\|ForAll"

let miss_conjunct idx ~promised ~run =
  let m = Printf.sprintf "Miss%02d" idx in
  let test () =
    should_fail miss_re
      (list_hdr m ^ int_checks ^ Printf.sprintf {|
fn bad(xs: List Int) -> List Int ? ForAll (%s) requires [] =
  List.filterCheck %s xs
|} promised run)
  in
  (Printf.sprintf "MISS-%02d promise (%s) run %s" idx promised run, test)

(* GAP-ALLCHECK-RET — CLOSED.
   `List.filterCheck` verifies the return-spec conjunction against the check's
   produced predicates (MISS-01/02 above, correctly rejected).  `List.allCheck`
   now does too: an allCheck return type `Maybe (... ::: ForAll (IsPos && IsSmall))`
   backed only by `checkPos` (which establishes `IsPos`) is rejected for the
   missing `IsSmall` conjunct.  (Downstream *consumption* of an over-claimed list
   is also rejected — see MISS-04.) *)
let miss_allcheck_gap () =
  should_fail miss_re
    (list_hdr "Miss03" ^ int_checks ^ {|
fn bad(xs: List Int) -> Maybe (xs: List Int ::: ForAll (IsPos && IsSmall) xs) requires [] =
  List.allCheck checkPos xs
|})

(* Consuming an allCheck result (which only ran checkPos) at a site demanding
   ForAll (IsPos && IsSmall) IS statically rejected — the over-claim does not
   propagate to consumers. *)
let miss_allcheck_consume () =
  should_fail miss_re
    (list_hdr "Miss04" ^ int_checks ^ {|
fn needsBoth(xs: List Int ::: ForAll (IsPos && IsSmall) xs) -> Int = List.length xs
fn bad(xs: List Int) -> Int requires [] =
  case List.allCheck checkPos xs of
    Nothing -> 0
    Something ys -> needsBoth ys
|})

let miss_cases =
  [ miss_conjunct 1 ~promised:"IsPos && IsSmall" ~run:"checkPos";
    miss_conjunct 2 ~promised:"IsPos && IsSmall" ~run:"checkSmall";
    miss_conjunct 4 ~promised:"IsSmall && IsPos" ~run:"checkPos";
    miss_conjunct 5 ~promised:"IsSmall && IsPos" ~run:"checkSmall";
    ("MISS-03 allCheck return over-claim (KNOWN GAP)", miss_allcheck_gap);
    ("MISS-04 allCheck over-claim rejected at consumer", miss_allcheck_consume); ]

(* ══════════════════════════════════════════════════════════════════════════
   PRED — feed a ForAll P list to a fn requiring ForAll Q.
   ══════════════════════════════════════════════════════════════════════════ *)

let pred_re = "does not.*statically.*satisfy\\|ForAll\\|V001"

let pred_clash idx ~built ~required =
  let m = Printf.sprintf "Pred%02d" idx in
  let test () =
    should_fail pred_re
      (list_hdr m ^ int_checks ^ Printf.sprintf {|
fn needs(xs: List Int ::: ForAll (%s) xs) -> Int = List.length xs
fn bad(nums: List Int) -> Int =
  let xs = List.filterCheck %s nums
  needs xs
|} required built)
  in
  (Printf.sprintf "PRED-%02d build %s require ForAll(%s)" idx built required, test)

(* Same predicate clash, but built via allCheck (consumed after the Maybe). *)
let pred_allcheck_clash idx ~built ~required =
  let m = Printf.sprintf "PredAc%02d" idx in
  let test () =
    should_fail pred_re
      (list_hdr m ^ int_checks ^ Printf.sprintf {|
fn needs(xs: List Int ::: ForAll (%s) xs) -> Int = List.length xs
fn bad(nums: List Int) -> Int =
  case List.allCheck %s nums of
    Nothing -> 0
    Something ys -> needs ys
|} required built)
  in
  (Printf.sprintf "PRED-AC-%02d allCheck %s require ForAll(%s)" idx built required, test)

let pred_cases =
  [ pred_clash 1 ~built:"checkPos" ~required:"IsSmall";
    pred_clash 2 ~built:"checkSmall" ~required:"IsPos";
    pred_clash 3 ~built:"checkPos" ~required:"IsPos && IsSmall";
    pred_clash 4 ~built:"checkSmall" ~required:"IsPos && IsSmall";
    pred_clash 5 ~built:"(checkPos && checkSmall)" ~required:"IsSmall && IsPos";
    pred_clash 6 ~built:"checkPos" ~required:"IsSmall && IsPos";
    pred_allcheck_clash 1 ~built:"checkPos" ~required:"IsSmall";
    pred_allcheck_clash 2 ~built:"checkSmall" ~required:"IsPos";
    pred_allcheck_clash 3 ~built:"checkPos" ~required:"IsPos && IsSmall"; ]
let _ = pred_clash

let pred_bare_list () =
  should_fail pred_re
    (list_hdr "PredBare01" ^ int_checks ^ {|
fn needs(xs: List Int ::: ForAll (IsPos) xs) -> Int = List.length xs
fn bad(nums: List Int) -> Int =
  needs nums
|})

let pred_bare_cases = [ ("PRED-BARE-01 bare list at ForAll site", pred_bare_list) ]

(* ══════════════════════════════════════════════════════════════════════════
   CTR — ForAllValues / ForAllKeys on a non-Dict container.
   ══════════════════════════════════════════════════════════════════════════ *)

let ctr_re =
  "ForAllValues\\|ForAllKeys\\|only.*meaningful\\|not a .Dict\\|Dict K V"

let ctr_wrong idx ~quant ~ty =
  let m = Printf.sprintf "Ctr%02d" idx in
  let test () =
    should_fail ctr_re
      (Printf.sprintf
        "#lang tesl\nmodule %s exposing []\n\
         import Tesl.Prelude exposing [Int, String, List, Fact]\n\
         fact IsPos (n: Int)\n\
         fn bad(xs: %s ::: %s IsPos xs) -> Int = 0\n" m ty quant)
  in
  (Printf.sprintf "CTR-%02d %s on %s" idx quant ty, test)

let ctr_cases =
  [ ctr_wrong 1 ~quant:"ForAllValues" ~ty:"List Int";
    ctr_wrong 2 ~quant:"ForAllKeys" ~ty:"List Int";
    ctr_wrong 3 ~quant:"ForAllValues" ~ty:"Int";
    ctr_wrong 4 ~quant:"ForAllKeys" ~ty:"String";
    ctr_wrong 5 ~quant:"ForAllValues" ~ty:"List String";
    ctr_wrong 6 ~quant:"ForAllKeys" ~ty:"Int";
    ctr_wrong 7 ~quant:"ForAllValues" ~ty:"String";
    ctr_wrong 8 ~quant:"ForAllKeys" ~ty:"List String"; ]

(* ══════════════════════════════════════════════════════════════════════════
   MAP — proof-requiring fn passed to List.map as a plain callback.
   ══════════════════════════════════════════════════════════════════════════ *)

let map_re =
  "plain callback\\|requires proof annotations\\|cannot be passed\\|\
   cannot satisfy\\|partial"

let map_plain_callback () =
  should_fail map_re
    (list_hdr "Map01" ^ int_checks ^ {|
fn needsProof(n: Int ::: IsPos n) -> String = "ok"
fn bad(xs: List Int) -> List String requires [] =
  List.map needsProof xs
|})

let map_partial () =
  should_fail map_re
    (list_hdr "MapPart01" ^ int_checks ^ {|
fn needsTwo(base: Int, n: Int ::: IsPos n) -> Int = base + n
fn bad(xs: List Int) -> List Int requires [] =
  let addTen = needsTwo 10
  List.map addTen xs
|})

(* A proof-requiring fn passed to other higher-order list consumers. *)
let map_via idx ~consumer ~setup =
  let m = Printf.sprintf "MapVia%02d" idx in
  let test () =
    should_fail map_re
      (list_hdr m ^ int_checks ^ Printf.sprintf {|
fn needsProof(n: Int ::: IsPos n) -> String = "ok"
%s
fn bad(xs: List Int) -> Int requires [] =
  let _ = %s
  List.length xs
|} "" setup)
  in
  (Printf.sprintf "MAP-VIA-%02d proof fn via %s" idx consumer, test)
let _ = map_via

let map_cases =
  [ ("MAP-01 proof fn to List.map", map_plain_callback);
    ("MAP-PART-01 partial-applied proof fn to map", map_partial);
    (* partial application of a 3-arg proof fn *)
    ("MAP-PART-02 partial 3-arg proof fn to map",
     fun () ->
       should_fail map_re
         (list_hdr "MapPart02" ^ int_checks ^ {|
fn needsThree(a: Int, b: Int, n: Int ::: IsPos n) -> Int = a + b + n
fn bad(xs: List Int) -> List Int requires [] =
  let f = needsThree 1 2
  List.map f xs
|}));
    (* proof fn bound to a let then passed *)
    ("MAP-03 let-bound proof fn to map",
     fun () ->
       should_fail map_re
         (list_hdr "Map03" ^ int_checks ^ {|
fn needsProof(n: Int ::: IsPos n) -> String = "ok"
fn bad(xs: List Int) -> List String requires [] =
  let g = needsProof
  List.map g xs
|})); ]

(* ══════════════════════════════════════════════════════════════════════════
   POS — positive companions (MUST compile).
   ══════════════════════════════════════════════════════════════════════════ *)

let pos_filtercheck_single () =
  should_pass (list_hdr "PosF01" ^ int_checks ^ {|
fn needs(xs: List Int ::: ForAll (IsPos) xs) -> Int = List.length xs
fn good(nums: List Int) -> Int =
  let xs = List.filterCheck checkPos nums
  needs xs
|})

let pos_filtercheck_expansion () =
  should_pass (list_hdr "PosF02" ^ int_checks ^ {|
fn narrow(xs: List Int ::: ForAll (IsPos) xs) -> List Int ? ForAll (IsPos && IsSmall) requires [] =
  List.filterCheck checkSmall xs
fn needsBoth(xs: List Int ::: ForAll (IsPos && IsSmall) xs) -> Int = List.length xs
|})

let pos_combined_check () =
  should_pass (list_hdr "PosF03" ^ int_checks ^ {|
fn filterBoth(nums: List Int) -> List Int ? ForAll (IsPos && IsSmall) requires [] =
  List.filterCheck (checkPos && checkSmall) nums
|})

let pos_allcheck_single () =
  should_pass (list_hdr "PosF04" ^ int_checks ^ {|
fn verify(nums: List Int) -> Maybe (nums: List Int ::: ForAll (IsPos) nums) requires [] =
  List.allCheck checkPos nums
|})

let pos_allcheck_combined () =
  should_pass (list_hdr "PosF05" ^ int_checks ^ {|
fn verify(nums: List Int) -> Maybe (nums: List Int ::: ForAll (IsPos && IsSmall) nums) requires [] =
  List.allCheck (checkPos && checkSmall) nums
|})

let pos_forall_param () =
  should_pass (list_hdr "PosF06" ^ int_checks ^ {|
fn countBoth(xs: List Int ::: ForAll (IsPos && IsSmall) xs) -> Int = List.length xs
|})

let pos_sequential_filter () =
  should_pass (list_hdr "PosF07" ^ int_checks ^ {|
fn needsBoth(xs: List Int ::: ForAll (IsPos && IsSmall) xs) -> Int = List.length xs
fn good(nums: List Int) -> Int =
  let pos = List.filterCheck checkPos nums
  let both = List.filterCheck checkSmall pos
  needsBoth both
|})

let pos_dict_values () =
  should_pass (dict_hdr "PosF08" ^ dict_facts ^ {|
fn getVerified(raw: Dict String Int) -> Dict String Int ::: ForAllValues IsPos =
  Dict.filterCheckValues checkPos raw
|})

let pos_dict_keys () =
  should_pass (dict_hdr "PosF09" ^ dict_facts ^ {|
fn getByKeys(raw: Dict String Int) -> Dict String Int ::: ForAllKeys IsNonEmpty =
  Dict.filterCheckKeys checkNonEmpty raw
|})

let pos_select_forall () =
  should_pass (Printf.sprintf
    "#lang tesl\nmodule PosF10 exposing []\n\
     import Tesl.Prelude exposing [String, List]\n\
     import Tesl.DB exposing [dbRead]\n%s"
    {|
entity Note table "notes" primaryKey id { id: String authorId: String }
fn listNotes(user: String) -> List Note ? ForAll (FromDb (AuthorId == user))
  requires [dbRead] =
  select note from Note where note.authorId == user
|})

let pos_combined_single_value () =
  should_pass (list_hdr "PosF11" ^ int_checks ^ {|
fn applyBoth(n: Int) -> Int ? (IsPos && IsSmall) requires [] =
  check (checkPos && checkSmall) n
|})

let pos_filter_then_consume () =
  should_pass (list_hdr "PosF12" ^ int_checks ^ {|
fn needsSmall(xs: List Int ::: ForAll (IsSmall) xs) -> Int = List.length xs
fn good(nums: List Int) -> Int =
  let xs = List.filterCheck checkSmall nums
  needsSmall xs
|})

(* Dict.filterCheckValues result re-affirmed at a ForAllValues *return* site
   (the supported shape; ForAllValues is a return-type quantifier, not a
   parameter annotation). *)
let pos_dict_values_return () =
  should_pass (dict_hdr "PosF13" ^ dict_facts ^ {|
fn refine(raw: Dict String Int) -> Dict String Int ::: ForAllValues IsPos =
  let d = Dict.filterCheckValues checkPos raw
  d
|})

(* ── Registration ────────────────────────────────────────────────────────── *)

let to_cases lst = List.map (fun (name, fn) -> test_case name `Quick fn) lst

let () =
  run "ProofSuite-F" [
    "ARG-bad-check-argument", to_cases (arg_list_cases @ arg_dict_cases);
    "MISS-missing-conjunct", to_cases miss_cases;
    "PRED-predicate-clash", to_cases (pred_cases @ pred_bare_cases);
    "CTR-wrong-container", to_cases ctr_cases;
    "MAP-plain-callback", to_cases map_cases;
    "POS-companions", [
      test_case "POS filterCheck single predicate" `Quick pos_filtercheck_single;
      test_case "POS filterCheck expansion P1->P1&&P2" `Quick pos_filtercheck_expansion;
      test_case "POS combined check &&" `Quick pos_combined_check;
      test_case "POS allCheck single predicate" `Quick pos_allcheck_single;
      test_case "POS allCheck combined check" `Quick pos_allcheck_combined;
      test_case "POS ForAll parameter contract" `Quick pos_forall_param;
      test_case "POS sequential filterCheck accumulates" `Quick pos_sequential_filter;
      test_case "POS Dict.filterCheckValues" `Quick pos_dict_values;
      test_case "POS Dict.filterCheckKeys" `Quick pos_dict_keys;
      test_case "POS select auto ForAll(FromDb)" `Quick pos_select_forall;
      test_case "POS combined check single value" `Quick pos_combined_single_value;
      test_case "POS filter then consume" `Quick pos_filter_then_consume;
      test_case "POS Dict values return-site" `Quick pos_dict_values_return;
    ];
  ]
