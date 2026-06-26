(** Source-position map: emitted-Racket [file:line] -> original [.tesl file:line].

    This is the headless substrate for "what broke, in Tesl terms" (roadmap
    item C / Track A / A1).  It is produced as a *sidecar* artifact next to the
    emitted [.rkt] (a [.tesl.map] JSON), so normal Racket emission stays
    byte-identical: the position data lives entirely outside the [.rkt].

    Two responsibilities:
      1. A data type + (de)serialisation for the map.
      2. [translate_trace]: rewrite a raw Racket stack trace (lines referencing
         the emitted [.rkt]) into [.tesl file:line] frames using the map.

    The map is *computed during emission* by {!Emit_racket} (which records line
    ranges against the [Location.loc] already carried by every AST node — no
    duplicate position tracking) and handed here for serialisation.  Downstream:
    A2 (Tesl-level failure rendering) and B2 (debugger breakpoints) consume the
    same artifact.

    No external dependencies (the compiler lib only links [str]); JSON is
    emitted and parsed by hand. *)

(** One mapping region.  [rkt_start_line]..[rkt_end_line] (inclusive, 1-based)
    in the emitted Racket file correspond to the Tesl source span beginning at
    [tesl_line]:[tesl_col] (1-based) in [tesl_file].  [form] is a short
    human-readable label for the originating construct (e.g. ["handler createUser"]),
    purely for diagnostics. *)
type entry = {
  rkt_start_line : int;
  rkt_end_line   : int;
  tesl_file      : string;
  tesl_line      : int;   (* 1-based *)
  tesl_col       : int;   (* 1-based *)
  tesl_end_line  : int;   (* 1-based *)
  tesl_end_col   : int;   (* 1-based *)
  form           : string;
}

(** A whole source-map for one emitted [.rkt]. *)
type t = {
  rkt_file : string;       (* the emitted .rkt this map describes ("" if not yet known) *)
  entries  : entry list;   (* sorted by rkt_start_line ascending *)
}

let empty rkt_file = { rkt_file; entries = [] }

(* ── Construction helpers ─────────────────────────────────────────────────── *)

(** Build an [entry] from a [Location.loc].  [Location] stores positions
    0-based; we publish 1-based lines/cols so they match what humans (and
    editors / Racket traces) see. *)
let entry_of_loc ~rkt_start_line ~rkt_end_line ~form (loc : Location.loc) =
  {
    rkt_start_line;
    rkt_end_line;
    tesl_file     = loc.Location.file;
    tesl_line     = loc.Location.start.line + 1;
    tesl_col      = loc.Location.start.col + 1;
    tesl_end_line = loc.Location.stop.line + 1;
    tesl_end_col  = loc.Location.stop.col + 1;
    form;
  }

(** Finalise a recorded entry list into a [t], sorted by emitted start line. *)
let of_entries ~rkt_file (entries : entry list) =
  let entries =
    List.stable_sort (fun a b -> compare a.rkt_start_line b.rkt_start_line) entries
  in
  { rkt_file; entries }

(* ── Lookup ───────────────────────────────────────────────────────────────── *)

(** Resolve an emitted-Racket line to the *narrowest* enclosing Tesl span.

    Regions nest (a top-level form encloses its body region), so the narrowest
    containing region is the most specific answer.  Returns [None] when no
    region covers [rkt_line] (e.g. a require/provide preamble line that has no
    user-source origin). *)
let resolve (m : t) (rkt_line : int) : entry option =
  let best = ref None in
  List.iter
    (fun e ->
      if e.rkt_start_line <= rkt_line && rkt_line <= e.rkt_end_line then
        match !best with
        | None -> best := Some e
        | Some b ->
          let span x = x.rkt_end_line - x.rkt_start_line in
          (* prefer the tighter (smaller) span; tie-break to the later/deeper one *)
          if span e <= span b then best := Some e)
    m.entries;
  !best

(* ── JSON serialisation (hand-rolled; no deps) ────────────────────────────── *)

