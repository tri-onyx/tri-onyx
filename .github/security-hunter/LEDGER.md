# Security hunter ledger

- 2026-11-20 | FIXED     | repo-store  | Keep agent-planted nested git repos out of the index so gateway git never runs their config (fsmonitor / clean filter RCE as the gateway) | lib/tri_onyx/repo_store.ex
- 2026-11-20 | DOWNGRADED| connectors  | GitHub connector runs git/gh with GH_TOKEN in env inside data/github/<repo>, which is mounted rw (incl. .git/) into the agent at /github/<repo>; an agent-written .git/config (core.fsmonitor, hooks, core.sshCommand) would run on the gateway — needs a design decision (separate gitdir like RepoStore) | lib/tri_onyx/connectors/github.ex
- 2026-11-20 | DOWNGRADED| repo-store  | Shared repo names "agents" and "self" pass @repo_name_pattern but collide with reserved tree paths (trees/_ro/agents is the parent of every agent _ro checkout; trees/<agent>/self is the agent's own tree); only reachable by a definition author, who can already grant agents/* | lib/tri_onyx/agent_definition.ex
