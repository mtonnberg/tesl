// Package migrationguide describes source-authoring choices for humans and AI
// clients. Its examples are advisory: only the compiler can validate a choice
// or produce a guarded source edit.
package migrationguide

import (
	"regexp"
	"strings"
)

type Option struct {
	ID                 string `json:"id"`
	Title              string `json:"title"`
	When               string `json:"when"`
	Example            string `json:"example,omitempty"`
	RequiresCustomCode bool   `json:"requiresCustomCode"`
}

type Guide struct {
	Title   string   `json:"title"`
	Summary string   `json:"summary"`
	Options []Option `json:"options"`
	Help    []string `json:"help"`
}

// Decision is supplied by the compiler preview. Consumers can describe these
// proposals, but a proposal with custom-code holes still requires compilation.
type Decision struct {
	ID      string           `json:"id"`
	Entity  string           `json:"entity"`
	File    string           `json:"file"`
	Line    int              `json:"line"`
	Col     int              `json:"col"`
	Reason  string           `json:"reason"`
	Options []DecisionOption `json:"options"`
}

type DecisionOption struct {
	ID              string `json:"id"`
	Label           string `json:"label"`
	Template        string `json:"template"`
	Help            string `json:"help"`
	NeedsCustomCode bool   `json:"needsCustomCode"`
}

// ForDecision prefers compiler-produced choices to diagnostic-text heuristics.
// Keeping fallback help also explains boundaries for currently unsupported
// choices, without turning those explanations into a selectable edit.
func ForDecision(decision Decision) Guide {
	guide := ForDiagnostic("MIG003", decision.Reason)
	if len(decision.Options) == 0 {
		guide.Options = []Option{}
		guide.Title = "Adjust this schema change"
		guide.Summary = decision.Reason + " The compiler has not proposed a source template for this case."
		guide.Help = []string{"Return to the schema step and address the stated constraint. An unsupported transition cannot be made safe by filling the placeholder with arbitrary migration rules. Keep frozen history unchanged."}
		return guide
	}
	guide.Title = "Choose how to migrate " + decision.Entity
	if strings.Contains(decision.Reason, "stored proof contract changed") || strings.Contains(decision.Reason, "a first proof was added to") || strings.Contains(decision.Reason, " was removed; choose what old binaries receive") {
		guide.Summary = decision.Reason + "\n\n" + guide.Summary
	} else {
		guide.Summary = decision.Reason
	}
	for _, option := range decision.Options {
		if option.ID == "map-fields" || strings.HasPrefix(option.ID, "rename:") || option.ID == "rename-all" {
			guide.Help = []string{"Choose explicit field identity mappings; matching types alone do not prove a rename. New fields and old-version writes for removed fields require your values or expressions.", "Record and ADT adapters rebuild exact target types through their constructors and codecs. Removed/new variants need a domain mapping; failed forward conversions reject the row. Review historical compatibility values and test both directions before retiring old writers."}
		}
		if option.ID == "map-queued-payload" || option.ID == "remove-empty-queue" {
			guide.Title = "Review " + decision.Entity
			guide.Help = []string{"Queued payload conversions use a generated pure helper module and historical fixtures. They use exact old/new payload types and codecs; rejected jobs are retained rather than discarded.", "Keep row changes and queue payload changes in separate revisions. Empty-queue retirement is a runtime-checked operation, not permission to discard queued data."}
		}
		if option.ID == "require-value" {
			guide.Title = "Choose a value for missing data"
			guide.Summary = decision.Reason
			guide.Help = []string{
				"Existing Something values are kept. Replace the missing-value placeholder with a value or an expression using the old row.",
				"The reverse function writes Something for new-version values so the old application can still read them. Fill valid historical example inputs for the generated fixture and recheck.",
			}
		}
	}
	guide.Options = make([]Option, 0, len(decision.Options))
	for _, option := range decision.Options {
		guide.Options = append(guide.Options, Option{
			ID: option.ID, Title: option.Label, When: option.Help,
			Example: option.Template, RequiresCustomCode: option.NeedsCustomCode,
		})
	}
	guide.Help = append(guide.Help, "The compiler proposed these templates after checking their structural route. Custom-code holes remain blocking; save the completed choice and recheck the whole application.")
	return guide
}

