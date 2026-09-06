open Alcotest
module P = Migration_plan
module G = Migration_preview
module M = Migration_manifest
let rec mkdir p = if not (Sys.file_exists p) then (mkdir (Filename.dirname p);Unix.mkdir p 0o700)
let rec remove p = if (Unix.lstat p).Unix.st_kind=Unix.S_DIR then
 (Array.iter (fun n -> remove (Filename.concat p n)) (Sys.readdir p);Unix.rmdir p) else Sys.remove p
let read p = In_channel.with_open_bin p In_channel.input_all
let write p source = mkdir (Filename.dirname p);Out_channel.with_open_bin p (fun out -> output_string out source)
let inspect p = ignore (Compile.agent_context_result_source p (read p))
let save p source = write p source;inspect p
let replace a b = Str.global_substitute (Str.regexp_string a) (fun _ -> b)
let get = function Ok x -> x | Error es -> fail (String.concat "\n" (List.map (fun (e : Migration_sparse.error) -> e.code ^ ": " ^ e.message) es))
let refused code = function
 | Error es -> check bool (String.concat "\n" (List.map (fun (e : Migration_sparse.error) -> e.message) es)) true
   (List.exists (fun (e : Migration_sparse.error) -> e.code=code) es)
 | Ok _ -> fail ("expected " ^ code)
let schema = {|module NotesSchema.VCurrent exposing [Note]
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
entity Note table "notes" primaryKey id { id: String }
|}
let app = {|module App exposing []
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import NotesSchema.VCurrent
database Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate,
 backend: Postgres (PostgresConfig { dbName: "notes", user: "tesl", password: "", namespace: "notes_app",
 connection: TcpConnection { host: "127.0.0.1", port: 5432 } }) }
|}
let with_project ?(initial=schema) f =
 let root = Filename.temp_file "tesl-plan-" ".dir" in Sys.remove root;Unix.mkdir root 0o700;
 Fun.protect ~finally:(fun () -> remove root) (fun () ->
  let path = Filename.concat root in
  write (path "tesl.toml") "";save (path "schema/notes/v-current.tesl") initial;save (path "app.tesl") app;
  f root path)
let plan ?(documents=[]) ?(initial_version=1) root = P.generate ~project_root:root ~entry_file:(Filename.concat root "app.tesl") ~database:None ~initial_version ~documents
let generate ?(next=false) root =
 let p = match G.generate ~project_root:root ~entry_file:(Filename.concat root "app.tesl") ~database:None ~new_revision:next ~documents:[] with
  | Ok p -> p | Error es -> fail (String.concat "\n" (List.map (fun (e : G.error) -> e.message) es)) in
 List.iter (fun (e : M.edit) -> write e.path e.after) (M.edits (G.manifest p));
 List.iter (fun (e : M.edit) -> inspect e.path) (M.edits (G.manifest p))
let last p = List.hd (List.rev (P.steps p))
let edit_schema path f = let p = path "schema/notes/v-current.tesl" in save p (f (read p))
let append_field source field = replace "id: String" ("id: String, " ^ field) source
let added p = (last p).P.operations |> List.filter_map (function P.Add_column x -> Some (x.column.name,x.default) | _ -> None)
let new_indexes p = (last p).P.operations |> List.filter_map (function P.Build_index x -> Some (x.index,x.window_risk) | _ -> None)
let set_entities path version entities =
 let file = path (Printf.sprintf "migrations/notes/v%d.tesl" version) in
 let source = read file in
 let view = match Migration_source_syntax.read ~file ~source with Ok v -> v | Error e -> fail e.message in
 let syntax = match Migration_declaration.read_syntax (Migration_source_syntax.module_ view) with Ok (Some s) -> s | _ -> fail "fixture syntax" in
 let range = match Migration_source_syntax.collection_range view syntax.entities with Ok r -> r | Error e -> fail e.message in
 let source = match Migration_source_syntax.replace view [range,entities] with Ok s -> s | Error e -> fail e.message in
 save file source
let baseline () = with_project (fun root path ->
 let p = get (plan root) in
 check int "initial revision" 1 (last p).version;
 check bool "new table" true (match (last p).operations with [P.Create_table t] -> t.name="notes" | _ -> false);
 check bool "read-only report" true (Compile.string_contains (P.to_json p) "\"executable\":false");
 check bool "no source generation" false (Sys.file_exists (path "migrations"));
 check string "stable identity" (P.digest p) (P.digest (get (plan root)));
 save (path "app.tesl") (replace "notes_app" "other_app" app);
 check bool "namespace is part of plan identity" true (P.digest p<>P.digest (get (plan root))))
