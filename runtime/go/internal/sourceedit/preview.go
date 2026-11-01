package sourceedit

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
)

// Preview is the successful, versioned compiler response. Its compilable flag is
// separate from success: generation deliberately writes typed decision holes.
// Decoding never turns a compiler error or an unknown protocol into a write.
type Preview struct {
	manifest                       *Manifest
	compilable                     bool
	compilerABI                    string
	canonical                      []byte
	entryFile, database, operation string
}

func (p *Preview) Manifest() *Manifest { return p.manifest }
func (p *Preview) Compilable() bool    { return p.compilable }
func (p *Preview) CompilerABI() string { return p.compilerABI }
func (p *Preview) JSON() []byte        { return bytes.Clone(p.canonical) }
func (p *Preview) EntryFile() string   { return p.entryFile }
func (p *Preview) Database() string    { return p.database }
func (p *Preview) Operation() string   { return p.operation }

func DecodePreview(data []byte) (*Preview, error) {
	if err := strictJSON(data); err != nil {
		return nil, err
	}
	keys := []string{"version", "kind", "ok", "operation", "compilerAbi", "compilable", "selection", "diagnostics", "manifest"}
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(data, &envelope); err != nil {
		return nil, err
	}
	// Older compilers have no advisory decisions. A new compiler may add this
	// exact field; it never changes manifest validation or compilability.
	if decisions, present := envelope["decisions"]; present {
		keys = append(keys, "decisions")
		if err := validatePreviewDecisions(decisions); err != nil {
			return nil, err
		}
	}
	fields, err := object(data, keys...)
	if err != nil {
		return nil, err
	}
	var header struct {
		Version     int    `json:"version"`
		Kind        string `json:"kind"`
		OK          *bool  `json:"ok"`
		Operation   string `json:"operation"`
		CompilerABI string `json:"compilerAbi"`
		Compilable  *bool  `json:"compilable"`
		Selection   struct {
			EntryFile string `json:"entryFile"`
			Database  string `json:"database"`
		} `json:"selection"`
	}
	if err := json.Unmarshal(data, &header); err != nil {
		return nil, err
	}
	const prefix = "tesl-source-abi-v1:"
	if header.Version != 1 || header.Kind != "migration-source-preview" || header.OK == nil || !*header.OK || header.Compilable == nil || (header.Operation != "start" && header.Operation != "refresh" && header.Operation != "contract") || !strings.HasPrefix(header.CompilerABI, prefix) || len(header.CompilerABI) != len(prefix)+64 || !validHex(strings.TrimPrefix(header.CompilerABI, prefix)) {
		return nil, fmt.Errorf("compiler did not return a successful supported migration source preview")
	}
	if _, err := object(fields["selection"], "entryFile", "databaseFile", "database", "family", "schemaRoot", "previousVersion", "revisionBefore", "revisionAfter"); err != nil {
		return nil, err
	}
	if header.Selection.EntryFile == "" || header.Selection.Database == "" {
		return nil, fmt.Errorf("missing migration preview selection")
	}
	if _, err := object(fields["diagnostics"], "version", "diagnostics"); err != nil {
		return nil, err
	}
	var diagnostics struct {
		Version     int `json:"version"`
		Diagnostics []struct {
			Severity string `json:"severity"`
		} `json:"diagnostics"`
	}
	if err := json.Unmarshal(fields["diagnostics"], &diagnostics); err != nil {
		return nil, err
	}
	if diagnostics.Version != 1 || diagnostics.Diagnostics == nil {
		return nil, fmt.Errorf("missing compiler diagnostics")
	}
	compilable := true
	for _, d := range diagnostics.Diagnostics {
		switch d.Severity {
		case "error":
			compilable = false
		case "warning":
		default:
			return nil, fmt.Errorf("unsupported compiler diagnostic severity")
		}
	}
	if compilable != *header.Compilable {
		return nil, fmt.Errorf("compiler diagnostics disagree with proposal compilability")
	}
	m, err := Decode(fields["manifest"])
	if err != nil {
		return nil, err
	}
	return &Preview{manifest: m, compilable: compilable, compilerABI: header.CompilerABI, canonical: bytes.Clone(data),
		entryFile: header.Selection.EntryFile, database: header.Selection.Database, operation: header.Operation}, nil
}

func validatePreviewDecisions(raw json.RawMessage) error {
	if err := arrayObjects(raw, "id", "entity", "file", "line", "col", "reason", "options"); err != nil {
		return fmt.Errorf("invalid compiler decisions: %w", err)
	}
	var decisions []struct {
		ID, Entity, File, Reason *string
		Line, Col                *int
		Options                  json.RawMessage
	}
	if err := json.Unmarshal(raw, &decisions); err != nil {
		return err
	}
	for _, d := range decisions {
		if d.ID == nil || *d.ID == "" || d.Entity == nil || *d.Entity == "" || d.File == nil || *d.File == "" ||
			d.Reason == nil || d.Line == nil || *d.Line < 0 || d.Col == nil || *d.Col < 0 {
			return fmt.Errorf("invalid compiler decision location or identity")
		}
		if err := arrayObjects(d.Options, "id", "label", "template", "help", "needsCustomCode"); err != nil {
			return fmt.Errorf("invalid compiler decision options: %w", err)
		}
		var options []struct {
			ID, Label, Template, Help *string
			NeedsCustomCode           *bool
		}
		if err := json.Unmarshal(d.Options, &options); err != nil {
			return err
		}
		for _, o := range options {
			if o.ID == nil || *o.ID == "" || o.Label == nil || o.Template == nil || o.Help == nil || o.NeedsCustomCode == nil {
				return fmt.Errorf("invalid compiler decision option")
			}
		}
	}
	return nil
}
