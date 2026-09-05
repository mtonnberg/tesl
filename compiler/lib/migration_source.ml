(** Source-preserving version renaming for frozen schema copies and completed
    migrations. Edits are token-based: comments, literal text, line endings and
    indentation stay byte-identical. This module does not hash semantic IR or
    write files; its caller builds and verifies the complete edit manifest. *)

let valid_revision name =
  name = "VCurrent" ||
  (String.length name > 1 && name.[0] = 'V' && name.[1] <> '0' &&
   let digits = String.sub name 1 (String.length name - 1) in
   String.for_all (fun c -> c >= '0' && c <= '9') digits &&
   match Int64.of_string_opt digits with
   | Some n -> n >= 1L && n <= 2147483646L
   | None -> false)

let valid_family family =
  not (String.contains family '.') &&
  Validation_common.schema_module_relative_path (family ^ ".VCurrent") <> None

(* Sorted, non-overlapping edits in raw source-byte coordinates. Sharing these
   ranges keeps editor fixes and frozen copies on exactly the same token walk. *)
let version_edits ~family ~before ~after source =
  if not (valid_family family) then
    Error "invalid schema family"
  else if not (valid_revision before && valid_revision after) then
    Error "schema revision must be VCurrent or V1..V2147483646 without leading zeros"
  else try
    let rec replacements source =
      let lines = Array.of_list (String.split_on_char '\n' source) in
      let offsets = Array.make (Array.length lines) 0 in
      for i = 1 to Array.length lines - 1 do
        offsets.(i) <- offsets.(i - 1) + String.length lines.(i - 1) + 1
      done;
      let position (token : Lexer.full_token) =
        (* Lexer columns expand leading tabs to eight spaces; all other columns
           are byte offsets. Convert only that indentation back to source bytes. *)
        let line = lines.(token.line) in
        let bytes = ref 0 and columns = ref 0 in
        while !bytes < String.length line && (line.[!bytes] = ' ' || line.[!bytes] = '\t') do
          columns := !columns + (if line.[!bytes] = '\t' then 8 else 1);
          incr bytes
        done;
        offsets.(token.line) + !bytes + token.col - !columns
      in
      let tokens = Array.of_list (Lexer.tokenize "<schema-rewrite>" source) in
      let edits = ref [] in
      Array.iteri (fun i (token : Lexer.full_token) ->
        (match token.tok with
         | Token.UIDENT name when name = family && i + 2 < Array.length tokens &&
             (i = 0 || tokens.(i - 1).tok <> Token.DOT) ->
           (match tokens.(i + 1).tok, tokens.(i + 2).tok with
            | Token.DOT, Token.UIDENT revision when revision = before ->
              let offset = position tokens.(i + 2) in
              if String.sub source offset (String.length before) <> before then
                failwith "version token does not match its source range";
              edits := (offset, String.length before) :: !edits
            | _ -> ())
         | Token.INTERP decoded ->
           (* The lexer has decoded escapes. Retain an exact decoded-byte to
              source-byte map, then recurse only into ${...} expressions using
              the same closing-brace rule as Parser.parse_interp_string. *)
           let start = position token in
           let map = Array.make (String.length decoded + 1) 0 in
           let src = ref (start + 1) in
           for j = 0 to String.length decoded - 1 do
             map.(j) <- !src;
             src := !src + (if source.[!src] = '\\' then 2 else 1)
           done;
           map.(String.length decoded) <- !src;
           let j = ref 0 in
           while !j + 1 < String.length decoded do
             if decoded.[!j] = '$' && decoded.[!j + 1] = '{' then begin
               let first = !j + 2 in
               let last = match String.index_from_opt decoded first '}' with
                 | Some k -> k | None -> failwith "unterminated interpolation in schema source" in
               let inner = String.sub decoded first (last - first) in
               List.iter (fun (offset, length) ->
                 let first = first + offset in
                 let source_offset = map.(first) in
                 let source_length = map.(first + length) - source_offset in
                 if source_length <> String.length before ||
                    String.sub source source_offset source_length <> before then
                   failwith "interpolated version token is not a literal identifier";
                 edits := (source_offset, source_length) :: !edits) (replacements inner);
               j := last + 1
             end else incr j
           done
         | _ -> ())) tokens;
      !edits
    in
    let edits = replacements source |> List.sort_uniq compare in
    let offset = ref 0 in
    List.iter (fun (start, length) ->
      if start < !offset then failwith "overlapping version references";
      offset := start + length) edits;
    Ok (if before = after then [] else List.map (fun (start, length) -> start, length, after) edits)
  with Failure message | Invalid_argument message -> Error message

