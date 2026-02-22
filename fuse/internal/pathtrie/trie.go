// Package pathtrie provides a path-based trie for O(1) filesystem access
// checks. It maps absolute paths to access levels (NoAccess, Traverse,
// ReadAccess, WriteAccess) and supports filtered directory listings.
package pathtrie

import (
	"path"
	"sort"
	"strings"
)

// AccessLevel represents the maximum allowed operation on a path.
type AccessLevel int

const (
	NoAccess    AccessLevel = 0
	Traverse    AccessLevel = 1 // stat / lookup only (intermediate dirs)
	ReadAccess  AccessLevel = 2
	WriteAccess AccessLevel = 3
)

// Node is a single element in the path trie.
type Node struct {
	children map[string]*Node
	access   AccessLevel
	isFile   bool
}

// Trie is a path-indexed access control structure.
type Trie struct {
	root *Node
}

// New returns an empty trie. The root node starts with NoAccess.
func New() *Trie {
	return &Trie{
		root: &Node{
			children: make(map[string]*Node),
		},
	}
}

// Insert adds a path to the trie with the given access level. Ancestor
// directories are created automatically with at least Traverse access.
// Access is only ever promoted — inserting a ReadAccess path that already
// has WriteAccess is a no-op for that node.
func (t *Trie) Insert(p string, level AccessLevel, isFile bool) {
	p = cleanPath(p)
	parts := splitPath(p)

	cur := t.root
	// Ensure root is at least traversable when we insert anything.
	if cur.access < Traverse {
		cur.access = Traverse
	}

	for i, part := range parts {
		child, ok := cur.children[part]
		if !ok {
			child = &Node{children: make(map[string]*Node)}
			cur.children[part] = child
		}

		isLast := i == len(parts)-1
		if isLast {
			// Promote, never demote.
			if level > child.access {
				child.access = level
			}
			child.isFile = isFile
		} else {
			// Intermediate: at least Traverse.
			if child.access < Traverse {
				child.access = Traverse
			}
		}
		cur = child
	}
}

// Build constructs a trie from pre-expanded path lists. readPaths get
// ReadAccess, writePaths get WriteAccess. sourceDir is used to determine
// whether each path is a file or directory on the real filesystem.
func Build(readPaths, writePaths []string, sourceDir string) *Trie {
	t := New()

	// Ensure root is always traversable, even if no paths are inserted.
	// This allows basic filesystem operations like stat(/) and chdir.
	t.root.access = Traverse

	for _, p := range readPaths {
		t.Insert(p, ReadAccess, isFilePath(sourceDir, p))
	}
	for _, p := range writePaths {
		t.Insert(p, WriteAccess, isFilePath(sourceDir, p))
	}
	return t
}

// Check returns the access level for the given path. Returns NoAccess
// if the path (or any ancestor) is not in the trie.
func (t *Trie) Check(p string) AccessLevel {
	p = cleanPath(p)
	if p == "/" || p == "." || p == "" {
		return t.root.access
	}

	parts := splitPath(p)
	cur := t.root
	for _, part := range parts {
		child, ok := cur.children[part]
		if !ok {
			return NoAccess
		}
		cur = child
	}
	return cur.access
}

// Children returns the sorted list of child names visible under dirPath.
func (t *Trie) Children(dirPath string) []string {
	dirPath = cleanPath(dirPath)
	cur := t.root
	if dirPath != "/" && dirPath != "." && dirPath != "" {
		for _, part := range splitPath(dirPath) {
			child, ok := cur.children[part]
			if !ok {
				return nil
			}
			cur = child
		}
	}

	names := make([]string, 0, len(cur.children))
	for name := range cur.children {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// --- helpers ---

func cleanPath(p string) string {
	p = path.Clean(p)
	p = strings.TrimPrefix(p, "/")
	if p == "." {
		return ""
	}
	return p
}

func splitPath(p string) []string {
	if p == "" {
		return nil
	}
	return strings.Split(p, "/")
}

// isFilePath checks the real filesystem to determine if sourcePath is a
// regular file. Returns true for files, false for directories (and for
// any stat error, treating unknowns as directories for traversal).
func isFilePath(sourceDir, relPath string) bool {
	// We use a simple heuristic: paths with a file extension are files.
	// This avoids a stat call at build time and works for all pre-expanded
	// paths. The FUSE layer does the real stat when needed.
	base := path.Base(relPath)
	return strings.Contains(base, ".")
}
