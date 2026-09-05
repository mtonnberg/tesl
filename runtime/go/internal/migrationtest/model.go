package migrationtest

import (
	"errors"
	"fmt"
	"maps"
	"math"
	"slices"
)

// Model is an independent, deliberately small oracle. It contains no SQL and
// imports no runtime implementation. A rejected operation leaves state intact.
// Time and process death advance only through explicit operations.
type Model struct {
	Base                    int
	Floor, Compat, Expanded int
	Epoch                   bool
	Versions                map[int]string
	Hashes                  map[int]string
	EpochPreserving         map[int]bool
	Writers                 map[string]int
	RetiringThrough         int
	Rows                    map[string]Row
	Jobs                    map[string]Job
	Leases                  map[string]Lease
	Processing              map[string]ProcessingABI
	ExecutorABI             map[int]string
	ABILocked               map[int]bool
	Repairs                 map[int][]string
	Indexes                 map[string]IndexJob
	Quarantine              map[string]QuarantineRow
	Clock                   int64
}

type Row struct {
	Generation, Target int
	Rejected           bool
	Version, Repair    int
	Revision           uint64
	Reason             string
}

type QuarantineRow struct {
	Version, Generation, Repair int
	Revision                    uint64
	Reason                      string
}
type Job struct {
	Version, Claimant int
	Attempt           uint64
	Status            string
	LeaseUntil        int64
	Quarantined       bool
}
type Lease struct {
	Holder string
	Token  uint64
	Until  int64
}

type ProcessingABI struct {
	Version     int
	Generation  int
	ABI         string
	Rows        uint64
	Provisional bool
	Written     bool // a committed application write produced this target generation
}

type Op struct {
	Kind, ID, Hash string
	Holder         string
	Version        int
	Generation     int
	Attempt        uint64
	Ticks          int64
	Additive       bool
	Sequence       int
	RepairHashes   []string
	Revision       uint64
	Accept         bool
	Reason         string
}

func NewModel(version int, hash string) *Model {
	return &Model{Base: version, Floor: version, Compat: version, Expanded: version, Epoch: true,
		Versions: map[int]string{version: "contracted"}, Hashes: map[int]string{version: hash},
		EpochPreserving: map[int]bool{version: true},
		Writers:         map[string]int{}, Rows: map[string]Row{}, Jobs: map[string]Job{}, Leases: map[string]Lease{}, Processing: map[string]ProcessingABI{}, ExecutorABI: map[int]string{}, ABILocked: map[int]bool{}, Repairs: map[int][]string{}, Indexes: map[string]IndexJob{}, Quarantine: map[string]QuarantineRow{}}
}

func (m *Model) Clone() *Model {
	n := *m
	n.Versions = maps.Clone(m.Versions)
	n.Hashes = maps.Clone(m.Hashes)
	n.EpochPreserving = maps.Clone(m.EpochPreserving)
	n.Writers = maps.Clone(m.Writers)
	n.Rows = maps.Clone(m.Rows)
	n.Jobs = maps.Clone(m.Jobs)
	n.Leases = maps.Clone(m.Leases)
	n.Processing = maps.Clone(m.Processing)
	n.ExecutorABI = maps.Clone(m.ExecutorABI)
	n.ABILocked = maps.Clone(m.ABILocked)
	n.Repairs = make(map[int][]string, len(m.Repairs))
	for v, chain := range m.Repairs {
		n.Repairs[v] = slices.Clone(chain)
	}
	n.Indexes = maps.Clone(m.Indexes)
	n.Quarantine = maps.Clone(m.Quarantine)
	for name, job := range n.Indexes {
		job.Holders = maps.Clone(job.Holders)
		n.Indexes[name] = job
	}
	return &n
}

func (m *Model) Admitted(v int) bool { return v >= m.Floor && v <= m.Expanded }

func (m *Model) Apply(op Op) error {
	n := m.Clone()
	if err := n.apply(op); err != nil {
		return err
	}
	if err := n.Check(); err != nil {
		return fmt.Errorf("operation %+v violates %w", op, err)
	}
	*m = *n
	return nil
}

