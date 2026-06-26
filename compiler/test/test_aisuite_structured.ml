(** AISuite family S — STRUCTURED OUTPUT safety (askFor / decodeAs + codec).

    NEGATIVE proof tests for the AI structured-output boundary: code that must
    NOT compile.  Tesl's `decodeAs "T" json` and `askFor agent prompt decoder
    maxRetries` turn untrusted MODEL output into a typed value.  The ONLY thing
    standing between a hallucinated JSON blob and business logic is the SAME
    codec/proof machinery used at the HTTP boundary: a proof-carrying decoder
    field must establish its proof through a `via` check, the `with_codec` must
    match the field type, a decoded ADT routed through a `case` must be handled
    exhaustively, and an UNVALIDATED decoded value may not reach a proof-carrying
    parameter.  If any of these slip, unvalidated model output reaches the
    domain.

    Families (all reject with `error[V001]` — never a runtime token):
      S-VIA   — a structured-output target whose proof-carrying decoder field has
                NO `via`, or a `via` establishing the WRONG proof.
      S-TYPE  — a structured-output target whose `with_codec` does not match the
                decoder field's type.
      S-FLOW  — an UNVALIDATED decoded value (or `.field`) fed to a proof-carrying
                fn — the proof obligation is not discharged.
      S-ADT   — a decoded ADT routed through a non-total / duplicate / unreachable
                `case` — exhaustiveness rejects it before any case body runs.
      S-CAP   — `askFor` / a fn transitively calling an AI verb, in a fn/test that
                does NOT grant `aiProvider` — capability gating rejects it.
      S-GAP   — KNOWN STATIC GAPS in `decodeAs` literal-type-name resolution
                (pinned `should_pass`; see notes).
      S-POS   — positive controls (a proper codec + decoder + downstream
                consumption) must compile.

    Hardening: a static rejection must NEVER leak a runtime token
    (`raise-user-error`, `check-fail`, a `.rkt` trace, `raco`).  `should_fail`
    asserts this — structured-output rejection is STATIC, before any emit.

    Register in compiler/test/dune is the INTEGRATOR's job. *)

open Alcotest

(* ── Compiler discovery (mirrors test_proofsuite_codec.ml) ───────────────── *)

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

(* The compiler rejects a module header that does not match the file name, so
   the temp file MUST be named the kebab-case of the `module` header. *)
let file_name_of_src content =
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

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-aiS" "" in
  let path = Filename.concat dir (file_name_of_src content) in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

(* Hardening: a static rejection must not leak a runtime token. *)
let leak_markers = [
  "raise-user-error"; "check-fail"; "context...:"; "context ...:";
  ".rkt:"; "racket/"; "/collects/"; "errortrace"; "uncaught exception"; "raco ";
]

let assert_no_runtime_leak ~ctx out =
  List.iter (fun m ->
    let re = Str.regexp_string m in
    if (try ignore (Str.search_forward re out 0); true with Not_found -> false)
    then failf "%s: STATIC-REJECTION VIOLATED: output contains runtime-leak \
                marker %S:\n%s" ctx m out)
    leak_markers

let should_fail ?(label = "") pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    let ctx = if label = "" then "should_fail" else label in
    assert_no_runtime_leak ~ctx out;
    if code = 0 then
      failf "%s: expected static failure matching %S, but COMPILED.\nsrc:\n%s" ctx pat src;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "%s: expected failure matching %S, got:\n%s" ctx pat out)

let should_pass ?(label = "") src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    let ctx = if label = "" then "should_pass" else label in
    let has_err =
      let re = Str.regexp "error\\[" in
      try ignore (Str.search_forward re out 0); true with Not_found -> false in
    if code <> 0 || has_err then
      failf "%s: expected COMPILE, but failed (exit %d):\n%s" ctx code out)

(* sanitise a string into a valid PascalCase-ish module-name fragment. *)
let modfrag s =
  String.map (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
    then c else 'X') s

(* ════════════════════════════════════════════════════════════════════════
   Matrix axes.
   ════════════════════════════════════════════════════════════════════════ *)

(* A scalar field type + the matching builtin codec + a check skeleton.  Each
   `mk_check` produces a `check` whose subject is `s` and which establishes the
   named predicate over field type `ty`. *)
type scalar = {
  ty       : string;   (* "String" | "Int" *)
  prelude  : string;   (* prelude import list fragment *)
  codec    : string;   (* matching builtin codec *)
  bad_codec: string;   (* a builtin codec that does NOT match `ty` *)
  cond     : string;   (* a boolean condition over subject `s` *)
}

let scalars = [
  { ty = "String"; prelude = "String"; codec = "stringCodec"; bad_codec = "intCodec";
    cond = "String.length s > 0" };
  { ty = "Int"; prelude = "Int, String"; codec = "intCodec"; bad_codec = "stringCodec";
    cond = "s > 0" };
]

(* Distinct predicate names so a "wrong via" can establish a DIFFERENT predicate
   over the same type. *)
let predicates =
  [ "ValidName"; "ValidLabel"; "Vetted"; "Trusted"; "Sanitised"; "Approved";
    "NonEmpty"; "Bounded"; "Whitelisted"; "Canonical" ]

(* The String.length import is only needed for String conditions. *)
let length_import sc = if sc.ty = "String" then "import Tesl.String exposing [String.length]\n" else ""

(* Build a `check` that establishes `pred s` over scalar `sc`. *)
let check_block sc pred name =
  Printf.sprintf
    "check %s(s: %s) -> s: %s ::: %s s =\n  if %s then\n    ok s ::: %s s\n  else\n    fail 400 \"bad\"\n"
    name sc.ty sc.ty pred sc.cond pred

(* ════════════════════════════════════════════════════════════════════════
   S-VIA — structured-output target: proof-carrying decoder field, NO via.
   matrix: scalars × predicates.
   ════════════════════════════════════════════════════════════════════════ *)

let via_no_pat =
  "requires proof predicates\\|has no .via. validation\\|V001"

let via_wrong_pat =
  "not established by any .via.\\|requires proof predicates\\|V001"

let s_via_missing sc pred =
  let modn = "SViaMiss" ^ modfrag sc.ty ^ modfrag pred in
  Printf.sprintf {|#lang tesl
module %s exposing []
import Tesl.Prelude exposing [%s]
import Tesl.Json exposing [%s]
import Tesl.Agent exposing [decodeAs]
fact %s (s: %s)
record Out { f: %s ::: %s f }
codec Out {
  toJson_forbidden
  fromJson [ { f <- "f" with_codec %s } ]
}
fn decodeOut(j: String) -> Out = decodeAs "Out" j
|}
    modn sc.prelude sc.codec pred sc.ty sc.ty pred sc.codec

let s_via_wrong sc pred =
  (* declare predicate `pred` on the field, but the only `via` check establishes
     a DIFFERENT predicate `Other` over the same type. *)
  let modn = "SViaWrong" ^ modfrag sc.ty ^ modfrag pred in
  let other = "Other" in
  Printf.sprintf {|#lang tesl
module %s exposing []
import Tesl.Prelude exposing [%s]
import Tesl.Json exposing [%s]
%simport Tesl.Agent exposing [decodeAs]
fact %s (s: %s)
fact %s (s: %s)
%srecord Out { f: %s ::: %s f }
codec Out {
  toJson_forbidden
  fromJson [ { f <- "f" with_codec %s via checkOther } ]
}
fn decodeOut(j: String) -> Out = decodeAs "Out" j
|}
    modn sc.prelude sc.codec (length_import sc) pred sc.ty other sc.ty
    (check_block sc other "checkOther") sc.ty pred sc.codec

(* two proof-carrying decoder fields, only ONE given a `via` — the other must be
   flagged.  `which` selects whether field `a` or field `b` keeps its via. *)
let s_via_partial sc pa pb ~give_a =
  let modn = Printf.sprintf "SViaPart%s%s%s%s"
      (modfrag sc.ty) (modfrag pa) (modfrag pb) (if give_a then "A" else "B") in
  let via_a = if give_a then " via checkA" else "" in
  let via_b = if give_a then "" else " via checkB" in
  Printf.sprintf {|#lang tesl
module %s exposing []
import Tesl.Prelude exposing [%s]
import Tesl.Json exposing [%s]
%simport Tesl.Agent exposing [decodeAs]
fact %s (s: %s)
fact %s (s: %s)
%s%srecord Out { a: %s ::: %s a, b: %s ::: %s b }
codec Out {
  toJson_forbidden
  fromJson [
    {
      a <- "a" with_codec %s%s
      b <- "b" with_codec %s%s
    }
  ]
}
fn decodeOut(j: String) -> Out = decodeAs "Out" j
|}
    modn sc.prelude sc.codec (length_import sc)
    pa sc.ty pb sc.ty
    (check_block sc pa "checkA") (check_block sc pb "checkB")
    sc.ty pa sc.ty pb
    sc.codec via_a sc.codec via_b

let s_via_matrix () =
  let single =
    List.concat_map (fun sc ->
      List.concat_map (fun pred ->
        [ test_case (Printf.sprintf "S-VIA missing %s/%s" sc.ty pred) `Quick
            (fun () -> should_fail ~label:"S-VIA missing" via_no_pat (s_via_missing sc pred));
          test_case (Printf.sprintf "S-VIA wrong %s/%s" sc.ty pred) `Quick
            (fun () -> should_fail ~label:"S-VIA wrong" via_wrong_pat (s_via_wrong sc pred)) ]
      ) predicates
    ) scalars
  in
  (* predicate PAIRS for the two-field sweep (distinct names). *)
  let pairs = [ ("ValidName","ValidLabel"); ("Vetted","Trusted");
                ("Sanitised","Approved"); ("NonEmpty","Bounded");
                ("Whitelisted","Canonical") ] in
  let partial =
    List.concat_map (fun sc ->
      List.concat_map (fun (pa, pb) ->
        [ test_case (Printf.sprintf "S-VIA partial give-a %s/%s+%s" sc.ty pa pb) `Quick
            (fun () -> should_fail ~label:"S-VIA partial a" via_no_pat (s_via_partial sc pa pb ~give_a:true));
          test_case (Printf.sprintf "S-VIA partial give-b %s/%s+%s" sc.ty pa pb) `Quick
            (fun () -> should_fail ~label:"S-VIA partial b" via_no_pat (s_via_partial sc pa pb ~give_a:false)) ]
      ) pairs
    ) scalars
  in
  single @ partial

(* ════════════════════════════════════════════════════════════════════════
   S-TYPE — structured-output target: with_codec ≠ decoder field type.
   matrix: scalars (intCodec on String / stringCodec on Int), encode + decode.
   ════════════════════════════════════════════════════════════════════════ *)

let type_pat = "has type.*but.*\\(encodes\\|decodes\\)\\|matching codec\\|V001"

let s_type_decode sc =
  let modn = "STypeDec" ^ modfrag sc.ty ^ modfrag sc.bad_codec in
  Printf.sprintf {|#lang tesl
module %s exposing []
import Tesl.Prelude exposing [%s]
import Tesl.Json exposing [%s]
import Tesl.Agent exposing [decodeAs]
record Out { f: %s }
codec Out {
  toJson_forbidden
  fromJson [ { f <- "f" with_codec %s } ]
}
fn decodeOut(j: String) -> Out = decodeAs "Out" j
|}
    modn sc.prelude sc.bad_codec sc.ty sc.bad_codec

let s_type_encode sc =
  let modn = "STypeEnc" ^ modfrag sc.ty ^ modfrag sc.bad_codec in
  Printf.sprintf {|#lang tesl
module %s exposing []
import Tesl.Prelude exposing [%s]
import Tesl.Json exposing [%s]
import Tesl.Agent exposing [decodeAs]
record Out { f: %s }
codec Out {
  toJson {
    f -> "f" with_codec %s
  }
  fromJson_forbidden
}
fn decodeOut(j: String) -> Out = decodeAs "Out" j
|}
    modn sc.prelude sc.bad_codec sc.ty sc.bad_codec

let s_type_matrix () =
  List.concat_map (fun sc ->
    [ test_case (Printf.sprintf "S-TYPE decode %s/%s" sc.bad_codec sc.ty) `Quick
        (fun () -> should_fail ~label:"S-TYPE decode" type_pat (s_type_decode sc));
      test_case (Printf.sprintf "S-TYPE encode %s/%s" sc.bad_codec sc.ty) `Quick
        (fun () -> should_fail ~label:"S-TYPE encode" type_pat (s_type_encode sc)) ]
  ) scalars

(* ════════════════════════════════════════════════════════════════════════
   S-FLOW — an UNVALIDATED decoded value reaching a proof-carrying fn param.
   The decoder field carries NO proof (plain record, codec compiles), the value
   is decoded, then a `.field` (or the bound var's field) is passed to a fn
   requiring a proof over it — the obligation is not discharged.
   matrix: scalars × predicates × {direct-expr, let-bound}.
   ════════════════════════════════════════════════════════════════════════ *)

let flow_pat =
  "requires proof\\|does not statically satisfy declared proof\\|no trackable subject\\|V001"

(* direct: `business (decodeAs ...).f` — expression has no trackable subject. *)
let s_flow_direct sc pred =
  let modn = "SFlowDir" ^ modfrag sc.ty ^ modfrag pred in
  Printf.sprintf {|#lang tesl
module %s exposing []
import Tesl.Prelude exposing [%s]
import Tesl.Json exposing [%s]
import Tesl.Agent exposing [decodeAs]
fact %s (s: %s)
record Out { f: %s }
codec Out {
  toJson_forbidden
  fromJson [ { f <- "f" with_codec %s } ]
}
fn business(s: %s ::: %s s) -> %s = s
fn handle(j: String) -> %s =
  business (decodeAs "Out" j).f
|}
    modn sc.prelude sc.codec pred sc.ty sc.ty sc.codec sc.ty pred sc.ty sc.ty

(* let-bound: `let v = decodeAs ...  business v.f` — `v.f` lacks the proof. *)
let s_flow_let sc pred =
  let modn = "SFlowLet" ^ modfrag sc.ty ^ modfrag pred in
  Printf.sprintf {|#lang tesl
module %s exposing []
import Tesl.Prelude exposing [%s]
import Tesl.Json exposing [%s]
import Tesl.Agent exposing [decodeAs]
fact %s (s: %s)
record Out { f: %s }
codec Out {
  toJson_forbidden
  fromJson [ { f <- "f" with_codec %s } ]
}
fn business(s: %s ::: %s s) -> %s = s
fn handle(j: String) -> %s =
  let v = decodeAs "Out" j
  business v.f
|}
    modn sc.prelude sc.codec pred sc.ty sc.ty sc.codec sc.ty pred sc.ty sc.ty

(* tool-dispatch: the decoded value is the dispatch fn's typed arg, and a `.field`
   of it (no proof) is passed to a proof-carrying business fn — the SAME boundary
   a tool's dispatchFn crosses when handed validated args. *)
let s_flow_dispatch sc pred =
  let modn = "SFlowDisp" ^ modfrag sc.ty ^ modfrag pred in
  Printf.sprintf {|#lang tesl
module %s exposing []
import Tesl.Prelude exposing [%s]
import Tesl.Json exposing [%s]
import Tesl.Agent exposing [decodeAs, tool]
fact %s (s: %s)
record Args { f: %s }
codec Args {
  toJson_forbidden
  fromJson [ { f <- "f" with_codec %s } ]
}
fn business(s: %s ::: %s s) -> %s = s
fn validateArgs(j: String) -> Args = decodeAs "Args" j
fn dispatch(a: Args) -> %s = business a.f
|}
    modn sc.prelude sc.codec pred sc.ty sc.ty sc.codec sc.ty pred sc.ty sc.ty

let s_flow_matrix () =
  List.concat_map (fun sc ->
    List.concat_map (fun pred ->
      [ test_case (Printf.sprintf "S-FLOW direct %s/%s" sc.ty pred) `Quick
          (fun () -> should_fail ~label:"S-FLOW direct" flow_pat (s_flow_direct sc pred));
        test_case (Printf.sprintf "S-FLOW let %s/%s" sc.ty pred) `Quick
          (fun () -> should_fail ~label:"S-FLOW let" flow_pat (s_flow_let sc pred));
        test_case (Printf.sprintf "S-FLOW dispatch %s/%s" sc.ty pred) `Quick
          (fun () -> should_fail ~label:"S-FLOW dispatch" flow_pat (s_flow_dispatch sc pred)) ]
    ) predicates
  ) scalars

