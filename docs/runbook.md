# Runbook

Symptom → diagnosis → fix. **Every entry below is a failure that actually
happened while building this repository**, not a hypothetical. Where a fix is
already in the code, the entry says so and explains what to look for if it
comes back.

---

## Bring-up

### On Windows, `make` prints `'#' n'est pas reconnu` — or does nothing at all

**Diagnosis.** `make` is being run from PowerShell or cmd, and GNU Make silently
fell back to `cmd.exe` because it could not resolve `SHELL`. `/usr/bin/env` only
exists inside an MSYS shell. cmd.exe then tries to execute the `#` comment lines
inside the recipes, and a target whose recipe is a single `.sh` invocation simply
produces no output.

**Fix.** Already in the Makefile: on Windows it resolves `SHELL` to Git Bash by
absolute path. Two details that make this work and are easy to get wrong:

- The path must contain **no spaces**. Make does not quote `SHELL`, so
  `C:/Program Files/Git/bin/bash.exe` fails even with the space escaped. The 8.3
  short form `C:/PROGRA~1/Git/bin/bash.exe` is used instead.
- `C:\Windows\System32ash.exe` is deliberately **not** a candidate. It is the
  WSL shim, and forwards to a distribution that may have no `/bin/bash` — which
  fails with `execvpe(/bin/bash) failed` rather than anything obvious.

If you see `No usable bash found`, install Git for Windows.

**Check.** `make -p | grep '^SHELL'` should print a bash, never `cmd.exe`.

---

### `make up-argocd` fails: `metadata.annotations: Too long: may not be more than 262144 bytes`

**Diagnosis.** Client-side `kubectl apply` stores the entire manifest in a
`last-applied-configuration` annotation. Argo CD's `applicationsets.argoproj.io`
CRD is larger than the 262144-byte limit etcd enforces on that annotation.

**Fix.** Server-side apply does not write that annotation at all. The Makefile
uses `kubectl apply --server-side --force-conflicts` for both engine installs.
If you apply an engine manifest by hand, do the same.

---

### `make up` times out waiting for a control plane, but the pods look fine

**Diagnosis.** Almost always image pulls, not a failure. A first run pulls
~1.5 GB, kubelet serialises pulls, and the 215 MB Argo CD image is pulled by
five separate pods. A single pull was measured at `3m6s including waiting`.

**Check.** `kubectl -n argocd get events --sort-by=.lastTimestamp | tail` — if
you see `Pulling`/`Pulled` entries, it is working, just slowly.

**Fix.** The readiness budget is `WAIT_TIMEOUT`, default 900s. Raise it rather
than assuming a fault: `make up WAIT_TIMEOUT=1800s`.

---

### `make ui-argocd` opens something that is not Argo CD

**Diagnosis.** Port collision. On Windows, `kubectl port-forward` can report
`Forwarding from 127.0.0.1:PORT` while traffic actually reaches a different
listener that already held the port — the failure is silent. This was hit with
Docker Desktop holding both 8080 and 8443.

**Fix.** The target refuses to start on an occupied port and tells you so. The
default is 9443. Override with `make ui-argocd ARGOCD_UI_PORT=<free port>`.

---

## Git server

### Gitea never becomes healthy, `last HTTP status: 000`

**Diagnosis in order of likelihood.**

1. `MSYS_NO_PATHCONV=1` is set in your shell. Under Git Bash this breaks `curl`
   outright — the request never leaves. Unset it.
2. The host port is already taken. `GITEA_HOST_PORT` defaults to 3300 precisely
   because 3000 usually is. Check with `docker logs showdown-gitea`.
3. A genuinely slow first start. Gitea initialises SQLite before `/api/healthz`
   returns 200; the wait budget is 360s and prints progress every 30s.

**Note.** `000` from `curl -w '%{http_code}'` means "no HTTP response at all",
not "server returned an error".

---

### The pods cannot resolve `gitea.showdown.local`

**Diagnosis.** Attaching the Gitea container to the `kind` Docker network makes
it routable from the cluster *nodes*, but pods resolve names through CoreDNS,
which knows nothing about Docker's embedded DNS.

**Fix.** `hack/git-server.sh` writes a `hosts` block into each cluster's CoreDNS
ConfigMap and restarts CoreDNS. Re-run `make git-server` after anything that
recreates a cluster or the Gitea container — the container's IP changes, and the
script re-points the entry.

**Check.**
```bash
kubectl --context kind-showdown-flux run dnstest --rm -it --restart=Never \
  --image=curlimages/curl:8.11.1 -- \
  sh -c 'getent hosts gitea.showdown.local; curl -s -o /dev/null -w "%{http_code}\n" \
    http://gitea.showdown.local:3000/api/healthz'
```

---

### `gitea admin user create` says the user already exists, but the script did not think so

**Diagnosis.** `docker exec` without `-u git` runs as root, and Gitea refuses to
run as root — it returns a fatal-error banner instead of the user list, so any
check that greps that output silently finds nothing.

**Fix.** Always `docker exec -u git`. Already fixed in `hack/git-server.sh`.

---

