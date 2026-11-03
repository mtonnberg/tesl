package migrationtest

import (
	"math"
	"strings"
)

// IndexJob separates PostgreSQL's catalog truth from worker bookkeeping. A live
// CREATE is already visible as INVALID. A lease expiry neither cancels that
// statement nor releases its backend's shared DDL-job lock.
type IndexJob struct {
	Version            int
	ContractVersion    int // immutable removal target; may be later than Version
	Expected, Observed string
	Catalog            string // absent, invalid, valid
	Active             string // backend currently executing CREATE
	Holders            map[string]IndexHolder
	Terminal, Ready    bool
	Attempts           uint64
}

type IndexHolder struct {
	Attempt uint64
	Version int // the executor's admitted schema, independently of index creation
}

func (m *Model) applyIndex(op Op) (bool, error) {
	if !strings.HasPrefix(op.Kind, "index-") {
		return false, nil
	}
	job, exists := m.Indexes[op.ID]
	lease := m.Leases["index:"+op.ID]
	current := op.Holder != "" && lease.Holder == op.Holder && lease.Token == op.Attempt && lease.Until > m.Clock
	held := op.Holder != "" && job.Holders[op.Holder].Attempt == op.Attempt && job.Holders[op.Holder].Version == op.Version && op.Attempt != 0
	switch op.Kind {
	case "index-plan":
		if op.ID == "" || op.Hash == "" || !m.Admitted(op.Version) {
			return true, refuse("INV-INDEX-IDENTITY: invalid planned index")
		}
		if exists {
			if job.Version != op.Version || job.Expected != op.Hash {
				return true, refuse("INV-INDEX-IDENTITY: index job identity changed")
			}
			return true, nil
		}
		job = IndexJob{Version: op.Version, Expected: op.Hash, Catalog: "absent", Holders: map[string]IndexHolder{}}
	case "index-enter":
		if !exists || job.Terminal || !m.Admitted(op.Version) || op.Version < job.Version || op.Version <= m.RetiringThrough || !current || job.Holders[op.Holder].Attempt != 0 {
			return true, refuse("INV-DDL-JOB: shared job lock requires an admitted current non-terminal executor")
		}
		job.Holders[op.Holder] = IndexHolder{Attempt: op.Attempt, Version: op.Version}
	case "index-start":
		if !held || !current || job.Terminal || job.Catalog != "absent" || job.Active != "" || job.Attempts >= math.MaxInt32 {
			return true, refuse("INV-INDEX-BUILD: CREATE requires an absent index and the current job owner")
		}
		job.Catalog, job.Observed, job.Active = "invalid", job.Expected, op.Holder
		job.Attempts++
	case "index-success", "index-failure":
		// The server can finish an already running statement after its worker's
		// lease expires. Publication remains a separate, token-checked action.
		if !held || job.Active != op.Holder || job.Catalog != "invalid" {
			return true, refuse("INV-INDEX-BUILD: no matching server-side build")
		}
		if op.Kind == "index-success" {
			job.Catalog = "valid"
		}
		job.Active = ""
	case "index-cleanup":
		if !held || !current || job.Terminal || job.Active != "" || job.Catalog != "invalid" {
			return true, refuse("INV-INDEX-RECOVERY: drop only an inactive invalid remnant")
		}
		job.Catalog, job.Observed = "absent", ""
	case "index-verify":
		if !held || !current || job.Terminal || job.Active != "" || job.Catalog != "valid" || job.Observed != job.Expected {
			return true, refuse("INV-INDEX-READY: readiness requires the exact valid catalog object")
		}
		job.Ready = true
	case "index-exit":
		if !held || job.Active == op.Holder {
			return true, refuse("INV-DDL-JOB: hold the job lock until the statement finishes")
		}
		delete(job.Holders, op.Holder)
	case "index-backend-death":
		if !held {
			return true, refuse("INV-DDL-JOB: unknown backend")
		}
		delete(job.Holders, op.Holder)
		if job.Active == op.Holder {
			job.Active = ""
		}
	case "index-terminal":
		if !exists || len(job.Holders) != 0 || job.Active != "" || op.Version < job.Version || op.Version > m.Floor || m.Hashes[op.Version] == "" {
			return true, refuse("INV-DDL-TERMINAL: contract needs every shared job lock to drain")
		}
		if job.ContractVersion != 0 && job.ContractVersion != op.Version {
			return true, refuse("INV-DDL-TERMINAL: an index removal cannot change its contract identity")
		}
		job.ContractVersion = op.Version
		job.Terminal, job.Ready = true, false
	case "index-drop":
		if !exists || !job.Terminal || len(job.Holders) != 0 || job.Active != "" || m.Compat < job.ContractVersion {
			return true, refuse("INV-DDL-TERMINAL: record terminal and announce the plan switch before destructive DDL")
		}
		job.Catalog, job.Observed = "absent", ""
	default:
		return true, refuse("unknown index model operation")
	}
	m.Indexes[op.ID] = job
	return true, nil
}

func (m *Model) checkIndexes() error {
	for name, job := range m.Indexes {
		if name == "" || job.Expected == "" || m.Hashes[job.Version] == "" || job.Attempts > math.MaxInt32 {
			return refuse("INV-INDEX-IDENTITY: invalid index job identity")
		}
		if job.Catalog != "absent" && job.Catalog != "invalid" && job.Catalog != "valid" {
			return refuse("INV-INDEX-BUILD: invalid catalog state")
		}
		if (job.Catalog == "absent") != (job.Observed == "") {
			return refuse("INV-INDEX-IDENTITY: catalog identity is missing or stale")
		}
		if job.Active != "" && (job.Catalog != "invalid" || job.Holders[job.Active].Attempt == 0) {
			return refuse("INV-DDL-JOB: active build lost its job lock")
		}
		if job.Terminal && (len(job.Holders) != 0 || job.Active != "" || job.Ready) {
			return refuse("INV-DDL-TERMINAL: terminal job has an active worker")
		}
		if job.Terminal != (job.ContractVersion != 0) || (job.Terminal && (job.ContractVersion < job.Version || job.ContractVersion > m.Floor || m.Hashes[job.ContractVersion] == "")) {
			return refuse("INV-DDL-TERMINAL: missing or invalid index removal contract")
		}
		if job.Ready && (job.Catalog != "valid" || job.Observed != job.Expected) {
			return refuse("INV-INDEX-READY: unverified index is ready")
		}
		for holder, claim := range job.Holders {
			// An expired holder may finish a statement, but retirement cannot
			// pass its session fence until the backend exits.
			if holder == "" || claim.Attempt == 0 || claim.Attempt > m.Leases["index:"+name].Token || !m.Admitted(claim.Version) || claim.Version < job.Version || claim.Version <= m.RetiringThrough {
				return refuse("INV-DDL-JOB: invalid or retired DDL backend")
			}
		}
	}
	return nil
}
