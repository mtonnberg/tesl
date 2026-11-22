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
type reverse_write = {previous:string;current:string option;physical:column}
type entity = {source:RH.entity;columns:column list;projection:field list;
               indexes:S.index list;marker_default_generation:int;
               rename_dual_writes:(string * column) list;reverse_writes:reverse_write list}
type window = {binding:RH.binding;before:entity;after:entity;
               requires_final_generation:int;invalidation_columns:column list;
               rename_dual_writes:(string * column) list}
type version = {version:int;entities:entity list;windows:window list;retirements:entity list;requires_contract_version:int option;
 promotions:(Migration_canonical.node * S.index) list;
 reliance:(int * (Migration_canonical.node * S.index) list) option;
 cancellations:Migration_canonical.node list}
(* A plan over a resumed row history: [boundary] is the prefix's last version
   rebuilt from its carried entities (no windows); [versions] are later ones.
   [cleanup] lists every carried version that needs a reviewed Contract. *)
type t = {history:RH.t;versions:version list;boundary:version option;cleanup:int list;pending:int option}
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

module Carried = struct
 module C = Migration_canonical
 let atom s = C.Bytes s
 let int n = atom (string_of_int n)
 let bool b = atom (if b then "true" else "false")
 let scalars = S.[Numeric;Float8;Text;Bool;Int4;Int8;Jsonb]
 let column (c:column) = C.Seq [atom c.name;atom (S.scalar_name c.scalar);bool c.nullable;bool c.primary_key;
  (match c.default with E.Null -> C.Seq [atom "null"] | E.Constant n -> C.Seq [atom "constant";n]);int c.introduced_version]
 let index (i:S.index) = C.Seq [atom i.name;C.Seq (List.map atom i.columns);bool i.unique]
 let entity (e:entity) = C.Seq [atom e.source.identity;C.Seq (List.map column e.columns);
  C.Seq (List.map (fun (f:field) -> C.Seq [atom f.logical.field.name;column f.physical]) e.projection);
  C.Seq (List.map index e.indexes);int e.marker_default_generation;
  C.Seq (List.map (fun (logical,physical) -> C.Seq [atom logical;column physical]) e.rename_dual_writes)]
 let encode ~pending ~cleanup entities = C.Seq [atom "tesl-retained-prefix-v1";
  C.Seq (Option.fold ~none:[] ~some:(fun v -> [int v]) pending);C.Seq (List.map int cleanup);C.Seq (List.map entity entities)]
 let fail () = invalid_arg "malformed retained-storage prefix"
 let text = function C.Bytes s -> s | C.Seq _ -> fail ()
 let number n = match int_of_string_opt (text n) with Some n -> n | None -> fail ()
 let flag n = match text n with "true" -> true | "false" -> false | _ -> fail ()
 let items = function C.Seq xs -> xs | C.Bytes _ -> fail ()
 let decode_column = function
  | C.Seq [name;scalar;nullable;primary_key;default;introduced] ->
    let scalar=match List.find_opt (fun x -> S.scalar_name x=text scalar) scalars with Some x -> x | None -> fail () in
    let default=match default with C.Seq [C.Bytes "null"] -> E.Null | C.Seq [C.Bytes "constant";n] -> E.Constant n | _ -> fail () in
    {name=text name;scalar;nullable=flag nullable;primary_key=flag primary_key;default;introduced_version=number introduced}
  | _ -> fail ()
 let decode_index = function
  | C.Seq [name;columns;unique] -> {S.name=text name;columns=List.map text (items columns);unique=flag unique}
  | _ -> fail ()
 (* Logical columns and the entity source come from the boundary version. *)
 let decode (boundary:RH.version) = function
  | C.Seq [C.Bytes "tesl-retained-prefix-v1";pending;cleanup;entities] ->
    let pending=match items pending with [] -> None | [v] -> Some (number v) | _ -> fail () in
    let entities=List.map (function
     | C.Seq [identity;columns;projection;indexes;marker;renames] ->
       let source=match List.find_opt (fun (e:RH.entity) -> e.identity=text identity) boundary.entities with
        | Some e -> e | None -> fail () in
       let projection=List.map (function
        | C.Seq [name;physical] ->
          (match List.find_opt (fun (c:S.column) -> c.field.name=text name) source.table.columns with
           | Some logical -> {logical;physical=decode_column physical}
           | None -> fail ())
        | _ -> fail ()) (items projection) in
       {source;columns=List.map decode_column (items columns);projection;indexes=List.map decode_index (items indexes);
        marker_default_generation=number marker;reverse_writes=[];
        rename_dual_writes=List.map (function C.Seq [logical;physical] -> text logical,decode_column physical | _ -> fail ()) (items renames)}
     | _ -> fail ()) (items entities) in
    if List.map (fun e -> e.source.identity) entities<>List.map (fun (e:RH.entity) -> e.identity) boundary.entities then fail ();
    pending,List.map number (items cleanup),entities
  | _ -> fail ()
