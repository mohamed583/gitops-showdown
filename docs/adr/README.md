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
| [002](002-migration-as-helm-hook.md) | Express the schema migration as a Helm hook, and as nothing else | Accepted |
| [003](003-two-clusters.md) | Two separate clusters, not two namespaces | Accepted |
| [004](004-local-git-server.md) | A local Git server, on the kind Docker network | Accepted |
| [005](005-secrets-management.md) | Secrets: what this bench does, and what it refuses to pretend | Accepted |

Records are numbered in the order decisions are made. This index lists only what
exists.
