# 004 — A local Git server, on the kind Docker network

- **Status:** Accepted
- **Date:** 2026-09-16

## Context

The premise of this repository is one commit reaching two engines. That needs a
Git remote **both clusters can reach**, and it needs to work for someone who has
just cloned the repository — not only on the author's machine.

Pointing both engines at GitHub would work, but it makes the demonstration
depend on the reader having push access to a repository somewhere, and it turns
a local experiment into something that leaves the machine. Neither is acceptable
for a bench whose whole claim is "clone it and run `make up`".

## Decision

**Run Gitea as a container on the `kind` Docker network, and give each cluster's
CoreDNS a hosts entry for it. Honour `GIT_REMOTE` as a complete escape hatch.**

[`hack/git-server.sh`](../../hack/git-server.sh) starts the container, creates
the user and repository, patches CoreDNS in whichever clusters exist, and pushes
the working tree. If `GIT_REMOTE` is set, the whole script is a no-op and the
engines use that remote instead.

## Attaching to the network is necessary but not sufficient

This is the part worth remembering.

Putting the container on the `kind` network makes it routable from the cluster
**nodes**, and Docker's embedded DNS will resolve its name — from other
containers. It does nothing for **pods**, which resolve through CoreDNS, and
CoreDNS knows nothing about Docker's DNS. Argo CD's `repo-server` and Flux's
`source-controller` are pods.

So the script writes a `hosts` block into each cluster's CoreDNS ConfigMap:

```
hosts {
    172.19.0.6 gitea.showdown.local
    fallthrough
}
```

and re-points it whenever the container's address changes, which it does on
every recreate. Verified from inside both clusters: the name resolves and
`git-upload-pack` answers 200.

The alternative — putting the container's IP directly in the manifests — was
rejected because the IP is not stable and the manifests are in Git, which is
exactly the thing that must not need editing per machine.

## Two ports, and why confusing them is easy

| | Value | Used by |
|---|---|---|
| `GITEA_HTTP_PORT` | 3000 | the container itself; **this is what goes in the Git URL the engines use** |
| `GITEA_HOST_PORT` | 3300 | published on the workstation, for pushing and browsing |

They are different because 3000 is very often taken — it was on the machine this
was built on. Using the published port in the manifests produces a URL that
works from your terminal and fails in every pod, which is a confusing failure to
debug.

## Consequences

- **The bench is self-contained.** No account, no network egress, no shared
  state between people running it.
- **CoreDNS in both clusters is modified.** That edit is confined to the two
  disposable `showdown-*` clusters, and `make down` deletes them entirely, but it
  is a real mutation and `SECURITY.md` says so.
- **Gitea runs in dev mode with committed credentials.** Documented at length in
  `SECURITY.md`. The credentials are default *so that they are not secret*: they
  guard an empty throwaway Git server on localhost.
- **`make git-server` must be re-run after recreating a cluster**, because the
  CoreDNS entry goes with it. `make up` does this in the right order.

## Two Gitea behaviours found the hard way

Both cost real time, and both are in [`docs/runbook.md`](../runbook.md):

1. **`gitea admin user list` must run as `-u git`.** Gitea refuses to run as
   root and returns a fatal-error banner instead of the list, so an existence
   check that greps that output silently finds nothing — and creation then fails
   on a user that was there all along.
2. **Users and organisations share one namespace.** An organisation cannot be
   created with the same name as a user (`user already exists`). The repository
   lives under the user account, which yields the identical clone URL.

## Alternatives considered

**GitHub or GitLab as the remote.** Rejected as the default, kept as
`GIT_REMOTE`. It requires an account and push access, and moves a local
experiment onto someone else's infrastructure.

**A bare repository served over `git daemon` or a static HTTP mount.** Rejected.
Lighter, but it gives no way to demonstrate a realistic pull-with-credentials
path later, and Gitea costs one container.

**Mounting the repository into the clusters with `extraMounts` and using a
`file://` source.** Rejected. Neither engine treats a local path the way it
treats a real remote, and the reconciliation loop being observed is precisely
the part that would be skipped.

**A static IP for the container instead of the CoreDNS entry.** Rejected. It
depends on the kind network's subnet, which varies between machines, and it
would collide with kind's own address allocation.
