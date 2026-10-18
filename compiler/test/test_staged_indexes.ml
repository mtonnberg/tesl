open Alcotest
module I = Migration_inventory
module S = Migration_sparse
let contains text part = try ignore (Str.search_forward (Str.regexp_string part) text 0); true with Not_found -> false
let replace a b = Str.global_replace (Str.regexp_string a) b
let only = function [x] -> x | _ -> fail "expected one item"
let parse source = match Parser.parse_module "stage.tesl" source with
  | Parser.Ok m -> m | Parser.Err e -> fail e.msg
let entity m = only (List.filter_map (function Ast.DEntity e -> Some e | _ -> None) m.Ast.decls)
let source revision index = Printf.sprintf {|module Schema.Stages.%s exposing [User]
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Int32 exposing [Int32]
entity User table "users" primaryKey id {
 id: String
 active: Bool
 other: Bool
 %s
}
|} revision index
let rec mkdir p = if not (Sys.file_exists p) then (mkdir (Filename.dirname p); Unix.mkdir p 0o700)
let rec remove p = if (Unix.lstat p).Unix.st_kind=Unix.S_DIR then
  (Array.iter (fun n -> remove (Filename.concat p n)) (Sys.readdir p); Unix.rmdir p) else Sys.remove p
let project f =
  let root=Filename.temp_dir "tesl-stages-" "" in
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let write name text = let p=Filename.concat root name in mkdir (Filename.dirname p);
      Out_channel.with_open_bin p (fun out -> output_string out text); p in
    ignore (write "tesl.toml" ""); f write)
let get = function Ok x -> x | Error (e:Migration_ir.error) -> fail e.message
let load write revision text =
  I.load ~compiler_abi:"stage-test-abi" ~root_file:(write ("schema/stages/" ^ String.lowercase_ascii revision ^ ".tesl") text) |> get
let errors ?(file="schema/stages/v-current.tesl") source = (Compile.agent_context_result_source file source).diagnostics
  |> List.filter (fun (d:Compile.diagnostic) -> d.severity="error")
let expect_ir_error part = function
  | Ok _ -> fail ("expected refusal: " ^ part)
  | Error (e:Migration_ir.error) -> check bool e.message true (contains e.message part)

let parse_format () =
  let text=source "VCurrent" "staging unique index [active] as \"prepare_active\"" in
  let index=only (entity (parse text)).indexes in
  check bool "obligation" true index.ix_staging;
  check bool "no unique promise" false index.ix_unique;
  let metadata=Ir.entity_index_json index in
  check bool "metadata retains stage intent" true (contains metadata "\"staging\":true");
  check bool "metadata grants no uniqueness" true (contains metadata "\"unique\":false");
  let formatted=Formatter.format_source text in
  let after=only (entity (parse formatted)).indexes in
  check bool "formatter preserves staging" true after.ix_staging;
  check bool "formatter never promotes" false after.ix_unique;
  check (option string) "name preserved" index.ix_name after.ix_name;
  check string "idempotent" formatted (Formatter.format_source formatted);
  let contextual=source "VCurrent" "" |> replace "other: Bool" "staging: Bool\n unique: Bool\n index: Bool" in
  ignore (parse contextual);
  List.iter (fun declaration ->
    match Parser.parse_module "stage.tesl" (source "VCurrent" declaration) with
    | Parser.Err _ -> () | Parser.Ok _ -> fail ("unsupported syntax accepted: " ^ declaration))
    ["staging index [active]";"staging unique index [active] nulls not distinct";
     "staging unique index [active] deferrable";"staging unique index [active] using hash"]

let negative_domains () =
  List.iter (fun (key,declaration) ->
    let ds=errors (source "VCurrent" declaration |> replace "active: Bool" ("active: " ^ key)) in
    check bool (key ^ ": expected MIG030") true
      (List.exists (fun (d:Compile.diagnostic) -> d.code="MIG030") ds))
    ["Bool","staging unique index [active, other]";
     "Bool","staging unique index [active]\n unique index [active]";
     "Int","staging unique index [active]";
     "String","staging unique index [active]";
     "Int32","staging unique index [active]";
     "Maybe (Maybe Bool)","staging unique index [active]";
     "Bool @db(text)","staging unique index [active]"]

let diagnostic_authority () =
  let metadata=Diagnostic_metadata.migration ~code:"MIG030" ~message:"CANCEL STAGED UNIQUE" ~related:[] in
  match metadata.action with
  | Some action ->
    check bool "stage changes are not fixAll" false action.fix_all_eligible;
    check bool "stage decisions require review" true action.needs_confirmation;
    check string "decision class" "decision" (Diagnostic_metadata.class_name action.class_)
  | None -> fail "stage obligation lost its decision classification"

