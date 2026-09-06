(** Pure physical expansion over already checked source inventories and edges.
    Source/ABI guards, Go emission, persisted history and execution remain callers'
    separate obligations. No compiler driver or source discovery runs here. *)
module I = Migration_inventory
module S = Migration_sparse
module D = Migration_declaration
module P = Migration_storage
open Migration_canonical

type default = Null | Constant of node
type operation =
 | Create_table of P.table
 | Add_column of {table:string;column:P.column;default:default}
 | Build_index of {table:string;index:P.index;window_risk:string option}
 | Retain_table of string
 | Retain_index of {table:string;index:P.index;window_risk:string option}
type catalog_column = {column:P.column;default:default}
type catalog_table = {name:string;columns:catalog_column list;indexes:P.index list}
type step = {version:int;snapshot_hash:string;operations:operation list;epoch_preserving:bool;
             catalog:catalog_table list}
exception Invalid of S.error list
let reject ?(code="MIG016") loc message = raise (Invalid [{S.code;loc;message;related=[]}])
let checked = function Ok x -> x | Error errors -> raise (Invalid errors)
let relative inventory name =
 let prefix = I.root_module inventory ^ "." in
 if not (String.starts_with ~prefix name) then assert false;
 String.sub name (String.length prefix) (String.length name-String.length prefix)
let column_node (c : P.column) = Seq [Bytes c.name;Bytes (P.scalar_name c.scalar);bool c.nullable;bool c.primary_key]
let index_node (i : P.index) = Seq [Bytes i.name;Seq (List.map bytes i.columns);bool i.unique]
let table_node (t : P.table) = Seq [Bytes t.name;Seq (List.map column_node t.columns);Seq (List.map index_node t.indexes)]
let default_node = function Null -> Seq [Bytes "null"] | Constant n -> Seq [Bytes "constant";n]
let risk_node = function None -> Seq [] | Some s -> Seq [Bytes s]
let operation_node = function
 | Create_table t -> Seq [Bytes "create-table";table_node t]
 | Add_column {table;column;default} -> Seq [Bytes "add-column";Bytes table;column_node column;default_node default]
 | Build_index {table;index;window_risk} -> Seq [Bytes "build-index-concurrently";Bytes table;index_node index;
     risk_node window_risk]
 | Retain_table table -> Seq [Bytes "retain-table";Bytes table]
 | Retain_index {table;index;window_risk} -> Seq [Bytes "retain-index";Bytes table;index_node index;risk_node window_risk]
let catalog_node (t : catalog_table) = Seq [Bytes t.name;
 Seq (List.map (fun (c : catalog_column) -> Seq [column_node c.column;default_node c.default]) t.columns);
 Seq (List.map index_node t.indexes)]
let step_node s = Seq [Bytes (string_of_int s.version);Bytes s.snapshot_hash;bool s.epoch_preserving;
 Seq (List.map operation_node s.operations);Seq (List.map catalog_node s.catalog)]
let step_hash s = digest Migration (Seq [Bytes "postgres-expansion-step-v1";step_node s])
let equivalent_index (a : P.index) (b : P.index) = a.columns=b.columns && a.unique=b.unique
let supported_index loc (i : P.index) =
 if i.columns=[] || List.length i.columns>32 then
  reject loc "the supported PostgreSQL B-tree mapping requires 1 to 32 key columns"
let bounded_domain (table : P.table) (index : P.index) =
 List.for_all (fun name ->
  let c = List.find (fun (c : P.column) -> c.name=name) table.columns in
  match c.scalar with P.Bool | P.Int4 | P.Int8 | P.Float8 -> true | _ -> false) index.columns
let assignment (c : P.column) value =
 let valid = match c.scalar,value with
 | P.Numeric,Seq [Bytes "int";Bytes n] ->
   let digits = String.length n - (if String.starts_with ~prefix:"-" n then 1 else 0) in digits<=131072
 | P.Float8,Seq [Bytes "float64";Bytes _] | P.Bool,Seq [Bytes "bool";Bytes _] -> true
 | P.Text,Seq [Bytes "string";Bytes text] -> String.is_valid_utf_8 text && not (String.contains text '\000')
 | _ -> false in
 if not valid then reject c.field.loc ("Default does not fit the supported PostgreSQL carrier for " ^ c.field.name)

