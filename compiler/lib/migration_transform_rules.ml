open Migration_inventory
open Migration_canonical
module S = Migration_sparse
module A = Migration_additive

type rule =
  | Rename of { previous : string; current : string; loc : Location.loc }
  | Default of A.default
type mode = Derived | Migrate
type entry = { entity : string; mode : mode; rules : rule list; loc : Location.loc }
type value_source =
  | Copy of { previous : stored_field; current : stored_field }
  | Renamed of { previous : stored_field; current : stored_field }
  | Empty_optional of stored_field
  | Constant of stored_field * node
  | Computed of stored_field
type entity = {
  identity : string; previous : stored_entity; current : stored_entity;
  mode : mode; values : value_source list; indexes_changed : bool;
}
type t = { coverage : S.t; entities : entity list }
let entities t = t.entities
let coverage t = t.coverage

(* Rename changes the field's spelling and the subjects in its own annotation.
   The referenced type, codec and fact-producer closures remain byte-for-byte
   equal. Never rewrite arbitrary names inside those dependency definitions. *)
let renamed_contract renames field =
  let rename name = Option.value (List.assoc_opt name renames) ~default:name in
  let rec subjects = function
    | Seq [Bytes "field-subject"; Bytes name] -> Seq [Bytes "field-subject"; Bytes (rename name)]
    | Seq children -> Seq (List.map subjects children)
    | Bytes _ as value -> value in
  match field.contract with
  | Seq [semantics; identity; Seq [Bytes "stored-field";
      Seq [Bytes "field"; Bytes name; ty; proof; storage]; dependencies]] ->
    Some (Seq [semantics; identity; Seq [Bytes "stored-field";
      Seq [Bytes "field"; Bytes (rename name); ty; subjects proof; storage]; dependencies]])
  | _ -> None