let additive_chain () = with_project (fun root path ->
 generate root;
 edit_schema path (fun s -> append_field s "caption: Maybe String");generate root;
 let p = get (plan root) in
 check bool "Nothing is the physical NULL source" true (added p=["caption",P.Null]);
 let prior_steps = List.map Migration_expansion.step_node (P.steps p) in
 generate ~next:true root;
 edit_schema path (fun s -> append_field s "active: Maybe Bool");generate root;
 let p = get (plan root) in
 check bool "frozen prior steps keep their canonical execution identity" true
  (prior_steps=List.map Migration_expansion.step_node (List.filter (fun (s : P.step) -> s.version<=2) (P.steps p)));
 check (list int) "complete history" [1;2;3] (List.map (fun (s : P.step) -> s.version) (P.steps p));
 check (list int) "physical catalog at every version" [1;2;3]
  (List.map (fun (s : P.step) -> List.length (List.hd s.catalog).columns) (P.steps p));
 check (list string) "all retained columns" ["active";"caption";"id"]
  (List.map (fun (c : P.catalog_column) -> c.column.name) (List.hd (last p).catalog).columns);
 check bool "later delta excludes predecessor column" true (added p=["active",P.Null]);
 check bool "every step preserves epoch" true (List.for_all (fun (s : P.step) -> s.epoch_preserving) (P.steps p));
 List.iter (fun initial_version ->
  let born = get (plan ~initial_version root) in
  check (list int) "selected initial revision and subsequent history"
   (List.init (4-initial_version) (fun i -> initial_version+i))
   (List.map (fun (s : P.step) -> s.version) (P.steps born));
  check bool "initial baseline creates the selected declared schema" true
   (match (List.hd (P.steps born)).operations with [P.Create_table t] -> List.length t.columns=initial_version | _ -> false);
  check bool "initial version binds plan identity" true (P.digest born<>P.digest p);
  check string "deterministic origin-specific plan" (P.to_json born) (P.to_json (get (plan ~initial_version root)));
  check bool "origin is reported" true (Compile.string_contains (P.to_json born) ("\"initialVersion\":" ^ string_of_int initial_version))) [2;3];
 check string "application unchanged" app (read (path "app.tesl")))
let defaults () = with_project (fun root path ->
 generate root;edit_schema path (fun s -> append_field s "rank: Int, label: String");generate root;
 set_entities path 2 "{ Note: Additive [Default rank 42, Default label \"å'\\\\\"] }";
 (* The generated module already exposes Rule(..), including Default. *)
 let p = get (plan root) in
 check int "both constants planned" 2 (List.length (added p));
 check bool "exact primitive integer" true (List.mem ("rank",P.Constant (Result.get_ok (Migration_canonical.integer "42"))) (added p));
 check bool "exact escaped string" true (List.mem ("label",P.Constant (Migration_canonical.string "å'\\")) (added p));
 let constants = List.filter_map (fun (c : P.catalog_column) -> match c.default with
   P.Null -> None | value -> Some (c.column.name,value)) (List.hd (last p).catalog).columns in
 check bool "projection retains exact defaults" true (List.sort compare constants=List.sort compare (added p));
 generate ~next:true root;
 let next = get (plan root) in
 let physical step = List.map (fun (t : P.catalog_table) -> t.name,
   List.map (fun (c : P.catalog_column) -> c.column.name,c.column.scalar,c.column.nullable,c.column.primary_key,c.default) t.columns,
   t.indexes) step.P.catalog in
 check bool "default contract survives unchanged later revision" true (physical (last next)=physical (last p));
 List.iter (fun initial_version ->
  let born = get (plan ~initial_version root) in
  check bool "new installation does not inherit a previous version's omission adapters" true
   (List.for_all (fun (step : P.step) -> List.for_all (fun (t : P.catalog_table) ->
     List.for_all (fun (c : P.catalog_column) -> c.default=P.Null) t.columns) step.catalog) (P.steps born))) [2;3];
 check int "earlier projection remains immutable" 1
  (List.length (List.hd (List.hd (P.steps next)).catalog).columns))
