open Alcotest
module P = Migration_retained_storage
module RH = Migration_row_history
module D = Migration_declaration
module S = Migration_sparse
module C = Migration_canonical
let get = function Ok x -> x | Error errors ->
 fail (String.concat "\n" (List.map (fun (e:S.error) -> e.code ^ ": " ^ e.message) errors))
let rec mkdir p = if not (Sys.file_exists p) then (mkdir (Filename.dirname p);Unix.mkdir p 0o700)
let write p s = mkdir (Filename.dirname p);Out_channel.with_open_bin p (fun o -> output_string o s)
let rec remove p = if (Unix.lstat p).Unix.st_kind=Unix.S_DIR then
 (Array.iter (fun n -> remove (Filename.concat p n)) (Sys.readdir p);Unix.rmdir p) else Sys.remove p
let root_name i n = if i=n then "Schema.Notes.VCurrent" else "Schema.Notes.V" ^ string_of_int i
let schema table indexes root fields extra = Printf.sprintf {|module %s exposing [Note]
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
entity Note table %S primaryKey id { %s
%s }
%s
|} root table fields indexes extra
let migration i n before entry row =
 let previous=root_name (i-1) n and current=root_name i n in
 Printf.sprintf {|module Schema.Notes.Migrate.V%d exposing [migration]
import Tesl.Prelude exposing [String, Int]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..)]
import Tesl.Maybe exposing [Maybe(..)]
import %s
import %s
migration = Migration { from: %s, to: %s, same: [], fixtures: [%s], entities: { %s } }
%s
|} i previous current previous current (if row="" then "" else "oldNote") entry
 (if row="" then "" else Printf.sprintf "fn convert(old: %s.Note) -> Migrated %s.Note = Row (%s.Note { %s })\n" previous current current row ^
   Printf.sprintf "fn oldNote() -> %s.Note = %s.Note { %s }\n" previous previous
    (String.split_on_char ',' before |> List.map (fun field ->
      match String.split_on_char ':' field with
      | [name;typ] -> String.trim name ^ ": " ^ (match String.trim typ with
        | "String" -> "\"retained\"" | "Int" -> "3" | "Maybe String" -> "Nothing" | _ -> fail "fixture type unsupported")
      | _ -> fail "fixture field unsupported") |> String.concat ", "))
let fixture ?(extras=[]) ?(table="notes") ?(indexes=[]) fields edges f =
 let root=Filename.temp_dir "tesl-retained-storage-" "" in
 Fun.protect ~finally:(fun () -> remove root) (fun () ->
  write (Filename.concat root "tesl.toml") "";
  let n=List.length fields in
  let paths=List.mapi (fun index fields ->
   let i=index+1 in
   let path=Filename.concat root (if i=n then "schema/notes/v-current.tesl" else Printf.sprintf "schema/notes/v%d.tesl" i) in
   write path (schema table (Option.value ~default:"" (List.assoc_opt i indexes)) (root_name i n) fields (Option.value ~default:"" (List.assoc_opt i extras)));path) fields in
  let edge_paths=List.mapi (fun index (entry,row) ->
   let i=index+2 in
   let path=Filename.concat root (Printf.sprintf "migrations/notes/v%d.tesl" i) in
   write path (migration i n (List.nth fields (i-2)) entry row);path) edges in
  let abi=match Migration_abi.current () with Ok a -> Migration_abi.id a | Error e -> fail e.message in
  let seals=List.map (fun path ->
   let inventory=match Migration_inventory.load ~compiler_abi:abi ~root_file:path with Ok i -> i | Error e -> fail e.message in
   match Migration_seal.create ~project_root:root inventory with Ok s -> s | Error e -> fail e.message) paths in
  List.iteri (fun index path ->
   let header=get (Migration_header.create ~previous:(List.nth seals index) ~current:(List.nth seals (index+1))) in
   let source=Migration_header.encode header ^ Source_input.read path in
   let source=if index+2<n then
    let closure=get (Migration_closure.capture ~project_root:root ~root_file:path ~source) in
    get (Migration_closure.attach ~file:path ~source closure)
    else source in
   write path source) edge_paths;
  List.iter (fun path ->
   let result=Compile.agent_context_result_source path (Source_input.read path) in
   let errors=List.filter (fun (d:Compile.diagnostic) -> d.severity="error") result.diagnostics in
   if errors<>[] then fail (String.concat "\n" (List.map (fun (d:Compile.diagnostic) -> d.code ^ ": " ^ d.message) errors))) (paths@edge_paths);
  let abi=match Migration_abi.current () with Ok a -> Migration_abi.id a | Error e -> fail e.message in
  let edges=List.map (fun path ->
   let source=Source_input.read path in
   let ast=match Parser.parse_module path source with Ok m -> m | Err e -> fail e.msg in
   match get (D.check ~compiler_abi:abi ~source ast) with Some d -> d | None -> fail "no migration") edge_paths in
  let schemas=match edges with
   | [] -> [ (match Migration_inventory.load ~compiler_abi:abi ~root_file:(List.hd paths) with Ok i -> i | Error e -> fail e.message) ]
   | first::_ -> fst (S.inventories (D.coverage first)) :: List.map (fun d -> snd (S.inventories (D.coverage d))) edges in
  let history=get (RH.check ~schemas ~edges) in
  f root paths history)
