(* Revision checkpoints: Start writes migrations/<family>/v<n>.checkpoint with
   the carried history state through V<n>, and records its digest in V<n>'s
   frozen-source block. These tests pin the contract:
   - resuming a prefix state reproduces the complete fold exactly;
   - outputs are identical in normal and full-history mode;
   - an edited checkpoint byte fails with MIG013;
   - a checkpoint that disagrees with the recomputation (with a consistently
     updated digest) is refused by full-history mode;
   - a checkpoint from another compiler ABI is ignored, not trusted;
   - histories without checkpoints keep working unchanged. *)
open Alcotest

let rec remove p = if (Unix.lstat p).Unix.st_kind=Unix.S_DIR then
  (Array.iter (fun n -> remove (Filename.concat p n)) (Sys.readdir p); Unix.rmdir p) else Sys.remove p
let rec mkdir p = if not (Sys.file_exists p) then (mkdir (Filename.dirname p); Unix.mkdir p 0o700)
let read p = In_channel.with_open_bin p In_channel.input_all
let write p s = mkdir (Filename.dirname p); Out_channel.with_open_bin p (fun out -> output_string out s)
let replace a b s = Str.global_replace (Str.regexp_string a) b s
let contains = Compile.string_contains

let with_temp f =
  let root = Filename.temp_file "tesl-checkpoint-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  let root = Unix.realpath root in
  Fun.protect ~finally:(fun () -> remove root) (fun () -> f root)

let with_full_history enabled f =
  let previous = Sys.getenv_opt "TESL_FULL_HISTORY" in
  Unix.putenv "TESL_FULL_HISTORY" (if enabled then "1" else "0");
  Fun.protect ~finally:(fun () -> Unix.putenv "TESL_FULL_HISTORY" (Option.value previous ~default:"0")) f

let render_artifacts = function
  | Compile.GoSuccess xs ->
    "ok\n" ^ String.concat "" (List.map (fun (a:Emit_go.artifact) ->
      Printf.sprintf "== %s %d\n%s\n" a.path (String.length a.contents) a.contents) xs)
  | Compile.GoFailure ds ->
    "failed\n" ^ String.concat "\n" (List.map (fun (d:Compile.diagnostic) ->
      Printf.sprintf "%s:%d:%d %s %s" d.file d.start_line d.start_col d.code d.message) ds)
let render_diags ds = String.concat "\n" (List.map (fun (d:Compile.diagnostic) ->
  Printf.sprintf "%s:%d:%d %s %s %s" d.file d.start_line d.start_col d.severity d.code d.message) ds)

let emit file = Migration_program.with_compilation_cache (fun () ->
  render_artifacts (Compile.compile_go_source ~path:file file (read file)))
let check_file file = Migration_program.with_compilation_cache (fun () ->
  let source = read file in
  match Parser.parse_module file source with
  | Parser.Ok m -> render_diags (Compile.check_module source m)
  | Parser.Err e -> fail e.msg)

let schema fields =
  let entity = "entity Alpha table \"alphas\" primaryKey id { " ^
    String.concat ", " (List.map (fun (k,t) -> k ^ ": " ^ t) fields) ^ " }" in
  let values = List.map (fun (k,t) -> k ^ ": " ^ (if k="id" then "id" else if t="String" then "\"n\"" else "Nothing")) fields in
  String.concat "\n" ["module Schema.Scale.VCurrent exposing [Alpha, makeAlpha]";
    "import Tesl.Prelude exposing [String]"; "import Tesl.Maybe exposing [Maybe(..)]"; entity;
    "fn makeAlpha(id: String) -> Alpha = Alpha { " ^ String.concat ", " values ^ " }"] ^ "\n"

let migration version body =
  Printf.sprintf {|module Schema.Scale.Migrate.V%d exposing [migration]
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..)]
import Schema.Scale.V%d
import Schema.Scale.VCurrent
%s|} version (version-1) body

let additive version = migration version (Printf.sprintf {|migration = Migration {
 from: Schema.Scale.V%d
 to: Schema.Scale.VCurrent
 same: []
 entities: { Alpha: Additive [] }
 fixtures: []
}
|} (version-1))

let rename version fields ~old ~fresh = migration version (Printf.sprintf {|migration = Migration {
 from: Schema.Scale.V%d
 to: Schema.Scale.VCurrent
 same: []
 entities: { Alpha: Migrate convertAlpha [Rename %s %s] }
 fixtures: [fixtureAlpha]
}
fn convertAlpha(old: Schema.Scale.V%d.Alpha) -> Migrated Schema.Scale.VCurrent.Alpha =
  Row (Schema.Scale.VCurrent.Alpha { %s })
fn fixtureAlpha() -> Schema.Scale.V%d.Alpha = Schema.Scale.V%d.makeAlpha "fixture"
|} (version-1) old fresh (version-1)
  (String.concat ", " (List.map (fun (k,_) -> k ^ ": old." ^ (if k=fresh then old else k)) fields))
  (version-1) (version-1))

