(* What history traversals read from a frozen module's parse: its declared
   name and its imports, in source order.

   Both are a function of the module's bytes alone. Discovery, trust seals,
   closure verification and source-integrity capture all walk the import
   closures of every frozen revision; parsing each module for those two facts
   made every command parse the complete history.

   A revision's checkpoint records the facts of the modules its seals cover
   (the previous and target schema closures, the migration root, its private
   helpers and its Contract), keyed by the SHA-256 of the bytes they were
   parsed from (for a migration root, its bytes without the frozen-source
   block, as its closure seal hashes them). A checkpoint's facts are used only
   after its own digest verified against the frozen-source block of its
   revision, and only when they were recorded by the running compiler ABI:
   then a parse of the same bytes gives the same facts. Under --full-history
   no recorded fact is used; every module is parsed, and every recorded
   checkpoint is recomputed and compared byte for byte
   (Migration_checkpoint.verify_all). *)
module C = Migration_canonical

type t = { module_name : string; imports : string list }

let of_module (m : Ast.module_form) =
  { module_name = m.module_name; imports = List.map (fun (i : Ast.import_decl) -> i.module_name) m.imports }

let format = "tesl-module-facts-v1"

(* Installed by Migration_trust (which sits above this module): the running
   compiler ABI, and whether trust is disabled (full history). *)
let current_abi : (unit -> string option) ref = ref (fun () -> None)
let disabled : (unit -> bool) ref = ref (fun () -> true)

let recorded : (string, t) Hashtbl.t = Hashtbl.create 256

(* Facts recorded for bytes with SHA-256 [digest], if any may be used. *)
let find digest = if !disabled () then None else Hashtbl.find_opt recorded digest

let encode ~compiler_abi entries =
  C.Seq [C.Bytes format; C.Bytes compiler_abi;
    C.Seq (List.map (fun (digest, t) ->
      C.Seq [C.Bytes digest; C.Bytes t.module_name; C.Seq (List.map (fun i -> C.Bytes i) t.imports)])
      (List.sort_uniq compare entries))]

let decode node =
  let fail () = invalid_arg "malformed module facts" in
  let str = function C.Bytes s -> s | C.Seq _ -> fail () in
  match node with
  | C.Seq [C.Bytes tag; abi; C.Seq entries] when tag = format ->
    str abi, List.map (function
      | C.Seq [digest; name; C.Seq imports] -> str digest, { module_name = str name; imports = List.map str imports }
      | _ -> fail ()) entries
  | _ -> fail ()

(* Use the facts of a verified checkpoint section. Facts recorded by another
   compiler ABI are ignored. *)
let load node =
  if not (!disabled ()) then
    match decode node with
    | exception Invalid_argument _ -> ()
    | abi, entries ->
      if Some abi = !current_abi () then begin
        if Hashtbl.length recorded > 65536 then Hashtbl.reset recorded;
        List.iter (fun (digest, t) -> Hashtbl.replace recorded digest t) entries end

(* Facts a verified history summary records (Migration_history_summary). *)
let add ~compiler_abi entries =
  if not (!disabled ()) && Some compiler_abi = !current_abi () then begin
    if Hashtbl.length recorded > 65536 then Hashtbl.reset recorded;
    List.iter (fun (digest, t) -> Hashtbl.replace recorded digest t) entries end

(* A revision checkpoint (Migration_checkpoint) starts with its format line and
   then this section. [text] must already have verified against its recorded
   digest. *)
let checkpoint_format = "tesl-migration-checkpoint-v6"
let load_checkpoint text =
  let header = checkpoint_format ^ "\n" in
  if not (!disabled ()) && String.starts_with ~prefix:header text then
    match C.parse_at text ~from:(String.length header) with
    | node, _ -> load node
    | exception Invalid_argument _ -> ()
