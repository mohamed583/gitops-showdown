# gitops-showdown -- one application, two GitOps control planes.
#
# Every version referenced here comes from hack/versions.env. Nothing in this
# file hardcodes a version; if you find one, it is a bug.

SHELL       := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

ROOT_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
include $(ROOT_DIR)/hack/versions.env
export

# kind prefixes every kubeconfig context it creates with "kind-".
CTX_ARGOCD := kind-$(CLUSTER_ARGOCD)
CTX_FLUX   := kind-$(CLUSTER_FLUX)

KA := kubectl --context $(CTX_ARGOCD)
KF := kubectl --context $(CTX_FLUX)

# 8080 and 8443 are bad defaults: Docker Desktop, proxies and dev servers squat
# them, and on Windows kubectl port-forward can appear to bind while traffic
# reaches the other listener. 9443 is far less contended and still reads as TLS.
ARGOCD_UI_PORT ?= 9443

CHART_DIR := $(ROOT_DIR)/apps/ticketflow/chart

# A first `make up` pulls ~1.5 GB of controller images, and kubelet serialises
# image pulls: the Argo CD image alone is 215 MB and is pulled by five pods.
# 300s is comfortably too short on a cold cache. Override for a warm one.
WAIT_TIMEOUT ?= 900s

.PHONY: help versions preflight lint build test venv template smoke \
        git-server git-server-down bootstrap bootstrap-argocd bootstrap-flux diverge \
        up up-argocd up-flux down down-argocd down-flux \
        status ui-argocd ui-flux

##@ Help & introspection

help: ## Show this help
	@awk -v argocd='$(ARGOCD_VERSION)' -v flux='$(FLUX_VERSION)' -v k8s='$(K8S_VERSION)' \
	     'BEGIN { FS = ":.*##"; printf "\n  \033[1mgitops-showdown\033[0m  Argo CD %s vs Flux %s on Kubernetes %s\n", argocd, flux, k8s } \
	      /^##@/                 { printf "\n  \033[1m%s\033[0m\n", substr($$0, 5) } \
	      /^[a-zA-Z0-9_-]+:.*##/ { printf "    \033[36m%-14s\033[0m %s\n", $$1, $$2 } \
	      END { printf "\n" }' $(MAKEFILE_LIST)

versions: ## Print every pinned version resolved from hack/versions.env
	@echo "Argo CD      $(ARGOCD_VERSION)"
	@echo "Flux         $(FLUX_VERSION)"
	@echo "kind         $(KIND_VERSION)"
	@echo "Kubernetes   $(K8S_VERSION)"
	@echo "node image   $(KIND_NODE_IMAGE)"

preflight: ## Check host tooling and versions before creating anything
	@$(ROOT_DIR)/hack/preflight.sh

##@ Bring up

up: up-argocd up-flux ## Bring up both clusters and both engines
	@echo ""
	@echo "==> both control planes are up. Next: make status"

up-argocd: preflight ## Create the Argo CD cluster and install Argo CD
	@if kind get clusters 2>/dev/null | grep -qx '$(CLUSTER_ARGOCD)'; then \
	   echo "==> cluster $(CLUSTER_ARGOCD) already exists, reusing it"; \
	 else \
	   echo "==> creating kind cluster $(CLUSTER_ARGOCD) on $(K8S_VERSION)"; \
	   kind create cluster \
	     --name   $(CLUSTER_ARGOCD) \
	     --config $(ROOT_DIR)/infra/kind/cluster-argocd.yaml \
	     --image  $(KIND_NODE_IMAGE) \
	     --wait 120s; \
	 fi
	@# Server-side apply is mandatory here: the applicationsets.argoproj.io CRD
	@# is larger than the 262144-byte limit on the last-applied-configuration
	@# annotation that client-side apply writes. --force-conflicts keeps a
	@# re-run idempotent once the controllers own their fields.
	@echo "==> installing Argo CD $(ARGOCD_VERSION) into namespace $(ARGOCD_NAMESPACE)"
	@$(KA) create namespace $(ARGOCD_NAMESPACE) --dry-run=client -o yaml | $(KA) apply -f -
	@$(KA) apply --server-side --force-conflicts -n $(ARGOCD_NAMESPACE) -f $(ARGOCD_MANIFEST)
	@echo "==> waiting for the Argo CD control plane (first run pulls images -- several minutes)"
	@$(KA) -n $(ARGOCD_NAMESPACE) rollout status statefulset/argocd-application-controller --timeout=$(WAIT_TIMEOUT)
	@$(KA) -n $(ARGOCD_NAMESPACE) wait --for=condition=Available deployment --all --timeout=$(WAIT_TIMEOUT)
	@echo "==> Argo CD $(ARGOCD_VERSION) ready. UI: make ui-argocd"

