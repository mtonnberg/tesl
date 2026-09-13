open Alcotest
module C = Migration_canonical
module D = Migration_declaration
module S = Migration_sparse
module H = Migration_row_history
module R = Migration_retained_storage
module L = Migration_transform_link

let get = function
 | Ok value -> value
 | Error errors -> fail (String.concat "\n" (List.map
     (fun (e:S.error) -> e.code ^ ": " ^ e.message) errors))
let rec mkdir path = if not (Sys.file_exists path) then
 (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let write path source = mkdir (Filename.dirname path);
 Out_channel.with_open_bin path (fun channel -> output_string channel source)
let rec remove path = if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then
 (Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
  Unix.rmdir path) else Sys.remove path

let schema root extra = Printf.sprintf {|module %s exposing [Note, Task]
import Tesl.Prelude exposing [String, Int]
entity Note table "notes" primaryKey id { id: String, title: String%s }
entity Task table "tasks" primaryKey id { id: String, title: String%s }
|} root extra extra

let migration task_value = Printf.sprintf {|module Schema.Work.Migrate.V2 exposing [migration]
import Tesl.Prelude exposing [String, Int]
import Tesl.Migration exposing [Migration, Entity(..), Migrated(..)]
import Schema.Work.V1
import Schema.Work.VCurrent
migration = Migration {
  from: Schema.Work.V1, to: Schema.Work.VCurrent, same: [],
  fixtures: [oldNote, oldTask],
  entities: { Note: Migrate convertNote [], Task: Migrate convertTask [] }
}
fn convertNote(old: Schema.Work.V1.Note) -> Migrated Schema.Work.VCurrent.Note =
  Row (Schema.Work.VCurrent.Note { id: old.id, title: old.title, count: 7 })
fn convertTask(old: Schema.Work.V1.Task) -> Migrated Schema.Work.VCurrent.Task =
  Row (Schema.Work.VCurrent.Task { id: old.id, title: old.title, count: %d })
fn oldNote() -> Schema.Work.V1.Note = Schema.Work.V1.Note { id: "note", title: "note" }
fn oldTask() -> Schema.Work.V1.Task = Schema.Work.V1.Task { id: "task", title: "task" }
|} task_value

type observed = {
 rows : C.node list;
 identity : string;
 windows : (string * string) list;
 physical_without_behavior : C.node;
}

let observe root task_value =
 let before = Filename.concat root "schema/work/v1.tesl" in
 let after = Filename.concat root "schema/work/v-current.tesl" in
 let edge = Filename.concat root "migrations/work/v2.tesl" in
 write before (schema "Schema.Work.V1" "");
 write after (schema "Schema.Work.VCurrent" ", count: Int");
 let abi = match Migration_abi.current () with
  | Ok abi -> Migration_abi.id abi | Error e -> fail e.message in
 let seal path =
  let inventory = match Migration_inventory.load ~compiler_abi:abi ~root_file:path with
   | Ok inventory -> inventory | Error e -> fail e.message in
  match Migration_seal.create ~project_root:root inventory with
  | Ok seal -> seal | Error e -> fail e.message in
 let header = get (Migration_header.create ~previous:(seal before) ~current:(seal after)) in
 write edge (Migration_header.encode header ^ migration task_value);
 (* The public frontend must accept both entities and fixtures before any
    compiler-internal history/physical assertions are meaningful. *)
 List.iter (fun path ->
  let result = Compile.agent_context_result_source path (Source_input.read path) in
  let errors = List.filter (fun (d:Compile.diagnostic) -> d.severity = "error") result.diagnostics in
  if errors <> [] then fail (String.concat "\n" (List.map
   (fun (d:Compile.diagnostic) -> d.code ^ ": " ^ d.message) errors))) [before;after;edge];
 let source = Source_input.read edge in
 let ast = match Parser.parse_module edge source with
  | Ok ast -> ast | Err e -> fail e.msg in
 let declaration = match get (D.check ~compiler_abi:abi ~source ast) with
  | Some declaration -> declaration | None -> fail "missing migration" in
 let before,after = S.inventories (D.coverage declaration) in
 let history = get (H.check ~schemas:[before;after] ~edges:[declaration]) in
 let plan = get (R.plan history) in
 let version = List.find (fun (v:R.version) -> v.version = 2) (R.versions plan) in
 check int "two independently transformed entities" 2 (List.length version.windows);
 let links = List.map (fun (w:R.window) -> H.link w.binding) version.windows in
 let identity = L.behavior_digest (List.hd links) in
 List.iter (fun link -> check string "each binding retains the entire edge" identity
   (L.behavior_digest link)) links;
 let rows = match L.behavior (List.hd links) with
  | C.Seq [_;_;_;C.Seq rows;_] -> rows
  | _ -> fail "unexpected checked behavior shape" in
 check int "both callback closures participate" 2 (List.length rows);
 (* Inspect the actual serializer, not a test reconstruction of its hash. *)
 let physical = Migration_retained_storage_json.version_node
   ~family:"work" ~namespace:"work" plan version in
 let windows,physical_without_behavior = match physical with
  | C.Seq [tag;family;namespace;version;schema;storage;entities;C.Seq windows] ->
   let parsed = List.map (function
    | C.Seq [C.Bytes entity;old;current;floor;before;after;C.Bytes behavior;columns] ->
      (entity,behavior), C.Seq [C.Bytes entity;old;current;floor;before;after;columns]
    | _ -> fail "unexpected physical window shape") windows in
   List.map fst parsed,
   C.Seq [tag;family;namespace;version;schema;storage;entities;C.Seq (List.map snd parsed)]
  | _ -> fail "unexpected physical version shape" in
 check (list string) "complete emitted windows" ["Note";"Task"] (List.map fst windows);
 List.iter (fun (entity,hash) -> check string (entity ^ " serialized shared behavior")
   identity hash) windows;
 {rows;identity;windows;physical_without_behavior}

let second_callback_changes_every_window () =
 let root = Filename.temp_dir "tesl-behavior-multi-" "" in
 Fun.protect ~finally:(fun () -> remove root) (fun () ->
  write (Filename.concat root "tesl.toml") "";
  let initial = observe root 11 in
  let changed = observe root 12 in
  check bool "first callback and its fixture remain byte-identical" true
   (List.hd initial.rows = List.hd changed.rows);
  check bool "second callback alone changes" false
   (List.nth initial.rows 1 = List.nth changed.rows 1);
  check bool "schema, storage, physical layout and window lineage unchanged" true
   (initial.physical_without_behavior = changed.physical_without_behavior);
  check bool "second entity changes complete checked behavior" false
   (initial.identity = changed.identity);
  List.iter (fun (entity,before) ->
   check bool (entity ^ " window invalidated by second callback") false
    (before = List.assoc entity changed.windows)) initial.windows)

let () = run "Migration behavior across entities" ["binding",[
 test_case "second callback invalidates every physical window" `Quick second_callback_changes_every_window]]
