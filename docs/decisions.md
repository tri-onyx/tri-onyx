# Architecture Decisions

This page indexes the Architecture Decision Records (ADRs) and key design documents for TriOnyx.

## Design Documents

| Document | Description |
|----------|-------------|
| [Security Model](https://github.com/tri-onyx/tri-onyx/blob/main/adr/SECURITY_MODEL.md) | Three-axis risk model (taint, sensitivity, capability), enforcement layers, violation detection |
| [Architecture](https://github.com/tri-onyx/tri-onyx/blob/main/adr/ARCHITECTURE.md) | System architecture overview |

## Architecture Decision Records

| ADR | Decision |
|-----|----------|
| [001](https://github.com/tri-onyx/tri-onyx/blob/main/adr/001-information-is-the-threat.md) | Information is the threat, not capability |
| [002](https://github.com/tri-onyx/tri-onyx/blob/main/adr/002-elixir-gateway.md) | Elixir/OTP for the gateway |
| [003](https://github.com/tri-onyx/tri-onyx/blob/main/adr/003-python-agent-runtime.md) | Python for the agent runtime and connector |
| [004](https://github.com/tri-onyx/tri-onyx/blob/main/adr/004-go-fuse-driver.md) | Go FUSE driver for filesystem policy enforcement |
| [005](https://github.com/tri-onyx/tri-onyx/blob/main/adr/005-bandwidth-constrained-trust.md) | Bandwidth restriction as taint containment |
| [006](https://github.com/tri-onyx/tri-onyx/blob/main/adr/006-gateway-credential-secrecy.md) | Gateway as sole credential holder with automatic sensitivity |
| [007](https://github.com/tri-onyx/tri-onyx/blob/main/adr/007-biba-blp-violation-detection.md) | Independent Biba and Bell-LaPadula violation detection |
| [008](https://github.com/tri-onyx/tri-onyx/blob/main/adr/008-risk-manifest-provenance.md) | Risk manifest for file-level provenance tracking |
| [009](https://github.com/tri-onyx/tri-onyx/blob/main/adr/009-graph-analysis-transitive-risk.md) | Graph analysis for transitive risk propagation |
| [010](https://github.com/tri-onyx/tri-onyx/blob/main/adr/010-lethal-trifecta.md) | The lethal trifecta -- taint, sensitivity, and capability |