up-flux: preflight ## Create the Flux cluster and install Flux
	@if kind get clusters 2>/dev/null | grep -qx '$(CLUSTER_FLUX)'; then \
	   echo "==> cluster $(CLUSTER_FLUX) already exists, reusing it"; \
	 else \
	   echo "==> creating kind cluster $(CLUSTER_FLUX) on $(K8S_VERSION)"; \
	   kind create cluster \
	     --name   $(CLUSTER_FLUX) \
	     --config $(ROOT_DIR)/infra/kind/cluster-flux.yaml \
	     --image  $(KIND_NODE_IMAGE) \
	     --wait 120s; \
	 fi
	@# Server-side apply for the same reason as Argo CD above, and to keep
	@# both installation paths identical -- see ADR 001.
	@echo "==> installing Flux $(FLUX_VERSION) into namespace $(FLUX_NAMESPACE)"
	@$(KF) apply --server-side --force-conflicts -f $(FLUX_MANIFEST)
	@echo "==> waiting for the Flux controllers (first run pulls images -- several minutes)"
	@$(KF) -n $(FLUX_NAMESPACE) wait --for=condition=Available deployment --all --timeout=$(WAIT_TIMEOUT)
	@echo "==> Flux $(FLUX_VERSION) ready. State: make ui-flux"

##@ GitOps

git-server: ## Start the local Gitea remote and push the repo to it
	@$(ROOT_DIR)/hack/git-server.sh up

git-server-down: ## Remove the local Gitea remote
	@$(ROOT_DIR)/hack/git-server.sh down

bootstrap: bootstrap-argocd bootstrap-flux ## Point both engines at the shared Git remote
	@echo ""
	@echo "==> both engines are now reconciling from $$($(ROOT_DIR)/hack/git-server.sh url)"

bootstrap-argocd: ## Apply the Argo CD app-of-apps root and let it pull the rest
	@echo "==> applying the Argo CD root application"
	@$(KA) apply --server-side --force-conflicts -f $(ROOT_DIR)/platform/argocd/bootstrap.yaml
	@echo "==> waiting for the ticketflow Application to become Healthy"
	@$(KA) -n $(ARGOCD_NAMESPACE) wait --for=jsonpath='{.status.health.status}'=Healthy \
	   application/ticketflow --timeout=$(WAIT_TIMEOUT)
	@echo "==> Argo CD has converged"

bootstrap-flux: ## Apply the Flux GitRepository + Kustomization and let it pull the rest
	@echo "==> applying the Flux bootstrap manifest"
	@$(KF) apply --server-side --force-conflicts -f $(ROOT_DIR)/platform/flux/bootstrap.yaml
	@echo "==> waiting for the ticketflow HelmRelease to become Ready"
	@$(KF) -n ticketflow wait --for=condition=Ready helmrelease/ticketflow --timeout=$(WAIT_TIMEOUT)
	@echo "==> Flux has converged"

diverge: ## Show the divergence: a Helm release exists on one side and not the other
	@echo "=== Argo CD cluster: helm releases in ticketflow ==="
	@helm list --kube-context $(CTX_ARGOCD) -n ticketflow 2>/dev/null || true
	@printf '  helm release secrets: '
	@$(KA) -n ticketflow get secrets -l owner=helm --no-headers 2>/dev/null | wc -l
	@echo ""
	@echo "=== Flux cluster: helm releases in ticketflow ==="
	@helm list --kube-context $(CTX_FLUX) -n ticketflow 2>/dev/null || true
	@printf '  helm release secrets: '
	@$(KF) -n ticketflow get secrets -l owner=helm --no-headers 2>/dev/null | wc -l
	@echo ""
	@echo "Same chart, same commit, same application. Flux went through helm-controller"
	@echo "and left a release you can 'helm history' and 'helm rollback'. Argo CD rendered"
	@echo "the chart with 'helm template' and applied it itself, so there is nothing for"
	@echo "Helm to roll back -- undo goes through 'argocd app rollback' over Git history."

##@ Inspect

status: ## Show the state of both clusters side by side
	@echo "=== clusters ==============================================="
	@kind get clusters 2>/dev/null | sed 's/^/  /' || echo "  (none)"
	@echo ""
	@echo "=== git remote ============================================="
	@$(ROOT_DIR)/hack/git-server.sh status
	@echo ""
	@echo "=== $(CLUSTER_ARGOCD) / Argo CD $(ARGOCD_VERSION) ==========="
	@$(KA) -n $(ARGOCD_NAMESPACE) get applications 2>/dev/null || echo "  no Applications -- run: make bootstrap-argocd"
	@$(KA) -n ticketflow get deployment,statefulset 2>/dev/null || echo "  ticketflow not deployed"
	@echo ""
	@echo "=== $(CLUSTER_FLUX) / Flux $(FLUX_VERSION) =================="
	@$(KF) -n ticketflow get helmrelease 2>/dev/null || echo "  no HelmRelease -- run: make bootstrap-flux"
	@$(KF) -n ticketflow get deployment,statefulset 2>/dev/null || echo "  ticketflow not deployed"

