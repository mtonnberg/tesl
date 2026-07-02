(** S3b (down-payment) — conformance of the single SQL op registry
    (Validation_common: sql_op / sql_op_effect / sql_op_of_name / is_sql_*_builtin
    / sql_{read,write}_op_names / all_sql_ops).

    The read/write EFFECT classification is soundness-load-bearing: it drives the
    capability write-set (dbRead vs dbWrite) and the FromDb forgery gate.  This
    test binds the classification to an INDEPENDENT oracle — the naming rule
    "every read op is named `select…`, every write op is not" — so a future op
    added to the type + `sql_op_of_name` but pointed at the WRONG effect fails the
    build (rather than silently widening what can be laundered as a read).  It
    also asserts the derived name-sets and the name predicates all AGREE with
    `sql_op_effect`, and that names round-trip through `sql_op_of_name`.

    S3b-b DONE: the emitter's free-variable SQL-keyword guard
    (emit_racket.ml, the `EVar` fallback) is now DERIVED from this registry — it
    calls [is_sql_builtin] directly instead of a hand-maintained literal that had
    drifted to 7 of 14 ops — so check (3) below (is_sql_builtin over all_sql_ops)
    IS the emit-guard coverage assertion; there is no longer a separate emitter
    list to drift.  NOTE (remaining, tracked as S3b in roadmap/later): the harder
    cross-seam half — binding this to the Racket guard set (`sql.rkt` per-builtin
    `require-capabilities!`) — is not yet asserted here.

    Pure OCaml, no alcotest / no Racket, so it runs in every gate:
      dune exec test/test_sql_registry.exe *)

open Validation_common

let failures = ref 0
let check name ok = if ok then Printf.printf "ok   - %s\n" name
  else begin incr failures; Printf.printf "FAIL - %s\n" name end

let starts_with pre s =
  String.length s >= String.length pre && String.sub s 0 (String.length pre) = pre

let () =
  (* 1. Effect classification agrees with the independent naming oracle:
     read <=> the op name begins with "select". *)
  List.iter (fun op ->
    let name = sql_op_name op in
    let oracle = if starts_with "select" name then SqlRead else SqlWrite in
    check (Printf.sprintf "effect(%s) matches naming oracle" name)
      (sql_op_effect op = oracle))
    all_sql_ops;

  (* 2. Names round-trip through sql_op_of_name (no typo drift between the
     of_name table and the name table). *)
  List.iter (fun op ->
    let name = sql_op_name op in
    check (Printf.sprintf "%s round-trips through sql_op_of_name" name)
      (sql_op_of_name name = Some op))
    all_sql_ops;

  (* 3. The name predicates agree with sql_op_effect for every op. *)
  List.iter (fun op ->
    let name = sql_op_name op in
    (match sql_op_effect op with
     | SqlRead ->
       check (Printf.sprintf "is_sql_read_builtin %s" name) (is_sql_read_builtin name);
       check (Printf.sprintf "not is_sql_write_builtin %s" name) (not (is_sql_write_builtin name))
     | SqlWrite ->
       check (Printf.sprintf "is_sql_write_builtin %s" name) (is_sql_write_builtin name);
       check (Printf.sprintf "not is_sql_read_builtin %s" name) (not (is_sql_read_builtin name)));
    check (Printf.sprintf "is_sql_builtin %s" name) (is_sql_builtin name))
    all_sql_ops;

  (* 4. The derived name-sets partition all op names: total and disjoint. *)
  let all_names = List.map sql_op_name all_sql_ops |> List.sort compare in
  let union = (sql_read_op_names @ sql_write_op_names) |> List.sort compare in
  check "read ∪ write op-names = all op-names" (union = all_names);
  check "read ∩ write op-names = empty"
    (not (List.exists (fun r -> List.mem r sql_write_op_names) sql_read_op_names));

  (* 5. A non-SQL name is not misclassified as a builtin. *)
  List.iter (fun n ->
    check (Printf.sprintf "%S is not an SQL builtin" n) (not (is_sql_builtin n)))
    [ "select_"; "insertX"; "map"; "filter"; "delete_all"; "" ];

  Printf.printf "\n%s (%d failure(s))\n"
    (if !failures = 0 then "PASS" else "FAILURES") !failures;
  exit (if !failures = 0 then 0 else 1)
