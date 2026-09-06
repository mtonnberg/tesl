open Alcotest
module I = Migration_inventory
module P = Migration_storage
let rec mkdir p = if not (Sys.file_exists p) then (mkdir (Filename.dirname p); Unix.mkdir p 0o700)
let rec remove p = if (Unix.lstat p).Unix.st_kind=Unix.S_DIR then
 (Array.iter (fun name -> remove (Filename.concat p name)) (Sys.readdir p); Unix.rmdir p)
 else Sys.remove p
let with_project f =
 let root = Filename.temp_file "tesl-storage-" ".dir" in Sys.remove root;Unix.mkdir root 0o700;
 Fun.protect ~finally:(fun () -> remove root) (fun () ->
  let write name source = let path = Filename.concat root name in mkdir (Filename.dirname path);
   Out_channel.with_open_bin path (fun out -> output_string out source);
   if Filename.check_suffix name ".tesl" then ignore (Compile.agent_context_result_source path source);
   path in
  ignore (write "tesl.toml" ""); f root write)
let get = function Ok x -> x | Error (e : Migration_ir.error) -> fail e.message
let load ?(abi="fixture-ABI") file = get (I.load ~compiler_abi:abi ~root_file:file)
let describe i = match P.describe i with Ok x -> x | Error es -> fail
 (String.concat "\n" (List.map (fun (e : Migration_sparse.error) -> e.message) es))
let only = function [x] -> x | _ -> fail "expected one table"
let replace a b = Str.global_substitute (Str.regexp_string a) (fun _ -> b)
let header = {|module NotesSchema.VCurrent exposing []
import Tesl.Prelude exposing [Int, String, Bool(..)]
import Tesl.Float exposing [Float]
import Tesl.Maybe exposing [Maybe(..)]
|}
let simple = header ^ "entity Note table \"notes\" primaryKey id { id: String, amount: Int }\n"
let column name table = List.find (fun (c : P.column) -> c.field.name=name) table.P.columns
let shape c = P.scalar_name c.P.scalar ^ (if c.nullable then "?" else "!") ^ (if c.primary_key then " key" else "")
let primitives () = with_project (fun _ write ->
 let file = write "schema/notes/v-current.tesl" (header ^ {|import Tesl.Int32 exposing [Int32]
import Tesl.Time exposing [PosixMillis]
entity Note table "notes" primaryKey id {
 id: String
 amount: Int
 rating: Float
 enabled: Bool
 small: Int32
 bounded: Int32 @db(integer)
 wide: Int32 @db(bigint)
 createdAt: PosixMillis
 userID: Maybe String
 optionalNumber: Maybe Int
}
|}) in
 let inventory = load file in
 let description = describe inventory in
 check bool "retains exact checked inventory" true (P.inventory description == inventory);
 let table = only (P.tables description) in
 List.iter (fun (name,expected) -> check string name expected (shape (column name table)))
  ["id","text! key";"amount","numeric!";"rating","float8!";"enabled","bool!";
   "small","numeric!";"bounded","int4!";"wide","int8!";"createdAt","int8!";"userID","text?";"optionalNumber","numeric?"];
 check string "shared acronym mapping" "user_id" (column "userID" table).name)
let owned_carriers () = with_project (fun _ write ->
 let file = write "schema/notes/v-current.tesl" (header ^ {|type Key = String
type Count = Int
type Wrapped = Count
record Details { value: String }
type Change
 = Unchanged
 | Changed value: Details
type Box a
 = Boxed value: a
entity Note table "notes" primaryKey id {
 id: Key
 amount: Wrapped
 details: Details
 backup: Maybe Details
 change: Change
 generic: Box Details
}
|}) in
 let table = only (P.tables (describe (load file))) in
 List.iter (fun (name,expected) -> check string name expected (shape (column name table)))
  ["id","text! key";"amount","numeric!";"details","jsonb!";"backup","jsonb?";"change","jsonb!";"generic","jsonb!"])
let private_modules () = with_project (fun _ write ->
 ignore (write "schema/notes/v-current/a.tesl" (replace "module NotesSchema.VCurrent" "module NotesSchema.VCurrent.A" simple));
 ignore (write "schema/notes/v-current/b.tesl" (replace "module NotesSchema.VCurrent" "module NotesSchema.VCurrent.B" (replace "\"notes\"" "\"archives\"" simple)));
 let file = write "schema/notes/v-current.tesl" "module NotesSchema.VCurrent exposing []\nimport NotesSchema.VCurrent.A\nimport NotesSchema.VCurrent.B\n" in
 let tables = P.tables (describe (load file)) in
 check (list string) "private tables sorted by storage name" ["archives";"notes"] (List.map (fun (t : P.table) -> t.name) tables);
 check (list string) "ownership retained" ["NotesSchema.VCurrent.B.Note";"NotesSchema.VCurrent.A.Note"]
  (List.map (fun (t : P.table) -> t.entity.entity_name) tables))
