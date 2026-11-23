(* Revalidation after a change of stored-value semantics.

   The history below is sealed under the real stdlib (the v1 baseline
   identity). The tests then point the compiler at a copy of the stdlib:
   - a comment-only edit keeps the identity, so nothing needs revalidation;
   - a semantic edit changes the identity: ordinary checking and the build
     report MIG013 with the revalidate command, and revalidation re-records the
     seals, frame blocks and checkpoints, after which both pass again;
   - a semantic edit that breaks a frozen migration makes revalidation refuse
     without proposing any edit;
   - an edited frozen source is never re-sealed. *)
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
import Tesl.List exposing [List.length]
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

let rename ?(list=false) version fields ~old ~fresh = migration version (Printf.sprintf {|migration = Migration {
 from: Schema.Scale.V%d
 to: Schema.Scale.VCurrent
 same: []
 entities: { Alpha: Migrate convertAlpha [Rename %s %s] }
 fixtures: [fixtureAlpha]
}
fn convertAlpha(old: Schema.Scale.V%d.Alpha) -> Migrated Schema.Scale.VCurrent.Alpha =
  %sRow (Schema.Scale.VCurrent.Alpha { %s })
fn fixtureAlpha() -> Schema.Scale.V%d.Alpha = Schema.Scale.V%d.makeAlpha "fixture"
|} (version-1) old fresh (version-1)
  (if list then "if List.length [1, 2] == 3 then\n    Reject \"impossible\"\n  else\n    " else "")
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
  revision 3 v3 (rename ~list:true 3 v3 ~old:"o2" ~fresh:"r3");
  apply (contract root entry 3);
  revision 4 v4 (additive 4);
  revision 5 v5 (rename 5 v5 ~old:"o4" ~fresh:"r5");
  apply (contract root entry 5);
  f root path entry)


let originals () = List.map (fun (name,base) ->
  match Validation_common.lifted_stdlib_source_path name with
  | Some file -> base,read file | None -> fail name) Validation_common.lifted_stdlib_sources

(* Run [f] with the compiler reading a stdlib copy changed by [edit]. *)
let with_stdlib edit f =
  let sources = originals () in
  with_temp (fun directory ->
    List.iter (fun (name,source) -> write (Filename.concat directory name) (edit name source)) sources;
    let previous = Sys.getenv_opt "TESL_STDLIB_DIR" in
    Unix.putenv "TESL_STDLIB_DIR" directory;
    Fun.protect ~finally:(fun () -> Unix.putenv "TESL_STDLIB_DIR" (Option.value previous ~default:"")) f)

let comment name source = if name = "either.tesl" then source ^ "\n# reworded documentation\n" else source
let semantic name source = if name = "either.tesl" then source ^ "\nfn revalidationProbe(x: Int) -> Int = x\n" else source
let breaking name source = if name = "list.tesl" then
  replace "fn length(xs: List a) -> Int =" "fn length(xs: List a) -> String =" source else source

let identity () = Migration_abi.stored_value_compatibility (Result.get_ok (Migration_abi.current ()))
let revalidate root entry = Migration_program.with_compilation_cache (fun () ->
  Migration_preview.generate_reseal ~project_root:root ~entry_file:entry ~database:None ~documents:[])
let snapshot path = List.map (fun name -> name,read (path name))
  ["migrations/scale/v2.tesl";"migrations/scale/v3.tesl";"migrations/scale/v4.tesl";"migrations/scale/v5.tesl";
   "migrations/scale/v2.checkpoint";"migrations/scale/v3.checkpoint";"migrations/scale/v4.checkpoint"]

let comment_only () = with_history (fun _ path entry ->
  let baseline = identity () in
  let before = snapshot path in
  with_stdlib comment (fun () ->
    check string "a comment-only stdlib edit keeps the identity" baseline (identity ());
    check bool "the application checks without MIG013" false (contains (check_file entry) "MIG013");
    let built = with_full_history true (fun () -> emit entry) in
    check bool ("the production build still succeeds:\n" ^ built) true (String.starts_with ~prefix:"ok\n" built));
  check bool "no source changed" true (before = snapshot path))

let revalidates () = with_history (fun root path entry ->
  let baseline = identity () in
  with_stdlib semantic (fun () ->
    let changed = identity () in
    check bool "a semantic stdlib edit changes the identity" false (baseline = changed);
    let diagnostics = check_file entry in
    check bool ("ordinary checking reports MIG013:\n" ^ diagnostics) true (contains diagnostics "MIG013");
    check bool "it names the module that changed" true (contains diagnostics "stdlib module either.tesl changed declarations");
    check bool "it names the command" true (contains diagnostics "tesl migrate reseal");
    let built = emit entry in
    check bool ("the production build refuses:\n" ^ built) true
      (String.starts_with ~prefix:"failed\n" built && contains built "tesl migrate reseal");
    let before = snapshot path in
    let preview = match revalidate root entry with
      | Ok preview -> preview | Error errors -> fail (preview_errors errors) in
    check bool "revalidation is a preview" true (before = snapshot path);
    let json = Migration_preview.to_json preview in
    check bool "the preview reports the operation" true (contains json "\"operation\":\"reseal\"");
    check bool "the preview names both identities" true (contains json baseline && contains json changed);
    let edited = List.map (fun (e:Migration_manifest.edit) -> Filename.basename e.path)
      (Migration_manifest.edits (Migration_preview.manifest preview)) |> List.sort compare in
    check (list string) "only seals, frozen-source blocks and checkpoints change"
      ["v2.checkpoint";"v2.tesl";"v3.checkpoint";"v3.tesl";"v4.checkpoint";"v4.tesl";"v5.tesl"] edited;
    List.iter (fun (e:Migration_manifest.edit) -> write e.path e.after) (Migration_manifest.edits (Migration_preview.manifest preview));
    List.iter (fun file ->
      check bool (file ^ " records the new identity") true (contains (read (path file)) changed);
      check bool (file ^ " no longer records the old one") false (contains (read (path file)) baseline))
      ["migrations/scale/v2.tesl";"migrations/scale/v5.tesl";"migrations/scale/v3.checkpoint"];
    check bool "the application checks clean" false (contains (check_file entry) "error");
    List.iter (fun full ->
      let built = with_full_history full (fun () -> emit entry) in
      check bool ("the build succeeds again:\n" ^ built) true (String.starts_with ~prefix:"ok\n" built)) [true;false];
    match revalidate root entry with
    | Ok _ -> fail "a second revalidation proposed edits"
    | Error errors -> check bool "nothing left to revalidate" true (contains (preview_errors errors) "nothing to re-seal"));
  (* Back on the original stdlib, the re-recorded seals are now the foreign ones. *)
  check bool "the original compiler now needs revalidation in turn" true (contains (check_file entry) "tesl migrate reseal"))

