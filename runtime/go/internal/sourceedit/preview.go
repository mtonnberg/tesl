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
	fields, err := object(data, "version", "kind", "ok", "operation", "compilerAbi", "compilable", "selection", "diagnostics", "manifest")
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
	if header.Version != 1 || header.Kind != "migration-source-preview" || header.OK == nil || !*header.OK || header.Compilable == nil || (header.Operation != "start" && header.Operation != "refresh") || !strings.HasPrefix(header.CompilerABI, prefix) || len(header.CompilerABI) != len(prefix)+64 || !validHex(strings.TrimPrefix(header.CompilerABI, prefix)) {
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
