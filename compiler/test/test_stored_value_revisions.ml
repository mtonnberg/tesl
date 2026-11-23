(* Every implementation file of a builtin family that can change stored values,
   codecs or proof results is listed in Stored_value_revisions with the digest
   it had when its revision was last reviewed. A change to such a file fails
   here until a developer has decided whether the family's revision must be
   bumped (which changes the stored-value identity of every project). *)
open Alcotest
module R = Stored_value_revisions

let repo () = match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some root when root <> "" -> root
  | _ -> fail "TESL_REPO_ROOT must name the repository root"

let reviewed () =
  let root = repo () in
  let stale = List.concat_map (fun (family : R.family) ->
    List.filter_map (fun (path,recorded) ->
      let file = Filename.concat root path in
      let actual = match In_channel.with_open_bin file In_channel.input_all with
        | source -> R.file_digest source
        | exception Sys_error _ -> "missing" in
      if actual = recorded then None else Some (family,path,actual)) family.files) R.families in
  if stale <> [] then
    fail (String.concat "\n" (List.map (fun ((family : R.family),path,actual) -> Printf.sprintf
      "%s changed. It implements the builtin family %S (revision %d), which can affect stored values, \
       codecs or proof results. If this change can make an existing stored value decode, compare, \
       write or prove differently, bump that family's revision in compiler/lib/stored_value_revisions.ml \
       (every sealed project then needs `tesl migrate revalidate`). Otherwise confirm that it has no \
       stored-value effect. In both cases record the reviewed digest:\n    %S,%S;"
      path family.name family.revision path actual) stale))

let well_formed () =
  let names = List.map (fun (f : R.family) -> f.name) R.families in
  check int "family names are unique" (List.length names) (List.length (List.sort_uniq compare names));
  List.iter (fun (f : R.family) ->
    check bool (f.name ^ " has a positive revision") true (f.revision >= 1);
    check bool (f.name ^ " lists its implementation") true (f.files <> [])) R.families;
  let paths = List.concat_map (fun (f : R.family) -> List.map fst f.files) R.families in
  check int "a file belongs to one family" (List.length paths) (List.length (List.sort_uniq compare paths))

(* The revision numbers are part of the identity; a bump must change it. *)
let revisions_enter_identity () =
  let stdlib_semantics = ["probe.tesl","0"] in
  let base = R.revisions () in
  let bumped = List.map (fun (name,revision) ->
    if name = "json-codecs" then name,revision + 1 else name,revision) base in
  check bool "a revision bump changes the fingerprint" false
    (Migration_abi.derive_fingerprint ~stdlib_semantics ~revisions:base =
     Migration_abi.derive_fingerprint ~stdlib_semantics ~revisions:bumped)

let () = run "Stored-value builtin revisions" ["review table",[
  test_case "implementation files match their reviewed digests" `Quick reviewed;
  test_case "table is well formed" `Quick well_formed;
  test_case "revisions enter the identity" `Quick revisions_enter_identity]]