let new_table () = with_project (fun root path ->
 generate root;
 edit_schema path (fun s -> s ^ "entity Tag table \"tags\" primaryKey id { id: String, name: String\n unique index [name]\n}\n");generate root;
 let p = get (plan root) in
 check bool "new table creates its indexes before admission" true (match (last p).operations with
  [P.Create_table t] -> t.name="tags" && List.length t.indexes=1 | _ -> false))
let retained_drop () = with_project (fun root path ->
 generate root;
 edit_schema path (replace "entity Note table \"notes\" primaryKey id { id: String }" "");
 edit_schema path (replace "exposing [Note]" "exposing []");generate root;
 let p = get (plan root) in
 check bool "drop retains physical table" true ((last p).operations=[P.Retain_table "notes"]);
 check bool "dropped storage remains in catalog" true ((last p).catalog=(List.hd (P.steps p)).catalog);
 let born = get (plan ~initial_version:2 root) in
 check bool "later installation never creates already dropped storage" true
  ((last born).catalog=[] && (last born).operations=[]);
 generate ~next:true root;
 edit_schema path (fun s -> s ^ "entity Replacement table \"notes\" primaryKey id { id: String }\n");generate root;
 List.iter (fun initial_version -> refused "MIG016" (plan ~initial_version root)) [1;2;3])
let index_case initial change risk = with_project ~initial (fun root path ->
 generate root;edit_schema path change;generate root;
 let p = get (plan root) in
 let indexes = new_indexes p in check int "one concurrent build" 1 (List.length indexes);
 let index,reason = List.hd indexes in
 check bool "versioned physical name" true (String.ends_with ~suffix:"__v2" index.name);
 check bool "catalog carries allocated index name" true
  (List.mem index (List.hd (last p).catalog).indexes);
 check bool "classified window risk" risk (reason<>None);
 check bool "epoch classification" (not risk) (last p).epoch_preserving)
let old_text_index () = index_case (append_field schema "label: String")
 (replace "label: String }" "label: String\n index [label]\n}") true
let old_fixed_index () = index_case (append_field schema "active: Bool")
 (replace "active: Bool }" "active: Bool\n index [active]\n}") false
let old_unique_index () = index_case (append_field schema "active: Bool")
 (replace "active: Bool }" "active: Bool\n unique index [active]\n}") true
let new_nullable_unique () = index_case schema
 (replace "id: String }" "id: String, key: Maybe String\n unique index [key]\n}") false
let mixed_unique () = index_case schema
 (replace "id: String }" "id: String, key: Maybe String\n unique index [key, id]\n}") true
let previously_added_column () = with_project (fun root path ->
 generate root;edit_schema path (fun s -> append_field s "key: Maybe String");generate root;
 generate ~next:true root;edit_schema path (replace "key: Maybe String }" "key: Maybe String\n unique index [key]\n}");generate root;
 List.iter (fun initial_version ->
  let p = get (plan ~initial_version root) in
  check bool "earlier admitted writer names key" true (snd (List.hd (new_indexes p))<>None)) [1;2])
let retained_index () = with_project ~initial:(replace "label: String }" "label: String\n index [label] as \"old_index\"\n}" (append_field schema "label: String")) (fun root path ->
 generate root;edit_schema path (replace "index [label] as \"old_index\"" "");generate root;
 let p = get (plan root) in
 check bool "removed index remains" true (match (last p).operations with [P.Retain_index x] -> x.index.name="old_index" | _ -> false);
 check bool "retained unbounded index constrains target writes" false (last p).epoch_preserving;
 generate ~next:true root;
 check bool "unchanged edge does not repeat a prior removal" true ((last (get (plan root))).operations=[]);
 edit_schema path (replace "label: String\n" "label: String\n index [label] as \"renamed_index\"\n");generate root;
 let p = get (plan root) in
 check int "equivalent retained index reused" 0 (List.length (new_indexes p));
 check (list string) "projection keeps the original physical index" ["old_index"]
  (List.map (fun (i : Migration_storage.index) -> i.name) (List.hd (last p).catalog).indexes);
 let born2 = get (plan ~initial_version:2 root) in
 check bool "index did not exist at installation" true ((List.hd (List.hd (P.steps born2)).catalog).indexes=[]);
 check bool "reintroduced index must build and classify old-writer risk" true (match new_indexes born2 with
  [index,Some _] -> index.name="renamed_index__v3" | _ -> false);
 check bool "building over old text requires epoch closure" false (last born2).epoch_preserving;
 let born3 = get (plan ~initial_version:3 root) in
 check bool "fresh current install has no concurrent build" true (new_indexes born3=[] && (last born3).epoch_preserving);
 check (list string) "fresh current install uses baseline name" ["renamed_index"]
  (List.map (fun (i : Migration_storage.index) -> i.name) (List.hd (last born3).catalog).indexes))
