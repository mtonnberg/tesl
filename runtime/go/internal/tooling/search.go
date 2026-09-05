package tooling

import "fmt"

// Validate the discovery fields MCP consumes. A missing requirements object must
// never turn into an apparently unrestricted result. The compiler owns types and
// matching; this adapter does not reimplement them.
func validateSearchResponse(root map[string]any) error {
	for _, field := range []string{"catalog_id", "scope", "query", "mode"} {
		if _, err := requiredString(root, field); err != nil {
			return err
		}
	}
	if root["scope"] != "builtins" || (root["mode"] != "text" && root["mode"] != "type") {
		return fmt.Errorf("unsupported search scope or mode")
	}
	if err := searchNullableString(root, "error"); err != nil {
		return err
	}
	total, err := requiredInt(root, "total")
	if err != nil || total < 0 {
		return fmt.Errorf("search total must be a non-negative integer")
	}
	limit, err := requiredInt(root, "limit")
	if err != nil || limit != 20 {
		return fmt.Errorf("unsupported search result limit")
	}
	items, err := requiredArray(root, "results")
	if err != nil {
		return err
	}
	if len(items) > limit || len(items) > total || (root["error"] != nil && (total != 0 || len(items) != 0)) {
		return fmt.Errorf("inconsistent search result count")
	}
	for index, raw := range items {
		item, err := valueObject(raw, fmt.Sprintf("results[%d]", index))
		if err != nil {
			return err
		}
		for _, field := range []string{"id", "name", "module", "kind", "signature", "doc", "structural_status"} {
			if _, err := requiredString(item, field); err != nil {
				return err
			}
		}
		if err := searchNullableString(item, "import"); err != nil {
			return err
		}
		requirements, err := valueObject(item["requirements"], "requirements")
		if err != nil {
			return err
		}
		caps, err := requiredArray(requirements, "capabilities")
		if err != nil {
			return err
		}
		for _, cap := range caps {
			if _, ok := cap.(string); !ok {
				return fmt.Errorf("search capability must be a string")
			}
		}
		if requirements["capabilities_status"] != "known-direct" && requirements["capabilities_status"] != "unavailable" {
			return fmt.Errorf("unsupported search capabilities_status")
		}
		if requirements["proofs_status"] != "unavailable" || requirements["additional_requirements_status"] != "unavailable" {
			return fmt.Errorf("unsupported search proof or additional requirements metadata")
		}
		if item["structural_status"] != "checker-scheme" && item["structural_status"] != "text-only" && item["structural_status"] != "incomplete-scheme" {
			return fmt.Errorf("unsupported search structural_status")
		}
	}
	return nil
}

func searchNullableString(value map[string]any, field string) error {
	raw, exists := value[field]
	if !exists {
		return fmt.Errorf("missing search field %q", field)
	}
	if raw != nil {
		if _, ok := raw.(string); !ok {
			return fmt.Errorf("search field %q must be a string or null", field)
		}
	}
	return nil
}