(* ════════════════════════════════════════════════════════════════════════
   S-ADT — a decoded ADT routed through a non-total / duplicate / unreachable
   `case`.  The model can produce ANY constructor, so an unhandled case is an
   unhandled hallucination path — exhaustiveness must reject it.
   matrix: ADTs × {missing each ctor} ; plus duplicate + unreachable.
   ════════════════════════════════════════════════════════════════════════ *)

(* (type name, ctor list) — nullary-only ADTs decoded via adtJson. *)
let adts = [
  ("Intent", [ "Refund"; "Cancel"; "Question" ]);
  ("Sentiment", [ "Pos"; "Neg"; "Neutral" ]);
  ("Priority", [ "Low"; "Medium"; "High"; "Urgent" ]);
  ("Category", [ "Billing"; "Tech"; "Sales"; "Other"; "Spam" ]);
  ("Verdict", [ "Allow"; "Deny" ]);
  ("Tier", [ "Free"; "Pro"; "Team"; "Enterprise"; "Trial"; "Legacy" ]);
  ("Stance", [ "For"; "Against"; "Abstain" ]);
  ("Severity", [ "Info"; "Warn"; "Error"; "Fatal" ]);
  ("Channel", [ "Email"; "Sms"; "Push"; "Webhook"; "Slack" ]);
  ("Outcome", [ "Win"; "Loss"; "Draw" ]);
  ("Action", [ "Create"; "Read"; "Update"; "Delete"; "List"; "Patch" ]);
]

