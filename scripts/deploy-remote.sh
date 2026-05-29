#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
SOURCE_ROOT=${SOURCE_ROOT:-$(cd -- "$DEPLOY_DIR/.." && pwd)}
REMOTE_HOST=${REMOTE_HOST:-pood1e@192.168.0.126}
REMOTE_DIR=${REMOTE_DIR:-/tmp/byte-v-forge-build-src}
REMOTE_KUBECONFIG=${REMOTE_KUBECONFIG:-/tmp/self-hosted-business-kubeconfigs/byte-v-forge.yaml}
REMOTE_HELM=${REMOTE_HELM:-/home/pood1e/.local/bin/helm}
RELEASE=${RELEASE:-byte-v-forge}
NAMESPACE=${NAMESPACE:-byte-v-forge}
if [[ -z "${CHART_DIR+x}" ]]; then
  CHART_DIR=$REMOTE_DIR/iac/helm/byte-v-forge
  CHART_DIR_DEFAULTED=true
else
  CHART_DIR_DEFAULTED=false
fi
VALUES_FILE=${VALUES_FILE:-/tmp/byte-v-forge-deploy-values-live.yaml}
IMAGE_PREFIX=${IMAGE_PREFIX:-byte-v-forge}
TAG=${TAG:-deploy-$(date +%Y%m%d%H%M%S)}
HELM_TIMEOUT=${HELM_TIMEOUT:-10m}
ROLLOUT_TIMEOUT=${ROLLOUT_TIMEOUT:-5m}
TRAEFIK_ENABLED=${TRAEFIK_ENABLED:-false}
TRAEFIK_RELEASE=${TRAEFIK_RELEASE:-byte-v-forge-traefik}
TRAEFIK_NAMESPACE=${TRAEFIK_NAMESPACE:-traefik}
TRAEFIK_CHART=${TRAEFIK_CHART:-oci://ghcr.io/traefik/helm/traefik}
TRAEFIK_CHART_VERSION=${TRAEFIK_CHART_VERSION:-40.2.0}
if [[ -z "${TRAEFIK_VALUES_FILE+x}" ]]; then
  TRAEFIK_VALUES_FILE=$REMOTE_DIR/iac/helm/traefik-values.yaml
  TRAEFIK_VALUES_FILE_DEFAULTED=true
else
  TRAEFIK_VALUES_FILE_DEFAULTED=false
fi

IMPORT_METHOD=${IMPORT_METHOD:-auto}
VM_NAME=${VM_NAME:-byte-v-forge-1}
IMPORT_HOST_IP=${IMPORT_HOST_IP:-192.168.122.1}
IMPORT_HTTP_BIND=${IMPORT_HTTP_BIND:-$IMPORT_HOST_IP}
IMPORT_HTTP_PORT=${IMPORT_HTTP_PORT:-31888}
IMPORT_TIMEOUT_SECONDS=${IMPORT_TIMEOUT_SECONDS:-600}
REMOTE_TAR=${REMOTE_TAR:-/tmp/byte-v-forge-images-${TAG}.tar}

CAMOUFOX_FETCH_PROXY=${CAMOUFOX_FETCH_PROXY:-http://host.docker.internal:10809}
BROWSER_AUTOMATION_RUNTIME_IMAGE=${BROWSER_AUTOMATION_RUNTIME_IMAGE:-${IMAGE_PREFIX}/browser-automation-runtime:camoufox-0.4.11-playwright-1.59.0-py3.12-bookworm}
REBUILD_BROWSER_AUTOMATION_RUNTIME=${REBUILD_BROWSER_AUTOMATION_RUNTIME:-false}
if [[ -z "${GPT_ORCHESTRATOR_BUILD_TAGS+x}" ]]; then
  GPT_ORCHESTRATOR_BUILD_TAGS=
fi
GPT_SERVICE_BUILD_TARGET=${GPT_SERVICE_BUILD_TARGET:-}
DEPLOY_REGISTRY_CONTAINER=${DEPLOY_REGISTRY_CONTAINER:-byte-v-forge-deploy-registry}
DEPLOY_REGISTRY_PUSH_ADDR=${DEPLOY_REGISTRY_PUSH_ADDR:-127.0.0.1:5050}
DEPLOY_REGISTRY_PULL_ADDR=${DEPLOY_REGISTRY_PULL_ADDR:-${IMPORT_HOST_IP}:30500}
SKIP_SYNC=${SKIP_SYNC:-false}
SKIP_BUILD=${SKIP_BUILD:-false}
SKIP_IMPORT=${SKIP_IMPORT:-false}
SKIP_HELM=${SKIP_HELM:-false}
SKIP_VALIDATE=${SKIP_VALIDATE:-false}
KEEP_REMOTE_TAR=${KEEP_REMOTE_TAR:-false}

SERVICE_CATALOG=(
  "browser-automation|.|browser-automation/Dockerfile"
  "proxy-runtime|.|proxy-runtime/Dockerfile"
  "workflow-runtime|.|workflow-runtime/Dockerfile"
  "webui|.|webui/Dockerfile"
  "gpt-service|.|gpt/gpt-service/Dockerfile"
  "mailbox|.|mailbox/Dockerfile"
  "sms-service|.|sms/Dockerfile"
)

SOURCE_REPOS=(
  common-lib
  gpt
  gpt-private
  mailbox
  webui
  sms
  browser-automation
  proxy-runtime
  workflow-runtime
)

RSYNC_EXCLUDES=(
  --exclude '.git/'
  --exclude '.codex/'
  --exclude '.env'
  --exclude '.temp'
  --exclude '.tmp*/'
  --exclude '.venv*/'
  --exclude '**/__pycache__/'
  --exclude '**/.pytest_cache/'
  --exclude '**/node_modules/'
  --exclude '**/dist/'
  --exclude '**/build/'
  --exclude '**/*.log'
)

usage() {
  cat <<'EOF'
Usage:
  scripts/deploy-remote.sh [options] <service...|all>

Examples:
  scripts/deploy-remote.sh gpt-service webui
  scripts/deploy-remote.sh mailbox browser-automation
  scripts/deploy-remote.sh --tag deploy-test-1 webui
  scripts/deploy-remote.sh all

Options:
  --tag TAG                 Image tag to build and deploy.
  --remote HOST             SSH target. Default: pood1e@192.168.0.126
  --remote-dir DIR          Remote source/build directory.
  --chart-dir DIR           Remote Helm chart directory.
  --values FILE             Remote Helm values file used for install/upgrade.
  --release NAME            Helm release. Default: byte-v-forge
  --namespace NAME          Kubernetes namespace. Default: byte-v-forge
  --skip-sync               Do not rsync this workspace to the remote host.
  --skip-build              Do not docker build images.
  --skip-import             Do not import images into the k3s node.
  --skip-helm               Do not run Helm upgrade.
  --skip-validate           Do not run helm lint/template before upgrade.
  -h, --help                Show this help.

Environment overrides:
  REMOTE_KUBECONFIG, REMOTE_HELM, IMAGE_PREFIX, IMPORT_METHOD, VM_NAME,
  IMPORT_HOST_IP, IMPORT_HTTP_BIND, IMPORT_HTTP_PORT, HELM_TIMEOUT,
  ROLLOUT_TIMEOUT, KEEP_REMOTE_TAR, SOURCE_ROOT, CAMOUFOX_FETCH_PROXY,
  VALUES_FILE, BROWSER_AUTOMATION_RUNTIME_IMAGE, REBUILD_BROWSER_AUTOMATION_RUNTIME,
  GPT_ORCHESTRATOR_BUILD_TAGS, GPT_SERVICE_BUILD_TARGET,
  DEPLOY_REGISTRY_PUSH_ADDR, DEPLOY_REGISTRY_PULL_ADDR, TRAEFIK_ENABLED,
  TRAEFIK_RELEASE, TRAEFIK_NAMESPACE, TRAEFIK_CHART, TRAEFIK_CHART_VERSION,
  TRAEFIK_VALUES_FILE. CAMOUFOX_FETCH_PROXY defaults to
  http://host.docker.internal:10809 for browser-automation runtime builds.
EOF
}

log() {
  printf '[deploy] %s\n' "$*"
}

die() {
  printf '[deploy] error: %s\n' "$*" >&2
  exit 1
}

shell_quote() {
  printf '%q' "$1"
}

remote() {
  ssh -o ConnectTimeout=5 "$REMOTE_HOST" "$@"
}

valid_service() {
  service_catalog_field "$1" name >/dev/null
}

docker_context() {
  service_catalog_field "$1" context || die "unknown service: $1"
}

dockerfile_path() {
  service_catalog_field "$1" dockerfile || die "unknown service: $1"
}

service_catalog_field() {
  local requested=$1
  local field=$2
  local entry name context dockerfile
  for entry in "${SERVICE_CATALOG[@]}"; do
    IFS='|' read -r name context dockerfile <<<"$entry"
    if [[ "$name" != "$requested" ]]; then
      continue
    fi
    case "$field" in
      name)
        printf '%s' "$name"
        ;;
      context)
        printf '%s' "$context"
        ;;
      dockerfile)
        printf '%s' "$dockerfile"
        ;;
      *)
        return 1
        ;;
    esac
    return 0
  done
  return 1
}

