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
    log "both engines will now try, and fail, to apply this. Give them a minute, then:"
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
