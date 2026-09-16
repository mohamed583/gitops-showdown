#!/usr/bin/env bash
#
# hack/demo-failed-migration.sh -- break the migration on purpose, and compare
# what each engine leaves you to work with.
#
# The happy path makes the two engines look interchangeable. Failure is where
# the difference becomes operational: one of them leaves a Helm release with
# history and a rollback verb, the other leaves a failed hook and a Git log.
#
# Usage: demo-failed-migration.sh break | fix | inspect

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=hack/versions.env disable=SC1091
source "${SCRIPT_DIR}/versions.env"

VALUES="${REPO_ROOT}/apps/ticketflow/chart/values-dev.yaml"
CTX_ARGOCD="kind-${CLUSTER_ARGOCD}"
CTX_FLUX="kind-${CLUSTER_FLUX}"

if [[ -t 1 ]]; then BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else BOLD=''; DIM=''; RESET=''; fi

log() { printf '%s==>%s %s\n' "${BOLD}" "${RESET}" "$*"; }

set_flag() {
  local value="$1"
  if grep -q '^  failOnPurpose:' "${VALUES}"; then
    sed -i -E "s|^  failOnPurpose: .*$|  failOnPurpose: ${value}|" "${VALUES}"
  else
    cat >> "${VALUES}" <<EOF

migration:
  failOnPurpose: ${value}
EOF
  fi
}

commit_and_push() {
  local message="$1"
  git -C "${REPO_ROOT}" add "${VALUES}"
  git -C "${REPO_ROOT}" commit -q -m "${message}"
  "${SCRIPT_DIR}/git-server.sh" up >/dev/null
  log "pushed $(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
}

inspect() {
  printf '\n  %sArgo CD -- %s%s\n' "${BOLD}" "${CLUSTER_ARGOCD}" "${RESET}"
  printf '  %ssync / health%s\n' "${DIM}" "${RESET}"
  kubectl --context "${CTX_ARGOCD}" -n argocd get application ticketflow \
    -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision \
    2>/dev/null | sed 's/^/    /' || echo "    (no Application)"
  # Read this line, not the one above. A failed PostSync hook leaves the
  # Application reporting Synced AND Healthy -- the failure lives only in the
  # last sync OPERATION. Alerting on sync/health alone misses a broken
  # migration completely.
  printf '  %slast sync operation -- where a failed hook actually shows%s\n' "${DIM}" "${RESET}"
  kubectl --context "${CTX_ARGOCD}" -n argocd get application ticketflow \
    -o jsonpath='    phase={.status.operationState.phase}  {.status.operationState.message}{"\n"}' \
    2>/dev/null || echo "    (no operation recorded)"
  printf '  %shelm releases -- expected: none, Argo CD never created one%s\n' "${DIM}" "${RESET}"
  helm list --kube-context "${CTX_ARGOCD}" -n ticketflow 2>/dev/null | sed 's/^/    /' || true
  printf '  %sundo path%s\n' "${DIM}" "${RESET}"
  echo "    argocd app history ticketflow   then   argocd app rollback ticketflow <id>"
  echo "    (Git history is the only record of what 'previous' means)"

  printf '\n  %sFlux -- %s%s\n' "${BOLD}" "${CLUSTER_FLUX}" "${RESET}"
  printf '  %sHelmRelease%s\n' "${DIM}" "${RESET}"
  # Single-quoted: the JSONPath filter contains [?(...)], which an unquoted
  # shell word treats as a glob character class.
  kubectl --context "${CTX_FLUX}" -n ticketflow get helmrelease ticketflow \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status}  {.reason}{"\n"}{end}' \
    2>/dev/null | sed 's/^/    /' || echo "    (no HelmRelease)"
  printf '  %shelm history -- a real release, with revisions%s\n' "${DIM}" "${RESET}"
  helm history ticketflow --kube-context "${CTX_FLUX}" -n ticketflow 2>/dev/null | sed 's/^/    /' \
    || echo "    (no release yet)"
  printf '  %sundo path%s\n' "${DIM}" "${RESET}"
  echo "    helm rollback ticketflow <revision>, or .spec.upgrade.remediation does it"
  echo "    automatically -- but Flux will then reconcile back to Git, which is the point"

  printf '\n  %sBoth engines reconcile back to Git.%s The difference is what exists\n' "${BOLD}" "${RESET}"
  printf '  underneath while you are deciding what to do.\n\n'
}

case "${1:-inspect}" in
  break)
    log "setting migration.failOnPurpose=true in values-dev.yaml"
    set_flag true
    commit_and_push "demo: break the schema migration on purpose"
    echo
    log "Flux will pick this up within a minute, fail the post-upgrade hook,"
    echo "    retry, and roll back on its own."
    echo
    log "Argo CD will NOT. A commit whose only change is inside a Helm hook"
    echo "    produces no diff, so automated sync never fires -- it will sit at"
    echo "    Synced/Healthy having never run the migration. That is the finding,"
    echo "    not a setup error. To make it run the hook, force it by hand:"
    echo
    echo "      argocd app sync ticketflow"
    echo
    log "then compare:"
    echo "      hack/demo-failed-migration.sh inspect"
    ;;
  fix)
    log "setting migration.failOnPurpose=false"
    set_flag false
    commit_and_push "demo: repair the schema migration"
    log "both engines will reconcile back to a working state"
    ;;
  inspect) inspect ;;
  *) echo "usage: $0 break|fix|inspect" >&2; exit 1 ;;
esac
