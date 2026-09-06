package tooling

import (
	"errors"
	"fmt"
	"net/url"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

// DiagnosticQueryVersion selects the rich endpoint for clients shipped with this
// toolchain. A custom older compiler reports an explicit unsupported endpoint;
// malformed rich responses never silently fall back to weaker metadata.
func (Client) DiagnosticQueryVersion() int { return 2 }

func validateDiagnosticMetadata(value map[string]any) error {
	related, err := requiredArray(value, "relatedInformation")
	if err != nil {
		return err
	}
	for i, raw := range related {
		item, err := valueObject(raw, fmt.Sprintf("relatedInformation[%d]", i))
		if err != nil {
			return err
		}
		for _, name := range []string{"file", "message"} {
			if _, err := requiredNonEmptyString(item, name); err != nil {
				return err
			}
		}
		start, err := requiredPosition(item, "start")
		if err != nil {
			return err
		}
		end, err := requiredPosition(item, "end")
		if err != nil {
			return err
		}
		if end[0] < start[0] || end[0] == start[0] && end[1] < start[1] {
			return errors.New("related diagnostic has an inverted range")
		}
	}
	class, present := value["actionClass"]
	if !present || class != nil && class != "mechanical" && class != "suggested" && class != "decision" {
		return errors.New("diagnostic requires a valid actionClass")
	}
	confirmation, ok := value["needsConfirmation"].(bool)
	if !ok {
		return errors.New("diagnostic requires needsConfirmation")
	}
	eligible, ok := value["fixAllEligible"].(bool)
	if !ok {
		return errors.New("diagnostic requires fixAllEligible")
	}
	command, present := value["command"]
	if !present {
		return errors.New("diagnostic requires command")
	}
	if class == "decision" && !confirmation || class == nil && (confirmation || eligible || command != nil) {
		return errors.New("diagnostic action and confirmation metadata disagree")
	}
	if eligible && (class != "mechanical" || confirmation || command != nil || value["fix"] == nil) {
		return errors.New("fix-all requires an unconfirmed mechanical source fix without a command")
	}
	if command != nil {
		if err := validateDiagnosticCommand(command); err != nil {
			return err
		}
	}
	description, present := value["codeDescription"]
	if !present {
		return errors.New("diagnostic requires codeDescription")
	}
	if description != nil {
		object, err := valueObject(description, "codeDescription")
		if err != nil {
			return err
		}
		href, err := requiredNonEmptyString(object, "href")
		if err != nil {
			return err
		}
		parsed, err := url.Parse(href)
		if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil {
			return errors.New("diagnostic documentation must be an absolute HTTPS URL")
		}
	}
	return nil
}

func validateDiagnosticCommand(raw any) error {
	command, err := valueObject(raw, "diagnostic command")
	if err != nil {
		return err
	}
	if _, err := requiredNonEmptyString(command, "title"); err != nil {
		return err
	}
	if name, err := requiredString(command, "command"); err != nil || name != "tesl.generateMigration" {
		return errors.New("unsupported diagnostic command")
	}
	args, err := requiredArray(command, "arguments")
	if err != nil || len(args) != 1 {
		return errors.New("migration diagnostic command requires one selection argument")
	}
	selection, err := valueObject(args[0], "migration selection")
	if err != nil {
		return err
	}
	for key, raw := range selection {
		text, ok := raw.(string)
		if !ok || text == "" || !utf8.ValidString(text) || strings.ContainsRune(text, 0) || key != "entryFile" && key != "database" {
			return errors.New("invalid migration diagnostic selection")
		}
	}
	entry, err := requiredNonEmptyString(selection, "entryFile")
	if err != nil || !filepath.IsAbs(entry) || filepath.Clean(entry) != entry || !strings.EqualFold(filepath.Ext(entry), ".tesl") {
		return errors.New("migration diagnostic selection requires a canonical absolute Tesl entry")
	}
	return nil
}
