package policy

import (
	"os"
	"path/filepath"
	"sort"
	"testing"
)

// helper: create a temp dir with files matching a layout.
func setupSource(t *testing.T, files []string) string {
	t.Helper()
	dir := t.TempDir()
	for _, f := range files {
		abs := filepath.Join(dir, filepath.FromSlash(f))
		if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(abs, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func writePolicy(t *testing.T, content string) string {
	t.Helper()
	f := filepath.Join(t.TempDir(), "policy.json")
	if err := os.WriteFile(f, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return f
}

func TestLoadValid(t *testing.T) {
	f := writePolicy(t, `{"fs_read":["/a"],"fs_write":["/b"],"log_denials":true}`)
	raw, err := Load(f)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw.FsRead) != 1 || raw.FsRead[0] != "/a" {
		t.Errorf("FsRead = %v", raw.FsRead)
	}
	if len(raw.FsWrite) != 1 || raw.FsWrite[0] != "/b" {
		t.Errorf("FsWrite = %v", raw.FsWrite)
	}
	if !raw.LogDenials {
		t.Error("LogDenials should be true")
	}
}

func TestLoadTwoAxisFields(t *testing.T) {
	f := writePolicy(t, `{
		"fs_read":["/a"],
		"max_read_risk":"high",
		"max_read_taint":"medium",
		"max_read_sensitivity":"low"
	}`)
	raw, err := Load(f)
	if err != nil {
		t.Fatal(err)
	}
	if raw.MaxReadRisk != "high" {
		t.Errorf("MaxReadRisk = %q, want high", raw.MaxReadRisk)
	}
	if raw.MaxReadTaint != "medium" {
		t.Errorf("MaxReadTaint = %q, want medium", raw.MaxReadTaint)
	}
	if raw.MaxReadSensitivity != "low" {
		t.Errorf("MaxReadSensitivity = %q, want low", raw.MaxReadSensitivity)
	}
}

func TestExpandPreservesTwoAxisFields(t *testing.T) {
	src := t.TempDir()
	raw := &RawPolicy{
		FsRead:         []string{"/a"},
		MaxReadTaint:   "medium",
		MaxReadSensitivity: "low",
	}
	pol, err := Expand(raw, src)
	if err != nil {
		t.Fatal(err)
	}
	if pol.MaxReadTaint != "medium" {
		t.Errorf("Policy.MaxReadTaint = %q, want medium", pol.MaxReadTaint)
	}
	if pol.MaxReadSensitivity != "low" {
		t.Errorf("Policy.MaxReadSensitivity = %q, want low", pol.MaxReadSensitivity)
	}
}

func TestLoadMissingKeys(t *testing.T) {
	f := writePolicy(t, `{}`)
	raw, err := Load(f)
	if err != nil {
		t.Fatal(err)
	}
	if raw.FsRead != nil && len(raw.FsRead) != 0 {
		t.Errorf("expected empty FsRead, got %v", raw.FsRead)
	}
	if raw.FsWrite != nil && len(raw.FsWrite) != 0 {
		t.Errorf("expected empty FsWrite, got %v", raw.FsWrite)
	}
	if raw.LogDenials {
		t.Error("LogDenials should default to false")
	}
}

func TestLoadMissingFile(t *testing.T) {
	_, err := Load("/nonexistent/policy.json")
	if err == nil {
		t.Error("expected error for missing file")
	}
}

func TestLoadMalformedJSON(t *testing.T) {
	f := writePolicy(t, `{not json}`)
	_, err := Load(f)
	if err == nil {
		t.Error("expected error for malformed JSON")
	}
}

func TestExpandDoubleStarGlob(t *testing.T) {
	src := setupSource(t, []string{
		"repo/src/main.py",
		"repo/src/lib/util.py",
		"repo/src/lib/deep/nested.py",
		"repo/README.md",
		"repo/src/data.csv",
	})

	raw := &RawPolicy{
		FsRead: []string{"/repo/**/*.py"},
	}
	pol, err := Expand(raw, src)
	if err != nil {
		t.Fatal(err)
	}

	expected := []string{
		"/repo/src/lib/deep/nested.py",
		"/repo/src/lib/util.py",
		"/repo/src/main.py",
	}
	if !strSliceEqual(pol.ReadPaths, expected) {
		t.Errorf("ReadPaths = %v, want %v", pol.ReadPaths, expected)
	}
	if len(pol.WritePaths) != 0 {
		t.Errorf("WritePaths should be empty, got %v", pol.WritePaths)
	}
}

func TestWriteImpliesRead(t *testing.T) {
	src := setupSource(t, []string{
		"out/result.json",
		"out/log.txt",
	})

	raw := &RawPolicy{
		FsWrite: []string{"/out/**"},
	}
	pol, err := Expand(raw, src)
	if err != nil {
		t.Fatal(err)
	}

	// Both files (and the directory matched by **) should be in WritePaths and ReadPaths
	sort.Strings(pol.WritePaths)
	sort.Strings(pol.ReadPaths)

	expectedWrite := []string{"/out", "/out/log.txt", "/out/result.json"}
	if !strSliceEqual(pol.WritePaths, expectedWrite) {
		t.Errorf("WritePaths = %v, want %v", pol.WritePaths, expectedWrite)
	}
	if !strSliceEqual(pol.ReadPaths, expectedWrite) {
		t.Errorf("ReadPaths = %v, want %v", pol.ReadPaths, expectedWrite)
	}
}

func TestDotfiles(t *testing.T) {
	src := setupSource(t, []string{
		"repo/.env",
		"repo/.gitignore",
		"repo/src/main.py",
	})

	raw := &RawPolicy{
		FsRead: []string{"/repo/**"},
	}
	pol, err := Expand(raw, src)
	if err != nil {
		t.Fatal(err)
	}

	// doublestar's ** should match dotfiles
	found := make(map[string]bool)
	for _, p := range pol.ReadPaths {
		found[p] = true
	}
	if !found["/repo/.env"] {
		t.Error(".env should be matched by /repo/**")
	}
	if !found["/repo/.gitignore"] {
		t.Error(".gitignore should be matched by /repo/**")
	}
}

func TestEmptySource(t *testing.T) {
	src := t.TempDir() // empty directory

	raw := &RawPolicy{
		FsRead: []string{"/repo/**/*.py"},
	}
	pol, err := Expand(raw, src)
	if err != nil {
		t.Fatal(err)
	}
	if len(pol.ReadPaths) != 0 {
		t.Errorf("expected empty ReadPaths, got %v", pol.ReadPaths)
	}
}

func TestRawWritePatternsPreserved(t *testing.T) {
	src := t.TempDir()

	raw := &RawPolicy{
		FsWrite: []string{"/out/**", "/tmp/*.log"},
	}
	pol, err := Expand(raw, src)
	if err != nil {
		t.Fatal(err)
	}
	expected := []string{"/out/**", "/tmp/*.log"}
	if !strSliceEqual(pol.RawWritePatterns, expected) {
		t.Errorf("RawWritePatterns = %v, want %v", pol.RawWritePatterns, expected)
	}
}

func strSliceEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