### Creating the Gitea organisation fails with `user already exists`

**Diagnosis.** Gitea keeps users and organisations in a single namespace, so an
organisation cannot share a name with a user.

**Fix.** The repository lives under the user account, which produces the
identical clone URL. There is no organisation.

---

## Reconciliation

### Argo CD sync hangs on `waiting for completion of hook batch/Job/...`

**Diagnosis.** The hook is a `pre-upgrade` Helm hook, which Argo CD maps to
`PreSync` and runs on *every* sync including the first. If that hook depends on
anything the chart creates in the `Sync` phase — a database, typically — it
waits forever, because `Sync` is blocked behind it. The namespace will contain
the Job and nothing else, which is the tell.

**Check.**
```bash
kubectl --context kind-showdown-argocd -n ticketflow get all
kubectl --context kind-showdown-argocd -n ticketflow logs job/ticketflow-migrate -c wait-for-postgres
```

**Fix.** `migration.hook` defaults to `post-install,post-upgrade`, which maps to
`PostSync` and runs after the database exists. See
[ADR 002](adr/002-migration-as-helm-hook.md). To recover a stuck sync:

```bash
kubectl -n argocd patch application ticketflow --type merge -p '{"operation":null}'
kubectl -n ticketflow patch job ticketflow-migrate --type json \
  -p '[{"op":"remove","path":"/metadata/finalizers"}]'
kubectl -n ticketflow delete job ticketflow-migrate
```

---

### Argo CD says `Synced` and `Healthy`, but the migration never ran

**Diagnosis.** Argo CD excludes hook resources from its live-versus-desired
diff. A commit whose only change is inside a Helm hook — the migration Job, its
command, its values — produces no diff, so automated sync never triggers and the
hook never runs. The Application's synced revision still advances, so it looks
current.

**The tell.** Sync status and health are not where the truth is:

```bash
kubectl -n argocd get application ticketflow -o jsonpath='
  sync={.status.sync.status} health={.status.health.status}
  operation={.status.operationState.phase} @ {.status.operationState.syncResult.revision}'
```

A healthy-looking app with `operation=Failed`, or with an operation revision
behind `sync.revision`, means exactly this.

**Fix.** Force it:

```bash
argocd app sync ticketflow
```

**Avoid it.** Do not put anything in a Helm hook that must run on every commit
when Argo CD drives delivery, and alert on `status.operationState.phase` rather
than on sync and health. Measured in full in
[docs/comparison.md](comparison.md#5-failure--where-the-two-engines-stop-resembling-each-other).

---

### Pods are `ImagePullBackOff` on `ticketflow:0.1.0`

**Diagnosis.** There is no registry. The image is built locally and side-loaded
into each cluster with `kind load docker-image`, and the chart pins
`imagePullPolicy: IfNotPresent` accordingly. A cluster that was recreated, or a
bootstrap run before `make build`, has no such image.

**Fix.** `make build`. This is why `make up` runs `build` before `bootstrap` —
the ordering is not cosmetic.

---

### The application serves stale behaviour after a code change

**Diagnosis.** The image tag did not change, so nothing tells Kubernetes to pull
or restart. Rebuilding under the same tag leaves running pods on the old image.

**Fix.** `make build`, then delete the pod or bump `appVersion` and commit — the
latter is the GitOps answer and is what `hack/demo-converge.sh` does.

---

### `helm install --wait` hangs on a hook Job that has clearly completed

**Diagnosis.** Helm 4 turned `--wait` into a strategy. The default that plain
`--wait` selects, `watcher`, was observed not to notice this hook Job finishing:
the Job reached `Complete` with `succeeded: 1` in six seconds while Helm waited
nineteen minutes to its timeout.

**Fix.** `--wait=legacy`, which is what `make smoke` uses.

**Not affected.** Flux's helm-controller, despite linking the same Helm 4 SDK.
Its default `poller` strategy handles it correctly — measured, 79 seconds
install to `InstallSucceeded`. If that ever regresses, the escape hatch is
`HelmRelease.spec.waitStrategy.name: legacy`.

---

## Quality gates

### `make lint` passes but is not actually checking anything

**Diagnosis.** This was a real bug. `[ -d "$dir" ] && yamllint "$dir" || true`
always succeeds, so every YAML failure was swallowed. A lint gate that cannot
fail is worse than no gate, because it is trusted.

**Check it can fail.** Drop a deliberately broken file in and confirm a non-zero
exit:
```bash
printf 'kind: Cluster\n  bad:   indent\n' > infra/kind/_canary.yaml
make lint ; echo "exit=$?"     # must be non-zero
rm infra/kind/_canary.yaml
```

---

### `hack/preflight.sh` reports `bad interpreter` after a fresh clone on Windows

**Diagnosis.** `core.autocrlf=true` checked the script out with CRLF line
endings, so the shebang reads `/usr/bin/env bash\r`.

**Fix.** `.gitattributes` pins LF for `*.sh`, `Makefile`, `*.yaml` and `*.env`.
If you hit this, your clone predates that file — re-clone or run
`git add --renormalize .`.