var additiveField = regexp.MustCompile(`(?:^|[ :])(?:[A-Za-z_][A-Za-z0-9_]*\.)+([A-Za-z_][A-Za-z0-9_]*): no additive value source`)

// ForDiagnostic uses stable diagnostic codes and known explanatory detail to
// select help, never to decide whether a migration is safe. Unknown details
// retain the general guide rather than inventing an applicable source repair.
func ForDiagnostic(code, message string) Guide {
	guide := Guide{
		Title:   "Review the migration source",
		Summary: "Choose the stored-data behavior explicitly, then save and recheck the whole application.",
		Options: []Option{},
		Help: []string{
			"Generation fills compiler-proven New, Drop and proof-free Additive entries. It preserves handwritten decisions and leaves todo where your intent or custom code is required.",
			"Examples alone do not change source or prove that a transition is supported. Selecting a compiler-proposed option applies its guarded scaffold; custom-code holes remain blocking until you supply the intended behavior and recheck.",
			"This command prepares source only. Test conversion and mixed old/new writers, review the plan, then build and deploy the migration worker before routing new requests. Contract retires old versions before removing retained storage.",
		},
	}
	if message != "" {
		guide.Summary = message
	}
	switch code {
	case "MIG001":
		guide.Title = "Keep these schema edits as a revision"
		guide.Summary = "Editing VCurrent changes its recorded hash. Run tesl migrate to start the next revision with these edits; fold them into the latest revision only if it has not been deployed."
		guide.Options = []Option{
			{ID: "start-next", Title: "Start the next revision with these edits", When: "The normal path: tesl migrate keeps your edits, restores the recorded source, starts the next revision and reapplies them."},
			{ID: "refresh-current", Title: "Continue the undeployed revision", When: "You are intentionally editing this still-undeployed revision; save your schema and refresh its generated source (tesl migrate --resume)."},
		}
		guide.Help = append(guide.Help, "The compiler cannot determine deployment state. A changed hash is not permission to reseal deployed history; frozen schema and completed migration errors remain blocking.")
	case "MIG013":
		guide.Title = "Restore the recorded history"
		guide.Summary = "Frozen source or history metadata changed. Preserve the recorded bytes and create a forward revision."
		guide.Help = append(guide.Help, "Do not dismiss this as a normal draft edit or replace recorded hashes manually. Restore frozen schemas, private helpers and completed migrations from the deployed source.")
	case "MIG024":
		guide.Title = "Same no longer proves identity"
		guide.Summary = "Same requires unchanged meaning, including the reached checks, establish functions, helpers and codecs. Old values passing a new check is not enough.\n\nIf your new check is more permissive, use a changed-proof conversion, not Same or same-column Revalidate. Old values may all pass forwards, but newly allowed values can fail the old check. While old versions can still write, the reverse conversion must supply an old-valid value."
		guide.Options = []Option{
			{ID: "restore-identity", Title: "Keep the old behavior", When: "The dependency change was unintended; restore it, then let the compiler verify Same again."},
			{ID: "explicit-transition", Title: "Write an explicit checked transition", When: "The stored meaning intentionally changed; remove the invalid Same and choose the appropriate migration rules.", RequiresCustomCode: true},
		}
		guide.Help = append(guide.Help, proofHelp()...)
	case "MIG003":
		guide.Title = "Choose how to populate existing rows"
		guide.Summary = "A generated todo marks an unresolved decision; generation does not fabricate a value or a proof."
		if strings.HasPrefix(message, "Fill this placeholder: ") {
			guide.Title = "Fill this placeholder: choose a policy"
			guide.Summary = strings.TrimPrefix(message, "Fill this placeholder: ")
			guide.Help = []string{"The scaffold is written; only this decision remains. Replace the todo with Reject \"reason\" (the row is refused and kept in the old storage) or with a reviewed Row value, then recheck."}
		} else if strings.HasPrefix(message, "Migration needs a value: ") {
			guide.Title = "Fill this migration value"
			guide.Summary = strings.TrimPrefix(message, "Migration needs a value: ")
			guide.Help = []string{"Replace the selected placeholder with a value or expression of the requested type, then recheck. Historical examples exercise the migration using the previous schema's constructor and validation."}
		} else if strings.Contains(message, "Choose a literal of type ") {
			guide.Title = "Complete the selected literal default"
			guide.Summary = "The scaffold is written. Replace this todo with a literal of the compiler's named type, then save and recheck."
			guide.Help = append(guide.Help, "This is the custom value for the default route you already selected. Keep its generated Default rule and replace only the value hole. Choose the value for existing rows deliberately; Same or Revalidate cannot supply that missing value.")
		} else if strings.Contains(message, "a first proof was added to") {
			guide.Title = "Check existing rows against the new proof"
			guide.Summary = "Existing rows were stored without this check. Revalidate runs the validator on each stored value: rows that pass gain the proof, rows that fail are rejected and stay in the old storage until you repair them. Old versions keep writing unchecked values during the overlap, so the same validator also guards those writes."
			guide.Options = []Option{{ID: "revalidate", Title: "Revalidate with the exported validator", When: "Choose the compiler's revalidate plan when it is offered; it reuses the establish function for this proof.", Example: "Migrate convert [Revalidate field CurrentSchema.tryField]", RequiresCustomCode: true}}
			guide.Help = append(guide.Help, proofHelp()...)
		} else if strings.Contains(message, " was removed; choose what old binaries receive") {
			guide.Title = "Old versions still require the removed proof"
			guide.Summary = "New values may no longer satisfy the proof that old versions expect. While old versions run, the historical write-back must return a value that passes the old proof, or Nothing to refuse that write."
			guide.Help = append(guide.Help, proofHelp()...)
		} else if strings.Contains(message, "stored proof contract changed") {
			guide.Title = "Migrate a changed historical proof"
			guide.Summary = "Changing an existing proof requires preserving an old-valid representation while old versions may write. This also applies when the new check is more permissive and every old value passes: newly allowed values may fail the old check in the reverse direction.\n\nChoose the validator-reuse plan if offered, or the custom conversion plan. Supply an old-valid fallback policy, or keep new writes within the old rule until old writers are retired. Neither Same nor same-column Revalidate replaces this changed proof."
			guide.Options = []Option{{ID: "retype-proof", Title: "Retype with a checked reverse function", When: "Use Migrate with Retype and WriteBack; the reverse function must return the exact historical type and proof.", Example: "Migrate convert [Retype field, WriteBack field field reverseFn]", RequiresCustomCode: true}}
			guide.Help = append(guide.Help, proofHelp()...)
		} else if match := additiveField.FindStringSubmatch(message); len(match) == 2 {
			field := match[1]
			guide.Title = "Choose a value for " + field
			guide.Options = []Option{
				{ID: "default", Title: "Use one literal default", When: "Every existing row should receive the same supported primitive literal; the new field must be non-optional and proof-free.", Example: "Additive [Default " + field + ` (todo "Choose the literal value for existing rows")]`, RequiresCustomCode: true},
				{ID: "row-transform", Title: "Compute the value from each old row", When: "The value depends on old data or requires validation; write a pure conversion returning Row or Reject.", Example: "Migrate convert []\n# Implement convert: old row -> Migrated current row.\n# Preserve unchanged fields and fill " + field + " from the intended custom code.", RequiresCustomCode: true},
			}
			guide.Help = append(guide.Help, "A Default cannot invent a nominal value or a proof. For those fields, use a supported typed conversion. The todo in the template deliberately prevents treating an example default as real data.")
			guide.Help = append(guide.Help, "If the new value depends on old data, write a pure Migrate conversion returning Row or Reject instead of choosing a constant default. No automatic row-mapping template is proposed here; the compiler must check the completed conversion and its compatibility rules.")
		} else {
			guide.Options = migrationOptions()
			guide.Help = append(guide.Help, proofHelp()...)
		}
	case "MIG016":
		guide.Title = "Choose identity or stored-value revalidation"
		guide.Summary = "Each reached stored type, fact and codec needs exact Same evidence or an explicit supported migration."
		guide.Options = migrationOptions()
		guide.Help = append(guide.Help, proofHelp()...)
	case "MIG022", "MIG023":
		guide.Title = "Correct the field rules"
		guide.Summary = "Rules must name the right fields, satisfy their exact contextual types, and avoid conflicting value sources."
		guide.Help = append(guide.Help, "Default is for a new non-optional proof-free primitive field. Rename preserves the exact old value. Retype selects new storage, WriteBack supplies the exact old representation, and Legacy/LegacyWith retain removed old fields during overlap.")
	case "MIG031":
		guide.Title = "Review the cost of this update"
		guide.Summary = "During a transformation window, this update locks and converts every matched row."
		guide.Help = append(guide.Help, "A primary-key equality bounds the match to one row. A broad predicate can be expensive even though client batches are bounded; measure the expected row count and mixed-version latency before deployment. Do not change the predicate merely to silence the warning.")
	}
	return guide
}

