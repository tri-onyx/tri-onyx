// Package fs implements the TriOnyx FUSE filesystem. It is a passthrough
// filesystem that filters every operation against a pre-computed path trie
// built from the agent's access policy.
package fs

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/tri-onyx/tri-onyx-fs/internal/pathtrie"
	"github.com/tri-onyx/tri-onyx-fs/internal/sanitize"
	"github.com/bmatcuk/doublestar/v4"
	gofusefs "github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

// Compile-time interface checks.
var _ = (gofusefs.NodeLookuper)((*SecureNode)(nil))
var _ = (gofusefs.NodeAccesser)((*SecureNode)(nil))
var _ = (gofusefs.NodeGetattrer)((*SecureNode)(nil))
var _ = (gofusefs.NodeOpendirer)((*SecureNode)(nil))
var _ = (gofusefs.NodeReaddirer)((*SecureNode)(nil))
var _ = (gofusefs.NodeOpener)((*SecureNode)(nil))
var _ = (gofusefs.NodeReader)((*SecureNode)(nil))
var _ = (gofusefs.NodeWriter)((*SecureNode)(nil))
var _ = (gofusefs.NodeCreater)((*SecureNode)(nil))
var _ = (gofusefs.NodeMkdirer)((*SecureNode)(nil))
var _ = (gofusefs.NodeSetattrer)((*SecureNode)(nil))
var _ = (gofusefs.NodeRenamer)((*SecureNode)(nil))
var _ = (gofusefs.NodeUnlinker)((*SecureNode)(nil))
var _ = (gofusefs.NodeRmdirer)((*SecureNode)(nil))
var _ = (gofusefs.NodeSymlinker)((*SecureNode)(nil))
var _ = (gofusefs.NodeLinker)((*SecureNode)(nil))

// RootData holds shared state for the entire mounted filesystem.
type RootData struct {
	SourceDir      string
	Trie           *pathtrie.Trie
	ReadPatterns   []string // raw read globs for dynamic read checks
	WritePatterns  []string // raw write globs for dynamic create checks
	LogDenials     bool
	Logger         *DenialLogger
	LogWrites      bool
	WriteLogger    *WriteLogger
	LogReads       bool
	ReadLogger     *ReadLogger
}

// DenialLogger writes structured JSON denial events to stderr.
type DenialLogger struct {
	mu  sync.Mutex
	enc *json.Encoder
}

// DenialEvent is the structured log entry for denied operations.
type DenialEvent struct {
	Event string `json:"event"`
	Op    string `json:"op"`
	Path  string `json:"path"`
	Mode  string `json:"mode"`
	Time  string `json:"time"`
}

// NewDenialLogger creates a logger that writes to stderr.
func NewDenialLogger() *DenialLogger {
	return &DenialLogger{
		enc: json.NewEncoder(os.Stderr),
	}
}

// Log writes a denial event if logging is enabled.
func (d *DenialLogger) Log(op, path, mode string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.enc.Encode(DenialEvent{
		Event: "denied",
		Op:    op,
		Path:  path,
		Mode:  mode,
		Time:  time.Now().UTC().Format(time.RFC3339),
	})
}

// WriteLogger writes structured JSON write events to stderr.
type WriteLogger struct {
	mu  sync.Mutex
	enc *json.Encoder
}

// WriteEvent is the structured log entry for write operations.
type WriteEvent struct {
	Event string `json:"event"`
	Op    string `json:"op"`
	Path  string `json:"path"`
	Time  string `json:"time"`
}

// NewWriteLogger creates a logger that writes to stderr.
func NewWriteLogger() *WriteLogger {
	return &WriteLogger{
		enc: json.NewEncoder(os.Stderr),
	}
}

// Log writes a write event.
func (w *WriteLogger) Log(op, path string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.enc.Encode(WriteEvent{
		Event: "write",
		Op:    op,
		Path:  path,
		Time:  time.Now().UTC().Format(time.RFC3339),
	})
}

// ReadLogger writes structured JSON read events to stderr. Each unique
// path is logged at most once per mount: the gateway's risk escalation
// is monotonic, so repeat reads of the same path carry no new
// information, and deduplication keeps event volume bounded.
type ReadLogger struct {
	mu   sync.Mutex
	enc  *json.Encoder
	seen map[string]struct{}
}

