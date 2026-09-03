// A Go service. air watches the tree and rebuilds; Caddy holds the request for
// up to 30s while it does (lb_try_duration in the runtime's serve.conf), so a
// save gives a slightly slow response rather than a 502 and a red line in the
// log.
package main

import (
	"fmt"
	"log/slog"
	"net/http"
	"os"

	"dx/demo/internal/status"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = os.Getenv("DX_APP_PORT")
	}
	if port == "" {
		port = "8080"
	}

	// JSON to stderr, so `dx logs` filtering and `dx verify`'s error diff treat
	// this runtime exactly like the others.
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stderr, nil)))

	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		fmt.Fprint(w, status.Render())
	})

	// No /healthz. Caddy answers it in front of this process and must keep
	// answering during the second or two a rebuild takes.

	// 0.0.0.0 by omission of a host: binding localhost inside a container makes
	// the process unreachable from Caddy, which presents as a 502 with nothing
	// in the application log.
	addr := ":" + port
	slog.Info("listening", "addr", addr, "instance", os.Getenv("DX_INSTANCE"))
	if err := http.ListenAndServe(addr, mux); err != nil {
		slog.Error("server stopped", "err", err)
		os.Exit(1)
	}
}
