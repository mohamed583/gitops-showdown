# gitops-showdown

**The same application, deployed by Argo CD and by FluxCD, from one identical
Helm chart — with the trade-offs written down.**

This is a comparison bench, not a tutorial. Both engines consume the same chart
on identically-configured clusters, so neither is advantaged by the setup and a
difference you observe is a difference in the engine.

<!-- Reserved for the demo recording — see "Roadmap" below. Nothing is recorded
     yet; this placeholder exists so the asset has a home, not to imply a demo. -->
> **Demo recording:** not recorded yet. Lands with the demo scenarios (roadmap
> step 4), at `docs/assets/showdown.gif`.

---

## Status — what actually works today

This repository is built in steps, and the README only ever describes what is
already in it. Right now:

| | |
|---|---|
| ✅ | Two `kind` clusters, identical topology, pinned Kubernetes by digest |
| ✅ | Argo CD 3.5.3 installed and reaching `Available` |
| ✅ | Flux 2.9.5 installed and reaching `Available` |
| ✅ | **ticketflow** — FastAPI + PostgreSQL + Alembic migration, one Helm chart |
| ✅ | `make smoke` proves the chart end to end with plain Helm, no engine |
| ✅ | `make preflight` · `make lint` · `make test` gate tooling, YAML, chart and code |
| ✅ | **Both engines reconciling the same chart from one local Gitea remote** |
| ✅ | `make diverge` shows the difference from the live clusters |
| ⬜ | Demo scenarios, architecture diagram, recording |

Both engines now deploy ticketflow from the same commit of the same repository.
What remains is the presentation layer: scripted demo scenarios, an architecture
diagram, and a recording.

---

## Quick start

Requires Docker, `kind` and `kubectl` — `make preflight` checks versions and
tells you exactly what is missing.

```bash
make preflight      # verify the host can run this
make up             # both clusters, both engines (~4 GB RAM)
make status         # what is running, side by side
make down           # delete everything
```

**The first `make up` takes roughly 10 minutes** and pulls ~1.5 GB of controller
images. kubelet serialises image pulls, and the 215 MB Argo CD image is pulled by
five separate pods, so the readiness budget is deliberately generous
(`WAIT_TIMEOUT`, default 900s). Subsequent runs complete in well under a minute
against a warm cache.

Build and verify the application:

```bash
make venv           # ticketflow virtualenv with dev extras
make test           # ruff + pytest
make build          # build the image, side-load it into both clusters
make smoke          # install the chart with plain Helm, probe it, remove it
```

Wire both engines to a shared Git remote and watch them converge:

```bash
make git-server     # local Gitea on the kind network, repo pushed to it
make bootstrap      # point both engines at it; they pull everything else
make diverge        # the punchline, read from the live clusters
```

Or one engine at a time:

```bash
make up-argocd      # cluster showdown-argocd + Argo CD 3.5.3
make up-flux        # cluster showdown-flux  + Flux 2.9.5
```

Inspect the control planes:

```bash
make ui-argocd      # port-forwards the web UI and prints the admin password
make ui-flux        # Flux ships no web UI upstream — this is the CLI equivalent
```

`make help` lists every target.

---

## What the bench actually measured

Same chart, same commit, same application, deployed by both engines:

| | Argo CD 3.5.3 | Flux 2.9.5 |
|---|---|---|
| `helm list` in the app namespace | empty | `ticketflow`, revision 1 |
| Helm release storage Secrets | 0 | 1 |
| Undo path | `argocd app rollback`, over Git history | `helm rollback`, over Helm history |

And one difference that is not a matter of taste: a migration Job annotated
`helm.sh/hook: pre-upgrade` installs cleanly under Flux and **deadlocks Argo CD's
first sync**, because Argo CD maps `pre-upgrade` to `PreSync` and runs it before
the database it depends on has been created. [ADR 002](docs/adr/002-migration-as-helm-hook.md)
has the evidence and what it costs to work around.

---

## Pinned versions

| Component | Version |
|---|---|
| Argo CD | `v3.5.3` |
| Flux | `v2.9.5` |
| kind | `v0.33.0` |
| Kubernetes | `v1.36.4`, pinned by digest |

