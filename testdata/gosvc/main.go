// Command gosvc is the fixture service sadbox/ci's own CI runs go.yml
// against: an HTTP server with the baseline's -healthcheck flag.
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"time"
)

func newMux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	return mux
}

// healthy reports whether the service at url answers 200 within timeout.
func healthy(ctx context.Context, url string, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: %s", url, resp.Status)
	}
	return nil
}

func main() {
	addr := flag.String("addr", "127.0.0.1:8080", "listen address")
	healthcheck := flag.Bool("healthcheck", false, "check the running service's /healthz and exit")
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))
	if *healthcheck {
		if err := healthy(context.Background(), "http://"+*addr+"/healthz", 5*time.Second); err != nil {
			logger.Error("unhealthy", "err", err)
			os.Exit(1)
		}
		return
	}

	srv := &http.Server{Addr: *addr, Handler: newMux(), ReadHeaderTimeout: 10 * time.Second}
	logger.Info("listening", "addr", *addr)
	if err := srv.ListenAndServe(); err != nil {
		logger.Error("serve", "err", err)
		os.Exit(1)
	}
}