func migrationOptions() []Option {
	return []Option{
		{ID: "same", Title: "Retain compiler-verified Same", When: "The complete stored meaning is unchanged. Matching names, SQL types or function signatures alone are insufficient.", Example: "Same PreviousSchema.Valid CurrentSchema.Valid"},
		{ID: "revalidate", Title: "Revalidate a supported new proof", When: "Add a first field-local proof, or a field-local conjunction retaining every historical proof through exact Same. This cannot replace changed historical proof semantics.", Example: "Migrate convert [Revalidate field CurrentSchema.tryField]", RequiresCustomCode: true},
		{ID: "transform", Title: "Write a supported typed transformation", When: "The value, type, codec or historical proof changes; choose explicit storage and compatibility rules.", Example: "Migrate convert [Retype field, WriteBack field field reverseFn]", RequiresCustomCode: true},
	}
}

func proofHelp() []string {
	return []string{
		"A changed check, establish function, private helper or codec can change stored meaning without changing a field's visible type. Same must not conceal that change; use the compiler's differing-dependency diagnostic.",
		"Revalidate supports a first proof or a supported field-local conjunction that preserves every historical proof through exact Same. It does not replace changed historical evidence. Removing a valid Same intentionally requests revalidation; refresh does not put it back.",
		"For a changed existing field proof, use Migrate with Retype and WriteBack. The reverse callback returns the exact historical field type and proof, or Maybe of that type. Something supplies the old representation; Nothing refuses the entire application write while old columns remain. During backfill, the exact original old projection can be retained instead. Cross-field entity predicates are unsupported for these field reverse callbacks.",
		"Stronger proofs may reject old rows; repair them before Contract. Weaker proofs may permit values old writers cannot represent. An old-valid reverse value is not necessarily lossless: an unrelated old update can invalidate the new row representation. Retire old writers before permitting such values when exact retention is required.",
		"Example: increasing a title limit from 120 to 200 accepts every previously valid title. A new 150-character title still fails the old 120-character check. Choose a reviewed old-valid representation for that reverse write, or wait until old writers are retired before accepting titles longer than 120. The compiler does not treat one-way acceptance as Same, and does not guess a truncation or fallback value.",
	}
}
