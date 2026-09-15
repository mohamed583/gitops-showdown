#!/usr/bin/env bash
#
# hack/preflight.sh -- verify the host can actually run the showdown.
#
# Exits non-zero on a HARD failure (a missing or too-old tool that makes
# `make up` impossible). Optional tooling produces a warning and nothing more:
# neither engine's CLI is on the critical path, because both control planes are
# installed from pinned upstream manifests via kubectl.
#
# Every threshold comes from hack/versions.env. No version is spelled here.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hack/versions.env disable=SC1091
source "${SCRIPT_DIR}/versions.env"

if [[ -t 1 ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; DIM=''; RESET=''
fi

failures=0
warnings=0

ok()   { printf '  %sOK%s    %-11s %s\n' "${GREEN}"  "${RESET}" "$1" "${DIM}${2-}${RESET}"; }
warn() { printf '  %sWARN%s  %-11s %s\n' "${YELLOW}" "${RESET}" "$1" "${2-}"; warnings=$((warnings + 1)); }
fail() { printf '  %sFAIL%s  %-11s %s\n' "${RED}"    "${RESET}" "$1" "${2-}"; failures=$((failures + 1)); }

# Strip a leading "v" and any build metadata, then compare with sort -V.
# ver_ge A B -> true when A >= B.
ver_ge() {
  local a="${1#v}" b="${2#v}"
  a="${a%%[-+ ]*}"
  b="${b%%[-+ ]*}"
  [[ "$(printf '%s\n%s\n' "${a}" "${b}" | sort -V | head -n 1)" == "${b}" ]]
}

require_version() {
  local name="$1" found="$2" minimum="$3"
  if [[ -z "${found}" ]]; then
    fail "${name}" "not installed (need >= ${minimum})"
  elif ver_ge "${found}" "${minimum}"; then
    ok "${name}" "${found}"
  else
    fail "${name}" "${found} is older than the required ${minimum}"
  fi
}

# Every CLI prints its version differently ("flux version 2.9.5",
# "argocd: v3.5.3+c9c369e", a ShellCheck banner...). Rather than special-casing
# each banner, take the first version-shaped token anywhere in the output.
optional() {
  local name="$1" hint="$2"
  shift 2
  if ! command -v "${name}" >/dev/null 2>&1; then
    warn "${name}" "absent -- ${hint}"
    return
  fi
  local version
  version="$("$@" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true)"
  ok "${name}" "${version:-installed}"
}

printf '\n  preflight -- Argo CD %s / Flux %s on Kubernetes %s\n\n' \
  "${ARGOCD_VERSION}" "${FLUX_VERSION}" "${K8S_VERSION}"

printf '  %srequired%s\n' "${DIM}" "${RESET}"

# --- docker ---------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  require_version docker \
    "$(docker version --format '{{.Client.Version}}' 2>/dev/null || true)" \
    "${MIN_DOCKER_VERSION}"
  if docker info >/dev/null 2>&1; then
    ok "daemon" "reachable"
  else
    fail "daemon" "docker is installed but the daemon is unreachable -- start Docker Desktop"
  fi
else
  fail docker "not installed (need >= ${MIN_DOCKER_VERSION})"
fi

# --- kind -----------------------------------------------------------------
# kind must be recent enough to know the pinned node image; an older kind will
# happily create a cluster from an unknown image and fail in obscure ways.
require_version kind \
  "$(kind version 2>/dev/null | awk '{print $2}' || true)" \
  "${MIN_KIND_VERSION}"

# --- kubectl --------------------------------------------------------------
require_version kubectl \
  "$(kubectl version --client -o json 2>/dev/null \
      | grep -oE '"gitVersion" *: *"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)" \
  "${MIN_KUBECTL_VERSION}"

# --- memory advisory ------------------------------------------------------
# Each cluster needs roughly 2 GB. Advisory only: Docker reports the VM
# allocation, not what is actually free, so a low number is a hint not a verdict.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
  mem_gb=$(( mem_bytes / 1024 / 1024 / 1024 ))
  if (( mem_gb >= 4 )); then
    ok "memory" "${mem_gb} GiB available to Docker"
  else
    warn "memory" "Docker reports ${mem_gb} GiB; two clusters need ~4 GiB"
  fi
fi

printf '\n  %soptional -- not on the critical path%s\n' "${DIM}" "${RESET}"
optional helm       "needed from session 2 to lint and template the chart"  helm version --short
optional flux       "make ui-flux falls back to kubectl without it"         flux version --client
optional argocd     "the UI works without it; the CLI is for rollbacks"     argocd version --client --short
optional shellcheck "make lint skips shell linting without it"              shellcheck --version
optional yamllint   "make lint skips YAML linting without it"               yamllint --version

printf '\n'
if (( failures > 0 )); then
  printf '  %s%d check(s) failed%s -- fix the above before running make up\n\n' \
    "${RED}" "${failures}" "${RESET}"
  exit 1
fi

if (( warnings > 0 )); then
  printf '  %sready%s, with %d warning(s)\n\n' "${GREEN}" "${RESET}" "${warnings}"
else
  printf '  %sready%s\n\n' "${GREEN}" "${RESET}"
fi
