(** GitHub issues #70 and #71 — two "check passes, the module is still broken"
    traps around ADT types in proof/api positions.

    #70 — a `fact` INDEXED BY AN ADT CONSTRUCTOR
    ------------------------------------------------------------------------
    `fact MayUse (c: Caller) (p: Permission)` demanded as
    `MayUse c WriteCostRates` passed `tesl check` and then trapped during
    code generation with an unbound proof-template name.

    Root cause was kernel-vs-frontend DRIFT about what an uppercase-initial
    proof argument means.  The frontend has always read it as a CONSTANT (both
    [Proof_checker.proof_subjects] and [Validation_common.proof_subjects] keep
    only lowercase-initial args as GDP subjects — and the Tesl lexer makes that
    exhaustive, since an uppercase-initial VALUE name is a parse error).  The
    The removed runtime instead read every symbol as a GDP name, so the
    constructor looked unbound.

    The kernel now shares the frontend's rule, and this pass owns what the
    kernel's guard used to catch by accident: a constructor argument must
    actually name a constructor of the ADT the fact declares at that position
    ([Validation_capabilities.check_fact_arg_types]).  Both directions are
    pinned below, because "make it compile" without the second half would have
    turned a codegen trap into a SILENT hole (`MayUse c Bogus` compiling and
    testing green).

    #71 — a same-module SUM TYPE as an api `auth` binding
    ------------------------------------------------------------------------
    `auth c: Simple ::: Authenticated c via resolveCaller` inside an `api` block
    failed with `unknown type: Simple` when `type Simple = VariantA | VariantB`
    was declared in the SAME module — while the identical annotation checked
    fine on the `auth` function's own signature and on the handler parameter,
    and while moving the type to another module made it compile and serve.

    Root cause: [Checker.check_api_decl_types] built its known-type list from
    records + CONSTRUCTORS + env + imports, never from the ADT/alias tables.  A
    newtype (`type UserId = String`) or a single-variant ADT
    (`type Wrapper = Wrapper String`) slipped through only by the name
    coincidence ctor≡type; a plain multi-variant sum has no such coincidence and
    was rejected. *)

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
  let code = match Unix.close_process_in ic with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n in
  (code, out)

let failf fmt = Printf.ksprintf failwith fmt

let rec mkdir_p path =
  if path = "" || path = Filename.current_dir_name || Sys.file_exists path then ()
  else (mkdir_p (Filename.dirname path); Unix.mkdir path 0o755)

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else Sys.remove path

let build_go_artifacts label artifacts =
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-i7071-go" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      List.iter (fun (a : Emit_go.artifact) ->
        let path = Filename.concat root a.path in
        mkdir_p (Filename.dirname path);
        Out_channel.with_open_bin path (fun oc -> output_string oc a.contents)) artifacts;
      let command = Printf.sprintf "cd %s && go build ./... 2>&1" (Filename.quote root) in
      let ic = Unix.open_process_in command in
      let out = In_channel.input_all ic in
      match Unix.close_process_in ic with
      | Unix.WEXITED 0 -> ()
      | Unix.WEXITED code -> failf "%s: generated Go build exited %d:\n%s" label code out
      | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
        failf "%s: generated Go build stopped by signal %d:\n%s" label signal out)
  end

let contains hay needle =
  let n = String.length needle and h = String.length hay in
  let rec go i = i + n <= h && (String.sub hay i n = needle || go (i + 1)) in
  n = 0 || go 0

(* Write [files] (basename → source) into a fresh directory and run one compiler
   invocation over [entry].  Module headers must match file names (V001), so the
   basenames carry meaning. *)
let with_project files entry args =
  let dir = Filename.temp_dir "tesl-i7071" "" in
  List.iter (fun (name, src) ->
    let oc = open_out (Filename.concat dir name) in
    output_string oc src; close_out oc)
    files;
  let result = run_compiler (args @ [ Filename.concat dir entry ]) in
  List.iter (fun (name, _) ->
    try Sys.remove (Filename.concat dir name) with _ -> ())
    files;
  (try Unix.rmdir dir with _ -> ());
  result

let check_one src = with_project [ ("app.tesl", src) ] "app.tesl" [ "--check" ]
let emit_one src =
  match Compile.compile_go_source "app.tesl" src with
  | Compile.GoSuccess artifacts ->
    (0, String.concat "\n" (List.map (fun (a : Emit_go.artifact) -> a.contents) artifacts))
  | Compile.GoFailure diagnostics ->
    (1, String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))

