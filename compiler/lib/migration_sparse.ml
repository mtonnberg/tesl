open Migration_inventory

type identity = {
  previous : Migration_ir.namespace * string;
  current : Migration_ir.namespace * string;
  loc : Location.loc;
}
type entry_kind = Additive | Transform | New | Drop | Reset
type entry = { entity : string; kind : entry_kind; loc : Location.loc }
type error = {
  code : string;
  loc : Location.loc;
  message : string;
  related : (Location.loc * string) list;
}
type missing_identity = {
  previous_field : stored_field;
  current_field : stored_field;
  previous_declaration : declaration;
  current_declaration : declaration;
}
type entity =
  | Added of stored_entity
  | Removed of stored_entity
  | Paired of {
      previous : stored_entity;
      current : stored_entity;
      contract_changed : bool;
      missing_identities : missing_identity list;
    }
type t = {
  entities : entity list;
  identities : same list;
  inventories : Migration_inventory.t * Migration_inventory.t;
  entries : (string * entry_kind) list;
}
let entities t = t.entities
let identities t = t.identities
let inventories t = t.inventories
let entries t = t.entries
let unchanged_count t = List.fold_left (fun count -> function
  | Paired {contract_changed=false; missing_identities=[]; _} -> count + 1
  | _ -> count) 0 t.entities

let eligible = function Newtype | Adt | Record | Fact | Codec_declaration -> true
  | Entity | Function -> false
let key (d : declaration) = d.namespace, d.qualified_name
let relative inventory name =
  let prefix = root_module inventory ^ "." in
  if not (String.starts_with ~prefix name) then
    invalid_arg "sparse coverage received a declaration outside its inventory";
  String.sub name (String.length prefix) (String.length name - String.length prefix)
let short name = List.hd (List.rev (String.split_on_char '.' name))
let related_declaration side (d : declaration) = d.source_loc,
  side ^ " " ^ Migration_ir.namespace d.namespace ^ " " ^ d.qualified_name
let related_entity side e = e.entity_loc, side ^ " entity " ^ e.entity_name

