# Argo CD 3.5.3 vs Flux 2.9.5 — what this bench actually found

Every row is either **measured** on the two clusters this repository builds, or
**sourced** to upstream documentation. Nothing here is recalled from memory or
taken from a blog post. Rows marked *measured* can be reproduced with the
commands in the last column.

The two engines deploy the same Helm chart, from the same commit of the same
repository, onto two `kind` clusters with identical topology. See
[ADR 001](adr/001-argocd-vs-flux.md) for why the comparison is set up that way
and what it deliberately does not test.

---

## 1. How a Helm chart becomes running objects

| | Argo CD 3.5.3 | Flux 2.9.5 | Evidence |
|---|---|---|---|
| Helm's role | renders only: "Helm is only used to inflate charts with `helm template`" | performs a real install/upgrade through the Helm SDK | [Argo CD Helm guide](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/) · [helm-controller](https://fluxcd.io/flux/components/helm/) |
| Who owns the lifecycle | "the lifecycle of the application is handled by Argo CD instead of Helm" | Helm | same |
| Helm version used | v4.2.1, bundled in `argocd-repo-server` | SDK v4.2.4, linked by helm-controller v1.6.4 | *measured*: `kubectl exec deploy/argocd-repo-server -- helm version` |
| `helm list` in the app namespace | **empty** | `ticketflow`, revision 1 | *measured*: `make diverge` |
| Helm release storage Secrets | **0** | **1** (`sh.helm.release.v1.ticketflow.v1`) | *measured*: `make diverge` |

This is the root difference. Everything below follows from it.

## 2. Undo

| | Argo CD 3.5.3 | Flux 2.9.5 |
|---|---|---|
| Application-level history | `argocd app history` | — |
| Helm release history | none exists | `helm history ticketflow` |
| Emergency undo verb | `argocd app rollback <id>` | `helm rollback`, or `.spec.upgrade.remediation` automatically |
| Correct undo | `git revert` | `git revert` |

Both engines reconcile back to Git, so a manual rollback on either side is
temporary. The difference is what exists underneath **while you are deciding**:
Flux hands you a Helm release you can inspect and step backwards through; Argo CD
hands you Git history and its own recorded sync revisions.

## 3. Hooks — where the engines genuinely disagree

Argo CD translates Helm hooks, conditionally:

> "If you define any Argo CD hooks, all Helm hooks will be ignored."
> — [Argo CD Helm guide](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/)

| Helm hook | Argo CD | Flux |
|---|---|---|
| `pre-install`, `pre-upgrade` | → `PreSync` | native |
| `post-install`, `post-upgrade` | → `PostSync` | native |
| `pre-delete`, `post-delete` | → `PreDelete`, `PostDelete` | native |
| `helm.sh/hook-weight` | → `argocd.argoproj.io/sync-wave` | native |
| **`pre-rollback`, `post-rollback`** | **ignored — unsupported** | executed |
| **`test-success`, `test-failure`** | **ignored — unsupported** | executed |

### The consequence that cost this repository a redesign

*Measured.* A migration Job annotated `helm.sh/hook: post-install,pre-upgrade`
installs cleanly under Flux and **deadlocks Argo CD's first sync**.

Argo CD has no notion of install versus upgrade. It maps `pre-upgrade` to
`PreSync` and runs it on *every* sync, including the first — before PostgreSQL
exists, because PostgreSQL is created in the `Sync` phase that `PreSync` is
blocking. Observed: the `ticketflow` namespace contained nothing but the
migration Job, its init container logging `no response` for four minutes, while
the Application reported `waiting for completion of hook batch/Job/…`.

Reproduce it: set `migration.hook=post-install,pre-upgrade`, commit, push.

Full account in [ADR 002](adr/002-migration-as-helm-hook.md).

## 4. What counts as "a change worth acting on"

*Measured, and the sharpest practical surprise after the hook phase.*

Commit a change that does not touch `Chart.yaml`'s `version` field — a template
edit, a values edit, an `appVersion` bump — and the two engines do not agree
that anything happened:

| | Argo CD 3.5.3 | Flux 2.9.5, default |
|---|---|---|
| Re-renders on every commit | yes | **no** |
| What triggers an upgrade | any change to the rendered manifests | a change to the chart's `version` |

Observed: after a commit bumping `appVersion` 0.1.0 → 0.1.1, both engines
reported the same commit as their current revision, Argo CD had rolled a new pod
serving `0.1.1`, and Flux was still serving `0.1.0` twelve minutes later. Flux's
`HelmChart` still read `version=0.1.0+1`, `reconcileStrategy=ChartVersion`.

