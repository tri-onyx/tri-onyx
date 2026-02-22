package fs

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/tri-onyx/tri-onyx-fs/internal/pathtrie"
	gofusefs "github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

// testMount sets up a FUSE mount with the given trie and returns
// a cleanup function. Skips the test if /dev/fuse is unavailable.
func testMount(t *testing.T, sourceDir string, trie *pathtrie.Trie, writePatterns []string) (mountDir string, cleanup func()) {
	return testMountWithOpts(t, sourceDir, trie, writePatterns, false)
}

// testMountWithOpts is like testMount but allows setting allow_other.
func testMountWithOpts(t *testing.T, sourceDir string, trie *pathtrie.Trie, writePatterns []string, allowOther bool) (mountDir string, cleanup func()) {
	t.Helper()

	// Check for FUSE availability.
	if _, err := os.Stat("/dev/fuse"); err != nil {
		t.Skip("FUSE not available (/dev/fuse missing)")
	}

	mountDir = t.TempDir()

	rd := &RootData{
		SourceDir:     sourceDir,
		Trie:          trie,
		WritePatterns: writePatterns,
		LogDenials:    true,
		Logger:        NewDenialLogger(),
	}

	root := &SecureNode{RootData: rd}
	oneSec := time.Second
	opts := &gofusefs.Options{
		EntryTimeout: &oneSec,
		AttrTimeout:  &oneSec,
	}
	opts.MountOptions.AllowOther = allowOther

	server, err := gofusefs.Mount(mountDir, root, opts)
	if err != nil {
		t.Fatalf("mount: %v", err)
	}

	return mountDir, func() {
		server.Unmount()
	}
}

