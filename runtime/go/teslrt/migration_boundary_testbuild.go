//go:build tesl_migration_test

package teslrt

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"time"
)

var migrationOccurrences = struct {
	sync.Mutex
	counts map[string]int
}{counts: make(map[string]int)}

// Each arrival uses its own connection. A paused actor must not hold a Go mutex
// that prevents another goroutine from reaching the competing boundary.
func migrationBoundary(name string) {
	socket := os.Getenv("TESL_MIGRATION_TEST_SOCKET")
	if socket == "" {
		return
	}
	actor := os.Getenv("TESL_MIGRATION_TEST_ACTOR")
	migrationOccurrences.Lock()
	migrationOccurrences.counts[name]++
	occurrence := migrationOccurrences.counts[name]
	migrationOccurrences.Unlock()
	deadline := time.Now().Add(30 * time.Second)
	conn, err := net.DialTimeout("unix", socket, time.Until(deadline))
	if err != nil {
		panic(fmt.Sprintf("migration boundary %s/%s/%d: %v", actor, name, occurrence, err))
	}
	defer conn.Close()
	if err = conn.SetDeadline(deadline); err != nil {
		panic(err)
	}
	err = json.NewEncoder(conn).Encode(struct {
		Version    int    `json:"version"`
		Name       string `json:"name"`
		Actor      string `json:"actor"`
		Occurrence int    `json:"occurrence"`
	}{1, name, actor, occurrence})
	if err != nil {
		panic(err)
	}
	reply, err := bufio.NewReader(io.LimitReader(conn, 128)).ReadString('\n')
	if err != nil || reply != "continue\n" {
		panic(fmt.Sprintf("migration boundary %s/%s/%d refused: %q (%v)", actor, name, occurrence, reply, err))
	}
}
