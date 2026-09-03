package main

import (
	"os"
	"regexp"
	"strings"
	"testing"

	"ssmd/demo/internal/status"
)

func TestRendersTheAgreedShape(t *testing.T) {
	out := status.Render()
	if !strings.HasPrefix(out, "ssmd demo app") {
		t.Fatalf("unexpected first line: %q", out)
	}
	for _, want := range []string{"runtime=", "instance=", "database=", "cache="} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q", want)
		}
	}
}

// The same guard ssmd enforces, asserted from inside the project so it is visible
// to anyone reading the app rather than only anyone reading the toolkit.
func TestRunsAgainstADisposableDatabase(t *testing.T) {
	db := os.Getenv("DB_DATABASE")
	if db == "" {
		t.Skip("no database configured")
	}
	if !regexp.MustCompile(`(_test|_sandbox)$`).MatchString(db) {
		t.Fatalf("the suite must never point at the development database, got %q", db)
	}
}
