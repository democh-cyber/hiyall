package realtime

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Two hubs on one database stand in for two API nodes.
func TestPGBusFansOutAcrossNodesAndSplitsLargeAudiences(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	bus := func() *PGBus { return &PGBus{Pool: pool, Config: pool.Config().ConnConfig} }
	nodeA, nodeB := NewHub(bus(), 5, 1000), NewHub(bus(), 5, 1000)
	retry := func(int) time.Duration { return 10 * time.Millisecond }
	go nodeA.Run(ctx, retry)
	go nodeB.Run(ctx, retry)

	onB := NewClient("bob", 8)
	nodeB.Register(onB)
	audience := make([]string, 0, 250)
	for i := range 249 {
		audience = append(audience, fmt.Sprintf("user-%d", i))
	}
	audience = append(audience, "bob")
	// LISTEN starts asynchronously; publish until node B is listening.
	deadline := time.After(5 * time.Second)
	for {
		nodeA.Publish(ctx, "inbox", map[string]string{"conversationId": "c1"}, audience...)
		select {
		case msg := <-onB.Send:
			if string(msg) != `{"type":"inbox","data":{"conversationId":"c1"}}` {
				t.Fatalf("wire %s", msg)
			}
			return
		case <-time.After(100 * time.Millisecond):
		case <-deadline:
			t.Fatal("event never crossed nodes")
		}
	}
}