[`hack/versions.env`](hack/versions.env) is the single source of truth. The
Makefile, `hack/preflight.sh` and CI all read from it; no version is hardcoded
anywhere else. `make versions` prints what is resolved.

### Why Kubernetes 1.36.4, and why not kind's default

kind v0.33.0 ships **v1.37.0** as its default node image, and that default is not
usable here. Argo CD 3.5's
[tested matrix](https://github.com/argoproj/argo-cd/blob/v3.5.3/docs/operator-manual/tested-kubernetes-versions.md)
stops at v1.36 — **Argo CD is the binding constraint, not Flux**, whose
[prerequisites](https://fluxcd.io/flux/installation/#prerequisites) (`1.33 ≥ 1.33.0`,
`1.34 ≥ 1.34.1`, `1.35 and later ≥ 1.35.0`) do not exclude 1.37.

The intersection of both support windows is **1.33 – 1.36**, so the repository
pins the newest version inside it, v1.36.4, by `sha256` digest — a tag could move
under the comparison, a digest cannot.

---

## How the comparison is kept fair

Three deliberate constraints, argued in [ADR 001](docs/adr/001-argocd-vs-flux.md):

**One chart, never duplicated.** Each engine consumes it through its own native
Helm path. Neither gets a bespoke copy of the manifests — otherwise the bench
measures the manifests.

**Identical substrate.** [`infra/kind/cluster-argocd.yaml`](infra/kind/cluster-argocd.yaml)
and [`infra/kind/cluster-flux.yaml`](infra/kind/cluster-flux.yaml) are the same
file apart from a node label. Neither the node image nor the cluster name is
written in them — both come from `hack/versions.env` via the Makefile, so the
pinned digest is spelled exactly once in the repository.

**Identical installation path.** Both control planes are installed by
`kubectl apply` of a pinned upstream manifest. Neither engine's CLI is required
to bring a cluster up, so neither gets a privileged install route.

Two separate clusters rather than two namespaces: both engines claim
cluster-scoped CRDs and RBAC, and sharing a cluster would let one engine's
reconciliation register as drift to the other.

---

## Layout

```
gitops-showdown/
├── Makefile                      # up / down / status / ui / preflight / lint
├── hack/
│   ├── versions.env              # single source of truth for every version
│   └── preflight.sh              # host tooling gate
├── infra/kind/
│   ├── cluster-argocd.yaml       # topology only — image and name come from the Makefile
│   └── cluster-flux.yaml         # identical, bar one node label
├── apps/ticketflow/
│   ├── src/ · tests/ · migrations/   # FastAPI, pytest, Alembic
│   ├── Dockerfile                    # multi-stage, non-root 65532
│   └── chart/                        # THE single application definition
│       └── templates/migration-job.yaml   # the point of divergence
├── platform/
│   ├── argocd/                   # AppProject + app-of-apps
│   └── flux/                     # GitRepository + Kustomization + HelmRelease
├── hack/git-server.sh            # local Gitea, on the kind network
├── docs/adr/                     # architecture decision records
├── .yamllint.yaml
└── SECURITY.md
```

`.github/workflows/` arrives with the step below.

---

## Roadmap

1. ✅ **Foundation** — Makefile, pinned versions, preflight, both clusters, both engines
2. ✅ **ticketflow** — FastAPI support-ticket API, PostgreSQL, schema migration Job
3. ✅ **Both control planes** driving that chart from a shared local Git remote
4. ⬜ **Demo scenarios**, architecture diagram, recording

The migration Job is the deliberate point of divergence: Flux runs a
real `helm upgrade` through helm-controller and leaves a Helm release you can
`helm rollback`; Argo CD renders the chart with `helm template` and applies it
with its own hooks and sync waves, leaving no Helm release at all. See
[ADR 001](docs/adr/001-argocd-vs-flux.md).

---

## Documentation

- [ADR index](docs/adr/README.md) — decisions, with their rejected alternatives
- [ADR 001](docs/adr/001-argocd-vs-flux.md) — why this comparison, and how it is kept fair
- [ADR 002](docs/adr/002-migration-as-helm-hook.md) — the migration hook, and why Argo CD forced its phase to change
- [SECURITY.md](SECURITY.md) — **read before exposing anything**; the bench is deliberately unhardened

---

## Licence

Apache-2.0. See [LICENSE](LICENSE).
