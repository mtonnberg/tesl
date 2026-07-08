(** E1 import ergonomics — the import suggestion engine.

    Given an unbound name in a module, answer "which `import … exposing […]`
    would bind it?" and build the machine-applicable edit (a
    {!Type_system.diagnostic_fix}) that the LSP applies as a quickfix.

    Sources searched, in priority order:
    1. stdlib value/function names — {!Type_system.stdlib_home_module_of}
       (THE authoritative name→home-module table);
    2. any other stdlib export (types, constructors, proof predicates) — the
       reverse of {!Type_system.tesl_module_exports};
    3. sibling `.tesl` modules in the importing file's directory (fully parsed,
       so exported ADT constructors are found too) — these imports resolve, so
       they get a fix;
    4. `.tesl` modules deeper in the folder tree — local imports resolve only
       from the importing file's own directory ({!resolve_local_import_path}),
       so a deep hit yields a guiding message but NO edit.

    All line numbers are 0-based (diagnostic wire convention). *)

open Ast

type suggestion = {
  sug_hint : string;
  (** sentence fragment to append to the error message (leading " — …") *)
  sug_fix  : Type_system.diagnostic_fix option;
  (** the one-keypress edit, when the suggested import actually resolves *)
}

(* ── Rendering an import statement ─────────────────────────────────────────── *)

(* Same layout contract as Formatter.reflow_exposing_lists: one line when it
   fits in 80 columns, else one name per line with trailing commas. *)
let render_import (module_name : string) (names : string list) : string =
  let one_line =
    Printf.sprintf "import %s exposing [%s]" module_name (String.concat ", " names)
  in
  if String.length one_line <= 80 then one_line
  else
    Printf.sprintf "import %s exposing [\n%s\n]" module_name
      (String.concat "\n" (List.map (fun n -> "  " ^ n ^ ",") names))

(* ── Edit construction ─────────────────────────────────────────────────────── *)

(** The 0-based line where a brand-new import statement should be inserted:
    right after the last existing import, else right before the first
    declaration (which also handles multi-line module headers). *)
let insertion_line (m : module_form) : int =
  match m.imports with
  | _ :: _ ->
    1 + List.fold_left (fun acc (imp : import_decl) ->
          max acc imp.loc.stop.line) 0 m.imports
  | [] ->
    (match m.decls with
     | d :: _ -> (top_decl_loc d).start.line
     | [] -> 2 (* after `#lang tesl` + `module …` in an otherwise empty file *))

(** Build the edit that makes [expose_name] available from [target_module]:
    extend that module's existing exposing list in place, or insert a fresh
    import statement.  [None] when the module is already imported wholesale
    ([ImportAll]) — nothing to edit. *)
let build_fix (m : module_form) ~(target_module : string) ~(expose_name : string)
  : Type_system.diagnostic_fix option =
  let existing =
    List.find_opt (fun (imp : import_decl) -> imp.module_name = target_module)
      m.imports
  in
  match existing with
  | Some { names = ImportAll; _ } -> None
  | Some ({ names = ImportExposing names; _ } as imp) ->
    Some (Type_system.Replace_span {
      start_line  = imp.loc.start.line;
      end_line    = imp.loc.stop.line;
      replacement = render_import target_module (names @ [expose_name]);
    })
  | None ->
    Some (Type_system.Insert_line {
      line = insertion_line m;
      text = render_import target_module [expose_name];
    })

(* ── Source 1+2: stdlib ────────────────────────────────────────────────────── *)

let strip_dotdot s =
  let n = String.length s in
  if n > 4 && String.sub s (n - 4) 4 = "(..)" then String.sub s 0 (n - 4) else s

(** Every stdlib module whose export list contains [name] (constructors and
    types included), plus the bare home-module row when there is one. *)
let stdlib_modules_exporting (name : string) : string list =
  let from_exports =
    List.filter_map (fun (m, names) ->
      if List.exists (fun n -> strip_dotdot n = name) names then Some m else None)
      Type_system.tesl_module_exports
  in
  let from_home = match Type_system.stdlib_home_module_of name with
    | Some m -> [m] | None -> []
  in
  List.sort_uniq compare (from_home @ from_exports)

(* ── Source 3+4: the folder tree ───────────────────────────────────────────── *)

