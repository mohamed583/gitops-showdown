# Security

## What this repository is

gitops-showdown is a **local comparison bench**. It runs on two throwaway `kind`
clusters on a single machine and is not hardened, not multi-tenant, and not
intended to be exposed to a network. Read the rest of this file before running
anything on a machine that other people can reach.

## Reporting a vulnerability

Open a GitHub issue. This is a lab repository with no production deployment and
no embargo process; there is nothing to coordinate disclosure against. If you
find a mistake that would mislead someone into an insecure production setup,
that is worth an issue too — the point of the repo is that its claims are
correct.

## Deliberately insecure by design

The following are known, intentional, and scoped to a local lab.

### Gitea runs in development mode, with default credentials

`make git-server` starts a local Gitea container attached to the `kind` Docker
network, so both clusters reach the same Git remote. It runs with
**installation-time defaults and a well-known username and password committed to
this repository** (`showdown` / `showdown-dev-only`, in `hack/versions.env`),
over plain HTTP, with no TLS. The repository it serves is public and both engines
clone it anonymously — there is no credential in any manifest.

`hack/git-server.sh` also writes a `hosts` entry into each cluster's CoreDNS
ConfigMap, mapping `gitea.showdown.local` to the container's address on the kind
network. Pods resolve through CoreDNS rather than Docker's embedded DNS, so
attaching the container to the network is necessary but not sufficient. That
edit is confined to the two disposable `showdown-*` clusters.

This is a deliberate trade-off: without a Git remote both clusters can reach, the
"one commit, two engines" demonstration only works on the author's machine. The
credentials are default *so that they are not secret* — they grant access to an
empty throwaway Git server and nothing else.

**Do not expose Gitea beyond localhost.** The container publishes its HTTP port
on the host (3300 by default; 3000 is commonly taken) purely so you can push and
browse. If you need the bench reachable from elsewhere, set `GIT_REMOTE` to a
real remote instead — `hack/git-server.sh` then becomes a no-op and no local Git
server is started at all.

### Argo CD is installed with its upstream defaults

`make up-argocd` applies the pinned upstream `install.yaml` unmodified. That
means the initial `admin` account, a self-signed certificate, and no SSO. The
initial password is read out of the `argocd-initial-admin-secret` Secret by
`make ui-argocd` and printed to your terminal. The API server is reached by
`kubectl port-forward`, never by an Ingress or a Service of type LoadBalancer.

### Flux is installed with its upstream defaults

`make up-flux` applies the pinned upstream `install.yaml` unmodified. No
multi-tenancy lockdown, no `--no-cross-namespace-refs`, no image automation
credentials.

### The clusters are disposable

Both clusters are single-node `kind` clusters with no network policies, no Pod
Security Admission enforcement beyond the Kubernetes default, and no resource
quotas. `make down` deletes them entirely.

## What is *not* acceptable here

These rules apply to contributions and to the author equally:

- **No secrets, kubeconfigs or tokens are ever committed.** Not encrypted, not
  base64-encoded, not "just for the demo". The Gitea default credentials are the
  single exception, and they are documented above precisely because they protect
  nothing.
- **No real registry credentials, cloud credentials or private chart repos.**
  Everything the bench needs is public.
- **Version pins are by digest where the artefact allows it.** The `kind` node
  image is pinned by `sha256` digest in `hack/versions.env`, not by tag, so the
  substrate cannot silently change under the comparison.

## Supply chain

Both control planes are installed from version-tagged upstream manifests fetched
over HTTPS at `make up` time:

- Argo CD: `raw.githubusercontent.com/argoproj/argo-cd/<version>/manifests/install.yaml`
- Flux: `github.com/fluxcd/flux2/releases/download/<version>/install.yaml`

Both URLs are built from `hack/versions.env`. They are immutable for a given
version tag, but they are **not** digest-pinned and are fetched at runtime — if
you need stronger guarantees than "upstream's tagged release", vendor the
manifests into the repository and point `ARGOCD_MANIFEST` and `FLUX_MANIFEST` at
the local copies.