catalog_service_names() {
  local entry name context dockerfile
  for entry in "${SERVICE_CATALOG[@]}"; do
    IFS='|' read -r name context dockerfile <<<"$entry"
    printf '%s\n' "$name"
  done
}

sync_one_repo() {
  local name=$1
  local source=$2
  local dest=$3
  if [[ ! -d "$source" ]]; then
    return
  fi
  log "sync $name source to $REMOTE_HOST:$dest"
  remote "mkdir -p $(shell_quote "$dest")"
  rsync -az --delete \
    "${RSYNC_EXCLUDES[@]}" \
    "$source/" "$REMOTE_HOST:$dest/"
}

image_ref() {
  printf '%s/%s:%s' "$IMAGE_PREFIX" "$1" "$TAG"
}

canonical_image_ref() {
  local image=$1
  local first_segment=${image%%/*}
  if [[ "$first_segment" == *.* || "$first_segment" == *:* || "$first_segment" == "localhost" ]]; then
    printf '%s' "$image"
    return
  fi
  printf 'docker.io/%s' "$image"
}

parse_args() {
  SERVICES=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag)
        [[ $# -ge 2 ]] || die "--tag requires a value"
        TAG=$2
        shift 2
        ;;
      --remote)
        [[ $# -ge 2 ]] || die "--remote requires a value"
        REMOTE_HOST=$2
        shift 2
        ;;
      --remote-dir)
        [[ $# -ge 2 ]] || die "--remote-dir requires a value"
        REMOTE_DIR=$2
        if [[ "$CHART_DIR_DEFAULTED" == "true" ]]; then
          CHART_DIR=$REMOTE_DIR/iac/helm/byte-v-forge
        fi
        if [[ "$TRAEFIK_VALUES_FILE_DEFAULTED" == "true" ]]; then
          TRAEFIK_VALUES_FILE=$REMOTE_DIR/iac/helm/traefik-values.yaml
        fi
        shift 2
        ;;
      --chart-dir)
        [[ $# -ge 2 ]] || die "--chart-dir requires a value"
        CHART_DIR=$2
        CHART_DIR_DEFAULTED=false
        shift 2
        ;;
      --values)
        [[ $# -ge 2 ]] || die "--values requires a value"
        VALUES_FILE=$2
        shift 2
        ;;
      --release)
        [[ $# -ge 2 ]] || die "--release requires a value"
        RELEASE=$2
        shift 2
        ;;
      --namespace)
        [[ $# -ge 2 ]] || die "--namespace requires a value"
        NAMESPACE=$2
        shift 2
        ;;
      --skip-sync)
        SKIP_SYNC=true
        shift
        ;;
      --skip-build)
        SKIP_BUILD=true
        shift
        ;;
      --skip-import)
        SKIP_IMPORT=true
        shift
        ;;
      --skip-helm)
        SKIP_HELM=true
        shift
        ;;
      --skip-validate)
        SKIP_VALIDATE=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          SERVICES+=("$1")
          shift
        done
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        SERVICES+=("$1")
        shift
        ;;
    esac
  done

  case "$IMPORT_METHOD" in
    auto|sudo|qga|registry) ;;
    *) die "IMPORT_METHOD must be auto, sudo, qga, or registry" ;;
  esac

  case "$TAG" in
    ""|*[!A-Za-z0-9_.-]*)
      die "invalid Docker tag: $TAG"
      ;;
  esac

  if [[ ${#SERVICES[@]} -eq 0 ]]; then
    usage
    die "service list is required; use all to deploy every workload"
  fi

  if [[ ${#SERVICES[@]} -eq 1 && ${SERVICES[0]} == "all" ]]; then
    SERVICES=()
    local service
    while IFS= read -r service; do
      SERVICES+=("$service")
    done < <(catalog_service_names)
  fi

  for service in "${SERVICES[@]}"; do
    valid_service "$service" || die "unknown service: $service"
  done
}

sync_source() {
  if [[ "$SKIP_SYNC" == "true" ]]; then
    log "skip sync"
    return
  fi

  stage_chart_sources

  local excludes repo
  excludes=("${RSYNC_EXCLUDES[@]}")
  for repo in "${SOURCE_REPOS[@]}"; do
    excludes+=(--exclude "/$repo/")
  done
  excludes+=(
    --exclude 'gopay-capture/'
    --exclude 'gopay-emulator/*.mitm'
  )

  log "sync source to $REMOTE_HOST:$REMOTE_DIR"
  remote "mkdir -p $(shell_quote "$REMOTE_DIR")"
  rsync -az --delete \
    "${excludes[@]}" \
    "$DEPLOY_DIR/" "$REMOTE_HOST:$REMOTE_DIR/"

  local repo_list
  repo_list=$(selected_source_repos)
  log "sync selected repos: $(printf '%s' "$repo_list" | tr '\n' ' ')"
  for repo in $repo_list; do
    [[ -n "$repo" ]] || continue
    sync_one_repo "$repo" "$SOURCE_ROOT/$repo" "$REMOTE_DIR/$repo"
  done
}

selected_source_repos() {
  local repo service
  local selected=""
  for service in "${SERVICES[@]}"; do
    for repo in $(service_source_repos "$service"); do
      case " $selected " in
        *" $repo "*) ;;
        *) selected="$selected $repo" ;;
      esac
    done
  done
  for repo in "${SOURCE_REPOS[@]}"; do
    case " $selected " in
      *" $repo "*) printf '%s\n' "$repo" ;;
    esac
  done
}

service_selected() {
  local target=$1
  local service
  for service in "${SERVICES[@]}"; do
    [[ "$service" == "$target" ]] && return 0
  done
  return 1
}

gpt_private_plugins_enabled() {
  local normalized=",${GPT_ORCHESTRATOR_BUILD_TAGS// /,},"
  [[ "$normalized" == *",private_plugins,"* ]]
}

gpt_service_build_target() {
  if [[ -n "$GPT_SERVICE_BUILD_TARGET" ]]; then
    printf '%s\n' "$GPT_SERVICE_BUILD_TARGET"
    return
  fi
  if gpt_private_plugins_enabled; then
    printf '%s\n' gpt_service_private_runtime
  else
    printf '%s\n' gpt_service_runtime
  fi
}

gpt_private_source_required() {
  [[ "$(gpt_service_build_target)" == "gpt_service_private_runtime" ]]
}

service_source_repos() {
  case "$1" in
    gpt-service)
      printf '%s\n' common-lib gpt mailbox
      if gpt_private_source_required; then
        printf '%s\n' gpt-private
      fi
      ;;
    webui)
      printf '%s\n' common-lib webui gpt mailbox sms browser-automation workflow-runtime
      ;;
    mailbox)
      printf '%s\n' common-lib mailbox
      ;;
    sms-service)
      printf '%s\n' common-lib sms
      ;;
    browser-automation)
      printf '%s\n' common-lib browser-automation
      ;;
    workflow-runtime)
      printf '%s\n' common-lib workflow-runtime
      ;;
    proxy-runtime)
      printf '%s\n' common-lib proxy-runtime
      ;;
    *)
      printf '%s\n' "${SOURCE_REPOS[@]}"
      ;;
  esac
}

stage_chart_sources() {
  local chart_files="$DEPLOY_DIR/iac/helm/byte-v-forge/files"
  mkdir -p "$chart_files/migrations"
  rm -rf "$chart_files/n8n-workflows"
  mkdir -p "$chart_files/n8n-workflows"
  rm -f "$chart_files/migrations/"*.sql
  cp "$SOURCE_ROOT/gpt/gpt-account/migrations/001_init.sql" "$chart_files/migrations/001_gpt_account.sql"
  cp "$SOURCE_ROOT/gpt/orchestrator/migrations/001_init.sql" "$chart_files/migrations/002_gpt_orchestrator.sql"
  cp "$SOURCE_ROOT/mailbox/services/mailbox-api/migrations/001_operations_outbox.sql" "$chart_files/migrations/003_mailbox_operations_outbox.sql"
  cp "$SOURCE_ROOT/sms/migrations/001_init.sql" "$chart_files/migrations/004_sms.sql"
  copy_workflow_tree "$SOURCE_ROOT/gpt/workflows/n8n" "$chart_files/n8n-workflows"
  if gpt_private_source_required && [ -d "$SOURCE_ROOT/gpt-private/workflows/n8n" ]; then
    copy_workflow_tree "$SOURCE_ROOT/gpt-private/workflows/n8n" "$chart_files/n8n-workflows"
  fi
}

copy_workflow_tree() {
  local source_dir=$1
  local target_dir=$2
  [ -d "$source_dir" ] || return 0
  mkdir -p "$target_dir"
  (
    cd "$source_dir"
    find . -type f -name '*.workflow.json' -print | while IFS= read -r file; do
      mkdir -p "$target_dir/$(dirname "$file")"
      cp "$file" "$target_dir/$file"
    done
  )
}

sync_dashboard_modules() {
  local service
  local needs_webui=false
  for service in "${SERVICES[@]}"; do
    if [[ "$service" == "webui" ]]; then
      needs_webui=true
      break
    fi
  done
  if [[ "$needs_webui" != "true" ]]; then
    return
  fi
  log "generate dashboard module registry"
  remote "cd $(shell_quote "$REMOTE_DIR") && SOURCE_ROOT=$(shell_quote "$REMOTE_DIR") FRONTEND_MODULES_CONFIG=$(shell_quote "$REMOTE_DIR/frontend-modules.json") ./scripts/sync-dashboard-modules.sh"
}

ensure_browser_automation_runtime_image() {
  if [[ "$REBUILD_BROWSER_AUTOMATION_RUNTIME" != "true" ]] && remote "docker image inspect $(shell_quote "$BROWSER_AUTOMATION_RUNTIME_IMAGE") >/dev/null 2>&1"; then
    log "browser automation runtime image exists: $BROWSER_AUTOMATION_RUNTIME_IMAGE"
    return
  fi

  local build_flags=""
  if [[ -n "$CAMOUFOX_FETCH_PROXY" ]]; then
    build_flags="--add-host=host.docker.internal:host-gateway --build-arg CAMOUFOX_FETCH_PROXY=$(shell_quote "$CAMOUFOX_FETCH_PROXY")"
  fi
  if [[ "$REBUILD_BROWSER_AUTOMATION_RUNTIME" == "true" ]]; then
    build_flags="$build_flags --no-cache"
  fi

  log "build browser automation runtime $BROWSER_AUTOMATION_RUNTIME_IMAGE"
  remote "cd $(shell_quote "$REMOTE_DIR") && docker build $build_flags -t $(shell_quote "$BROWSER_AUTOMATION_RUNTIME_IMAGE") -f browser-automation/Dockerfile.runtime browser-automation"
}

build_images() {
  if [[ "$SKIP_BUILD" == "true" ]]; then
    log "skip build"
    return
  fi

  local service context dockerfile dockerfile_arg image build_flags
  for service in "${SERVICES[@]}"; do
    context=$(docker_context "$service")
    dockerfile=$(dockerfile_path "$service")
    dockerfile_arg=$dockerfile
    if [[ "$context" != "." && "$dockerfile" != /* ]]; then
      dockerfile_arg=$context/$dockerfile
    fi
    image=$(image_ref "$service")
    build_flags=""
    if [[ "$service" == "browser-automation" ]]; then
      ensure_browser_automation_runtime_image
      build_flags="--build-arg BROWSER_AUTOMATION_RUNTIME_IMAGE=$(shell_quote "$BROWSER_AUTOMATION_RUNTIME_IMAGE")"
    elif [[ "$service" == "gpt-service" ]]; then
      build_flags="--target $(shell_quote "$(gpt_service_build_target)") --build-arg GPT_ORCHESTRATOR_BUILD_TAGS=$(shell_quote "$GPT_ORCHESTRATOR_BUILD_TAGS")"
    fi
    log "build $image"
    remote "cd $(shell_quote "$REMOTE_DIR") && docker build $build_flags -t $(shell_quote "$image") -f $(shell_quote "$dockerfile_arg") $(shell_quote "$context")"
  done
}

ensure_image_tar() {
  if [[ "$SKIP_BUILD" == "true" || "$SKIP_IMPORT" == "true" ]]; then
    return
  fi
  if remote "test -f $(shell_quote "$REMOTE_TAR")"; then
    return
  fi

  local images=()
  local service
  for service in "${SERVICES[@]}"; do
    images+=("$(image_ref "$service")")
  done

  local quoted_images=""
  for image in "${images[@]}"; do
    quoted_images+=" $(shell_quote "$image")"
  done

  log "save image tar on remote: $REMOTE_TAR"
  remote "docker save -o $(shell_quote "$REMOTE_TAR")$quoted_images"
}

save_images() {
  case "$IMPORT_METHOD" in
    auto|registry)
      log "defer image tar save; registry import will be tried first"
      ;;
    sudo|qga)
      ensure_image_tar
      ;;
  esac
}

import_images_qga() {
  local tar_path=$1
  log "import image tar into k3s via qemu guest agent"
  ssh -o ConnectTimeout=5 "$REMOTE_HOST" \
    "TAR_PATH=$(shell_quote "$tar_path") VM_NAME=$(shell_quote "$VM_NAME") IMPORT_HOST_IP=$(shell_quote "$IMPORT_HOST_IP") IMPORT_HTTP_BIND=$(shell_quote "$IMPORT_HTTP_BIND") IMPORT_HTTP_PORT=$(shell_quote "$IMPORT_HTTP_PORT") IMPORT_TIMEOUT_SECONDS=$(shell_quote "$IMPORT_TIMEOUT_SECONDS") bash -s" <<'REMOTE_SCRIPT'
set -Eeuo pipefail

die() {
  printf '[deploy] error: %s\n' "$*" >&2
  exit 1
}

command -v virsh >/dev/null 2>&1 || die "virsh is not available on remote host"
command -v python3 >/dev/null 2>&1 || die "python3 is not available on remote host"

tar_dir=$(dirname "$TAR_PATH")
tar_name=$(basename "$TAR_PATH")
url="http://${IMPORT_HOST_IP}:${IMPORT_HTTP_PORT}/${tar_name}"
pidfile="/tmp/byte-v-forge-import-http-${IMPORT_HTTP_PORT}.pid"
logfile="/tmp/byte-v-forge-import-http-${IMPORT_HTTP_PORT}.log"

cleanup() {
  if [[ -f "$pidfile" ]]; then
    old_pid=$(cat "$pidfile" 2>/dev/null || true)
    if [[ -n "${old_pid:-}" ]]; then
      kill "$old_pid" >/dev/null 2>&1 || true
    fi
    rm -f "$pidfile"
  fi
}
trap cleanup EXIT

cleanup
(
  cd "$tar_dir"
  python3 -m http.server "$IMPORT_HTTP_PORT" --bind "$IMPORT_HTTP_BIND" >"$logfile" 2>&1 &
  echo $! >"$pidfile"
)
sleep 1
server_pid=$(cat "$pidfile")
if ! kill -0 "$server_pid" >/dev/null 2>&1; then
  cat "$logfile" >&2 || true
  die "failed to start temporary HTTP server on ${IMPORT_HTTP_BIND}:${IMPORT_HTTP_PORT}"
fi

guest_cmd="set -e; rm -f /tmp/${tar_name}; curl -fsSL -o /tmp/${tar_name} ${url}; k3s ctr -n k8s.io images import /tmp/${tar_name}; rm -f /tmp/${tar_name}"
payload=$(GUEST_CMD="$guest_cmd" python3 - <<'PY'
import json
import os

print(json.dumps({
    "execute": "guest-exec",
    "arguments": {
        "path": "/bin/sh",
        "arg": ["-lc", os.environ["GUEST_CMD"]],
        "capture-output": True,
    },
}))
PY
)

start_json=$(virsh qemu-agent-command "$VM_NAME" "$payload")
guest_pid=$(printf '%s' "$start_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["return"]["pid"])')

for _ in $(seq 1 "$IMPORT_TIMEOUT_SECONDS"); do
  status_payload=$(PID="$guest_pid" python3 - <<'PY'
import json
import os

print(json.dumps({
    "execute": "guest-exec-status",
    "arguments": {"pid": int(os.environ["PID"])},
}))
PY
)
  status_json=$(virsh qemu-agent-command "$VM_NAME" "$status_payload")
  exited=$(printf '%s' "$status_json" | python3 -c 'import json,sys; print("1" if json.load(sys.stdin)["return"].get("exited") else "0")')
  if [[ "$exited" != "1" ]]; then
    sleep 1
    continue
  fi

  STATUS_JSON="$status_json" python3 - <<'PY'
import base64
import json
import os
import sys

status = json.loads(os.environ["STATUS_JSON"])["return"]
for key, stream in (("out-data", sys.stdout), ("err-data", sys.stderr)):
    value = status.get(key)
    if value:
        stream.write(base64.b64decode(value).decode("utf-8", "replace"))
PY
  exit_code=$(printf '%s' "$status_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["return"].get("exitcode", 1))')
  if [[ "$exit_code" != "0" ]]; then
    die "guest image import failed with exit code $exit_code"
  fi
  exit 0
done

die "guest image import timed out after ${IMPORT_TIMEOUT_SECONDS}s"
REMOTE_SCRIPT
}

ensure_deploy_registry() {
  local push_port pull_host pull_port
  push_port=${DEPLOY_REGISTRY_PUSH_ADDR##*:}
  pull_host=${DEPLOY_REGISTRY_PULL_ADDR%:*}
  pull_port=${DEPLOY_REGISTRY_PULL_ADDR##*:}

  log "ensure deploy registry push=$DEPLOY_REGISTRY_PUSH_ADDR pull=$DEPLOY_REGISTRY_PULL_ADDR"
  remote "set -e; \
    if docker inspect $(shell_quote "$DEPLOY_REGISTRY_CONTAINER") >/dev/null 2>&1; then \
      docker start $(shell_quote "$DEPLOY_REGISTRY_CONTAINER") >/dev/null; \
    else \
      docker run -d --restart unless-stopped --name $(shell_quote "$DEPLOY_REGISTRY_CONTAINER") \
        -p 127.0.0.1:$(shell_quote "$push_port"):5000 \
        -p $(shell_quote "$pull_host"):$(shell_quote "$pull_port"):5000 \
        registry:2 >/dev/null; \
    fi; \
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do \
      curl -fsS http://$(shell_quote "$DEPLOY_REGISTRY_PUSH_ADDR")/v2/ >/dev/null && exit 0; \
      sleep 1; \
    done; \
    exit 1"
}

push_registry_images() {
  local service image push_ref
  for service in "${SERVICES[@]}"; do
    image=$(image_ref "$service")
    push_ref="${DEPLOY_REGISTRY_PUSH_ADDR}/${image}"
    log "push registry image $push_ref"
    remote "docker tag $(shell_quote "$image") $(shell_quote "$push_ref") && docker push $(shell_quote "$push_ref")"
  done
}

import_images_registry() {
  ensure_deploy_registry || return 1
  push_registry_images || return 1

  local guest_cmd="set -e"
  local service image canonical pull_ref
  for service in "${SERVICES[@]}"; do
    image=$(image_ref "$service")
    canonical=$(canonical_image_ref "$image")
    pull_ref="${DEPLOY_REGISTRY_PULL_ADDR}/${image}"
    guest_cmd="$guest_cmd; k3s ctr -n k8s.io images pull --plain-http $(shell_quote "$pull_ref"); k3s ctr -n k8s.io images tag --force $(shell_quote "$pull_ref") $(shell_quote "$image")"
    if [[ "$canonical" != "$image" ]]; then
      guest_cmd="$guest_cmd; k3s ctr -n k8s.io images tag --force $(shell_quote "$pull_ref") $(shell_quote "$canonical")"
    fi
  done

  log "import images into k3s via registry"
  ssh -o ConnectTimeout=5 "$REMOTE_HOST" \
    "GUEST_CMD=$(shell_quote "$guest_cmd") VM_NAME=$(shell_quote "$VM_NAME") IMPORT_TIMEOUT_SECONDS=$(shell_quote "$IMPORT_TIMEOUT_SECONDS") bash -s" <<'REMOTE_SCRIPT'
set -Eeuo pipefail

die() {
  printf '[deploy] error: %s\n' "$*" >&2
  exit 1
}

command -v virsh >/dev/null 2>&1 || die "virsh is not available on remote host"
command -v python3 >/dev/null 2>&1 || die "python3 is not available on remote host"

payload=$(python3 - <<'PY'
import json
import os

print(json.dumps({
    "execute": "guest-exec",
    "arguments": {
        "path": "/bin/sh",
        "arg": ["-lc", os.environ["GUEST_CMD"]],
        "capture-output": True,
    },
}))
PY
)

start_json=$(virsh qemu-agent-command "$VM_NAME" "$payload")
guest_pid=$(printf '%s' "$start_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["return"]["pid"])')

for _ in $(seq 1 "$IMPORT_TIMEOUT_SECONDS"); do
  status_payload=$(PID="$guest_pid" python3 - <<'PY'
import json
import os

print(json.dumps({
    "execute": "guest-exec-status",
    "arguments": {"pid": int(os.environ["PID"])},
}))
PY
)
  status_json=$(virsh qemu-agent-command "$VM_NAME" "$status_payload")
  exited=$(printf '%s' "$status_json" | python3 -c 'import json,sys; print("1" if json.load(sys.stdin)["return"].get("exited") else "0")')
  if [[ "$exited" != "1" ]]; then
    sleep 1
    continue
  fi

  STATUS_JSON="$status_json" python3 - <<'PY'
import base64
import json
import os
import sys

status = json.loads(os.environ["STATUS_JSON"])["return"]
for key, stream in (("out-data", sys.stdout), ("err-data", sys.stderr)):
    value = status.get(key)
    if value:
        stream.write(base64.b64decode(value).decode("utf-8", "replace"))
PY
  exit_code=$(printf '%s' "$status_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["return"].get("exitcode", 1))')
  if [[ "$exit_code" != "0" ]]; then
    die "guest registry image import failed with exit code $exit_code"
  fi
  exit 0
done

die "guest registry image import timed out after ${IMPORT_TIMEOUT_SECONDS}s"
REMOTE_SCRIPT
}

import_images() {
  if [[ "$SKIP_IMPORT" == "true" ]]; then
    log "skip import"
    return
  fi

  if [[ "$SKIP_BUILD" == "true" ]]; then
    die "--skip-build cannot be combined with image import unless images were already saved by this script"
  fi

  case "$IMPORT_METHOD" in
    sudo)
      log "import image tar into k3s via sudo k3s ctr"
      ensure_image_tar
      remote "sudo -n k3s ctr -n k8s.io images import $(shell_quote "$REMOTE_TAR")"
      ;;
    qga)
      ensure_image_tar
      import_images_qga "$REMOTE_TAR"
      ;;
    registry)
      import_images_registry
      ;;
    auto)
      log "try sudo k3s ctr image import"
      if remote "sudo -n true"; then
        ensure_image_tar
        remote "sudo -n k3s ctr -n k8s.io images import $(shell_quote "$REMOTE_TAR")"
        return
      fi
      log "sudo import unavailable; try registry import"
      if import_images_registry; then
        return
      fi
      log "registry import unavailable; fallback to qemu guest agent"
      ensure_image_tar
      import_images_qga "$REMOTE_TAR"
      ;;
  esac
}

write_overlay() {
  OVERLAY_FILE=/tmp/byte-v-forge-deploy-overlay-${TAG}.yaml
  local tmp
  tmp=$(mktemp)
  {
    if service_selected gpt-service; then
      printf 'gptPrivate:\n'
      if gpt_private_source_required; then
        printf '  enabled: true\n'
      else
        printf '  enabled: false\n'
      fi
    fi
    printf 'workloads:\n'
    local service
    for service in "${SERVICES[@]}"; do
      printf '  %s:\n' "$service"
      printf '    image:\n'
      printf '      repository: %s/%s\n' "$IMAGE_PREFIX" "$service"
      printf '      tag: %s\n' "$TAG"
    done
  } >"$tmp"

  log "write Helm overlay: $OVERLAY_FILE"
  ssh -o ConnectTimeout=5 "$REMOTE_HOST" "cat > $(shell_quote "$OVERLAY_FILE")" <"$tmp"
  rm -f "$tmp"
}

helm_values_flags() {
  if remote "test -f $(shell_quote "$VALUES_FILE")"; then
    printf '%s' "-f $(shell_quote "$VALUES_FILE") -f $(shell_quote "$OVERLAY_FILE")"
  else
    printf '%s' "--reset-values -f $(shell_quote "$OVERLAY_FILE")"
  fi
}

helm_render_values_flags() {
  if remote "test -f $(shell_quote "$VALUES_FILE")"; then
    printf '%s' "-f $(shell_quote "$VALUES_FILE") -f $(shell_quote "$OVERLAY_FILE")"
  else
    printf '%s' "-f $(shell_quote "$OVERLAY_FILE")"
  fi
}

persist_live_values() {
  if [[ "$SKIP_HELM" == "true" ]]; then
    return
  fi
  if ! remote "test -f $(shell_quote "$VALUES_FILE")"; then
    return
  fi

  local services_csv
  services_csv=$(IFS=,; printf '%s' "${SERVICES[*]}")
  log "persist image tags into Helm values: $VALUES_FILE"
  remote "VALUES_FILE=$(shell_quote "$VALUES_FILE") IMAGE_PREFIX=$(shell_quote "$IMAGE_PREFIX") TAG=$(shell_quote "$TAG") DEPLOY_SERVICES=$(shell_quote "$services_csv") python3 - <<'PY'
import os
import shutil
import time

import yaml

path = os.environ['VALUES_FILE']
image_prefix = os.environ['IMAGE_PREFIX'].rstrip('/')
tag = os.environ['TAG']
services = [item for item in os.environ['DEPLOY_SERVICES'].split(',') if item]

with open(path, 'r', encoding='utf-8') as handle:
    values = yaml.safe_load(handle) or {}

workloads = values.setdefault('workloads', {})

for service in services:
    image = workloads.setdefault(service, {}).setdefault('image', {})
    image['repository'] = f'{image_prefix}/{service}'
    image['tag'] = tag

backup = f'{path}.bak-{int(time.time())}'
shutil.copy2(path, backup)
tmp = f'{path}.tmp'
with open(tmp, 'w', encoding='utf-8') as handle:
    yaml.safe_dump(values, handle, sort_keys=False, allow_unicode=True)
os.replace(tmp, path)
print(f'updated {path}; backup {backup}')
PY"
}

validate_chart() {
  if [[ "$SKIP_VALIDATE" == "true" || "$SKIP_HELM" == "true" ]]; then
    return
  fi

  local flags rendered
  if [[ "$TRAEFIK_ENABLED" == "true" ]]; then
    log "traefik helm template"
    remote "KUBECONFIG=$(shell_quote "$REMOTE_KUBECONFIG") $(shell_quote "$REMOTE_HELM") template $(shell_quote "$TRAEFIK_RELEASE") $(shell_quote "$TRAEFIK_CHART") --version $(shell_quote "$TRAEFIK_CHART_VERSION") --namespace $(shell_quote "$TRAEFIK_NAMESPACE") -f $(shell_quote "$TRAEFIK_VALUES_FILE") > $(shell_quote "/tmp/${TRAEFIK_RELEASE}-${TAG}.rendered.yaml")"
  fi

  flags=$(helm_render_values_flags)
  rendered="/tmp/${RELEASE}-${TAG}.rendered.yaml"
  log "helm lint/template"
  remote "KUBECONFIG=$(shell_quote "$REMOTE_KUBECONFIG") $(shell_quote "$REMOTE_HELM") lint $(shell_quote "$CHART_DIR") $flags"
  remote "KUBECONFIG=$(shell_quote "$REMOTE_KUBECONFIG") $(shell_quote "$REMOTE_HELM") template $(shell_quote "$RELEASE") $(shell_quote "$CHART_DIR") --namespace $(shell_quote "$NAMESPACE") $flags > $(shell_quote "$rendered")"
}

helm_upgrade() {
  if [[ "$SKIP_HELM" == "true" ]]; then
    log "skip helm"
    return
  fi

  local flags
  if [[ "$TRAEFIK_ENABLED" == "true" ]]; then
    log "helm upgrade traefik release=$TRAEFIK_RELEASE namespace=$TRAEFIK_NAMESPACE"
    remote "KUBECONFIG=$(shell_quote "$REMOTE_KUBECONFIG") $(shell_quote "$REMOTE_HELM") upgrade --install $(shell_quote "$TRAEFIK_RELEASE") $(shell_quote "$TRAEFIK_CHART") --version $(shell_quote "$TRAEFIK_CHART_VERSION") --namespace $(shell_quote "$TRAEFIK_NAMESPACE") --create-namespace --rollback-on-failure --wait=watcher --wait-for-jobs --timeout $(shell_quote "$HELM_TIMEOUT") -f $(shell_quote "$TRAEFIK_VALUES_FILE")"
  fi

  flags=$(helm_values_flags)
  log "helm upgrade release=$RELEASE namespace=$NAMESPACE tag=$TAG"
  remote "KUBECONFIG=$(shell_quote "$REMOTE_KUBECONFIG") $(shell_quote "$REMOTE_HELM") upgrade --install $(shell_quote "$RELEASE") $(shell_quote "$CHART_DIR") --namespace $(shell_quote "$NAMESPACE") --create-namespace --server-side=false --rollback-on-failure --wait=watcher --wait-for-jobs --timeout $(shell_quote "$HELM_TIMEOUT") $flags"
}

verify_rollout() {
  if [[ "$SKIP_HELM" == "true" ]]; then
    return
  fi

  local service deploy_name
  for service in "${SERVICES[@]}"; do
    deploy_name="${RELEASE}-${service}"
    log "verify rollout $deploy_name"
    remote "kubectl --kubeconfig $(shell_quote "$REMOTE_KUBECONFIG") -n $(shell_quote "$NAMESPACE") rollout status deploy/$(shell_quote "$deploy_name") --timeout=$(shell_quote "$ROLLOUT_TIMEOUT")"
  done

  log "current images"
  remote "kubectl --kubeconfig $(shell_quote "$REMOTE_KUBECONFIG") -n $(shell_quote "$NAMESPACE") get deploy -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,READY:.status.readyReplicas,UPDATED:.status.updatedReplicas,AVAILABLE:.status.availableReplicas"
}

cleanup_remote_tar() {
  if [[ "${REMOTE_TAR:-}" == "" || "$KEEP_REMOTE_TAR" == "true" || "$SKIP_BUILD" == "true" || "$SKIP_IMPORT" == "true" ]]; then
    return
  fi
  remote "rm -f $(shell_quote "$REMOTE_TAR")" || true
}

main() {
  parse_args "$@"

  log "services: ${SERVICES[*]}"
  log "tag: $TAG"
  sync_source
  sync_dashboard_modules
  build_images
  save_images
  import_images
  write_overlay
  validate_chart
  helm_upgrade
  verify_rollout
  persist_live_values
  cleanup_remote_tar
  log "done"
}

main "$@"
