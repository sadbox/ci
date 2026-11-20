package main

import (
	"context"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func TestHealthy(t *testing.T) {
	srv := httptest.NewServer(newMux())
	defer srv.Close()

	// Concurrent checks, so -race has something to watch.
	var wg sync.WaitGroup
	errs := make([]error, 8)
	for i := range errs {
		wg.Go(func() {
			errs[i] = healthy(context.Background(), srv.URL+"/healthz", 5*time.Second)
		})
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Errorf("check %d: %v", i, err)
		}
	}

	if err := healthy(context.Background(), srv.URL+"/missing", 5*time.Second); err == nil {
		t.Error("a 404 was reported healthy")
	}
}