let refuses_failing_history () = with_history (fun root path entry ->
  with_stdlib breaking (fun () ->
    let before = snapshot path in
    (match revalidate root entry with
     | Ok _ -> fail "revalidation accepted a history that no longer checks"
     | Error errors ->
       let text = preview_errors errors in
       check bool ("the refusal explains why:\n" ^ text) true
         (contains text "does not check under the new stored-value semantics"));
    check bool "nothing was written" true (before = snapshot path)))

let refuses_edited_source () = with_history (fun root path entry ->
  let frozen = path "schema/scale/v2.tesl" in
  write frozen (read frozen ^ "# edited after freezing\n");
  with_stdlib semantic (fun () ->
    match revalidate root entry with
    | Ok _ -> fail "revalidation re-sealed an edited frozen source"
    | Error errors -> check bool "the refusal asks to restore the recorded source" true
        (contains (preview_errors errors) "restore the recorded source")))

let command_line () = with_history (fun _ _ entry ->
  let run args = Migration_command.run args in
  let refused = run ["reseal";entry;"--manifest-json";"--new-revision"] in
  check int "revalidate refuses unrelated options" 1 refused.exit_code;
  let help = run ["reseal";"--help"] in
  check bool "usage names revalidate" true (contains help.stdout "tesl migrate reseal");
  with_stdlib semantic (fun () ->
    let result = run ["reseal";entry;"--manifest-json"] in
    check int ("the compiler verb previews:\n" ^ result.stdout) 0 result.exit_code;
    check bool "it reports the stored-value identities" true (contains result.stdout "\"reseal\"")))

let trusted entry =
  Migration_trust.reset_trusted_roots ();
  let built = with_full_history false (fun () -> emit entry) in
  check bool ("the build succeeds:\n" ^ built) true (String.starts_with ~prefix:"ok\n" built);
  List.sort_uniq compare (Migration_trust.trusted_roots ())

(* A compiler upgrade that keeps the stored-value identity (here: a comment-only
   stdlib edit, which changes the compiler ABI) leaves old seals untrusted until
   they are re-sealed; the result equals what a fresh freeze would record. *)
let reseal_after_abi_change () =
  let fresh = with_stdlib comment (fun () -> with_history (fun _ path _ -> snapshot path)) in
  with_history (fun root path entry ->
    let completed = ["Schema.Scale.Migrate.V2";"Schema.Scale.Migrate.V3";"Schema.Scale.Migrate.V4"] in
    check (list string) "the sealing compiler trusts its history" completed (trusted entry);
    with_stdlib comment (fun () ->
      check (list string) "another compiler build trusts nothing" [] (trusted entry);
      let diagnostics = check_file entry in
      check bool ("ordinary checking suggests re-sealing:\n" ^ diagnostics) true
        (contains diagnostics "warning MIG033" && contains diagnostics "tesl migrate reseal");
      check bool "it is not an error" false (contains diagnostics " error ");
      let preview = match revalidate root entry with
        | Ok preview -> preview | Error errors -> fail (preview_errors errors) in
      List.iter (fun (e:Migration_manifest.edit) -> write e.path e.after) (Migration_manifest.edits (Migration_preview.manifest preview));
      check (list string) "re-sealed revisions are trusted again" completed (trusted entry);
      check bool "the suggestion is gone" false (contains (check_file entry) "MIG033");
      List.iter2 (fun (name,expected) (_,actual) ->
        check string (name ^ " equals a fresh freeze under this compiler") expected actual) fresh (snapshot path);
      (* Tampering is still caught after re-sealing. *)
      let frozen = path "schema/scale/v3.tesl" in
      write frozen (read frozen ^ "# edited after re-sealing\n");
      check bool "an edited frozen byte fails the build" true (contains (emit entry) "MIG013")))

let () = run "Stored-value revalidation" [
  "identity", [ test_case "a comment-only stdlib edit needs no revalidation" `Slow comment_only ];
  "reseal", [ test_case "a semantic edit is revalidated and re-sealed" `Slow revalidates;
                  test_case "a history that no longer checks is refused" `Slow refuses_failing_history;
                  test_case "an edited frozen source is never re-sealed" `Slow refuses_edited_source;
                  test_case "compiler command line" `Slow command_line ];
  "compiler-abi", [ test_case "a new compiler ABI is re-sealed and trusted again" `Slow reseal_after_abi_change ];
]
