package store

import (
	"context"
	"path/filepath"
	"sort"

	"github.com/jackc/pgx/v5"
)

// MaintenanceLockKey is the advisory lock that makes one API instance the maintenance leader. It is
// deliberately different from the migration lock (4917301, in cmd/migrate); both live in the
// database-wide advisory lock namespace.
const MaintenanceLockKey int64 = 4917302

// MigrationNames lists the migration files in dir, in application order. The migrate command
// records the same names in schema_migrations.
func MigrationNames(dir string) ([]string, error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.sql"))
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(files))
	for _, f := range files {
		names = append(names, filepath.Base(f))
	}
	sort.Strings(names)
	return names, nil
}

// MissingMigrations returns the expected migrations the database has not applied. A database that has
// applied more than the binary knows (a rollback to the previous release) is fine: migrations are
// written to be backward compatible with the release before.
func (s *Store) MissingMigrations(ctx context.Context, expected []string) ([]string, error) {
	rows, err := s.Pool.Query(ctx, `SELECT version FROM schema_migrations`)
	if err != nil {
		return nil, err
	}
	applied := map[string]bool{}
	for rows.Next() {
		var v string
		if err = rows.Scan(&v); err != nil {
			rows.Close()
			return nil, err
		}
		applied[v] = true
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	var missing []string
	for _, name := range expected {
		if !applied[name] {
			missing = append(missing, name)
		}
	}
	return missing, nil
}

// Leader elects one instance to run singleton work (maintenance) with a session-level PostgreSQL
// advisory lock held on a connection of its own, so it costs no pool slot and the lock disappears when
// the process or the connection dies. It is not safe for concurrent use: one goroutine calls Acquire
// on each tick and Release at shutdown.
//
// Session-level locks need a direct (or session-mode pooled) connection: behind a transaction-mode
// pooler such as PgBouncer or Supabase's pooler on port 6543, the lock would be taken and dropped on
// different server connections. Point DATABASE_URL at the primary directly.
type Leader struct {
	s    *Store
	key  int64
	conn *pgx.Conn
}

// NewLeader returns a candidate for the lock key (MaintenanceLockKey for the maintenance jobs).
func (s *Store) NewLeader(key int64) *Leader { return &Leader{s: s, key: key} }

// Acquire reports whether this instance holds the lock now. A leader checks that its connection is
// still alive; if it is not, the lock is gone with it and Acquire tries to take it again.
func (l *Leader) Acquire(ctx context.Context) (bool, error) {
	if l.conn != nil {
		if err := l.conn.Ping(ctx); err == nil {
			return true, nil
		}
		l.drop()
	}
	conn, err := pgx.ConnectConfig(ctx, l.s.Pool.Config().ConnConfig.Copy())
	if err != nil {
		return false, err
	}
	var got bool
	if err = conn.QueryRow(ctx, `SELECT pg_try_advisory_lock($1)`, l.key).Scan(&got); err != nil || !got {
		_ = conn.Close(context.WithoutCancel(ctx))
		return false, err
	}
	l.conn = conn
	return true, nil
}

// IsLeader reports whether the last Acquire succeeded and nothing has dropped the lock since.
func (l *Leader) IsLeader() bool { return l.conn != nil }

// Release gives the lock up so another instance can take over at once. Safe to call when not the leader.
func (l *Leader) Release(ctx context.Context) error {
	if l.conn == nil {
		return nil
	}
	conn := l.conn
	l.conn = nil
	_, err := conn.Exec(ctx, `SELECT pg_advisory_unlock($1)`, l.key)
	_ = conn.Close(ctx)
	return err
}

func (l *Leader) drop() {
	if l.conn != nil {
		_ = l.conn.Close(context.Background())
		l.conn = nil
	}
}
