// Security property: the dependency-graph view's D3 tooltips (graph.js)
// build markup via raw template-literal `innerHTML`. Two agent-definition
// fields reach those tooltips after only a superficial gateway-side check
// ("is a string", "starts with claude-") with no HTML/format validation:
// `model` and each entry of a `network` hostname allow-list. Anyone who
// can set an agent's definition — the builder UI, or another agent with a
// `repos_write` grant on the shared repo the definitions live in — must
// not be able to turn that into script execution in the operator's
// dashboard just by hovering the node.
//
// Run with: node --test frontend/trionyx_ui/static/js/tests/graph_safety.test.js
// (Node's built-in test runner and assert module only — no npm install.)

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { escapeHtml, formatNetwork } = require("../graph_safety.js");

test("escapeHtml neutralizes a raw <script> tag", () => {
  const out = escapeHtml("<script>alert(document.cookie)</script>");
  assert.ok(!out.includes("<script>"), `expected no live <script> tag, got: ${out}`);
  assert.equal(out, "&lt;script&gt;alert(document.cookie)&lt;/script&gt;");
});

test("formatNetwork escapes each hostname in an allow-list", () => {
  // AgentDefinition.parse_network (lib/tri_onyx/agent_definition.ex) only
  // requires the list to be strings without "*" — it never validates that
  // each entry is a syntactically valid hostname.
  const out = formatNetwork(['<img src=x onerror=alert(1)>', 'api.example.com']);
  assert.ok(
    !out.includes("<img"),
    `expected the malicious hostname entry to be escaped, got: ${out}`
  );
  assert.equal(out, "&lt;img src=x onerror=alert(1)&gt;, api.example.com");
});

test("formatNetwork keeps the isolated/outbound badges intact", () => {
  assert.equal(formatNetwork("none"), '<span style="color:var(--green)">isolated</span>');
  assert.equal(formatNetwork(null), '<span style="color:var(--green)">isolated</span>');
  assert.equal(formatNetwork("outbound"), '<span style="color:var(--purple)">outbound (unrestricted)</span>');
});

test("formatNetwork escapes an ordinary hostname list without altering it", () => {
  assert.equal(formatNetwork(["a.example.com", "b.example.com"]), "a.example.com, b.example.com");
});