// setupTestSource creates a temp dir with a standard test layout.
func setupTestSource(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()

	files := map[string]string{
		"repo/src/main.py":       "print('hello')\n",
		"repo/src/lib/util.py":   "def util(): pass\n",
		"repo/.env":              "SECRET=abc\n",
		"repo/README.md":         "# Readme\n",
		"repo/out/result.json":   `{"ok":true}`,
		"repo/out/debug.log":     "debug\n",
	}
	for rel, content := range files {
		abs := filepath.Join(dir, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(abs, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestAllowedRead(t *testing.T) {
	src := setupTestSource(t)

	tr := pathtrie.New()
	tr.Insert("/repo/src/main.py", pathtrie.ReadAccess, true)
	tr.Insert("/repo/README.md", pathtrie.ReadAccess, true)

	mnt, cleanup := testMount(t, src, tr, nil)
	defer cleanup()

	data, err := os.ReadFile(filepath.Join(mnt, "repo/src/main.py"))
	if err != nil {
		t.Fatalf("reading allowed file: %v", err)
	}
	if !bytes.Contains(data, []byte("hello")) {
		t.Errorf("unexpected content: %s", data)
	}
}

func TestDeniedRead(t *testing.T) {
	src := setupTestSource(t)

	tr := pathtrie.New()
	tr.Insert("/repo/README.md", pathtrie.ReadAccess, true)
	// .env is not in the trie

	mnt, cleanup := testMount(t, src, tr, nil)
	defer cleanup()

	_, err := os.ReadFile(filepath.Join(mnt, "repo/.env"))
	if err == nil {
		t.Fatal("expected error reading denied file")
	}
	if !os.IsPermission(err) {
		t.Errorf("expected EACCES, got: %v", err)
	}
}

func TestAllowedWrite(t *testing.T) {
	src := setupTestSource(t)

	tr := pathtrie.New()
	tr.Insert("/repo/out/result.json", pathtrie.WriteAccess, true)

	mnt, cleanup := testMount(t, src, tr, nil)
	defer cleanup()

	err := os.WriteFile(filepath.Join(mnt, "repo/out/result.json"), []byte(`{"new":true}`), 0o644)
	if err != nil {
		t.Fatalf("writing allowed file: %v", err)
	}

	// Verify through source dir.
	data, err := os.ReadFile(filepath.Join(src, "repo/out/result.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(data, []byte("new")) {
		t.Errorf("write not reflected: %s", data)
	}
}

func TestDeniedWrite(t *testing.T) {
	src := setupTestSource(t)

	tr := pathtrie.New()
	tr.Insert("/repo/src/main.py", pathtrie.ReadAccess, true)

	mnt, cleanup := testMount(t, src, tr, nil)
	defer cleanup()

	err := os.WriteFile(filepath.Join(mnt, "repo/src/main.py"), []byte("hacked"), 0o644)
	if err == nil {
		t.Fatal("expected error writing to read-only file")
	}
	if !os.IsPermission(err) {
		t.Errorf("expected EACCES, got: %v", err)
	}
}

func TestReaddirFiltering(t *testing.T) {
	src := setupTestSource(t)

	tr := pathtrie.New()
	tr.Insert("/repo/src/main.py", pathtrie.ReadAccess, true)
	tr.Insert("/repo/README.md", pathtrie.ReadAccess, true)
	// .env and out/ are NOT in the trie

	mnt, cleanup := testMount(t, src, tr, nil)
	defer cleanup()

	entries, err := os.ReadDir(filepath.Join(mnt, "repo"))
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}

	names := make(map[string]bool)
	for _, e := range entries {
		names[e.Name()] = true
	}

	if !names["src"] {
		t.Error("expected 'src' in readdir")
	}
	if !names["README.md"] {
		t.Error("expected 'README.md' in readdir")
	}
	if names[".env"] {
		t.Error(".env should be hidden from readdir")
	}
	if names["out"] {
		t.Error("out/ should be hidden from readdir")
	}
}

func TestDirectoryTraversal(t *testing.T) {
	src := setupTestSource(t)

	tr := pathtrie.New()
	tr.Insert("/repo/src/lib/util.py", pathtrie.ReadAccess, true)

	mnt, cleanup := testMount(t, src, tr, nil)
	defer cleanup()

	// Should be able to stat intermediate directories.
	for _, rel := range []string{"repo", "repo/src", "repo/src/lib"} {
		info, err := os.Stat(filepath.Join(mnt, rel))
		if err != nil {
			t.Errorf("stat %s: %v", rel, err)
			continue
		}
		if !info.IsDir() {
			t.Errorf("%s should be a directory", rel)
		}
	}

	// Should be able to read the deep file.
	data, err := os.ReadFile(filepath.Join(mnt, "repo/src/lib/util.py"))
	if err != nil {
		t.Fatalf("read deep file: %v", err)
	}
	if !bytes.Contains(data, []byte("util")) {
		t.Errorf("unexpected content: %s", data)
	}
}

func TestDenialLogging(t *testing.T) {
	// Capture stderr output.
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	oldStderr := os.Stderr
	os.Stderr = w
	defer func() { os.Stderr = oldStderr }()

	logger := &DenialLogger{
		enc: json.NewEncoder(w),
	}
	logger.Log("open", "/secret.txt", "read")
	w.Close()

	var buf bytes.Buffer
	buf.ReadFrom(r)

	var ev DenialEvent
	if err := json.Unmarshal(buf.Bytes(), &ev); err != nil {
		t.Fatalf("parse denial log: %v (raw: %s)", err, buf.String())
	}
	if ev.Event != "denied" || ev.Op != "open" || ev.Path != "/secret.txt" || ev.Mode != "read" {
		t.Errorf("unexpected denial event: %+v", ev)
	}
}

func TestDynamicCreateInWriteGlob(t *testing.T) {
	src := setupTestSource(t)

	tr := pathtrie.New()
	tr.Insert("/repo/out/result.json", pathtrie.WriteAccess, true)

	// The glob pattern allows creating new files under /repo/out/
	writePatterns := []string{"/repo/out/**"}

	mnt, cleanup := testMount(t, src, tr, writePatterns)
	defer cleanup()

	// Create a file that doesn't exist in the trie but matches the glob.
	newFile := filepath.Join(mnt, "repo/out/new-output.txt")
	err := os.WriteFile(newFile, []byte("new data"), 0o644)
	if err != nil {
		t.Fatalf("creating new file in writable glob: %v", err)
	}

	// Verify through source.
	data, err := os.ReadFile(filepath.Join(src, "repo/out/new-output.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "new data" {
		t.Errorf("unexpected content: %s", data)
	}
}

func TestEmptyWritableDirTraversalAndCreate(t *testing.T) {
	src := setupTestSource(t)

	// Create an empty directory that matches a write glob but has no files
	// to populate the trie at startup. This simulates the agents/{name}/memory/
	// scenario where the directory exists but is empty.
	emptyDir := filepath.Join(src, "agents/test-agent/memory")
	if err := os.MkdirAll(emptyDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Also create HEARTBEAT.md so the parent dir has one file in the trie
	heartbeat := filepath.Join(src, "agents/test-agent/HEARTBEAT.md")
	if err := os.WriteFile(heartbeat, []byte("# Heartbeat\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	tr := pathtrie.New()
	// Only the heartbeat file exists, so only it gets into the trie.
	tr.Insert("/agents/test-agent/HEARTBEAT.md", pathtrie.WriteAccess, true)

	// The write glob covers the entire agent directory including memory/
	writePatterns := []string{"/agents/test-agent/**"}

	mnt, cleanup := testMount(t, src, tr, writePatterns)
	defer cleanup()

	// Should be able to stat the empty memory directory
	memDir := filepath.Join(mnt, "agents/test-agent/memory")
	info, err := os.Stat(memDir)
	if err != nil {
		t.Fatalf("stat empty writable dir: %v", err)
	}
	if !info.IsDir() {
		t.Error("memory should be a directory")
	}

	// Should be able to list the empty directory
	entries, err := os.ReadDir(memDir)
	if err != nil {
		t.Fatalf("readdir empty writable dir: %v", err)
	}
	if len(entries) != 0 {
		t.Errorf("expected empty dir, got %d entries", len(entries))
	}

	// Should be able to create a file in the empty directory
	dailyFile := filepath.Join(mnt, "agents/test-agent/memory/2026-02-17.md")
	err = os.WriteFile(dailyFile, []byte("# Memory\n"), 0o644)
	if err != nil {
		t.Fatalf("create file in empty writable dir: %v", err)
	}

	// Verify through source
	data, err := os.ReadFile(filepath.Join(src, "agents/test-agent/memory/2026-02-17.md"))
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "# Memory\n" {
		t.Errorf("unexpected content: %s", data)
	}
}

func TestRenameRequiresBothPaths(t *testing.T) {
	src := setupTestSource(t)

	tr := pathtrie.New()
	tr.Insert("/repo/out/result.json", pathtrie.WriteAccess, true)
	tr.Insert("/repo/src/main.py", pathtrie.ReadAccess, true)

	mnt, cleanup := testMount(t, src, tr, nil)
	defer cleanup()

	// Rename from write-allowed to read-only dir → should fail.
	oldPath := filepath.Join(mnt, "repo/out/result.json")
	newPath := filepath.Join(mnt, "repo/src/moved.json")

	err := syscall.Rename(oldPath, newPath)
	if err == nil {
		t.Fatal("expected error renaming to read-only location")
	}
	if err != syscall.EACCES {
		t.Errorf("expected EACCES, got: %v", err)
	}
}

func TestNonExistentReturnsENOENT(t *testing.T) {
	src := setupTestSource(t)

	tr := pathtrie.New()
	tr.Insert("/repo/src/main.py", pathtrie.ReadAccess, true)

	mnt, cleanup := testMount(t, src, tr, nil)
	defer cleanup()

	_, err := os.Stat(filepath.Join(mnt, "repo/src/nonexistent.py"))
	if err == nil {
		t.Fatal("expected error for non-existent file")
	}
	// Should be ENOENT (not EACCES) since file truly doesn't exist.
	if !strings.Contains(err.Error(), "no such file") {
		t.Errorf("expected ENOENT, got: %v", err)
	}
}

// Verify that os.Stat on the mount root works (important for container startup).
func TestRootStat(t *testing.T) {
	src := setupTestSource(t)

	tr := pathtrie.New()
	tr.Insert("/repo/README.md", pathtrie.ReadAccess, true)

	mnt, cleanup := testMount(t, src, tr, nil)
	defer cleanup()

	info, err := os.Stat(mnt)
	if err != nil {
		t.Fatalf("stat mount root: %v", err)
	}
	if !info.IsDir() {
		t.Error("mount root should be a directory")
	}
}

func TestSymlinkAlwaysDenied(t *testing.T) {
	src := setupTestSource(t)

	tr := pathtrie.New()
	tr.Insert("/repo/out/result.json", pathtrie.WriteAccess, true)

	writePatterns := []string{"/repo/out/**"}

	mnt, cleanup := testMount(t, src, tr, writePatterns)
	defer cleanup()

	// Even in a fully writable directory, symlink creation must be denied.
	linkPath := filepath.Join(mnt, "repo/out/sneaky-link")
	err := os.Symlink("/etc/passwd", linkPath)
	if err == nil {
		t.Fatal("expected error creating symlink, but it succeeded")
	}
	if !strings.Contains(err.Error(), "operation not permitted") && !strings.Contains(err.Error(), "not permitted") {
		// Accept either EPERM text. On Linux, EPERM gives "operation not permitted".
		t.Errorf("expected EPERM, got: %v", err)
	}
}

// TestPermissiveModeBits verifies that directories report 0777 and files
// report 0666 through the FUSE mount, regardless of the source filesystem
// permissions. This is critical for non-root users: the kernel checks the
// inode's StableAttr mode bits before forwarding Create/Mkdir to the FUSE
// daemon, so restrictive source bits cause spurious EACCES.
func TestPermissiveModeBits(t *testing.T) {
	src := setupTestSource(t)

	tr := pathtrie.New()
	tr.Insert("/repo/src/main.py", pathtrie.ReadAccess, true)
	tr.Insert("/repo/out/result.json", pathtrie.WriteAccess, true)

	mnt, cleanup := testMount(t, src, tr, nil)
	defer cleanup()

	// Check directory mode bits.
	dirInfo, err := os.Stat(filepath.Join(mnt, "repo/src"))
	if err != nil {
		t.Fatalf("stat dir: %v", err)
	}
	dirPerm := dirInfo.Mode().Perm()
	if dirPerm != 0777 {
		t.Errorf("directory should have 0777 perms, got %04o", dirPerm)
	}

	// Check file mode bits.
	fileInfo, err := os.Stat(filepath.Join(mnt, "repo/src/main.py"))
	if err != nil {
		t.Fatalf("stat file: %v", err)
	}
	filePerm := fileInfo.Mode().Perm()
	if filePerm != 0666 {
		t.Errorf("file should have 0666 perms, got %04o", filePerm)
	}
}

// TestNonRootWrite verifies that a non-root user can create and write files
// through the FUSE mount. This is the exact scenario that was broken when
// newChild used source filesystem mode bits in StableAttr.
func TestNonRootWrite(t *testing.T) {
	src := setupTestSource(t)

	// Make the source out/ directory world-writable so the underlying
	// syscall.Open in Create succeeds for the nobody user.
	os.Chmod(filepath.Join(src, "repo/out"), 0777)

	tr := pathtrie.New()
	tr.Insert("/repo/out/result.json", pathtrie.WriteAccess, true)

	writePatterns := []string{"/repo/out/**"}

	// Use a world-accessible mount point so nobody can traverse to it.
	// t.TempDir() uses 0700 which blocks non-root users.
	mountDir, err := os.MkdirTemp("/tmp", "fuse-nonroot-test-")
	if err != nil {
		t.Fatal(err)
	}
	os.Chmod(mountDir, 0755)
	defer os.RemoveAll(mountDir)

	rd := &RootData{
		SourceDir:     src,
		Trie:          tr,
		WritePatterns: writePatterns,
		LogDenials:    true,
		Logger:        NewDenialLogger(),
	}
	root := &SecureNode{RootData: rd}
	oneSec := time.Second
	opts := &gofusefs.Options{
		EntryTimeout: &oneSec,
		AttrTimeout:  &oneSec,
	}
	opts.MountOptions.AllowOther = true

	server, err := gofusefs.Mount(mountDir, root, opts)
	if err != nil {
		t.Fatalf("mount: %v", err)
	}
	defer server.Unmount()

	targetFile := filepath.Join(mountDir, "repo/out/nonroot-write-test.txt")

	// Run as nobody (uid 65534). Requires CAP_SETUID in the test container.
	cmd := exec.Command("su", "-s", "/bin/sh", "nobody", "-c",
		"echo nonroot > '"+targetFile+"'")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("non-root write failed: %v\noutput: %s", err, out)
	}

	data, err := os.ReadFile(filepath.Join(src, "repo/out/nonroot-write-test.txt"))
	if err != nil {
		t.Fatalf("reading back non-root file: %v", err)
	}
	if !bytes.Contains(data, []byte("nonroot")) {
		t.Errorf("unexpected content: %s", data)
	}
}

// testMountWithRisk sets up a mount with risk manifest and two-axis thresholds.
func testMountWithRisk(t *testing.T, sourceDir string, trie *pathtrie.Trie, writePatterns []string, manifest map[string]RiskEntry, maxTaint, maxSensitivity string) (mountDir string, cleanup func()) {
	t.Helper()

	if _, err := os.Stat("/dev/fuse"); err != nil {
		t.Skip("FUSE not available (/dev/fuse missing)")
	}

	mountDir = t.TempDir()

	rd := &RootData{
		SourceDir:      sourceDir,
		Trie:           trie,
		WritePatterns:  writePatterns,
		LogDenials:     true,
		Logger:         NewDenialLogger(),
		MaxReadTaint:   maxTaint,
		MaxReadSensitivity: maxSensitivity,
		RiskManifest:   manifest,
	}

	root := &SecureNode{RootData: rd}
	oneSec := time.Second
	opts := &gofusefs.Options{
		EntryTimeout: &oneSec,
		AttrTimeout:  &oneSec,
	}

	server, err := gofusefs.Mount(mountDir, root, opts)
	if err != nil {
		t.Fatalf("mount: %v", err)
	}

	return mountDir, func() {
		server.Unmount()
	}
}

func TestTwoAxisRiskDenyHighTaint(t *testing.T) {
	src := setupTestSource(t)

	tr := pathtrie.New()
	tr.Insert("/repo/src/main.py", pathtrie.ReadAccess, true)

	manifest := map[string]RiskEntry{
		"/repo/src/main.py": {
			TaintLevel:   "high",
			SensitivityLevel: "low",
			RiskLevel:    "high",
			Agent:        "scraper",
			UpdatedAt:    "now",
		},
	}

	// Agent only allows low taint reads
	mnt, cleanup := testMountWithRisk(t, src, tr, nil, manifest, "low", "")
	defer cleanup()

	_, err := os.ReadFile(filepath.Join(mnt, "repo/src/main.py"))
	if err == nil {
		t.Fatal("expected error reading high-taint file with low-taint threshold")
	}
	if !os.IsPermission(err) {
		t.Errorf("expected EACCES, got: %v", err)
	}
}

func TestTwoAxisRiskDenyHighSensitivity(t *testing.T) {
	src := setupTestSource(t)

	tr := pathtrie.New()
	tr.Insert("/repo/src/main.py", pathtrie.ReadAccess, true)

	manifest := map[string]RiskEntry{
		"/repo/src/main.py": {
			TaintLevel:   "low",
			SensitivityLevel: "high",
			RiskLevel:    "high",
			Agent:        "secret-handler",
			UpdatedAt:    "now",
		},
	}

	// Agent only allows low sensitivity reads
	mnt, cleanup := testMountWithRisk(t, src, tr, nil, manifest, "", "low")
	defer cleanup()

	_, err := os.ReadFile(filepath.Join(mnt, "repo/src/main.py"))
	if err == nil {
		t.Fatal("expected error reading high-sensitivity file with low-sensitivity threshold")
	}
	if !os.IsPermission(err) {
		t.Errorf("expected EACCES, got: %v", err)
	}
}

func TestTwoAxisRiskAllowLowBoth(t *testing.T) {
	src := setupTestSource(t)

	tr := pathtrie.New()
	tr.Insert("/repo/src/main.py", pathtrie.ReadAccess, true)

	manifest := map[string]RiskEntry{
		"/repo/src/main.py": {
			TaintLevel:   "low",
			SensitivityLevel: "low",
			RiskLevel:    "low",
			Agent:        "safe-agent",
			UpdatedAt:    "now",
		},
	}

	// Agent allows medium on both axes — low file should be readable
	mnt, cleanup := testMountWithRisk(t, src, tr, nil, manifest, "medium", "medium")
	defer cleanup()

	data, err := os.ReadFile(filepath.Join(mnt, "repo/src/main.py"))
	if err != nil {
		t.Fatalf("reading low-risk file should succeed: %v", err)
	}
	if !bytes.Contains(data, []byte("hello")) {
		t.Errorf("unexpected content: %s", data)
	}
}

func TestTwoAxisRiskIndependentEnforcement(t *testing.T) {
	src := setupTestSource(t)

	tr := pathtrie.New()
	tr.Insert("/repo/src/main.py", pathtrie.ReadAccess, true)

	manifest := map[string]RiskEntry{
		"/repo/src/main.py": {
			TaintLevel:   "low",
			SensitivityLevel: "high",
			RiskLevel:    "high",
			Agent:        "secret-handler",
			UpdatedAt:    "now",
		},
	}

	// Agent allows high taint but only low sensitivity — sensitivity should block
	mnt, cleanup := testMountWithRisk(t, src, tr, nil, manifest, "high", "low")
	defer cleanup()

	_, err := os.ReadFile(filepath.Join(mnt, "repo/src/main.py"))
	if err == nil {
		t.Fatal("expected error: file sensitivity exceeds agent's sensitivity threshold")
	}
	if !os.IsPermission(err) {
		t.Errorf("expected EACCES, got: %v", err)
	}
}

func TestBackwardCompatMaxReadRisk(t *testing.T) {
	src := setupTestSource(t)

	tr := pathtrie.New()
	tr.Insert("/repo/src/main.py", pathtrie.ReadAccess, true)

	manifest := map[string]RiskEntry{
		"/repo/src/main.py": {
			TaintLevel:   "",
			SensitivityLevel: "",
			RiskLevel:    "high",
			Agent:        "legacy-agent",
			UpdatedAt:    "now",
		},
	}

	// No axis-specific thresholds, use legacy MaxReadRisk
	rd := &RootData{
		SourceDir:    src,
		Trie:         tr,
		LogDenials:   true,
		Logger:       NewDenialLogger(),
		MaxReadRisk:  "low",
		RiskManifest: manifest,
	}

	if _, err := os.Stat("/dev/fuse"); err != nil {
		t.Skip("FUSE not available")
	}

	mountDir := t.TempDir()
	root := &SecureNode{RootData: rd}
	oneSec := time.Second
	opts := &gofusefs.Options{
		EntryTimeout: &oneSec,
		AttrTimeout:  &oneSec,
	}
	server, err := gofusefs.Mount(mountDir, root, opts)
	if err != nil {
		t.Fatalf("mount: %v", err)
	}
	defer server.Unmount()

	_, err = os.ReadFile(filepath.Join(mountDir, "repo/src/main.py"))
	if err == nil {
		t.Fatal("expected error: legacy risk exceeds MaxReadRisk threshold")
	}
	if !os.IsPermission(err) {
		t.Errorf("expected EACCES, got: %v", err)
	}
}

// Ensure fuse import is used.
var _ fuse.Server
