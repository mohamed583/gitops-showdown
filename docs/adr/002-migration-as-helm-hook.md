# 002 — Express the schema migration as a Helm hook, and as nothing else

- **Status:** Accepted
- **Date:** 2026-09-15, revised 2026-09-16 with results from running both engines

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

Both engines consume that identical manifest and diverge only in execution.
Measured on this bench, same chart, same commit, same application:

| | Argo CD 3.5.3 | Flux 2.9.5 |
|---|---|---|
| How the hook runs | `helm template` renders it; Argo CD maps the Helm hook to its own phase and applies it | Helm itself runs it, inside a real `helm install`/`upgrade` |
| `helm list` in the app namespace | **empty** | `ticketflow`, revision 1 |
| Helm release storage Secrets | **0** | 1 (`sh.helm.release.v1.ticketflow.v1`) |
| Undo path | `argocd app rollback` over Git history | `helm rollback` / `.spec.upgrade.remediation` |
| `pre-rollback` / `post-rollback` hooks | **ignored — unsupported** | executed |

`make diverge` prints the first three rows from the live clusters.

## Never `pre-install`

Helm runs `pre-install` hooks **before it creates any of the chart's normal
resources**. On a first install there is therefore no PostgreSQL Service and no
StatefulSet yet, and a migration hooked on `pre-install` waits for a database
that does not exist until `activeDeadlineSeconds` kills the Job. Observed
directly: during the `pre-install` phase the namespace contained exactly one
object, the migration Job itself.

## Why the hook phase had to become a chart value

The textbook choice is `post-install,pre-upgrade`: migrate after the database
exists on first install, and before the new pods roll on every upgrade. Flux
honours exactly that, because helm-controller runs a real Helm install or
upgrade and Helm knows which one it is performing.

**Argo CD has no such distinction, and this deadlocks the first sync.** It
translates `pre-upgrade` to `PreSync` and runs it on *every* sync, including the
very first — before PostgreSQL exists, because PostgreSQL is created in the
`Sync` phase that `PreSync` is blocking. Observed on this bench: the `ticketflow`
namespace contained nothing but the migration Job, its init container logging
`ticketflow-postgres…:5432 - no response` for four minutes, while the
Application reported `waiting for completion of hook batch/Job/ticketflow-migrate`.
The identical manifest had installed cleanly under Flux minutes earlier.

`.Values.migration.hook` therefore defaults to **`post-install,post-upgrade`**,
which maps to `PostSync` on Argo CD and runs after the database exists on both
engines. The cost is real and is not hidden: on an upgrade the schema changes
*after* the new pods have rolled, which is only safe for additive migrations.

In production the answer is not a different annotation, it is a different
boundary: keep the database out of the application's release, and `pre-upgrade`
becomes safe on both engines. This bench cannot do that without giving each
engine its own chart, which ADR 001 forbids.

Setting `migration.hook=post-install,pre-upgrade` reproduces the Argo CD
deadlock deliberately. It is the sharpest demonstration in this repository.

## Why readiness checks connectivity only

`GET /readyz` executes `SELECT 1`, not a query against the migrated table.

Helm waits for the Deployment to become ready **before** running `post-install`
hooks. A readiness probe that required the migrated schema would therefore
deadlock the first install: the pod waits for the migration, and the migration
waits for the pod. Liveness does not touch the database at all, so a database
incident cannot escalate into an application restart loop.

The cost is a window, on first install only, where the API is in the Service but
`/tickets` fails because the table does not exist yet.

## A Helm 4 hazard in the CLI — tested against Flux, and not reproduced

Helm 4 replaced the boolean `--wait` with a strategy: `watcher`, `hookOnly` or
`legacy`. Under `watcher` — what plain `--wait` selects — the Helm **CLI** did
not observe this hook Job completing: the Job reached `Complete` with
`succeeded: 1` in six seconds while Helm waited until its timeout, nineteen
minutes later. `--wait=legacy` returns in under twenty seconds, which is why
`make smoke` pins it.

