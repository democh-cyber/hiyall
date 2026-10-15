package main

import (
	"fmt"
	"io"
	"net"
	"time"
)

// healthcheck is `admin healthcheck`, the container HEALTHCHECK: the image is distroless (no shell, curl or wget).
// It opens a TCP connection to the console's own listener (ADMIN_ADDR, default 127.0.0.1:8081) and exits 0 when it
// accepts one. A connection proves the process is up whether or not it terminates TLS, and the check needs no login
// and no database. It returns the process exit code.
func healthcheck(getenv func(string) string, stderr io.Writer) int {
	addr := getenv("ADMIN_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8081"
	}
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		fmt.Fprintln(stderr, "invalid ADMIN_ADDR")
		return 2
	}
	if ip := net.ParseIP(host); host == "" || (ip != nil && ip.IsUnspecified()) {
		host = "127.0.0.1"
	}
	conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, port), 3*time.Second)
	if err != nil {
		fmt.Fprintln(stderr, "unhealthy: console is not accepting connections")
		return 1
	}
	_ = conn.Close()
	return 0
}
