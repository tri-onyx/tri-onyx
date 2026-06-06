// Package sanitize strips invisible Unicode characters from byte slices.
// These characters can be used to hide prompt injection payloads in files
// that appear clean to human reviewers but are parsed by LLMs.
package sanitize

import (
	"path/filepath"
	"strings"
	"unicode/utf8"
)

var binaryExtensions = map[string]bool{
	".png": true, ".jpg": true, ".jpeg": true, ".gif": true, ".webp": true,
	".bmp": true, ".ico": true, ".tiff": true, ".tif": true, ".svg": true,
	".pdf": true, ".zip": true, ".gz": true, ".tar": true, ".bz2": true,
	".xz": true, ".7z": true, ".rar": true, ".zst": true,
	".wasm": true, ".so": true, ".dylib": true, ".dll": true, ".exe": true,
	".o": true, ".a": true, ".pyc": true, ".class": true,
	".mp3": true, ".mp4": true, ".wav": true, ".ogg": true, ".flac": true,
	".avi": true, ".mkv": true, ".mov": true, ".webm": true,
	".ttf": true, ".otf": true, ".woff": true, ".woff2": true, ".eot": true,
	".sqlite": true, ".db": true,
}

// IsBinaryPath reports whether the file at path is likely binary based on its
// extension. Binary files must not be sanitized — stripping bytes corrupts them.
func IsBinaryPath(path string) bool {
	return binaryExtensions[strings.ToLower(filepath.Ext(path))]
}

// blocked reports whether a rune should be stripped from read data.
func blocked(r rune) bool {
	switch {
	// Zero-width and invisible formatting
	case r == 0x00AD: // Soft Hyphen
		return true
	case r == 0x034F: // Combining Grapheme Joiner
		return true
	case r == 0x061C: // Arabic Letter Mark
		return true
	case r == 0x180E: // Mongolian Vowel Separator
		return true
	case r == 0x200B: // Zero Width Space
		return true
	case r == 0x200C: // Zero Width Non-Joiner
		return true
	case r == 0x200D: // Zero Width Joiner
		return true
	case r == 0x2060: // Word Joiner
		return true
	case r == 0xFEFF: // BOM (handled specially by caller for offset 0)
		return true

	// BiDi overrides (Trojan Source attack vector)
	case r >= 0x202A && r <= 0x202E: // LRE, RLE, PDF, LRO, RLO
		return true
	case r >= 0x2066 && r <= 0x2069: // LRI, RLI, FSI, PDI
		return true

	// Invisible math operators
	case r >= 0x2061 && r <= 0x2064:
		return true

	// Deprecated formatting characters
	case r >= 0x206A && r <= 0x206F:
		return true

	// Tag characters (can encode hidden ASCII text)
	case r >= 0xE0001 && r <= 0xE007F:
		return true
	}
	return false
}

// StripInvisible removes invisible Unicode characters from data.
// If the first bytes are a UTF-8 BOM (EF BB BF), that leading BOM is
// preserved; any BOM occurring later is stripped.
//
// If data contains no blocked characters, the original slice is returned
// with no allocation. Invalid UTF-8 sequences pass through unchanged.
func StripInvisible(data []byte) []byte {
	// Fast path: scan for any blocked rune. Most reads contain none.
	hasBOM := len(data) >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF
	pos := 0
	if hasBOM {
		pos = 3 // skip leading BOM in the scan
	}

	needsClean := false
	scan := data[pos:]
	for len(scan) > 0 {
		r, size := utf8.DecodeRune(scan)
		if r != utf8.RuneError && blocked(r) {
			needsClean = true
			break
		}
		scan = scan[size:]
	}
	if !needsClean {
		return data
	}

	// Slow path: rebuild without blocked runes.
	out := make([]byte, 0, len(data))
	if hasBOM {
		out = append(out, 0xEF, 0xBB, 0xBF)
		pos = 3
	} else {
		pos = 0
	}

	rest := data[pos:]
	for len(rest) > 0 {
		r, size := utf8.DecodeRune(rest)
		if r == utf8.RuneError || !blocked(r) {
			out = append(out, rest[:size]...)
		}
		rest = rest[size:]
	}
	return out
}
