package migrationtest

import "maps"

// BootstrapSnapshot is an independent catalog oracle. Object identities are
// atomic catalog properties (a table, column/type/default, or constraint), not
// generated SQL text. These fixtures cover initial install and additive expand.
type BootstrapSnapshot struct {
	Hash    string
	Objects map[string]string
}

type BootstrapModel struct {
	Holder     string
	Installing int
	Catalog    map[string]string
	Snapshots  map[int]BootstrapSnapshot
	History    *Model // nil until the initial expansion commits
}

func cloneBootstrapSnapshots(snapshots map[int]BootstrapSnapshot) map[int]BootstrapSnapshot {
	copy := maps.Clone(snapshots)
	for version, snapshot := range copy {
		snapshot.Objects = maps.Clone(snapshot.Objects)
		copy[version] = snapshot
	}
	return copy
}

func NewBootstrapModel(snapshots map[int]BootstrapSnapshot) *BootstrapModel {
	return &BootstrapModel{Catalog: map[string]string{}, Snapshots: cloneBootstrapSnapshots(snapshots)}
}

func (m *BootstrapModel) Clone() *BootstrapModel {
	n := *m
	n.Catalog = maps.Clone(m.Catalog)
	n.Snapshots = cloneBootstrapSnapshots(m.Snapshots)
	if m.History != nil {
		n.History = m.History.Clone()
	}
	return &n
}

func (m *BootstrapModel) Apply(op Op) error {
	n := m.Clone()
	if err := n.apply(op); err != nil {
		return err
	}
	if err := n.Check(); err != nil {
		return err
	}
	*m = *n
	return nil
}

func (m *BootstrapModel) apply(op Op) error {
	switch op.Kind {
	case "boot-lock":
		if op.Holder == "" || m.Holder != "" {
			return refuse("INV-BOOT-LOCK: another backend holds the non-expiring boot lock")
		}
		m.Holder = op.Holder
		return nil
	case "boot-crash":
		if m.Holder == "" || m.Holder != op.Holder {
			return refuse("INV-BOOT-LOCK: unknown boot backend")
		}
		m.Holder = ""
		return nil
	}
	if op.Holder == "" || m.Holder != op.Holder {
		return refuse("INV-BOOT-LOCK: catalog work requires the owning backend's boot lock")
	}
	switch op.Kind {
	case "boot-release":
		m.Holder = ""
	case "install-select":
		if m.History != nil || m.Snapshots[op.Version].Hash == "" {
			return refuse("INV-INSTALL-TARGET: initial target requires an uninstalled database and an embedded snapshot")
		}
		if m.Installing == 0 {
			m.Installing = op.Version
		}
		// A successor observes the persisted target; its own newer version
		// does not replace it merely because the previous backend died.
	case "install-object":
		target := m.Installing
		if m.History != nil {
			target = m.History.Expanded + 1
		}
		definition := m.Snapshots[target].Objects[op.ID]
		if target == 0 || op.Version != target || definition == "" || definition != op.Hash {
			return refuse("INV-INSTALL-TARGET: catalog work does not belong to the selected snapshot")
		}
		if previous := m.Catalog[op.ID]; previous != "" && previous != definition {
			return refuse("INV-INSTALL-CATALOG: existing object differs from its expected definition")
		}
		m.Catalog[op.ID] = definition
	case "install-record", "boot-expand":
		if m.History != nil && op.Version == m.History.Expanded {
			if op.Kind == "install-record" && op.Version != m.History.Base {
				return refuse("INV-INSTALL-ATOMIC: an expansion cannot be retried as an initial install")
			}
			return m.History.Apply(Op{Kind: "expand", Version: op.Version, Hash: op.Hash, Additive: true})
		}
		target := m.Installing
		if op.Kind == "boot-expand" && m.History != nil {
			target = m.History.Expanded + 1
		} else if op.Kind != "install-record" || m.History != nil {
			return refuse("INV-INSTALL-ATOMIC: initial install and subsequent expand are different edges")
		}
		snapshot := m.Snapshots[target]
		if target == 0 || target != op.Version || snapshot.Hash == "" || snapshot.Hash != op.Hash {
			return refuse("INV-INSTALL-TARGET: wrong version or artefact for the selected install")
		}
		for object, definition := range snapshot.Objects {
			if m.Catalog[object] != definition {
				return refuse("INV-INSTALL-CATALOG: catalog verification must finish before recording expansion")
			}
		}
		if m.History == nil {
			m.History = NewModel(target, snapshot.Hash)
			m.Installing = 0
		} else if err := m.History.Apply(Op{Kind: "expand", Version: target, Hash: snapshot.Hash, Additive: true}); err != nil {
			return err
		}
	default:
		return refuse("unknown bootstrap model operation")
	}
	return nil
}

func (m *BootstrapModel) Check() error {
	if len(m.Snapshots) == 0 {
		return refuse("INV-INSTALL-TARGET: no embedded catalog snapshots")
	}
	for version, snapshot := range m.Snapshots {
		if version < 1 || version >= 2147483647 || snapshot.Hash == "" {
			return refuse("INV-INSTALL-TARGET: invalid embedded snapshot identity")
		}
		for object, definition := range snapshot.Objects {
			if object == "" || definition == "" {
				return refuse("INV-INSTALL-CATALOG: incomplete catalog definition")
			}
		}
	}
	current, pending := m.Installing, m.Installing
	if m.History != nil {
		if m.Installing != 0 {
			return refuse("INV-INSTALL-ATOMIC: installed history still has an initial target")
		}
		if err := m.History.Check(); err != nil {
			return err
		}
		current, pending = m.History.Expanded, m.History.Expanded+1
		for version, hash := range m.History.Hashes {
			if m.Snapshots[version].Hash != hash {
				return refuse("INV-INSTALL-ATOMIC: recorded history differs from embedded snapshots")
			}
		}
		for object, definition := range m.Snapshots[current].Objects {
			if m.Catalog[object] != definition {
				return refuse("INV-INSTALL-CATALOG: installed version has an incomplete catalog")
			}
		}
	} else if m.Installing != 0 && m.Snapshots[m.Installing].Hash == "" {
		return refuse("INV-INSTALL-TARGET: persisted target has no embedded snapshot")
	}
	for object, definition := range m.Catalog {
		if definition == "" || (m.Snapshots[current].Objects[object] != definition && m.Snapshots[pending].Objects[object] != definition) {
			return refuse("INV-INSTALL-CATALOG: catalog contains work from an unselected version")
		}
	}
	return nil
}
