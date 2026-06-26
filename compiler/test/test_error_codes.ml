(** Stable-error-code registry tests (roadmap A3 / WS4).

    Guards the contract that:
      1. every code in [Error_codes.registry] is unique;
      2. every documented manual anchor (`section#anchor`) on a code resolves to
         a REAL heading in the named manual section — so the "read more" links a
         diagnostic prints never dangle (this is the same stability promise the
         manual-side test makes, but starting from the compiler's registry);
      3. the broad validation code [V001] refines to the right section by
         message keyword;
      4. [explain] / [index] / [lookup] behave.

    Pure OCaml + the compiler lib; reads manual/*.md off disk (located the same
    way manual/tests/test_embedded_docs.ml does). Run:
      dune exec test/test_error_codes.exe
*)

let failures = ref 0
let check name ok msg =
  if ok then Printf.printf "ok   - %s\n" name
  else begin incr failures; Printf.printf "FAIL - %s: %s\n" name msg end

(* ── Locate manual/ (cwd is the project root under dune; be robust) ────────── *)
let is_manual_dir d =
  Sys.file_exists (Filename.concat d "anchors.md")
  && Sys.file_exists (Filename.concat d "MANUAL.md")

let rec up_to_manual dir n =
  if n > 12 then None
  else
    let cand = Filename.concat dir "manual" in
    if is_manual_dir cand then Some cand
    else if is_manual_dir dir then Some dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then None else up_to_manual parent (n + 1)

let manual_dir =
  let starts =
    [ (try Sys.getenv "TESL_MANUAL_DIR" with Not_found -> "");
      Sys.getcwd ();
      (try Filename.dirname (Unix.realpath Sys.executable_name)
       with _ -> Filename.dirname Sys.executable_name) ]
  in
  let rec pick = function
    | [] -> None
    | s :: rest ->
      if s <> "" && is_manual_dir s then Some s
      else match up_to_manual (if s = "" then Sys.getcwd () else s) 0 with
        | Some d -> Some d
        | None -> pick rest
  in
  match pick starts with
  | Some d -> d
  | None ->
    prerr_endline "FATAL: could not locate manual/ (set TESL_MANUAL_DIR)";
    exit 2

let read_file file =
  let path = Filename.concat manual_dir file in
  try Some (In_channel.with_open_text path In_channel.input_all)
  with Sys_error _ -> None

(* Section name -> manual file (mirrors compiler/bin/main.ml's resolution for
   the sections that actually live inside manual/).  language-spec/getting-
   started have files too but only the ones with promised anchors matter. *)
let section_file = function
  | "getting-started" -> Some "GETTING-STARTED.md"
  | "overview"        -> Some "overview.md"
  | "examples"        -> Some "examples.md"
  | "best-practices"  -> Some "best-practices.md"
  | "faq"             -> Some "FAQ.md"
  | "anchors"         -> Some "anchors.md"
  (* language-spec lives at repo root, not manual/; dev lives in dev-docs/.
     We do not slug-check those here (no in-manual file), matching the manual
     test's policy. *)
  | _ -> None

(* slug rule — identical to Error_codes.slug_of_heading / anchors.md *)
let slug heading =
  let b = Buffer.create (String.length heading) in
  String.iter (fun c ->
    let c = Char.lowercase_ascii c in
    if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') then Buffer.add_char b c
    else if c = ' ' || c = '-' then Buffer.add_char b ' ') heading;
  String.split_on_char ' ' (Buffer.contents b)
  |> List.filter (fun s -> s <> "")
  |> String.concat "-"

let slugs_of_file file =
  match read_file file with
  | None -> []
  | Some content ->
    String.split_on_char '\n' content
    |> List.filter_map (fun line ->
         let l = String.trim line in
         if String.length l >= 2 && l.[0] = '#' then begin
           let i = ref 0 in
           while !i < String.length l && l.[!i] = '#' do incr i done;
           let text = String.sub l !i (String.length l - !i) |> String.trim in
           if text = "" then None else Some (slug text)
         end else None)

(* split "section#anchor" / "section" *)
let split_anchor s =
  match String.index_opt s '#' with
  | Some i -> String.sub s 0 i, Some (String.sub s (i+1) (String.length s - i - 1))
  | None -> s, None

let () =
  Printf.printf "# error-code registry tests (manual_dir = %s)\n" manual_dir;

  let reg = Error_codes.registry in

  (* 1. uniqueness *)
  let codes = List.map (fun (e : Error_codes.entry) -> e.code) reg in
  let dups =
    List.filter (fun c -> List.length (List.filter ((=) c) codes) > 1) codes
    |> List.sort_uniq compare
  in
  check "codes are unique" (dups = [])
    (Printf.sprintf "duplicate codes: %s" (String.concat ", " dups));

  check "registry is non-trivial" (List.length reg >= 20)
    (Printf.sprintf "only %d codes" (List.length reg));

  (* 2. every code documented (title + explanation non-empty) *)
  List.iter (fun (e : Error_codes.entry) ->
    check (Printf.sprintf "code documented: %s" e.code)
      (e.title <> "" && String.length e.explanation > 10)
      "empty title/explanation")
    reg;

  (* 3. every documented manual anchor resolves to a real heading *)
  List.iter (fun (e : Error_codes.entry) ->
    match e.manual with
    | None -> ()
    | Some spec ->
      let section, anchor = split_anchor spec in
      (match anchor with
       | None -> ()  (* whole-section citation; nothing to slug-check *)
       | Some a ->
         (match section_file section with
          | None ->
            (* sections without an in-manual file: only allow known ones *)
            check (Printf.sprintf "anchor section known: %s (%s)" spec e.code)
              (section = "language-spec" || section = "dev")
              (Printf.sprintf "unknown section '%s'" section)
          | Some file ->
            check (Printf.sprintf "anchor resolves: %s (%s)" spec e.code)
              (List.mem a (slugs_of_file file))
              (Printf.sprintf "no heading in %s slugs to '%s'" file a))))
    reg;

  (* 4. V001 message refinement *)
  let refines msg expected =
    Error_codes.manual_for ~code:"V001" ~message:msg = Some expected
  in
  check "V001 capability -> api-design"
    (refines "handler 'h' uses [db] but does not declare the required capabilities"
       "best-practices#api-design") "wrong refinement";
  check "V001 database -> database-access"
    (refines "database `D` references unknown entity `E`" "best-practices#database-access")
    "wrong refinement";
  check "V001 codec -> validation-patterns"
    (refines "codec 'C' refers to unknown type 'C'" "best-practices#validation-patterns")
    "wrong refinement";
  check "V001 server -> api-design"
    (refines "server 'S': handler 'h' for endpoint 'e' is not declared"
       "best-practices#api-design") "wrong refinement";

  (* 4b. every anchor manual_for can EMIT (incl. V001 refinements not tied to a
     code's manual field) resolves to a real heading. Guards against a heading
     rename silently breaking a refined deep-link. *)
  let emitted_anchors =
    [ "overview#core-principles";
      "best-practices#validation-patterns";
      "best-practices#proof-management";
      "best-practices#api-design";
      "best-practices#database-access";
      "best-practices#error-handling";
      "best-practices#testing" ]
  in
  List.iter (fun spec ->
    let section, anchor = split_anchor spec in
    match anchor, section_file section with
    | Some a, Some file ->
      check (Printf.sprintf "emitted anchor resolves: %s" spec)
        (List.mem a (slugs_of_file file))
        (Printf.sprintf "no heading in %s slugs to '%s'" file a)
    | _ -> ())
    emitted_anchors;

  (* 5. explain / index / lookup *)
  check "explain known code" (Error_codes.explain "T001" <> None) "no explanation";
  check "explain unknown code" (Error_codes.explain "ZZZ999" = None) "should be None";
  check "lookup known" (Error_codes.lookup "V001" <> None) "missing";
  check "index mentions a code" (Error_codes.contains_ci ~needle:"E000" (Error_codes.index ()))
    "index missing E000";

  (* 6. the codes the contract & rendering paths assert on are all present *)
  List.iter (fun c ->
    check (Printf.sprintf "rendered code present in registry: %s" c)
      (Error_codes.lookup c <> None) "missing from registry")
    [ "E000"; "T001"; "P001"; "V001"; "VBOOL001"; "VBOOL002"; "W010"; "W080" ];

  Printf.printf "\n%s (%d failure(s))\n"
    (if !failures = 0 then "PASS" else "FAILURES") !failures;
  exit (if !failures = 0 then 0 else 1)
