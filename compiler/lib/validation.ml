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
  @ check_entity_structure decls
  @ check_api_endpoint_structure decls
  @ check_queue_structure decls
  @ check_channel_structure decls
  @ check_workers_structure ~extra_funcs:imported_funcs decls
  @ check_database_entities m
  @ check_api_test_structure m
  @ check_test_descriptions decls
  @ check_server_completeness ~extra_funcs:imported_funcs decls
  @ check_sql_field_names ~extra_funcs:imported_funcs decls
  @ check_codec_target_types decls
  @ check_codec_proof_coverage ~extra_funcs:imported_funcs decls
  @ check_codec_field_types decls
  @ check_call_site_proofs ~extra_funcs:imported_funcs decls
  @ check_record_field_proof_construction ~extra_funcs:imported_funcs decls
  @ check_sql_where_clauses ~extra_funcs:imported_funcs decls
  @ check_fn_return_proof_annotations ~extra_funcs:imported_funcs decls
  @ check_circular_const_bindings decls
  @ check_ghost_witness_predicates decls
  @ check_filter_check_args ~extra_funcs:imported_funcs decls
  @ check_forall_consistency ~extra_funcs:imported_funcs decls
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
  @ check_ord_operator_types ~extra_funcs:imported_funcs decls
  @ check_handler_isolation decls
  @ check_auth_call_restriction decls
  @ collect_import_parse_errors m