// ReadEvent is the structured log entry for read operations.
type ReadEvent struct {
	Event string `json:"event"`
	Op    string `json:"op"`
	Path  string `json:"path"`
	Time  string `json:"time"`
}

// NewReadLogger creates a logger that writes to stderr.
func NewReadLogger() *ReadLogger {
	return &ReadLogger{
		enc:  json.NewEncoder(os.Stderr),
		seen: make(map[string]struct{}),
	}
}

// Log writes a read event unless the path was already logged.
func (r *ReadLogger) Log(op, path string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.seen[path]; ok {
		return
	}
	r.seen[path] = struct{}{}
	r.enc.Encode(ReadEvent{
		Event: "read",
		Op:    op,
		Path:  path,
		Time:  time.Now().UTC().Format(time.RFC3339),
	})
}

// SecureNode is a single node in the FUSE tree. Each node holds a pointer
// back to the shared RootData.
type SecureNode struct {
	gofusefs.Inode
	RootData *RootData
}

// mountPath returns this node's path relative to the mount root.
func (n *SecureNode) mountPath() string {
	return "/" + n.Path(n.Root())
}

// sourcePath returns the absolute path on the host filesystem.
func (n *SecureNode) sourcePath() string {
	return filepath.Join(n.RootData.SourceDir, n.Path(n.Root()))
}

// childMountPath returns the mount-relative path for a child name.
func (n *SecureNode) childMountPath(name string) string {
	mp := n.mountPath()
	if mp == "/" {
		return "/" + name
	}
	return mp + "/" + name
}

// childSourcePath returns the host path for a child name.
func (n *SecureNode) childSourcePath(name string) string {
	return filepath.Join(n.sourcePath(), name)
}

// deny logs a denial (if enabled) and returns EACCES.
func (n *SecureNode) deny(op, path, mode string) syscall.Errno {
	return n.denyWith(op, path, mode, syscall.EACCES)
}

// denyWith logs a denial (if enabled) and returns the given errno.
func (n *SecureNode) denyWith(op, path, mode string, errno syscall.Errno) syscall.Errno {
	if n.RootData.LogDenials {
		n.RootData.Logger.Log(op, path, mode)
	}
	return errno
}

// logWrite logs a write event if write logging is enabled.
func (n *SecureNode) logWrite(op, path string) {
	if n.RootData.LogWrites {
		n.RootData.WriteLogger.Log(op, path)
	}
}

// logRead logs a read event if read logging is enabled.
func (n *SecureNode) logRead(op, path string) {
	if n.RootData.LogReads {
		n.RootData.ReadLogger.Log(op, path)
	}
}

// checkAccess returns whether the given path has at least the required level.
func (n *SecureNode) checkAccess(path string, required pathtrie.AccessLevel) bool {
	return n.RootData.Trie.Check(path) >= required
}

// matchPatterns reports whether the path matches any of the raw globs.
func matchPatterns(path string, patterns []string) bool {
	for _, pattern := range patterns {
		if matched, _ := doublestar.Match(pattern, path); matched {
			return true
		}
	}
	return false
}

// checkWriteDynamic checks write access for paths that may not exist in
// the trie (new files/dirs). Falls back to glob matching against raw
// write patterns.
func (n *SecureNode) checkWriteDynamic(path string) bool {
	if n.RootData.Trie.Check(path) >= pathtrie.WriteAccess {
		return true
	}
	// Fall back to glob matching for files not in the trie at startup.
	return matchPatterns(path, n.RootData.WritePatterns)
}

// checkReadDynamic checks read access for paths that may not exist in
// the trie (files created after mount time, e.g., new inbox emails).
// Falls back to glob matching against raw read patterns.
func (n *SecureNode) checkReadDynamic(path string) bool {
	if n.RootData.Trie.Check(path) >= pathtrie.ReadAccess {
		return true
	}
	return matchPatterns(path, n.RootData.ReadPatterns)
}

// canTraverse reports whether the path is visible at all: reachable via
// the static trie (at least Traverse) or via a dynamic read/write glob.
// Every metadata operation (Lookup, Getattr, Access, Opendir, Readdir)
// must use this single check so visibility stays consistent.
func (n *SecureNode) canTraverse(path string) bool {
	return n.checkAccess(path, pathtrie.Traverse) ||
		n.checkReadDynamic(path) ||
		n.checkWriteDynamic(path)
}