let check ~before ~after ~(identities : identity list) ~(entries : entry list) ~loc =
  (* Checks the family and ABI even for completely empty schemas. *)
  match entity_changes ~before ~after with
  | Error error -> Error [{code="MIG020";loc;message=error.message;related=[]}]
  | Ok _ ->
    let errors = ref [] in
    let report code loc message related = errors := {code;loc;message;related} :: !errors in
    let seen_old = Hashtbl.create 16 and seen_new = Hashtbl.create 16 in
    let verified = List.filter_map (fun (claim : identity) ->
      let duplicate = Hashtbl.mem seen_old claim.previous || Hashtbl.mem seen_new claim.current in
      Hashtbl.replace seen_old claim.previous (); Hashtbl.replace seen_new claim.current ();
      if duplicate then begin
        report "MIG024" claim.loc "duplicate Same declaration: each old and new declaration may occur only once" [];
        None
      end else match verify_same ~before ~after ~previous:claim.previous ~current:claim.current with
        | Ok evidence -> Some evidence
        | Error error ->
          let related = List.filter_map Fun.id [
            Option.map (related_declaration "previous") error.difference.previous;
            Option.map (related_declaration "current") error.difference.current] in
          report "MIG024" claim.loc error.message related; None) identities in
    (* An invalid list must not become evidence, nor cause misleading cascades
       saying that the user omitted the very pair just rejected. *)
    if !errors <> [] then Error (List.rev !errors) else
    let verified = List.sort (fun left right ->
      let old_left, _ = same_declarations left and old_right, _ = same_declarations right in
      compare (key old_left) (key old_right)) verified in
    let supplied = Hashtbl.create 16 in
    List.iter (fun evidence ->
      let old, fresh = same_declarations evidence in
      Hashtbl.add supplied (key old, key fresh) ()) verified;
    let fields inventory =
      let table = Hashtbl.create 16 in
      List.iter (fun (field : stored_field) ->
        let fields = Option.value (Hashtbl.find_opt table field.entity) ~default:[] in
        Hashtbl.replace table field.entity (field :: fields)) (stored_fields inventory);
      table in
    let old_fields = fields before and new_fields = fields after in
    let dependencies inventory (field : stored_field) =
      match stored_dependencies inventory ~entity:field.entity ~field:field.name with
      | None -> assert false (* Both field and inventory came from the same loader. *)
      | Some ds -> List.filter (fun d -> eligible d.declaration_kind) ds in
    let missing_for old fresh =
      let old_fields = Option.value (Hashtbl.find_opt old_fields old.entity_name) ~default:[] in
      let new_fields = Option.value (Hashtbl.find_opt new_fields fresh.entity_name) ~default:[] in
      let new_by_name = Hashtbl.create (List.length new_fields) in
      List.iter (fun (field : stored_field) -> Hashtbl.add new_by_name field.name field) new_fields;
      List.concat_map (fun (previous_field : stored_field) ->
        match Hashtbl.find_opt new_by_name previous_field.name with
        | None -> [] (* Removed fields already change the semantic contract. *)
        | Some current_field ->
          let current_dependencies = Hashtbl.create 16 in
          List.iter (fun d -> Hashtbl.add current_dependencies
            (d.namespace, relative after d.qualified_name) d) (dependencies after current_field);
          List.filter_map (fun previous_declaration ->
            let identity = previous_declaration.namespace, relative before previous_declaration.qualified_name in
            match Hashtbl.find_opt current_dependencies identity with
            | None -> None (* Added/removed dependencies already change the contract. *)
            | Some current_declaration when Hashtbl.mem supplied (key previous_declaration, key current_declaration) -> None
            | Some current_declaration -> Some {previous_field;current_field;previous_declaration;current_declaration})
            (dependencies before previous_field)) old_fields
      |> List.sort (fun a b -> compare (a.previous_field.name, key a.previous_declaration)
          (b.previous_field.name, key b.previous_declaration)) in
    let old_entities = List.map (fun e -> relative before e.entity_name, e) (stored_entities before) in
    let new_entities = List.map (fun e -> relative after e.entity_name, e) (stored_entities after) in
    let names = List.sort_uniq String.compare (List.map fst old_entities @ List.map fst new_entities) in
    let covered = List.map (fun name -> name,
      match List.assoc_opt name old_entities, List.assoc_opt name new_entities with
      | Some old, Some fresh -> Paired {previous=old;current=fresh;
          contract_changed=old.entity_contract <> fresh.entity_contract;
          missing_identities=missing_for old fresh}
      | Some old, None -> Removed old
      | None, Some fresh -> Added fresh
      | None, None -> assert false) names in
    let related = function
      | Added e -> [related_entity "current" e]
      | Removed e -> [related_entity "previous" e]
      | Paired e -> [related_entity "previous" e.previous; related_entity "current" e.current] in
    let names_for identity entity = identity :: short identity ::
      (match entity with
       | Added e | Removed e -> [e.entity_name]
       | Paired e -> [e.previous.entity_name; e.current.entity_name]) in
    let assigned = Hashtbl.create 16 in
    List.iter (fun (entry : entry) ->
      let matches = List.filter (fun (identity, entity) ->
        List.mem entry.entity (names_for identity entity)) covered in
      match matches with
      | [] -> report "MIG002" entry.loc ("migration entry names no owned entity: " ^ entry.entity) []
      | _ :: _ :: _ ->
        report "MIG002" entry.loc
          ("ambiguous entity `" ^ entry.entity ^ "`; use an owning module path: " ^ String.concat ", " (List.map fst matches))
          (List.concat_map (fun (_, entity) -> related entity) matches)
      | [(identity, entity)] ->
        if Hashtbl.mem assigned identity then
          report "MIG002" entry.loc ("duplicate migration entry for " ^ identity) (related entity)
        else Hashtbl.add assigned identity entry) entries;
    List.iter (fun (identity, entity) ->
      let entry = Hashtbl.find_opt assigned identity in
      let at = match entry with Some entry -> entry.loc | None -> loc in
      let missing_report (gap : missing_identity) =
        let dependency_locations = match verify_same ~before ~after
            ~previous:(key gap.previous_declaration) ~current:(key gap.current_declaration) with
          | Ok _ -> []
          | Error error -> List.filter_map Fun.id [
              Option.map (related_declaration "differing previous") error.difference.previous;
              Option.map (related_declaration "differing current") error.difference.current] in
        report "MIG016" at (identity ^ ": stored field `" ^ gap.current_field.name ^ "` has no Same for " ^
          gap.previous_declaration.qualified_name ^ " -> " ^ gap.current_declaration.qualified_name ^
          "; provide verified identity or an entry that revalidates the stored values")
          (related entity @ [gap.previous_field.loc, "previous stored field";
            gap.current_field.loc, "current stored field";
            related_declaration "previous" gap.previous_declaration;
            related_declaration "current" gap.current_declaration] @ dependency_locations) in
      let report code message = report code at (identity ^ ": " ^ message) (related entity) in
      match entity, entry with
      | Paired {contract_changed=false;missing_identities=[];_}, None -> ()
      | Paired {contract_changed=false;missing_identities=[];_}, Some _ ->
        report "MIG002" "unchanged entities must be absent from the sparse migration record"
      | Added _, Some {kind=New;_} | Removed _, Some {kind=Drop;_} -> ()
      | Added _, _ -> report "MIG002" "an added entity requires a New entry"
      | Removed _, _ -> report "MIG002" "a removed entity requires a Drop entry"
      | Paired _, Some {kind=(New | Drop);_} -> report "MIG002" "an existing entity requires a modification entry"
      | Paired {missing_identities=gap :: _;_}, (None | Some {kind=Additive;_}) ->
        missing_report gap
      | Paired _, None -> report "MIG002" "changed entity has no migration entry"
      | Paired _, Some {kind=(Additive | Transform | Reset);_} -> ()) covered;
    if !errors <> [] then Error (List.rev !errors)
    else Ok {entities=List.map snd covered; identities=verified;inventories=(before,after);
      entries=List.filter_map (fun name ->
        Option.map (fun (e : entry) -> name,e.kind) (Hashtbl.find_opt assigned name)) names}