(* Replay only checked operations to obtain the physical superset at each history
   position. Logical Drop and removed indexes do not remove physical contracts;
   defaults installed by an earlier additive step remain in every later catalog. *)
let project_catalog steps =
 let tables = Hashtbl.create 16 in
 let update table f = match Hashtbl.find_opt tables table with
  | None -> reject (Location.dummy_loc "") ("catalog projection has no retained table " ^ table)
  | Some t -> Hashtbl.replace tables table (f t) in
 List.map (fun step ->
  List.iter (function
   | Create_table (t : P.table) -> Hashtbl.add tables t.name
       {name=t.name;columns=List.map (fun column -> {column;default=Null}) t.columns;indexes=t.indexes}
   | Add_column {table;column;default} -> update table (fun t -> {t with columns=t.columns @ [{column;default}]})
   | Build_index {table;index;_} -> update table (fun t -> {t with indexes=t.indexes @ [index]})
   | Retain_table _ | Retain_index _ -> ()) step.operations;
  let catalog = Hashtbl.to_seq_values tables |> List.of_seq |>
   List.sort (fun (a : catalog_table) b -> String.compare a.name b.name) |>
   List.map (fun (t : catalog_table) -> {t with
    columns=List.sort (fun a b -> String.compare a.column.name b.column.name) t.columns;
    indexes=List.sort (fun (a : P.index) b -> String.compare a.name b.name) t.indexes}) in
  {step with catalog}) steps

(* The entire retained source chain is visited, including versions that no longer
   declare an entity. Physical objects are never freed by a logical Drop. *)
