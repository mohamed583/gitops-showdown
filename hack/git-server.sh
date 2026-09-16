#!/usr/bin/env bash
#
# hack/git-server.sh -- a local Git remote both clusters can reach.
#
# Without this, the "one commit, two engines" demonstration only works on the
# author's machine. Gitea runs as a container on the `kind` Docker network, so
# it is routable from both clusters, and CoreDNS in each cluster is given a
# hosts entry for it -- pods resolve through CoreDNS, not through Docker's DNS,
# so attaching to the network is necessary but not sufficient.
#
# Set GIT_REMOTE to point the engines at a real remote (GitHub, GitLab) and
# this script becomes a no-op.
#
# SECURITY: dev mode, default credentials, plain HTTP, no TLS. Bound to
# localhost. Read SECURITY.md before exposing it anywhere.
#
# Usage: git-server.sh up | down | status | url

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=hack/versions.env disable=SC1091
source "${SCRIPT_DIR}/versions.env"

GIT_REMOTE="${GIT_REMOTE:-}"
KIND_NETWORK="${KIND_NETWORK:-kind}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# What the engines use, from inside a cluster: the container's own port, not
# the port published on the host. Getting these two confused produces a URL
# that works from your terminal and fails in every pod.
internal_url() {
  printf 'http://%s:%s/%s/%s.git' \
    "${GITEA_HOSTNAME}" "${GITEA_HTTP_PORT}" "${GITEA_OWNER}" "${GITEA_REPO}"
}

# The host cannot resolve GITEA_HOSTNAME (that name lives only in each
# cluster's CoreDNS), so pushes go through the published port on localhost.
push_url() {
  printf 'http://%s:%s@localhost:%s/%s/%s.git' \
    "${GITEA_USER}" "${GITEA_PASSWORD}" "${GITEA_HOST_PORT}" "${GITEA_OWNER}" "${GITEA_REPO}"
}

container_ip() {
  docker inspect "${GITEA_CONTAINER}" \
    --format "{{(index .NetworkSettings.Networks \"${KIND_NETWORK}\").IPAddress}}" 2>/dev/null
}

# First start does more than boot a web server: it generates SSH host keys and
# initialises the SQLite schema, and /api/healthz reports 503 until the database
# check passes. Budget for that, and report the last status code seen -- a wait
# that fails silently tells you nothing about why.
wait_for_gitea() {
  local url="http://localhost:${GITEA_HOST_PORT}/api/healthz" code i
  log "waiting for Gitea to become healthy (first start initialises SQLite)"
  for i in $(seq 1 180); do
    # The fallback must NOT live inside the command substitution: curl writes
    # the status code to stdout and can still exit non-zero, and
    # `code="$(curl ... || echo 000)"` then concatenates both into "200000".
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${url}")" || code=000
    if [[ "${code}" == "200" ]]; then
      log "Gitea healthy after ~$((i * 2))s"
      return 0
    fi
    # Say something every 30s; a silent five-minute wait looks like a hang.
    if (( i % 15 == 0 )); then
      log "  still waiting (~$((i * 2))s, last HTTP status ${code})"
    fi
    sleep 2
  done
  die "Gitea never became healthy (last HTTP status: ${code}) -- try: docker logs ${GITEA_CONTAINER}"
}

start_container() {
  if docker ps -a --format '{{.Names}}' | grep -qx "${GITEA_CONTAINER}"; then
    if docker ps --format '{{.Names}}' | grep -qx "${GITEA_CONTAINER}"; then
      log "container ${GITEA_CONTAINER} already running"
    else
      log "starting existing container ${GITEA_CONTAINER}"
      docker start "${GITEA_CONTAINER}" >/dev/null
    fi
    return
  fi

  docker network inspect "${KIND_NETWORK}" >/dev/null 2>&1 \
    || die "Docker network '${KIND_NETWORK}' does not exist -- run 'make up' first"

  log "creating container ${GITEA_CONTAINER} on network ${KIND_NETWORK}"
  # INSTALL_LOCK skips the web installer entirely; sqlite3 keeps it to one
  # container. Registration is disabled so the only account is the one this
  # script creates.
  docker run -d \
    --name "${GITEA_CONTAINER}" \
    --network "${KIND_NETWORK}" \
    --restart unless-stopped \
    -p "${GITEA_HOST_PORT}:${GITEA_HTTP_PORT}" \
    -e GITEA__security__INSTALL_LOCK=true \
    -e GITEA__database__DB_TYPE=sqlite3 \
    -e GITEA__server__DOMAIN="${GITEA_HOSTNAME}" \
    -e GITEA__server__ROOT_URL="http://${GITEA_HOSTNAME}:${GITEA_HTTP_PORT}/" \
    -e GITEA__server__HTTP_PORT="${GITEA_HTTP_PORT}" \
    -e GITEA__service__DISABLE_REGISTRATION=true \
    -e GITEA__server__DISABLE_SSH=true \
    -e GITEA__repository__DEFAULT_BRANCH=main \
    -e GITEA__log__LEVEL=Warn \
    "${GITEA_IMAGE}" >/dev/null
}