ui-argocd: ## Port-forward the Argo CD web UI and print the admin password
	@# Refuse to forward onto an occupied port. kubectl port-forward does not
	@# reliably fail on Windows when the port is taken, and silently serving
	@# somebody else's application on the Argo CD URL is worse than an error.
	@if (exec 3<>/dev/tcp/127.0.0.1/$(ARGOCD_UI_PORT)) 2>/dev/null; then \
	   exec 3<&- 2>/dev/null || true; \
	   echo "port $(ARGOCD_UI_PORT) is already in use on this machine."; \
	   echo "pick another:  make ui-argocd ARGOCD_UI_PORT=<free port>"; \
	   exit 1; \
	 fi
	@echo "Argo CD UI -> https://localhost:$(ARGOCD_UI_PORT)"
	@echo "user:     admin"
	@printf 'password: '
	@$(KA) -n $(ARGOCD_NAMESPACE) get secret argocd-initial-admin-secret \
	   -o jsonpath='{.data.password}' | base64 -d; echo
	@echo "(self-signed certificate -- your browser will warn; Ctrl-C to stop)"
	@$(KA) -n $(ARGOCD_NAMESPACE) port-forward svc/argocd-server $(ARGOCD_UI_PORT):443

ui-flux: ## Show Flux state -- Flux ships no web UI, this is the honest equivalent
	@echo "Flux ships no web UI upstream. Its state lives in the custom resources"
	@echo "themselves; this target is the CLI counterpart of 'make ui-argocd'."
	@echo ""
	@if command -v flux >/dev/null 2>&1; then \
	   flux --context $(CTX_FLUX) check; \
	   echo ""; \
	   echo "--- reconciled objects ---"; \
	   out="$$(flux --context $(CTX_FLUX) get all --all-namespaces 2>&1)"; \
	   if [ -n "$$out" ]; then echo "$$out"; \
	   else echo "none yet -- no Flux source or release is defined (roadmap step 3)"; fi; \
	 else \
	   echo "(flux CLI not installed -- falling back to kubectl)"; \
	   $(KF) get kustomizations,helmreleases,gitrepositories,helmrepositories,ocirepositories \
	     --all-namespaces 2>/dev/null || echo "no Flux custom resources yet"; \
	 fi

##@ Tear down

down: down-argocd down-flux ## Delete both clusters
	@echo "==> everything is gone"

down-argocd: ## Delete the Argo CD cluster
	@kind delete cluster --name $(CLUSTER_ARGOCD)

down-flux: ## Delete the Flux cluster
	@kind delete cluster --name $(CLUSTER_FLUX)

##@ Application

build: ## Build the ticketflow image and side-load it into both clusters
	@echo "==> building $(TICKETFLOW_IMAGE):$(TICKETFLOW_VERSION)"
	@docker build \
	  --build-arg PYTHON_IMAGE=$(PYTHON_IMAGE) \
	  -t $(TICKETFLOW_IMAGE):$(TICKETFLOW_VERSION) \
	  $(ROOT_DIR)/apps/ticketflow
	@# There is no registry: the image is side-loaded into each cluster's
	@# containerd. The chart therefore pins imagePullPolicy: IfNotPresent.
	@for c in $(CLUSTER_ARGOCD) $(CLUSTER_FLUX); do \
	   if kind get clusters 2>/dev/null | grep -qx "$$c"; then \
	     echo "==> loading image into $$c"; \
	     kind load docker-image $(TICKETFLOW_IMAGE):$(TICKETFLOW_VERSION) --name "$$c"; \
	   else \
	     echo "==> skipping $$c (cluster does not exist)"; \
	   fi; \
	 done

test: ## Run the ticketflow unit tests and ruff
	@cd $(ROOT_DIR)/apps/ticketflow && \
	  if [ ! -x .venv/bin/python ] && [ ! -x .venv/Scripts/python.exe ]; then \
	    echo "no venv -- run: make venv"; exit 1; fi; \
	  PY=$$( [ -x .venv/bin/python ] && echo .venv/bin/python || echo .venv/Scripts/python.exe ); \
	  echo "==> ruff"   && $$PY -m ruff check . && \
	  echo "==> pytest" && $$PY -m pytest -q

