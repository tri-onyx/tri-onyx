# TODO

## Graph analyzer understates sensitivity on filesystem edges

**Found:** 2026-06-09

Runtime file-read escalation (ADR-011) inherits the file's sensitivity at
full strength, but `GraphAnalyzer.propagate_levels/3` still applies the
per-hop `step_down` on every edge type — so the worst-case projection can
understate sensitivity propagation along filesystem chains relative to
actual runtime behavior. Align the analyzer: full-strength sensitivity on
`:filesystem` edges, keep the decay for `:messaging` and `:bcp` edges
where the intermediary-summarization rationale still applies.
