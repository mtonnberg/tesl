package teslrt

import (
	"context"
	"fmt"
	"runtime"

	"github.com/jackc/pgx/v5"
)

// Every process reads after its own cursor; no shared delivered bit or claims.
func (receiver *pgPubsub) drainBroadcast(conn *pgx.Conn, db *PostgresDB) error {
	receiver.deliveryMutex.Lock()
	defer receiver.deliveryMutex.Unlock()
	for {
		ctx, cancel := context.WithTimeout(receiver.ctx, pgLeaseTimeout())
		batch, err := pgMigrationStatementOn(ctx, db, conn, false, func(executor pgExecutor) ([]pubsubRow, error) {
			rows, err := executor.Query(ctx, "select dispatch_seq,channel,key,payload::text from "+db.QualifiedTable(pgBroadcastTable)+" where dispatch_seq>$1 order by dispatch_seq limit $2", receiver.cursor(), pubsubSweepBatch)
			if err != nil {
				return nil, err
			}
			return pgx.CollectRows(rows, func(row pgx.CollectableRow) (pubsubRow, error) {
				var event pubsubRow
				err := row.Scan(&event.dispatchSequence, &event.channel, &event.key, &event.encoded)
				return event, err
			})
		})
		cancel()
		if err != nil {
			return err
		}
		for _, event := range batch {
			receiver.deliver(event.channel, event.key, event.encoded)
			receiver.advance(event.dispatchSequence)
		}
		if len(batch) < pubsubSweepBatch {
			return nil
		}
		runtime.Gosched()
	}
}

func (receiver *pgPubsub) pruneBroadcast(conn *pgx.Conn, db *PostgresDB) error {
	ctx, cancel := context.WithTimeout(receiver.ctx, pgLeaseTimeout())
	defer cancel()
	_, err := pgMigrationStatementOn(ctx, db, conn, true, func(executor pgExecutor) (struct{}, error) {
		_, err := executor.Exec(ctx, "select "+db.QualifiedTable("tesl_sse_prune")+"($1::integer,$2::bigint)", db.migration.version, receiver.cursor())
		return struct{}{}, err
	})
	return err
}

func pgRequireBroadcast(db *PostgresDB) error {
	if !pgBroadcastConnection(db) {
		return fmt.Errorf("SSE requires a format5 Worker connection")
	}
	ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
	defer cancel()
	verify := func(tx pgx.Tx) error {
		if _, err := pgVerifyBroadcast(ctx, tx, db.schema, db.migration.roles, true); err != nil {
			return err
		}
		_, err := pgReadBroadcastClock(ctx, tx, db)
		return err
	}
	if tx := currentTransactionFor(db); tx != nil {
		return verify(tx)
	}
	tx, err := db.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted, AccessMode: pgx.ReadOnly})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if err := pgControlSession(ctx, tx); err != nil {
		return err
	}
	return verify(tx)
}

// Clock and retained maximum are read in the same statement snapshot.
func pgReadBroadcastClock(ctx context.Context, executor pgExecutor, db *PostgresDB) (int64, error) {
	var sequence int64
	clock := db.QualifiedTable(pgBroadcastClock)
	err := executor.QueryRow(ctx, "select value from "+clock+" where name='broadcast' and value>=0 and (select count(*) from "+clock+")=1 and value>=coalesce((select max(dispatch_seq) from "+db.QualifiedTable(pgBroadcastTable)+"),0)").Scan(&sequence)
	if err != nil {
		return 0, fmt.Errorf("SSE clock missing or inconsistent; refusing to reset delivery order: %w", err)
	}
	return sequence, nil
}
