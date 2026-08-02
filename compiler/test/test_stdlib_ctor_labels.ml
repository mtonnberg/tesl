(** Durable seam test: the compiler's stdlib constructor → field-label table
    agrees with the RUNTIME, in both directions.

    Closes the drift class behind GitHub #69's second defect.  {!Emit_racket.stdlib_ctor_fields}
    is a hand-maintained literal that tells [pattern_to_racket] which hash key each
    POSITIONAL sub-pattern of a stdlib constructor binds:

      case t of
        Tuple3 a b c -> ...      ⇒  (hash-ref (adt-value-fields t) 'first) …

    When a constructor is MISSING from that table the lowering silently falls back
    to using the pattern's own variable names as hash keys, emitting
    [(hash-ref … 'a)] against a value whose real keys are 'first/'second/'third.
    That type-checks, compiles, and passes the .rkt snapshot diff — then dies at
    runtime with "hash-ref: no value found for key".  `Tuple3` was missing exactly
    this way and nothing caught it, because the whole corpus only ever used the
    `Tuple3.first/.second/.third` accessors and never pattern-matched a Tuple3.

    The truth source is the runtime itself, never a grep: each constructor is
    APPLIED to distinguishable sentinels and the resulting [adt-value]'s field hash
    is read back to recover the labels IN CONSTRUCTOR ORDER.  Order matters — the
    lowering indexes into the label list positionally — and a hash's key order is
    unspecified, so it cannot be recovered any other way.

    Both directions are pinned:
      (1) every table row matches the runtime's actual ordered labels (wrong or
          reordered labels);
      (2) every field-carrying stdlib constructor the runtime exports HAS a row
          (the Tuple3 omission).

    Direction (2) discovers its candidate set by scanning the stdlib modules'
    real phase-0 exports, so a newly added stdlib constructor is required to have
    a row automatically, with nothing to remember to update here.

    Racket absent on PATH → self-skips loudly, matching the convention in
    test_stdlib_runtime_binding.ml; the authoritative gate always has racket. *)

open Alcotest

module SM = Map.Make (String)

(* ── Repo root (same walk as test_stdlib_runtime_binding.ml) ──────────────── *)

let is_repo_root d =
  Sys.file_exists (Filename.concat d "compile-examples.sh")
  && Sys.file_exists (Filename.concat d "tesl")

let rec up_to_root dir n =
  if n > 12 then None
  else if is_repo_root dir then Some dir
  else
    let parent = Filename.dirname dir in
    if parent = dir then None else up_to_root parent (n + 1)

let repo_root =
  let starts =
    [ (try Sys.getenv "TESL_REPO_ROOT" with Not_found -> "");
      Sys.getcwd ();
      (try Filename.dirname (Unix.realpath Sys.executable_name)
       with _ -> Filename.dirname Sys.executable_name) ]
  in
  let rec pick = function
    | [] -> failwith "test_stdlib_ctor_labels: could not locate the repo root"
    | "" :: rest -> pick rest
    | s :: rest -> (match up_to_root s 0 with Some r -> r | None -> pick rest)
  in
  pick starts

(* The stdlib .rkt modules that define or re-export data constructors.  A module
   listed here contributes its constructors to BOTH directions of the check. *)
let ctor_modules =
  [ "tesl/tuple.rkt"; "dsl/types.rkt"; "tesl/either-prim.rkt";
    "tesl/api-test.rkt"; "tesl/maybe.rkt" ]

let racket_available () = Sys.command "racket -e '(void)' >/dev/null 2>&1" = 0

(* Recover each exported constructor's ORDERED field labels from the runtime.
   A nullary constructor is already an adt-value; an n-ary one is a procedure,
   applied to sentinels so each field can be matched back to its argument
   position.  Anything that raises, or does not yield an adt-value whose field
   count equals the arity, is not a data constructor and is skipped. *)
let probe_script = {racket|#lang racket/base
(require racket/list racket/string)
;; usage: racket <script> <types.rkt> <rkt-path> ...
;; prints "<ctor>\t<label>,<label>,..." for every field-carrying data constructor
(define argv (current-command-line-arguments))
(define types-path (vector-ref argv 0))
(define types-mp `(file ,(path->string (path->complete-path types-path))))
(define adt-value?       (dynamic-require types-mp 'adt-value?))
(define adt-value-fields (dynamic-require types-mp 'adt-value-fields))

(define (ordered-labels ctor arity)
  (define sentinels
    (for/list ([i (in-range arity)]) (string->symbol (format "__ARG~a__" i))))
  (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
    (define v (apply ctor sentinels))
    (and (adt-value? v)
         (let ([fields (adt-value-fields v)])
           (and (= (hash-count fields) arity)
                (let ([ls (for/list ([s (in-list sentinels)])
                            (for/first ([(k fv) (in-hash fields)] #:when (eq? fv s)) k))])
                  (and (andmap values ls) ls)))))))

(define (classify mod name)
  (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
    (define v (dynamic-require mod name))
    (cond
      [(adt-value? v)
       (define fs (adt-value-fields v))
       (and (positive? (hash-count fs)) (hash-keys fs))]
      [(procedure? v)
       (for/or ([arity (in-list '(1 2 3 4))]) (ordered-labels v arity))]
      [else #f])))

(for ([p (in-vector argv 1)])
  (define mp `(file ,(path->string (path->complete-path p))))
  (dynamic-require mp (void))
  (define-values (vals _stxs) (module->exports mp))
  (for* ([ph (in-list vals)]
         #:when (equal? (car ph) 0)
         [exp (in-list (cdr ph))])
    (define name (car exp))
    (define s (symbol->string name))
    (when (and (positive? (string-length s)) (char-upper-case? (string-ref s 0)))
      (define ls (classify mp name))
      (when ls
        (printf "~a\t~a\n" name (string-join (map symbol->string ls) ","))))))
|racket}

(** ctor name → ordered field labels, as the RUNTIME actually builds them. *)
let runtime_ctor_labels () : string list SM.t =
  let script = Filename.temp_file "tesl-ctor-labels" ".rkt" in
  Out_channel.with_open_text script (fun oc -> output_string oc probe_script);
  let cmd =
    String.concat " "
      ("racket" :: Filename.quote script
       :: Filename.quote (Filename.concat repo_root "dsl/types.rkt")
       :: List.map (fun p -> Filename.quote (Filename.concat repo_root p)) ctor_modules)
  in
  let ic = Unix.open_process_in cmd in
  let acc = ref SM.empty in
  (try
     while true do
       let line = input_line ic in
       match String.index_opt line '\t' with
       | None -> ()
       | Some i ->
         let name = String.sub line 0 i in
         let labels = String.sub line (i + 1) (String.length line - i - 1) in
         acc := SM.add name (String.split_on_char ',' labels) !acc
     done
   with End_of_file -> ());
  let status = Unix.close_process_in ic in
  Sys.remove script;
  (match status with
   | Unix.WEXITED 0 -> ()
   | _ -> fail "racket constructor-label probe failed — a stdlib .rkt does not \
                even load (run the printed command by hand to see the error)");
  !acc

let compiler_table () : string list SM.t =
  List.fold_left
    (fun m (ctor, labels) -> SM.add ctor labels m)
    SM.empty Emit_racket.stdlib_ctor_fields

let show labels = String.concat "," labels

(* ── (1) every table row matches the runtime's real ordered labels ────────── *)

let test_rows_match () =
  if not (racket_available ()) then
    print_endline
      "SKIP - racket not on PATH; constructor-label seam self-skips \
       (the authoritative gate ./ci.sh runs with racket available)"
  else begin
    let runtime = runtime_ctor_labels () in
    let wrong =
      SM.fold
        (fun ctor labels acc ->
           match SM.find_opt ctor runtime with
           | Some real when real = labels -> acc
           | Some real ->
             Printf.sprintf "%s: table says [%s] but the runtime builds [%s]"
               ctor (show labels) (show real) :: acc
           | None ->
             Printf.sprintf
               "%s: in the compiler table but NOT exported as a data constructor \
                by any module in ctor_modules (stale row, or the module moved)"
               ctor :: acc)
        (compiler_table ()) []
    in
    if wrong <> [] then
      failf
        "Emit_racket.stdlib_ctor_fields disagrees with the runtime.  A wrong \
         label makes `case … of Ctor a b` emit a hash-ref against a key that \
         does not exist, which dies at RUNTIME ('hash-ref: no value found for \
         key') long after the gate is green:\n  %s"
        (String.concat "\n  " wrong)
  end

(* ── (2) every field-carrying runtime constructor has a table row ─────────── *)

let test_no_missing_rows () =
  if not (racket_available ()) then
    print_endline
      "SKIP - racket not on PATH; constructor-completeness seam self-skips \
       (the authoritative gate ./ci.sh runs with racket available)"
  else begin
    let table = compiler_table () in
    let missing =
      SM.fold
        (fun ctor labels acc ->
           if SM.mem ctor table then acc
           else Printf.sprintf "%s (runtime labels: [%s])" ctor (show labels) :: acc)
        (runtime_ctor_labels ()) []
    in
    if missing <> [] then
      failf
        "stdlib data constructor(s) carry fields but have NO row in \
         Emit_racket.stdlib_ctor_fields, so `case … of Ctor a b` silently \
         lowers to (hash-ref … 'a) — the exact GitHub #69 Tuple3 defect.  Add \
         a row with the labels shown:\n  %s"
        (String.concat "\n  " missing)
  end

let () =
  run "stdlib-ctor-labels"
    [ ( "field-labels",
        [ test_case "table rows match the runtime's ordered labels" `Quick test_rows_match;
          test_case "no field-carrying runtime ctor lacks a row" `Quick test_no_missing_rows ] ) ]
