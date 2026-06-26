(** [tesl-sourcemap] — A1 headless CLI surface for the source-position map.

    This is a *separate* executable (it does not touch the main [tesl] CLI
    dispatch, owned elsewhere).  It exposes the two A1 deliverables:

      tesl-sourcemap emit-map  <file.tesl> [--rkt-out PATH] [--map-out PATH] [--quiet]
        Compile [file.tesl] with source-map recording on, write the sidecar
        [.tesl.map] JSON (default: alongside the .rkt as <out>.tesl.map), and
        print the map to stdout.  Optionally also write the emitted .rkt.

      tesl-sourcemap translate <file.tesl.map> [TRACE_FILE]
        Read a raw Racket stack trace (from TRACE_FILE, or stdin) and rewrite the
        frames that reference the emitted .rkt back to .tesl file:line.

      tesl-sourcemap render <file.tesl.map> [TRACE_FILE]   (A2)
        Tesl-level failure rendering: classify a runtime failure (check reject,
        capability violation, runtime type / proof error) from the trace and
        render it as a single line at the originating Tesl construct, e.g.
          todo.tesl:42:5 (handler createTodo): expected ValidTitle
            — title argument does not satisfy declared proof ValidTitle

    All build only on public library functions ([Parser], [Checker],
    [Emit_racket], [Source_map], [Compile]); release emission is unaffected
    because recording is opt-in and writes only the sidecar. *)

let prog = "tesl-sourcemap"

let usage () =
  Printf.eprintf
    "usage:\n\
    \  %s emit-map  <file.tesl> [--rkt-out PATH] [--map-out PATH] [--quiet]\n\
    \  %s translate <file.tesl.map> [TRACE_FILE]   (trace also accepted on stdin)\n\
    \  %s render    <file.tesl.map> [TRACE_FILE]   (A2: Tesl-level failure rendering)\n"
    prog prog prog

let read_file path = In_channel.with_open_text path In_channel.input_all

let read_all_stdin () = In_channel.input_all In_channel.stdin

let die msg = Printf.eprintf "%s: %s\n" prog msg; exit 1

(* Replace a trailing .tesl with .rkt (matches how the .rkt sits next to source). *)
let rkt_path_of_tesl tesl =
  if Filename.check_suffix tesl ".tesl" then
    (Filename.remove_extension tesl) ^ ".rkt"
  else tesl ^ ".rkt"

(* ── emit-map ─────────────────────────────────────────────────────────────── *)

let cmd_emit_map args =
  (* parse flags *)
  let file = ref None and rkt_out = ref None and map_out = ref None and quiet = ref false in
  let rec go = function
    | [] -> ()
    | "--rkt-out" :: v :: rest -> rkt_out := Some v; go rest
    | "--map-out" :: v :: rest -> map_out := Some v; go rest
    | "--quiet" :: rest -> quiet := true; go rest
    | f :: rest when !file = None && not (String.length f > 0 && f.[0] = '-') ->
      file := Some f; go rest
    | other :: _ -> die (Printf.sprintf "unexpected argument: %s" other)
  in
  go args;
  let file = match !file with Some f -> f | None -> usage (); exit 1 in
  if not (Sys.file_exists file) then die (Printf.sprintf "no such file: %s" file);

  let source = read_file file in
  let m =
    match Parser.parse_module file source with
    | Parser.Err e ->
      die (Printf.sprintf "%s:%d:%d parse error: %s"
             e.Parser.loc.Location.file
             (e.Parser.loc.Location.start.line + 1)
             (e.Parser.loc.Location.start.col + 1)
             e.Parser.msg)
    | Parser.Ok m -> m
  in
  (* type-check first: never emit for a module that would fail `tesl check`. *)
  (match Compile.check_module source m with
   | [] -> ()
   | diags ->
     List.iter
       (fun (d : Compile.diagnostic) ->
         Printf.eprintf "%s:%d:%d %s: %s\n" d.Compile.file d.start_line d.start_col
           d.severity d.message)
       diags;
     die "type errors — not emitting");

  let root_path = Compile.default_root_path () in
  let cyclic =
    if m.Ast.source_file = "" || m.Ast.source_file = "<test>" then []
    else Compile.cyclic_local_import_paths_for_entry m.Ast.source_file
  in
  let out_rkt = match !rkt_out with Some p -> p | None -> rkt_path_of_tesl file in

  (* Emit WITH recording on. *)
  Emit_racket.set_source_map_recording true;
  let racket = Emit_racket.compile_to_string ~root_path ~cyclic_local_import_paths:cyclic m in
  let smap = Emit_racket.take_source_map ~rkt_file:out_rkt () in
  Emit_racket.set_source_map_recording false;

  (* Write sidecar map next to the .rkt unless overridden. *)
  let map_path = match !map_out with Some p -> p | None -> out_rkt ^ ".tesl.map" in
  Out_channel.with_open_text map_path (fun oc -> Out_channel.output_string oc (Source_map.to_json smap));

  (* Optionally write the .rkt too (handy for a fully reproducible demo). *)
  (match !rkt_out with
   | Some p -> Out_channel.with_open_text p (fun oc -> Out_channel.output_string oc racket)
   | None -> ());

  if not !quiet then begin
    print_string (Source_map.to_json smap)
  end;
  Printf.eprintf "%s: wrote %s (%d entries)\n" prog map_path (List.length smap.Source_map.entries)