let no_conflict_promise () =
  let text=source "VCurrent" "staging unique index [active]" |> replace "Schema.Stages.VCurrent" "StageConflict" in
  let text=replace "entity User" "import Tesl.DB exposing [dbWrite]\nentity User" text ^ {|
fn put() -> Int requires [dbWrite User] =
 let done = upsert User { id: "one", active: True, other: False } onConflict [active] doUpdate [other]
 0
|} in
  let ds=errors ~file:"stage-conflict.tesl" text in
  check bool "staging cannot supply an upsert arbiter" true
    (List.exists (fun (d:Compile.diagnostic) -> contains d.message "unique index") ds)

let inventory_history () = project (fun write ->
  let staged=source "V8" "staging unique index [active] as \"prep_a\"" in
  let before=load write "V8" staged in
  let predecessor=load write "V7" (source "V7" "") in
  (match get (I.stage_transitions ~before:predecessor ~after:before) with
   | [I.Stage _] -> () | _ -> fail "stage introduction was not distinguished");
  (match S.requirements ~before:predecessor ~after:before ~identities:[] ~loc:(Location.dummy_loc "stage.tesl") with
   | Error _ -> fail "source staging was refused as a migration intent"
   | Ok requirements ->
     check bool "staging is not an unchanged sparse entity" true
       (List.exists (function _,S.Paired {contract_changed=true;_} -> true | _ -> false)
          (S.requirement_entities requirements)));
  let carried=load write "V9" (source "V9" "staging unique index [active] as \"prep_b\"") in
  let old=only (I.staged_indexes before) and fresh=only (I.staged_indexes carried) in
  check string "revision and index name do not identify stage" old.stage_id fresh.stage_id;
  (match get (I.stage_transitions ~before ~after:carried) with [I.Carry _] -> () | _ -> fail "not a carry");
  let storage=match Migration_storage.describe before with Ok x -> x | Error _ -> fail "storage" in
  let index=only (only (Migration_storage.tables storage)).indexes in
  check bool "preparatory physical index is NONUNIQUE" false index.unique;
  check string "explicit name" "prep_a" index.name;
  (match Migration_storage.stage_nodes storage with
   | Migration_canonical.Seq [Migration_canonical.Seq [_;Bytes id;semantic;_;_;_;_;_;_;_]] ->
     check string "sealed descriptor carries semantic id" old.stage_id id;
     check bool "sealed descriptor carries full typed dependency contract" true (semantic=old.stage_contract)
   | _ -> fail "missing complete source storage stage descriptor");
  let plain=load write "V9" (source "V9" "index [active] as \"prep_a\"") in
  check bool "stage canonical identity differs from plain index" true (I.snapshot before<>I.snapshot plain);
  (match get (I.stage_transitions ~before ~after:plain) with [I.Cancel _] -> () | _ -> fail "not cancellation");
  let promoted=load write "V9" (source "V9" "unique index [active]") in
  (match get (I.stage_transitions ~before ~after:promoted) with [I.Promote _] -> () | _ -> fail "not promotion");
  List.iter (fun after -> match S.requirements ~before ~after ~identities:[] ~loc:old.stage_loc with
    | Ok _ -> fail "unimplemented transition admitted"
    | Error es -> check bool "explicit unsupported transition" true
        (List.exists (fun (e:S.error) -> e.code="MIG030" && contains e.message "not implemented") es)) [plain;promoted];
  let changed=load write "V9" (source "V9" "staging unique index [other]") in
  expect_ir_error "changing staged columns" (I.stage_transitions ~before ~after:changed);
  let removed=load write "V9" (source "V9" "" |> replace "active: Bool\n" "") in
  expect_ir_error "renaming its key" (I.stage_transitions ~before ~after:removed);
  let typed=load write "V9" (source "V9" "" |> replace "active: Bool" "active: Maybe Bool") in
  expect_ir_error "type, dependencies" (I.stage_transitions ~before ~after:typed);
  let dropped=load write "V9" "module Schema.Stages.V9 exposing []\n" in
  expect_ir_error "its entity" (I.stage_transitions ~before ~after:dropped);
  let v10=load write "V10" (source "V10" "staging unique index [active]") in
  let v11=load write "V11" (source "V11" "staging unique index [active]") in
  ignore (get (I.check_stage_history [before;carried;v10]));
  expect_ir_error "maximum carried versions" (I.check_stage_history [before;carried;v10;v11]))

