# Architecture Decision Records

This directory records the decisions that shape gitops-showdown, and — more
importantly — the reasoning and the alternatives that were rejected. A decision
without its rejected alternatives is just a preference.

## Format

A trimmed-down [MADR](https://adr.github.io/madr/). Every record has:

| Section | Purpose |
|---|---|
| **Status** | `Proposed` · `Accepted` · `Superseded by NNN` |
| **Context** | The forces in play. What makes this a real question. |
| **Decision** | One sentence, in the active voice. |
| **Consequences** | What this costs. Negative consequences are mandatory. |
| **Alternatives considered** | What was rejected, and why. |

Two rules keep these honest:

1. **Every factual claim is sourced.** Version support matrices, behavioural
   differences between the two engines, API guarantees — each carries a link to
   upstream documentation or source, not to a blog post.
2. **Experience is labelled.** Where a record relies on something the author has
   run in production, it says so. Where it relies on documentation and this lab
   only, it says that instead. See ADR 001.

## Index

| # | Title | Status |
|---|---|---|
| [001](001-argocd-vs-flux.md) | Compare Argo CD and Flux on one shared Helm chart | Accepted |

Records 002–005 (cluster topology, the migration Job as the divergence point,
the local Git server, secrets management) are written as the corresponding code
lands. This index lists only what exists.