let catalog_collision () = with_project ~initial:(replace "label: String }" "label: String\n index [label] as \"notes_pkey\"\n}" (append_field schema "label: String"))
 (fun root _ -> refused "MIG016" (plan root))
let origin_index_collision () =
 let initial = replace "active: Bool }" "active: Bool\n index [active] as \"later\"\n}" (append_field schema "active: Bool") in
 with_project ~initial (fun root path ->
  generate root;
  edit_schema path (fun s -> replace "index [active] as \"later\"" "" s ^
   "entity Tag table \"tags\" primaryKey id { id: String, label: String\n index [label] as \"later__v3\"\n}\n");generate root;
  generate ~next:true root;
  edit_schema path (replace "active: Bool\n" "active: Bool\n index [active] as \"later\"\n");generate root;
  check int "V1 installation reuses its index" 0 (List.length (new_indexes (get (plan root))));
  refused "MIG016" (plan ~initial_version:2 root);
  ignore (get (plan ~initial_version:3 root)))
let semantic_change () = with_project ~initial:(replace "entity Note" "type Label = String\nentity Note" (append_field schema "label: Label")) (fun root path ->
 generate root;edit_schema path (replace "type Label = String" "type Label = Int");generate root;
 refused "MIG003" (plan root))
let codec_emission () = with_project ~initial:(replace "entity Note" "record Details { value: String }\nentity Note" (append_field schema "details: Details")) (fun root _ ->
 match plan root with
 | Error es -> check bool "actual emitter rejects missing storage codec" true (List.exists (fun (e : Migration_sparse.error) -> Compile.string_contains e.message "codec") es)
 | Ok _ -> fail "carrier mapping concealed missing codec")
let stale_source () = with_project (fun root path ->
 let p = get (plan root) in
 save (path "app.tesl") (app ^ "# changed\n");refused "MIG013" (P.verify p ~documents:[]);
 save (path "app.tesl") app;
 let p = get (plan root) in write (path "schema/notes/v2.tesl") "";
 refused "MIG013" (P.verify p ~documents:[]))
let defaulted_unique () = with_project (fun root path ->
 generate root;edit_schema path (replace "id: String }" "id: String, rank: Int\n unique index [rank]\n}");generate root;
 set_entities path 2 "{ Note: Additive [Default rank 42] }";
 check bool "old omissions write the same default key" true (snd (List.hd (new_indexes (get (plan root))))<>None))
let removed_unique () = with_project ~initial:(replace "active: Bool }" "active: Bool\n unique index [active]\n}" (append_field schema "active: Bool")) (fun root path ->
 generate root;edit_schema path (replace "unique index [active]" "");generate root;
 let p = get (plan root) in
 check bool "retained uniqueness cannot be silently removed" false (last p).epoch_preserving;
 check bool "explicit retirement and contract obligation" true (match (last p).operations with
  [P.Retain_index {window_risk=Some _;_}] -> true | _ -> false))
let removed_safe_index () = with_project ~initial:(replace "active: Bool }" "active: Bool\n index [active]\n}" (append_field schema "active: Bool")) (fun root path ->
 generate root;edit_schema path (replace "index [active]" "");generate root;
 let p = get (plan root) in
 check bool "retaining bounded plain index preserves writes" true (last p).epoch_preserving;
 check bool "retained object is still recorded" true (match (last p).operations with [P.Retain_index _] -> true | _ -> false))
let same_jsonb () =
 let extra = {|import Tesl.Json exposing [stringCodec]
record Details { value: String }
codec Details {
 toJson { value -> "value" with_codec stringCodec }
 fromJson [ { value <- "value" with_codec stringCodec } ]
}
|} in
 with_project ~initial:(replace "entity Note" (extra ^ "entity Note") (append_field schema "details: Details")) (fun root path ->
 ignore (get (plan root));generate root;
 edit_schema path (replace "\"value\" with_codec" "\"renamed\" with_codec");generate root;
 refused "MIG003" (plan root))