let derive ~initial_version baseline edges =
 let tables = Hashtbl.create 16 and relations = Hashtbl.create 32 in
 let reserve loc name =
   if Hashtbl.mem relations name then reject loc ("retained PostgreSQL relation name cannot be reused: " ^ name);
   Hashtbl.add relations name () in
 let indexes = Hashtbl.create 16 in
 let admitted = ref [] in
 let table_indexes name = Option.value (Hashtbl.find_opt indexes name) ~default:[] in
 let add_table (t : P.table) =
   reserve t.entity.entity_loc t.name;
   (* PostgreSQL chooses the primary-key index name when DDL omits it. Reject
      ambiguous names here until execution supplies an explicit checked name. *)
   let primary_name = t.name ^ "_pkey" in
   if String.length primary_name>63 then reject t.entity.entity_loc "migration tables require an explicit bounded primary-key index name before execution can support this table name";
   reserve t.entity.entity_loc primary_name;
   List.iter (fun (i : P.index) -> supported_index t.entity.entity_loc i;reserve t.entity.entity_loc i.name) t.indexes;
   Hashtbl.add tables t.name t;
   Hashtbl.add indexes t.name t.indexes;
   Create_table t in
 let baseline_storage = checked (P.describe baseline) in
 let first = {version=initial_version;snapshot_hash=P.digest baseline_storage;
   operations=List.map add_table (P.tables baseline_storage);epoch_preserving=true;catalog=[]} in
 admitted := [P.tables baseline_storage];
 let previous_inventory = ref baseline in
 let later = List.map (fun (edge : D.t) ->
   let before,after = S.inventories (D.coverage edge) in
   let version = D.version edge in
   if I.snapshot before <> I.snapshot !previous_inventory || I.root_module before <> I.root_module !previous_inventory ||
      I.compiler_abi before <> I.compiler_abi !previous_inventory then
     reject (Location.dummy_loc "") "physical planning requires the exact complete adjacent schema chain";
   let after_storage = checked (P.describe after) in
   let before_storage = checked (P.describe before) in
   let fresh_tables = P.tables after_storage in
   let operation_list = ref [] in
   let add op = operation_list := op :: !operation_list in
   List.iter (function
    | S.Added entity ->
      let table = List.find (fun (t : P.table) -> t.entity.entity_name=entity.entity_name) fresh_tables in
      add (add_table table)
    | S.Removed entity -> add (Retain_table entity.table_name)
    | S.Paired pair ->
      let table = List.find (fun (t : P.table) -> t.entity.entity_name=pair.current.entity_name) fresh_tables in
      let previous = List.find (fun (t : P.table) -> t.entity.entity_name=pair.previous.entity_name) (P.tables before_storage) in
      let adapter = List.find_opt (fun (e : Migration_additive.entity) -> e.identity=relative after pair.current.entity_name)
        (Migration_additive.entities (D.additive edge)) in
      Option.iter (fun (adapter : Migration_additive.entity) ->
       List.iter (function
        | Migration_additive.Existing _ -> ()
        | Migration_additive.Empty_optional field ->
          let c = List.find (fun (c : P.column) -> c.field.name=field.name) table.columns in
          add (Add_column {table=table.name;column=c;default=Null})
        | Migration_additive.Constant (field,value) ->
          let c = List.find (fun (c : P.column) -> c.field.name=field.name) table.columns in
          assignment c value;
          add (Add_column {table=table.name;column=c;default=Constant value})) adapter.values) adapter;
      let retained = table_indexes table.name in
      List.iter (fun (old : P.index) ->
        if List.exists (equivalent_index old) previous.indexes && not (List.exists (equivalent_index old) table.indexes) then
          let window_risk = if not old.unique && bounded_domain table old then None else
            Some "the retained index can still reject writes; retiring its admitted users and applying its contract is required to remove that restriction" in
          add (Retain_index {table=table.name;index=old;window_risk})) retained;
      List.iter (fun (index : P.index) ->
       supported_index table.entity.entity_loc index;
       if not (List.exists (equivalent_index index) retained) then begin
        let all_new_null = List.for_all (fun name ->
          let c = List.find (fun (c : P.column) -> c.name=name) table.columns in
          c.nullable && Option.fold ~none:false ~some:(fun (a : Migration_additive.entity) ->
            List.exists (function Migration_additive.Empty_optional f -> f.name=c.field.name | _ -> false) a.values) adapter &&
          List.for_all (fun schema -> List.for_all (fun (t : P.table) -> t.name<>table.name ||
            not (List.exists (fun (old : P.column) -> old.name=name) t.columns)) schema) !admitted) index.columns in
        let bounded_old_domain = bounded_domain table index in
        let window_risk =
          if all_new_null || (not index.unique && bounded_old_domain) then None
          else Some (if index.unique then "unique keys can be written by an admitted schema or supplied by a default; close the additive epoch before expansion"
             else "the admitted key domain is not proved to fit a total supported B-tree index; close the additive epoch before expansion") in
        let suffix = "__v" ^ string_of_int version in
        let name = if String.length index.name+String.length suffix<=63 then index.name ^ suffix else
          let hash = String.sub (Migration_hash.digest index.name) 0 12 in
          "tesl_index_" ^ hash ^ suffix in
        reserve table.entity.entity_loc name;
        let physical_index = {index with P.name=name} in
        Hashtbl.replace indexes table.name (table_indexes table.name @ [physical_index]);
        add (Build_index {table=table.name;index=physical_index;window_risk})
       end) table.indexes;
      (* Columns are monotonic in this subset. Logical table absence never
         replaces this physical record, so later name reuse is refused. *)
      Hashtbl.replace tables table.name table) (S.entities (D.coverage edge));
   admitted := fresh_tables :: !admitted;
   previous_inventory := after;
   let operations = List.rev !operation_list in
   {version;snapshot_hash=P.digest after_storage;operations;catalog=[];
    epoch_preserving=not (List.exists (function Build_index {window_risk=Some _;_} | Retain_index {window_risk=Some _;_} -> true | _ -> false) operations)}) edges in
 project_catalog (first :: later)

(* A complete checked source chain remains mandatory even when installation
   starts later. Every supplied inventory must be the exact inventory judged by
   its adjacent declarations, not merely one with an equal SQL carrier. *)
let same_inventory a b = I.snapshot a=I.snapshot b && I.root_module a=I.root_module b &&
 I.compiler_abi a=I.compiler_abi b