func refuse(reason string) error { return errors.New(reason) }

func (m *Model) apply(op Op) error {
	switch op.Kind {
	case "expand":
		if old, ok := m.Hashes[op.Version]; ok {
			if op.Version != m.Expanded || op.Version < m.Floor {
				return refuse("INV-LIFECYCLE: an older expansion cannot be replayed after its successor")
			}
			if old != op.Hash || m.EpochPreserving[op.Version] != op.Additive {
				return refuse("INV-HISTORY: immutable version hash")
			}
			return nil
		}
		if op.Hash == "" || op.Version != m.Expanded+1 || op.Version >= 2147483647 {
			return refuse("INV-VERSION: consecutive bounded version required")
		}
		if m.RetiringThrough != 0 {
			return refuse("INV-EXPAND: retirement holds boot lock")
		}
		if !op.Additive && m.Floor != m.Expanded {
			return refuse("INV-WINDOW: close epoch before transform")
		}
		if !m.Epoch && m.Floor != m.Expanded {
			return refuse("INV-WINDOW: predecessor must be retired")
		}
		if !m.Epoch && m.Versions[m.Expanded] != "contracted" {
			return refuse("INV-CONTRACT: prior physical work incomplete")
		}
		m.Expanded = op.Version
		m.Hashes[op.Version] = op.Hash
		m.EpochPreserving[op.Version] = op.Additive
		m.Versions[op.Version] = "expanded"
		m.Epoch = m.Epoch && op.Additive
	case "write-begin":
		if !m.Admitted(op.Version) || op.Version <= m.RetiringThrough {
			return refuse("INV-FENCE: writer refused")
		}
		if _, ok := m.Writers[op.ID]; ok {
			return refuse("duplicate writer")
		}
		m.Writers[op.ID] = op.Version
	case "write-end":
		if _, ok := m.Writers[op.ID]; !ok {
			return refuse("missing writer")
		}
		delete(m.Writers, op.ID)
	case "read-deliver":
		if !m.Admitted(op.Version) {
			return refuse("INV-READ: retired reader cannot deliver")
		}
	case "retire-begin":
		if op.Version <= m.Floor || op.Version > m.Expanded || m.RetiringThrough != 0 {
			return refuse("INV-FLOOR: invalid target")
		}
		for _, v := range m.Writers {
			if v < op.Version {
				return refuse("INV-FENCE: old writer still holds fence")
			}
		}
		m.RetiringThrough = op.Version - 1
	case "retire-commit":
		if m.RetiringThrough != op.Version-1 || op.Version <= m.Floor {
			return refuse("INV-FENCE: exclusive fences missing")
		}
		for _, r := range m.Rows {
			if r.Rejected || r.Generation != r.Target {
				return refuse("INV-FINAL: row unfinished")
			}
		}
		for _, j := range m.Jobs {
			if j.Version < op.Version && !j.Quarantined {
				return refuse("INV-QUEUE-FLOOR: old job survives")
			}
		}
		m.Floor = op.Version
		m.RetiringThrough = 0
	case "contract-begin":
		if op.Version > m.Floor || m.Versions[op.Version] != "expanded" {
			return refuse("INV-CONTRACT: retire and expand first")
		}
		m.Versions[op.Version] = "contracting"
		m.Compat = max(m.Compat, op.Version)
	case "contract-end":
		if m.Versions[op.Version] != "contracting" {
			return refuse("INV-CONTRACT: no contract in progress")
		}
		m.Versions[op.Version] = "contracted"
	case "crash":
		// Session/transaction locks disappear, durable work survives.
		m.Writers = map[string]int{}
		m.RetiringThrough = 0
		for name, job := range m.Indexes {
			job.Holders = map[string]IndexHolder{}
			job.Active = ""
			m.Indexes[name] = job
		}
	case "row-add":
		if _, ok := m.Rows[op.ID]; ok || op.Generation < 1 || op.Generation >= 32767 {
			return refuse("INV-GENERATION: invalid row generation")
		}
		m.Rows[op.ID] = Row{Generation: op.Generation, Target: op.Generation + 1, Version: m.Expanded, Revision: 1}
	case "backfill", "reject", "old-write":
		r, ok := m.Rows[op.ID]
		if !ok {
			return refuse("unknown row")
		}
		switch op.Kind {
		case "old-write":
			if !m.Admitted(op.Version) || op.Version <= m.RetiringThrough {
				return refuse("INV-FENCE: retired writer")
			}
			if r.Revision == math.MaxUint64 {
				return refuse("INV-ROW-REVISION: revision overflow")
			}
			r.Generation = min(r.Generation, r.Target-1)
			r.Revision++
			r.Rejected, r.Repair, r.Reason = false, 0, ""
			delete(m.Quarantine, op.ID)
		case "reject":
			if r.Generation == r.Target {
				return refuse("INV-REPAIR-SCOPE: do not re-evaluate an accepted row")
			}
			r.Rejected = true
			r.Repair, r.Reason = 0, op.Reason
			if r.Reason == "" {
				r.Reason = "frozen migration rejected the row"
			}
			delete(m.Quarantine, op.ID)
		default:
			if r.Generation == r.Target {
				return nil
			}
			if r.Revision == math.MaxUint64 {
				return refuse("INV-ROW-REVISION: revision overflow")
			}
			r.Generation = r.Target
			r.Revision++
			r.Rejected, r.Repair, r.Reason = false, 0, ""
			delete(m.Quarantine, op.ID)
		}
		m.Rows[op.ID] = r
	case "row-delete":
		if !m.Admitted(op.Version) || op.Version <= m.RetiringThrough {
			return refuse("INV-FENCE: row deletion needs an admitted writer")
		}
		delete(m.Rows, op.ID)
		delete(m.Quarantine, op.ID)
	case "repair-row":
		r, exists := m.Rows[op.ID]
		if !exists || !r.Rejected || r.Generation == r.Target || r.Revision != op.Revision || op.Version != r.Version {
			return refuse("INV-REPAIR-SCOPE: repair only a current rejected row")
		}
		if m.RetiringThrough != op.Version-1 {
			return refuse("INV-FENCE: repair pass requires the predecessor's exclusive fence")
		}
		if err := m.repairCompatible(op.Version, op.RepairHashes, true); err != nil {
			return err
		}
		chain := m.Repairs[op.Version]
		if op.Sequence != r.Repair+1 || op.Sequence > len(chain) || op.Hash != chain[op.Sequence-1] {
			return refuse("INV-REPAIR-ORDER: apply recorded repairs in order")
		}
		r.Repair = op.Sequence
		if op.Accept {
			if r.Revision == math.MaxUint64 {
				return refuse("INV-ROW-REVISION: revision overflow")
			}
			r.Generation, r.Rejected, r.Reason = r.Target, false, ""
			r.Revision++
			delete(m.Quarantine, op.ID)
		} else {
			if op.Reason == "" {
				return refuse("INV-QUARANTINE: rejected repair requires a reason")
			}
			r.Reason = op.Reason
			// An older observation does not describe the latest evaluated chain.
			delete(m.Quarantine, op.ID)
		}
		m.Rows[op.ID] = r
	case "quarantine-refresh":
		if m.RetiringThrough != 0 {
			return refuse("INV-QUARANTINE: record rejection after retirement aborts")
		}
		r, exists := m.Rows[op.ID]
		if !exists {
			delete(m.Quarantine, op.ID)
			return nil
		}
		if r.Revision != op.Revision {
			return refuse("INV-QUARANTINE: stale row observation")
		}
		if !r.Rejected {
			delete(m.Quarantine, op.ID)
		} else {
			m.Quarantine[op.ID] = QuarantineRow{Version: r.Version, Generation: r.Target, Revision: r.Revision, Repair: r.Repair, Reason: r.Reason}
		}
	case "enqueue":
		if !m.Admitted(op.Version) || op.Version <= m.RetiringThrough {
			return refuse("INV-FENCE: enqueue refused")
		}
		if _, ok := m.Jobs[op.ID]; ok {
			return refuse("duplicate job")
		}
		m.Jobs[op.ID] = Job{Version: op.Version, Status: "pending"}
	case "claim":
		j, ok := m.Jobs[op.ID]
		if !ok {
			return refuse("unknown job")
		}
		if !m.Admitted(op.Version) || op.Version <= m.RetiringThrough || j.Version > op.Version || j.Version < m.Floor || j.Quarantined {
			return refuse("INV-DECODER: outside admitted decoder window")
		}
		if j.Status != "pending" && j.Status != "processing" {
			return refuse("INV-ATTEMPT: only pending or expired processing jobs are claimable")
		}
		if j.Status == "processing" && j.LeaseUntil > m.Clock {
			return refuse("INV-ATTEMPT: live claim")
		}
		if op.Ticks <= 0 || op.Ticks > math.MaxInt64-m.Clock || j.Attempt >= math.MaxInt64 {
			return refuse("INV-ATTEMPT: lease or attempt out of range")
		}
		j.Status = "processing"
		j.Attempt++
		j.Claimant = op.Version
		j.LeaseUntil = m.Clock + op.Ticks
		m.Jobs[op.ID] = j
	case "renew", "complete", "retry", "dead":
		j, ok := m.Jobs[op.ID]
		if !ok {
			return refuse("unknown job")
		}
		if j.Status != "processing" || j.Attempt != op.Attempt || j.Claimant != op.Version || j.LeaseUntil <= m.Clock {
			return refuse("INV-ATTEMPT: stale outcome")
		}
		if !m.Admitted(op.Version) || op.Version <= m.RetiringThrough {
			return refuse("INV-FENCE: claimant retired")
		}
		switch op.Kind {
		case "renew":
			if op.Ticks <= 0 || op.Ticks > math.MaxInt64-m.Clock {
				return refuse("INV-ATTEMPT: lease out of range")
			}
			j.LeaseUntil = m.Clock + op.Ticks
		case "complete":
			delete(m.Jobs, op.ID)
			return nil
		case "retry":
			j.Status = "pending"
			j.Version = op.Version
		case "dead":
			j.Status = "dead"
			j.Version = op.Version
		}
		m.Jobs[op.ID] = j
	case "restamp":
		j, ok := m.Jobs[op.ID]
		if !ok {
			return refuse("unknown job")
		}
		if m.RetiringThrough != op.Version-1 || op.Version > m.Expanded || j.Version >= op.Version {
			return refuse("INV-QUEUE-FLOOR: invalid restamp")
		}
		if j.Status == "processing" && j.Claimant < op.Version && j.LeaseUntil > m.Clock {
			return refuse("INV-CLAIMANT: wait only for retiring claimant")
		}
		if j.Status == "processing" && j.Claimant < op.Version {
			j.Status = "pending"
		}
		j.Version = op.Version
		m.Jobs[op.ID] = j
	case "tick":
		if op.Ticks < 0 || op.Ticks > math.MaxInt64-m.Clock {
			return refuse("INV-CLOCK: clock cannot reverse or overflow")
		}
		m.Clock += op.Ticks
	case "lease-acquire":
		l := m.Leases[op.ID]
		if l.Until > m.Clock || op.Ticks <= 0 || op.Ticks > math.MaxInt64-m.Clock || l.Token >= math.MaxInt64 || op.Hash == "" {
			return refuse("INV-LEASE: lease held or invalid")
		}
		l.Token++
		l.Holder = op.Hash
		l.Until = m.Clock + op.Ticks
		m.Leases[op.ID] = l
	case "lease-commit":
		l := m.Leases[op.ID]
		if l.Token != op.Attempt || l.Holder != op.Hash || l.Until <= m.Clock {
			return refuse("INV-LEASE: stale executor")
		}
	case "abi-select", "abi-batch", "abi-provisional", "abi-write":
		p := m.Processing[op.ID]
		if op.ID == "" || op.Hash == "" || op.Generation < 1 || op.Generation > 32767 || !m.Admitted(op.Version) {
			return refuse("INV-ABI: missing ABI or invalid generation")
		}
		if op.Kind == "abi-write" && (op.Holder == "" || m.Writers[op.Holder] != op.Version) {
			return refuse("INV-ABI: application target writes require the admitted transaction's fence")
		}
		if m.ABILocked[op.Version] && m.ExecutorABI[op.Version] != op.Hash {
			return refuse("INV-ABI: another entity or pass already fixed the migration ABI")
		}
		if p.Generation == 0 || (op.Generation == p.Generation+1 && op.Version > p.Version) {
			p = ProcessingABI{Version: op.Version, Generation: op.Generation, ABI: op.Hash}
		}
		if op.Version != p.Version || op.Generation != p.Generation || (op.Hash != p.ABI && (p.Rows > 0 || p.Provisional || p.Written)) {
			return refuse("INV-ABI: semantics cannot change after processing starts")
		}
		m.ExecutorABI[op.Version] = op.Hash
		p.ABI = op.Hash
		if op.Kind == "abi-batch" {
			if p.Rows == math.MaxUint64 {
				return refuse("INV-ABI: processed-row count overflow")
			}
			p.Rows++
			m.ABILocked[op.Version] = true
		}
		if op.Kind == "abi-provisional" {
			p.Provisional = true
			m.ABILocked[op.Version] = true
		}
		if op.Kind == "abi-write" {
			p.Written = true
			m.ABILocked[op.Version] = true
		}
		m.Processing[op.ID] = p
	case "repair-record":
		if m.Hashes[op.Version] == "" || op.Sequence < 1 || op.Sequence > 32767 || op.Hash == "" {
			return refuse("INV-REPAIR-HISTORY: repair requires a committed migration and a bounded positive sequence")
		}
		chain := m.Repairs[op.Version]
		if op.Sequence <= len(chain) {
			if chain[op.Sequence-1] != op.Hash {
				return refuse("INV-REPAIR-HISTORY: recorded repair is immutable")
			}
		} else if op.Sequence != len(chain)+1 {
			return refuse("INV-REPAIR-HISTORY: repair sequence has a gap")
		} else {
			m.Repairs[op.Version] = append(chain, op.Hash)
		}
	case "repair-admit", "repair-final":
		if err := m.repairCompatible(op.Version, op.RepairHashes, op.Kind == "repair-final"); err != nil {
			return err
		}
	default:
		if handled, err := m.applyIndex(op); handled {
			return err
		}
		return fmt.Errorf("unknown model operation %q", op.Kind)
	}
	return nil
}