let overrides () = with_project (fun _ write ->
 List.iter (fun (field,annotation,expected) ->
  let source = replace field (field ^ " @db(" ^ annotation ^ ")") simple in
  let file = write "schema/notes/v-current.tesl" source in
  let table = only (P.tables (describe (load file))) in
  check string annotation expected (P.scalar_name (column (if field="id: String" then "id" else "amount") table).scalar))
  ["id: String","text","text";"amount: Int","decimal","numeric";"amount: Int","numeric","numeric"])
let refuses_physical_mismatch () = with_project (fun _ write ->
 List.iter (fun (label,source) ->
  let file = write "schema/notes/v-current.tesl" source in
  match P.describe (load file) with
  | Ok _ -> fail ("accepted " ^ label)
  | Error errors -> check bool label true (List.exists (fun (e : Migration_sparse.error) -> e.code="MIG016" && e.loc.file=file) errors))
  ["integer narrowing needs evidence",replace "amount: Int" "amount: Int @db(bigint)" simple;
   "custom type has catalog obligations",replace "id: String" "id: String @db(custom_text)" simple;
   "catalog-dependent varchar",replace "id: String" "id: String @db(varchar)" simple;
   "nested optional",replace "amount: Int" "amount: Maybe (Maybe Int)" simple;
   "wrapped optional",header ^ "type Optional = (Maybe Int)\nentity Note table \"notes\" primaryKey id { id: String, amount: Optional }\n";
   "unmapped list",header ^ "import Tesl.Prelude exposing [List]\nentity Note table \"notes\" primaryKey id { id: String, amount: List Int @db(jsonb) }\n"])
let indexes () = with_project (fun _ write ->
 let source = replace "amount: Int }" "amount: Int\n unique index [amount] as \"notes_amount_unique\"\n index [id, amount]\n}" simple in
 let file = write "schema/notes/v-current.tesl" source in
 let t = only (P.tables (describe (load file))) in
 check (list string) "all indexes retained" ["notes_amount_unique";"notes_id_amount_idx"]
  (List.map (fun (i : P.index) -> i.name) t.indexes);
 check (list bool) "unique and nonunique remain distinct" [true;false] (List.map (fun (i : P.index) -> i.unique) t.indexes);
 check (list string) "key order retained" ["id";"amount"] (List.nth t.indexes 1).columns)
let relation_collisions () = with_project (fun _ write ->
 List.iter (fun source ->
  let file = write "schema/notes/v-current.tesl" source in
  match I.load ~compiler_abi:"fixture-ABI" ~root_file:file with
  | Error e -> check bool "existing duplicate index validation" true (Compile.string_contains e.message "already used by")
  | Ok inventory -> match P.describe inventory with
    | Ok _ -> fail "relation namespace collision accepted"
    | Error es -> check bool "related storage owner retained" true (List.exists (fun (e : Migration_sparse.error) -> e.related<>[]) es))
  [replace "amount: Int }" "amount: Int\n index [amount] as \"notes\"\n}" simple;
   replace "amount: Int }" "amount: Int\n index [amount] as \"shared\"\n}" simple ^ "entity Other table \"other\" primaryKey id { id: String, value: String\n index [value] as \"shared\"\n}\n"])
let name_limits () = with_project (fun _ write ->
 List.iter (fun name ->
  let file = write "schema/notes/v-current.tesl" (replace "\"notes\"" (Compile.json_encode_string name) simple) in
  match I.load ~compiler_abi:"fixture-ABI" ~root_file:file with
  | Error _ -> () | Ok i -> match P.describe i with Ok _ -> fail "PostgreSQL silently truncated relation name" | Error _ -> ())
  [String.make 64 'a';String.concat "" (List.init 32 (fun _ -> "å"))];
 let source = replace "\"notes\"" ("\"" ^ String.make 63 'n' ^ "\"") (replace "amount: Int }" "amount: Int\n unique index [amount]\n}" simple) in
 let file = write "schema/notes/v-current.tesl" source in
 let t = only (P.tables (describe (load file))) in
 check bool "derived index fits" true (String.length (List.hd t.indexes).name<=63))
let semantic_identity () = with_project (fun root write ->
 let file = write "schema/notes/v-current.tesl" (header ^ "record Details { text: String }\nentity Note table \"notes\" primaryKey id { id: String, details: Details }\n") in
 let initial = In_channel.with_open_bin file In_channel.input_all in
 let old = describe (load file) in
 ignore (write "schema/notes/v-current.tesl" (initial ^ "# formatting has no semantic effect\n"));
 check string "comment insensitive descriptor" (P.digest old) (P.digest (describe (load file)));
 ignore (write "schema/notes/v-current.tesl" (replace "record Details { text: String }" "record Details { text: String, count: Int }" initial));
 let fresh = describe (load file) in
 check bool "same SQL carrier still changes identity" true (P.digest old<>P.digest fresh);
 check string "old JSONB carrier" "jsonb!" (shape (column "details" (only (P.tables old))));
 check string "new JSONB carrier" "jsonb!" (shape (column "details" (only (P.tables fresh))));
 check bool "ABI changes descriptor identity" true (P.digest fresh<>P.digest (describe (load ~abi:"other ABI" file)));
 ignore root)