venv: ## Create the ticketflow virtualenv and install it with dev extras
	@cd $(ROOT_DIR)/apps/ticketflow && \
	  python -m venv .venv 2>/dev/null || py -3.13 -m venv .venv; \
	  PY=$$( [ -x .venv/bin/python ] && echo .venv/bin/python || echo .venv/Scripts/python.exe ); \
	  $$PY -m pip install -q --upgrade pip && $$PY -m pip install -q -e ".[dev]" && \
	  echo "==> venv ready"

template: ## Render the chart for every environment, exactly as the engines do
	@for env in dev staging; do \
	  echo "==> helm template -f values-$$env.yaml"; \
	  helm template ticketflow $(CHART_DIR) \
	    --values $(CHART_DIR)/values.yaml \
	    --values $(CHART_DIR)/values-$$env.yaml \
	    --namespace ticketflow > /dev/null; \
	done
	@echo "==> all environments render"

smoke: ## Install the chart with plain Helm and prove it works, then remove it
	@# Deliberately uses Helm directly, no GitOps engine. It answers one
	@# question -- is the chart itself sound? -- before either engine is wired
	@# up, so a session-3 failure cannot be blamed on the chart.
	@#
	@# --wait=legacy is not decoration. Helm 4 turned --wait into a strategy
	@# (watcher | hookOnly | legacy) and the default 'watcher' never observes
	@# this hook Job completing: the Job reaches Complete in seconds while
	@# Helm waits until timeout. 'legacy' returns in under 20 seconds.
	@set -e; \
	 ctx=kind-$(CLUSTER_ARGOCD); ns=ticketflow-smoke; \
	 trap 'helm uninstall smoke --kube-context '"$$"'ctx -n '"$$"'ns >/dev/null 2>&1 || true; \
	       kubectl --context '"$$"'ctx delete namespace '"$$"'ns --wait=false >/dev/null 2>&1 || true' EXIT; \
	 echo "==> installing the chart with helm (no engine involved)"; \
	 helm install smoke $(CHART_DIR) --kube-context $$ctx \
	   --namespace $$ns --create-namespace \
	   --values $(CHART_DIR)/values.yaml --values $(CHART_DIR)/values-dev.yaml \
	   --wait=legacy --wait-for-jobs --timeout 6m >/dev/null; \
	 echo "==> migration job log"; \
	 kubectl --context $$ctx -n $$ns logs job/smoke-ticketflow-migrate -c migrate | sed 's/^/    /'; \
	 echo "==> probing the API through its Service, from inside the cluster"; \
	 pod=$$(kubectl --context $$ctx -n $$ns get pod -l app.kubernetes.io/component=api \
	        -o jsonpath='{.items[0].metadata.name}'); \
	 kubectl --context $$ctx -n $$ns exec -i $$pod -- python - http://smoke-ticketflow:8000 \
	   < $(ROOT_DIR)/hack/smoke-probe.py; \
	 echo "==> chart verified end to end"

##@ Quality

lint: ## Lint shell scripts, YAML and the Helm chart
	@if command -v shellcheck >/dev/null 2>&1; then \
	   echo "==> shellcheck"; \
	   find $(ROOT_DIR)/hack -maxdepth 1 -name '*.sh' -exec shellcheck {} + ; \
	 else echo "==> shellcheck  SKIPPED (not installed -- enforced in CI)"; fi
	@if command -v yamllint >/dev/null 2>&1; then \
	   echo "==> yamllint"; \
	   for d in infra platform .github; do \
	     if [ -d "$(ROOT_DIR)/$$d" ]; then yamllint -c $(ROOT_DIR)/.yamllint.yaml "$(ROOT_DIR)/$$d"; fi; \
	   done; \
	 else echo "==> yamllint    SKIPPED (not installed -- enforced in CI)"; fi
	@# The chart is linted against every values file it ships, not just the
	@# defaults: an override that breaks a template must fail here, not in a
	@# cluster three minutes later.
	@if command -v helm >/dev/null 2>&1 && [ -d "$(CHART_DIR)" ]; then \
	   echo "==> helm lint"; \
	   for env in "" dev staging; do \
	     if [ -z "$$env" ]; then \
	       helm lint $(CHART_DIR) --values $(CHART_DIR)/values.yaml; \
	     else \
	       helm lint $(CHART_DIR) --values $(CHART_DIR)/values.yaml \
	                              --values $(CHART_DIR)/values-$$env.yaml; \
	     fi; \
	   done; \
	 else echo "==> helm lint    SKIPPED (helm not installed)"; fi
	@echo "==> lint clean"
