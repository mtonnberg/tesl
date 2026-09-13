open Migration_inventory
open Migration_canonical
module S = Migration_sparse

type literal = Integer of string | Floating of float | Boolean of bool | Text of string
type default = { entity : string; field : string; value : literal; loc : Location.loc }
type value_source =
  | Existing of { previous : stored_field; current : stored_field }
  | Empty_optional of stored_field
  | Constant of stored_field * node

type entity = {
  identity : string;
  previous : stored_entity;
  current : stored_entity;
  values : value_source list;
  indexes_changed : bool;
}
type t = entity list
let entities t = t
let primitive name = Seq [Bytes "named"; Seq [Bytes "reference"; Bytes "type";
  Seq [Bytes "primitive"; Bytes name]]]
let nullable shape = match shape.type_identity with
  | Seq [Bytes "apply"; head; _] -> head = primitive "Tesl.Maybe.Maybe"
  | _ -> false
let literal = function
  | Integer value -> Result.map (fun node -> "Tesl.Prelude.Int", node) (Migration_canonical.integer value)
  | Floating value -> Result.map (fun node -> "Tesl.Float.Float", node) (Migration_canonical.float value)
  | Boolean value -> Ok ("Tesl.Prelude.Bool", Migration_canonical.bool value)
  | Text value -> Ok ("Tesl.Prelude.String", Migration_canonical.string value)
let relative inventory name =
  let prefix = root_module inventory ^ "." in
  if not (String.starts_with ~prefix name) then assert false;
  String.sub name (String.length prefix) (String.length name - String.length prefix)

let check coverage ~defaults =
  let before, after = S.inventories coverage in
  let entries = S.entries coverage in
  let errors = ref [] in
  let report code loc message related = errors := ({S.code;loc;message;related} : S.error) :: !errors in
  let supplied = Hashtbl.create 16 in
  List.iter (fun (default : default) ->
    if List.assoc_opt default.entity entries <> Some S.Additive then
      report "MIG022" default.loc ("Default must belong to a covered Additive entry: " ^ default.entity) []
    else if Hashtbl.mem supplied (default.entity,default.field) then
      report "MIG023" default.loc ("duplicate Default for " ^ default.entity ^ "." ^ default.field) []
    else Hashtbl.add supplied (default.entity,default.field) default) defaults;
  if !errors <> [] then Error (List.rev !errors) else
  let old_shapes = field_shapes before and new_shapes = field_shapes after in
  let shapes all entity = List.filter (fun shape -> shape.stored_field.entity = entity.entity_name) all
    |> List.sort (fun a b -> String.compare a.stored_field.name b.stored_field.name) in
  let result = S.entities coverage |> List.filter_map (function
    | S.Paired pair when List.assoc_opt (relative after pair.current.entity_name) entries = Some S.Additive ->
      let identity = relative after pair.current.entity_name in
      let related = [pair.previous.entity_loc,"previous entity";pair.current.entity_loc,"current entity"] in
      let refuse message = report "MIG016" pair.current.entity_loc (identity ^ ": " ^ message) related in
      if pair.previous.table_name <> pair.current.table_name then refuse "Additive cannot change the physical table identity";
      if pair.previous.primary_key <> pair.current.primary_key then refuse "Additive cannot change the primary key";
      let previous = shapes old_shapes pair.previous and current = shapes new_shapes pair.current in
      let old_by_name = List.map (fun s -> s.stored_field.name,s) previous in
      let new_by_name = List.map (fun s -> s.stored_field.name,s) current in
      List.iter (fun old -> if not (List.mem_assoc old.stored_field.name new_by_name) then
        refuse ("Additive cannot remove existing field `" ^ old.stored_field.name ^ "`")) previous;
      List.iter (fun (default : default) ->
        if default.entity = identity && not (List.mem_assoc default.field new_by_name) then
          report "MIG022" default.loc ("Default names no current field: " ^ identity ^ "." ^ default.field) related) defaults;
      let values = List.filter_map (fun fresh ->
        let field = fresh.stored_field in
        let default = Hashtbl.find_opt supplied (identity,field.name) in
        let invalid_default (default : default) message =
          report "MIG022" default.loc (identity ^ "." ^ field.name ^ ": " ^ message)
            [field.loc,"current field"] in
        match List.assoc_opt field.name old_by_name with
        | Some old ->
          Option.iter (fun default -> invalid_default default "Default applies only to newly added fields") default;
          if old.stored_field.contract <> field.contract then begin
            report "MIG016" field.loc (identity ^ "." ^ field.name ^
              ": Additive requires the existing field's complete type, proof, codec and storage contract to remain equal")
              [old.stored_field.loc,"previous field";field.loc,"current field"];
            None
          end else Some (Existing {previous=old.stored_field;current=field})
        | None when nullable fresh && fresh.proof_identity = None ->
          Option.iter (fun default -> invalid_default default "a new Maybe field uses Nothing, not a Default rule") default;
          Some (Empty_optional field)
        | None ->
          match default with
          | None ->
            report "MIG016" field.loc (identity ^ "." ^ field.name ^
              ": no additive value source; this field requires a typed default or row transformation") [];
            None
          | Some default ->
            if fresh.proof_identity <> None then begin
              invalid_default default "a literal does not establish the field's proof"; None
            end else match literal default.value with
              | Error message -> invalid_default default message; None
              | Ok (ty,node) when fresh.type_identity = primitive ty -> Some (Constant (field,node))
              | Ok _ ->
                invalid_default default "default literal must have the field's exact primitive type; nominal constructors and other values require further contextual elaboration";
                None) current in
      let indexes inventory entity = match entity_indexes inventory ~entity:entity.entity_name with
        | Some node -> node | None -> assert false in
      Some {identity;previous=pair.previous;current=pair.current;values;
        indexes_changed=indexes before pair.previous <> indexes after pair.current}
    | _ -> None) in
  if !errors <> [] then Error (List.rev !errors) else Ok result