let app = {|module App exposing [Main]
import Tesl.Prelude exposing [String]
import Tesl.Env exposing [env, envInt, envRead]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection, MigrationConfig, Worker]
import Tesl.App exposing [App]
import Schema.Scale.VCurrent exposing [Alpha]
database Main = Database { schema: Schema.Scale.VCurrent, migrations: Schema.Scale.Migrate,
 backend: Postgres (PostgresConfig { namespace: "scale", dbName: env "S_DB", user: env "S_USER", password: "",
 connection: TcpConnection { host: env "S_HOST", port: envInt "S_PORT" 5432 },
 migrations: MigrationConfig { topology: Worker, controlOwner: env "S_OWNER", requestRole: env "S_REQUEST", workerRole: env "S_WORKER", ddlConnection: env "S_DDL" } }) }
api ScaleApi {
get "/health" -> String
}
handler get health() -> String = "ready"
server ScaleServer for ScaleApi { health }
main() -> App requires [envRead] =
App { database: Main, api: ScaleServer, port: envInt "S_HTTP_PORT" 8099 }
|}

let preview_errors errors = String.concat "\n" (List.map (fun (e:Migration_preview.error) -> e.message) errors)
let edits = function
  | Error errors -> fail (preview_errors errors)
  | Ok preview ->
    if not (Migration_preview.compilable preview) then
      fail ("generated revision does not compile:\n" ^ render_diags (Migration_preview.diagnostics preview));
    List.map (fun (e:Migration_manifest.edit) -> e.path,e.after) (Migration_manifest.edits (Migration_preview.manifest preview))
let apply result = List.iter (fun (path,after) -> write path after) (edits result)

let generate root entry new_revision = Migration_program.with_compilation_cache (fun () ->
  Migration_preview.generate ~project_root:root ~entry_file:entry ~database:None ~new_revision ~documents:[])
let contract root entry version = Migration_program.with_compilation_cache (fun () ->
  Migration_preview.generate_contract ~project_root:root ~entry_file:entry ~database:None ~version ~documents:[])

(* V1 {id,name}; V2 adds o2; V3 renames o2 -> r3 (Contract); V4 adds o4;
   V5 (current) renames o4 -> r5 with its Contract. Completed: V2, V3, V4. *)
let v1 = ["id","String"; "name","String"]
let v3 = v1 @ ["r3","Maybe String"]
let v4 = v3 @ ["o4","Maybe String"]
let v5 = v3 @ ["r5","Maybe String"]
let with_history f = with_temp (fun root ->
  let path = Filename.concat root in
  let entry = path "app.tesl" in
  write (path "tesl.toml") "";
  write (path "schema/scale/v-current.tesl") (schema v1);
  write entry app;
  let revision version fields body =
    apply (generate root entry true);
    write (path "schema/scale/v-current.tesl") (schema fields);
    let edge = path (Printf.sprintf "migrations/scale/v%d.tesl" version) in
    let header = List.hd (Str.split_delim (Str.regexp_string "module ") (read edge)) in
    write edge (header ^ body);
    apply (generate root entry false) in
  revision 2 (v1 @ ["o2","Maybe String"]) (additive 2);
  revision 3 v3 (rename 3 v3 ~old:"o2" ~fresh:"r3");
  apply (contract root entry 3);
  revision 4 v4 (additive 4);
  revision 5 v5 (rename 5 v5 ~old:"o4" ~fresh:"r5");
  apply (contract root entry 5);
  f root path entry)

let checkpoint path version = path (Printf.sprintf "migrations/scale/v%d.checkpoint" version)

(* Rewrite a checkpoint and the digest recorded for it, as someone editing both
   consistently would. *)
let rewrite_checkpoint path version edit =
  let file = checkpoint path version in
  let text = edit (read file) in
  write file text;
  let root = path (Printf.sprintf "migrations/scale/v%d.tesl" version) in
  let source = read root in
  let line = Str.regexp "# tesl:frozen-checkpoint [0-9a-f]+" in
  write root (Str.global_replace line ("# tesl:frozen-checkpoint " ^ Migration_hash.digest text) source)

let written () = with_history (fun _ path _ ->
  List.iter (fun version ->
    check bool (Printf.sprintf "v%d.checkpoint exists" version) true (Sys.file_exists (checkpoint path version));
    let digest = Migration_hash.digest (read (checkpoint path version)) in
    check bool (Printf.sprintf "v%d records the checkpoint digest" version) true
      (contains (read (path (Printf.sprintf "migrations/scale/v%d.tesl" version))) ("# tesl:frozen-checkpoint " ^ digest)))
    [2;3;4];
  check bool "the current revision has no checkpoint" false (Sys.file_exists (checkpoint path 5)))