let adt_decl tyname ctors =
  let body = ctors
    |> List.mapi (fun i c -> Printf.sprintf "  %s %s" (if i = 0 then "=" else "|") c)
    |> String.concat "\n" in
  Printf.sprintf "type %s\n%s\n" tyname body

(* a case body covering every ctor except [missing]. *)
let cover_except ctors missing =
  ctors
  |> List.filter (fun c -> c <> missing)
  |> List.map (fun c -> Printf.sprintf "    %s -> \"%s\"" c (String.lowercase_ascii c))
  |> String.concat "\n"

let s_adt_missing tyname ctors missing =
  let modn = "SAdtMiss" ^ modfrag tyname ^ modfrag missing in
  Printf.sprintf {|#lang tesl
module %s exposing []
import Tesl.Prelude exposing [String]
import Tesl.Agent exposing [decodeAs]
%scodec %s { adtJson }
fn route(x: %s) -> String =
  case x of
%s
fn classify(j: String) -> String = route (decodeAs "%s" j)
|}
    modn (adt_decl tyname ctors) tyname tyname (cover_except ctors missing) tyname

let s_adt_dup tyname ctors =
  let modn = "SAdtDup" ^ modfrag tyname in
  let arms =
    (match ctors with
     | first :: _ ->
       (* duplicate the first ctor, then cover the rest *)
       let dup = Printf.sprintf "    %s -> \"a\"\n    %s -> \"again\"" first first in
       let rest = List.tl ctors
         |> List.map (fun c -> Printf.sprintf "    %s -> \"%s\"" c (String.lowercase_ascii c))
         |> String.concat "\n" in
       if rest = "" then dup else dup ^ "\n" ^ rest
     | [] -> "") in
  Printf.sprintf {|#lang tesl
module %s exposing []
import Tesl.Prelude exposing [String]
import Tesl.Agent exposing [decodeAs]
%scodec %s { adtJson }
fn route(x: %s) -> String =
  case x of
%s
fn classify(j: String) -> String = route (decodeAs "%s" j)
|}
    modn (adt_decl tyname ctors) tyname tyname arms tyname

