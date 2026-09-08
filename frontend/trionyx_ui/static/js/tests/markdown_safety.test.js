// Security property: chat.js's live SSE markdown renderer (the `marked`
// library) must not let agent/tool-result content execute script in the
// dashboard — via a raw HTML tag, or via a markdown link/image whose
// destination uses a script-executing scheme. These are the two guards
// chat.js wires into `marked.use()`; see markdown_safety.js for why.
//
// Run with: node --test frontend/trionyx_ui/static/js/tests/markdown_safety.test.js
// (Node's built-in test runner and assert module only — no npm install.)

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { escapeHtmlText, isSafeLinkUrl } = require("../markdown_safety.js");

test("escapeHtmlText neutralizes a raw <script> tag", () => {
  const out = escapeHtmlText("<script>alert(document.cookie)</script>");
  assert.ok(
    !out.includes("<script>"),
    `expected no live <script> tag in escaped output, got: ${out}`
  );
  assert.equal(out, "&lt;script&gt;alert(document.cookie)&lt;/script&gt;");
});

test("escapeHtmlText neutralizes an event-handler-bearing tag", () => {
  const out = escapeHtmlText('<img src=x onerror=alert(1)>');
  assert.ok(!out.includes("<img"), `expected the <img> tag to be escaped, got: ${out}`);
});

test("escapeHtmlText leaves plain text untouched", () => {
  assert.equal(escapeHtmlText("just plain text"), "just plain text");
});

test("isSafeLinkUrl rejects javascript: destinations regardless of case", () => {
  assert.equal(isSafeLinkUrl("javascript:alert(1)"), false);
  assert.equal(isSafeLinkUrl("JaVaScRiPt:alert(1)"), false);
});

test("isSafeLinkUrl rejects vbscript: and non-image data: destinations", () => {
  assert.equal(isSafeLinkUrl("vbscript:alert(1)"), false);
  assert.equal(isSafeLinkUrl("data:text/html,<script>alert(1)</script>"), false);
});

test("isSafeLinkUrl rejects a scheme hidden behind an embedded tab/newline", () => {
  // A browser strips embedded tab/newline/CR from a URL before parsing
  // its scheme, so "java\tscript:" is executed as "javascript:".
  assert.equal(isSafeLinkUrl("java\tscript:alert(1)"), false);
  assert.equal(isSafeLinkUrl("java\nscript:alert(1)"), false);
});

test("isSafeLinkUrl accepts ordinary http(s)/mailto/relative/fragment destinations", () => {
  assert.equal(isSafeLinkUrl("https://example.com/a?b=1"), true);
  assert.equal(isSafeLinkUrl("http://example.com"), true);
  assert.equal(isSafeLinkUrl("mailto:a@example.com"), true);
  assert.equal(isSafeLinkUrl("/workspace/pages/abc123/report.html"), true);
  assert.equal(isSafeLinkUrl("#section"), true);
  assert.equal(isSafeLinkUrl("./relative"), true);
  assert.equal(isSafeLinkUrl(""), true);
  assert.equal(isSafeLinkUrl(undefined), true);
});