(* Stage-1 identity: resuming each carried prefix reproduces the complete fold. *)
let resume_equals_fold () = with_history (fun root _ _ ->
  Migration_program.with_compilation_cache (fun () ->
  let abi = Migration_abi.id (Result.get_ok (Migration_abi.current ())) in
  let h = Result.get_ok (Migration_history_sources.discover ~compiler_abi:abi ~project_root:root ~family:"Schema.Scale") in
  let schemas = Migration_history_sources.frozen h @ [Migration_history_sources.current h] in
  let sources = Migration_history_sources.completed_migrations h @ Option.to_list (Migration_history_sources.current_migration h) in
  let edge (m:Migration_history_sources.migration_source) =
    match Parser.parse_module m.path m.contents with
    | Parser.Ok ast -> Option.get (Result.get_ok (Migration_declaration.check ~compiler_abi:abi ~source:m.contents ast))
    | Parser.Err e -> fail e.msg in
  let edges = List.map edge sources in
  let full = Result.get_ok (Migration_row_history.check ~schemas:(List.map Migration_history_sources.inventory schemas) ~edges) in
  let plan = Result.get_ok (Migration_retained_storage.plan full) in
  let node plan v = Migration_canonical.encode (Migration_retained_storage_canonical.version_node ~family:"Schema.Scale" ~namespace:"scale" plan v) in
  List.iter (fun through ->
    let retained = Option.get (Migration_retained_storage.prefix_state plan ~through) in
    let prefix = Option.get (Migration_row_history.prefix_state full ~through ~retained) in
    let tail_schemas = List.filter (fun (s:Migration_history_sources.schema) -> s.version>=through) schemas
      |> List.map Migration_history_sources.inventory in
    let tail_edges = List.filter (fun d -> Migration_declaration.version d>through) edges in
    let resumed = match Migration_row_history.resume ~prefix ~schemas:tail_schemas ~edges:tail_edges with
      | Some rows -> rows | None -> fail "resume refused a carried prefix" in
    let resumed_plan = Result.get_ok (Migration_retained_storage.plan resumed) in
    let later plan = List.filter (fun (v:Migration_retained_storage.version) -> v.version>through)
      (Migration_retained_storage.versions plan) in
    check (list string) (Printf.sprintf "retained versions after V%d" through)
      (List.map (node plan) (later plan)) (List.map (node resumed_plan) (later resumed_plan));
    check (list int) "cleanup versions" (Migration_retained_storage.cleanup_versions plan)
      (Migration_retained_storage.cleanup_versions resumed_plan);
    let generations rows = List.concat_map (fun (v:Migration_row_history.version) ->
      if v.version<=through then [] else List.map (fun (e:Migration_row_history.entity) -> v.version,e.identity,e.generation) v.entities)
      (Migration_row_history.versions rows) in
    check (list (triple int string int)) "generations" (generations full) (generations resumed);
    check (option string) "final carried state"
      (Option.map Migration_canonical.encode (Migration_retained_storage.prefix_state plan ~through:5))
      (Option.map Migration_canonical.encode (Migration_retained_storage.prefix_state resumed_plan ~through:5)))
    [2;3;4]))

let preview_text root entry new_revision =
  match generate root entry new_revision with
  | Error errors -> "error\n" ^ preview_errors errors
  | Ok preview -> Migration_preview.to_json preview

let identity () = with_history (fun root path entry ->
  let full = with_full_history true (fun () -> emit entry) in
  let normal = with_full_history false (fun () -> emit entry) in
  check bool "the history emits" true (String.starts_with ~prefix:"ok\n" full);
  check string "emission is identical in both modes" full normal;
  List.iter (fun name ->
    check string ("diagnostics for " ^ name)
      (with_full_history true (fun () -> check_file (path name))) (with_full_history false (fun () -> check_file (path name))))
    ["app.tesl"; "migrations/scale/v5.tesl"; "migrations/scale/v5-contract.tesl"; "migrations/scale/v3-contract.tesl"];
  List.iter (fun new_revision ->
    check string (Printf.sprintf "preview (new revision: %b)" new_revision)
      (with_full_history true (fun () -> preview_text root entry new_revision))
      (with_full_history false (fun () -> preview_text root entry new_revision))) [false; true])

