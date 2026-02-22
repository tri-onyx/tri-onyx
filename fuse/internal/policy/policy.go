// Package policy handles parsing and expanding TriOnyx filesystem
// access policies. It reads a JSON config file containing glob patterns,
// expands them against a source directory, and produces deduplicated
// path lists for the pathtrie.
package policy

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/bmatcuk/doublestar/v4"
)

// RawPolicy is the on-disk JSON format.
type RawPolicy struct {
	FsRead         []string `json:"fs_read"`
	FsWrite        []string `json:"fs_write"`
	LogDenials     bool     `json:"log_denials"`
	LogWrites      bool     `json:"log_writes"`
	MaxReadRisk    string   `json:"max_read_risk"`              // backward compat
	MaxReadTaint   string   `json:"max_read_taint,omitempty"`   // independent taint threshold
	MaxReadSensitivity string `json:"max_read_sensitivity,omitempty"` // independent sensitivity threshold
}

// Policy contains the expanded, ready-to-use path lists.
type Policy struct {
	ReadPaths        []string // Deduplicated absolute paths (relative to mount root)
	WritePaths       []string
	RawReadPatterns  []string // Original read globs (for dynamic read checks)
	RawWritePatterns []string // Original write globs (for dynamic create checks)
	LogDenials       bool
	LogWrites        bool
	MaxReadRisk        string // backward compat: max(taint, sensitivity) threshold
	MaxReadTaint       string // independent taint threshold for reads
	MaxReadSensitivity string // independent sensitivity threshold for reads
}

// Load reads and parses a JSON policy file. Returns an error on missing
// file or malformed JSON. Missing keys default to empty slices / false.
func Load(configPath string) (*RawPolicy, error) {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil, fmt.Errorf("policy: read config: %w", err)
	}

	var raw RawPolicy
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("policy: parse config: %w", err)
	}
	return &raw, nil
}

// Expand walks sourceDir and matches every path against the raw glob
// patterns. fs_write matches are added to both ReadPaths and WritePaths.
// All returned paths are relative to the source root (with leading /).
func Expand(raw *RawPolicy, sourceDir string) (*Policy, error) {
	sourceDir = filepath.Clean(sourceDir)

	// Collect all relative paths in the source directory.
	allPaths, err := collectPaths(sourceDir)
	if err != nil {
		return nil, fmt.Errorf("policy: walk source: %w", err)
	}

	readSet := make(map[string]struct{})
	writeSet := make(map[string]struct{})

	// Match read patterns.
	for _, pattern := range raw.FsRead {
		pattern = cleanPattern(pattern)
		for _, p := range allPaths {
			if matched, _ := doublestar.Match(pattern, p); matched {
				readSet[p] = struct{}{}
			}
		}
	}

	// Match write patterns. Write implies read.
	for _, pattern := range raw.FsWrite {
		pattern = cleanPattern(pattern)
		for _, p := range allPaths {
			if matched, _ := doublestar.Match(pattern, p); matched {
				writeSet[p] = struct{}{}
				readSet[p] = struct{}{}
			}
		}
	}

	pol := &Policy{
		ReadPaths:        sortedKeys(readSet),
		WritePaths:       sortedKeys(writeSet),
		RawReadPatterns:  expandReadPatterns(raw.FsRead, raw.FsWrite),
		RawWritePatterns: expandWritePatterns(raw.FsWrite),
		LogDenials:       raw.LogDenials,
		LogWrites:        raw.LogWrites,
		MaxReadRisk:      raw.MaxReadRisk,
		MaxReadTaint:     raw.MaxReadTaint,
		MaxReadSensitivity: raw.MaxReadSensitivity,
	}
	return pol, nil
}

// --- helpers ---

// collectPaths walks sourceDir and returns all paths relative to it,
// prefixed with /. Includes both files and directories.
func collectPaths(sourceDir string) ([]string, error) {
	var paths []string

	err := filepath.Walk(sourceDir, func(absPath string, info os.FileInfo, err error) error {
		if err != nil {
			return nil // skip unreadable entries
		}

		rel, err := filepath.Rel(sourceDir, absPath)
		if err != nil {
			return nil
		}

		if rel == "." {
			return nil
		}

		// Normalize to forward slash with leading /
		p := "/" + filepath.ToSlash(rel)
		paths = append(paths, p)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return paths, nil
}

func cleanPattern(p string) string {
	p = strings.TrimSpace(p)
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	return p
}

// expandReadPatterns returns the cleaned read globs (union of fs_read and
// fs_write, since write implies read) for dynamic read checks on files
// created after mount time.
func expandReadPatterns(readPatterns, writePatterns []string) []string {
	var out []string
	for _, p := range readPatterns {
		out = append(out, cleanPattern(p))
	}
	for _, p := range writePatterns {
		out = append(out, cleanPattern(p))
	}
	return out
}

// expandWritePatterns returns the cleaned write patterns plus companion
// patterns for atomic writes. Tools like Claude Code's Write create temp
// files (e.g., .SOUL.md.tmp) and rename them to the target. For each
// literal write path (no glob characters), we add a pattern matching
// temp files in the same directory: dir/.basename.*
func expandWritePatterns(patterns []string) []string {
	var out []string
	for _, p := range patterns {
		p = cleanPattern(p)
		out = append(out, p)

		if !hasGlobChars(p) {
			dir := filepath.Dir(p)
			base := filepath.Base(p)
			// Match temp files like .SOUL.md.tmp, .SOUL.md.12345, etc.
			tempPattern := filepath.Join(dir, "."+base+".*")
			out = append(out, tempPattern)
		}
	}
	return out
}

// hasGlobChars reports whether pattern contains glob metacharacters.
func hasGlobChars(pattern string) bool {
	return strings.ContainsAny(pattern, "*?[{")
}

func sortedKeys(m map[string]struct{}) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
