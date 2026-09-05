(** Version 1 local session transport. Each request is five length-prefixed byte
    strings: snapshot, flag, absolute staged file, line, column. Responses are
    length-prefixed JSON. Framing deliberately uses only the OCaml standard
    library; neither source bytes nor filenames undergo shell/string parsing.
    The owner must keep the complete staged tree immutable during a request. *)
let max_response = 8 * 1024 * 1024

let read_frame input limit =
  (* A clean EOF is only possible before the first length byte. Truncation
     inside a frame is a protocol error, never a successful empty request. *)
  let first = input_byte input in
  let size = try
    let b = input_byte input in
    let c = input_byte input in
    let d = input_byte input in
    (first lsl 24) lor (b lsl 16) lor (c lsl 8) lor d
    with End_of_file -> failwith "truncated session frame header" in
  if size < 0 || size > limit then failwith "session frame exceeds limit";
  try really_input_string input size
  with End_of_file -> failwith "truncated session frame body"

let write_frame output text =
  if String.length text > max_response then failwith "session response exceeds limit";
  output_binary_int output (String.length text);
  output_string output text;
  flush output

let cached_query = Query_cache.memo ~limit:32 ~max_weight:max_response
  ~value_weight:(fun result -> String.length result.Compiler_query.json)
  ~weight:(fun (_, path, _) -> (try (Unix.stat path).Unix.st_size with _ -> 0))
  (fun (flag, filename, position) -> Compiler_query.run ~filename ~logical_path:filename flag position)

(* Bundled sources are semantic inputs outside the private project mirror.
   The compiler owns their resolution. Compare their exact bytes, including
   missing/created candidates, so a development stdlib edit cannot hit a stale
   query cache even when the project snapshot itself is unchanged. *)
let stdlib_inputs () =
  let directories = Validation_common.stdlib_source_directories () in
  let total = ref 0 in
  List.concat_map (fun directory ->
    if not (Sys.file_exists directory) then [directory, None]
    else Sys.readdir directory |> Array.to_list |> List.sort String.compare
      |> List.filter (fun name -> Filename.check_suffix name ".tesl")
      |> List.map (fun name ->
        let path = Filename.concat directory name in
        let size = (Unix.stat path).Unix.st_size in
        total := !total + size;
        if size > 1024 * 1024 || !total > 8 * 1024 * 1024 then failwith "stdlib input limit exceeded";
        path, Some (In_channel.with_open_bin path In_channel.input_all))) directories

let run input output =
  set_binary_mode_in input true;
  set_binary_mode_out output true;
  Query_cache.set_enabled true;
  Fun.protect ~finally:(fun () -> Query_cache.set_enabled false; Checker.clear_import_parse_cache ()) (fun () ->
    write_frame output "{\"version\":1,\"protocol\":\"tesl-workspace\",\"invalidation\":\"whole-snapshot\"}";
    let current = ref None in
    let rec loop () =
      match (try Some (read_frame input 128) with End_of_file -> None) with
      | None -> ()
      | Some snapshot ->
        let flag, filename, line, col = try
          let flag = read_frame input 64 in
          let filename = read_frame input 4096 in
          let line = read_frame input 20 in
          let col = read_frame input 20 in
          flag, filename, line, col
          with End_of_file -> failwith "truncated session request" in
        let response = try
          if snapshot = "" || Filename.is_relative filename || String.contains filename '\000'
          then invalid_arg "invalid workspace snapshot or path";
          let inputs = stdlib_inputs () in
          if !current <> Some (snapshot, inputs) then begin
            Query_cache.clear ();
            (* This is conservative by design: filesystem/catalogue changes
               invalidate all semantic answers. Imported ASTs are content-aware. *)
            Hashtbl.clear Validation_common.literal_occ_content;
            current := Some (snapshot, inputs)
          end;
          let position = if line = "" && col = "" then [] else [line; col] in
          let result = cached_query (flag, filename, position) in
          Printf.sprintf "{\"version\":1,\"snapshot\":%s,\"exit_code\":%d,\"result\":%s,\"error\":null,\"cache_hits\":%d,\"cache_misses\":%d}"
            (Compile.json_encode_string snapshot) result.exit_code result.json !Query_cache.hits !Query_cache.misses
        with exn ->
          Query_cache.clear ();
          Printf.sprintf "{\"version\":1,\"snapshot\":%s,\"exit_code\":1,\"result\":null,\"error\":%s}"
            (Compile.json_encode_string snapshot) (Compile.json_encode_string (Printexc.to_string exn)) in
        let response = if String.length response <= max_response then response else
          Printf.sprintf "{\"version\":1,\"snapshot\":%s,\"exit_code\":1,\"result\":null,\"error\":\"session response exceeds limit\"}"
            (Compile.json_encode_string snapshot) in
        write_frame output response;
        loop () in
    loop ())
