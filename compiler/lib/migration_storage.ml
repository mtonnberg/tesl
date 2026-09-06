open Migration_canonical
module I = Migration_inventory
module S = Migration_sparse

type scalar = Numeric | Float8 | Text | Bool | Int4 | Int8 | Jsonb
let scalar_name = function
 | Numeric -> "numeric" | Float8 -> "float8" | Text -> "text" | Bool -> "bool"
 | Int4 -> "int4" | Int8 -> "int8" | Jsonb -> "jsonb"
type column = {field:I.stored_field;name:string;scalar:scalar;nullable:bool;primary_key:bool}
type index = {name:string;columns:string list;unique:bool}
type table = {entity:I.stored_entity;name:string;columns:column list;indexes:index list}
type t = {inventory:I.t;tables:table list;digest:string}
let inventory t = t.inventory
let tables t = t.tables
let digest t = t.digest
exception Invalid of S.error
let reject loc message = raise (Invalid {S.code="MIG016";loc;message;related=[]})
let identifier loc name =
 if name="" || String.length name > 63 || String.contains name '\000' || not (String.is_valid_utf_8 name) then
  reject loc "PostgreSQL storage names must be nonempty UTF-8, contain no NUL and fit in 63 bytes";
 name
let primitive = function
 | Seq [Bytes "named";Seq [Bytes "reference";Bytes "type";Seq [Bytes "primitive";Bytes name]]] -> Some name
 | _ -> None
let maybe = "Tesl.Maybe.Maybe"
let rec storage inventory loc visited node =
 match primitive node with
 | Some "Tesl.Prelude.Int" -> Numeric,false,false
 | Some "Tesl.Float.Float" -> Float8,false,false
 | Some "Tesl.Prelude.String" -> Text,false,false
 | Some "Tesl.Prelude.Bool" -> Bool,false,false
 (* The Go backend erases Int32 to its Int runtime alias and currently emits
    NUMERIC. Preserve that installed layout; an explicit integer/bigint override
    may use the checked Int32 range without treating arbitrary Int as bounded. *)
 | Some "Tesl.Int32.Int32" -> Numeric,false,true
 | Some "Tesl.Time.PosixMillis" -> Int8,false,false
 | Some name -> reject loc ("PostgreSQL migration storage does not yet support primitive " ^ name)
 | None -> match node with
   | Seq [Bytes "apply";head;inner] when primitive head=Some maybe ->
     let scalar,nullable,bounded32 = storage inventory loc visited inner in
     if nullable then reject loc "nested Maybe values cannot share one SQL NULL representation";
     scalar,true,bounded32
   | Seq [Bytes "named";reference] -> owned inventory loc visited reference
   | Seq (Bytes "apply" :: _) ->
     let rec head = function Seq [Bytes "apply";f;_] -> head f | x -> x in
     (match head node with
      | Seq [Bytes "named";reference] ->
        (match I.owned_type_definition inventory reference with
         | Some ({I.declaration_kind=I.Adt;_},_) -> Jsonb,false,false
         | _ -> reject loc "applied field carrier is not a supported owned ADT")
      | _ -> reject loc "unsupported applied PostgreSQL field carrier")
   | _ -> reject loc "unsupported PostgreSQL field carrier"
and owned inventory loc visited reference =
 match I.owned_type_definition inventory reference with
 | None -> reject loc "PostgreSQL field type has no checked owned definition"
 | Some (declaration,body) ->
   if List.mem declaration.I.qualified_name visited then reject loc "recursive scalar wrapper has no finite PostgreSQL carrier";
   let visited = declaration.qualified_name :: visited in
   match declaration.declaration_kind,body with
   | I.Record,_ | I.Adt,_ -> Jsonb,false,false
   | I.Newtype,Seq [Bytes "newtype";_;_;base] ->
     let scalar,nullable,bounded32 = storage inventory loc visited base in
     if nullable then reject loc "a newtype wrapping Maybe requires a distinct storage representation";
     scalar,false,bounded32
   | _ -> reject loc "only scalar newtypes, records and ADTs have migration field carriers"
