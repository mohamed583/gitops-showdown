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

# A first `make up` pulls ~1.5 GB of controller images, and kubelet serialises
# image pulls: the Argo CD image alone is 215 MB and is pulled by five pods.
# 300s is comfortably too short on a cold cache. Override for a warm one.
WAIT_TIMEOUT ?= 900s

.PHONY: help versions preflight lint \
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

##@ Inspect

status: ## Show the state of both clusters side by side
	@echo "=== clusters ==============================================="
	@kind get clusters 2>/dev/null | sed 's/^/  /' || echo "  (none)"
	@echo ""
	@echo "=== $(CLUSTER_ARGOCD) / Argo CD $(ARGOCD_VERSION) ==========="
	@$(KA) -n $(ARGOCD_NAMESPACE) get deployment,statefulset 2>/dev/null || echo "  cluster unreachable -- run: make up-argocd"
	@echo ""
	@echo "=== $(CLUSTER_FLUX) / Flux $(FLUX_VERSION) =================="
	@$(KF) -n $(FLUX_NAMESPACE) get deployment 2>/dev/null || echo "  cluster unreachable -- run: make up-flux"

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

##@ Quality

lint: ## Lint shell scripts and YAML (skips loudly when a linter is absent)
	@if command -v shellcheck >/dev/null 2>&1; then \
	   echo "==> shellcheck"; \
	   find $(ROOT_DIR)/hack -maxdepth 1 -name '*.sh' -exec shellcheck {} + ; \
	 else echo "==> shellcheck  SKIPPED (not installed -- enforced in CI)"; fi
	@if command -v yamllint >/dev/null 2>&1; then \
	   echo "==> yamllint"; \
	   for d in infra platform apps .github; do \
	     if [ -d "$(ROOT_DIR)/$$d" ]; then yamllint -c $(ROOT_DIR)/.yamllint.yaml "$(ROOT_DIR)/$$d"; fi; \
	   done; \
	 else echo "==> yamllint    SKIPPED (not installed -- enforced in CI)"; fi
	@echo "==> lint clean"
