// tri-onyx-fs is a FUSE filesystem driver that enforces fine-grained
// file access control for TriOnyx agent containers. It mounts a
// passthrough filesystem filtered by a JSON policy of glob patterns.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	trionyxfs "github.com/tri-onyx/tri-onyx-fs/internal/fs"
	"github.com/tri-onyx/tri-onyx-fs/internal/pathtrie"
	"github.com/tri-onyx/tri-onyx-fs/internal/policy"
	gofusefs "github.com/hanwen/go-fuse/v2/fs"
)

func main() {
	configPath := flag.String("config", "", "path to JSON policy file")
	sourceDir := flag.String("source", "", "source directory to mirror (host bind mount)")
	mountPoint := flag.String("mountpoint", "", "directory to mount the FUSE filesystem")
	allowOther := flag.Bool("allow-other", false, "set FUSE allow_other option (requires /etc/fuse.conf)")
	flag.Parse()

	if *configPath == "" || *sourceDir == "" || *mountPoint == "" {
		fmt.Fprintf(os.Stderr, "usage: tri-onyx-fs --config <path> --source <dir> --mountpoint <dir>\n")
		os.Exit(1)
	}

	// Validate paths exist.
	for _, p := range []struct{ name, path string }{
		{"config", *configPath},
		{"source", *sourceDir},
		{"mountpoint", *mountPoint},
	} {
		if _, err := os.Stat(p.path); err != nil {
			fatalf("validate %s: %v", p.name, err)
		}
	}

	// 1. Load policy — fail closed on error.
	raw, err := policy.Load(*configPath)
	if err != nil {
		fatalf("load policy: %v", err)
	}

	// 2. Expand globs against source directory.
	pol, err := policy.Expand(raw, *sourceDir)
	if err != nil {
		fatalf("expand policy: %v", err)
	}

	// 3. Build path trie.
	trie := pathtrie.Build(pol.ReadPaths, pol.WritePaths, *sourceDir)

	// 4. Create root node.
	logger := trionyxfs.NewDenialLogger()
	rootData := &trionyxfs.RootData{
		SourceDir:     *sourceDir,
		Trie:          trie,
		ReadPatterns:  pol.RawReadPatterns,
		WritePatterns: pol.RawWritePatterns,
		LogDenials:    pol.LogDenials,
		Logger:        logger,
		LogWrites:     pol.LogWrites,
		MaxReadRisk:   pol.MaxReadRisk,
	}
	if pol.LogWrites {
		rootData.WriteLogger = trionyxfs.NewWriteLogger()
	}
	// Load risk manifest for risk-based read filtering (Phase 4).
	// Missing manifest is not fatal — filtering is simply inactive.
	if rootData.MaxReadRisk != "" {
		if err := rootData.LoadManifest(); err != nil {
			logEvent("warn", map[string]interface{}{
				"msg":   "failed to load risk manifest",
				"error": err.Error(),
			})
		}
	}
	root := &trionyxfs.SecureNode{RootData: rootData}

	// 5. Mount FUSE filesystem.
	oneSec := time.Second
	opts := &gofusefs.Options{
		EntryTimeout: &oneSec,
		AttrTimeout:  &oneSec,
	}
	opts.MountOptions.AllowOther = *allowOther

	server, err := gofusefs.Mount(*mountPoint, root, opts)
	if err != nil {
		fatalf("mount: %v", err)
	}

	// 6. Log structured startup event.
	logEvent("mounted", map[string]interface{}{
		"source":      *sourceDir,
		"mountpoint":  *mountPoint,
		"read_paths":  len(pol.ReadPaths),
		"write_paths": len(pol.WritePaths),
		"log_denials": pol.LogDenials,
		"log_writes":  pol.LogWrites,
	})

	// 7. Signal handler: clean unmount on SIGTERM/SIGINT.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		sig := <-sigCh
		logEvent("unmounting", map[string]interface{}{
			"signal": sig.String(),
		})
		server.Unmount()
	}()

	// 8. Serve until unmounted.
	server.Wait()

	logEvent("shutdown", nil)
}

func fatalf(format string, args ...interface{}) {
	logEvent("fatal", map[string]interface{}{
		"error": fmt.Sprintf(format, args...),
	})
	os.Exit(1)
}

func logEvent(event string, fields map[string]interface{}) {
	m := map[string]interface{}{
		"event": event,
		"time":  time.Now().UTC().Format(time.RFC3339),
	}
	for k, v := range fields {
		m[k] = v
	}
	json.NewEncoder(os.Stderr).Encode(m)
}