let rewrite_version ~family ~before ~after source =
  match version_edits ~family ~before ~after source with
  | Error _ as error -> error
  | Ok edits ->
    let output = Buffer.create (String.length source) in
    let offset = ref 0 in
    List.iter (fun (start, length, replacement) ->
      Buffer.add_substring output source !offset (start - !offset);
      Buffer.add_string output replacement;
      offset := start + length) edits;
    Buffer.add_substring output source !offset (String.length source - !offset);
    Ok (Buffer.contents output)

let version_fix ~family ~before ~after source =
  match version_edits ~family ~before ~after source with
  | Error _ | Ok [] -> None
  | Ok edits ->
    let cursor = ref 0 and line = ref 0 and line_start = ref 0 in
    let edits = List.map (fun (start, length, replacement) ->
      while !cursor < start do
        if source.[!cursor] = '\n' then (incr line; line_start := !cursor + 1);
        incr cursor
      done;
      Diag_fix.Replace_range { start_line = !line; start_col = start - !line_start;
        end_line = !line; end_col = start - !line_start + length; replacement }) edits in
    Some (match edits with [edit] -> edit | _ -> Diag_fix.Multi edits)

type frozen_copy = {
  source_path : string;
  target_path : string;
  source_digest : string; (** Raw bytes for the manifest's edit precondition, not semantic identity. *)
  contents : string;
}

let freeze_closure ~project_root ~family ~version =
  let after = "V" ^ string_of_int version in
  let prefix = family ^ ".VCurrent" in
  if not (valid_revision after) then Error "schema version is out of range"
  else if not (valid_family family) then Error "invalid schema family"
  else match Validation_common.schema_module_relative_path prefix with
  | None -> Error "invalid schema family"
  | Some _ ->
    try
      let project_root = Source_input.realpath project_root in
      let copies = ref [] in
      let visited = Hashtbl.create 16 in
      let rec visit name =
        if not (Hashtbl.mem visited name) then begin
          Hashtbl.add visited name ();
          let relative = match Validation_common.schema_module_relative_path name with
            | Some path -> path | None -> failwith ("invalid schema module " ^ name) in
          let path = Filename.concat project_root relative in
          (* Family-owned inputs and outputs stay within their canonical layout;
             following a symlink must not turn a freeze into a copy of app code. *)
          if Source_input.kind path <> Unix.S_REG then failwith ("schema source is not a regular file: " ^ path);
          if Source_input.realpath path <> path then failwith ("schema source is not at its canonical path: " ^ path);
          let source = Source_input.read path in
          let m = match Parser.parse_module path source with
            | Ok m -> m | Err e -> failwith (path ^ ": " ^ e.msg) in
          if m.module_name <> name then failwith
            (Printf.sprintf "%s declares %s instead of %s" path m.module_name name);
          (match Migration_schema.check_contents m with
           | [] -> () | error :: _ -> failwith (path ^ ": " ^ error.message));
          List.iter (fun (imp : Ast.import_decl) ->
            if String.starts_with ~prefix:"Tesl." imp.module_name then ()
            else if Migration_schema.within prefix imp.module_name then visit imp.module_name
            else failwith (Printf.sprintf "%s imports %s outside its frozen schema closure" path imp.module_name)) m.imports;
          let contents = match rewrite_version ~family ~before:"VCurrent" ~after source with
            | Ok text -> text | Error message -> failwith (path ^ ": " ^ message) in
          let suffix = String.sub name (String.length prefix) (String.length name - String.length prefix) in
          let target_name = family ^ "." ^ after ^ suffix in
          let relative = match Validation_common.schema_module_relative_path target_name with
            | Some path -> path | None -> assert false in
          let target_path = Filename.concat project_root relative in
          let rec check_parent dir =
            match Source_input.kind dir with
            | kind ->
              if kind <> Unix.S_DIR || Source_input.realpath dir <> dir then
                failwith ("frozen target has a noncanonical parent: " ^ dir)
            | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
              check_parent (Filename.dirname dir)
          in
          check_parent (Filename.dirname target_path);
          let exists = match Source_input.kind target_path with
            | kind when kind <> Unix.S_REG ->
              failwith ("frozen target is not a regular file: " ^ target_path)
            | _ -> true
            | exception Unix.Unix_error (Unix.ENOENT, _, _) -> false in
          if exists then begin
            if Source_input.read target_path <> contents then
              failwith ("refusing to overwrite existing frozen history: " ^ target_path)
          end else copies := { source_path = path; target_path;
            source_digest = Migration_hash.digest source; contents } :: !copies
        end
      in
      visit prefix;
      Ok (List.sort (fun a b -> String.compare a.target_path b.target_path) !copies)
    with
    | Failure message | Sys_error message | Invalid_argument message -> Error message
    | Unix.Unix_error (error, operation, path) ->
      Error (Printf.sprintf "%s: %s: %s" operation path (Unix.error_message error))