This is not a defect. `HelmChart.spec.reconcileStrategy` defaults to
`ChartVersion`, which is the right default for a chart pulled from a registry
and the wrong one for a chart that lives beside the application in the same
repository. This bench sets `reconcileStrategy: Revision` on the HelmRelease,
and says so in the manifest with the measurement attached.

If you take one operational thing from this repository, take this one: a Flux
HelmRelease pointed at a co-located chart will silently ignore your commits
until you set it.

## 5. Convergence latency — and why the number is almost meaningless

*Measured*, with `hack/demo-converge.sh`, one commit bumping `appVersion`:

| | commit noticed | pod serving the new release |
|---|---|---|
| Flux 2.9.5 | 7s | 15s |
| Argo CD 3.5.3 | 348s | 354s |

**This does not mean Flux is twenty times faster.** It measures the polling
intervals this bench configures and nothing else:

- Flux's `GitRepository` and `Kustomization` are set to `interval: 1m` in
  `platform/flux/`.
- Argo CD's repository polling is left at its default of 3 minutes.

Both engines support webhooks, which remove polling from the picture entirely.
The honest conclusion is the boring one: each engine converged on the cadence it
was told to use. The number is reported here because omitting it would look like
concealment, and qualified because quoting it bare would be dishonest.

## 6. Values files

Both consume the chart's own per-environment values natively, with no
duplication and no engine-specific copy of the manifests:

| | Path |
|---|---|
| Argo CD | `spec.source.helm.valueFiles` → `platform/argocd/apps/ticketflow.yaml` |
| Flux | `spec.chart.spec.valuesFiles` → `platform/flux/releases/ticketflow.yaml` |

*Measured.* Flux reports the merge explicitly: `packaged 'ticketflow' chart with
version '0.1.0+1' and merged values files [apps/ticketflow/chart/values.yaml
apps/ticketflow/chart/values-dev.yaml]`.

## 7. Operator surface

| | Argo CD 3.5.3 | Flux 2.9.5 |
|---|---|---|
| Web UI | yes, ships in the default install | **none upstream** |
| CLI | `argocd` | `flux` |
| State lives in | Application CRs + the UI/API | the custom resources themselves |
| Install footprint | *measured*: 6 Deployments + 1 StatefulSet | *measured*: 7 Deployments |
| Health check for the install | — | `flux check` |

`make ui-argocd` port-forwards the real UI. `make ui-flux` does not pretend an
equivalent exists: it runs `flux check` and lists the reconciled objects.

## 8. Kubernetes support windows

| | Supported |
|---|---|
| Argo CD 3.5 | v1.33, v1.34, v1.35, **v1.36** ([source](https://github.com/argoproj/argo-cd/blob/v3.5.3/docs/operator-manual/tested-kubernetes-versions.md)) |
| Flux 2.9.5 | v1.33 ≥ 1.33.0 · v1.34 ≥ 1.34.1 · v1.35 and later ≥ 1.35.0 ([source](https://fluxcd.io/flux/installation/#prerequisites)) |

The intersection is **1.33 – 1.36**. Argo CD sets the ceiling, not Flux — which
is why this repository pins `kindest/node:v1.36.4` by digest rather than using
kind v0.33.0's default of v1.37.

## 9. One thing that is not a difference

Helm 4 replaced the boolean `--wait` with a strategy. Under `watcher` — what
plain `--wait` selects — the Helm **CLI** never observed the migration hook Job
completing: the Job reached `Complete` in six seconds while Helm waited nineteen
minutes to its timeout.

The obvious worry was that Flux inherits this, since helm-controller links the
same Helm 4 SDK. *Measured: it does not.* With the default `poller` strategy the
HelmRelease went `Progressing` → `InstallSucceeded` in 79 seconds. The hazard is
specific to the CLI. Recorded because the reasoning was sound and the conclusion
was wrong.

---

## What this bench does not tell you

- **Nothing about scale.** Two single-node `kind` clusters, one application, no
  multi-tenancy, no cloud IAM, no network partitions.
- **Nothing about Argo CD's exclusive features.** ApplicationSets, sync options,
  `Replace=true`, the UI's diff and rollback ergonomics — all excluded, because
  using them would mean the two engines no longer read the same manifest.
- **Nothing about Flux's exclusive features.** Image automation, OCI sources,
  `dependsOn` across releases, multi-tenancy lockdown.
- **Nothing about day-2 operations at organisational scale**, which is where
  most of the real difference between these two tools actually lives.

## Experience asymmetry

Flux is the engine the author has run in production, through a migration of
staging, pre-production and production onto HelmRelease. Argo CD is known from
its documentation and from this lab only, never operated in production — every
Argo CD row above is either quoted from upstream documentation or measured on
these two `kind` clusters, and none of it should be read as field experience.