let revision p n = List.find (fun (v:P.version) -> v.version=n) (P.versions p)
let note p n = List.find (fun (e:P.entity) -> e.source.identity="Note") (revision p n).entities
let column e name = List.find (fun (c:P.column) -> c.name=name) e.P.columns
let window p n = List.hd (revision p n).windows
let old = "id: String, author: String, title: String"
let fresh = "id: String, owner: String, title: String, count: Int"
let transform = "Note: Migrate convert [Rename author owner]", "id: old.id, owner: old.author, title: old.title, count: 7"
let transformed f = fixture [old;fresh] [transform] (fun root paths history -> f root paths history (get (P.plan history)))

let baseline () = fixture [old] [] (fun _ _ history ->
 let p=get (P.plan history) in let e=note p 1 in
 check int "baseline generation" 1 e.source.generation;
 check int "marker default" 1 e.marker_default_generation;
 check (list string) "complete physical columns" ["author";"id";"title"] (List.map (fun (c:P.column) -> c.name) e.columns);
 check bool "no invented nullable" false (column e "author").nullable;
 check bool "primary key" true (column e "id").primary_key;
 check int "no window" 0 (List.length (revision p 1).windows))
let rename () = transformed (fun _ _ _ p ->
 let before=note p 1 and after=note p 2 and w=window p 2 in
 check (list string) "retained old columns" ["author";"count";"id";"owner";"title"] (List.map (fun (c:P.column) -> c.name) after.columns);
 check bool "old remains required" false (column after "author").nullable;
 check bool "target NULL until marker" true (column after "owner").nullable;
 check bool "computed NULL until marker" true (column after "count").nullable;
 check bool "old catalog immutable" true ((column before "author")=(column after "author"));
 check int "generation increments" 2 after.source.generation;
 check int "old inserts stamp old generation" 1 after.marker_default_generation;
 check int "finality prerequisite" 1 w.requires_final_generation;
 check (list string) "invalidate complete predecessor" ["author";"id";"title"] (List.map (fun (c:P.column) -> c.name) w.invalidation_columns);
 check (list (pair string string)) "dual write actual old column" ["owner","author"] (List.map (fun (f,(c:P.column)) -> f,c.name) w.rename_dual_writes))
let projection_order () = transformed (fun _ _ _ p ->
 let projection=get (P.project p ~version:2 ~entity:"Note" ~logical_fields:["title";"id";"owner";"count"]) in
 check (list string) "requested order retained" ["title";"id";"owner";"count"]
  (List.map (fun (f:P.field) -> f.physical.name) (P.projection_fields projection));
 check int "correct owner generation" 2 (P.projection_entity projection).source.generation;
 let old=get (P.project p ~version:1 ~entity:"Note" ~logical_fields:["title";"author";"id"]) in
 check (list string) "predecessor exact layout" ["title";"author";"id"] (List.map (fun (f:P.field) -> f.physical.name) (P.projection_fields old)))
let projection_refusals () = transformed (fun _ _ _ p ->
 List.iter (fun fields -> match P.project p ~version:2 ~entity:"Note" ~logical_fields:fields with
 | Error _ -> () | Ok _ -> fail "invalid logical projection accepted")
  [[];["id";"owner"];["id";"id";"title";"count"];["id";"author";"title";"count"];["id";"owner";"title";"count";"author"]];
 List.iter (fun (version,entity) -> match P.project p ~version ~entity ~logical_fields:[] with
 | Error _ -> () | Ok _ -> fail "unknown owner accepted") [0,"Note";3,"Note";2,"Missing"])
let additive_tail () = fixture [old;fresh;fresh ^ ", note: Maybe String"]
 [transform;"Note: Additive []",""] (fun _ _ h ->
 let p=get (P.plan h) in let e=note p 3 in
 check int "additive retains generation" 2 e.source.generation;
 check int "additive retains insert default" 1 e.marker_default_generation;
 check bool "prior target still physically nullable" true (column e "count").nullable;
 check bool "optional nullable" true (column e "note").nullable;
 check int "birth not schema generation" 3 (column e "note").introduced_version;
 check (list (pair string string)) "additive preserves required legacy writes" ["owner","author"] (List.map (fun (f,(c:P.column)) -> f,c.name) e.rename_dual_writes);
 check int "no additive window" 0 (List.length (revision p 3).windows))