let resumed_capture () = with_history (fun _ _ entry ->
  let source = read entry in
  let m = match Parser.parse_module entry source with Parser.Ok m -> m | Parser.Err e -> fail e.msg in
  let capture resume = Migration_program.with_compilation_cache (fun () ->
    Migration_program.with_source_history ~resume ~entry:m ~source (function
      | None -> fail "no history"
      | Some history ->
        let program = Migration_program.source_program history in
        let rows = List.assoc "App.Main" (Migration_program.row_histories history) in
        let plan = Result.get_ok (Migration_retained_storage.plan rows) in
        Migration_program.resumed program,Migration_retained_storage.cleanup_versions plan,
        (try ignore (Migration_program.to_json ~quote:Compile.json_encode_string program); true with Invalid_argument _ -> false))) in
  let resumed = with_full_history false (fun () -> capture true) in
  let full = with_full_history true (fun () -> capture true) in
  (match resumed, full with
   | Ok (true,cleanup,emits), Ok (false,full_cleanup,full_emits) ->
     check (list int) "cleanup versions agree" full_cleanup cleanup;
     check bool "a resumed program refuses to publish history" false emits;
     check bool "a full program publishes history" true full_emits
   | Ok (r,_,_), Ok (f,_,_) -> fail (Printf.sprintf "unexpected resumption: normal %b, full %b" r f)
   | _ -> fail "capture failed"))

let tampered () = with_history (fun _ path entry ->
  let file = checkpoint path 3 in
  write file (read file ^ "x");
  List.iter (fun full ->
    let output = with_full_history full (fun () -> emit entry) in
    check bool ("an edited checkpoint fails emission:\n" ^ output) true
      (String.starts_with ~prefix:"failed\n" output && contains output "MIG013");
    check bool "application diagnostics report MIG013" true
      (contains (with_full_history full (fun () -> check_file entry)) "MIG013")) [false; true])

let stale_rejected_by_full_history () = with_history (fun root path entry ->
  (* A consistently re-recorded checkpoint with different carried generations. *)
  rewrite_checkpoint path 4 (fun text -> replace "s5:Alphas1:2" "s5:Alphas1:3" text);
  check bool "the edit changed the checkpoint" true (contains (read (checkpoint path 4)) "s5:Alphas1:3");
  let full = with_full_history true (fun () -> emit entry) in
  check bool ("full history refuses the stale checkpoint:\n" ^ full) true
    (String.starts_with ~prefix:"failed\n" full && contains full "differs from the full-history recomputation");
  ignore root)

let other_abi_ignored () = with_history (fun root path entry ->
  let abi = Migration_abi.id (Result.get_ok (Migration_abi.current ())) in
  let other = "tesl-source-abi-v1:another-compiler-build" in
  let length s = string_of_int (String.length s) in
  List.iter (fun version -> rewrite_checkpoint path version (fun text ->
    replace ("s" ^ length abi ^ ":" ^ abi) ("s" ^ length other ^ ":" ^ other) text)) [2;3;4];
  let reference = with_full_history true (fun () -> emit entry) in
  check bool "the history still emits" true (String.starts_with ~prefix:"ok\n" reference);
  check string "normal emission agrees" reference (with_full_history false (fun () -> emit entry));
  check bool "previews still work" true
    (not (String.starts_with ~prefix:"error" (with_full_history false (fun () -> preview_text root entry false)))))

(* Removing the frozen-checkpoint line shifts later source lines, so compare the
   checkpoint-free history against its own full-history build. *)
let without_checkpoints () = with_history (fun root path entry ->
  List.iter (fun version ->
    Sys.remove (checkpoint path version);
    let file = path (Printf.sprintf "migrations/scale/v%d.tesl" version) in
    write file (Str.global_replace (Str.regexp "# tesl:frozen-checkpoint [0-9a-f]+\n") "" (read file))) [2;3;4];
  let reference = with_full_history true (fun () -> emit entry) in
  check bool "the history emits without checkpoints" true (String.starts_with ~prefix:"ok\n" reference);
  check string "normal emission agrees without checkpoints" reference (with_full_history false (fun () -> emit entry));
  check string "previews agree without checkpoints"
    (with_full_history true (fun () -> preview_text root entry false))
    (with_full_history false (fun () -> preview_text root entry false));
  check bool "previews still work" true
    (not (String.starts_with ~prefix:"error" (with_full_history false (fun () -> preview_text root entry false)))))

let () = run "Migration checkpoints" [
  "written", [ test_case "Start writes sealed checkpoints" `Slow written ];
  "resume", [ test_case "a resumed prefix equals the complete fold" `Slow resume_equals_fold;
              test_case "a resumed capture agrees and cannot publish" `Slow resumed_capture ];
  "identity", [ test_case "normal and full-history outputs agree" `Slow identity ];
  "integrity", [ test_case "an edited checkpoint byte fails with MIG013" `Slow tampered;
                 test_case "full history refuses a stale checkpoint" `Slow stale_rejected_by_full_history ];
  "abi", [ test_case "another compiler's checkpoint is ignored" `Slow other_abi_ignored ];
  "compatibility", [ test_case "histories without checkpoints work" `Slow without_checkpoints ];
]