// sanitizeMode overrides the permission bits of a stat mode so the kernel
// doesn't pre-check against the host's UID/GID (which won't match the
// container's non-root agent user). Type bits are preserved; real access
// control is enforced by the trie-based checks in each operation handler
// and the Access handler.
func sanitizeMode(mode uint32) uint32 {
	if mode&syscall.S_IFDIR != 0 {
		return (mode & 0xFFFFF000) | 0777
	}
	return (mode & 0xFFFFF000) | 0666
}

// newChild creates a new SecureNode inode for a child.
// We override the permission bits in StableAttr.Mode so the kernel doesn't
// use the source filesystem's mode for permission pre-checks. The inode type
// bits (S_IFDIR, S_IFREG, etc.) are preserved. Real access control is
// enforced by the trie in each operation handler and the Access handler.
func (n *SecureNode) newChild(ctx context.Context, st *syscall.Stat_t) *gofusefs.Inode {
	child := &SecureNode{RootData: n.RootData}
	stable := gofusefs.StableAttr{
		Mode: sanitizeMode(uint32(st.Mode)),
		Ino:  st.Ino,
	}
	return n.NewInode(ctx, child, stable)
}

// --- NodeLookuper ---

func (n *SecureNode) Lookup(ctx context.Context, name string, out *fuse.EntryOut) (*gofusefs.Inode, syscall.Errno) {
	childMount := n.childMountPath(name)
	childSource := n.childSourcePath(name)

	// Check if the file exists on the real filesystem.
	var st syscall.Stat_t
	if err := syscall.Lstat(childSource, &st); err != nil {
		return nil, gofusefs.ToErrno(err) // truly doesn't exist → ENOENT
	}

	// Symlinks are unconditionally denied, mirroring the Symlink handler:
	// the target is opaque, so a pre-existing symlink (e.g. from a git
	// checkout or plugin) would let its logical path pass the trie check
	// while the open resolves somewhere outside the policy. Deny the node
	// entirely so symlinks are invisible through the mount.
	if st.Mode&syscall.S_IFMT == syscall.S_IFLNK {
		return nil, n.deny("lookup", childMount, "symlink")
	}

	// File exists — check if trie allows at least traversal, or if the
	// path matches a read/write pattern (dynamically created files won't
	// be in the trie).
	if !n.canTraverse(childMount) {
		return nil, n.deny("lookup", childMount, "traverse")
	}

	out.Attr.FromStat(&st)
	out.Attr.Mode = sanitizeMode(out.Attr.Mode)

	return n.newChild(ctx, &st), gofusefs.OK
}

// --- NodeAccesser ---

// Access implements the access(2) / faccessat(2) check. Without this
// method the kernel falls back to checking the mode bits returned by
// Getattr, which reflect the *host* UID/GID — not the container user.
// That causes spurious EACCES for the non-root agent user.
//
// We delegate to the trie: F_OK and R_OK require at least Traverse,
// W_OK requires write (static trie or dynamic glob), X_OK requires
// Traverse. This keeps the access(2) result consistent with the actual
// operation handlers (Open, Create, Mkdir, etc.).
func (n *SecureNode) Access(ctx context.Context, mask uint32) syscall.Errno {
	mp := n.mountPath()

	// F_OK — does the file exist? If we got here the inode exists.
	if mask == 0 {
		return gofusefs.OK
	}

	// W_OK (0x2)
	if mask&0x2 != 0 {
		if !n.checkWriteDynamic(mp) {
			return syscall.EACCES
		}
	}

	// R_OK (0x4) and X_OK (0x1) both require visibility.
	if mask&(0x4|0x1) != 0 {
		if !n.canTraverse(mp) {
			return syscall.EACCES
		}
	}

	return gofusefs.OK
}

// --- NodeGetattrer ---

func (n *SecureNode) Getattr(ctx context.Context, f gofusefs.FileHandle, out *fuse.AttrOut) syscall.Errno {
	// If a file handle is available, delegate to it.
	if f != nil {
		if fga, ok := f.(gofusefs.FileGetattrer); ok {
			return fga.Getattr(ctx, out)
		}
	}

	mp := n.mountPath()
	if !n.canTraverse(mp) {
		return n.deny("getattr", mp, "traverse")
	}

	p := n.sourcePath()
	var st syscall.Stat_t
	var err error
	if &n.Inode == n.Root() {
		err = syscall.Stat(p, &st)
	} else {
		err = syscall.Lstat(p, &st)
	}
	if err != nil {
		return gofusefs.ToErrno(err)
	}
	// A symlink may have appeared at this path after the node was looked
	// up (e.g. swapped in on the host side). Symlinks are unconditionally
	// denied — see Lookup.
	if st.Mode&syscall.S_IFMT == syscall.S_IFLNK {
		return n.deny("getattr", mp, "symlink")
	}
	out.FromStat(&st)
	out.Mode = sanitizeMode(out.Mode)

	return gofusefs.OK
}

