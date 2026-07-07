(** Validation orchestrator — calls all validation passes in sequence.

    The actual validation logic lives in:
      validation_common.ml        — shared types, utilities, import loading
      validation_structural.ml    — entity, API, queue, channel, workers, server
      validation_sql_codec.ml     — SQL field names, codec coverage/types
      validation_proof.ml         — call-site proof checking, ForAll/Exists
      validation_names.ml         — case exhaustiveness, name shadowing, imports
      validation_capabilities.ml  — capabilities, type arities, ord operators
      validation_advanced.ml      — SQL WHERE, record-field proofs, annotations,
                                    auth restrictions, handler isolation *)

open Ast
open Validation_common
open Validation_structural
open Validation_sql_codec
open Validation_proof
open Validation_names
open Validation_capabilities
open Validation_advanced

(* Re-export the core type so compile.ml can still use Validation.validation_error *)
type validation_error = Validation_common.validation_error

let check_module (m : module_form) : validation_error list =
  let decls = m.decls in
  let imported_funcs = load_imported_func_info m in
  let cap_map = build_local_cap_map decls @ load_imported_cap_map m in
  (* Module-level facts computed ONCE and threaded through the passes that would
     otherwise rebuild build_func_info/build_fields_map/build_ctor_info/
     build_field_proof_map. Built with ~extra_funcs:imported_funcs so mf_funcs is
     exactly [build_func_info decls @ imported_funcs] — matching every pass below
     that is called ~extra_funcs:imported_funcs. (check_existential_proof_enforcement
     is intentionally NOT given facts: the orchestrator calls it without extra_funcs.) *)
  let facts = build_module_facts ~extra_funcs:imported_funcs decls in
  (* B5: the manual deep-link topic is decided HERE by which pass produced the
     error — a semantic object, listed exactly once per pass — and stamped onto
     every error the pass returns via [with_topic].  Message text never routes
     the anchor (that was the substring-sniffing bug this replaces).  Each pass
     gets exactly one stable topic, so the same rule can never route two ways. *)
  let open Error_codes in
  let ( @: ) (t : manual_topic) es = with_topic t es in
    (TNaming @: check_file_module_name_match m)
  @ (TNaming @: check_local_imports_exist m)
  @ (TNaming @: check_duplicate_imports m.imports)
  @ (TNaming @: check_imported_exposed_name_conflicts m)
  @ (TNaming @: check_imported_exposed_type_and_ctor_conflicts m)
  @ (TNaming @: check_self_imports m.module_name m.imports)
  @ (TNaming @: check_duplicate_top_level_names decls)
  @ (TNaming @: check_duplicate_adt_constructors decls)
  @ (TNaming @: check_duplicate_decl_fields decls)
  @ (TCapability @: check_capability_cycles decls)
  @ (TProof @: check_check_fn_has_proof_return decls)
  @ (TDatabase @: check_entity_structure ~facts decls)
  @ (TCodec @: check_capture_codec_types decls)
  @ (TProof @: check_capture_proof_via ~facts decls)
  @ (TProof @: check_auth_proof_via ~facts decls)
  @ (TProof @: check_endpoint_proof_subject_binding decls)
  @ (TStructural @: check_api_endpoint_structure ~facts decls)
  @ (TStructural @: check_queue_structure decls)
  @ (TStructural @: check_channel_structure decls)
  @ (TStructural @: check_workers_structure ~extra_funcs:imported_funcs decls)
  @ (TStructural @: check_cache_structure decls)
  @ (TStructural @: check_email_structure decls)
  @ (TStructural @: check_typed_config_blocks decls)
  @ (TStructural @: check_app_wiring decls)
  @ (TDatabase @: check_database_entities m)
  @ (TTesting @: check_api_test_structure m)
  @ (TTesting @: check_test_descriptions decls)
  @ (TStructural @: check_server_completeness ~extra_funcs:imported_funcs decls)
  @ (TDatabase @: check_sql_field_names ~facts decls)
  @ (TCodec @: check_codec_target_types ~facts decls)
  @ (TCodec @: check_codec_proof_coverage ~facts decls)
  @ (TCodec @: check_codec_alt_completeness ~facts decls)
  @ (TCodec @: check_codec_field_types ~facts decls)
  @ (TProof @: check_call_site_proofs ~facts decls)
  @ (TProof @: check_record_field_proof_construction ~facts decls)
  @ (TDatabase @: check_sql_where_clauses ~facts decls)
  @ (TDatabase @: check_group_by_rules decls)
  @ (TProof @: Proof_discharge.check_fn_return_proof_annotations ~facts decls)
  @ (TNaming @: check_circular_const_bindings decls)
  @ (TProof @: check_ghost_witness_predicates ~facts decls)
  @ (TProof @: check_filter_check_args ~facts decls)
  @ (TProof @: check_forall_consistency ~facts decls)
  @ (TProof @: check_fact_arg_types decls)
  @ (TProof @: check_exists_bindings decls)
  (* review 2.1: now given imported_funcs so an existential pack of an IMPORTED
     proof-returning function (e.g. `insertCommentBody … ? FromDb`) is recognised
     as proof-carrying rather than falsely rejected. *)
  @ (TProof @: check_existential_proof_enforcement ~extra_funcs:imported_funcs decls)
  @ (TNaming @: check_case_exhaustiveness ~extra_ctors:(load_imported_ctor_info m) decls)
  @ (TNaming @: check_name_shadowing m)
  (* S5b: the reserved-generated-name check was retired — every emitter temp is now
     minted with a lexer-illegal hyphen (`tesl-case-N`, `tesl-ignored-N`, …), so a
     user identifier can never collide with one by construction. *)
  @ (TProof @: check_forall_param_subjects decls)
  @ (TCapability @: check_handler_capabilities ~cap_map ~imported_func_caps:(load_imported_func_caps m) decls)
  @ (TDatabase @: check_pk_match decls)
  @ (TDatabase @: check_insert_pk_match decls)
  @ (TDatabase @: check_nonexist_named_pack_insert decls)
  (* Fail-closed provenance-spelling gate (2026-07-03 hole #7): reject any
     FromDb/FromQueue/FromDeadQueue return-spec predicate not written as the
     checkable `(Column == subject)` form, so the dataflow verifiers above can
     never be silently bypassed by a non-canonical spelling. *)
  @ (TDatabase @: check_provenance_spelling decls)
  @ (TStructural @: check_cookies_field_access decls)
  @ (TNaming @: check_adt_variant_names decls)
  (* 2026-07-03 hole #8: reject `fact FromDb`/`fact ForAll`/… re-declarations of
     reserved framework provenance/quantifier predicates. *)
  @ (TNaming @: check_reserved_predicate_names decls)
  @ (TNaming @: check_self_referential_aliases decls)
  @ (TNaming @: check_type_arities decls)
  (* Ord/Eq operand decidability is now driven from HM-resolved types at the
     comparison site (checker.ml infer_binop, Eq/Ord Stage 1); the divergent
     shadow re-inferencer `check_ord_operator_types` was retired. *)
  @ (TStructural @: check_handler_isolation decls)
  @ (TCapability @: check_auth_call_restriction decls)
  @ (TNaming @: collect_import_parse_errors m)
