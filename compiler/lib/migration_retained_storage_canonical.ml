module C = Migration_canonical
module R = Migration_retained_storage
module H = Migration_row_history
module S = Migration_storage
let atom s = C.Bytes s
let list xs = C.Seq xs
let int n = atom (string_of_int n)
let bool value = list [atom "bool";atom (string_of_bool value)]
let column (c:R.column) = list [atom c.name;atom (S.scalar_name c.scalar);
 bool c.nullable;bool c.primary_key;int c.introduced_version;
 (match c.default with Migration_expansion.Null -> list [atom "null"] | Constant n -> n)]
let index (i:S.index) = list [atom i.name;list (List.map atom i.columns);bool i.unique]
let entity ~reverse (e:R.entity) = list ([atom e.source.identity;atom e.source.table.name;
 int e.source.generation;int e.marker_default_generation;
 atom (snd (H.contract C.Contract e.source.type_contract));
 list (List.map column e.columns);
 list (List.map (fun (f:R.field) -> list [atom f.logical.field.name;atom f.physical.name])
  (List.sort (fun (a:R.field) b -> String.compare a.logical.field.name b.logical.field.name) e.projection));
 list (List.map index e.indexes);
 list (List.map (fun (logical,(physical:R.column)) -> list [atom logical;atom physical.name]) e.rename_dual_writes)] @
 (if reverse then [list (List.map (fun (w:R.reverse_write) ->
   list ([atom w.previous] @ Option.fold ~none:[] ~some:(fun current -> [atom current]) w.current @ [atom w.physical.name])) e.reverse_writes)] else []))
let version_node ~family ~namespace plan (version:R.version) =
 let history=R.history plan in
 let schema n = List.find (fun (v:H.version) -> v.version=n) (H.versions history) in
 let hash n = C.digest C.Snapshot (Migration_inventory.snapshot (schema n).schema) in
 let window (w:R.window) = list [atom w.after.source.identity;
 int w.before.source.generation;int w.after.source.generation;int w.requires_final_generation;
 atom (hash (version.version-1));atom (hash version.version);
 atom (Migration_transform_link.behavior_digest (H.link w.binding));
 list (List.map (fun (c:R.column) -> atom c.name) w.invalidation_columns)] in
 let reverse=version.requires_contract_version<>None || List.exists (fun (e:R.entity) -> e.reverse_writes<>[]) version.entities in
 let legacy=List.exists (fun (e:R.entity) -> List.exists (fun (w:R.reverse_write) -> w.current=None) e.reverse_writes) version.entities in
 list ([atom (if legacy then "tesl-retained-physical-version-v4" else if version.requires_contract_version<>None then "tesl-retained-physical-version-v3" else if reverse then "tesl-retained-physical-version-v2" else "tesl-retained-physical-version-v1");atom family;atom namespace;int version.version;
 atom (hash version.version);atom (S.digest (schema version.version).storage);
 list (List.map (entity ~reverse) version.entities);list (List.map window version.windows)] @
 (if legacy then [list (Option.fold ~none:[] ~some:(fun v -> [int v]) version.requires_contract_version)]
  else Option.fold ~none:[] ~some:(fun v -> [int v]) version.requires_contract_version))

let settled_node ~family ~namespace plan version =
 match version_node ~family ~namespace plan version with
 | C.Seq (_tag::rest) -> C.Seq (atom "tesl-settled-physical-version-v1"::rest)
 | _ -> assert false
