open Alcotest

let contains text fragment =
  try ignore (Str.search_forward (Str.regexp_string fragment) text 0); true
  with Not_found -> false

let rec mkdir path =
  if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)

let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path

let with_project f =
  let root = Filename.temp_dir "tesl-jsonb-columns-" "" in
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let write relative contents =
      let path = Filename.concat root relative in
      mkdir (Filename.dirname path);
      Out_channel.with_open_text path (fun out -> output_string out contents);
      path in
    ignore (write "tesl.toml" "");
    f root write)

let compile file = match Compile.compile_go_file file with
  | Compile.GoSuccess artifacts -> artifacts
  | Compile.GoFailure diagnostics -> fail (Compile.diagnostics_to_json diagnostics)

let execute root write artifacts tests =
  List.iter (fun (a : Emit_go.artifact) -> ignore (write ("out/" ^ a.path) a.contents)) artifacts;
  List.iter (fun (path, text) -> ignore (write ("out/" ^ path) text)) tests;
  let log = Filename.concat root "go.log" in
  let command = "cd " ^ Filename.quote (Filename.concat root "out")
    ^ " && go test -count=1 ./... > " ^ Filename.quote log ^ " 2>&1" in
  if Sys.command command <> 0 then fail (In_channel.with_open_text log In_channel.input_all)

let imports = {|import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.Json exposing [stringCodec, intCodec]
|}

let database entities = Printf.sprintf {|database Db = Database {
  schema: "jsonb_columns"
  entities: [%s]
  backend: Postgres (PostgresConfig {
    dbName: "test", user: "test", password: "test"
    connection: TcpConnection { host: "localhost", port: 5432 }
  })
}
|} entities