let s_adt_unreachable tyname ctors =
  (* a catch-all `_` arm BEFORE the last ctor makes the last arm unreachable. *)
  let modn = "SAdtUnreach" ^ modfrag tyname in
  let arms =
    (match List.rev ctors with
     | last :: _ ->
       (* cover all-but-last, then catch-all, then last (unreachable). *)
       let allbut = ctors |> List.filter (fun c -> c <> last)
         |> List.map (fun c -> Printf.sprintf "    %s -> \"%s\"" c (String.lowercase_ascii c))
         |> String.concat "\n" in
       Printf.sprintf "%s\n    _ -> \"other\"\n    %s -> \"last\"" allbut last
     | [] -> "") in
  Printf.sprintf {|#lang tesl
module %s exposing []
import Tesl.Prelude exposing [String]
import Tesl.Agent exposing [decodeAs]
%scodec %s { adtJson }
fn route(x: %s) -> String =
  case x of
%s
fn classify(j: String) -> String = route (decodeAs "%s" j)
|}
    modn (adt_decl tyname ctors) tyname tyname arms tyname

let s_adt_matrix () =
  List.concat_map (fun (tyname, ctors) ->
    let missing =
      List.map (fun m ->
        test_case (Printf.sprintf "S-ADT %s missing %s" tyname m) `Quick
          (fun () -> should_fail ~label:"S-ADT missing"
              (Printf.sprintf "non-exhaustive case: missing constructor.*%s" m)
              (s_adt_missing tyname ctors m)))
        ctors in
    let dup =
      test_case (Printf.sprintf "S-ADT %s duplicate arm" tyname) `Quick
        (fun () -> should_fail ~label:"S-ADT dup"
            "duplicate case arm\\|already covered\\|V001"
            (s_adt_dup tyname ctors)) in
    let unreach =
      test_case (Printf.sprintf "S-ADT %s unreachable arm" tyname) `Quick
        (fun () -> should_fail ~label:"S-ADT unreach"
            "unreachable case arm\\|catch-all\\|V001"
            (s_adt_unreachable tyname ctors)) in
    missing @ [ dup; unreach ]
  ) adts

(* ════════════════════════════════════════════════════════════════════════
   S-CAP — capability gating: an AI verb (or a fn transitively calling one) in a
   fn/test that does NOT grant `aiProvider` is rejected.
   matrix: AI verbs × call sites.
   ════════════════════════════════════════════════════════════════════════ *)

let cap_pat = "aiProvider\\|requires.*\\[\\|privileged operations\\|V001"

(* Each entry is a fragment of a fn body that invokes an AI verb on a built
   agent, plus the imports it needs.  All share the same provider/decoder
   scaffold. *)
type cap_case = { name : string; imports : string; body : string; ret : string;
                  extra_decl : string }

let cap_scaffold_imports =
  "import Tesl.Agent exposing [defineAgent, mockProvider, ask, askReply, askFor, decodeAs, converse, newConversation, agentRun, replyText]"

let cap_cases = [
  { name = "ask"; imports = ""; ret = "String"; extra_decl = "";
    body = "  let agent = defineAgent (mockProvider [\"x\"]) \"x\" 64\n  ask agent \"hi\"" };
  { name = "askReply"; imports = ""; ret = "String"; extra_decl = "";
    body = "  let agent = defineAgent (mockProvider [\"x\"]) \"x\" 64\n  let r = askReply agent \"hi\"\n  replyText r" };
  { name = "askFor"; imports = ""; ret = "Out"; extra_decl =
      "record Out { f: String }\ncodec Out {\n  toJson_forbidden\n  fromJson [ { f <- \"f\" with_codec stringCodec } ]\n}\nfn decodeOut(j: String) -> Out = decodeAs \"Out\" j\n";
    body = "  let agent = defineAgent (mockProvider [\"{\\\"f\\\":\\\"x\\\"}\"]) \"x\" 64\n  askFor agent \"go\" decodeOut 2" };
  { name = "converse"; imports = ""; ret = "String"; extra_decl = "";
    body = "  let agent = defineAgent (mockProvider [\"x\"]) \"x\" 64\n  let c = newConversation agent\n  let _ = converse c \"hi\"\n  \"done\"" };
]

(* (a) the AI verb used directly in a fn with NO `requires`. *)
let s_cap_direct cc =
  let modn = "SCapDir" ^ modfrag cc.name in
  Printf.sprintf {|#lang tesl
module %s exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec]
%s
%sfn go() -> %s =
%s
|}
    modn cap_scaffold_imports cc.extra_decl cc.ret cc.body

(* (b) an AI verb wrapped in a fn that DOES grant aiProvider, then called from a
   fn that does NOT propagate the capability — gating must reject the caller. *)
let s_cap_transitive cc =
  let modn = "SCapTrans" ^ modfrag cc.name in
  Printf.sprintf {|#lang tesl
module %s exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec]
%s
%sfn inner() -> %s requires [aiProvider] =
%s
fn outer() -> %s = inner
|}
    modn cap_scaffold_imports cc.extra_decl cc.ret cc.body cc.ret

let s_cap_matrix () =
  List.concat_map (fun cc ->
    [ test_case (Printf.sprintf "S-CAP direct %s no aiProvider" cc.name) `Quick
        (fun () -> should_fail ~label:"S-CAP direct" cap_pat (s_cap_direct cc));
      test_case (Printf.sprintf "S-CAP transitive %s caller drops cap" cc.name) `Quick
        (fun () -> should_fail ~label:"S-CAP transitive" cap_pat (s_cap_transitive cc)) ]
  ) cap_cases

(* ════════════════════════════════════════════════════════════════════════
   S-GAP — KNOWN STATIC GAPS in `decodeAs` literal-type-name resolution.

   The `decodeAs` builtin is typed `String -> String -> _a` (type_system.ml:539)
   — fully polymorphic in its result.  The literal type-name STRING argument is
   NOT statically reconciled with:
     (1) the existence of a type/codec of that name, nor
     (2) the inferred result type.
   So `decodeAs "Nonexistent" j`, `decodeAs "WeatherArgs" j` returned where a
   `Summary` is expected, and `decodeAs "T" j` where `T` has NO codec at all,
   ALL COMPILE today.  An attacker who controls the type-name string (or a typo)
   can summon a decode the codec registry never validated.  These SHOULD be
   rejected (a `decodeAs "T"` should require: T exists, T has a fromJson codec,
   and T unifies with the result type).  Pinned `should_pass` so the suite stays
   green; flip to `should_fail` when the checker reconciles decodeAs type names.
   Reported to ZC-FINALIZE.
   ════════════════════════════════════════════════════════════════════════ *)

let s_gap_nonexistent_type () =
  should_pass ~label:"S-GAP decodeAs nonexistent type (KNOWN GAP)" {|
#lang tesl
module SGapNonexistent exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec, intCodec]
import Tesl.Agent exposing [decodeAs]
record Summary { title: String, score: Int }
codec Summary {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec
      score <- "score" with_codec intCodec
    }
  ]
}
fn decodeSummary(j: String) -> Summary = decodeAs "Nonexistent" j
|}

let s_gap_type_name_mismatch () =
  should_pass ~label:"S-GAP decodeAs name != result type (KNOWN GAP)" {|
#lang tesl
module SGapMismatch exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec, intCodec]
import Tesl.Agent exposing [decodeAs]
record Summary { title: String, score: Int }
codec Summary {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec
      score <- "score" with_codec intCodec
    }
  ]
}
record WeatherArgs { city: String }
codec WeatherArgs {
  toJson_forbidden
  fromJson [ { city <- "city" with_codec stringCodec } ]
}
fn decodeSummary(j: String) -> Summary = decodeAs "WeatherArgs" j
|}

let s_gap_no_codec_target () =
  should_pass ~label:"S-GAP decodeAs target has NO codec (KNOWN GAP)" {|
#lang tesl
module SGapNoCodec exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Agent exposing [decodeAs]
record Summary { title: String, score: Int }
fn decodeSummary(j: String) -> Summary = decodeAs "Summary" j
|}

(* ════════════════════════════════════════════════════════════════════════
   S-POS — positive controls (must compile).
   ════════════════════════════════════════════════════════════════════════ *)

let pos_decoder_full () =
  should_pass ~label:"S-POS proper codec + decoder" {|
#lang tesl
module PosSFull exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec, intCodec]
import Tesl.Agent exposing [decodeAs]
record Summary { title: String, score: Int }
codec Summary {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec
      score <- "score" with_codec intCodec
    }
  ]
}
fn decodeSummary(j: String) -> Summary = decodeAs "Summary" j
|}

let pos_via_flow_downstream () =
  should_pass ~label:"S-POS via establishes proof consumed downstream" {|
#lang tesl
module PosSFlow exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
import Tesl.String exposing [String.length]
import Tesl.Agent exposing [decodeAs]
fact ValidName (s: String)
check checkName(s: String) -> s: String ::: ValidName s =
  if String.length s > 0 then
    ok s ::: ValidName s
  else
    fail 400 "empty"
record Out { f: String ::: ValidName f }
codec Out {
  toJson_forbidden
  fromJson [ { f <- "f" with_codec stringCodec via checkName } ]
}
fn business(s: String ::: ValidName s) -> String = s
fn handle(j: String) -> String =
  let v = decodeAs "Out" j
  business v.f
|}

let pos_adt_total () =
  should_pass ~label:"S-POS decoded ADT routed through a total case" {|
#lang tesl
module PosSAdt exposing []
import Tesl.Prelude exposing [String]
import Tesl.Agent exposing [decodeAs]
type Intent
  = Refund
  | Cancel
  | Question
codec Intent { adtJson }
fn route(x: Intent) -> String =
  case x of
    Refund -> "refund"
    Cancel -> "cancel"
    Question -> "question"
fn classify(j: String) -> String = route (decodeAs "Intent" j)
|}

let pos_askfor_with_cap () =
  should_pass ~label:"S-POS askFor under aiProvider capability" {|
#lang tesl
module PosSAskFor exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec, intCodec]
import Tesl.Agent exposing [aiProvider, decodeAs, askFor, defineAgent, mockProvider]
capability supportBot implies aiProvider
record Summary { title: String, score: Int }
codec Summary {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec
      score <- "score" with_codec intCodec
    }
  ]
}
fn decodeSummary(j: String) -> Summary = decodeAs "Summary" j
fn go() -> Summary requires [supportBot] =
  let agent = defineAgent (mockProvider ["{\"title\":\"ok\",\"score\":1}"]) "x" 64
  askFor agent "summarize" decodeSummary 2
|}

let pos_cross_field_via () =
  should_pass ~label:"S-POS cross-field via on a structured-output codec" {|
#lang tesl
module PosSCross exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [intCodec]
import Tesl.Agent exposing [decodeAs]
fact IsPositive (n: Int)
check checkPositiveInt(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "neg"
fact PriceExceedsQuantity (price: Int, quantity: Int)
check checkPriceExceedsQuantity(price: Int, quantity: Int) -> price: Int ::: PriceExceedsQuantity price quantity =
  if price > quantity then
    ok price ::: PriceExceedsQuantity price quantity
  else
    fail 400 "no"
record OrderLine {
  price: Int ::: IsPositive price
  quantity: Int ::: IsPositive quantity
} ::: PriceExceedsQuantity price quantity
codec OrderLine {
  toJson_forbidden
  fromJson [
    {
      price <- "price" with_codec intCodec via checkPositiveInt
      quantity <- "quantity" with_codec intCodec via checkPositiveInt
    } via checkPriceExceedsQuantity
  ]
}
fn decodeOrderLine(j: String) -> OrderLine = decodeAs "OrderLine" j
|}

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let () =
  run "AISuite-S-Structured" [
    "S-VIA decoder proof coverage (scalars × predicates)", s_via_matrix ();
    "S-TYPE with_codec type mismatch (scalars, enc+dec)", s_type_matrix ();
    "S-FLOW unvalidated decoded value → proof param", s_flow_matrix ();
    "S-ADT decoded ADT exhaustiveness", s_adt_matrix ();
    "S-CAP aiProvider capability gating (verbs × sites)", s_cap_matrix ();
    "S-GAP decodeAs type-name resolution (KNOWN GAPS, pinned)", [
      test_case "decodeAs to nonexistent type name (KNOWN GAP)" `Quick s_gap_nonexistent_type;
      test_case "decodeAs name != result type (KNOWN GAP)" `Quick s_gap_type_name_mismatch;
      test_case "decodeAs target has no codec (KNOWN GAP)" `Quick s_gap_no_codec_target;
    ];
    "S-POS positive controls", [
      test_case "proper codec + decoder compiles" `Quick pos_decoder_full;
      test_case "via proof consumed downstream compiles" `Quick pos_via_flow_downstream;
      test_case "decoded ADT total case compiles" `Quick pos_adt_total;
      test_case "askFor under aiProvider compiles" `Quick pos_askfor_with_cap;
      test_case "cross-field via codec compiles" `Quick pos_cross_field_via;
    ];
  ]
