(** ProofSuite Family B — proof CONSUMPTION (`fn` / `handler` / `worker` params
    that REQUIRE a proof).

    NEG-CORE: compile-time rejection of every "passed an unproven value at a
    proof-required parameter" mistake, proven WITHOUT the runtime net. Modeled on
    [test_library_negative.ml] / [test_review20_antagonistic.ml].

    Every negative is STATIC: [should_fail] asserts non-zero exit AND no runtime
    leak. A negative that compiles is a real static-checker gap; such cases are
    named `..._GAP_...` and reported (informs ZC-FINALIZE).

    Anchors: `check_call_proofs` / `validation_proof.ml` (V001
    "does not statically satisfy declared proof"). Handlers cannot be called from
    code, so handler/worker consumption is exercised from inside their BODY. *)

open Alcotest

(* ── Inlined harness (self-contained per NEG-CORE brief) ─────────────────── *)

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
    | Unix.WEXITED c -> c | Unix.WSIGNALED n -> 128+n | Unix.WSTOPPED n -> 128+n
  in (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-psB" "" in
  let name =
    let re = Str.regexp "\\(module\\|library\\)[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 2 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
        else Buffer.add_char buf c) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let runtime_leak_re =
  Str.regexp_case_fold "raise-user-error\\|check-fail\\|context\\.\\.\\.:\\|/racket/\\|collects/racket"

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then
      failf "expected STATIC failure matching %S, but compiled cleanly:\n%s" pat out;
    (try ignore (Str.search_forward runtime_leak_re out 0);
       failf "rejection leaked to RUNTIME (not static) for %S, got:\n%s" pat out
     with Not_found -> ());
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected clean compile, got exit %d:\n%s" code out)

let prelude name =
  Printf.sprintf
    "#lang tesl\nmodule %s exposing []\n\
     import Tesl.Prelude exposing [Int, String, Bool(..), List, Fact]\n\
     import Tesl.Maybe exposing [Maybe(..)]\n" name

(* the dominant consumption rejection *)
let unsat = "does not statically satisfy declared proof"

(* ── B. Hand-written CONSUMPTION negatives ───────────────────────────────── *)

(* raw `Int` passed where `n: Int ::: P n` is required. *)
let test_B_raw_at_proof_pos () =
  should_fail unsat (prelude "BRaw" ^ {|
fact IsPositive (n: Int)
fn needs(n: Int ::: IsPositive n) -> Int = n
fn caller(raw: Int) -> Int =
  needs raw
|})

(* a literal passed directly at a proof position. *)
let test_B_literal_direct () =
  should_fail (unsat ^ "\\|requires proof.*literal") (prelude "BLitDirect" ^ {|
fact IsPositive (n: Int)
fn needs(n: Int ::: IsPositive n) -> Int = n
fn caller() -> Int =
  needs 100
|})

(* a literal bound to a name first, then passed (still unproven). *)
let test_B_literal_bound () =
  should_fail (unsat ^ "\\|requires proof.*literal") (prelude "BLitBound" ^ {|
fact IsPositive (n: Int)
fn needs(n: Int ::: IsPositive n) -> Int = n
fn caller() -> Int =
  let x = 42
  needs x
|})

(* an expression with no trackable subject at a proof position. *)
let test_B_expr_no_subject () =
  should_fail "expression with no trackable subject" (prelude "BExpr" ^ {|
fact IsPositive (n: Int)
fn needs(n: Int ::: IsPositive n) -> Int = n
fn other(x: Int) -> Int = x
fn caller(raw: Int) -> Int =
  needs (other raw)
|})

(* arithmetic expression (no subject) at a proof position. *)
let test_B_arith_expr_no_subject () =
  should_fail "expression with no trackable subject\\|does not statically satisfy"
    (prelude "BArith" ^ {|
fact IsPositive (n: Int)
fn needs(n: Int ::: IsPositive n) -> Int = n
fn caller(raw: Int) -> Int =
  needs (raw + 1)
|})

