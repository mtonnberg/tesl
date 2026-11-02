(** Isolated discovery/capture benchmark; includes final source and disk guards. *)
let rec remove path = if (Unix.lstat path).Unix.st_kind=Unix.S_DIR then (Array.iter (fun name -> remove(Filename.concat path name))(Sys.readdir path);Unix.rmdir path) else Sys.remove path
let write path source = Out_channel.with_open_bin path(fun out -> output_string out source)
let () = List.iter(fun count ->
 let root=Filename.temp_file "tesl-integrity-scale-" "" in Sys.remove root;Unix.mkdir root 0o700;
 Fun.protect ~finally:(fun()->remove root) (fun()->
  let names=List.init count (fun i -> Printf.sprintf "Leaf%d" i) in
  List.iter(fun name -> write(Filename.concat root(String.lowercase_ascii name ^ ".tesl"))("module " ^ name ^ " exposing []\n")) names;
  let source="module Main exposing []\n" ^ String.concat "" (List.map(fun name -> "import " ^ name ^ "\n")names) in
  let file=Filename.concat root "main.tesl" in write file source;
  let start=Unix.gettimeofday() in
  match Migration_source_integrity.capture ~project_root:root ~inputs:[file,source] with
  | Error errors -> failwith(String.concat ";" (List.map(fun (e:Migration_sparse.error)->e.message)errors))
  | Ok token ->
   (match Migration_source_integrity.with_captured token(fun () -> Source_input.read file=source) with Ok true->()|_->failwith"capture differs");
   Printf.printf "{\"helpers\":%d,\"ms\":%.6f}\n%!" count ((Unix.gettimeofday()-.start)*.1000.))) [8;32;64;128]