let check coverage ~entries =
  let before, after = S.inventories coverage in
  let errors = ref [] in
  let report code loc message related = errors := {S.code;loc;message;related} :: !errors in
  let supplied = Hashtbl.create 8 in
  List.iter (fun (entry : entry) ->
    if List.assoc_opt entry.entity (S.entries coverage) <> Some S.Transform then
      report "MIG022" entry.loc ("transform rules must belong to a covered transforming entry: " ^ entry.entity) []
    else if Hashtbl.mem supplied entry.entity then
      report "MIG023" entry.loc ("duplicate transforming entry: " ^ entry.entity) []
    else Hashtbl.add supplied entry.entity entry) entries;
  let shapes inventory entity = field_shapes inventory
    |> List.filter (fun shape -> shape.stored_field.entity = entity.entity_name)
    |> List.map (fun shape -> shape.stored_field.name, shape)
    |> List.sort (fun (a,_) (b,_) -> String.compare a b) in
  let relative inventory name =
    let prefix = root_module inventory ^ "." in
    String.sub name (String.length prefix) (String.length name - String.length prefix) in
  let key (declaration : declaration) = declaration.namespace, declaration.qualified_name in
  let verified = S.identities coverage |> List.map (fun evidence ->
    let previous, current = same_declarations evidence in key previous, key current) in
  let dependencies inventory (field:stored_field) =
    stored_dependencies inventory ~entity:field.entity ~field:field.name
    |> Option.map (List.filter (fun d -> match d.declaration_kind with Function | Entity -> false | _ -> true)) in
  let same_dependencies previous current =
    match dependencies before previous, dependencies after current with
    | Some old, Some fresh -> List.length old = List.length fresh && List.for_all (fun old ->
        List.exists (fun current -> List.mem (key old, key current) verified) fresh) old
    | _ -> false in
  let mapped = S.entities coverage |> List.filter_map (function
    | S.Paired pair when List.assoc_opt (relative after pair.current.entity_name) (S.entries coverage) = Some S.Transform ->
      let identity = relative after pair.current.entity_name in
      let related = [pair.previous.entity_loc,"previous entity";pair.current.entity_loc,"current entity"] in
      (match Hashtbl.find_opt supplied identity with
       | None -> report "MIG021" pair.current.entity_loc (identity ^ ": missing transforming rule entry") related; None
       | Some entry ->
         let refuse code loc message = report code loc (identity ^ ": " ^ message) related in
         if pair.previous.table_name <> pair.current.table_name || pair.previous.primary_key <> pair.current.primary_key then
           refuse "MIG009" entry.loc "online transformations cannot change the table or primary key identity";
         let previous = shapes before pair.previous and current = shapes after pair.current in
         (match List.assoc_opt pair.previous.primary_key previous, List.assoc_opt pair.current.primary_key current with
          | Some old, Some fresh when old.stored_field.contract = fresh.stored_field.contract -> ()
          | _ -> refuse "MIG009" entry.loc "online transformations cannot change the primary key's stored contract");
         let renamed = Hashtbl.create 8 and destinations = Hashtbl.create 8 and defaults = Hashtbl.create 8 in
         List.iter (function
           | Rename rule ->
             if Hashtbl.mem renamed rule.previous || Hashtbl.mem destinations rule.current || Hashtbl.mem defaults rule.current then
               refuse "MIG023" rule.loc "duplicate or conflicting Rename endpoints"
             else if rule.previous = pair.previous.primary_key || rule.current = pair.current.primary_key then
               refuse "MIG009" rule.loc "online Rename cannot change the primary key"
             else if not (List.mem_assoc rule.previous previous) || List.mem_assoc rule.previous current ||
                     not (List.mem_assoc rule.current current) || List.mem_assoc rule.current previous then
               refuse "MIG022" rule.loc "Rename requires an old-only source field and a new-only target field"
             else begin
               Hashtbl.add renamed rule.previous rule.current;
               Hashtbl.add destinations rule.current rule.previous
             end
           | Default rule ->
             if rule.entity <> identity || not (List.mem_assoc rule.field current) || List.mem_assoc rule.field previous then
               refuse "MIG022" rule.loc "Default requires a newly added field in this entity"
             else if Hashtbl.mem defaults rule.field || Hashtbl.mem destinations rule.field then
               refuse "MIG023" rule.loc "duplicate or conflicting Default target"
             else Hashtbl.add defaults rule.field rule) entry.rules;
         let renames = Hashtbl.to_seq renamed |> List.of_seq in
         List.iter (fun (name, shape) ->
           if not (List.mem_assoc name current) && not (Hashtbl.mem renamed name) then
             refuse "MIG022" shape.stored_field.loc ("removed field `" ^ name ^ "` needs a legacy-write rule; Rename alone cannot discard retained data")) previous;
         let values = List.filter_map (fun (name, shape) ->
           let field = shape.stored_field in
           let source = match Hashtbl.find_opt destinations name with
             | Some old -> Some (true, List.assoc old previous)
             | None -> Option.map (fun old -> false, old) (List.assoc_opt name previous) in
           match source with
           | Some (rename, old) ->
             if renamed_contract renames old.stored_field <> Some field.contract then begin
               refuse "MIG022" field.loc ("`" ^ name ^ "` changes its type, proof, codec or storage contract; an identity rule cannot transform that value"); None
             end else if not (same_dependencies old.stored_field field) then begin
               refuse "MIG024" field.loc ("`" ^ name ^ "` needs explicit verified Same entries for all copied stored dependencies"); None
             end else if rename then Some (Renamed {previous=old.stored_field;current=field})
             else Some (Copy {previous=old.stored_field;current=field})
           | None ->
             match Hashtbl.find_opt defaults name with
             | Some default ->
               (match A.literal default.value with
                | Ok (ty,value) when shape.proof_identity = None && shape.type_identity = A.primitive ty ->
                  Some (Constant (field,value))
                | _ -> refuse "MIG022" default.loc ("`" ^ name ^ "` requires a primitive literal of its exact unproven type"); None)
             | None when entry.mode = Migrate -> Some (Computed field)
             | None when A.nullable shape && shape.proof_identity = None -> Some (Empty_optional field)
             | None -> refuse "MIG016" field.loc ("Derived cannot compute `" ^ name ^ "`; provide Migrate with a checked row function"); None) current in
         if entry.mode = Derived && Hashtbl.length renamed = 0 then
           refuse "MIG016" entry.loc "this Derived entry has no identity transformation; use Additive for nullable additions and literal defaults";
         let indexes_changed = entity_indexes before ~entity:pair.previous.entity_name <>
           entity_indexes after ~entity:pair.current.entity_name in
         Some {identity;previous=pair.previous;current=pair.current;mode=entry.mode;values;indexes_changed})
    | _ -> None) in
  if !errors = [] then Ok {coverage;entities=mapped} else Error (List.rev !errors)
