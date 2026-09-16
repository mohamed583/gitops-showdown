#!/usr/bin/env bash
#
# hack/demo-play.sh -- the guided tour, at reading speed.
#
# Runs the real commands against the live clusters with the pacing of a live
# demo. Useful on its own, and it is what the terminal recording records:
#
#     PowerSession rec demo.cast --command "bash hack/demo-play.sh"   # Windows
#     asciinema rec demo.cast --command "bash hack/demo-play.sh"      # macOS/Linux
#     agg demo.cast docs/assets/showdown.gif
#
# READ-ONLY against both clusters. It commits nothing and changes nothing, so it
# is safe to re-run. The bench must already be up: `make up`.
#
# Environment:
#   DEMO_SPEED   multiplier for every pause; 0.3 is a quick skim (default 1.0)

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}" || exit 1
# shellcheck source=hack/versions.env disable=SC1091
source "${SCRIPT_DIR}/versions.env"

SPEED="${DEMO_SPEED:-1.0}"

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; CYAN=$'\033[36m'; RESET=$'\033[0m'

pause() { sleep "$(awk -v a="$1" -v s="${SPEED}" 'BEGIN{printf "%.2f", a*s}')"; }

# Type a command out one character at a time, then run it for real.
run() {
  local cmd="$1" i char
  printf '%s$%s ' "${GREEN}" "${RESET}"
  for (( i = 0; i < ${#cmd}; i++ )); do
    char="${cmd:i:1}"
    printf '%s' "${char}"
    sleep 0.02
  done
  printf '\n'
  pause 0.4
  eval "${cmd}"
  pause 2.5
}

say() {
  printf '\n%s# %s%s\n' "${CYAN}" "$*" "${RESET}"
  pause 1.8
}

clear
printf '\n  %sgitops-showdown%s  %sArgo CD %s vs Flux %s on Kubernetes %s%s\n\n' \
  "${BOLD}" "${RESET}" "${DIM}" "${ARGOCD_VERSION}" "${FLUX_VERSION}" "${K8S_VERSION}" "${RESET}"
pause 2

say "One application. Two GitOps engines. One identical Helm chart."
run "make status"

say "Both engines serve the same commit. So what actually differs?"
run "make diverge"

say "Flux ran a real helm upgrade, so a release exists -- with history."
run "helm history ticketflow --kube-context kind-${CLUSTER_FLUX} -n ticketflow"

say "Argo CD rendered the chart itself. There is no Helm release at all."
run "helm list --kube-context kind-${CLUSTER_ARGOCD} -n ticketflow"

say "Same chart, same commit, same application -- different machinery."
run "ls docs docs/adr"

printf '\n  %sEvery trade-off is written down: measured here, or sourced upstream.%s\n' "${BOLD}" "${RESET}"
printf '  %sdocs/comparison.md  ·  docs/adr/  ·  docs/runbook.md%s\n\n' "${DIM}" "${RESET}"
pause 3