func (m *Model) Check() error {
	if m.Clock < 0 {
		return refuse("INV-CLOCK: negative clock")
	}
	if m.Base < 1 || m.Floor < m.Base || m.Compat < m.Base || m.Compat > m.Floor || m.Floor > m.Expanded || m.Expanded >= 2147483647 {
		return refuse("INV-FLOOR: invalid floor ordering")
	}
	if len(m.Versions) != m.Expanded-m.Base+1 || len(m.Hashes) != len(m.Versions) || len(m.EpochPreserving) != len(m.Versions) {
		return refuse("INV-HISTORY: missing or extra version evidence")
	}
	for v, state := range m.Versions {
		if _, exists := m.EpochPreserving[v]; !exists || m.Hashes[v] == "" || v < m.Base || v > m.Expanded {
			return refuse("INV-HISTORY: incomplete version identity")
		}
		if state != "expanded" && state != "contracting" && state != "contracted" || state != "expanded" && v > m.Compat {
			return refuse("INV-LIFECYCLE: invalid contract evidence")
		}
	}
	if m.Versions[m.Compat] == "expanded" || m.RetiringThrough != 0 && (m.RetiringThrough < m.Floor || m.RetiringThrough >= m.Expanded) {
		return refuse("INV-FLOOR: compatibility or retirement fence has no lifecycle basis")
	}
	if !m.Epoch && m.Expanded-m.Floor > 1 {
		return refuse("INV-WINDOW: more than two admitted versions")
	}
	for _, v := range m.Writers {
		if !m.Admitted(v) || v <= m.RetiringThrough {
			return refuse("INV-FENCE: excluded writer active")
		}
	}
	for _, r := range m.Rows {
		if r.Generation < 1 || r.Generation > r.Target || r.Target > 32767 || r.Target-r.Generation > 1 {
			return refuse("INV-GENERATION: invalid generation")
		}
		if r.Revision == 0 || m.Hashes[r.Version] == "" || r.Repair < 0 || r.Repair > len(m.Repairs[r.Version]) || (r.Rejected && (r.Reason == "" || r.Generation == r.Target)) {
			return refuse("INV-REPAIR-SCOPE: invalid row evaluation evidence")
		}
	}
	for id, q := range m.Quarantine {
		r, exists := m.Rows[id]
		if !exists || !r.Rejected || q.Revision != r.Revision || q.Version != r.Version || q.Generation != r.Target || q.Repair != r.Repair || q.Reason != r.Reason {
			return refuse("INV-QUARANTINE: quarantine does not describe a current rejection")
		}
	}
	for _, j := range m.Jobs {
		if j.Status != "pending" && j.Status != "dead" && j.Status != "processing" || j.Attempt > math.MaxInt64 || j.LeaseUntil < 0 {
			return refuse("INV-ATTEMPT: invalid queue state")
		}
		if j.Version < m.Floor && !j.Quarantined {
			return refuse("INV-QUEUE-FLOOR: job below admission floor")
		}
		if j.Version > m.Expanded {
			return refuse("INV-DECODER: future job")
		}
		if j.Status == "processing" && (j.Attempt == 0 || j.Claimant < j.Version && j.LeaseUntil > m.Clock) {
			return refuse("INV-ATTEMPT: invalid processing identity")
		}
	}
	for _, l := range m.Leases {
		if l.Token == 0 || l.Token > math.MaxInt64 || l.Until < 0 || l.Holder == "" {
			return refuse("INV-LEASE: invalid executor identity")
		}
	}
	for entity, p := range m.Processing {
		if entity == "" || p.Generation < 1 || p.Generation > 32767 || p.ABI == "" || m.Hashes[p.Version] == "" {
			return refuse("INV-ABI: invalid processing state")
		}
		if (p.Rows > 0 || p.Provisional || p.Written) && (!m.ABILocked[p.Version] || p.ABI != m.ExecutorABI[p.Version]) {
			return refuse("INV-ABI: processed work has no consistent ABI")
		}
	}
	for v, chain := range m.Repairs {
		if m.Hashes[v] == "" || len(chain) > 32767 {
			return refuse("INV-REPAIR-HISTORY: invalid repair chain")
		}
		for _, hash := range chain {
			if hash == "" {
				return refuse("INV-REPAIR-HISTORY: missing repair identity")
			}
		}
	}
	return m.checkIndexes()
}

func (m *Model) repairCompatible(version int, embedded []string, finalPass bool) error {
	if m.Hashes[version] == "" || len(embedded) > 32767 {
		return refuse("INV-REPAIR-HISTORY: unknown migration or excessive repair sequence")
	}
	for _, hash := range embedded {
		if hash == "" {
			return refuse("INV-REPAIR-HISTORY: incomplete embedded repair chain")
		}
	}
	recorded := m.Repairs[version]
	shared := min(len(recorded), len(embedded))
	if !slices.Equal(recorded[:shared], embedded[:shared]) {
		return refuse("INV-REPAIR-HISTORY: incompatible repair chain")
	}
	if finalPass && len(embedded) < len(recorded) {
		return refuse("INV-REPAIR-EXECUTOR: final pass requires every recorded repair")
	}
	return nil
}