let frozen_history () = with_project (fun root path ->
 generate root;edit_schema path (fun s -> append_field s "caption: Maybe String");generate root;
 generate ~next:true root;
 let file = path "schema/notes/v1.tesl" in save file (read file ^ "# valid edit to frozen bytes\n");
 List.iter (fun initial_version -> refused "MIG013" (plan ~initial_version root)) [1;2;3])
let app_failure () = with_project (fun root path ->
 save (path "app.tesl") (replace "import Tesl.Database" "import Tesl.Prelude exposing [Int]\nimport Tesl.Database" app ^ "fn broken() -> Int = \"wrong\"\n");
 refused "T001" (plan root))
let invalid_defaults () = with_project (fun root path ->
 generate root;edit_schema path (fun s -> append_field s "rank: Int, label: String");generate root;
 set_entities path 2 ("{ Note: Additive [Default rank 42, Default label \"" ^ String.make 1 '\000' ^ "\"] }");
 refused "MIG016" (plan root);
 set_entities path 2 ("{ Note: Additive [Default rank " ^ "1" ^ String.make 131072 '0' ^ ", Default label \"ok\"] }");
 refused "MIG016" (plan root))
let index_key_limit () =
 let names = List.init 33 (fun i -> "key" ^ string_of_int i) in
 let fields = String.concat ", " (List.map (fun name -> name ^ ": Maybe Bool") names) in
 with_project ~initial:(replace "id: String }" ("id: String, " ^ fields ^ "\n index [" ^ String.concat ", " names ^ "]\n}") schema)
  (fun root _ -> refused "MIG016" (plan root))
let overlays () = with_project (fun root path ->
 let file = path "schema/notes/v-current.tesl" in
 let documents = [{M.path=file;version=4}] in
 Source_input.with_overlays ~project_root:root [file,append_field schema "caption: Maybe String"] (fun () ->
  let p = get (plan ~documents root) in
  check bool "unsaved baseline is planned" true (match (last p).operations with [P.Create_table t] -> List.length t.columns=2 | _ -> false);
  get (P.verify p ~documents);
  refused "MIG013" (P.verify p ~documents:[{M.path=file;version=5}]));
 check string "buffer was not saved" schema (read file))
let initial_version_bounds () = with_project (fun root _ ->
 List.iter (fun initial_version -> refused "MIG020" (plan ~initial_version root))
  [min_int;0;2;2147483646;2147483647;max_int];
 check string "implicit V1 and explicit V1 agree" (P.digest (get (plan root)))
  (P.digest (get (plan ~initial_version:1 root))))
let earlier_default_validation () = with_project (fun root path ->
 generate root;edit_schema path (fun s -> append_field s "label: String");generate root;
 set_entities path 2 ("{ Note: Additive [Default label \"" ^ String.make 1 '\000' ^ "\"] }");
 (* Source/type checking can accept this literal; PostgreSQL assignment cannot.
    A fresh V2 would not install it, but must still reject the unusable history. *)
 refused "MIG016" (plan ~initial_version:2 root))
let expansion_chain_boundary () = with_project (fun root path ->
 generate root;edit_schema path (fun s -> append_field s "caption: Maybe String");generate root;
 generate ~next:true root;edit_schema path (fun s -> append_field s "active: Maybe Bool");generate root;
 let expected = get (plan root) in
 let history = match Migration_history_sources.discover ~compiler_abi:(P.compiler_abi expected)
   ~project_root:root ~family:"NotesSchema" with Ok h -> h | Error e -> fail e.message in
 let schema_sources = Migration_history_sources.frozen history @ [Migration_history_sources.current history] in
 let schemas = List.map (fun (s : Migration_history_sources.schema) -> s.inventory) schema_sources in
 let sources = Migration_history_sources.completed_migrations history @ Option.to_list (Migration_history_sources.current_migration history) in
 let edges = List.map (fun (s : Migration_history_sources.migration_source) ->
   let module_ = match Parser.parse_module s.path s.contents with Ok m -> m | Err e -> fail e.msg in
   match get (Migration_declaration.check ~compiler_abi:(P.compiler_abi expected) ~source:s.contents module_) with
    Some edge -> edge | None -> fail "checked fixture edge missing") sources in
 let derive = Migration_expansion.generate ~schemas ~edges in
 List.iter (fun initial_version ->
  let physical = get (derive ~initial_version) in
  let preview = get (plan ~initial_version root) in
  check bool "shared expansion and driver have identical canonical steps" true
   (List.map Migration_expansion.step_node physical=List.map Migration_expansion.step_node (P.steps preview))) [1;2;3];
 refused "MIG020" (derive ~initial_version:0);
 refused "MIG020" (derive ~initial_version:4);
 refused "MIG001" (Migration_expansion.generate ~initial_version:1 ~schemas ~edges:[]);
 refused "MIG016" (Migration_expansion.generate ~initial_version:3 ~schemas ~edges:(List.rev edges));
 refused "MIG016" (Migration_expansion.generate ~initial_version:3 ~schemas:(List.rev schemas) ~edges);
 let different_abi = match Migration_inventory.load ~compiler_abi:"different-comparison-context"
   ~root_file:(List.hd schema_sources).root_file with Ok i -> i | Error e -> fail e.message in
 refused "MIG016" (Migration_expansion.generate ~initial_version:3
   ~schemas:(different_abi :: List.tl schemas) ~edges))