(* ── translate ────────────────────────────────────────────────────────────── *)

let cmd_translate args =
  let map_file, trace_file =
    match args with
    | [mf] -> mf, None
    | [mf; tf] -> mf, Some tf
    | _ -> usage (); exit 1
  in
  if not (Sys.file_exists map_file) then die (Printf.sprintf "no such map file: %s" map_file);
  let smap = Source_map.of_json (read_file map_file) in
  let trace =
    match trace_file with
    | Some tf -> read_file tf
    | None -> read_all_stdin ()
  in
  let translated = Source_map.translate_trace smap trace in
  print_string translated;
  if String.length translated > 0 && translated.[String.length translated - 1] <> '\n'
  then print_newline ();
  let resolved = Source_map.count_resolved smap trace in
  Printf.eprintf "%s: resolved %d frame(s) to .tesl\n" prog resolved

(* ── render (A2: Tesl-level failure rendering) ──────────────────────────────── *)

(* A2 turns a raw Racket backend trace into a single Tesl-level failure line
   rendered at the originating Tesl construct, e.g.

     todo.tesl:42:5 (handler createTodo): expected ValidTitle
       — title argument does not satisfy declared proof ValidTitle

   It classifies the failure into one of the three categories A2 targets (check
   reject, capability violation, runtime type/proof error), extracts the salient
   detail (the expected predicate/type, the missing capabilities, the reject
   message), and pairs it with the *deepest* trace frame the source map can
   resolve back to a [.tesl] span.  Everything is derived from the raw trace +
   the compile-time source-map artifact, so it stays runtime-agnostic: the only
   backend requirement is line numbers in traces. *)

(* Each category: a recogniser over a trace line → a (label, detail) the renderer
   leads with.  [label] is the short "expected …" headline; [detail] is the
   verbatim backend phrasing kept for reference. *)
type failure = { category : string; headline : string; detail : string }

let re_match re s = try ignore (Str.search_forward re s 0); true with Not_found -> false
let group n s = try Some (Str.matched_group n s) with Not_found | Invalid_argument _ -> None

(* check / proof / type rejections raised by check-runtime.rkt and the web
   boundary.  We match the stable message fragments those paths emit. *)
