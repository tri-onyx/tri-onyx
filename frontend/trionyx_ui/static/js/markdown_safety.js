// Pure, dependency-free guards for the client-side markdown renderer
// (chat.js's renderMarkdown, backed by the `marked` library loaded from
// the CDN in base.html).
//
// `marked` renders untrusted agent/tool-result text for the live SSE
// stream, duplicating what views/helpers.render_markdown does for the
// initial page load. Unlike that server-side renderer (markdown-it with
// `html: False`, deliberately chosen so raw HTML is escaped instead of
// passed through), `marked` passes raw HTML straight into the output by
// design and performs no destination-scheme validation on links/images
// at all (its docs explicitly delegate sanitization to the caller). Both
// gaps let a `javascript:` link or a raw `<script>`/`<img onerror=...>`
// tag in agent text or tool-result content execute in the dashboard's
// origin as soon as it streams in over SSE.
//
// These two functions close that gap and are wired into `marked.use()`
// in chat.js: `escapeHtmlText` replaces marked's default (passthrough)
// `html` renderer, and `isSafeLinkUrl` gates `link`/`image` token hrefs
// via `walkTokens` before marked's own (otherwise-unchanged) attribute
// escaping renders them.
(function (root) {
  "use strict";

  function escapeHtmlText(str) {
    return String(str == null ? "" : str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;");
  }

  // Allow-list mirrors markdown-it's default validateLink used on the
  // server-rendered path: http(s)/mailto, plus fragment/relative URLs.
  // Everything else (javascript:, vbscript:, data:, and anything a
  // browser would still recognize after stripping embedded tab/newline
  // tricks) is rejected.
  var SAFE_PROTOCOL_RE = /^(?:https?|mailto):/i;

  function isSafeLinkUrl(href) {
    if (!href) return true;
    var trimmed = String(href).trim().replace(/[\t\n\r]/g, "");
    if (trimmed === "") return true;
    var first = trimmed.charAt(0);
    if (first === "#" || first === "/" || first === ".") return true;
    return SAFE_PROTOCOL_RE.test(trimmed);
  }

  var api = { escapeHtmlText: escapeHtmlText, isSafeLinkUrl: isSafeLinkUrl };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  } else {
    root.MarkdownSafety = api;
  }
})(typeof window !== "undefined" ? window : globalThis);