let dependencies () = project (fun write ->
  let proof={|fact Approved (b: Bool)
fn desired() -> Bool = True
establish approve(b: Bool) -> Maybe (value: Bool ::: Approved value) =
 if b == desired() then
  Something (b ::: Approved b)
 else
  Nothing
|} in
  let text=source "V8" "staging unique index [active]" |> replace "entity User" (proof ^ "entity User")
    |> replace "active: Bool" "active: Bool ::: Approved active" in
  let before=load write "V8" text in
  let after=load write "V9" (text |> replace ".V8" ".V9" |> replace "= True" "= False") in
  check bool "private proof helper participates in stage identity" true
    ((only (I.staged_indexes before)).stage_id<>(only (I.staged_indexes after)).stage_id);
  expect_ir_error "dependencies" (I.stage_transitions ~before ~after))

let execution_refusals () = project (fun write ->
  let schema=load write "V1" (source "V1" "staging unique index [active]") in
  let storage=match Migration_storage.describe schema with Ok x -> x | Error _ -> fail "storage" in
  let index=only (only (Migration_storage.tables storage)).indexes in
  check string "preparation has its own physical name" "users_active_stage_idx" index.name;
  let refuses = function
    | Ok _ -> fail "stage reached executable physical plan"
    | Error errors -> check bool "MIG030 refusal" true
        (List.exists (fun (e:S.error) -> e.code="MIG030" && contains e.message "not implemented") errors) in
  refuses (Migration_expansion.generate ~initial_version:1 ~schemas:[schema] ~edges:[]);
  refuses (Migration_row_history.check ~schemas:[schema] ~edges:[]);
  let integer=load write "V2" (source "V2" "staging unique index [active]" |> replace "active: Bool" "active: Int32 @db(integer)") in
  let integer_storage=match Migration_storage.describe integer with Ok x -> x | Error _ -> fail "integer storage" in
  check bool "integer staging does not enforce uniqueness" false
    (only (only (Migration_storage.tables integer_storage)).indexes).unique;
  let optional=load write "V3" (source "V3" "staging unique index [active]" |> replace "active: Bool" "active: Maybe Bool") in
  check int "NULLS DISTINCT optional key is admitted" 1 (List.length (I.staged_indexes optional)))

let memory_codegen () =
  let text=source "VCurrent" "staging unique index [active]" |> replace "Schema.Stages.VCurrent" "StageMemory" in
  (* Unique comparators are emitted at write sites, not entity declarations.
     Exercise the actual Memory insert lowering for both sides of the control. *)
  let text=replace "entity User" "import Tesl.DB exposing [dbWrite]\nentity User" text ^ {|
fn add(id: String) -> User requires [dbWrite User] =
 insert User { id: id, active: True, other: False }
|} in
  let emit text = match Compile.compile_go_source "stage-memory.tesl" text with
    | Compile.GoFailure ds -> fail (String.concat "\n" (List.map (fun (d:Compile.diagnostic) -> d.message) ds))
    | Compile.GoSuccess artifacts -> String.concat "\n" (List.filter_map (fun (a:Emit_go.artifact) ->
        if contains a.path "internal/teslrt" then None else Some a.contents) artifacts) in
  check bool "Memory gets no uniqueness comparator" false (contains (emit text) "teslrt.UniqueIndexOf(");
  check bool "ordinary unique control does get comparator" true
    (contains (emit (replace "staging unique" "unique" text)) "teslrt.UniqueIndexOf(")

let memory_runtime () =
  let directory=Filename.dirname (Unix.realpath Sys.executable_name) in
  let compiler=Filename.concat directory "../bin/main.exe" in
  let fixture=match Sys.getenv_opt "TESL_REPO_ROOT" with
    | Some root -> Filename.concat root "compiler/test/fixtures/stage-memory.tesl"
    | None -> Filename.concat directory "fixtures/stage-memory.tesl" in
  let pid=Unix.create_process compiler [|compiler;"test";fixture|]
    Unix.stdin Unix.stdout Unix.stderr in
  match snd (Unix.waitpid [] pid) with
  | Unix.WEXITED 0 -> ()
  | _ -> fail "compiled staged Memory fixture failed (Go execution is mandatory)"

let () = run "staged indexes" ["source",[
  test_case "parse and format" `Quick parse_format;
  test_case "restricted domains" `Quick negative_domains;
  test_case "decision authority" `Quick diagnostic_authority;
  test_case "no conflict promise" `Quick no_conflict_promise;
  test_case "inventory and source history" `Quick inventory_history;
  test_case "complete proof dependencies" `Quick dependencies;
  test_case "execution remains refused" `Quick execution_refusals;
  test_case "Memory lowering" `Quick memory_codegen;
  test_case "compiled Memory execution" `Quick memory_runtime]]