let generate ~initial_version ~schemas ~edges =
 try
  let loc = Location.dummy_loc "" in
  if initial_version<1 || initial_version>2147483646 || initial_version>List.length schemas then
   reject ~code:"MIG020" loc "initial installation version must name a retained source revision";
  if schemas=[] || List.length edges+1<>List.length schemas then
   reject ~code:"MIG001" loc "physical planning requires a complete source history";
  let rec check_chain version schemas edges = match schemas,edges with
   | [_],[] -> ()
   | a :: (b :: _ as rest),edge :: later ->
     let before,after = S.inventories (D.coverage edge) in
     if D.version edge<>version || not (same_inventory before a) || not (same_inventory after b) then
      reject loc "physical planning requires the exact complete adjacent schema chain";
     check_chain (version+1) rest later
   | _ -> reject ~code:"MIG001" loc "physical planning requires a complete source history" in
  check_chain 2 schemas edges;
  let complete_steps = derive ~initial_version:1 (List.hd schemas) edges in
  Ok (if initial_version=1 then complete_steps else
    derive ~initial_version (List.nth schemas (initial_version-1))
      (List.filter (fun edge -> D.version edge>initial_version) edges))
 with Invalid errors -> Error errors

(** The consumer supplies its JSON string encoder; physical transport has one owner. *)
let step_to_json ?(include_catalog=true) ~quote s =
 let array f xs = "[" ^ String.concat "," (List.map f xs) ^ "]" in
 let json_column (c : P.column) = Printf.sprintf {|{"name":%s,"type":%s,"nullable":%b,"primaryKey":%b}|}
  (quote c.name) (quote (P.scalar_name c.scalar)) c.nullable c.primary_key in
 let json_index (i : P.index) = Printf.sprintf {|{"name":%s,"columns":%s,"unique":%b,"method":"btree","nullsDistinct":true}|}
  (quote i.name) (array quote i.columns) i.unique in
 let json_default = function Null -> {|{"kind":"null"}|} | Constant n ->
  let kind,value = match n with Seq [Bytes kind;Bytes value] -> kind,value | _ -> assert false in
  Printf.sprintf {|{"kind":%s,"value":%s}|} (quote kind) (quote value) in
 let json_catalog (t : catalog_table) =
  let column (c : catalog_column) = Printf.sprintf
   {|{"name":%s,"type":%s,"nullable":%b,"primaryKey":%b,"default":%s}|}
   (quote c.column.name) (quote (P.scalar_name c.column.scalar)) c.column.nullable c.column.primary_key
   (match c.default with Null -> "null" | Constant _ -> json_default c.default) in
  Printf.sprintf {|{"name":%s,"columns":%s,"indexes":%s}|}
   (quote t.name) (array column t.columns) (array json_index t.indexes) in
 let json_operation = function
  | Create_table t -> Printf.sprintf {|{"kind":"create-table","table":%s,"columns":%s,"indexes":%s}|}
    (quote t.name) (array json_column t.columns) (array json_index t.indexes)
  | Add_column {table;column;default} -> Printf.sprintf {|{"kind":"add-column","table":%s,"column":%s,"default":%s}|}
    (quote table) (json_column column) (json_default default)
  | Build_index {table;index;window_risk} -> Printf.sprintf {|{"kind":"build-index-concurrently","table":%s,"index":%s,"windowRisk":%s,"requiresConcurrentBuilder":true}|}
    (quote table) (json_index index) (Option.fold ~none:"null" ~some:quote window_risk)
  | Retain_table table -> Printf.sprintf {|{"kind":"retain-table","table":%s}|} (quote table)
  | Retain_index {table;index;window_risk} -> Printf.sprintf {|{"kind":"retain-index","table":%s,"index":%s,"requiresContract":true,"windowRisk":%s}|}
    (quote table) (json_index index) (Option.fold ~none:"null" ~some:quote window_risk) in
 Printf.sprintf {|{"version":%d,"snapshotHash":%s,"stepHash":%s,"epochPreserving":%b,"operations":%s%s}|}
  s.version (quote s.snapshot_hash) (quote (step_hash s)) s.epoch_preserving
  (array json_operation s.operations)
  (if include_catalog then ",\"catalog\":" ^ array json_catalog s.catalog else "")
