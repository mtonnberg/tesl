open Alcotest
module H = Migration_row_history
module R = Migration_retained_storage
module D = Migration_declaration
module S = Migration_sparse
module I = Migration_inventory
module C = Migration_canonical
exception Rejected of S.error list
let get = function Ok x -> x | Error es -> fail (String.concat "\n" (List.map (fun (e:S.error)->e.message) es))
let rec mkdir p = if not(Sys.file_exists p) then (mkdir(Filename.dirname p);Unix.mkdir p 0o700)
let write p s = mkdir(Filename.dirname p);Out_channel.with_open_bin p (fun o->output_string o s)
let rec remove p = if (Unix.lstat p).Unix.st_kind=Unix.S_DIR then
 (Array.iter(fun n->remove(Filename.concat p n))(Sys.readdir p);Unix.rmdir p) else Sys.remove p
let name i count = "Schema.Drop." ^ if i=count then "VCurrent" else "V" ^ string_of_int i
let fixture bodies entries run =
 let root=Filename.temp_dir "tesl-table-drop-" "" in
 Fun.protect ~finally:(fun()->remove root) (fun()->
 write (Filename.concat root "tesl.toml") "";
 let count=List.length bodies in
 let schemas=List.mapi(fun index body ->
  let i=index+1 in let file=Filename.concat root (if i=count then "schema/drop/v-current.tesl" else Printf.sprintf "schema/drop/v%d.tesl" i) in
  write file (Printf.sprintf "module %s exposing []\nimport Tesl.Prelude exposing [String, Int]\nimport Tesl.Maybe exposing [Maybe(..)]\n%s\n" (name i count) body);file) bodies in
 let abi=match Migration_abi.current() with Ok x->Migration_abi.id x|Error e->fail e.message in
 let inventories=List.map(fun file->match I.load ~compiler_abi:abi ~root_file:file with Ok x->x|Error e->fail e.message) schemas in
 let seals=List.map(fun inventory->match Migration_seal.create ~project_root:root inventory with Ok x->x|Error e->fail e.message) inventories in
  let result = try
  let edges=List.mapi(fun index entry ->
  let version=index+2 in let file=Filename.concat root (Printf.sprintf "migrations/drop/v%d.tesl" version) in
  let previous=name (version-1) count and current=name version count in
  let header=get(Migration_header.create ~previous:(List.nth seals index) ~current:(List.nth seals(index+1))) in
  let body=Printf.sprintf {|module Schema.Drop.Migrate.V%d exposing [migration]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..)]
import %s
import %s
migration = Migration { from: %s, to: %s, same: [], fixtures: [], entities: { %s } }
|} version previous current previous current entry in
  let source=Migration_header.encode header ^ body in write file source;
  let source=if version<count then
    let closure=get(Migration_closure.capture ~project_root:root ~root_file:file ~source) in
    get(Migration_closure.attach ~file ~source closure) else source in
  write file source;
  let ast=match Parser.parse_module file source with Ok x->x|Err e->fail e.msg in
   match D.check ~compiler_abi:abi ~source ast with
   | Ok (Some x)->x | Ok None->fail "no migration" | Error errors->raise (Rejected errors)) entries in
  H.check ~schemas:inventories ~edges with Rejected errors -> Error errors in
  run result)
let note="entity Note table \"notes\" primaryKey id { id: String, title: String }\n"
let archive="entity Archive table \"archive\" primaryKey id { id: String, title: String }\n"
let indexed="entity Archive table \"archive\" primaryKey id { id: String, title: String\n index [title] as \"archive_title\" }\n"
let revision p n=List.find(fun(v:R.version)->v.version=n)(R.versions p)
let refuses message bodies edges ()=fixture bodies edges(function
 | Ok _->fail("accepted: "^message)
 | Error es->check bool (String.concat "\n" (List.map(fun(e:S.error)->e.message)es)) true
   (List.exists(fun(e:S.error)->e.code="MIG016" && Compile.string_contains e.message message)es))
let queue_refuses before after () = fixture [note^archive^before;note^after] ["Archive: Drop"] (function
 | Ok _ -> fail "accepted changed queue contract alongside Drop"
 | Error errors -> check bool "queue-specific refusal" true
   (List.exists (fun (e:S.error) -> Compile.string_contains e.message "queue") errors))
