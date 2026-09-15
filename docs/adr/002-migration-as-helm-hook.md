# 002 — Express the schema migration as a Helm hook, and as nothing else

- **Status:** Accepted
- **Date:** 2026-09-15

## Context

[ADR 001](001-argocd-vs-flux.md) establishes that the two engines differ most in
how they turn a Helm chart into running objects. The schema migration is where
that difference becomes observable, so how the migration is expressed decides
whether the bench measures the engines or measures the manifest.

Argo CD translates Helm hooks into its own hook model, but the translation is
conditional. Its documentation is explicit:

> "If you define any Argo CD hooks, all Helm hooks will be ignored."
> — [Argo CD user guide, Helm](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/)

So a single `argocd.argoproj.io/hook` annotation on the migration Job would mean
the two engines are reading two different sets of instructions, and any observed
divergence would be an artefact of the annotations.

## Decision

**The migration Job carries `helm.sh/*` annotations only. No
`argocd.argoproj.io/*` annotation appears anywhere in the chart.**

```yaml
"helm.sh/hook": post-install,pre-upgrade
"helm.sh/hook-weight": "-5"
"helm.sh/hook-delete-policy": before-hook-creation
```

Both engines consume that identical manifest and diverge only in execution:

| | Argo CD 3.5.3 | Flux 2.9.5 |
|---|---|---|
| How the hook runs | `helm template` renders it; Argo CD maps `post-install`/`pre-upgrade` to `PostSync`/`PreSync` and `hook-weight` to a sync-wave, then applies it itself | Helm itself runs it, inside a real `helm upgrade` |
| Helm release afterwards | none | yes, with history |
| Undo path | `argocd app rollback` over Git history | `helm rollback` / `.spec.upgrade.remediation` |
| `pre-rollback` / `post-rollback` hooks | **ignored — unsupported** | executed |

## Why `post-install` and not `pre-install`

This was wrong in the first draft, and the smoke test caught it.

Helm runs `pre-install` hooks **before it creates any of the chart's normal
resources**. On a first install there is therefore no PostgreSQL Service and no
StatefulSet yet, and a migration hooked on `pre-install` waits for a database
that does not exist until `activeDeadlineSeconds` kills the Job. Observed
directly: during the `pre-install` phase the namespace contained exactly one
object, the migration Job itself.

`post-install` runs once PostgreSQL exists. `pre-upgrade` runs before the new
application pods roll, which is when a schema change must land. The pair covers
both cases correctly.

## Why readiness checks connectivity only

`GET /readyz` executes `SELECT 1`, not a query against the migrated table.

Helm waits for the Deployment to become ready **before** running `post-install`
hooks. A readiness probe that required the migrated schema would therefore
deadlock the first install: the pod waits for the migration, and the migration
waits for the pod. Liveness does not touch the database at all, so a database
incident cannot escalate into an application restart loop.

The cost is a window, on first install only, where the API is in the Service but
`/tickets` fails because the table does not exist yet. That is accepted: the
alternative is an install that never completes.

## Consequences

- The chart cannot use any Argo CD-specific sync behaviour — sync options,
  selective sync waves on non-hook resources, `Replace=true`. Argo CD is
  therefore not shown at its most expressive. That is the price of a fair bench,
  and it is stated in the README rather than hidden.
- `pre-rollback` and `post-rollback` hooks are unusable, because Argo CD ignores
  them. Rollback behaviour has to be compared through each engine's own
  mechanism instead of a shared one.
- A deliberately failing migration is available behind
  `migration.failOnPurpose=true`, so the two engines can be compared on failure
  and not only on the happy path.

## A Helm 4 hazard this surfaced, carried into session 3

Helm 4 replaced the boolean `--wait` with a strategy: `watcher`, `hookOnly` or
`legacy`. Under the `watcher` strategy — what plain `--wait` selects — Helm did
not observe this hook Job completing: the Job reached `Complete` with
`succeeded: 1` in six seconds while Helm waited until its timeout, nineteen
minutes later. `--wait=legacy` returns in under twenty seconds. `make smoke`
pins `legacy` for that reason.

This matters beyond the smoke test. Flux 2.9.5 ships helm-controller v1.6.4,
which links `helm.sh/helm/v4 v4.2.4` — the same generation of the Helm SDK. If
helm-controller waits on hook Jobs through the same code path, a HelmRelease
carrying this Job could stall the same way. **Verify this explicitly when the
Flux control plane is wired up in session 3**, and treat a stall as a suspected
upstream issue rather than a chart defect.

## Alternatives considered

**Put the migration in an init container on the API Deployment.** Rejected. With
more than one replica, every pod races to migrate the same schema, and there is
no single place to observe success or failure. It would also erase the
divergence this bench exists to show, since there would be no hook at all.

**Annotate PostgreSQL as a hook too, with a lower weight, so `pre-install` could
work.** Rejected. It makes a database part of the hook lifecycle, where a
`before-hook-creation` delete policy would drop and recreate it on every
upgrade. Defensible in a lab, indefensible as a pattern, and the repository
should not teach it.

**Run migrations from the application at startup.** Rejected. It couples schema
changes to pod restarts, gives no failure surface a GitOps engine can act on,
and is exactly the anti-pattern this bench is meant to examine.