// --- NodeOpendirer ---

func (n *SecureNode) Opendir(ctx context.Context) syscall.Errno {
	mp := n.mountPath()
	if !n.canTraverse(mp) {
		return n.deny("opendir", mp, "traverse")
	}
	return gofusefs.OK
}

// --- NodeReaddirer ---

func (n *SecureNode) Readdir(ctx context.Context) (gofusefs.DirStream, syscall.Errno) {
	mp := n.mountPath()
	if !n.canTraverse(mp) {
		return nil, n.deny("readdir", mp, "traverse")
	}

	// Get the allowed children from the trie.
	allowed := n.RootData.Trie.Children(mp)

	// Collect trie children into a set for dedup.
	seen := make(map[string]struct{}, len(allowed))
	entries := make([]fuse.DirEntry, 0, len(allowed))
	for _, name := range allowed {
		seen[name] = struct{}{}
		childSource := n.childSourcePath(name)
		var st syscall.Stat_t
		if err := syscall.Lstat(childSource, &st); err != nil {
			continue // skip entries that disappeared from disk
		}
		if st.Mode&syscall.S_IFMT == syscall.S_IFLNK {
			continue // symlinks are unconditionally denied — hide them
		}
		entries = append(entries, fuse.DirEntry{
			Name: name,
			Mode: uint32(st.Mode),
			Ino:  st.Ino,
		})
	}

	// For directories reachable via write patterns (but not fully in the
	// trie), also list host filesystem entries that match write globs.
	// This handles the case where a directory was created at runtime or
	// is empty and thus had no files to populate the trie at startup.
	hostEntries, err := os.ReadDir(n.sourcePath())
	if err == nil {
		for _, de := range hostEntries {
			name := de.Name()
			if _, ok := seen[name]; ok {
				continue // already in trie listing
			}
			childMount := n.childMountPath(name)
			if n.canTraverse(childMount) {
				seen[name] = struct{}{}
				childSource := n.childSourcePath(name)
				var st syscall.Stat_t
				if err := syscall.Lstat(childSource, &st); err != nil {
					continue
				}
				if st.Mode&syscall.S_IFMT == syscall.S_IFLNK {
					continue // symlinks are unconditionally denied — hide them
				}
				entries = append(entries, fuse.DirEntry{
					Name: name,
					Mode: uint32(st.Mode),
					Ino:  st.Ino,
				})
			}
		}
	}

	return gofusefs.NewListDirStream(entries), gofusefs.OK
}

// --- NodeOpener ---

func (n *SecureNode) Open(ctx context.Context, flags uint32) (gofusefs.FileHandle, uint32, syscall.Errno) {
	mp := n.mountPath()

	isWrite := flags&(syscall.O_WRONLY|syscall.O_RDWR|syscall.O_TRUNC|syscall.O_APPEND) != 0
	if isWrite {
		if !n.checkWriteDynamic(mp) {
			return nil, 0, n.deny("open", mp, "write")
		}
	} else {
		if !n.checkReadDynamic(mp) {
			return nil, 0, n.deny("open", mp, "read")
		}
	}

	p := n.sourcePath()
	// O_NOFOLLOW guarantees the final path component is never a symlink,
	// so a pre-existing symlink in the source tree cannot redirect the
	// open to a target outside the policy. Symlinks in *intermediate*
	// components are still resolved by the kernel; the future hardening
	// path is openat2(2) with RESOLVE_BENEATH, which confines the entire
	// resolution to the source dir.
	fd, err := syscall.Open(p, (int(flags)&^syscall.O_APPEND)|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, 0, gofusefs.ToErrno(err)
	}
	if isWrite {
		n.logWrite("open", mp)
	}
	// Any open whose access mode permits reading exposes the file's
	// content to the agent — including O_RDWR write-opens.
	if flags&syscall.O_ACCMODE != uint32(syscall.O_WRONLY) {
		n.logRead("open", mp)
	}
	return gofusefs.NewLoopbackFile(fd), 0, gofusefs.OK
}

