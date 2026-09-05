(** Syntactic recognition only. Contextual names are not runtime bindings; their
    arguments are checked by Migration_declaration against checked inventories. *)
open Ast

let type_names = ["Migration"; "Entity"; "Rule"; "Same"]
let constructor_groups = ["Entity", ["Additive"; "New"; "Drop"];
                          "Rule", ["Default"]; "Same", ["Same"]]
let names = List.sort_uniq String.compare
  (type_names @ List.concat_map snd constructor_groups)

let rec application = function
  | EApp {fn;arg;_} -> let head,args = application fn in head,args @ [arg]
  | EConstructor {name;args;_} -> name,args
  | ERecord {type_hint=Some name;fields;loc} ->
    name,[ERecord {type_hint=None;fields;loc}]
  | _ -> "",[]

let available (m : module_form) =
  List.exists (fun (i : import_decl) -> i.module_name = "Tesl.Migration") m.imports

let imported_name (m : module_form) name =
  List.exists (fun (i : import_decl) -> i.module_name = "Tesl.Migration" &&
    match i.names with
    | ImportAll -> true
    | ImportExposing exposed -> List.mem name exposed || List.exists (fun (owner,constructors) ->
        List.mem name constructors && List.mem (owner ^ "(..)") exposed) constructor_groups) m.imports

let is_declaration (m : module_form) (c : const_form) =
  imported_name m "Migration" && fst (application c.value) = "Migration"

let runtime_declarations (m : module_form) =
  List.filter (function DConst c -> not (is_declaration m c) | _ -> true) m.decls

(** Called after contextual checking, before SCC renaming and emission. An
    exported declaration can be named by later contextual records but is not an
    exported runtime value. Ordinary uses fail because no value scheme is bound. *)
let erase (m : module_form) =
  let erased = List.filter_map (function
    | DConst c when is_declaration m c -> Some c.name | _ -> None) m.decls in
  {m with decls=runtime_declarations m;exports=List.filter (function
    | ExportName name | ExportAdt name -> not (List.mem name erased)) m.exports}
