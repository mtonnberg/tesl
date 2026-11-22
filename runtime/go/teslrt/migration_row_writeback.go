package teslrt

import (
	"errors"
	"fmt"
)

var errHistoricalWriteBackRejected = errors.New("historical write-back rejected the new value")

// PgRowWriteBack keeps the compiler's explicit reverse constructor nominally
// typed. It grants no transaction, SQL mapping or generation admission authority.
type PgRowWriteBack[From, To any] struct {
	storage *PgRowStorage[From, To]
	reverse func(To) Maybe[From]
}

func RegisterCompiledRowWriteBack[From, To any](storage *PgRowStorage[From, To], reverse func(To) From) *PgRowWriteBack[From, To] {
	if reverse == nil {
		panic("database: missing compiled WriteBack adapter")
	}
	return RegisterCompiledRowTryWriteBack(storage, func(value To) Maybe[From] { return Something(reverse(value)) })
}

// Nothing is a normal compatibility refusal. The transaction caller propagates
// this error before publishing a write, including rollback of earlier batches.
func RegisterCompiledRowTryWriteBack[From, To any](storage *PgRowStorage[From, To], reverse func(To) Maybe[From]) *PgRowWriteBack[From, To] {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	if storage == nil || storage.transform == nil || storage.transform.registration == nil || reverse == nil {
		panic("database: missing compiled WriteBack adapter")
	}
	r := storage.transform.registration
	if err := pgCheckRowOwner(r.database, r.compiled); err != nil {
		panic(err)
	}
	if r.sealed || pgMigrationClosedFamilies[r.compiled.history.Family] {
		panic("database: WriteBack attachment is closed")
	}
	if !r.storageAttached || len(r.compiled.transforms[r.index].WriteBacks)+len(r.compiled.transforms[r.index].LegacyWrites) == 0 {
		panic("database: WriteBack requires its exact compiled storage descriptor")
	}
	if r.writeBackAttached {
		panic("database: duplicate WriteBack attachment")
	}
	r.writeBackAttached = true
	adapter := &PgRowWriteBack[From, To]{storage: storage, reverse: reverse}
	storage.writeBack = adapter
	return adapter
}
func (adapter *PgRowWriteBack[From, To]) Reverse(value To) (result From, err error) {
	if adapter == nil || !adapter.storage.ready() {
		return result, fmt.Errorf("WriteBack requires a sealed adapter")
	}
	defer func() {
		if trapped := recover(); trapped != nil {
			var empty From
			result = empty
			err = fmt.Errorf("WriteBack rejected a value")
			if failure, bounded := trapped.(migrationExecutionFailure); bounded {
				err = failure
			}
		}
	}()
	defer BeginMigrationExecution()()
	previous := adapter.reverse(value)
	MigrationStep()
	if previous.Tag == MaybeNothing {
		return result, errHistoricalWriteBackRejected
	}
	if previous.Tag != MaybeSomething {
		return result, fmt.Errorf("historical write-back returned an invalid Maybe tag")
	}
	return previous.SomethingValue, nil
}
func (adapter *PgRowWriteBack[From, To]) Encode(value To) (PgEncodedRow, error) {
	old, err := adapter.Reverse(value)
	if err != nil {
		return PgEncodedRow{}, err
	}
	return adapter.storage.EncodeSource(old)
}