let cli () = with_project (fun _root path ->
 let args = ["plan";path "app.tesl"] in
 let response = Migration_command.run args in
 check int response.stdout 0 response.exit_code;
 check bool "versioned plan protocol" true (Compile.string_contains response.stdout "\"kind\":\"migration-plan-preview\"");
 List.iter (fun rest -> let r = Migration_command.run (args @ rest) in
  check int r.stdout 1 r.exit_code;
  check bool "plan errors preserve protocol kind" true (Compile.string_contains r.stdout "\"kind\":\"migration-plan-preview\""))
  ([["--new-revision"];["--manifest-json"];["--database";"missing"];
    ["--initial-version"];["--initial-version";"1";"--initial-version";"1"]] @
   List.map (fun value -> ["--initial-version";value])
    ["";"0";"-1";"2";"01";"+1";"0x1";"1_0";"1.0";"1 ";" 1";"2147483646";"2147483647";String.make 80 '9']);
 let explicit = Migration_command.run (args @ ["--initial-version";"1"]) in
 check string "CLI default is explicitly V1" response.stdout explicit.stdout)
let step_identity () = with_project (fun root path ->
 let hash = Migration_expansion.step_hash in
 let baseline=get (plan root) in
 save (path "app.tesl") (replace "database Main" "database Other" (replace "notes_app" "other_app" app));
 let renamed=get (plan root) in
 check string "connection selection does not change an individual step" (hash (last baseline)) (hash (last renamed));
 check bool "whole preview remains bound to its selected connection" true (P.digest baseline<>P.digest renamed);
 save (path "app.tesl") app;
 generate root;edit_schema path (fun s -> append_field s "rank: Int");generate root;
 set_entities path 2 "{ Note: Additive [Default rank 42] }";
 let original=get (plan root) in
 set_entities path 2 "{ Note: Additive [Default rank 43] }";
 let changed=get (plan root) in
 check string "schema alone cannot identify row defaults" (last original).snapshot_hash (last changed).snapshot_hash;
 check bool "step identity covers changed default meaning" true (hash (last original)<>hash (last changed));
 let fresh=get (plan ~initial_version:2 root) in
 check bool "baseline installation and expansion have distinct step identities" true (hash (last fresh)<>hash (last changed));
 let recorded=List.map hash (P.steps changed) in
 generate ~next:true root;
 let later=get (plan root) in
 check (list string) "later revisions retain earlier identities" recorded
  (List.map hash (List.filter (fun (s:P.step) -> s.version<=2) (P.steps later)));
 check bool "identity is carried through JSON" true
  (Compile.string_contains (P.to_json later) ("\"stepHash\":\"" ^ hash (last later) ^ "\"")))
let step_identity_vector () =
 let step = {Migration_expansion.version=2;snapshot_hash=String.make 64 '0';epoch_preserving=true;operations=[];catalog=[]} in
 check string "cross-language empty-step canonical vector"
  "684432dfc81373f761f50b1c774739e156cf11205aadaa92d894e654320325c3" (Migration_expansion.step_hash step)