// --- NodeReader ---

func (n *SecureNode) Read(ctx context.Context, f gofusefs.FileHandle, dest []byte, off int64) (fuse.ReadResult, syscall.Errno) {
	fr, ok := f.(gofusefs.FileReader)
	if !ok {
		return nil, syscall.ENOTSUP
	}
	res, errno := fr.Read(ctx, dest, off)
	if errno != gofusefs.OK || res == nil {
		return res, errno
	}
	if sanitize.IsBinaryPath(n.mountPath()) {
		return res, gofusefs.OK
	}
	buf := make([]byte, res.Size())
	data, status := res.Bytes(buf)
	if status != fuse.OK {
		return res, syscall.Errno(status)
	}
	res.Done()
	cleaned := sanitize.StripInvisible(data)
	return fuse.ReadResultData(cleaned), gofusefs.OK
}

// --- NodeWriter ---

func (n *SecureNode) Write(ctx context.Context, f gofusefs.FileHandle, data []byte, off int64) (uint32, syscall.Errno) {
	if fw, ok := f.(gofusefs.FileWriter); ok {
		return fw.Write(ctx, data, off)
	}
	return 0, syscall.ENOTSUP
}

// --- NodeCreater ---

func (n *SecureNode) Create(ctx context.Context, name string, flags uint32, mode uint32, out *fuse.EntryOut) (*gofusefs.Inode, gofusefs.FileHandle, uint32, syscall.Errno) {
	childMount := n.childMountPath(name)

	if !n.checkWriteDynamic(childMount) {
		return nil, nil, 0, n.deny("create", childMount, "write")
	}

	childSource := n.childSourcePath(name)
	// O_NOFOLLOW: never follow a pre-existing symlink at the target path
	// (see the comment in Open for the intermediate-component caveat).
	fd, err := syscall.Open(childSource, int(flags)|syscall.O_CREAT|syscall.O_NOFOLLOW, mode)
	if err != nil {
		return nil, nil, 0, gofusefs.ToErrno(err)
	}

	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil {
		syscall.Close(fd)
		return nil, nil, 0, gofusefs.ToErrno(err)
	}

	out.FromStat(&st)
	lf := gofusefs.NewLoopbackFile(fd)
	n.logWrite("create", childMount)
	return n.newChild(ctx, &st), lf, 0, gofusefs.OK
}

// --- NodeMkdirer ---

func (n *SecureNode) Mkdir(ctx context.Context, name string, mode uint32, out *fuse.EntryOut) (*gofusefs.Inode, syscall.Errno) {
	childMount := n.childMountPath(name)

	if !n.checkWriteDynamic(childMount) {
		return nil, n.deny("mkdir", childMount, "write")
	}

	childSource := n.childSourcePath(name)
	if err := os.Mkdir(childSource, os.FileMode(mode)); err != nil {
		return nil, gofusefs.ToErrno(err)
	}

	var st syscall.Stat_t
	if err := syscall.Lstat(childSource, &st); err != nil {
		syscall.Rmdir(childSource)
		return nil, gofusefs.ToErrno(err)
	}

	out.Attr.FromStat(&st)
	n.logWrite("mkdir", childMount)
	return n.newChild(ctx, &st), gofusefs.OK
}

// --- NodeSetattrer ---

func (n *SecureNode) Setattr(ctx context.Context, f gofusefs.FileHandle, in *fuse.SetAttrIn, out *fuse.AttrOut) syscall.Errno {
	mp := n.mountPath()
	if !n.checkWriteDynamic(mp) {
		return n.deny("setattr", mp, "write")
	}

	p := n.sourcePath()

	// Delegate to file handle if available.
	if fsa, ok := f.(gofusefs.FileSetattrer); ok && fsa != nil {
		fsa.Setattr(ctx, in, out)
	} else {
		if m, ok := in.GetMode(); ok {
			if err := syscall.Chmod(p, m); err != nil {
				return gofusefs.ToErrno(err)
			}
		}
		uid, uok := in.GetUID()
		gid, gok := in.GetGID()
		if uok || gok {
			suid, sgid := -1, -1
			if uok {
				suid = int(uid)
			}
			if gok {
				sgid = int(gid)
			}
			if err := syscall.Chown(p, suid, sgid); err != nil {
				return gofusefs.ToErrno(err)
			}
		}
		if sz, ok := in.GetSize(); ok {
			if err := syscall.Truncate(p, int64(sz)); err != nil {
				return gofusefs.ToErrno(err)
			}
		}
	}

	// Return updated attributes.
	if fga, ok := f.(gofusefs.FileGetattrer); ok && fga != nil {
		n.logWrite("setattr", mp)
		return fga.Getattr(ctx, out)
	}
	var st syscall.Stat_t
	if err := syscall.Lstat(p, &st); err != nil {
		return gofusefs.ToErrno(err)
	}
	out.FromStat(&st)
	n.logWrite("setattr", mp)
	return gofusefs.OK
}