let classify_line (line : string) : failure option =
  (* runtime type error: "<subject> argument <name> does not satisfy declared type <T>" *)
  if re_match (Str.regexp "argument \\([A-Za-z0-9_']+\\) does not satisfy declared type \\(.+\\)$") line then
    (match group 1 line, group 2 line with
     | Some name, Some ty ->
       Some { category = "runtime type error";
              headline = Printf.sprintf "expected %s" (String.trim ty);
              detail = Printf.sprintf "%s argument does not satisfy declared type %s" name (String.trim ty) }
     | _ -> None)
  (* proof rejection: "... argument <name> does not satisfy declared proof <P>" *)
  else if re_match (Str.regexp "argument \\([A-Za-z0-9_']+\\) does not satisfy declared proof \\(.+\\)$") line then
    (match group 1 line, group 2 line with
     | Some name, Some p ->
       Some { category = "proof rejection";
              headline = Printf.sprintf "expected %s" (String.trim p);
              detail = Printf.sprintf "%s argument does not satisfy declared proof %s" name (String.trim p) }
     | _ -> None)
  (* capability violation: "Missing capabilities: (a b)" / "Capabilities not declared ...: (a)" *)
  else if re_match (Str.regexp "\\(Missing capabilities\\|Capabilities not declared[^:]*\\): \\(.+\\)$") line then
    (match group 2 line with
     | Some caps ->
       Some { category = "capability violation";
              headline = Printf.sprintf "missing capability %s" (String.trim caps);
              detail = String.trim line }
     | _ -> None)
  (* check reject surfaced through the fn/handler boundary: "<msg> (HTTP <code>)" *)
  else if re_match (Str.regexp "\\(.+\\) (HTTP \\([0-9]+\\))$") line then
    (match group 1 line, group 2 line with
     | Some msg, Some code ->
       Some { category = "check reject";
              headline = Printf.sprintf "check rejected: %s" (String.trim msg);
              detail = Printf.sprintf "%s (HTTP %s)" (String.trim msg) code }
     | _ -> None)
  else None

let cmd_render args =
  let map_file, trace_file =
    match args with
    | [mf] -> mf, None
    | [mf; tf] -> mf, Some tf
    | _ -> usage (); exit 1
  in
  if not (Sys.file_exists map_file) then die (Printf.sprintf "no such map file: %s" map_file);
  let smap = Source_map.of_json (read_file map_file) in
  let trace = match trace_file with Some tf -> read_file tf | None -> read_all_stdin () in
  let frames = Source_map.translate_frames smap trace in
  (* The deepest resolved frame is the originating Tesl construct (Racket traces
     list the innermost call first; we take the first resolved one). *)
  let originating =
    List.fold_left
      (fun acc (f : Source_map.translated_frame) ->
        match acc, f.Source_map.resolved with
        | None, Some e -> Some e
        | _ -> acc)
      None frames
  in
  (* First classifiable failure line drives the headline. *)
  let failure =
    List.fold_left
      (fun acc line -> match acc with Some _ -> acc | None -> classify_line line)
      None (String.split_on_char '\n' trace)
  in
  (match failure, originating with
   | Some f, Some e ->
     let where = if e.Source_map.form <> "" then Printf.sprintf " (%s)" e.Source_map.form else "" in
     Printf.printf "%s:%d:%d%s: %s\n  \xe2\x80\x94 %s [%s]\n"
       e.Source_map.tesl_file e.Source_map.tesl_line e.Source_map.tesl_col where
       f.headline f.detail f.category
   | Some f, None ->
     (* No frame resolved (e.g. the failing form has no checkpoint), but we can
        still render the category headline. *)
     Printf.printf "%s\n  \xe2\x80\x94 %s [%s]\n" f.headline f.detail f.category
   | None, Some e ->
     let where = if e.Source_map.form <> "" then Printf.sprintf " (%s)" e.Source_map.form else "" in
     Printf.printf "%s:%d:%d%s: runtime failure\n"
       e.Source_map.tesl_file e.Source_map.tesl_line e.Source_map.tesl_col where
   | None, None ->
     (* Nothing recognised — fall back to the full translated trace so the user
        still gets the .tesl frames the translator could resolve. *)
     print_string (Source_map.translate_trace smap trace);
     print_newline ());
  let resolved = Source_map.count_resolved smap trace in
  Printf.eprintf "%s: resolved %d frame(s) to .tesl\n" prog resolved

(* ── entry ────────────────────────────────────────────────────────────────── *)

let () =
  match Array.to_list Sys.argv |> List.tl with
  | "emit-map" :: rest -> cmd_emit_map rest
  | "translate" :: rest -> cmd_translate rest
  | "render" :: rest -> cmd_render rest
  | ("-h" :: _) | ("--help" :: _) | [] -> usage (); exit 0
  | other :: _ -> die (Printf.sprintf "unknown subcommand: %s" other)
