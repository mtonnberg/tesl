module RH = Migration_row_history
module S = Migration_storage
module R = Migration_transform_rules
module A = Migration_additive
module D = Migration_declaration
module E = Migration_expansion
module I = Migration_inventory

type column = {name:string;scalar:S.scalar;nullable:bool;primary_key:bool;
               default:E.default;introduced_version:int}
type field = {logical:S.column;physical:column}
type reverse_write = {previous:string;current:string;physical:column}
type entity = {source:RH.entity;columns:column list;projection:field list;
               indexes:S.index list;marker_default_generation:int;
               rename_dual_writes:(string * column) list;reverse_writes:reverse_write list}
type window = {binding:RH.binding;before:entity;after:entity;
               requires_final_generation:int;invalidation_columns:column list;
               rename_dual_writes:(string * column) list}
type version = {version:int;entities:entity list;windows:window list;requires_contract_version:int option}
type t = {history:RH.t;versions:version list}
type projection = {entity:entity;fields:field list}
let history t = t.history
let versions t = t.versions
let projection_fields p = p.fields
let projection_entity p = p.entity
exception Invalid of Migration_sparse.error list
let reject loc message = raise (Invalid [{Migration_sparse.code="MIG016";loc;message;related=[]}])
let get = function Ok value -> value | Error errors -> raise (Invalid errors)
let protect f = try Ok (f ()) with Invalid errors -> Error errors
let loc = Location.dummy_loc "<migration-retained-storage>"
let order_columns = List.sort (fun (a:column) b -> String.compare a.name b.name)
let order_indexes = List.sort (fun (a:S.index) b -> String.compare a.name b.name)
let field (e:entity) name =
 match List.find_opt (fun f -> f.logical.field.name=name) e.projection with
 | Some f -> f
 | None -> reject e.source.table.entity.entity_loc ("missing retained field projection: " ^ name)
let shape (c:S.column) version nullable default =
 {name=c.name;scalar=c.scalar;nullable;primary_key=c.primary_key;default;introduced_version=version}
let same_carrier (a:S.column) (b:S.column) =
 a.scalar=b.scalar && a.nullable=b.nullable && a.primary_key=b.primary_key

let settle_entity (e:entity) =
 let projection=List.map (fun (f:field) ->
  {f with physical={f.physical with nullable=f.logical.nullable}}) e.projection in
 {e with projection;columns=order_columns (List.map (fun (f:field) -> f.physical) projection);
  indexes=order_indexes e.source.table.indexes;
  marker_default_generation=e.source.generation;rename_dual_writes=[];reverse_writes=[]}