let two_transforms () = fixture [old;fresh;"id: String, editor: String, title: String, count: Int"]
 [transform;"Note: Migrate convert [Rename owner editor]","id: old.id, editor: old.owner, title: old.title, count: old.count"]
 (fun _ _ h -> let p=get (P.plan h) in let w=window p 3 in
 check int "next window requires previous finality" 2 w.requires_final_generation;
 check int "next default follows predecessor generation" 2 w.after.marker_default_generation;
 check int "target generation" 3 w.after.source.generation;
 check (option int) "explicit predecessor contraction prerequisite" (Some 2) (revision p 3).requires_contract_version;
 check bool "contracted oldest physical data removed from next window" false (List.exists (fun (c:P.column) -> c.name="author") w.after.columns);
 check (list (pair string string)) "only admitted predecessor alias remains after required contract" ["editor","owner"] (List.map (fun (f,(c:P.column)) -> f,c.name) w.rename_dual_writes))
let alias_chain_through_additive () = fixture
 [old;fresh;fresh ^ ", note: Maybe String";
  "id: String, editor: String, title: String, count: Int, note: Maybe String";
  "id: String, editor: String, title: String, count: Int, note: Maybe String, extra: Maybe String"]
 [transform;"Note: Additive []","";
  "Note: Migrate convert [Rename owner editor]","id: old.id, editor: old.owner, title: old.title, count: old.count, note: old.note";
  "Note: Additive []",""]
 (fun _ _ h -> let p=get (P.plan h) in
  List.iter (fun n -> let e=note p n in
   check (list (pair string string)) "current window alias survives following additive revision"
    ["editor","owner"] (List.map (fun (f,(c:P.column)) -> f,c.name) e.rename_dual_writes);
   check bool "contracted oldest column has no write obligation" false (List.exists (fun (c:P.column) -> c.name="author") e.columns)) [4;5];
  check (option int) "additive tail uses actual last transforming contract" (Some 2) (revision p 4).requires_contract_version;
  check (option int) "additive revision has no invented contract" None (revision p 5).requires_contract_version;
  check int "additive revision has no separate window" 0 (List.length (revision p 5).windows))
let unrelated_rename_keeps_aliases () = fixture
 [old;fresh;"id: String, owner: String, heading: String, count: Int";
  "id: String, editor: String, heading: String, count: Int"]
 [transform;
  "Note: Migrate convert [Rename title heading]","id: old.id, owner: old.owner, heading: old.title, count: old.count";
  "Note: Migrate convert [Rename owner editor]","id: old.id, editor: old.owner, heading: old.heading, count: old.count"]
 (fun _ _ h -> let p=get (P.plan h) in
  check (list (pair string string)) "next window discards aliases of required contracted predecessor"
   ["heading","title"] (List.map (fun (f,(c:P.column)) -> f,c.name) (note p 3).rename_dual_writes);
  let e=note p 4 in
  check (list (pair string string)) "independent chains do not duplicate or cross owners"
   ["editor","owner"] (List.map (fun (f,(c:P.column)) -> f,c.name) e.rename_dual_writes);
  check bool "window publishes complete entity obligations" true ((window p 4).rename_dual_writes=e.rename_dual_writes))
let additive_default () = fixture [old;old ^ ", priority: Int";fresh ^ ", priority: Int"]
 ["Note: Additive [Default priority 9]","";
  "Note: Migrate convert [Rename author owner]","id: old.id, owner: old.author, title: old.title, count: 7, priority: old.priority"]
 (fun _ _ h -> let p=get (P.plan h) in
 let c=column (note p 3) "priority" in
 check bool "checked default retained" true (c.default=Migration_expansion.Constant (C.Seq [C.Bytes "int";C.Bytes "9"]));
 check bool "additive requiredness retained" false c.nullable;
 check int "introducing revision retained" 2 c.introduced_version;
 check int "transform is generation two despite V3" 2 (note p 3).source.generation)
let reuse () = fixture [old;fresh;"id: String, author: String, title: String, count: Int"]
 [transform;"Note: Migrate convert [Rename owner author]","id: old.id, author: old.owner, title: old.title, count: old.count"]
 (fun _ _ h -> let p=get (P.plan h) in
  check (option int) "reclaimed name requires exact earlier contract" (Some 2) (revision p 3).requires_contract_version;
  check int "reclaimed physical name has new introduction" 3 (column (note p 3) "author").introduced_version;
  check (list (pair string string)) "reclaimed name does not borrow retired alias" ["author","owner"]
   (List.map (fun (f,(c:P.column)) -> f,c.name) (note p 3).rename_dual_writes))