let proof_queue blocked = Printf.sprintf {|fact Valid (text: String)
establish validate(text: String) -> Maybe (value: String ::: Valid value) =
 if text != %S then
  Something (text ::: Valid text)
 else
  Nothing
record Payload { text: String ::: Valid text }
queueSchema Jobs { jobs: [Payload] }
|} blocked
let retained ()=fixture [note^indexed;note;note] ["Archive: Drop";""] (fun result->
 let history=get result in let p=get(R.plan history) in
 let before=revision p 1 and window=revision p 2 and next=revision p 3 in
 let old=List.find(fun(e:R.entity)->e.source.identity="Archive")before.entities in
 check bool "exact old physical table retained" true (window.retirements=[old]);
 check bool "no fictional row work" true (window.windows=[] && H.bindings history=[]);
 check int "no generation advance" 1 (List.hd window.retirements).source.generation;
 check int "both physical entities" 2 (List.length window.entities);
 check bool "current logical access refused" true (Result.is_error(R.project p ~version:2 ~entity:"Archive" ~logical_fields:["id";"title"]));
 let settled=get(R.settled_version p ~version:2) in
 check (list string) "only surviving table settled" ["Note"] (List.map(fun(e:R.entity)->e.source.identity)settled.entities);
 check (option int) "successor requires retirement Contract" (Some 2) next.requires_contract_version;
 check (list string) "successor omits contracted table" ["Note"] (List.map(fun(e:R.entity)->e.source.identity)next.entities);
 match Migration_retained_storage_canonical.version_node ~family:"Schema.Drop" ~namespace:"drop" p window with
 | C.Seq [C.Bytes "tesl-retained-physical-version-v5";_;_;_;_;_;C.Seq entities;C.Seq [];C.Seq [];C.Seq [C.Seq [C.Bytes "Archive";C.Bytes previous;C.Bytes current]]] ->
   let hash n=C.digest C.Snapshot (I.snapshot (List.find(fun(v:H.version)->v.version=n)(H.versions history)).schema) in
   check string "exact predecessor source hash" (hash 1) previous;
   check string "exact target source hash" (hash 2) current;
   check bool "all physical entities use explicit reverse shape" true (List.for_all(function C.Seq xs->List.length xs=10|_->false)entities)
 | _->fail "wrong exact table retirement wire shape")
let ()=run "Table Drop planning" ["boundaries",[
 test_case "indexed baseline table retained until Contract" `Quick retained;
 test_case "last entity refused" `Quick (refuses "last entity" [archive;""] ["Archive: Drop"]);
 test_case "new table on Drop edge refused" `Quick (refuses "unchanged surviving" [note^archive;note^"entity Extra table \"extra\" primaryKey id { id: String }"] ["Archive: Drop, Extra: New"]);
 test_case "changed survivor refused" `Quick (refuses "unchanged surviving" [note^archive;"entity Note table \"notes\" primaryKey id { id: String, title: String, extra: Maybe String }"] ["Archive: Drop, Note: Additive []"]);
 test_case "transformed survivor refused" `Quick (refuses "unchanged surviving" [note^archive;"entity Note table \"notes\" primaryKey id { id: String, renamed: String }"] ["Archive: Drop, Note: Derived [Rename title renamed]"]);
 test_case "multiple Drops refused" `Quick (refuses "exactly one" [note^archive^"entity Extra table \"extra\" primaryKey id { id: String }";note] ["Archive: Drop, Extra: Drop"]);
 test_case "unchanged queue survives unrelated Drop" `Quick (fun () ->
  let q="record Payload { text: String }\nqueueSchema Jobs { jobs: [Payload] }\n" in
  fixture [note^archive^q;note^q] ["Archive: Drop"] (fun result ->
   let history=get result in
   check int "historical descriptors retained" 2 (List.length (H.versions history));
   check int "one retirement" 1 (List.length (H.retirements history))));
 test_case "queue addition alongside Drop refused" `Quick (let q="record Payload { text: String }\nqueueSchema Jobs { jobs: [Payload] }\n" in refuses "unchanged historical queue" [note^archive;note^q] ["Archive: Drop"]);
 test_case "earlier queue membership change remains unsupported" `Quick (let q="record Payload { text: String }\nqueueSchema Jobs { jobs: [Payload] }\n" in refuses "unchanged historical queue" [note^archive;note^archive^q;note^q] ["";"Archive: Drop"]);
 test_case "queue removal alongside Drop refused" `Quick (queue_refuses "record Payload { text: String }\nqueueSchema Jobs { jobs: [Payload] }\n" "");
 test_case "payload shape change alongside Drop refused" `Quick (queue_refuses "record Payload { text: String }\nqueueSchema Jobs { jobs: [Payload] }\n" "record Payload { text: Int }\nqueueSchema Jobs { jobs: [Payload] }\n");
 test_case "payload proof dependency change alongside Drop refused" `Quick (queue_refuses (proof_queue "") (proof_queue "blocked"));
 test_case "previously transformed table refused" `Quick (refuses "previously transformed" [note^archive;note^"entity Archive table \"archive\" primaryKey id { id: String, renamed: String }";note] ["Archive: Derived [Rename title renamed]";"Archive: Drop"]);
 test_case "protected concurrent index lifecycle refused" `Quick (refuses "concurrent index" [note^archive;note^indexed;note] ["Archive: Additive []";"Archive: Drop"]);
 test_case "entity identity cannot restart" `Quick (refuses "restart a retained" [note^archive;note;note^archive] ["Archive: Drop";"Archive: New"]);
 test_case "retired table name cannot change owner" `Quick (refuses "reuse a retained table" [note^archive;note;note^"entity Replacement table \"archive\" primaryKey id { id: String }"] ["Archive: Drop";"Replacement: New"])
 ]]