create_user_and_repo() {
  # `-u git` is not optional: Gitea refuses to run as root, so a plain
  # `docker exec` returns a fatal-error banner instead of the user list, the
  # existence check silently finds nothing, and creation then fails on a user
  # that was there all along.
  if docker exec -u git "${GITEA_CONTAINER}" gitea admin user list 2>/dev/null \
       | awk 'NR > 1 {print $2}' | grep -qx "${GITEA_USER}"; then
    log "user ${GITEA_USER} already exists"
  else
    log "creating user ${GITEA_USER}"
    docker exec -u git "${GITEA_CONTAINER}" gitea admin user create \
      --username "${GITEA_USER}" \
      --password "${GITEA_PASSWORD}" \
      --email "${GITEA_USER}@showdown.local" \
      --admin --must-change-password=false >/dev/null
  fi

  local api="http://localhost:${GITEA_HOST_PORT}/api/v1"
  local auth="${GITEA_USER}:${GITEA_PASSWORD}"

  # No organisation is created. Gitea keeps users and organisations in a single
  # namespace, so an org cannot share a name with a user -- attempting both
  # fails with "user already exists". The repository lives under the user
  # account, which yields exactly the same clone URL.
  if curl -sf -u "${auth}" "${api}/repos/${GITEA_OWNER}/${GITEA_REPO}" >/dev/null 2>&1; then
    log "repo ${GITEA_OWNER}/${GITEA_REPO} already exists"
  else
    log "creating repo ${GITEA_OWNER}/${GITEA_REPO}"
    curl -sf -u "${auth}" -X POST "${api}/user/repos" \
      -H 'Content-Type: application/json' \
      -d "{\"name\":\"${GITEA_REPO}\",\"private\":false,\"default_branch\":\"main\"}" >/dev/null
  fi
}

# Pods resolve names through CoreDNS, which knows nothing about Docker's
# embedded DNS. Without this, source-controller and repo-server cannot resolve
# the Gitea hostname even though the container is on the same network.
patch_coredns() {
  local ip="$1" cluster ctx corefile
  for cluster in "${CLUSTER_ARGOCD}" "${CLUSTER_FLUX}"; do
    if ! kind get clusters 2>/dev/null | grep -qx "${cluster}"; then
      log "skipping CoreDNS in ${cluster} (cluster does not exist)"
      continue
    fi
    ctx="kind-${cluster}"

    corefile="$(kubectl --context "${ctx}" -n kube-system get configmap coredns \
                 -o jsonpath='{.data.Corefile}')"

    if printf '%s' "${corefile}" | grep -q "${GITEA_HOSTNAME}"; then
      # Re-point an existing entry: the container IP changes across recreates.
      corefile="$(printf '%s\n' "${corefile}" \
        | sed -E "s|^([[:space:]]*)[0-9.]+ ${GITEA_HOSTNAME}$|\1${ip} ${GITEA_HOSTNAME}|")"
      log "updating CoreDNS entry in ${cluster} -> ${ip}"
    else
      # Insert a hosts block immediately after the `ready` line, which every
      # kind Corefile has, so the block sits inside the server definition.
      corefile="$(printf '%s\n' "${corefile}" | awk -v ip="${ip}" -v host="${GITEA_HOSTNAME}" '
        { print }
        /^[[:space:]]*ready[[:space:]]*$/ && !done {
          print "    hosts {"
          print "        " ip " " host
          print "        fallthrough"
          print "    }"
          done = 1
        }')"
      log "adding CoreDNS entry in ${cluster} -> ${ip}"
    fi

    kubectl --context "${ctx}" -n kube-system create configmap coredns \
      --from-literal=Corefile="${corefile}" \
      --dry-run=client -o yaml \
      | kubectl --context "${ctx}" -n kube-system apply -f - >/dev/null

    kubectl --context "${ctx}" -n kube-system rollout restart deployment/coredns >/dev/null
    kubectl --context "${ctx}" -n kube-system rollout status deployment/coredns --timeout=120s >/dev/null
  done
}

push_repository() {
  log "pushing the working tree to ${GITEA_OWNER}/${GITEA_REPO}"
  git -C "${REPO_ROOT}" push --force "$(push_url)" HEAD:refs/heads/main >/dev/null 2>&1 \
    || die "push failed -- is everything committed?"
  log "pushed $(git -C "${REPO_ROOT}" rev-parse --short HEAD) to main"
}

cmd_up() {
  if [[ -n "${GIT_REMOTE}" ]]; then
    log "GIT_REMOTE is set (${GIT_REMOTE}) -- not starting the local Git server"
    return 0
  fi
  start_container
  wait_for_gitea
  create_user_and_repo
  local ip
  ip="$(container_ip)"
  [[ -n "${ip}" ]] || die "could not read the container IP on network ${KIND_NETWORK}"
  patch_coredns "${ip}"
  push_repository
  echo
  log "engines should use: $(internal_url)"
  log "you can browse:     http://localhost:${GITEA_HOST_PORT}/${GITEA_OWNER}/${GITEA_REPO}"
  log "credentials:        ${GITEA_USER} / ${GITEA_PASSWORD}  (dev only -- see SECURITY.md)"
}

cmd_down() {
  if docker ps -a --format '{{.Names}}' | grep -qx "${GITEA_CONTAINER}"; then
    log "removing ${GITEA_CONTAINER}"
    docker rm -f "${GITEA_CONTAINER}" >/dev/null
  else
    log "${GITEA_CONTAINER} is not present"
  fi
}

cmd_status() {
  if docker ps --format '{{.Names}}' | grep -qx "${GITEA_CONTAINER}"; then
    printf '  Gitea    running at %s (ip %s)\n' "$(internal_url)" "$(container_ip)"
    printf '  browse   http://localhost:%s/%s/%s\n' \
      "${GITEA_HOST_PORT}" "${GITEA_OWNER}" "${GITEA_REPO}"
  else
    printf '  Gitea    not running -- make git-server\n'
  fi
}

case "${1:-up}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  url)    internal_url; echo ;;
  *)      die "usage: $0 up|down|status|url" ;;
esac
