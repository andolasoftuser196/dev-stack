// The `queue` role runs this. The demo does no real work - it exists so the
// worker container has something to run and stays up.
package main

import (
	"log/slog"
	"os"
	"time"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stderr, nil)))
	slog.Info("worker started", "instance", os.Getenv("DX_INSTANCE"))
	for range time.Tick(30 * time.Second) {
		slog.Info("worker tick")
	}
}