(* ── #70 fixtures ───────────────────────────────────────────────────────── *)

(* [demanded] is the second proof argument written everywhere the fact appears. *)
let adt_fact_app demanded =
  Printf.sprintf {|module App exposing []
import Tesl.Prelude exposing [String, Bool(..), List]
import Tesl.List exposing [List.member]

type Permission
  = WriteCostRates
  | ReadProjects

type Colour
  = Red
  | Green

record Caller {
  granted: List Permission
}

fact MayUse (c: Caller) (p: Permission)

check mayWriteCostRates(c: Caller) -> c: Caller ::: MayUse c %s =
  if List.member WriteCostRates c.granted then
    ok c ::: MayUse c %s
  else
    fail 403 "missing permission write:cost-rates"

fn writeCostRatesCore(c: Caller ::: MayUse c %s) -> String =
  "wrote cost rates"
|} demanded demanded demanded

let t_adt_indexed_fact_checks () =
  let code, out = check_one (adt_fact_app "WriteCostRates") in
  if code <> 0 then
    failf "a fact indexed by an ADT constructor must check cleanly; got (exit %d):\n%s"
      code out

(* The actual #70 trap: check-clean source must also reach Go emission. Proofs
   erase in Go, so successful artifact production is the relevant assertion. *)
let t_adt_indexed_fact_emits_the_constructor () =
  let code, out = emit_one (adt_fact_app "WriteCostRates") in
  if code <> 0 then
    failf "emitting a fact indexed by an ADT constructor must succeed; got (exit %d):\n%s"
      code out

let t_misspelled_constructor_is_rejected_at_check_time () =
  let code, out = check_one (adt_fact_app "Bogus") in
  if code = 0 then
    failf
      "a proof argument that names no constructor must be rejected at CHECK \
       time — otherwise the kernel's uppercase-is-a-constant rule turns #70's \
       codegen trap into a silent hole.\n%s" out;
  if not (contains out "is not a constructor of `Permission`") then
    failf "the diagnostic must name the ADT whose constructors are valid here.\n%s" out;
  if not (contains out "WriteCostRates, ReadProjects") then
    failf "the hint must list the ADT's constructors.\n%s" out

let t_constructor_of_another_adt_is_rejected () =
  let code, out = check_one (adt_fact_app "Red") in
  if code = 0 then
    failf
      "`Red` is a real constructor, but not of `Permission` — an ADT-indexed \
       fact must be checked against the ADT it declares.\n%s" out;
  if not (contains out "argument `Red` is not a constructor of `Permission`") then
    failf "the diagnostic must name the offending argument and the declared ADT.\n%s" out

(* The whole point of indexing a fact by a constructor: two constructors are two
   non-interchangeable proofs.  If this ever regresses, #70's "make it compile"
   half would be worse than the trap it replaced. *)
let t_constructors_are_non_interchangeable () =
  let src = adt_fact_app "WriteCostRates" ^ {|
fn readProjectsCore(c: Caller ::: MayUse c ReadProjects) -> String =
  "read projects"

fn mkCaller(granted: List Permission) -> Caller =
  Caller { granted: granted }

test "a WriteCostRates proof must not satisfy a ReadProjects demand" {
  let c = mkCaller [WriteCostRates]
  let proven = check mayWriteCostRates c
  expect (readProjectsCore proven) == "read projects"
}
|} in
  let code, out = check_one src in
  if code = 0 then
    failf
      "a `MayUse c WriteCostRates` proof must NOT discharge a \
       `MayUse c ReadProjects` obligation.\n%s" out;
  if not (contains out "does not statically satisfy declared proof `MayUse c ReadProjects`")
  then
    failf "the rejection must come from call-site proof discharge.\n%s" out

(* Cross-module: the ADT lives in another module, so the constructor table this
   pass consults must include imported type decls. *)
let perms_module = {|module Perms exposing [Permission(..)]
import Tesl.Prelude exposing [String]

type Permission
  = WriteCostRates
  | ReadProjects
|}

let imported_adt_fact_app demanded =
  Printf.sprintf {|module App exposing []
import Tesl.Prelude exposing [String, Bool(..), List]
import Tesl.List exposing [List.member]
import Perms exposing [Permission(..)]

record Caller {
  granted: List Permission
}

fact MayUse (c: Caller) (p: Permission)

check mayWriteCostRates(c: Caller) -> c: Caller ::: MayUse c %s =
  if List.member WriteCostRates c.granted then
    ok c ::: MayUse c %s
  else
    fail 403 "missing permission write:cost-rates"
|} demanded demanded

let t_imported_adt_constructor_checks () =
  let code, out =
    with_project
      [ ("perms.tesl", perms_module); ("app.tesl", imported_adt_fact_app "WriteCostRates") ]
      "app.tesl" [ "--check" ]
  in
  if code <> 0 then
    failf "an IMPORTED ADT's constructor must index a fact just as well; got (exit %d):\n%s"
      code out

let t_imported_adt_misspelling_is_rejected () =
  let code, out =
    with_project
      [ ("perms.tesl", perms_module); ("app.tesl", imported_adt_fact_app "Nope") ]
      "app.tesl" [ "--check" ]
  in
  if code = 0 then
    failf
      "the constructor table must include IMPORTED ADTs, or a cross-module \
       misspelling stays silent.\n%s" out;
  if not (contains out "is not a constructor of `Permission`") then
    failf "the cross-module diagnostic must name the imported ADT.\n%s" out

(* ── #71 fixtures ───────────────────────────────────────────────────────── *)

let api_auth_app type_decl auth_type = Printf.sprintf {|module App exposing []
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Http exposing [HttpRequest]

%s

fact Authenticated (c: %s)

auth resolveCaller(request: HttpRequest) -> c: %s ::: Authenticated c
  requires [] =
  let c = VariantA
  ok c ::: Authenticated c

handler get whoami(c: %s ::: Authenticated c) -> String
  requires [] =
  "ok"

api MiniApi {
  get "/whoami"
    auth c: %s ::: Authenticated c via resolveCaller
    -> String
}

server MiniServer for MiniApi {
  whoami
}
|} type_decl auth_type auth_type auth_type auth_type

let sum_type_decl = {|type Simple
  = VariantA
  | VariantB|}

let t_same_module_sum_type_auth_checks () =
  let code, out = check_one (api_auth_app sum_type_decl "Simple") in
  if code <> 0 then
    failf
      "a multi-variant sum declared in the SAME module as the api block must be \
       accepted in the `auth` clause; got (exit %d):\n%s" code out

let t_same_module_sum_type_auth_emits () =
  let code, out = emit_one (api_auth_app sum_type_decl "Simple") in
  if code <> 0 then
    failf "the same-module sum-type auth app must emit; got (exit %d):\n%s" code out;
  if not (contains out "type Simple struct") then
    failf "the sum type must still be emitted as a Go ADT.\n%s" out

(* An api type position that names nothing must STILL be an error — the fix adds
   the ADT/alias tables to the known-type list, it does not disable the check. *)
let t_unknown_api_auth_type_is_still_rejected () =
  let code, out = check_one (api_auth_app sum_type_decl "Nonexistent") in
  if code = 0 then
    failf "an api `auth` clause naming an undeclared type must still fail.\n%s" out;
  if not (contains out "unknown type: Nonexistent") then
    failf "the undeclared api type must still report `unknown type`.\n%s" out

(* The cross-module shape the issue reported as the workaround — a regression
   guard, since it was the only working spelling before the fix. *)
let callers_module = {|module Callers exposing [Simple(..), Authenticated, resolveCaller]
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Http exposing [HttpRequest]

type Simple
  = VariantA
  | VariantB

fact Authenticated (c: Simple)

auth resolveCaller(request: HttpRequest) -> c: Simple ::: Authenticated c
  requires [] =
  let c = VariantA
  ok c ::: Authenticated c
|}

let cross_module_api_app = {|module App exposing []
import Tesl.Prelude exposing [String, Bool(..)]
import Callers exposing [Simple(..), Authenticated, resolveCaller]

handler get whoami(c: Simple ::: Authenticated c) -> String
  requires [] =
  "ok"

api MiniApi {
  get "/whoami"
    auth c: Simple ::: Authenticated c via resolveCaller
    -> String
}

server MiniServer for MiniApi {
  whoami
}
|}

let t_cross_module_sum_type_auth_still_checks () =
  let code, out =
    with_project
      [ ("callers.tesl", callers_module); ("app.tesl", cross_module_api_app) ]
      "app.tesl" [ "--check" ]
  in
  if code <> 0 then
    failf "the cross-module sum-type auth shape must keep working; got (exit %d):\n%s"
      code out

(* The known-type list is built from the checker's ADT table, so it must not care
   whether the type is declared BEFORE or AFTER the api block — the emitted
   emission follows source order, and a scope-order-sensitive fix would leave
   the trailing-declaration spelling broken. *)
let t_sum_type_declared_after_the_api_block_checks () =
  let src = {|module App exposing []
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Http exposing [HttpRequest]

fact Authenticated (c: Simple)

auth resolveCaller(request: HttpRequest) -> c: Simple ::: Authenticated c
  requires [] =
  let c = VariantA
  ok c ::: Authenticated c

handler get whoami(c: Simple ::: Authenticated c) -> String
  requires [] =
  "ok"

api MiniApi {
  get "/whoami"
    auth c: Simple ::: Authenticated c via resolveCaller
    -> String
}

server MiniServer for MiniApi {
  whoami
}

type Simple
  = VariantA
  | VariantB
|} in
  let code, out = check_one src in
  if code <> 0 then
    failf
      "the api `auth` type lookup must be declaration-order independent; got \
       (exit %d):\n%s" code out

(* ── #70's CLASS: check-clean implies Go emission accepts it ─────────────────

   #70 was not "constructors were forgotten once".  Its shape is that TWO
   frontend passes independently decide whether a proof-template atom is a GDP
   name. Any disagreement is a `tesl check` passes / codegen traps bug. The
   invariant that matters is end-to-end:

     for every proof-argument spelling, either `tesl check` rejects it, or the
     Go emission accepts it without an unbound proof-name error.

   Each row below is one spelling in the second slot of a two-parameter fact.  A
   future divergence in either implementation fails here regardless of which side
   changed. *)

(* The second proof argument is [arg]; [decls] adds whatever declares it. *)
let proof_arg_probe ~decls ~param_type ~arg = Printf.sprintf {|module App exposing []
import Tesl.Prelude exposing [String, Bool(..), Int]

record Caller {
  name: String
}

%s

fact MayUse (c: Caller) (p: %s)

check mayUse(c: Caller) -> c: Caller ::: MayUse c %s =
  if c.name == "" then
    fail 403 "denied"
  else
    ok c ::: MayUse c %s

fn core(c: Caller ::: MayUse c %s) -> String =
  c.name
|} decls param_type arg arg arg

(* (label, declarations, fact-parameter type, the argument spelling) *)
let proof_arg_rows = [
  ("a bound parameter name", "", "Caller", "c");
  ("an ADT constructor",
   "type Permission\n  = WriteCostRates\n  | ReadProjects", "Permission",
   "WriteCostRates");
  ("an Int literal", "", "Int", "42");
  ("a String literal", "", "String", "\"fixed\"");
  ("a name that is bound nowhere", "", "Caller", "ghost");
  ("a dotted path", "", "String", "c.name");
  ("a constructor that does not exist",
   "type Permission\n  = WriteCostRates\n  | ReadProjects", "Permission",
   "Bogus");
]

let t_check_clean_implies_the_kernel_accepts () =
  List.iter (fun (label, decls, param_type, arg) ->
      let src = proof_arg_probe ~decls ~param_type ~arg in
      let check_code, check_out = check_one src in
      if check_code <> 0 then
        (* Rejected at check time: code generation is never reached. *)
        ignore check_out
      else
        match Compile.compile_go_source "app.tesl" src with
        | Compile.GoSuccess artifacts -> build_go_artifacts label artifacts
        | Compile.GoFailure diagnostics ->
          let emit_out = String.concat "\n"
              (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics) in
          failf
            "%s: `tesl check` passed but Go emission rejected `%s`; this is \
             issue #70's check-clean/codegen-trap shape.\n%s"
            label arg emit_out)
    proof_arg_rows

(* ── #71's CLASS: every type-declaring form is visible to a type-position check ──

   The bug was not "ADTs were forgotten once".  It was a consumer rebuilding
   "which types exist" from a hand-picked subset of the tables
   [Checker.collect_type_defs] writes.  [Checker.ctx_type_names] now derives that
   list from the tables themselves; this test is the completeness ratchet on the
   derivation — declare every type-introducing form in one module and require the
   name of each to come back.  A new type form that registers into a FOURTH table
   fails here rather than surfacing as another "unknown type: X" bug report. *)
let all_type_forms_src = {|module App exposing []
import Tesl.Prelude exposing [String, Int, PosixMillis]

record RecordShape {
  id: String
}

entity EntityShape table "entity_shapes" primaryKey id {
  id: String
  createdAt: PosixMillis
}

type AdtShape
  = FirstVariant
  | SecondVariant

type ParamAdtShape a
  = Wrapped value: a
  | Absent

type NewtypeShape = String

secret SecretShape = String
|}

let t_every_type_form_is_in_ctx_type_names () =
  let m =
    match Parser.parse_module "app.tesl" all_type_forms_src with
    | Ok m -> m
    | Err e -> failf "the all-type-forms probe must parse: %s" e.msg
  in
  let ctx = Checker.make_ctx ~filename:"app.tesl" ~env:[] () in
  let ctx = Checker.collect_type_defs ctx m.decls in
  let names = Checker.ctx_type_names ctx in
  List.iter (fun expected ->
    if not (List.mem expected names) then
      failf
        "`%s` is declared as a type but ctx_type_names does not report it — a \
         type-position scope check would call it `unknown type` (issue #71's \
         class).  Reported: %s"
        expected (String.concat ", " names))
    [ "RecordShape"; "EntityShape"; "AdtShape"; "ParamAdtShape"; "NewtypeShape";
      "SecretShape" ]

(* …and the same forms, end to end, in the api type position that reported #71. *)
let api_auth_with_type_named ty extra_decls = Printf.sprintf {|module App exposing []
import Tesl.Prelude exposing [String, Bool(..), Int]
import Tesl.Http exposing [HttpRequest]

%s

fact Authenticated (c: %s)

auth resolveCaller(request: HttpRequest) -> c: %s ::: Authenticated c
  requires [] =
  let c = %s
  ok c ::: Authenticated c

handler get whoami(c: %s ::: Authenticated c) -> String
  requires [] =
  "ok"

api MiniApi {
  get "/whoami"
    auth c: %s ::: Authenticated c via resolveCaller
    -> String
}

server MiniServer for MiniApi {
  whoami
}
|} extra_decls ty ty (match ty with
     | "RecordShape" -> "RecordShape { id: \"x\" }"
     | "AdtShape" -> "FirstVariant"
     | "NewtypeShape" -> "NewtypeShape \"x\""
     | other -> failf "no constructor expression for %s" other)
    ty ty

let t_every_type_form_works_as_an_api_auth_type () =
  List.iter (fun (ty, decls) ->
    let code, out = check_one (api_auth_with_type_named ty decls) in
    if code <> 0 then
      failf
        "`%s` is a declared type, so it must be accepted in the api `auth` \
         clause; got (exit %d):\n%s" ty code out)
    [ ("RecordShape", "record RecordShape {\n  id: String\n}");
      ("AdtShape", "type AdtShape\n  = FirstVariant\n  | SecondVariant");
      ("NewtypeShape", "type NewtypeShape = String") ]

let () =
  run "Issues-70-71" [
    "issue-70-adt-indexed-fact", [
      test_case "an ADT-constructor-indexed fact checks" `Quick
        t_adt_indexed_fact_checks;
       test_case "an ADT-indexed fact reaches Go emission" `Quick
        t_adt_indexed_fact_emits_the_constructor;
      test_case "a misspelled constructor fails at check time" `Quick
        t_misspelled_constructor_is_rejected_at_check_time;
      test_case "a constructor of another ADT is rejected" `Quick
        t_constructor_of_another_adt_is_rejected;
      test_case "two constructors are non-interchangeable proofs" `Quick
        t_constructors_are_non_interchangeable;
      test_case "an imported ADT's constructor indexes a fact" `Quick
        t_imported_adt_constructor_checks;
      test_case "a cross-module misspelling is rejected" `Quick
        t_imported_adt_misspelling_is_rejected;
    ];
    "issue-71-api-auth-sum-type", [
      test_case "a same-module sum type is a valid auth type" `Quick
        t_same_module_sum_type_auth_checks;
      test_case "the same-module sum-type auth app emits" `Quick
        t_same_module_sum_type_auth_emits;
      test_case "an undeclared api type is still rejected" `Quick
        t_unknown_api_auth_type_is_still_rejected;
      test_case "the cross-module shape keeps working" `Quick
        t_cross_module_sum_type_auth_still_checks;
      test_case "the sum type may be declared after the api block" `Quick
        t_sum_type_declared_after_the_api_block_checks;
    ];
    "issue-70-class-check-clean-implies-go-builds", [
      test_case "no proof-argument spelling passes check and traps at codegen" `Slow
        t_check_clean_implies_the_kernel_accepts;
    ];
    "issue-71-class-every-type-form", [
      test_case "ctx_type_names reports every type-declaring form" `Quick
        t_every_type_form_is_in_ctx_type_names;
      test_case "every type form works as an api auth type" `Quick
        t_every_type_form_works_as_an_api_auth_type;
    ];
  ]