(* validated a DIFFERENT value, then passed the unvalidated one. *)
let test_B_validated_other_value () =
  should_fail unsat (prelude "BOther" ^ {|
fact IsPositive (n: Int)
check c(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn needs(n: Int ::: IsPositive n) -> Int = n
fn caller(a: Int, b: Int) -> Int =
  let v = check c a
  needs b
|})

(* a proof-carrying PARAM, run through arithmetic, drops the proof. *)
let test_B_proof_param_after_arith () =
  should_fail unsat (prelude "BParamArith" ^ {|
fact IsPositive (n: Int)
fn needs(n: Int ::: IsPositive n) -> Int = n
fn caller(p: Int ::: IsPositive p) -> Int =
  let doubled = p + p
  needs doubled
|})

(* called a proof-requiring fn from a body that never validated anything. *)
let test_B_never_validated () =
  should_fail unsat (prelude "BNever" ^ {|
fact IsPositive (n: Int)
fn needs(n: Int ::: IsPositive n) -> Int = n
fn caller(a: Int) -> Int =
  let y = a + 0
  needs a
|})

(* handler BODY consuming a raw value (handlers can't be called externally). *)
let test_B_handler_body_raw () =
  should_fail unsat (prelude "BHandlerRaw" ^ {|
import Tesl.Http exposing [HttpRequest]
fact IsPositive (n: Int)
fn needs(n: Int ::: IsPositive n) -> Int = n
handler h(raw: Int) -> Int requires [] =
  needs raw
|})

(* worker BODY consuming a raw value. *)
let test_B_worker_body_raw () =
  should_fail unsat (prelude "BWorkerRaw" ^ {|
record Job { n: Int }
fact JobOk (j: Job)
fn needs(j: Job ::: JobOk j) -> Job = j
worker w(raw: Job) requires [] =
  needs raw
|})

(* directly calling a handler from code is itself rejected. *)
let test_B_handler_called_from_code () =
  should_fail "handlers cannot be called from code\\|only the server router" (prelude "BHandlerCall" ^ {|
fact IsPositive (n: Int)
handler h(n: Int ::: IsPositive n) -> Int requires [] = n
fn caller(raw: Int) -> Int =
  h raw
|})

(* conjunction param: only one proof produced, both required. *)
let test_B_conjunction_partial () =
  should_fail unsat (prelude "BConjPart" ^ {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)
check cp(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn needsBoth(n: Int ::: IsPositive n && IsSmall n) -> Int = n
fn caller(raw: Int) -> Int =
  let v = check cp raw
  needsBoth v
|})

(* string-subject proof: raw String at proof position. *)
let test_B_string_raw () =
  should_fail unsat (prelude "BStrRaw" ^ {|
import Tesl.String exposing [String.length]
fact IsNonEmpty (s: String)
fn needs(s: String ::: IsNonEmpty s) -> String = s
fn caller(raw: String) -> String =
  needs raw
|})

(* 2-arg subject proof: raw at proof position. *)
let test_B_two_arg_raw () =
  should_fail unsat (prelude "BTwoArg" ^ {|
fact Linked (owner: Int) (item: Int)
fn needs(o: Int, i: Int ::: Linked o i) -> Int = i
fn caller(o: Int, raw: Int) -> Int =
  needs o raw
|})

(* literal-param proof (Clamped 1 100): raw at proof position. *)
let test_B_literal_param_raw () =
  should_fail unsat (prelude "BClampRaw" ^ {|
fact Clamped (lo: Int) (hi: Int) (n: Int)
fn needs(n: Int ::: Clamped 1 100 n) -> Int = n
fn caller(raw: Int) -> Int =
  needs raw
|})

(* ── B. Positive sanity — correct CONSUMPTION compiles ───────────────────── *)

let test_B_pos_validated_flows () =
  should_pass (prelude "BPosFlow" ^ {|
fact IsPositive (n: Int)
check c(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn needs(n: Int ::: IsPositive n) -> Int = n
fn caller(raw: Int) -> Int =
  let v = check c raw
  needs v
|})

let test_B_pos_handler_body_validates () =
  should_pass (prelude "BPosHandler" ^ {|
import Tesl.Http exposing [HttpRequest]
fact IsPositive (n: Int)
check c(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn needs(n: Int ::: IsPositive n) -> Int = n
handler h(raw: Int) -> Int requires [] =
  let v = check c raw
  needs v
|})

let test_B_pos_worker_body_validates () =
  should_pass (prelude "BPosWorker" ^ {|
record Job { n: Int }
fact JobOk (j: Job)
check c(j: Job) -> j: Job ::: JobOk j =
  ok j ::: JobOk j
fn needs(j: Job ::: JobOk j) -> Job = j
worker w(raw: Job) requires [] =
  let v = check c raw
  needs v
|})

let test_B_pos_proof_param_passthrough () =
  (* a value that already carries the proof (as a param) flows to a consumer. *)
  should_pass (prelude "BPosParam" ^ {|
fact IsPositive (n: Int)
fn needs(n: Int ::: IsPositive n) -> Int = n
fn forward(n: Int ::: IsPositive n) -> Int =
  needs n
|})

let test_B_pos_two_arg_validated () =
  should_pass (prelude "BPosTwoArg" ^ {|
fact Linked (owner: Int) (item: Int)
check c(o: Int, i: Int) -> i: Int ::: Linked o i =
  if i > 0 then
    ok i ::: Linked o i
  else
    fail 400 "bad"
fn needs(o: Int, i: Int ::: Linked o i) -> Int = i
fn caller(o: Int, raw: Int) -> Int =
  let v = check c o raw
  needs o v
|})

let test_B_pos_literal_param_validated () =
  should_pass (prelude "BPosClamp" ^ {|
fact Clamped (lo: Int) (hi: Int) (n: Int)
check c(n: Int) -> n: Int ::: Clamped 1 100 n =
  if n >= 1 && n <= 100 then
    ok n ::: Clamped 1 100 n
  else
    fail 400 "oob"
fn needs(n: Int ::: Clamped 1 100 n) -> Int = n
fn caller(raw: Int) -> Int =
  let v = check c raw
  needs v
|})

(* ── B. Parameterized CONSUMPTION negatives (Tier 2) ─────────────────────── *)
(* predicate axis × consumer-kind × consumption-mistake-shape, generated from
   data so adding a predicate adds N cases for free. *)

type pred = {
  pname : string;    (* short axis name for labels *)
  decl : string;     (* fact declaration(s) *)
  chk  : string;     (* a `check c(...)` producer that establishes the proof *)
  ty   : string;     (* subject type of the proof-carrying parameter *)
  needs_decl : string;          (* `fn needs(...) -> ... = ...` *)
  call : string -> string;      (* given the proof-carrying arg, the `needs` call *)
  imports : string;             (* extra imports *)
}

(* `suffix` keeps fact names unique per (kind, mistake) bucket. *)
let predicates suffix = [
  (* 1-arg Int *)
  { pname = "Int";
    decl = Printf.sprintf "fact PbPos%s (n: Int)" suffix;
    chk = Printf.sprintf
        "check c(x: Int) -> x: Int ::: PbPos%s x =\n  if x > 0 then\n    ok x ::: PbPos%s x\n  else\n    fail 400 \"bad\"\n" suffix suffix;
    ty = "Int";
    needs_decl = Printf.sprintf "fn needs(x: Int ::: PbPos%s x) -> Int = x\n" suffix;
    call = (fun a -> Printf.sprintf "needs %s" a);
    imports = "" };
  (* 1-arg String *)
  { pname = "String";
    decl = Printf.sprintf "fact PbNE%s (s: String)" suffix;
    chk = Printf.sprintf
        "check c(x: String) -> x: String ::: PbNE%s x =\n  if String.length x > 0 then\n    ok x ::: PbNE%s x\n  else\n    fail 400 \"bad\"\n" suffix suffix;
    ty = "String";
    needs_decl = Printf.sprintf "fn needs(x: String ::: PbNE%s x) -> String = x\n" suffix;
    call = (fun a -> Printf.sprintf "needs %s" a);
    imports = "import Tesl.String exposing [String.length]\n" };
  (* literal-param 3-arg Int *)
  { pname = "Clamped";
    decl = Printf.sprintf "fact PbClamp%s (lo: Int) (hi: Int) (n: Int)" suffix;
    chk = Printf.sprintf
        "check c(x: Int) -> x: Int ::: PbClamp%s 1 100 x =\n  if x >= 1 && x <= 100 then\n    ok x ::: PbClamp%s 1 100 x\n  else\n    fail 400 \"oob\"\n" suffix suffix;
    ty = "Int";
    needs_decl = Printf.sprintf "fn needs(x: Int ::: PbClamp%s 1 100 x) -> Int = x\n" suffix;
    call = (fun a -> Printf.sprintf "needs %s" a);
    imports = "" };
  (* second 1-arg Int predicate (distinct fact) *)
  { pname = "Even";
    decl = Printf.sprintf "fact PbEven%s (n: Int)" suffix;
    chk = Printf.sprintf
        "check c(x: Int) -> x: Int ::: PbEven%s x =\n  if x > 0 then\n    ok x ::: PbEven%s x\n  else\n    fail 400 \"bad\"\n" suffix suffix;
    ty = "Int";
    needs_decl = Printf.sprintf "fn needs(x: Int ::: PbEven%s x) -> Int = x\n" suffix;
    call = (fun a -> Printf.sprintf "needs %s" a);
    imports = "" };
  (* second 1-arg String predicate (distinct fact) *)
  { pname = "Trimmed";
    decl = Printf.sprintf "fact PbTrim%s (s: String)" suffix;
    chk = Printf.sprintf
        "check c(x: String) -> x: String ::: PbTrim%s x =\n  if String.length x > 0 then\n    ok x ::: PbTrim%s x\n  else\n    fail 400 \"bad\"\n" suffix suffix;
    ty = "String";
    needs_decl = Printf.sprintf "fn needs(x: String ::: PbTrim%s x) -> String = x\n" suffix;
    call = (fun a -> Printf.sprintf "needs %s" a);
    imports = "import Tesl.String exposing [String.length]\n" };
  (* second literal-param style Int predicate (distinct fact) *)
  { pname = "Bounded";
    decl = Printf.sprintf "fact PbBound%s (n: Int)" suffix;
    chk = Printf.sprintf
        "check c(x: Int) -> x: Int ::: PbBound%s x =\n  if x < 1000 then\n    ok x ::: PbBound%s x\n  else\n    fail 400 \"bad\"\n" suffix suffix;
    ty = "Int";
    needs_decl = Printf.sprintf "fn needs(x: Int ::: PbBound%s x) -> Int = x\n" suffix;
    call = (fun a -> Printf.sprintf "needs %s" a);
    imports = "" };
]

let literal_of ty = if ty = "String" then "\"hi\"" else "42"

(* consumer wrapper for each kind; [pre] are statements before the failing call. *)
let consumer_kind_src kind ty ~pre ~needs_call =
  let body = pre ^ needs_call in
  match kind with
  | "fn" -> Printf.sprintf "fn caller(raw: %s) -> %s =\n%s\n" ty ty body
  | "handler" -> Printf.sprintf "handler caller(raw: %s) -> %s requires [] =\n%s\n" ty ty body
  | "worker" -> Printf.sprintf "worker caller(raw: %s) requires [] =\n%s\n" ty body
  | _ -> assert false

let consume_param_cases () =
  let kinds = [ "fn"; "handler"; "worker" ] in
  let mistakes =
    [ `Raw; `Literal; `Expr; `Passthrough; `ForgotCheck; `WrongValidated ] in
  let mtag = function
    | `Raw -> "R" | `Literal -> "L" | `Expr -> "E"
    | `Passthrough -> "P" | `ForgotCheck -> "F" | `WrongValidated -> "W" in
  let mlabel = function
    | `Raw -> "raw-arg" | `Literal -> "literal" | `Expr -> "expr-no-subject"
    | `Passthrough -> "passthrough-drops-proof"
    | `ForgotCheck -> "forgot-check"
    | `WrongValidated -> "validated-other-value" in
  List.concat_map (fun kind ->
    List.concat_map (fun mistake ->
      let osuffix = Printf.sprintf "%s%s" (String.sub kind 0 1) (mtag mistake) in
      List.mapi (fun i p ->
        let suffix = Printf.sprintf "%s%d" osuffix i in
        let modname = Printf.sprintf "BPar%s" suffix in
        (* whether this mistake needs a check producer in scope *)
        let needs_check =
          match mistake with `Passthrough | `WrongValidated -> true | _ -> false in
        let pre, needs_call =
          match mistake with
          | `Raw -> "", "  " ^ p.call "raw" ^ "\n"
          | `Literal -> "", "  " ^ p.call (literal_of p.ty) ^ "\n"
          | `Expr ->
            if p.ty = "String"
            then "", "  " ^ p.call "(passthru raw)" ^ "\n"
            else "", "  " ^ p.call "(raw + 0)" ^ "\n"
          | `ForgotCheck ->
            (* binds raw to a name (a no-op `let`) but never validates *)
            "  let v = raw\n", "  " ^ p.call "v" ^ "\n"
          | `Passthrough ->
            (* validates, then launders through identity fn (drops proof) *)
            "  let v = check c raw\n  let w = id v\n", "  " ^ p.call "w" ^ "\n"
          | `WrongValidated ->
            (* validates `raw`, passes the OTHER (unproven) parameter *)
            "  let v = check c raw\n", "  " ^ p.call "other" ^ "\n"
        in
        let id_helper =
          if mistake = `Passthrough
          then Printf.sprintf "fn id(x: %s) -> %s = x\n" p.ty p.ty else "" in
        let expr_helper =
          if mistake = `Expr && p.ty = "String"
          then Printf.sprintf "fn passthru(x: %s) -> %s = x\n" p.ty p.ty else "" in
        (* WrongValidated needs a second unproven param `other` of the same type *)
        let consumer =
          match mistake with
          | `WrongValidated ->
            let body = pre ^ needs_call in
            (match kind with
             | "fn" -> Printf.sprintf "fn caller(raw: %s, other: %s) -> %s =\n%s\n" p.ty p.ty p.ty body
             | "handler" -> Printf.sprintf "handler caller(raw: %s, other: %s) -> %s requires [] =\n%s\n" p.ty p.ty p.ty body
             | "worker" -> Printf.sprintf "worker caller(raw: %s) requires [] =\n  let other = raw\n%s\n" p.ty body
             | _ -> assert false)
          | _ -> consumer_kind_src kind p.ty ~pre ~needs_call
        in
        let src =
          prelude modname
          ^ p.imports
          ^ p.decl ^ "\n"
          ^ (if needs_check then p.chk else "")
          ^ p.needs_decl
          ^ id_helper
          ^ expr_helper
          ^ consumer
        in
        let label = Printf.sprintf "B-PAR %s/%s/%s" kind (mlabel mistake) p.pname in
        let pat =
          unsat ^ "\\|requires proof.*literal\\|expression with no trackable subject"
        in
        test_case label `Quick (fun () -> should_fail pat src))
        (predicates osuffix))
      mistakes)
    kinds

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let () =
  run "ProofSuite-B-Consume" [
    "consume-raw", [
      test_case "B raw at proof position" `Quick test_B_raw_at_proof_pos;
      test_case "B never validated" `Quick test_B_never_validated;
      test_case "B proof param after arithmetic" `Quick test_B_proof_param_after_arith;
      test_case "B validated other value" `Quick test_B_validated_other_value;
      test_case "B string raw" `Quick test_B_string_raw;
      test_case "B two-arg raw" `Quick test_B_two_arg_raw;
      test_case "B literal-param raw" `Quick test_B_literal_param_raw;
    ];
    "consume-literal", [
      test_case "B literal direct" `Quick test_B_literal_direct;
      test_case "B literal bound then passed" `Quick test_B_literal_bound;
    ];
    "consume-no-subject", [
      test_case "B expression with no subject" `Quick test_B_expr_no_subject;
      test_case "B arithmetic expr no subject" `Quick test_B_arith_expr_no_subject;
    ];
    "consume-handler-worker", [
      test_case "B handler body consumes raw" `Quick test_B_handler_body_raw;
      test_case "B worker body consumes raw" `Quick test_B_worker_body_raw;
      test_case "B handler called from code rejected" `Quick test_B_handler_called_from_code;
    ];
    "consume-conjunction", [
      test_case "B conjunction partial proof" `Quick test_B_conjunction_partial;
    ];
    "consume-parameterized", consume_param_cases ();
    "consume-positive-sanity", [
      test_case "B+ validated flows to consumer" `Quick test_B_pos_validated_flows;
      test_case "B+ handler body validates" `Quick test_B_pos_handler_body_validates;
      test_case "B+ worker body validates" `Quick test_B_pos_worker_body_validates;
      test_case "B+ proof param passthrough" `Quick test_B_pos_proof_param_passthrough;
      test_case "B+ two-arg validated" `Quick test_B_pos_two_arg_validated;
      test_case "B+ literal-param validated" `Quick test_B_pos_literal_param_validated;
    ];
  ]
