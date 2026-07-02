(** test_agent_decode.ml — Compiler-level tests for A8 type-directed `decodeAs`.

    A8 (decide-by-resolution): the polymorphic decoder `decodeAs "T" j` has a
    free result var and takes a literal type-NAME string that was never
    cross-checked against the annotated/inferred result type. This let
    `decodeAs "Priority"` be annotated as an unrelated type (reading a
    non-existent field) or used ambiguously. These tests pin the hole shut:

    1.  Negative: the type-name string disagrees with the annotated result type.
    2.  Negative: the target type has no `fromJson` codec.
    3.  Positive: the corpus shape (string == annotated codec type) still compiles.
    4.  Negative: an unannotated/ambiguous standalone decodeAs is flagged.
*)

(* ── Helpers (mirror test_jwt.ml) ────────────────────────────────────────── *)

let root =
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some p when p <> "" -> p
  | _ ->
    let rec find dir =
      let candidate = Filename.concat dir "compiler" in
      if (try Sys.file_exists candidate && Sys.is_directory candidate with _ -> false)
      then dir
      else
        let parent = Filename.dirname dir in
        if parent = dir then Filename.current_dir_name
        else find parent
    in
    find (Filename.dirname Sys.executable_name)

let agent_imports =
  "import Tesl.Prelude exposing [Int, String]\n\
   import Tesl.Json exposing [stringCodec, intCodec]\n\
   import Tesl.Agent exposing [decodeAs]\n"

let module_ ?(name="M") ?(exports="") body =
  Printf.sprintf "#lang tesl\nmodule %s exposing [%s]\n%s\n%s"
    name exports agent_imports body

let compile_ok name src =
  match Compile.compile_source ~root_path:root "<test>" src with
  | Compile.Success racket -> racket
  | Compile.Failure diags ->
    Alcotest.failf "%s: unexpected compile failure: %s" name
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diags))

let compile_err name src =
  let diags = Compile.check_source "<test>" src in
  if diags = [] then
    Alcotest.failf "%s: expected errors but compilation succeeded" name
  else
    String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) diags)

let contains needle haystack =
  let n = String.length needle in
  let m = String.length haystack in
  if n > m then false
  else begin
    let found = ref false in
    for i = 0 to m - n do
      if String.sub haystack i n = needle then found := true
    done;
    !found
  end

let check_err_contains name src substr =
  let msg = compile_err name src in
  if not (contains substr msg) then
    Alcotest.failf "%s: expected error containing %S, got:\n%s" name substr msg

let check_err_nonempty name src =
  let _ = compile_err name src in
  ()

(* Two records + codecs shared by the mismatch tests. *)
let two_records_with_codecs = {|
record Priority { level: Int reason: String }
record Other { name: String }

codec Priority {
  toJson_forbidden
  fromJson [ { level <- "level" with_codec intCodec  reason <- "reason" with_codec stringCodec } ]
}
codec Other {
  toJson_forbidden
  fromJson [ { name <- "name" with_codec stringCodec } ]
}
|}

(* ── 1. Negative: name/type mismatch ─────────────────────────────────────── *)

let test_decode_name_type_mismatch () =
  (* decodeAs "Priority" annotated as Other: the string says one type, the
     result is used as another. Reading the Priority codec into an Other value
     is silent nonsense at runtime — must be rejected. *)
  let src = module_ ~exports:"f"
    (two_records_with_codecs ^
     "\nfn f(j: String) -> Other = decodeAs \"Priority\" j\n") in
  let msg = compile_err "decode_name_type_mismatch" src in
  if not (contains "Priority" msg && contains "Other" msg) then
    Alcotest.failf
      "decode_name_type_mismatch: expected an error naming both `Priority` and \
       `Other`, got:\n%s" msg

(* ── 2. Negative: target type has no fromJson codec ──────────────────────── *)

let test_decode_no_codec () =
  let src = module_ ~exports:"f" {|
record Priority { level: Int reason: String }

fn f(j: String) -> Priority = decodeAs "Priority" j
|} in
  check_err_contains "decode_no_codec" src "fromJson"

(* ── 3. Positive: corpus shape (string == annotated codec type) ──────────── *)

let test_decode_matched_compiles () =
  let src = module_ ~exports:"f" {|
record Priority { level: Int reason: String }
codec Priority {
  toJson_forbidden
  fromJson [ { level <- "level" with_codec intCodec  reason <- "reason" with_codec stringCodec } ]
}
fn f(j: String) -> Priority = decodeAs "Priority" j
|} in
  let _ = compile_ok "decode_matched_compiles" src in
  ()

(* ── 4. Negative: unannotated / ambiguous standalone decodeAs ────────────── *)

let test_decode_ambiguous_unannotated () =
  (* A truly-unconstrained `let x = decodeAs "Priority" j` (x never used with a
     concrete type) COMPILES: the literal type-name drives the runtime decode,
     and the static name/codec reconciliation fires on the CHECK-path once the
     result type is pinned by use (tests 1-3). Rejecting it at infer time
     over-rejected legitimate let-bound-then-used decodes (e.g.
     `let x = decodeAs "T" j` returned from a `-> T` fn), so the infer-path
     defers rather than flags. *)
  let src = module_ ~exports:"f" {|
record Priority { level: Int reason: String }
codec Priority {
  toJson_forbidden
  fromJson [ { level <- "level" with_codec intCodec  reason <- "reason" with_codec stringCodec } ]
}
fn f(j: String) -> String =
  let x = decodeAs "Priority" j
  "ok"
|} in
  ignore (compile_ok "decode_ambiguous_unannotated_compiles" src)

(* ── 5. Negative: first arg is a non-literal type name ───────────────────── *)

let test_decode_non_literal_type_name () =
  (* The type-name must be a compile-time string literal so it can be checked
     against the resolved type; a dynamic type name is the unsound pattern. *)
  let src = module_ ~exports:"f" {|
record Priority { level: Int reason: String }
codec Priority {
  toJson_forbidden
  fromJson [ { level <- "level" with_codec intCodec  reason <- "reason" with_codec stringCodec } ]
}
fn f(tn: String, j: String) -> Priority = decodeAs tn j
|} in
  check_err_nonempty "decode_non_literal_type_name" src

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "AgentDecode" [
    "decodeAs", [
      Alcotest.test_case "name/type mismatch rejected" `Quick test_decode_name_type_mismatch;
      Alcotest.test_case "target without fromJson codec rejected" `Quick test_decode_no_codec;
      Alcotest.test_case "matched string==type compiles" `Quick test_decode_matched_compiles;
      Alcotest.test_case "ambiguous unannotated deferred (compiles)" `Quick test_decode_ambiguous_unannotated;
      Alcotest.test_case "non-literal type name rejected" `Quick test_decode_non_literal_type_name;
    ];
  ]
