(** Formatting is a source edit. Canonical frozen schema paths and completed
    migration namespaces are therefore read-only, including private helpers.
    This guard prevents accidental rewrites; source seals remain the independent
    integrity check, and persisted history remains the execution authority. *)
let revision component =
 let stem = if Filename.check_suffix component ".tesl" then Filename.chop_suffix component ".tesl" else component in
 if String.length stem > 1 && stem.[0]='v' &&
    Migration_source.valid_revision ("V" ^ String.sub stem 1 (String.length stem-1)) then Some stem
 else None

let root_exists path =
 try ignore (Source_input.kind path);true with Unix.Unix_error (Unix.ENOENT,_,_) -> false

let completion_marker ~file source =
 (* Use the actual leading-comment protocol. A marker-shaped line inside a
    function/string is not history. Malformed leading metadata cannot make a
    completed source writable by formatting. *)
 match Migration_closure.read ~file source with Ok None -> false | Ok (Some _) | Error _ -> true

let reason ~file ~source =
 let absolute = if Filename.is_relative file then Filename.concat (Sys.getcwd ()) file else file in
 (* Keep the supplied spelling as well as the resolved one: a symlink replacing
    a frozen file cannot hide its ownership by pointing outside schema/. *)
 let resolved = try Source_input.canonical_path absolute with Unix.Unix_error _ | Sys_error _ -> absolute in
 let candidates = List.sort_uniq String.compare [absolute;resolved] in
 let inspect candidate =
  let rec walk child directory =
   let container = Filename.dirname directory in
   let kind = Filename.basename container in
   let continue () = if directory=container then None else walk directory container in
   if kind<>"schema" && kind<>"migrations" then continue () else
   match revision (Filename.basename child) with
   | None -> continue ()
   | Some version ->
     if kind="schema" then Some "frozen schema snapshot; edit VCurrent and generate a forward revision"
     else
      let family = Filename.basename directory in
      let project_root = Filename.dirname container in
      let schema = Filename.concat (Filename.concat (Filename.concat project_root "schema") family) (version ^ ".tesl") in
      let root = Filename.concat directory (version ^ ".tesl") in
      let completed = root_exists schema ||
       (child=candidate && completion_marker ~file:candidate source) ||
       (match Source_input.kind root with
        | Unix.S_REG -> completion_marker ~file:root (Source_input.read root)
        | _ -> true
        | exception Unix.Unix_error (Unix.ENOENT,_,_) -> false) in
      if completed then Some "completed migration source; keep its recorded bytes and generate a forward revision"
      else continue () in
  walk candidate (Filename.dirname candidate) in
 try List.find_map inspect candidates with
 | Unix.Unix_error _ | Sys_error _ | Invalid_argument _ ->
   Some "cannot verify migration source ownership; restore the canonical history before formatting"
