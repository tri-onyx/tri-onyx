// Pure, dependency-free HTML-escaping guard for the dependency-graph
// view's D3 tooltips (graph.js), which build tooltip markup with raw
// template-literal `innerHTML` rather than the DOM API.
//
// Most tooltip fields are either gateway-owned vocabulary (risk/taint
// levels, agent ids — validated against AgentDefinition's strict
// `@name_pattern`) or already escaped before interpolation (description,
// paths). Two fields are NOT format-validated by the gateway beyond
// "is a string":
//   - `model` (AgentDefinition.parse_model only requires a "claude-"
//     prefix — anything after it is free text)
//   - each entry of a `network` hostname allow-list
//     (AgentDefinition.parse_network only checks the list is all
//     binaries and rejects "*" — no hostname-format check at all)
// Anyone who can set an agent's definition — the builder UI, or another
// agent holding a `repos_write` grant on the shared repo the definition
// files live in — can put arbitrary HTML/script in either field. It
// previously rendered unescaped as soon as an operator hovered that
// agent's node in the graph view, executing in the dashboard's origin.
(function (root) {
  "use strict";

  function escapeHtml(str) {
    return String(str == null ? "" : str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function formatNetwork(n) {
    if (!n || n === "none") return '<span style="color:var(--green)">isolated</span>';
    if (n === "outbound") return '<span style="color:var(--purple)">outbound (unrestricted)</span>';
    if (Array.isArray(n)) return n.map(escapeHtml).join(", ");
    return escapeHtml(String(n));
  }

  var api = { escapeHtml: escapeHtml, formatNetwork: formatNetwork };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  } else {
    root.GraphSafety = api;
  }
})(typeof window !== "undefined" ? window : globalThis);