let override loc inferred ~bounded32 = function
 | None -> inferred
 | Some name ->
   let declared = match String.lowercase_ascii name with
    | "numeric" | "decimal" -> Numeric
    | "float8" -> Float8
    | "text" -> Text
    | "bool" | "boolean" -> Bool
    | "int" | "integer" | "int4" -> Int4
    | "bigint" | "int8" -> Int8
    | "jsonb" -> Jsonb
    | other -> reject loc ("PostgreSQL migration storage requires a supported built-in type; " ^ other ^ " needs a separately checked mapping") in
   if inferred <> declared && not (bounded32 && inferred=Numeric && (declared=Int4 || declared=Int8)) then
    reject loc ("storage override " ^ name ^ " changes the field's native carrier " ^ scalar_name inferred ^ "; assignment and range evidence is required");
   declared
(* Keep existing emitter name derivation for ordinary indexes. Reject a truncated
   UTF-8 fragment rather than passing an invalid name to PostgreSQL. *)
let derived_index loc name =
 let hash = ref 0x811c9dc5 in
 String.iter (fun c -> hash := ((!hash lxor Char.code c) * 16777619) land 0xffffffff) name;
 let result = if String.length name <= 63 then name else
  let suffix = Printf.sprintf "_%x" !hash in String.sub name 0 (63-String.length suffix) ^ suffix in
 identifier loc result
let table inventory entity =
 let name = identifier entity.I.entity_loc entity.table_name in
 let columns = I.field_shapes inventory |> List.filter_map (fun shape ->
  let field = shape.I.stored_field in
  if field.entity<>entity.entity_name then None else
  let scalar,nullable,bounded32 = storage inventory field.loc [] shape.type_identity in
  let scalar = override field.loc scalar ~bounded32 shape.db_type in
  let primary_key = field.name=entity.primary_key in
  if nullable && primary_key then reject field.loc "a PostgreSQL primary key cannot be nullable";
  Some {field;name=identifier field.loc (Validation_common.sql_column_name field.name);scalar;nullable;primary_key})
  |> List.sort (fun (a : column) b -> String.compare a.name b.name) in
 let field_name field = match List.find_opt (fun c -> c.field.name=field) columns with
  | Some c -> c.name | None -> reject entity.entity_loc "index references an unknown storage field" in
 let indexes = match I.entity_indexes inventory ~entity:entity.entity_name with
  | Some (Seq entries) -> List.map (function
    | Seq [Bytes "index";Seq [Bytes "bool";Bytes unique];Seq fields;explicit] ->
      let fields = List.map (function Bytes name -> field_name name | _ -> assert false) fields in
      let ix_name = match explicit with
       | Seq [Bytes "none"] -> derived_index entity.entity_loc (name ^ "_" ^ String.concat "_" fields ^ "_idx")
       | Seq [Bytes "some";Bytes text] -> identifier entity.entity_loc text
       | _ -> assert false in
      {name=ix_name;columns=fields;unique=unique="true"}
    | _ -> assert false) entries |> List.sort (fun (a : index) b -> String.compare a.name b.name)
  | _ -> assert false in
 {entity;name;columns;indexes}
let describe inventory =
 try
  let tables = I.stored_entities inventory |> List.map (table inventory)
   |> List.sort (fun a b -> String.compare a.name b.name) in
  let names = Hashtbl.create 16 in
  let reserve loc kind name = match Hashtbl.find_opt names name with
   | None -> Hashtbl.add names name (kind,loc)
   | Some (previous,old_loc) -> raise (Invalid {S.code="MIG016";loc;
     message="PostgreSQL relation name collision: " ^ name ^ " (" ^ previous ^ "/" ^ kind ^ ")";
     related=[old_loc,"previous relation"]}) in
  List.iter (fun t -> reserve t.entity.entity_loc "table" t.name) tables;
  List.iter (fun t -> List.iter (fun (i : index) -> reserve t.entity.entity_loc "index" i.name) t.indexes) tables;
  let scalar (c : column) = Seq [Bytes c.name;Bytes (scalar_name c.scalar);bool c.nullable;bool c.primary_key] in
  let index (i : index) = Seq [Bytes i.name;Seq (List.map bytes i.columns);bool i.unique] in
  let storage t = Seq [Bytes t.name;Seq (List.map scalar t.columns);Seq (List.map index t.indexes)] in
  let digest = Migration_canonical.digest Migration
    (Seq [Bytes "postgres-storage-v1";I.snapshot inventory;Seq (List.map storage tables)]) in
  Ok {inventory;tables;digest}
 with Invalid error -> Error [error]
