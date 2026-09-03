// Package status renders the ssmd demo status page.
//
// Standard library only - no database driver, no redis client. A TCP probe
// answers "is it reachable", which is the question, and pulling in three
// drivers to answer it would make the demo's dependency list larger than the
// demo. It also keeps `go mod download` instant, which is what makes a fresh
// worktree instance start fast.
package status

import (
	"fmt"
	"net"
	"os"
	"runtime"
	"strings"
	"time"
)

func reachable(host, port string) bool {
	if host == "" || port == "" {
		return false
	}
	c, err := net.DialTimeout("tcp", net.JoinHostPort(host, port), 5*time.Second)
	if err != nil {
		return false
	}
	_ = c.Close()
	return true
}

func okFailed(ok bool) string {
	if ok {
		return "ok"
	}
	return "FAILED"
}

// Render returns the plain-text status page every ssmd demo app serves.
func Render() string {
	e := os.Getenv
	var b strings.Builder

	fmt.Fprintln(&b, "ssmd demo app")
	fmt.Fprintf(&b, "runtime=%s framework=none version=%s\n",
		or(e("SSMD_RUNTIME"), "go"), strings.TrimPrefix(runtime.Version(), "go"))
	fmt.Fprintf(&b, "instance=%s\n", or(e("SSMD_INSTANCE"), "main"))

	if db := e("DB_DATABASE"); db != "" {
		fmt.Fprintf(&b, "database=%s %s\n", db, okFailed(reachable(e("DB_HOST"), e("DB_PORT"))))
	} else {
		fmt.Fprintln(&b, "database=skipped")
	}

	if h := e("REDIS_HOST"); h != "" {
		fmt.Fprintf(&b, "cache=db%s %s\n", or(e("REDIS_DB"), "0"),
			okFailed(reachable(h, or(e("REDIS_PORT"), "6379"))))
	} else {
		fmt.Fprintln(&b, "cache=skipped")
	}

	if h := e("MAIL_HOST"); h != "" {
		fmt.Fprintf(&b, "mail=%s\n", okFailed(reachable(h, or(e("MAIL_PORT"), "1025"))))
	} else {
		fmt.Fprintln(&b, "mail=skipped")
	}

	fmt.Fprintf(&b, "storage=%s\n", map[bool]string{true: "ok", false: "skipped"}[e("S3_ENDPOINT") != ""])
	return b.String()
}

func or(v, fallback string) string {
	if v == "" {
		return fallback
	}
	return v
}
