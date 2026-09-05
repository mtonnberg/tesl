(** Browser driver for the Tesl playground (js_of_ocaml).

    TWO functions are exported to JavaScript:

      teslCheck(source : string) : string   // a JSON document
      teslExplain(code : string) : string   // `tesl explain <CODE>` prose, "" if none

    It is the browser equivalent of `tesl --check-json <file>`: it reuses
    {!Compile.check_source} + {!Linter.lint_file} (the same pair
    [compiler/bin/main.ml]'s [check_json_diags] uses) and serialises with
    {!Compile.diag_to_json}, so the diagnostics — including the
    machine-applicable [fix] edits and their titles — are byte-identical to what
    the CLI and the LSP see.

    The returned document is a SUPERSET of the CLI's `--check-json` shape:

      { "version": 1,
        "diagnostics": [ <same objects as --check-json> ],
        "go":     <string|null>,   // emitted only when the check passes
        "racket": <string|null>,   // legacy alias of "go", retained for clients
        "ts":     <string|null>,
        "elm":    <string|null> }

    Extra keys, never fewer, so a consumer written against `--check-json` keeps
    working.

    What this driver deliberately does NOT do: run anything. There is no Go
    runtime, no PostgreSQL, no HTTP server in the browser. It checks, and it
    shows you what the compiler would have emitted.

    Filesystem: js_of_ocaml gives us an in-memory pseudo-FS. The source is
    written into it under a fixed name before checking, because
    {!Linter.lint_file} re-reads the file from disk. Local `import`s of other
    files cannot resolve (there is only one file) — the playground is
    single-module by construction. *)

open Js_of_ocaml

(* The virtual file NAME is derived from the module header, because one of the
   validation passes requires header and file name to agree ("the compiler
   resolves imports by file name").  A fixed `playground.tesl` would therefore
   force every pasted snippet to be `module Playground`, and pasting a lesson
   verbatim would report a spurious error.  Deriving the name instead means any
   well-formed snippet checks exactly as it does on disk. *)
let vfile_of_source source =
  let n = String.length source in
  let is_ident c =
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    || (c >= '0' && c <= '9') || c = '_'
  in
  (* Find a line whose first token is `module`, skipping comments/blank lines. *)
  let rec scan i =
    if i >= n then None
    else
      (* start of a line: skip leading whitespace *)
      let rec skip_ws j = if j < n && (source.[j] = ' ' || source.[j] = '\t') then skip_ws (j + 1) else j in
      let s = skip_ws i in
      let eol = try String.index_from source s '\n' with Not_found -> n in
      let line = String.sub source s (eol - s) in
      if String.length line >= 7 && String.sub line 0 7 = "module " then begin
        let rest = String.sub line 7 (String.length line - 7) in
        let k = ref 0 in
        while !k < String.length rest && (rest.[!k] = ' ' || rest.[!k] = '\t') do incr k done;
        let start = !k in
        while !k < String.length rest && is_ident rest.[!k] do incr k done;
        if !k > start then Some (String.sub rest start (!k - start)) else None
      end
      else if eol >= n then None
      else scan (eol + 1)
  in
  match scan 0 with
  | Some name -> name ^ ".tesl"
  | None -> "playground.tesl"

(* A mounted pseudo-directory rather than [Sys_js.create_file]: create_file only
   works when the '/' device is js_of_ocaml's in-memory fake one, so under Node
   (where the runtime mounts the REAL filesystem) it raises and the linter
   silently contributes nothing.  A [Sys_js.mount] resolver installs our own
   in-memory device at [vfs_dir] and therefore behaves identically in the
   browser and under Node — which is what makes the Node smoke test meaningful. *)
let vfs_dir = "/tesl/"

let sources : (string, string) Hashtbl.t = Hashtbl.create 8

let () =
  try Sys_js.mount ~path:vfs_dir (fun ~prefix:_ ~path -> Hashtbl.find_opt sources path)
  with _ ->
    (* Fail soft: without the pseudo-directory the linter contributes nothing
       (Linter.lint_file swallows Sys_error and returns []), but the parser,
       type checker, proof checker and validation passes all work off the
       in-memory string and are unaffected. *)
    ()

let register_source basename content = Hashtbl.replace sources basename content

(* Mirrors [check_json_diags] in compiler/bin/main.ml: do not lint a buffer the
   parser or lexer rejected — the linter's re-parse would be meaningless. *)
let check_diags vfile source =
  let diags = Compile.check_source vfile source in
  if List.exists
       (fun (d : Compile.diagnostic) -> d.source = "parser" || d.source = "lexer")
       diags
  then diags
  else diags @ Linter.lint_file vfile

let json_or_null = function
  | None -> "null"
  | Some s -> Compile.json_encode_string s

(* Emitters run only on a clean check, exactly as the CLI gates
   --generate-ts / --generate-elm behind the full checker (main.ml §B1): a
   program that fails `tesl check` must not produce a plausible artifact. *)
let emitted vfile source =
  match Parser.parse_module vfile source with
  | Err _ -> (None, None, None)
  | Ok m ->
    let racket =
      match Compile.compile_source ~root_path:"." ~type_check:false vfile source with
      | Compile.Success rkt -> Some rkt
      | Compile.Failure _ -> None
    in
    let m' = try Compile.merge_imported_client_decls m with _ -> m in
    let ts = try Some (Emit_ts.emit_ts m') with _ -> None in
    let elm = try Some (Emit_elm.emit_elm m') with _ -> None in
    (racket, ts, elm)

let check (src : Js.js_string Js.t) : Js.js_string Js.t =
  let source = Js.to_string src in
  let basename = vfile_of_source source in
  register_source basename source;
  let vfile = vfs_dir ^ basename in
  let json =
    try
      let diags = check_diags vfile source in
      let has_error =
        List.exists (fun (d : Compile.diagnostic) -> d.severity = "error") diags
      in
      let racket, ts, elm = if has_error then (None, None, None) else emitted vfile source in
      Printf.sprintf
        {|{"version":1,"backend":"go","diagnostics":[%s],"go":%s,"racket":%s,"ts":%s,"elm":%s}|}
        (String.concat "," (List.map Compile.diag_to_json diags))
        (json_or_null racket) (json_or_null racket) (json_or_null ts) (json_or_null elm)
    with e ->
      (* A crash in the compiler must surface as a diagnostic, not a blank
         page: the playground is also a bug reporter. *)
      Printf.sprintf
        {|{"version":1,"backend":"go","diagnostics":[{"file":%s,"start":{"line":0,"col":0},"end":{"line":0,"col":0},"severity":"error","code":"E000","message":%s,"fix":null,"source":"playground"}],"go":null,"racket":null,"ts":null,"elm":null}|}
        (Compile.json_encode_string vfile)
        (Compile.json_encode_string
           ("internal compiler error: " ^ Printexc.to_string e))
  in
  Js.string json

let () = Js.Unsafe.set Js.Unsafe.global "teslCheck" (Js.wrap_callback check)

(* ── teslExplain: the same prose as `tesl explain <CODE>` ────────────────────
   Every diagnostic carries a stable code, and {!Error_codes.explain} is the ONE
   place its explanation lives — the CLI's `tesl explain` / `tesl help <CODE>`
   render exactly this string.  Exporting it costs nothing: [error_codes.ml] is
   already linked (the checker calls into it for titles and categories) and holds
   its prose as plain string literals.

   Called WITHOUT [~manual], deliberately.  The optional argument only swaps the
   trailing "read more: tesl help manual <anchor>" line for a message-refined
   anchor; resolving that anchor to actual prose is what would reach for
   {!Embedded_docs} and triple the artifact (see the note at the bottom of this
   file).  The default anchor is a literal string, so the line stays a pointer at
   the CLI rather than becoming an in-page manual.

   Unknown code -> "" (not an exception, not "null"): the page renders the
   disclosure only when there is prose, and a missing code is not an error. *)
let explain (code : Js.js_string Js.t) : Js.js_string Js.t =
  match Error_codes.explain (Js.to_string code) with
  | Some prose -> Js.string prose
  | None -> Js.string ""

let () = Js.Unsafe.set Js.Unsafe.global "teslExplain" (Js.wrap_callback explain)

(* Deliberately NOT exported: anything that references [Embedded_docs] pulls the
   entire embedded manual into the bundle.  Measured, with the same docs
   snapshot: 1 127 187 B → 3 424 269 B raw (359 603 B → 867 613 B gzipped).
   js_of_ocaml's dead-code elimination drops all 2.3 MB as long as nothing
   reaches for it, so an in-page `tesl help` should fetch the manual as a
   separate lazily-loaded file rather than link it in here. *)
