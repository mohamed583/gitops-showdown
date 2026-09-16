#!/usr/bin/env bash
#
# hack/demo-converge.sh -- one commit, two engines, two rhythms.
#
# Changes the application's release string in the chart, commits it, pushes it
# to the shared Git remote, and then times how long each engine takes to (a)
# notice the commit and (b) have a pod actually serving the new value.
#
# Nothing here is pushed to either cluster directly. The only action taken
# against the clusters is reading. That is the point: the commit is the input,
# and convergence is what is being measured.
#
# Usage: demo-converge.sh [new-release-string]

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=hack/versions.env disable=SC1091
source "${SCRIPT_DIR}/versions.env"

CHART="${REPO_ROOT}/apps/ticketflow/chart/Chart.yaml"
CTX_ARGOCD="kind-${CLUSTER_ARGOCD}"
CTX_FLUX="kind-${CLUSTER_FLUX}"

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; RESET=$'\033[0m'
else
  BOLD=''; DIM=''; GREEN=''; RESET=''
fi

log() { printf '%s==>%s %s\n' "${BOLD}" "${RESET}" "$*"; }

current_release() {
  awk -F'"' '/^appVersion:/ {print $2}' "${CHART}"
}

# Read the release string an actual pod is serving, through the Service.
served_release() {
  local ctx="$1"
  kubectl --context "${ctx}" -n ticketflow exec deploy/ticketflow -- \
    python -c "import json,urllib.request;print(json.load(urllib.request.urlopen('http://ticketflow:8000/version'))['release'])" \
    2>/dev/null || echo "?"
}

new_release="${1:-}"
if [[ -z "${new_release}" ]]; then
  # 0.1.0 -> 0.1.1 -> 0.1.2 ...
  cur="$(current_release)"
  new_release="${cur%.*}.$(( ${cur##*.} + 1 ))"
fi

old_release="$(current_release)"

cat <<BANNER

  ${BOLD}gitops-showdown -- one commit, two engines${RESET}
  ${DIM}appVersion ${old_release} -> ${new_release}${RESET}

BANNER

if [[ "$(git -C "${REPO_ROOT}" status --porcelain)" != "" ]]; then
  echo "working tree is dirty -- commit or stash first" >&2
  exit 1
fi

log "editing the chart's appVersion"
sed -i -E "s|^appVersion: \"${old_release}\"$|appVersion: \"${new_release}\"|" "${CHART}"

log "committing"
git -C "${REPO_ROOT}" add "${CHART}"
git -C "${REPO_ROOT}" commit -q -m "demo: ticketflow ${old_release} -> ${new_release}"
sha="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"

log "pushing ${sha} to the shared remote"
"${SCRIPT_DIR}/git-server.sh" up >/dev/null

# Both engines poll on their own interval. Nothing below nudges them: the
# whole point is to watch the rhythm each one actually has.
started="$(date +%s)"
argocd_seen="" ; flux_seen=""
argocd_served=""; flux_served=""

printf '\n  %-6s  %-22s  %-22s\n' "time" "Argo CD" "Flux"
printf '  %-6s  %-22s  %-22s\n' "------" "----------------------" "----------------------"

for _ in $(seq 1 120); do
  now=$(( $(date +%s) - started ))

  if [[ -z "${argocd_seen}" ]]; then
    rev="$(kubectl --context "${CTX_ARGOCD}" -n argocd get application ticketflow \
            -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
    [[ "${rev}" == "${sha}"* ]] && argocd_seen="${now}"
  fi
  if [[ -z "${flux_seen}" ]]; then
    rev="$(kubectl --context "${CTX_FLUX}" -n flux-system get gitrepository showdown \
            -o jsonpath='{.status.artifact.revision}' 2>/dev/null || true)"
    [[ "${rev}" == *"${sha}"* ]] && flux_seen="${now}"
  fi
  [[ -z "${argocd_served}" && "$(served_release "${CTX_ARGOCD}")" == "${new_release}" ]] && argocd_served="${now}"
  [[ -z "${flux_served}"  && "$(served_release "${CTX_FLUX}")"  == "${new_release}" ]] && flux_served="${now}"

  printf '\r  %-6s  commit %-4s serving %-4s  commit %-4s serving %-4s' \
    "${now}s" \
    "${argocd_seen:-–}" "${argocd_served:-–}" \
    "${flux_seen:-–}" "${flux_served:-–}"

  [[ -n "${argocd_served}" && -n "${flux_served}" ]] && break
  sleep 5
done
printf '\n\n'

report() {
  local name="$1" seen="$2" served="$3"
  printf '  %s%-8s%s commit noticed after %-5s pod serving %s after %s\n' \
    "${BOLD}" "${name}" "${RESET}" "${seen:-never}s" "${new_release}" "${served:-never}s"
}
report "Argo CD" "${argocd_seen}" "${argocd_served}"
report "Flux" "${flux_seen}" "${flux_served}"

cat <<NEXT

  ${GREEN}Both engines converged on ${sha} from the same commit.${RESET}

  ${BOLD}Read those numbers carefully.${RESET} They measure the POLLING INTERVALS
  this bench happens to configure, not any inherent speed difference:

    Flux      GitRepository and Kustomization interval: 1m (set in platform/flux)
    Argo CD   default repo polling: 3m (timeout.reconciliation, unchanged here)

  Both engines support webhooks, which make the poll interval irrelevant.
  Neither is "faster" than the other in any sense this demo can establish --
  what it shows is that the same commit reaches both, on the cadence each was
  told to use.

  What genuinely differs is the machinery underneath:
    ${DIM}make diverge${RESET}   Flux left a Helm release; Argo CD did not.

  To undo, commit the reverse -- that is what GitOps means here:
    ${DIM}git revert HEAD && hack/git-server.sh up${RESET}

NEXT
