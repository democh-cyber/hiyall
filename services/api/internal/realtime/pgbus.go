package realtime

import (
	"context"
	"encoding/json"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Channel is the PostgreSQL notification channel the PGBus listens on.
const Channel = "hiyall_realtime"

// maxUsersPerNotify keeps each payload well under PostgreSQL's 8000-byte limit.
const maxUsersPerNotify = 100

// PGBus fans out through LISTEN/NOTIFY. It suits one regional cell; NOTIFY
// serializes on a cluster-wide queue, so a Redis or NATS bus with per-node
// routing replaces it once socket counts or event rates outgrow that.
type PGBus struct {
	Pool   *pgxpool.Pool
	Config *pgx.ConnConfig
}

func (b *PGBus) Publish(ctx context.Context, e Event) error {
	users := e.Users
	for len(users) > 0 {
		n := min(len(users), maxUsersPerNotify)
		part := e
		part.Users = users[:n]
		users = users[n:]
		payload, err := json.Marshal(part)
		if err != nil {
			return err
		}
		if _, err = b.Pool.Exec(ctx, `SELECT pg_notify($1,$2)`, Channel, string(payload)); err != nil {
			return err
		}
	}
	return nil
}

// Run listens on a dedicated connection so it never holds a pool slot.
func (b *PGBus) Run(ctx context.Context, deliver func(Event)) error {
	conn, err := pgx.ConnectConfig(ctx, b.Config)
	if err != nil {
		return err
	}
	defer conn.Close(context.Background())
	if _, err = conn.Exec(ctx, `LISTEN `+Channel); err != nil {
		return err
	}
	for {
		n, err := conn.WaitForNotification(ctx)
		if err != nil {
			return err
		}
		var e Event
		if json.Unmarshal([]byte(n.Payload), &e) != nil || e.Type == "" {
			continue
		}
		deliver(e)
	}
}