let json_escape (s : string) : string =
  let buf = Buffer.create (String.length s + 8) in
  String.iter
    (fun c ->
      match c with
      | '"'  -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c when Char.code c < 0x20 ->
        Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

let entry_to_json (e : entry) : string =
  Printf.sprintf
    {|{"rktStart":%d,"rktEnd":%d,"teslFile":"%s","teslLine":%d,"teslCol":%d,"teslEndLine":%d,"teslEndCol":%d,"form":"%s"}|}
    e.rkt_start_line e.rkt_end_line (json_escape e.tesl_file)
    e.tesl_line e.tesl_col e.tesl_end_line e.tesl_end_col (json_escape e.form)

(** Serialise to a stable, pretty-printed JSON document. *)
let to_json (m : t) : string =
  let buf = Buffer.create 1024 in
  Buffer.add_string buf "{\n";
  Buffer.add_string buf (Printf.sprintf "  \"version\": 1,\n");
  Buffer.add_string buf (Printf.sprintf "  \"rktFile\": \"%s\",\n" (json_escape m.rkt_file));
  Buffer.add_string buf "  \"entries\": [";
  (match m.entries with
   | [] -> ()
   | _ ->
     Buffer.add_char buf '\n';
     let n = List.length m.entries in
     List.iteri
       (fun i e ->
         Buffer.add_string buf "    ";
         Buffer.add_string buf (entry_to_json e);
         if i < n - 1 then Buffer.add_char buf ',';
         Buffer.add_char buf '\n')
       m.entries;
     Buffer.add_string buf "  ");
  Buffer.add_string buf "]\n";
  Buffer.add_string buf "}\n";
  Buffer.contents buf

(* ── JSON deserialisation ─────────────────────────────────────────────────── *)
(* Minimal, tolerant scanner for exactly the document {!to_json} produces.  We
   only need to read back our own format, so a full JSON parser is overkill; we
   extract the fields with [Str] regexps over each entry object. *)

let unescape_json (s : string) : string =
  let buf = Buffer.create (String.length s) in
  let n = String.length s in
  let i = ref 0 in
  while !i < n do
    if s.[!i] = '\\' && !i + 1 < n then begin
      (match s.[!i + 1] with
       | 'n' -> Buffer.add_char buf '\n'
       | 'r' -> Buffer.add_char buf '\r'
       | 't' -> Buffer.add_char buf '\t'
       | '"' -> Buffer.add_char buf '"'
       | '\\' -> Buffer.add_char buf '\\'
       | '/' -> Buffer.add_char buf '/'
       | c -> Buffer.add_char buf c);
      i := !i + 2
    end else begin
      Buffer.add_char buf s.[!i];
      incr i
    end
  done;
  Buffer.contents buf

let find_int (obj : string) (key : string) : int option =
  let re = Str.regexp ("\"" ^ key ^ "\"[ \t]*:[ \t]*\\(-?[0-9]+\\)") in
  try
    let _ = Str.search_forward re obj 0 in
    Some (int_of_string (Str.matched_group 1 obj))
  with Not_found -> None

let find_str (obj : string) (key : string) : string option =
  (* match "key" : "....."  with escaped quotes inside *)
  let re = Str.regexp ("\"" ^ key ^ "\"[ \t]*:[ \t]*\"\\(\\(\\\\.\\|[^\"\\]\\)*\\)\"") in
  try
    let _ = Str.search_forward re obj 0 in
    Some (unescape_json (Str.matched_group 1 obj))
  with Not_found -> None

let entry_of_json (obj : string) : entry option =
  match
    find_int obj "rktStart", find_int obj "rktEnd",
    find_str obj "teslFile", find_int obj "teslLine", find_int obj "teslCol"
  with
  | Some rkt_start_line, Some rkt_end_line, Some tesl_file, Some tesl_line, Some tesl_col ->
    Some {
      rkt_start_line; rkt_end_line; tesl_file; tesl_line; tesl_col;
      tesl_end_line = Option.value (find_int obj "teslEndLine") ~default:tesl_line;
      tesl_end_col  = Option.value (find_int obj "teslEndCol") ~default:tesl_col;
      form          = Option.value (find_str obj "form") ~default:"";
    }
  | _ -> None

(** Parse a document previously produced by {!to_json}. *)
let of_json (s : string) : t =
  let rkt_file = Option.value (find_str s "rktFile") ~default:"" in
  (* Split the entries array into individual {...} objects.  Our entries have no
     nested braces, so splitting on '}' boundaries inside the entries region is
     safe. *)
  let entries =
    (* isolate the substring after "entries" to avoid matching rktFile etc. *)
    let start =
      try (Str.search_forward (Str.regexp "\"entries\"") s 0) with Not_found -> 0
    in
    let region = String.sub s start (String.length s - start) in
    let re = Str.regexp "{[^{}]*}" in
    let rec collect pos acc =
      match (try Some (Str.search_forward re region pos) with Not_found -> None) with
      | None -> List.rev acc
      | Some i ->
        let obj = Str.matched_string region in
        let next = i + String.length obj in
        (match entry_of_json obj with
         | Some e -> collect next (e :: acc)
         | None -> collect next acc)
    in
    collect 0 []
  in
  of_entries ~rkt_file entries

(* ── Trace translation ────────────────────────────────────────────────────── *)

(** A single translated frame. *)
type translated_frame = {
  raw          : string;             (* the original trace line, verbatim *)
  rkt_line     : int option;         (* the .rkt line we parsed out, if any *)
  resolved     : entry option;       (* the Tesl span it maps to, if found *)
}

(** Decide whether a trace line refers to the [.rkt] this map describes.
    We match on the basename so absolute vs. relative paths both resolve.
    When [m.rkt_file] is empty (caller did not record it) we fall back to
    "any line that mentions a [.rkt] path", which is still useful for a
    single-module program. *)
let line_refers_to_rkt (m : t) (line : string) : bool =
  if m.rkt_file <> "" then begin
    let base = Filename.basename m.rkt_file in
    (* substring search for the basename *)
    let contains hay needle =
      let hl = String.length hay and nl = String.length needle in
      if nl = 0 then true
      else
        let rec go i = i + nl <= hl && (String.sub hay i nl = needle || go (i + 1)) in
        go 0
    in
    contains line base
  end else begin
    (* heuristic: mentions a .rkt path *)
    try ignore (Str.search_forward (Str.regexp "\\.rkt") line 0); true
    with Not_found -> false
  end

(* Patterns Racket uses for source positions in traces / error messages.
   Examples:
     /abs/path/to/foo.rkt:123:45
     foo.rkt:123:7:
     ...in: foo.rkt:88
   We look for "<something>.rkt:" followed by a line number, optionally a col. *)
let rkt_line_re = Str.regexp "[^ \t\n:]*\\.rkt:\\([0-9]+\\)\\(:[0-9]+\\)?"

(** Extract the first [.rkt:LINE] occurrence on a trace line, if present. *)
let parse_rkt_line (line : string) : int option =
  try
    let _ = Str.search_forward rkt_line_re line 0 in
    Some (int_of_string (Str.matched_group 1 line))
  with Not_found | Failure _ -> None

(** Translate a single raw trace line. *)
let translate_line (m : t) (line : string) : translated_frame =
  if not (line_refers_to_rkt m line) then
    { raw = line; rkt_line = None; resolved = None }
  else
    let rkt_line = parse_rkt_line line in
    let resolved = match rkt_line with Some n -> resolve m n | None -> None in
    { raw = line; rkt_line; resolved }

(** Translate a whole raw trace (newline-separated) into structured frames. *)
let translate_frames (m : t) (trace : string) : translated_frame list =
  String.split_on_char '\n' trace |> List.map (translate_line m)

(** Render a single translated frame back to a human line.  When a frame
    resolved to a Tesl span we *prepend* the Tesl location and keep the original
    Racket frame for reference; unresolved lines pass through verbatim. *)
let render_frame (f : translated_frame) : string =
  match f.resolved with
  | Some e ->
    let where =
      if e.form <> "" then Printf.sprintf " (%s)" e.form else ""
    in
    Printf.sprintf "%s:%d:%d%s    [from %s]"
      e.tesl_file e.tesl_line e.tesl_col where (String.trim f.raw)
  | None -> f.raw

(** Rewrite a raw Racket stack trace into Tesl terms.

    Every line that referenced the emitted [.rkt] and that we could resolve is
    rewritten to lead with the responsible [.tesl file:line:col]; other lines
    pass through unchanged.  This is the headless "what broke, in Tesl terms"
    rendering used by CI output, production traces, failing [tesl test], and AI
    agents reading a trace. *)
let translate_trace (m : t) (trace : string) : string =
  translate_frames m trace
  |> List.map render_frame
  |> String.concat "\n"

(** Convenience: how many frames in [trace] resolved to a Tesl span. *)
let count_resolved (m : t) (trace : string) : int =
  translate_frames m trace
  |> List.filter (fun f -> f.resolved <> None)
  |> List.length
