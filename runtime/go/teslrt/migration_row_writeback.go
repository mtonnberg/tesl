package teslrt

import "fmt"

// PgRowWriteBack keeps the compiler's explicit reverse constructor nominally
// typed. It grants no transaction, SQL mapping or generation admission authority.
type PgRowWriteBack[From, To any] struct {
	storage *PgRowStorage[From, To]
	reverse func(To) From
}

func RegisterCompiledRowWriteBack[From, To any](storage *PgRowStorage[From, To], reverse func(To) From) *PgRowWriteBack[From, To] {
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
	if !r.storageAttached || len(r.compiled.inventory.Transforms[r.index].WriteBacks) == 0 {
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
		if recover() != nil {
			var empty From
			result = empty
			err = fmt.Errorf("WriteBack rejected a value")
		}
	}()
	return adapter.reverse(value), nil
}
func (adapter *PgRowWriteBack[From, To]) Encode(value To) (PgEncodedRow, error) {
	old, err := adapter.Reverse(value)
	if err != nil {
		return PgEncodedRow{}, err
	}
	return adapter.storage.EncodeSource(old)
}