The obvious worry was that Flux inherits this. Flux 2.9.5 ships helm-controller
v1.6.4, which links `helm.sh/helm/v4 v4.2.4` and sets
`install.WaitStrategy` from the HelmRelease's own `.spec.waitStrategy`
(`poller`, the kstatus-based default, or `legacy`).

**Tested, and it does not reproduce.** With the default `poller` strategy and no
override, the HelmRelease went from `Progressing` to `InstallSucceeded` in 79
seconds, the hook Job completing in 8. No `waitStrategy` override is needed and
none is set. The hazard is specific to the Helm CLI's `watcher` strategy.

Recorded because the reasoning was sound and the conclusion was wrong: the
escape hatch exists at `.spec.waitStrategy.name` if a future version regresses.

## What the failure path measured, and the cost it revealed

`migration.failOnPurpose=true` makes the migration exit non-zero. Pointing both
engines at that commit produced the sharpest result in this repository:

- **Flux** ran it, failed the post-upgrade hook, retried three times and
  **rolled back automatically** to the previous release. `helm history` records
  the whole cycle.
- **Argo CD never ran it.** The commit changed only the hook, Argo CD excludes
  hook resources from its live-versus-desired diff, so `argocd app diff` was
  empty, automated sync never fired, and the Application reported `Synced` and
  `Healthy`. Forcing `argocd app sync` ran the hook, which then failed correctly.

And while a failed migration Job sat in the namespace with three errored pods:

```
sync.status        = Synced
health.status      = Healthy
operation.phase    = Failed
operation.revision = <the previous commit>
```

**This is the real cost of expressing the migration as a hook.** ADR 001 requires
both engines to read the same manifest, and a Helm hook is the only construct
that satisfies that. But under Argo CD, putting the migration in a hook means a
migration-only commit can be skipped silently while the dashboard stays green --
and the repaired commit is equally invisible until a sync is forced.

If this repository were a delivery pipeline rather than a bench, the right answer
under Argo CD would be to stop using a hook: make the migration a normal resource
whose spec changes per release, so a diff exists and automated sync fires. That
would mean two different manifests for the two engines, which is precisely what
ADR 001 forbids. The constraint that makes the comparison fair is the same one
that produces the bad operational outcome, and it is worth stating that plainly
rather than presenting the hook as best practice.

Full measurements in [docs/comparison.md](../comparison.md), recovery steps in
[docs/runbook.md](../runbook.md).

## Consequences

- The chart cannot use any Argo CD-specific sync behaviour — sync options,
  selective sync waves on non-hook resources, `Replace=true`. Argo CD is
  therefore not shown at its most expressive. That is the price of a fair bench.
- `pre-rollback` and `post-rollback` hooks are unusable, because Argo CD ignores
  them. Rollback has to be compared through each engine's own mechanism.
- The default hook phase is a compromise driven by the weaker of the two
  engines' hook models, not by what is best for a migration.
- A deliberately failing migration is available behind
  `migration.failOnPurpose=true`, so the two engines can be compared on failure
  and not only on the happy path.

## Alternatives considered

**Put the migration in an init container on the API Deployment.** Rejected. With
more than one replica, every pod races to migrate the same schema, and there is
no single place to observe success or failure. It would also erase the
divergence this bench exists to show, since there would be no hook at all.

**Annotate PostgreSQL as a hook too, with a lower weight.** Rejected. It makes a
database part of the hook lifecycle, where a `before-hook-creation` delete
policy would drop and recreate it on every upgrade. Defensible in a lab,
indefensible as a pattern, and the repository should not teach it.

**Run migrations from the application at startup.** Rejected. It couples schema
changes to pod restarts, gives no failure surface a GitOps engine can act on,
and is exactly the anti-pattern this bench is meant to examine.