let plan history = protect (fun () ->
 ignore (get (RH.revalidate history));
 let relations=Hashtbl.create 32 in
 let reserve location name =
  if Hashtbl.mem relations name then reject location ("retained PostgreSQL relation name cannot be reused: " ^ name);
  Hashtbl.add relations name () in
 let add_indexes source retained =
  List.fold_left (fun all (index:S.index) ->
   if index.columns=[] || List.length index.columns>32 then
    reject source.RH.table.entity.entity_loc "retained B-tree index requires 1 to 32 columns";
   match List.find_opt (fun (old:S.index) -> old.name=index.name) all with
   | Some old when old=index -> all
   | Some _ -> reject source.table.entity.entity_loc ("retained index definition cannot be replaced: " ^ index.name)
   | None -> reserve source.table.entity.entity_loc index.name;index::all)
   retained source.table.indexes |> order_indexes in
 let born version source =
  let table=source.RH.table in
  reserve table.entity.entity_loc table.name;
  let pk=table.name ^ "_pkey" in
  if String.length pk>63 then reject table.entity.entity_loc "retained table needs a bounded primary-key index name";
  reserve table.entity.entity_loc pk;
  let projection=List.map (fun (logical:S.column) ->
    {logical;physical=shape logical version logical.nullable E.Null}) table.columns in
  {source;projection;columns=order_columns (List.map (fun (f:field) -> f.physical) projection);
   indexes=add_indexes source [];marker_default_generation=1;rename_dual_writes=[];reverse_writes=[]} in
 let prior=ref [] in
 let previous_transform=ref None in
 let planned=List.map (fun (revision:RH.version) ->
  let transforming=List.exists (fun b -> RH.migration_version b=revision.version) (RH.bindings history) in
  let requires_contract_version=if transforming then !previous_transform else None in
  (* Planning states a prerequisite; it does not observe or authorize contraction. *)
  if requires_contract_version<>None then prior:=List.map settle_entity !prior;
  let windows=ref [] in
  let edge=List.find_opt (fun d -> D.version d=revision.version) (RH.declarations history) in
  let entities=List.map (fun (source:RH.entity) ->
   match List.find_opt (fun e -> e.source.identity=source.identity) !prior with
   | None -> born revision.version source
   | Some before ->
    let binding=List.find_opt (fun b -> RH.migration_version b=revision.version &&
      (RH.current b).identity=source.identity) (RH.bindings history) in
    if Option.is_some binding && before.reverse_writes<>[] then
     reject source.table.entity.entity_loc "a further transforming physical window requires a contracted predecessor plan";
    let reverse_writes=ref (match binding with None -> before.reverse_writes | Some _ -> []) in
    Option.iter (fun binding ->
     List.iter (fun (write:Migration_transform.writeback_binding) ->
      let previous=write.mapping.previous.name and current=write.mapping.current.name in
      let add physical = reverse_writes:={previous;current;physical}::!reverse_writes in
      add (field before previous).physical;
      List.iter (fun (owner,physical) -> if owner=previous then add physical) before.rename_dual_writes)
     (RH.row binding).writebacks) binding;
    let columns=ref before.columns in
    let add (logical:S.column) nullable default =
     if List.exists (fun (c:column) -> c.name=logical.name) !columns then
      reject logical.field.loc ("retained physical column cannot be reused: " ^ logical.name);
     (match default with E.Null -> () | E.Constant value -> ignore (get (E.validate_assignment logical value)));
     let physical=shape logical revision.version nullable default in
     columns:=physical::!columns;{logical;physical} in
    let rename_writes=ref [] in
    let inherit_aliases current previous =
     List.iter (fun (owner,physical) ->
      if owner=previous then rename_writes:=(current,physical)::!rename_writes)
      before.rename_dual_writes in
    let copy (logical:S.column) previous =
     let old=field before previous in
     if old.physical.name<>logical.name || not (same_carrier old.logical logical) then
      reject logical.field.loc "an unchanged logical field must retain its exact PostgreSQL column and carrier";
     inherit_aliases logical.field.name previous;
     {logical;physical=old.physical} in
    let projection=List.map (fun (logical:S.column) ->
     match binding with
     | Some binding ->
      let mapping=(RH.row binding).mapping in
      let target = function
       | R.Copy {current;_} | R.Renamed {current;_} | R.Empty_optional current
       | R.Constant (current,_) | R.Computed current | R.Retyped {current;_} -> current.I.name in
      (match List.find_opt (fun m -> target m=logical.field.name) mapping.values with
       | Some (R.Retyped _) -> add logical true E.Null
       | Some (R.Copy {previous;_}) -> copy logical previous.name
       | Some (R.Renamed {previous;_}) ->
        let old=field before previous.name in
        if not (same_carrier old.logical logical) then
         reject logical.field.loc "a retained Rename requires equal SQL carriers";
        inherit_aliases logical.field.name previous.name;
        rename_writes:=(logical.field.name,old.physical)::!rename_writes;
        add logical true E.Null
       | Some (R.Empty_optional _ | R.Constant _ | R.Computed _) -> add logical true E.Null
       | None -> reject logical.field.loc "checked transformation omitted a target storage field")
     | None ->
      (match List.find_opt (fun f -> f.logical.field.name=logical.field.name) before.projection with
       | Some _ -> copy logical logical.field.name
       | None ->
        let adapters=Option.fold ~none:[] ~some:(fun d -> A.entities (D.additive d)) edge in
        let adapter=List.find_opt (fun (a:A.entity) -> a.identity=source.identity) adapters in
        let values=Option.fold ~none:[] ~some:(fun (a:A.entity) -> a.values) adapter in
        let target = function A.Existing {current;_} | A.Empty_optional current | A.Constant (current,_) -> current.I.name in
        match List.find_opt (fun m -> target m=logical.field.name) values with
        | Some (A.Empty_optional _) -> add logical logical.nullable E.Null
        | Some (A.Constant (_,value)) -> add logical logical.nullable (E.Constant value)
        | Some (A.Existing _) | None -> reject logical.field.loc "new additive storage requires its exact checked default judgment")) source.table.columns in
    let after={source;columns=order_columns !columns;projection;
      indexes=add_indexes source before.indexes;
      rename_dual_writes=List.sort_uniq compare !rename_writes;
      reverse_writes=List.sort_uniq compare !reverse_writes;
      marker_default_generation=(match binding with Some b -> (RH.previous b).generation | None -> before.marker_default_generation)} in
    Option.iter (fun binding ->
     windows:={binding;before;after;requires_final_generation=(RH.previous binding).generation;
       invalidation_columns=order_columns (List.map (fun (f:field) -> f.physical) before.projection);
       rename_dual_writes=after.rename_dual_writes}::!windows) binding;
    after) revision.entities in
  prior:=entities;
  if transforming then previous_transform:=Some revision.version;
  {version=revision.version;entities;windows=List.rev !windows;requires_contract_version}) (RH.versions history) in
 {history;versions=planned})

let project t ~version ~entity ~logical_fields = protect (fun () ->
 let revision=match List.find_opt (fun v -> v.version=version) t.versions with
  | Some v -> v | None -> reject loc "projection names a revision outside its retained history" in
 let owner=match List.find_opt (fun e -> e.source.identity=entity) revision.entities with
  | Some e -> e | None -> reject loc "projection names an entity outside its retained revision" in
 let expected=List.map (fun f -> f.logical.field.name) owner.projection |> List.sort String.compare in
 if List.sort String.compare logical_fields<>expected then
  reject loc "projection must name every logical field exactly once";
 {entity=owner;fields=List.map (field owner) logical_fields})

let settled_version t ~version = protect (fun () ->
 let retained=match List.find_opt (fun v -> v.version=version) t.versions with
  | Some v -> v | None -> reject loc "settled projection names a revision outside its retained history" in
 let entities=List.map settle_entity retained.entities in
 {version;entities;windows=[];requires_contract_version=None})
