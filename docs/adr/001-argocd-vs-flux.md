# 001 — Compare Argo CD and Flux on one shared Helm chart

- **Status:** Accepted
- **Date:** 2026-09-15

## Context

Argo CD and Flux are both CNCF graduated projects solving the same problem:
reconciling a Kubernetes cluster against a Git repository. Choosing between them
is a real decision that platform teams make, and most published comparisons are
not useful for making it — because they compare two different *setups*. The chart
differs, the manifests differ, the cluster differs, sometimes the application
differs. What such a comparison measures is the lab, not the engine.

The difference that actually matters is not the feature list. It is **how each
engine turns a Helm chart into running objects**, because that single mechanism
decides what "rollback" means, what a failed migration Job leaves behind, and
which tool can be trusted to report the true state of a release.

Argo CD does not delegate to Helm. Its documentation is explicit:

> "Helm is only used to inflate charts with `helm template`. The lifecycle of the
> application is handled by Argo CD instead of Helm."
> — [Argo CD user guide, Helm](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/)

A consequence, from the same documentation, is that no Helm release object exists
in the cluster: the FAQ entry is titled *"After deploying my Helm application with
Argo CD, I cannot see it with `helm ls`"*.

Flux does delegate to Helm. Its helm-controller performs real install and upgrade
operations and stores a release:

> "`.spec.storageNamespace` is an optional field used to specify the namespace in
> which Helm stores release information. […] When making use of the Helm CLI and
> attempting to make use of `helm get` commands to inspect a release, the `-n`
> flag should target the storage namespace of the HelmRelease."
> — [Flux HelmRelease API](https://fluxcd.io/flux/components/helm/helmreleases/)

Two engines, one chart, two genuinely different execution models. That is worth a
bench.

## Decision

**Deploy one application — ticketflow — from one Helm chart, onto two kind
clusters with identical topology: one running Argo CD 3.5.3, one running Flux
2.9.5, both on Kubernetes 1.36.4.**

Each engine consumes `apps/ticketflow/chart/` through its own native Helm path —
`source.helm.valueFiles` for Argo CD, `HelmChart.spec.valuesFiles` for Flux.
Neither engine gets a bespoke copy of the manifests. Both control planes are
installed the same way, by `kubectl apply` of a pinned upstream manifest, so
neither is advantaged by its installation path either.

## Consequences

### Costs

- **~4 GB of RAM and two clusters.** `make up` is roughly twice as slow as a
  single-cluster lab, and a 8 GB machine will feel it.
- **The chart is constrained to the intersection of both engines.** Any Helm
  capability that only one of the two consumes natively is out of scope. The
  bench therefore cannot showcase either engine's exclusive Helm features — it
  deliberately trades expressiveness for comparability.
- **Two clusters cannot show the engines contending for the same cluster-scoped
  resources.** That is a real production concern (CRD ownership, admission,
  cluster-wide RBAC) which this lab explicitly does not model.
- **kind is not production.** No cloud LoadBalancer, no cloud IAM, no
  multi-tenant RBAC pressure, no real network partition. Conclusions about
  behaviour at scale do not transfer from this bench and should not be claimed
  to.

### Benefits

- The substrate is identical, so an observed difference is attributable to the
  engine rather than to the setup.
- The divergence is concentrated at one observable point — the schema migration
  Job — instead of being diffused across the whole application.
- Every version is pinned in `hack/versions.env` and the node image is pinned by
  digest, so the bench is reproducible rather than anecdotal.

## The divergence, stated precisely

| | Argo CD 3.5.3 | Flux 2.9.5 |
|---|---|---|
| Helm usage | `helm template` only — "the lifecycle of the application is handled by Argo CD instead of Helm" | helm-controller performs real Helm install/upgrade |
| Helm release in cluster | none — not visible to `helm ls` | yes, stored in `.spec.storageNamespace` |
| Rollback path | `argocd app rollback`, over Git history | `helm rollback` / `.spec.upgrade.remediation` |
| Hook model | Helm hooks translated to Argo CD hooks and sync waves — "if you define any Argo CD hooks, all Helm hooks will be ignored" | native Helm hooks, executed by Helm |

Sources: [Argo CD Helm user guide](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/)
· [Flux helm-controller](https://fluxcd.io/flux/components/helm/)
· [Flux HelmRelease API](https://fluxcd.io/flux/components/helm/helmreleases/)

## Alternatives considered

**One cluster, two namespaces.** Rejected. Both engines install cluster-scoped
CRDs and RBAC and both watch cluster-scoped resources. Sharing a cluster would
let one engine's reconciliation appear as drift to the other, and the bench would
end up measuring the interference rather than the engines. The RAM saved is not
worth a corrupted result.

**One engine per chart, or duplicated manifests per engine.** Rejected. The
comparison would then measure the manifests. A single shared chart is the whole
premise: it is the only way the difference observed is the engine's.

**Compare Argo CD against Flux's kustomize-controller.** Rejected. That would put
Argo CD's Helm path against Flux's non-Helm path, and the resulting divergence
would be an artefact of the pairing, not a property of either tool.

**Run the bench on a managed cloud cluster.** Rejected. It costs money, and a
reader cannot reproduce it by cloning the repository. Everything here must run on
a laptop with `make up`.

## Experience asymmetry

Flux is the engine I have run in production: I migrated staging, pre-production
and production to FluxCD with HelmRelease, and the operational judgements about
Flux in this repository come from having been on call for them. Argo CD I know
from its documentation and from this lab only — I have never operated it in
production, and every claim made here about Argo CD should be read as sourced
from upstream documentation and verified in kind, not as field experience.