end

let needs_contract (v:version) = v.windows<>[] || v.retirements<>[] || v.promotions<>[]

let plan history = protect (fun () ->
 ignore (get (RH.revalidate history));
 let carried=Option.map (fun (p:RH.prefix) ->
  let boundary=match RH.versions history with
   | first::_ when first.version=p.through -> first
   | _ -> reject loc "resumed retained storage lost its boundary version" in
  p.through,(try Carried.decode boundary p.retained with Invalid_argument message -> reject loc message)) (RH.prefix history) in
 let relations=Hashtbl.create 32 in
 let reserve location name =
  if Hashtbl.mem relations name then reject location ("retained PostgreSQL relation name cannot be reused: " ^ name);
  Hashtbl.add relations name () in
  let promotion_targets=ref [] in
  let add_indexes source retained =
  List.fold_left (fun all (index:S.index) ->
   if index.columns=[] || List.length index.columns>32 then
    reject source.RH.table.entity.entity_loc "retained B-tree index requires 1 to 32 columns";
   match List.find_opt (fun (old:S.index) -> old.name=index.name) all with
   | Some old when old=index -> all
   | Some _ -> reject source.table.entity.entity_loc ("retained index definition cannot be replaced: " ^ index.name)
   | None -> reserve source.table.entity.entity_loc index.name;index::all)
    retained (List.filter (fun (i:S.index) -> not (List.mem i !promotion_targets)) source.table.indexes) |> order_indexes in
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
  let previous_promotions=ref [] and reliance=ref None in
 let pending_contract=ref None and prior_retirements=ref [] in
 let through=match carried with
  | None -> 0
  | Some (through,(pending,_,entities)) ->
    prior:=entities;pending_contract:=pending;
    List.iter (fun e ->
     let location=e.source.table.entity.entity_loc in
     reserve location e.source.table.name;reserve location (e.source.table.name ^ "_pkey");
     List.iter (fun (i:S.index) -> reserve location i.name) e.indexes) entities;
    through in
 let boundary=Option.map (fun (through,(_,_,entities)) ->
  {version=through;entities;windows=[];retirements=[];requires_contract_version=None;promotions=[];reliance=None;cancellations=[]}) carried in
  let planned=List.filter (fun (revision:RH.version) -> revision.version>through) (RH.versions history) |> List.map (fun (revision:RH.version) ->
   let promotions=match List.find_opt (fun (v:RH.version) -> v.version=revision.version-1) (RH.versions history) with
    | None -> [] | Some previous -> S.promotions ~before:previous.storage ~after:revision.storage in
   let cancellations=match List.find_opt(fun(v:RH.version)->v.version=revision.version-1)(RH.versions history) with
    | None->[]|Some previous->S.cancellations ~before:previous.storage ~after:revision.storage in
   if promotions<>[] && cancellations<>[] then reject loc "simultaneous promotion and cancellation require separate staged revisions";
   if !previous_promotions<>[] then begin
    reliance:=Some(revision.version-1,!previous_promotions);
    prior:=List.map(fun(e:entity)->{e with indexes=order_indexes(List.sort_uniq compare(e.indexes @ e.source.table.indexes))})!prior
   end;
   if !reliance<>None && (promotions<>[] || cancellations<>[]) then reject loc "MIG030: combining another staged decision with an enforced reliance history is unsupported";
   Option.iter(fun(_,guards)->List.iter(fun(prep,target)->
    let table=match prep with Migration_canonical.Seq[_;_;_;_;_;Bytes table;_;_;_;_]->table|_->assert false in
    if not(List.exists(fun(e:RH.entity)->e.table.name=table && List.mem target e.table.indexes)revision.entities) then
     reject loc "staged reliance must retain its exact unique key and target; guarded/enforced cancellation is unsupported")guards)!reliance;
   previous_promotions:=promotions;
   promotion_targets:=List.map snd promotions;
  let transforming=List.exists (fun b -> RH.migration_version b=revision.version) (RH.bindings history) in
  let requires_contract_version= !pending_contract in
  pending_contract:=None;
  (* Planning states a prerequisite; it does not observe or authorize contraction. *)
  if requires_contract_version<>None then prior:=List.filter (fun e ->
    not (List.mem e.source.identity !prior_retirements)) !prior |> List.map settle_entity;
  let retirements=RH.retirements history |> List.filter_map (fun (r:RH.retirement) ->
    if r.version<>revision.version then None else
    match List.find_opt (fun e -> e.source.identity=r.previous.identity) !prior with
    | Some e -> Some e
    | None -> reject loc "table retirement has no exact retained predecessor") in
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
      let previous=write.mapping.previous.name and current=Some write.mapping.current.name in
      let add physical = reverse_writes:={previous;current;physical}::!reverse_writes in
      add (field before previous).physical;
      List.iter (fun (owner,physical) -> if owner=previous then add physical) before.rename_dual_writes)
     (RH.row binding).writebacks;
     List.iter (fun (write:Migration_transform.legacy_binding) ->
      let previous=write.mapping.previous.name in
      let add physical = reverse_writes:={previous;current=None;physical}::!reverse_writes in
      add (field before previous).physical;
      List.iter (fun (owner,physical) -> if owner=previous then add physical) before.rename_dual_writes)
     (RH.row binding).legacies) binding;
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
       | R.Constant (current,_) | R.Computed current | R.Retyped {current;_}
       | R.Revalidated {current;_} -> current.I.name in
      (match List.find_opt (fun m -> target m=logical.field.name) mapping.values with
       | Some (R.Retyped _) -> add logical true E.Null
       | Some (R.Copy {previous;_} | R.Revalidated {previous;_}) -> copy logical previous.name
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
  let entities=List.sort (fun a b -> compare a.source.identity b.source.identity) (entities @ retirements) in
  prior:=entities;prior_retirements:=List.map (fun e -> e.source.identity) retirements;
  if transforming || retirements<>[] then pending_contract:=Some revision.version;
   {version=revision.version;entities;windows=List.rev !windows;retirements;requires_contract_version;promotions;reliance= !reliance;cancellations}) in
 let cleanup=Option.fold ~none:[] ~some:(fun (_,(_,cleanup,_)) -> cleanup) carried @
  List.filter_map (fun v -> if needs_contract v then Some v.version else None) planned in
 {history;versions=planned;boundary;cleanup;pending= !pending_contract})