let complete_step_vectors () = with_project (fun root _ ->
 let module E = Migration_expansion in
 let module S = Migration_storage in
 let module C = Migration_canonical in
 let table = match (last (get (plan root))).operations with [P.Create_table t] -> t | _ -> fail "baseline table" in
 let column name scalar nullable primary_key = {(List.hd table.columns) with S.name;scalar;nullable;primary_key} in
 let id=column "id" S.Text false true and active=column "active" S.Bool false false in
 let index={S.name="active_idx";columns=["active"];unique=false} in
 let optional_index={S.name="optional_idx__v2";columns=["optional"];unique=true} in
 let unique_index={S.name="active_unique__v3";columns=["active"];unique=true} in
 let defaults = List.map (fun (name,scalar,kind,value) ->
  let c=column name scalar (kind="") false in
  c,if kind="" then E.Null else E.Constant (C.Seq [C.Bytes kind;C.Bytes value]))
  ["rank",S.Numeric,"int","-9007199254740993";"ratio",S.Float8,"float64","8000000000000000";
   "published",S.Bool,"bool","true";"caption",S.Text,"string","雪é ' \\ 🙂";"optional",S.Jsonb,"",""] in
 let catalog name columns indexes = {E.name;columns=List.map (fun (column,default) -> {E.column;default}) columns |>
  List.sort (fun (a:E.catalog_column) b -> String.compare a.column.name b.column.name);
  indexes=List.sort (fun (a:S.index) b -> String.compare a.name b.name) indexes} in
 let base=[id,E.Null;active,E.Null] in
 let audit=catalog "audit" [id,E.Null] [] in
 let step version epoch_preserving operations catalog = {E.version;snapshot_hash=String.make 64 (Char.chr (48+version));epoch_preserving;operations;catalog} in
 let steps = [
  step 1 true [E.Create_table {table with columns=[id;active];indexes=[index]}] [catalog "notes" base [index]];
  step 2 true (List.map (fun (column,default) -> E.Add_column {table="notes";column;default}) defaults @
   [E.Create_table {table with name="audit";columns=[id];indexes=[]};
    E.Build_index {table="notes";index=optional_index;window_risk=None}])
   [audit;catalog "notes" (base @ defaults) [index;optional_index]];
  step 3 false [E.Retain_table "audit";E.Retain_index {table="notes";index;window_risk=None};
   E.Build_index {table="notes";index=unique_index;window_risk=Some "requires epoch closure: old writers can conflict"}]
   [audit;catalog "notes" (base @ defaults) [index;optional_index;unique_index]]] in
 check (list string) "independent full-operation vectors, also checked by Go"
  ["98c1b95a7d9cba37b698e711bd35e87986a0aecb4cc578a8e0369d865dd17176";
   "3ab826b6198a44531229be7f371e5c8b642ea83a001a6d410d03d2c3200e0bd3";
   "f856c9a5d896d4b0b008d8a03b564fd36af23e6299f7dd59c3c0bc600faa77f8"] (List.map E.step_hash steps))
let () = run "Migration expansion plan" ["checked complete history",List.map (fun (name,f) -> test_case name `Quick f)
 ["baseline identity and namespace",baseline;"consecutive additive history",additive_chain;"constant assignment",defaults;
  "new table owns initial indexes",new_table;"drop retains storage and blocks reuse",retained_drop;
  "unbounded nonunique key narrows",old_text_index;"bounded nonunique key preserves",old_fixed_index;
  "old unique key narrows",old_unique_index;"new nullable unique preserves",new_nullable_unique;
  "mixed unique key narrows",mixed_unique;"every earlier admitted schema is considered",previously_added_column;
  "retained indexes are reused",retained_index;"implicit primary index collision",catalog_collision;
  "SQL carrier cannot hide semantics",semantic_change;"actual storage codec emission",codec_emission;
  "saved source and discovery guards",stale_source;"read-only CLI protocol",cli;
  "constant default is not a harmless old NULL key",defaulted_unique;
  "removed uniqueness retains write restrictions",removed_unique;
  "removed bounded plain index remains compatible",removed_safe_index;
  "same JSONB column still requires codec migration",same_jsonb;
  "frozen history cannot be planned after editing",frozen_history;
  "full application errors refuse planning",app_failure;
  "unsaved buffers and document versions",overlays;
  "PostgreSQL default assignment limits",invalid_defaults;
  "supported B-tree key count",index_key_limit;
  "initial installation version bounds",initial_version_bounds;
  "origin-specific index allocation collision",origin_index_collision;
  "shared expansion checks every supplied schema and edge",expansion_chain_boundary;
  "late installation checks earlier unsupported defaults",earlier_default_validation;
  "per-step identities bind meaning and survive later builds",step_identity;
  "step canonical identity golden vector",step_identity_vector;
  "all-operation cross-language identity vectors",complete_step_vectors]]
