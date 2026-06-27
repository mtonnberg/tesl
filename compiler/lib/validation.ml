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
  check_file_module_name_match m
  @ check_local_imports_exist m
  @ check_duplicate_imports m.imports
  @ check_imported_exposed_name_conflicts m
  @ check_imported_exposed_type_and_ctor_conflicts m
  @ check_self_imports m.module_name m.imports
  @ check_duplicate_top_level_names decls
  @ check_duplicate_adt_constructors decls
  @ check_duplicate_decl_fields decls
  @ check_capability_cycles decls
  @ check_check_fn_has_proof_return decls
  @ check_library_self_boundary m
  @ check_entity_structure ~facts decls
  @ check_capture_codec_types decls
  @ check_capture_proof_via ~facts decls
  @ check_api_endpoint_structure ~facts decls
  @ check_queue_structure decls
  @ check_channel_structure decls
  @ check_workers_structure ~extra_funcs:imported_funcs decls
  @ check_cache_structure decls
  @ check_email_structure decls
  @ check_config_field_schema decls
  @ check_database_entities m
  @ check_api_test_structure m
  @ check_test_descriptions decls
  @ check_server_completeness ~extra_funcs:imported_funcs decls
  @ check_sql_field_names ~facts decls
  @ check_codec_target_types ~facts decls
  @ check_codec_proof_coverage ~facts decls
  @ check_codec_field_types ~facts decls
  @ check_call_site_proofs ~facts decls
  @ check_record_field_proof_construction ~facts decls
  @ check_sql_where_clauses ~facts decls
  @ check_fn_return_proof_annotations ~facts decls
  @ check_circular_const_bindings decls
  @ check_ghost_witness_predicates decls
  @ check_filter_check_args ~facts decls
  @ check_forall_consistency ~facts decls
  @ check_fact_arg_types decls
  @ check_exists_bindings decls
  @ check_existential_proof_enforcement decls
  @ check_case_exhaustiveness ~extra_ctors:(load_imported_ctor_info m) decls
  @ check_name_shadowing m
  @ check_forall_param_subjects decls
  @ check_handler_capabilities ~cap_map decls
  @ check_pk_match decls
  @ check_insert_pk_match decls
  @ check_cookies_field_access decls
  @ check_adt_variant_names decls
  @ check_self_referential_aliases decls
  @ check_type_arities decls
  @ check_ord_operator_types ~facts decls
  @ check_handler_isolation decls
  @ check_auth_call_restriction decls
  @ check_imported_module_is_library m
  @ check_exported_signature_completeness m
  @ collect_import_parse_errors m
