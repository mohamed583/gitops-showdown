# 003 — Two separate clusters, not two namespaces

- **Status:** Accepted
- **Date:** 2026-09-16

## Context

The cheapest way to run both engines on one laptop is one cluster with two
namespaces: `argocd` and `flux-system`, one application namespace each. It saves
about 2 GB of RAM and several minutes of `make up`.

It also invalidates the result.

Both engines install cluster-scoped resources and both watch cluster-scoped
state. Argo CD's `application-controller` and Flux's `kustomize-controller` and
`helm-controller` each hold cluster-wide RBAC and each maintain their own view of
what the cluster *should* look like. Put them side by side and a reconciliation
performed by one is observable as unexplained change by the other. A bench built
that way does not measure two engines; it measures their interference.

There is a second, quieter problem: Helm. The Flux side creates a real Helm
release in the application namespace. If both engines managed an application in
the same namespace, `helm list` — the single clearest piece of evidence this
repository produces — would no longer distinguish them.

## Decision

**One `kind` cluster per engine: `showdown-argocd` and `showdown-flux`, with
identical topology.**

[`infra/kind/cluster-argocd.yaml`](../../infra/kind/cluster-argocd.yaml) and
[`infra/kind/cluster-flux.yaml`](../../infra/kind/cluster-flux.yaml) are the same
file apart from one node label. Neither carries the node image nor the cluster
name: both are passed by the Makefile from `hack/versions.env`, so the pinned
digest is spelled exactly once in the repository and the two substrates cannot
drift apart by editing one file.

Each cluster is a single control-plane node with no workers. A worker would cost
roughly another gigabyte to schedule the same three pods.

## Consequences

### Costs

- **~4 GB of RAM and two clusters.** A first `make up` takes about ten minutes,
  most of it pulling ~1.5 GB of controller images that kubelet pulls serially.
- **Nothing about contention is tested.** CRD ownership conflicts, admission
  webhooks fighting, cluster-wide RBAC overlap — all real production concerns
  when two GitOps engines coexist, and all deliberately out of scope here.
- **The image has to be side-loaded twice.** There is no registry, so
  `make build` runs `kind load docker-image` into both clusters. Forget it and
  both clusters give `ImagePullBackOff`; that ordering is why `make up` runs
  `build` before `bootstrap`.
- **Two kubeconfig contexts to keep straight.** Every Makefile target names its
  context explicitly rather than relying on the current one, which is verbose
  but means no target can act on the wrong cluster.

### Benefits

- An observed difference is attributable to the engine, not to the neighbour.
- `helm list` stays a clean signal: 0 release Secrets on one side, N on the
  other, with nothing to disambiguate.
- Either half can be destroyed and rebuilt alone — `make down-flux && make up-flux`
  — which made several of this repository's findings cheap to reproduce.

## Alternatives considered

**One cluster, two namespaces.** Rejected, above.

**One cluster, two engines, one managing the other.** Rejected. It is a real
pattern — Argo CD bootstrapping Flux, or the reverse — and an interesting one,
but it makes one engine a dependency of the other and there is no longer a
symmetric comparison to make.

**k3d or minikube instead of kind.** Not rejected on merit; kind was chosen
because its node images are published per Kubernetes patch version and pinnable
by digest, which is what lets this bench state exactly which Kubernetes version
both engines ran on. Nothing here depends on kind specifically.

**A single cluster with two virtual clusters (vcluster).** Rejected as extra
machinery to explain. It would isolate the control planes properly, but a reader
would then have to trust that vcluster itself does not skew the comparison, and
that is a harder claim to support than "two clusters, same config".