(* Directories that can never contain project Tesl modules. *)
let skip_dir = function
  | "_build" | "compiled" | "node_modules" | ".git" | "target" | "dist" -> true
  | d -> String.length d > 0 && d.[0] = '.'

let max_scanned_files = 200

(** All `.tesl` files under [dir] except [self], nearest-first (the directory's
    own files before subdirectories'), capped at {!max_scanned_files}. *)
let tesl_files_under (dir : string) ~(self : string) : string list =
  let count = ref 0 in
  let rec go dir acc =
    if !count >= max_scanned_files then acc
    else
      match (try Some (Sys.readdir dir) with Sys_error _ -> None) with
      | None -> acc
      | Some entries ->
        Array.sort compare entries;
        let files, dirs =
          Array.to_list entries
          |> List.partition (fun e ->
               not (try Sys.is_directory (Filename.concat dir e)
                    with Sys_error _ -> true))
        in
        let here =
          List.filter_map (fun e ->
            let path = Filename.concat dir e in
            if Filename.check_suffix e ".tesl" && path <> self
               && !count < max_scanned_files
            then (incr count; Some path)
            else None
          ) files
        in
        List.fold_left (fun acc d ->
          if skip_dir d then acc else go (Filename.concat dir d) acc
        ) (acc @ here) dirs
  in
  go dir []

(* One exposed name of a local module, as the folder-tree index carries it. *)
type local_export = {
  le_module : string;         (* module name to import *)
  le_path   : string;         (* file that defines it *)
  le_expose : string;         (* what to put in the exposing list — the name
                                 itself, or `Type(..)` for an ADT constructor *)
  le_opaque_const : bool;     (* #34: a bare top-level constant whose value has
                                 no syntactically evident type — the importer's
                                 checker cannot bind it, so "add the import"
                                 would be a lie; hint the zero-arg-fn wrap. *)
}

(** Parse [path] and index every name an importer could expose: exported names,
    `Type(..)` forms, and the constructors of exported ADTs (mapped back to
    their `Type(..)` import form).  Parse failures index nothing. *)
let exports_of_file (path : string) : (string * local_export) list =
  let source =
    try
      let ic = open_in_bin path in
      let n = in_channel_length ic in
      let s = really_input_string ic n in
      close_in ic; s
    with Sys_error _ | End_of_file -> ""
  in
  if source = "" then []
  else
    match Parser.parse_module path source with
    | Err _ -> []
    | Ok m ->
      let entry expose name =
        let opaque_const =
          List.exists (function
            | DConst (c : const_form) ->
              c.name = name && Type_system.shallow_const_ty c.value = None
            | _ -> false
          ) m.decls
        in
        (name, { le_module = m.module_name; le_path = path; le_expose = expose;
                 le_opaque_const = opaque_const })
      in
      List.concat_map (function
        | ExportName n -> [entry n n]
        | ExportAdt n ->
          let ctors =
            List.concat_map (function
              | DType (TypeAdt { name; variants; _ }) when name = n ->
                List.map (fun (v : adt_variant) -> v.ctor) variants
              | _ -> []
            ) m.decls
          in
          entry n n :: List.map (fun c -> entry (n ^ "(..)") c) ctors
      ) m.exports

(** The folder-tree index for one checked module: unbound name →
    (export entry, does the import resolve from here?).  Built lazily — the
    scan only ever runs when an unbound-name error is actually being emitted. *)
type local_index = (string * (local_export * bool)) list Lazy.t

let build_local_index (m : module_form) : local_index =
  lazy begin
    (* Only scan next to a module that really lives on disk — synthetic
       filenames ("<test>", "") must not trigger a cwd-relative walk. *)
    if not (Sys.file_exists m.source_file) then []
    else begin
    let dir = Filename.dirname m.source_file in
    let prefix = dir ^ Filename.dir_sep in
    let files = tesl_files_under dir ~self:m.source_file in
    List.concat_map (fun path ->
      let same_dir = Filename.dirname path = dir in
      (* Report the path relative to the importing file's directory. *)
      let rel =
        let pl = String.length prefix in
        if String.length path > pl && String.sub path 0 pl = prefix
        then String.sub path pl (String.length path - pl)
        else path
      in
      List.map (fun (name, le) -> (name, ({ le with le_path = rel }, same_dir)))
        (exports_of_file path)
    ) files
    end
  end

(* ── Putting it together ───────────────────────────────────────────────────── *)

(* #34: is [expose_name] already listed in an import of [target_module]?  When
   it is, "add `import …`" would tell the user to duplicate a line they already
   have — the unbound name has some other cause (e.g. a declaration kind that
   does not bind across modules), so the hint must say that instead. *)
let already_imported (m : module_form) ~(target_module : string) ~(expose_name : string) =
  List.exists (fun (imp : import_decl) ->
    imp.module_name = target_module
    && (match imp.names with
        | ImportAll -> true
        | ImportExposing names -> List.mem expose_name names))
    m.imports

(* " — add `import M exposing [x]`", or, when M is already imported with an
   exposing list, " — add `x` to the existing `import M exposing [...]`". *)
let hint_for (m : module_form) ~(target_module : string) ~(expose_name : string) =
  let already_exposing =
    List.exists (fun (imp : import_decl) ->
      imp.module_name = target_module
      && (match imp.names with ImportExposing _ -> true | ImportAll -> false))
      m.imports
  in
  if already_imported m ~target_module ~expose_name then
    Printf.sprintf " — `%s` is already imported from `%s`, but the import does \
                    not make it usable here" expose_name target_module
  else if already_exposing then
    Printf.sprintf " — add `%s` to the existing `import %s exposing [...]`"
      expose_name target_module
  else
    Printf.sprintf " — add `import %s exposing [%s]`" target_module expose_name

(** The guiding hint (and quickfix) for an unbound [name] in [m], or [None]
    when nothing anywhere is known to export it.  [local_index] comes from
    {!build_local_index} — pass the same lazy value for every error in one
    module so the folder tree is scanned at most once. *)
let suggest (m : module_form) ~(local_index : local_index) (name : string)
  : suggestion option =
  match stdlib_modules_exporting name with
  | [target_module] ->
    Some { sug_hint = hint_for m ~target_module ~expose_name:name;
           sug_fix  = build_fix m ~target_module ~expose_name:name }
  | (_ :: _ :: _) as modules ->
    (* Ambiguous across stdlib modules: name them all, fix against the first. *)
    let target_module = List.hd modules in
    Some {
      sug_hint = Printf.sprintf " — exported by %s; e.g. `import %s exposing [%s]`"
          (String.concat ", " (List.map (Printf.sprintf "`%s`") modules))
          target_module name;
      sug_fix = build_fix m ~target_module ~expose_name:name;
    }
  | [] ->
    match List.assoc_opt name (Lazy.force local_index) with
    | Some (le, true) ->
      if le.le_opaque_const then
        (* #34: a bare constant only crosses the module boundary when its type
           is evident from a literal value — otherwise no import can help. *)
        Some {
          sug_hint = Printf.sprintf " — `%s` (%s) exports it, but a constant \
                                     with a non-literal value cannot be \
                                     imported; wrap it in a zero-arg function \
                                     in %s instead (`fn %s() -> T = ...`)"
              le.le_module (Filename.basename le.le_path)
              (Filename.basename le.le_path) le.le_expose;
          sug_fix = None;
        }
      else if already_imported m ~target_module:le.le_module ~expose_name:le.le_expose then
        (* #34: the import line the old hint suggested is already present —
           adding it again cannot fix anything, so say what is actually wrong. *)
        Some {
          sug_hint = Printf.sprintf " — `%s` is already imported from `%s` (%s), \
                                     but this declaration does not bind across \
                                     modules"
              le.le_expose le.le_module (Filename.basename le.le_path);
          sug_fix = None;
        }
      else
      Some {
        sug_hint = Printf.sprintf " — module `%s` (%s) exports it; add `import %s exposing [%s]`"
            le.le_module (Filename.basename le.le_path) le.le_module le.le_expose;
        sug_fix = build_fix m ~target_module:le.le_module ~expose_name:le.le_expose;
      }
    | Some (le, false) ->
      Some {
        sug_hint = Printf.sprintf " — module `%s` (%s) exports it, but local imports \
                                   only resolve from the importing file's own directory"
            le.le_module le.le_path;
        sug_fix = None;
      }
    | None -> None