let details = {|fact Positive (n: Int)
check positive(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 422 "not positive"
record Details { text: String, count: Int ::: Positive count }
codec Details {
  toJson { text -> "body" with_codec stringCodec, count -> "count" with_codec intCodec }
  fromJson [
    { text <- "body" with_codec stringCodec, count <- "count" with_codec intCodec via positive }
    { text <- "title" with_codec stringCodec, count <- "count" with_codec intCodec via positive }
  ]
}
|}

let scanner_row = {|type rawRow struct { values []any }
func (r rawRow) FieldDescriptions() []pgconn.FieldDescription { return nil }
func (r rawRow) Values() ([]any, error) { return r.values, nil }
func (r rawRow) RawValues() [][]byte { return nil }
func (r rawRow) Scan(dest ...any) error {
  for i, value := range r.values {
    target := reflect.ValueOf(dest[i]).Elem()
    if value == nil { target.SetZero() } else { target.Set(reflect.ValueOf(value)) }
  }
  return nil
}
func mustPanic(t *testing.T, f func()) {
  t.Helper()
  defer func() { if recover() == nil { t.Error("corrupt or incompatible row was accepted") } }()
  f()
}
|}

let local_records () = with_project (fun root write ->
  let file = write "columns.tesl" ("module Columns exposing [store, read]\n" ^ imports ^ details ^ {|
type Event
  = Empty
  | Changed details: Details
record Nested { details: Details }
codec Nested {
  toJson { details -> "payload" with_codec Details }
  fromJson [ { details <- "payload" with_codec Details } ]
}
entity Stored table "stored" primaryKey id {
  id: String
  details: Details
  optional: Maybe Details
  event: Event
  nested: Nested @db(jsonb)
}
|} ^ database "Stored" ^ {|
fn store(id: String, details: Details) -> Stored requires [dbWrite Stored] =
  insert Stored {
    id: id, details: details, optional: Something details,
    event: Changed details, nested: Nested { details: details }
  }
fn read(id: String) -> Maybe Stored requires [dbRead Stored] =
  selectOne s from Stored where s.id == id
test "a stored record has the same value in memory" requires [dbRead Stored, dbWrite Stored] {
  let raw = 3
  let n = check positive raw
  let detail = Details { text: "kept", count: n }
  let _ = store "one" detail
  case read "one" of
    Nothing -> expect False
    Something row -> expect row.details == detail
}
|}) in
  let artifacts = compile file in
  let generated = List.find (fun (a : Emit_go.artifact) -> a.path = "internal/teslmodcolumns/module.go") artifacts in
  check bool "record type is automatically JSONB" true
    (contains generated.contents "PostgresColumnOf(\"details\", \"JSONB\", false, false)");
  check bool "Maybe record is nullable JSONB" true
    (contains generated.contents "PostgresColumnOf(\"optional\", \"JSONB\", false, true)");
  execute root write artifacts ["internal/teslmodcolumns/column_regression_test.go", {|
package teslmodcolumns
import (
  "reflect"
  "testing"
  "github.com/jackc/pgx/v5/pgconn"
)
|} ^ scanner_row ^ {|
func TestStoredRecordCodecs(t *testing.T) {
  good := []byte(`{"title":"legacy","count":123456789012345678901234567890}`)
  event := []byte(`{"tag":"Changed","fields":{"details":{"title":"legacy","count":3}}}`)
  nested := []byte(`{"payload":{"title":"legacy","count":3}}`)
  row, err := teslScanStored(rawRow{[]any{"one", good, good, event, nested}})
  if err != nil { t.Fatal(err) }
  if row.Details.Text != "legacy" || row.Details.Count.String() != "123456789012345678901234567890" {
    t.Fatalf("record lost fields or integer precision: %+v", row.Details)
  }
  optional, ok := row.Optional.Value()
  if !ok || optional.Text != "legacy" || row.Nested.Details.Text != "legacy" {
    t.Fatal("nullable/nested record did not use its codec")
  }
  encoded := EncodeDetailsJSON(row.Details).(map[string]any)
  if encoded["body"] != "legacy" || encoded["title"] != nil { t.Fatal(encoded) }
  row, err = teslScanStored(rawRow{[]any{"one", good, nil, event, nested}})
  if err != nil { t.Fatal(err) }
  if _, ok := row.Optional.Value(); ok { t.Fatal("SQL NULL became Something") }
  // Ordered alternatives still choose the first successful decoder.
  both := []byte(`{"body":"current","title":"legacy","count":3}`)
  row, err = teslScanStored(rawRow{[]any{"one", both, nil, event, nested}})
  if err != nil || row.Details.Text != "current" { t.Fatalf("wrong alternative: %+v %v", row, err) }
  for _, corrupt := range []string{
    `null`, `[]`, `{}`, `{"body":42,"count":3}`, `{"body":"bad","count":0}`,
    `{"title":"bad","count":-1}`, `{"body":"bad","count":1.5}`, `{"body":"bad","count":"3"}`,
  } {
    t.Run(corrupt, func(t *testing.T) {
      bad := []byte(corrupt)
      mustPanic(t, func() { _, _ = teslScanStored(rawRow{[]any{"one", bad, nil, event, nested}}) })
      mustPanic(t, func() { _, _ = teslScanStored(rawRow{[]any{"one", good, bad, event, nested}}) })
    })
  }
  mustPanic(t, func() {
    _, _ = teslScanStored(rawRow{[]any{"one", good, nil,
      []byte(`{"tag":"Changed","fields":{"details":{"body":"bad","count":0}}}`), nested}})
  })
  mustPanic(t, func() {
    _, _ = teslScanStored(rawRow{[]any{"one", good, nil, event,
      []byte(`{"payload":{"body":"bad","count":0}}`)}})
  })
}
|}])

let private_nominal_codecs transitive () = with_project (fun root write ->
  List.iter (fun (name, key, entity) ->
    ignore (write (String.lowercase_ascii name ^ ".tesl")
      (Printf.sprintf {|module %s exposing [%s]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record Details { text: String }
codec Details {
  toJson { text -> "%s" with_codec stringCodec }
  fromJson [ { text <- "%s" with_codec stringCodec } ]
}
entity %s table "%s" primaryKey id { id: String, details: Details }
|} name entity key key entity (String.lowercase_ascii entity))))
    ["Alpha", "a", "First"; "Beta", "b", "Second"];
  if transitive then begin
    ignore (write "inner.tesl" {|module Inner exposing [Details]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record Details { text: String }
codec Details {
  toJson { text -> "a" with_codec stringCodec }
  fromJson [ { text <- "a" with_codec stringCodec } ]
}
|});
    ignore (write "alpha.tesl" {|module Alpha exposing [First]
import Tesl.Prelude exposing [String]
import Inner exposing [Details]
entity First table "first" primaryKey id { id: String, details: Details }
|})
  end;
  let entry = write "columns.tesl" ("module Columns exposing [first, second]\n" ^ imports ^ {|
import Alpha exposing [First]
import Beta exposing [Second]
|} ^ database "First, Second" ^ {|
fn first() -> Maybe First requires [dbRead First] = selectOne f from First
fn second() -> Maybe Second requires [dbRead Second] = selectOne s from Second
|}) in
  execute root write (compile entry) ["internal/teslmodcolumns/nominal_regression_test.go", {|
package teslmodcolumns
import (
  "reflect"
  "testing"
  "github.com/jackc/pgx/v5/pgconn"
)
|} ^ scanner_row ^ {|
func TestPrivateSameNamedCodecs(t *testing.T) {
  first, err := teslScanFirst(rawRow{[]any{"a", []byte(`{"a":"alpha"}`)}})
  if err != nil || first.Details.Text != "alpha" { t.Fatalf("%+v %v", first, err) }
  second, err := teslScanSecond(rawRow{[]any{"b", []byte(`{"b":"beta"}`)}})
  if err != nil || second.Details.Text != "beta" { t.Fatalf("%+v %v", second, err) }
  mustPanic(t, func() { _, _ = teslScanFirst(rawRow{[]any{"a", []byte(`{"b":"wrong"}`)}}) })
  mustPanic(t, func() { _, _ = teslScanSecond(rawRow{[]any{"b", []byte(`{"a":"wrong"}`)}}) })
}
|}])

let forbidden_directions () = with_project (fun _root write ->
  List.iter (fun field_type -> List.iter (fun queried -> List.iter (fun codec ->
    let file = write "columns.tesl" ((if queried then "module Columns exposing [read]\n" else "module Columns exposing []\n") ^ imports ^
      "record Details { text: String }\n" ^ codec ^
      "\ntype Event\n  = Empty\n  | Changed details: Details\n" ^
      "entity Stored table \"stored\" primaryKey id { id: String, details: " ^ field_type ^ " @db(jsonb) }\n" ^
      database "Stored" ^
      (if queried then "fn read() -> Maybe Stored requires [dbRead Stored] = selectOne s from Stored\n" else "")) in
    match Compile.compile_go_file file with
    | Compile.GoSuccess _ -> fail "storage admitted a record with no bidirectional codec"
    | Compile.GoFailure diagnostics -> check bool "actionable storage refusal" true
        (List.exists (fun (d : Compile.diagnostic) -> contains d.message "stored record") diagnostics))
    ["";
     "codec Details { toJson_forbidden, fromJson [ { text <- \"text\" with_codec stringCodec } ] }";
     "codec Details { toJson { text -> \"text\" with_codec stringCodec }, fromJson_forbidden }"]) [true; false])
    ["Details"; "Maybe Details"; "Event"])

let forbidden_adt_directions () = with_project (fun _root write ->
  List.iter (fun field_type -> List.iter (fun queried -> List.iter (fun direction ->
    let source = (if queried then "module Columns exposing [read]\n" else "module Columns exposing []\n") ^ imports ^
      "type State\n  = Idle\n  | Named value: String\n" ^
      "codec State { adtJson, " ^ direction ^ " }\n" ^
      "type Event\n  = Empty\n  | Changed state: State\n" ^
      "type Envelope a\n  = Wrapped value: a\n" ^
      "entity Stored table \"stored\" primaryKey id { id: String, state: " ^ field_type ^ " @db(jsonb) }\n" ^
      database "Stored" ^
      (if queried then "fn read() -> Maybe Stored requires [dbRead Stored] = selectOne s from Stored\n" else "") in
    let file = write "columns.tesl" source in
    match Compile.compile_go_file file with
    | Compile.GoSuccess _ -> fail "stored ADT bypassed its explicit forbidden codec direction"
    | Compile.GoFailure diagnostics -> check bool "actionable ADT codec refusal" true
        (List.exists (fun (d : Compile.diagnostic) -> contains d.message "stored ADT") diagnostics))
    ["toJson_forbidden"; "fromJson_forbidden"; "toJson_forbidden, fromJson_forbidden"])
    [true; false]) ["State"; "Maybe State"; "Event"; "Envelope State"; "Envelope (Envelope State)"])

let same_named_adts boxed = with_project (fun root write ->
  List.iter (fun (name, entity, field_type) ->
    ignore (write (String.lowercase_ascii name ^ ".tesl")
      (Printf.sprintf {|module %s exposing [%s]
import Tesl.Prelude exposing [String, Int]
type State
  = Empty
  | Named value: %s
%sentity %s table "%s" primaryKey id { id: String, state: State }
|} name entity field_type
        (if boxed then "  | Wide " ^ String.concat " " (List.init 24 (fun n ->
          "field" ^ string_of_int n ^ ": String")) ^ "\n" else "")
        entity (String.lowercase_ascii entity))))
    ["Alpha", "First", "String"; "Beta", "Second", "Int"];
  let entry = write "columns.tesl" ("module Columns exposing [first, second]\n" ^ imports ^ {|
import Alpha exposing [First]
import Beta exposing [Second]
|} ^ database "First, Second" ^ {|
fn first() -> Maybe First requires [dbRead First] = selectOne f from First
fn second() -> Maybe Second requires [dbRead Second] = selectOne s from Second
|}) in
  let test = {|
package teslmodcolumns
import (
  "reflect"
  "testing"
  "github.com/jackc/pgx/v5/pgconn"
)
|} ^ scanner_row ^ {|
func TestSameNamedADTs(t *testing.T) {
  first, err := teslScanFirst(rawRow{[]any{"a", []byte(`{"tag":"Named","fields":{"value":"alpha"}}`)}})
  if err != nil || first.State.NamedValue != "alpha" { t.Fatalf("%+v %v", first, err) }
  second, err := teslScanSecond(rawRow{[]any{"b", []byte(`{"tag":"Named","fields":{"value":123456789012345678901234567890}}`)}})
  if err != nil || second.State.NamedValue.String() != "123456789012345678901234567890" { t.Fatalf("%+v %v", second, err) }
  mustPanic(t, func() { _, _ = teslScanFirst(rawRow{[]any{"a", []byte(`{"tag":"Named","fields":{"value":3}}`)}}) })
  mustPanic(t, func() { _, _ = teslScanSecond(rawRow{[]any{"b", []byte(`{"tag":"Named","fields":{"value":"wrong"}}`)}}) })
}
|} in
  let test = if boxed then Str.global_replace (Str.regexp_string ".State.NamedValue")
    ".State.Named.Value" test else test in
  execute root write (compile entry) ["internal/teslmodcolumns/adt_regression_test.go", test])

let generic_adts imported boxed = with_project (fun root write ->
  let declarations = {|type Parcel a
  = Missing
  | Loaded value: a
|} ^ (if boxed then "  | Wide " ^ String.concat " " (List.init 24 (fun n ->
        "field" ^ string_of_int n ^ ": String")) ^ "\n" else "") ^ {|
entity Document table "documents" primaryKey id {
  id: String, text: Parcel String, number: Parcel Int
  nested: Parcel (Parcel Int), optional: Maybe (Parcel String)
}
|} in
  let prefix = if imported then begin
    ignore (write "model.tesl" ("module Model exposing [Parcel(..), Document]\n" ^ imports ^ declarations));
    "Model."
  end else "" in
  let source = "module Columns exposing [sample, store, read]\n" ^ imports ^
    "import Tesl.ApiTest exposing [statusOk]\n" ^
    (if imported then "import Model exposing [Parcel(..), Document]\n" else declarations) ^
    database "Document" ^ Printf.sprintf {|
fn sample() -> Document = Document {
  id: "one", text: %sLoaded "hello", number: %sLoaded 123456789012345678901234567890
  nested: %sLoaded (%sLoaded 9), optional: Something (%sLoaded "optional")
}
fn store(row: Document) -> Document requires [dbWrite Document] =
  insert Document { id: row.id, text: row.text, number: row.number, nested: row.nested, optional: row.optional }
fn read() -> Maybe Document requires [dbRead Document] = selectOne row from Document
test "generic payloads retain their instantiations" requires [dbRead Document, dbWrite Document] {
  let _ = store (sample ())
  expect read () == Something (sample ())
}
handler get document() -> Document = sample ()
api DocumentsApi { get "/document" -> Document }
server DocumentsServer for DocumentsApi { document }
api-test "generic payloads encode through the application" for DocumentsServer {
  let response = get "/document"
  expect response.status == 200
  expect response.body.text.fields.value == "hello"
  expect response.body.number.fields.value == 123456789012345678901234567890
  expect response.body.nested.fields.value.fields.value == 9
  expect response.body.optional.fields.value.fields.value == "optional"
}
|} prefix prefix prefix prefix prefix in
  let file = write "columns.tesl" source in
  let test = {|
package teslmodcolumns
import (
  "reflect"
  "testing"
  "github.com/jackc/pgx/v5/pgconn"
)
|} ^ scanner_row ^ {|
func TestGenericColumnInstantiations(t *testing.T) {
  values := []any{"one",
    []byte(`{"tag":"Loaded","fields":{"value":"hello"}}`),
    []byte(`{"tag":"Loaded","fields":{"value":123456789012345678901234567890}}`),
    []byte(`{"tag":"Loaded","fields":{"value":{"tag":"Loaded","fields":{"value":9}}}}`),
    []byte(`{"tag":"Loaded","fields":{"value":"optional"}}`),
  }
  row, err := teslScanDocument(rawRow{values})
  if err != nil || row.Text.LoadedValue != "hello" || row.Number.LoadedValue.String() != "123456789012345678901234567890" || row.Nested.LoadedValue.LoadedValue.String() != "9" {
    t.Fatalf("generic scanner mixed instantiations: %+v, %v", row, err)
  }
  optional, ok := row.Optional.Value()
  if !ok || optional.LoadedValue != "optional" { t.Fatalf("nullable generic: %+v", row.Optional) }
  for position, invalid := range map[int]string{
    1: `{"tag":"Loaded","fields":{"value":3}}`,
    2: `{"tag":"Loaded","fields":{"value":"wrong"}}`,
    3: `{"tag":"Loaded","fields":{"value":{"tag":"Loaded","fields":{"value":null}}}}`,
    4: `null`,
  } {
    bad := append([]any(nil), values...)
    bad[position] = []byte(invalid)
    mustPanic(t, func() { _, _ = teslScanDocument(rawRow{bad}) })
  }
  values[4] = nil
  row, err = teslScanDocument(rawRow{values})
  if _, ok := row.Optional.Value(); err != nil || ok { t.Fatalf("SQL NULL: %+v %v", row, err) }
}
|} in
  let test = if boxed then Str.global_replace (Str.regexp_string ".LoadedValue")
    ".Loaded.Value" test else test in
  execute root write (compile file) ["internal/teslmodcolumns/generic_regression_test.go", test])

let single_variant_adts explicit_codec = with_project (fun root write ->
  let file = write "single.tesl" ("module Single exposing [sample, store, read]\n" ^ imports ^ {|
import Tesl.ApiTest exposing [statusOk]
import Tesl.Tuple exposing [Tuple2(..)]
type Packet =
  | Packed number: Int text: String
type Singleton =
  | Only
|} ^ (if explicit_codec then "codec Packet { adtJson }\ncodec Singleton { adtJson }\n" else "") ^ {|
entity Document table "documents" primaryKey id { id: String, packet: Packet, singleton: Singleton, pair: Tuple2 Int String }
|} ^ database "Document" ^ {|
fn sample() -> Packet = Packed 123456789012345678901234567890 "hello"
fn store() -> Document requires [dbWrite Document] =
  insert Document { id: "one", packet: sample (), singleton: Only, pair: Tuple2 7 "pair" }
fn read() -> Maybe Document requires [dbRead Document] = selectOne row from Document
test "a tagless Go layout retains the complete payload" requires [dbRead Document, dbWrite Document] {
  let _ = store ()
  case read () of
    Nothing -> expect False
    Something row -> expect row.packet == sample ()
}
handler get packet() -> Packet = sample ()
handler get singleton() -> Singleton = Only
handler get pair() -> Tuple2 Int String = Tuple2 7 "pair"
api ValuesApi { get "/packet" -> Packet, get "/singleton" -> Singleton, get "/pair" -> Tuple2 Int String }
server ValuesServer for ValuesApi { packet, singleton, pair }
api-test "single constructors still use the tagged JSON contract" for ValuesServer {
  let response = get "/packet"
  expect response.status == 200
  expect response.body.tag == "Packed"
  expect response.body.fields.number == 123456789012345678901234567890
  expect response.body.fields.text == "hello"
  let empty = get "/singleton"
  expect empty.status == 200
  expect empty.body.tag == "Only"
  let tuple = get "/pair"
  expect tuple.status == 200
  expect tuple.body.tag == "Tuple2"
  expect tuple.body.fields.first == 7
  expect tuple.body.fields.second == "pair"
}
|}) in
  let test = {|
package teslmodsingle
import (
  "reflect"
  "testing"
  "github.com/jackc/pgx/v5/pgconn"
)
|} ^ scanner_row ^ {|
func TestSingleVariantSQLShape(t *testing.T) {
  values := []any{"one", []byte(`{"tag":"Packed","fields":{"number":123456789012345678901234567890,"text":"hello"}}`), []byte(`{"tag":"Only"}`), []byte(`{"tag":"Tuple2","fields":{"first":7,"second":"pair"}}`)}
  row, err := teslScanDocument(rawRow{values})
  if err != nil || row.Packet.PackedNumber.String() != "123456789012345678901234567890" || row.Packet.PackedText != "hello" || row.Pair.Tuple2First.String() != "7" || row.Pair.Tuple2Second != "pair" {
    t.Fatalf("tagless Go layout: %+v %v", row, err)
  }
  for _, invalid := range []string{`null`, `{"tag":"Wrong"}`, `{"tag":"Packed","fields":{"number":1}}`, `{"tag":"Packed","fields":{"number":"wrong","text":"hello"}}`} {
    bad := append([]any(nil), values...)
    bad[1] = []byte(invalid)
    mustPanic(t, func() { _, _ = teslScanDocument(rawRow{bad}) })
  }
  values[2] = []byte(`{"tag":"Wrong"}`)
  mustPanic(t, func() { _, _ = teslScanDocument(rawRow{values}) })
}
|} ^ (if explicit_codec then {|
func TestSingleVariantExplicitCodec(t *testing.T) {
  raw, err := teslrt.ParseColumnJSON(teslrt.MustEncodeJSON(EncodePacketJSON(Sample())))
  if err != nil { t.Fatal(err) }
  result := DecodePacketJSON(raw)
  value, ok := result.Value()
  if !ok || value.PackedText != "hello" || value.PackedNumber.String() != "123456789012345678901234567890" { t.Fatalf("roundtrip: %+v", result) }
  if !DecodeSingletonJSON(EncodeSingletonJSON(Singleton{})).OK() { t.Fatal("nullary roundtrip") }
  if !DecodeSingletonJSON("Only").OK() { t.Fatal("legacy nullary tag") }
  if DecodePacketJSON("Packed").OK() { t.Fatal("a bare tag lost its payload") }
}
|} else "") in
  let test = if explicit_codec then Str.global_replace (Str.regexp_string "\"reflect\"")
    "\"reflect\"\n  \"tesl.generated/teslmodsingle/internal/teslrt\"" test else test in
  execute root write (compile file) ["internal/teslmodsingle/single_regression_test.go", test])

let recursive_adt explicit_codec boxed = with_project (fun root write ->
  let file = write "recursive.tesl" ("module Recursive exposing [sample, store, read, Tree(..), Document]\n" ^ imports ^ {|
import Tesl.ApiTest exposing [statusOk]
type Tree
  = Leaf
  | Branch left: Tree right: Tree
|} ^ (if boxed then "  | Wide " ^ String.concat " " (List.init 24 (fun n ->
        "field" ^ string_of_int n ^ ": String")) ^ "\n" else "") ^
  (if explicit_codec then "codec Tree { adtJson }\n" else "") ^ {|
entity Document table "documents" primaryKey id { id: String, tree: Tree }
|} ^ database "Document" ^ {|
fn sample() -> Tree = Branch Leaf (Branch Leaf Leaf)
fn store(tree: Tree) -> Document requires [dbWrite Document] =
  insert Document { id: "tree", tree: tree }
fn read() -> Maybe Document requires [dbRead Document] =
  selectOne doc from Document where doc.id == "tree"
test "a recursive column retains its full value" requires [dbRead Document, dbWrite Document] {
  let _ = store (sample ())
  case read () of
    Nothing -> expect False
    Something row -> expect row.tree == sample ()
}
handler get sampleTree() -> Tree = sample ()
api TreeApi { get "/tree" -> Tree }
server TreeServer for TreeApi { sampleTree }
api-test "recursive response encoding preserves all children" for TreeServer {
  let response = get "/tree"
  expect response.status == 200
  expect response.body.tag == "Branch"
  expect response.body.fields.left.tag == "Leaf"
  expect response.body.fields.right.tag == "Branch"
  expect response.body.fields.right.fields.left.tag == "Leaf"
  expect response.body.fields.right.fields.right.tag == "Leaf"
}
|}) in
  (* This regression used to hang during emission. Keep the compiler itself in
     a bounded child process so a recurrence cannot stall the entire CI suite. *)
  let compiler = Filename.concat (Filename.dirname Sys.executable_name) "../bin/main.exe" in
  let log = Filename.concat root "compile.log" in
  let command = Printf.sprintf "timeout 15s %s --backend go %s --out %s > %s 2>&1"
    (Filename.quote compiler) (Filename.quote file) (Filename.quote (Filename.concat root "out"))
    (Filename.quote log) in
  let status = Sys.command command in
  if status <> 0 then failf "recursive column emission exited %d: %s" status
    (In_channel.with_open_text log In_channel.input_all);
  let explicit_tests = if not explicit_codec then "" else {|
func TestRecursiveCodec(t *testing.T) {
  encoded := EncodeTreeJSON(Sample())
  decoded := DecodeTreeJSON(encoded)
  value, ok := decoded.Value()
  if !ok || !value.TeslEqual(Sample()) { t.Fatal("codec lost recursive payload", decoded.Message()) }
  // Both legacy leaf spellings remain valid. A constructor requiring children
  // must never turn a bare tag, malformed field map or bad child into zero values.
  for _, leaf := range []any{"Leaf", map[string]any{"tag":"Leaf"}} {
    decoded := DecodeTreeJSON(leaf)
    value, ok := decoded.Value()
    if !ok || value.Tag != TreeLeaf { t.Fatal("leaf compatibility lost") }
  }
  for _, invalid := range []any{
    "Branch", nil, map[string]any{"tag":"Branch"},
    map[string]any{"tag":"Branch", "fields":false},
    map[string]any{"tag":"Branch", "fields":map[string]any{"left":"Leaf"}},
    map[string]any{"tag":"Branch", "fields":map[string]any{"left":"Leaf", "right":"Unknown"}},
    map[string]any{"tag":"Branch", "fields":map[string]any{"left":"Leaf", "right":nil}},
  } {
    if DecodeTreeJSON(invalid).OK() { t.Errorf("accepted invalid payload: %#v", invalid) }
  }
}
|} in
  execute root write [] ["internal/teslmodrecursive/recursive_column_test.go", {|
package teslmodrecursive
import (
  "reflect"
  "testing"
  "github.com/jackc/pgx/v5/pgconn"
)
|} ^ scanner_row ^ {|
func TestRecursiveColumnDecode(t *testing.T) {
  good := []byte(`{"tag":"Branch","fields":{"left":{"tag":"Leaf"},"right":{"tag":"Branch","fields":{"left":{"tag":"Leaf"},"right":{"tag":"Leaf"}}}}}`)
  row, err := teslScanDocument(rawRow{[]any{"tree", good}})
  if err != nil { t.Fatal(err) }
  if !row.Tree.TeslEqual(Sample()) { t.Fatal("recursive payload was lost or misboxed") }
  for _, invalid := range []string{
    `{"tag":"Branch","fields":{"left":{"tag":"Leaf"},"right":{"tag":"Missing"}}}`,
    `{"tag":"Branch","fields":{"left":{"tag":"Leaf"}}}`,
    `{"tag":"Branch","fields":{"left":null,"right":{"tag":"Leaf"}}}`,
  } {
    mustPanic(t, func() { _, _ = teslScanDocument(rawRow{[]any{"tree", []byte(invalid)}}) })
  }
}
|} ^ explicit_tests])

let () = run "jsonb columns" ["storage boundary", [
  test_case "local, nullable and nested records revalidate proofs" `Slow local_records;
  test_case "private same-named records keep their owning codecs" `Slow (private_nominal_codecs false);
  test_case "transitive private records keep their owning codecs" `Slow (private_nominal_codecs true);
  test_case "missing or forbidden codec directions are refused" `Quick forbidden_directions;
  test_case "stored ADTs respect explicit forbidden codec directions" `Quick forbidden_adt_directions;
  test_case "same-named ADT columns retain their own payload types" `Slow (fun () -> same_named_adts false);
  test_case "same-named imported boxed ADTs retain their payload owners" `Slow (fun () -> same_named_adts true);
  test_case "generic ADT columns retain each instantiation" `Slow (fun () -> generic_adts false false);
  test_case "imported generic ADT columns retain each instantiation" `Slow (fun () -> generic_adts true false);
  test_case "boxed generic ADT columns retain each instantiation" `Slow (fun () -> generic_adts false true);
  test_case "imported boxed generic ADT columns retain each instantiation" `Slow (fun () -> generic_adts true true);
  test_case "single-variant ADTs preserve their JSON tags" `Slow (fun () -> single_variant_adts false);
  test_case "single-variant ADTs with explicit codecs" `Slow (fun () -> single_variant_adts true);
  test_case "recursive ADT columns with an implicit codec" `Slow (fun () -> recursive_adt false false);
  test_case "recursive ADT columns with an explicit codec" `Slow (fun () -> recursive_adt true false);
  test_case "boxed recursive ADT columns with an implicit codec" `Slow (fun () -> recursive_adt false true);
  test_case "boxed recursive ADT columns with an explicit codec" `Slow (fun () -> recursive_adt true true);
]]