let emitter_agreement () = with_project (fun _ write ->
 let source = header ^ "import Tesl.Int32 exposing [Int32]\nimport Tesl.Time exposing [PosixMillis]\nimport Tesl.Json exposing [stringCodec]\ntype UserKey = String\nrecord Details { caption: String }\ncodec Details {\n toJson { caption -> \"caption\" with_codec stringCodec }\n fromJson [ { caption <- \"caption\" with_codec stringCodec } ]\n}\nentity Note table \"notes\" primaryKey id { id: UserKey, amount: Int, enabled: Bool, rating: Float, small: Int32, bounded: Int32 @db(integer), wide: Int32 @db(bigint), createdAt: PosixMillis, details: Details, backup: Maybe Details\n unique index [amount]\n}\n" in
 let schema = write "schema/notes/v-current.tesl" source in
 let storage = describe (load schema) in
 let app = "module App exposing []\nimport Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]\nimport NotesSchema.VCurrent\ndatabase Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate, backend: Postgres (PostgresConfig { dbName: \"notes\", user: \"tesl\", password: \"\", connection: TcpConnection { host: \"127.0.0.1\", port: 5432 }, namespace: \"app\" }) }\n" in
 let file = write "app.tesl" app in
 let artifacts = match Compile.compile_go_source file app with
  | Compile.GoSuccess a -> a
  | Compile.GoFailure ds -> fail (Compile.diagnostics_to_json ds) in
 let emitted = List.map (fun (a : Emit_go.artifact) -> a.contents) artifacts |> String.concat "\n" in
 let native_type = function P.Numeric -> "NUMERIC" | P.Float8 -> "DOUBLE PRECISION" | P.Text -> "TEXT" | P.Bool -> "BOOLEAN" | P.Int4 -> "INTEGER" | P.Int8 -> "BIGINT" | P.Jsonb -> "JSONB" in
 List.iter (fun (t : P.table) ->
  List.iter (fun (c : P.column) ->
   let wanted = Printf.sprintf "teslrt.PostgresColumnOf(%S, %S, %b, %b)" c.name (native_type c.scalar) c.primary_key c.nullable in
   let found = Compile.string_contains emitted wanted in
   if not found then List.iter (fun line -> if Compile.string_contains line "teslrt.PostgresColumnOf(" then Printf.eprintf "%s\n%!" line) (String.split_on_char '\n' emitted);
   check bool wanted true found) t.columns;
  List.iter (fun (i : P.index) ->
   let wanted = Printf.sprintf "teslrt.PostgresIndexOf(%S, %s)" i.name (String.concat ", " (List.map (Printf.sprintf "%S") i.columns)) in
   check bool wanted true (Compile.string_contains emitted wanted)) t.indexes) (P.tables storage))
let nominal_names_are_not_storage_tags () = with_project (fun _ write ->
 let source = header ^ "type Int32 = String\nentity Note table \"notes\" primaryKey id { id: String, narrow: Int32 }\n" in
 let schema = write "schema/notes/v-current.tesl" source in
 let table = only (P.tables (describe (load schema))) in
 check string "owned bounded spelling retains String base" "text!" (shape (column "narrow" table));
 let app = "module App exposing []\nimport Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]\nimport NotesSchema.VCurrent\ndatabase Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate, backend: Postgres (PostgresConfig { dbName: \"notes\", user: \"tesl\", password: \"\", connection: TcpConnection { host: \"127.0.0.1\", port: 5432 }, namespace: \"app\" }) }\n" in
 let file = write "app.tesl" app in
 let emitted = match Compile.compile_go_source file app with
  | Compile.GoFailure ds -> fail (Compile.diagnostics_to_json ds)
  | Compile.GoSuccess artifacts -> String.concat "\n" (List.map (fun (a : Emit_go.artifact) -> a.contents) artifacts) in
 List.iter (fun name -> check bool (name ^ " actual emitter carrier") true
  (Compile.string_contains emitted (Printf.sprintf "teslrt.PostgresColumnOf(%S, \"TEXT\", false, false)" name))) ["narrow"])
let () = run "PostgreSQL migration storage" ["checked storage",List.map (fun (name,f) -> test_case name `Quick f)
 ["primitive carriers and optional columns",primitives;"owned newtypes records and ADTs",owned_carriers;
  "private module ownership",private_modules;"equivalent explicit builtin types",overrides;
  "unsupported assignment and representation refuse",refuses_physical_mismatch;
  "index metadata and key order",indexes;"relation namespace collisions",relation_collisions;
  "PostgreSQL identifier byte limits",name_limits;"JSONB semantics and ABI retained",semantic_identity;
  "independent actual Go emission agrees",emitter_agreement;
  "nominal spellings are not builtin storage tags",nominal_names_are_not_storage_tags]]