let source_guard () = transformed (fun _ paths history _ ->
 let file=List.hd paths in write file (Source_input.read file ^ "\n# after source checking\n");
 match P.plan history with Error _ -> () | Ok _ -> fail "stale callback source retained its plan")

let independent_entity () =
 let session="entity Session table \"sessions\" primaryKey id { id: String }\n" in
 fixture ~extras:[1,session;2,session;3,session ^ "entity Added table \"added\" primaryKey id { id: String }\n"]
  [old;fresh;fresh] [transform;"Added: New",""] (fun _ _ h ->
   let p=get (P.plan h) in
   List.iter (fun n -> let e=List.find (fun (e:P.entity) -> e.source.identity="Session") (revision p n).entities in
    check int "unaffected entity generation" 1 e.source.generation;
    check int "unaffected marker default" 1 e.marker_default_generation) [1;2;3];
   let e=List.find (fun (e:P.entity) -> e.source.identity="Added") (revision p 3).entities in
   check int "new entity starts at generation one" 1 e.source.generation;
   check int "new entity birth version" 3 (column e "id").introduced_version)
let quoted_and_normalized () = fixture ~table:"notes \"live\"" ["id: String, displayName: String"] [] (fun _ _ h ->
 let p=get (P.plan h) in
 let projection=get (P.project p ~version:1 ~entity:"Note" ~logical_fields:["displayName";"id"]) in
 check string "quoted table bytes retained" "notes \"live\"" (P.projection_entity projection).source.table.name;
 check (list string) "logical names are not guessed SQL names" ["display_name";"id"]
  (List.map (fun (f:P.field) -> f.physical.name) (P.projection_fields projection)))
let transform_default () = fixture [old;fresh]
 ["Note: Migrate convert [Rename author owner, Default count 7]",snd transform]
 (fun _ _ h -> let p=get (P.plan h) in
  check bool "row default is not an installed SQL default" true ((column (note p 2) "count").default=Migration_expansion.Null);
  check bool "row default remains behind marker" true (column (note p 2) "count").nullable)
let retained_index () = fixture ~indexes:[1,"index [title] as \"title_historical\""] [old;fresh] [transform]
 (fun _ _ h -> let p=get (P.plan h) in
  check (list string) "historical index retained until contract" ["title_historical"]
   (List.map (fun (i:Migration_storage.index) -> i.name) (note p 2).indexes))
let index_replacement () = fixture ~indexes:[1,"index [title] as \"shared\"";2,"index [owner] as \"shared\""] [old;fresh] [transform]
 (fun _ _ h -> match P.plan h with
 | Error errors -> check bool "exact index identity refusal" true
   (List.exists (fun (e:S.error) -> Compile.string_contains e.message "retained index definition cannot be replaced: shared") errors)
 | Ok _ -> fail "retained index name silently changed definition")
let primary_index_collision () = fixture ~indexes:[1,"index [title] as \"notes_pkey\""] [old] []
 (fun _ _ h -> match P.plan h with
 | Error errors -> check bool "primary index reserves namespace" true
   (List.exists (fun (e:S.error) -> Compile.string_contains e.message "relation name cannot be reused: notes_pkey") errors)
 | Ok _ -> fail "implicit primary index name silently reused")

let () = Alcotest.run "Retained row storage" ["physical lineage",[
 test_case "baseline permanent marker contract" `Quick baseline;
 test_case "rename and computed columns coexist" `Quick rename;
 test_case "logical order is explicit" `Quick projection_order;
 test_case "projection completeness and owner refusals" `Quick projection_refusals;
 test_case "additive tail retains physical history" `Quick additive_tail;
 test_case "adjacent transforms require predecessor finality" `Quick two_transforms;
 test_case "contract prerequisite crosses additive revisions" `Quick alias_chain_through_additive;
 test_case "new windows drop only contracted alias obligations" `Quick unrelated_rename_keeps_aliases;
 test_case "additive SQL default survives later transformation" `Quick additive_default;
 test_case "old field name reuse requires prior contract and new provenance" `Quick reuse;
 test_case "linked source guard remains required" `Quick source_guard;
 test_case "unaffected and newly born entities retain generation one" `Quick independent_entity;
 test_case "quoted table and normalized column names" `Quick quoted_and_normalized;
 test_case "transform Default remains marker-aware" `Quick transform_default;
 test_case "historical index retained until contract" `Quick retained_index;
 test_case "retained index identity cannot be replaced" `Quick index_replacement;
 test_case "implicit primary index reserves relation name" `Quick primary_index_collision]]
