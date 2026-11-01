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
		guide.Summary += " The compiler has not proposed a source template for this case."
		return guide
	}
	guide.Title = "Choose how to migrate " + decision.Entity
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
			"Examples are source templates, not applied edits or evidence that a transition is supported. Keep placeholders unresolved until you have supplied the intended behavior and the compiler accepts it.",
			"This command prepares source only. Test conversion and mixed old/new writers, review the plan, then build and deploy the migration worker before routing new requests. Contract retires old versions before removing retained storage.",
		},
	}
	switch code {
	case "MIG001":
		guide.Title = "Refresh an undeployed current revision"
		guide.Summary = "Editing VCurrent changes its recorded hash. Refresh only if this revision has not been deployed."
		guide.Options = []Option{
			{ID: "refresh-current", Title: "Continue the undeployed revision", When: "You are intentionally editing this still-undeployed revision; save your schema and refresh its generated source."},
			{ID: "restore-deployed", Title: "Restore deployed source, then start a forward revision", When: "This revision was already deployed, or you cannot establish that it is undeployed."},
		}
		guide.Help = append(guide.Help, "The compiler cannot determine deployment state. A changed hash is not permission to reseal deployed history; frozen schema and completed migration errors remain blocking.")
	case "MIG013":
		guide.Title = "Restore the recorded history"
		guide.Summary = "Frozen source or history metadata changed. Preserve the recorded bytes and create a forward revision."
		guide.Help = append(guide.Help, "Do not dismiss this as a normal draft edit or replace recorded hashes manually. Restore frozen schemas, private helpers and completed migrations from the deployed source.")
	case "MIG024":
		guide.Title = "Same no longer proves identity"
		guide.Summary = "Same requires an equal complete semantic closure, including facts, checks, establish functions, helpers and codecs."
		guide.Options = []Option{
			{ID: "restore-identity", Title: "Keep the old behavior", When: "The dependency change was unintended; restore it, then let the compiler verify Same again."},
			{ID: "explicit-transition", Title: "Write an explicit checked transition", When: "The stored meaning intentionally changed; remove the invalid Same and choose the appropriate migration rules.", RequiresCustomCode: true},
		}
		guide.Help = append(guide.Help, proofHelp()...)
	case "MIG003":
		guide.Title = "Choose how to populate existing rows"
		guide.Summary = "A generated todo marks an unresolved decision; generation does not fabricate a value or a proof."
		if strings.Contains(message, "stored proof contract changed") {
			guide.Title = "Migrate a changed historical proof"
			guide.Summary = "Changing an existing proof requires preserving an old-valid representation while old versions may write."
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
		"For a changed existing primitive field proof, use Migrate with Retype and WriteBack. The reverse callback returns the exact historical field type and proof. Cross-field entity predicates are unsupported for these scalar reverse callbacks.",
		"Stronger proofs may reject old rows; repair them before Contract. Weaker proofs may permit values old writers cannot represent. An old-valid reverse value is not necessarily lossless: an unrelated old update can invalidate the new row representation. Retire old writers before permitting such values when exact retention is required.",
	}
}
