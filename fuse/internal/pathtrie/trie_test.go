package pathtrie

import (
	"testing"
)

func TestEmptyTrie(t *testing.T) {
	tr := New()
	if got := tr.Check("/anything"); got != NoAccess {
		t.Errorf("empty trie: Check(/anything) = %d, want NoAccess", got)
	}
	if got := tr.Check("/"); got != NoAccess {
		t.Errorf("empty trie: Check(/) = %d, want NoAccess", got)
	}
}

func TestSingleInsertRead(t *testing.T) {
	tr := New()
	tr.Insert("/repo/src/main.py", ReadAccess, true)

	tests := []struct {
		path string
		want AccessLevel
	}{
		{"/", Traverse},
		{"/repo", Traverse},
		{"/repo/src", Traverse},
		{"/repo/src/main.py", ReadAccess},
		{"/repo/src/other.py", NoAccess},
		{"/other", NoAccess},
	}
	for _, tt := range tests {
		if got := tr.Check(tt.path); got != tt.want {
			t.Errorf("Check(%q) = %d, want %d", tt.path, got, tt.want)
		}
	}
}

func TestWriteDoesNotDowngrade(t *testing.T) {
	tr := New()
	tr.Insert("/repo/out/data.json", WriteAccess, true)
	tr.Insert("/repo/out/data.json", ReadAccess, true) // lower level after

	if got := tr.Check("/repo/out/data.json"); got != WriteAccess {
		t.Errorf("should not downgrade: got %d, want WriteAccess", got)
	}
}

func TestWritePromotesRead(t *testing.T) {
	tr := New()
	tr.Insert("/repo/out/data.json", ReadAccess, true)
	tr.Insert("/repo/out/data.json", WriteAccess, true)

	if got := tr.Check("/repo/out/data.json"); got != WriteAccess {
		t.Errorf("should promote: got %d, want WriteAccess", got)
	}
}

func TestChildrenFiltering(t *testing.T) {
	tr := New()
	tr.Insert("/repo/src/a.py", ReadAccess, true)
	tr.Insert("/repo/src/b.py", ReadAccess, true)
	tr.Insert("/repo/docs/readme.md", ReadAccess, true)

	// Root children
	rootKids := tr.Children("/")
	if len(rootKids) != 1 || rootKids[0] != "repo" {
		t.Errorf("root children = %v, want [repo]", rootKids)
	}

	// /repo children
	repoKids := tr.Children("/repo")
	if len(repoKids) != 2 || repoKids[0] != "docs" || repoKids[1] != "src" {
		t.Errorf("/repo children = %v, want [docs src]", repoKids)
	}

	// /repo/src children
	srcKids := tr.Children("/repo/src")
	if len(srcKids) != 2 || srcKids[0] != "a.py" || srcKids[1] != "b.py" {
		t.Errorf("/repo/src children = %v, want [a.py b.py]", srcKids)
	}

	// Non-existent dir
	noKids := tr.Children("/nonexistent")
	if len(noKids) != 0 {
		t.Errorf("nonexistent children = %v, want []", noKids)
	}
}

func TestDeepPaths(t *testing.T) {
	tr := New()
	tr.Insert("/a/b/c/d/e/f.txt", ReadAccess, true)

	// Every ancestor should be Traverse
	for _, p := range []string{"/", "/a", "/a/b", "/a/b/c", "/a/b/c/d", "/a/b/c/d/e"} {
		if got := tr.Check(p); got != Traverse {
			t.Errorf("Check(%q) = %d, want Traverse", p, got)
		}
	}
	if got := tr.Check("/a/b/c/d/e/f.txt"); got != ReadAccess {
		t.Errorf("Check(leaf) = %d, want ReadAccess", got)
	}
}

func TestBuild(t *testing.T) {
	readPaths := []string{"/src/main.py", "/src/lib/util.py"}
	writePaths := []string{"/out/result.json"}

	tr := Build(readPaths, writePaths, "/fake")

	if got := tr.Check("/src/main.py"); got != ReadAccess {
		t.Errorf("read path: got %d, want ReadAccess", got)
	}
	if got := tr.Check("/out/result.json"); got != WriteAccess {
		t.Errorf("write path: got %d, want WriteAccess", got)
	}
	if got := tr.Check("/src"); got != Traverse {
		t.Errorf("intermediate: got %d, want Traverse", got)
	}
}

func TestBuildEmptyPaths(t *testing.T) {
	// Build a trie with no paths — simulates empty source dir or
	// glob patterns that match nothing.
	tr := Build(nil, nil, "/fake")

	// Root must be traversable even with no paths.
	if got := tr.Check("/"); got != Traverse {
		t.Errorf("empty trie from Build: Check(/) = %d, want Traverse", got)
	}

	// Children should return empty list, not nil.
	children := tr.Children("/")
	if children == nil || len(children) != 0 {
		t.Errorf("empty trie children = %v, want empty slice []", children)
	}

	// Any other path should still be NoAccess.
	if got := tr.Check("/anything"); got != NoAccess {
		t.Errorf("empty trie: Check(/anything) = %d, want NoAccess", got)
	}
}

func TestNonExistentLookups(t *testing.T) {
	tr := New()
	tr.Insert("/repo/a.py", ReadAccess, true)

	tests := []string{
		"/repo/b.py",
		"/repo/a.py/child",
		"/completely/different",
		"/repo/a.pyc",
	}
	for _, p := range tests {
		if got := tr.Check(p); got != NoAccess {
			t.Errorf("Check(%q) = %d, want NoAccess", p, got)
		}
	}
}

func TestRootOnlyAccess(t *testing.T) {
	tr := New()
	// Insert at root level
	tr.Insert("/file.txt", ReadAccess, true)

	if got := tr.Check("/"); got != Traverse {
		t.Errorf("Check(/) = %d, want Traverse", got)
	}
	if got := tr.Check("/file.txt"); got != ReadAccess {
		t.Errorf("Check(/file.txt) = %d, want ReadAccess", got)
	}
}