(* The carried state after [through]: exactly the inputs the next revision's
   planning reads (retained entities, a pending Contract prerequisite) plus the
   versions needing a Contract. Relation names are rebuilt from the entities. *)
let prefix_state t ~through =
 let encode (v:version) ~pending =
  Carried.encode ~pending ~cleanup:(List.filter (fun n -> n<=through) t.cleanup) v.entities in
 let rec at = function
  | [] -> None
  | v::rest when v.version=through ->
    (* The Contract prerequisite pending after [through] is exactly what the
       next planned version requires. *)
    Some (encode v ~pending:(match rest with next::_ -> next.requires_contract_version | [] -> t.pending))
  | _::rest -> at rest in
 match at t.versions with
 | Some node -> Some node
 | None -> match t.boundary with
   | Some b when b.version=through ->
     Some (encode b ~pending:(match t.versions with next::_ -> next.requires_contract_version | [] -> t.pending))
   | _ -> None
let cleanup_versions t = t.cleanup
let find_version t version =
 match List.find_opt (fun v -> v.version=version) t.versions with
 | Some v -> Some v
 | None -> Option.bind t.boundary (fun b -> if b.version=version then Some b else None)
let resumed t = t.boundary<>None

let project t ~version ~entity ~logical_fields = protect (fun () ->
 let revision=match List.find_opt (fun v -> v.version=version) t.versions with
  | Some v -> v | None -> reject loc "projection names a revision outside its retained history" in
 let owner=match List.find_opt (fun e -> e.source.identity=entity &&
  not (List.exists (fun retired -> retired.source.identity=entity) revision.retirements)) revision.entities with
  | Some e -> e | None -> reject loc "projection names an entity outside its retained revision" in
 let expected=List.map (fun f -> f.logical.field.name) owner.projection |> List.sort String.compare in
 if List.sort String.compare logical_fields<>expected then
  reject loc "projection must name every logical field exactly once";
 {entity=owner;fields=List.map (field owner) logical_fields})

let settled_version t ~version = protect (fun () ->
 let retained=match List.find_opt (fun v -> v.version=version) t.versions with
  | Some v -> v | None -> reject loc "settled projection names a revision outside its retained history" in
  let entities=List.filter (fun e -> not (List.exists (fun retired ->
  retired.source.identity=e.source.identity) retained.retirements)) retained.entities |> List.map settle_entity in
  let entities=if retained.promotions=[] then entities else List.map(fun(e:entity)->
   {e with indexes=order_indexes(List.sort_uniq compare(e.indexes @ (List.find(fun old->old.source.identity=e.source.identity)retained.entities).indexes))})entities in
  {version;entities;windows=[];retirements=[];requires_contract_version=None;promotions=[];reliance=None;cancellations=[]})