// --- NodeRenamer ---

func (n *SecureNode) Rename(ctx context.Context, name string, newParent gofusefs.InodeEmbedder, newName string, flags uint32) syscall.Errno {
	oldMount := n.childMountPath(name)
	if !n.checkWriteDynamic(oldMount) {
		return n.deny("rename", oldMount, "write")
	}

	// Compute new path. The new parent is also a SecureNode.
	newNode, ok := newParent.(*SecureNode)
	if !ok {
		return syscall.EINVAL
	}
	newMount := newNode.childMountPath(newName)
	if !newNode.checkWriteDynamic(newMount) {
		return n.deny("rename", newMount, "write")
	}

	oldSource := n.childSourcePath(name)
	newSource := newNode.childSourcePath(newName)
	if errno := gofusefs.ToErrno(syscall.Rename(oldSource, newSource)); errno != gofusefs.OK {
		return errno
	}
	n.logWrite("rename", oldMount)
	n.logWrite("rename", newMount)
	return gofusefs.OK
}

// --- NodeUnlinker ---

func (n *SecureNode) Unlink(ctx context.Context, name string) syscall.Errno {
	childMount := n.childMountPath(name)
	if !n.checkWriteDynamic(childMount) {
		return n.deny("unlink", childMount, "write")
	}
	if errno := gofusefs.ToErrno(syscall.Unlink(n.childSourcePath(name))); errno != gofusefs.OK {
		return errno
	}
	n.logWrite("unlink", childMount)
	return gofusefs.OK
}

// --- NodeRmdirer ---

func (n *SecureNode) Rmdir(ctx context.Context, name string) syscall.Errno {
	childMount := n.childMountPath(name)
	if !n.checkWriteDynamic(childMount) {
		return n.deny("rmdir", childMount, "write")
	}
	if errno := gofusefs.ToErrno(syscall.Rmdir(n.childSourcePath(name))); errno != gofusefs.OK {
		return errno
	}
	n.logWrite("rmdir", childMount)
	return gofusefs.OK
}

// --- NodeSymlinker ---

// Symlink creation is unconditionally denied. Symlinks bypass path-based
// access control because the target string is opaque -- it can point
// anywhere on the underlying filesystem, including paths outside the
// policy. Returning EPERM removes this attack surface entirely.
func (n *SecureNode) Symlink(ctx context.Context, target, name string, out *fuse.EntryOut) (*gofusefs.Inode, syscall.Errno) {
	return nil, n.denyWith("symlink", n.childMountPath(name), "write", syscall.EPERM)
}

// --- NodeLinker ---

func (n *SecureNode) Link(ctx context.Context, target gofusefs.InodeEmbedder, name string, out *fuse.EntryOut) (*gofusefs.Inode, syscall.Errno) {
	childMount := n.childMountPath(name)
	if !n.checkWriteDynamic(childMount) {
		return nil, n.deny("link", childMount, "write")
	}

	// Also check write on the target.
	targetNode, ok := target.(*SecureNode)
	if !ok {
		return nil, syscall.EINVAL
	}
	targetMount := targetNode.mountPath()
	if !n.checkAccess(targetMount, pathtrie.WriteAccess) {
		return nil, n.deny("link", targetMount, "write")
	}

	childSource := n.childSourcePath(name)
	targetSource := targetNode.sourcePath()
	if err := syscall.Link(targetSource, childSource); err != nil {
		return nil, gofusefs.ToErrno(err)
	}

	var st syscall.Stat_t
	if err := syscall.Lstat(childSource, &st); err != nil {
		syscall.Unlink(childSource)
		return nil, gofusefs.ToErrno(err)
	}

	out.Attr.FromStat(&st)
	n.logWrite("link", childMount)
	return n.newChild(ctx, &st), gofusefs.OK
}
