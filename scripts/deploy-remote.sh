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
BUILD_CREATED_AT=${BUILD_CREATED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
BUILD_PARALLELISM=${BUILD_PARALLELISM:-2}
DOCKER_BUILDKIT=${DOCKER_BUILDKIT:-1}
BUILDKIT_PROGRESS=${BUILDKIT_PROGRESS:-plain}
DOCKER_BUILD_PULL=${DOCKER_BUILD_PULL:-false}
DOCKER_BUILD_NO_CACHE=${DOCKER_BUILD_NO_CACHE:-false}
BUILD_CACHE_MAX_USED_SPACE=${BUILD_CACHE_MAX_USED_SPACE:-20GB}
SOURCE_REVISION=${SOURCE_REVISION:-}
RELEASE_MANIFEST=${RELEASE_MANIFEST:-}
ALLOW_DIRTY_SOURCE=${ALLOW_DIRTY_SOURCE:-false}
HELM_TIMEOUT=${HELM_TIMEOUT:-10m}
HELM_HISTORY_MAX=${HELM_HISTORY_MAX:-0}
ROLLOUT_TIMEOUT=${ROLLOUT_TIMEOUT:-5m}
IMAGE_TAGS_RETAIN=${IMAGE_TAGS_RETAIN:-1}
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
N8N_WORKFLOW_CHECKSUM_FILE=/tmp/byte-v-forge-n8n-workflows.sha256
N8N_WORKFLOW_MANIFEST_FILE=/tmp/byte-v-forge-n8n-workflows.manifest
N8N_WORKFLOW_IMPORT=${N8N_WORKFLOW_IMPORT:-auto}
N8N_WORKFLOW_IMPORT_ENABLED=false
N8N_WORKFLOW_IMPORT_FULL=false
N8N_WORKFLOW_IMPORT_FILES=
N8N_WORKFLOW_STATE_SEED=false
N8N_WORKFLOW_CHECKSUM=
N8N_WORKFLOW_MANIFEST=

BROWSER_FETCH_PROXY=${BROWSER_FETCH_PROXY:-http://host.docker.internal:10809}
METACUBEXD_GIT_PROXY=${METACUBEXD_GIT_PROXY:-}
BROWSER_AUTOMATION_RUNTIME_IMAGE=${BROWSER_AUTOMATION_RUNTIME_IMAGE:-${IMAGE_PREFIX}/browser-automation-runtime:camoufox-cloakbrowser-py3.12-bookworm}
REBUILD_BROWSER_AUTOMATION_RUNTIME=${REBUILD_BROWSER_AUTOMATION_RUNTIME:-false}
DEPLOY_REGISTRY_CONTAINER=${DEPLOY_REGISTRY_CONTAINER:-byte-v-forge-deploy-registry}
DEPLOY_REGISTRY_PUSH_ADDR=${DEPLOY_REGISTRY_PUSH_ADDR:-127.0.0.1:5050}
DEPLOY_REGISTRY_PULL_ADDR=${DEPLOY_REGISTRY_PULL_ADDR:-${IMPORT_HOST_IP}:30500}
CLEANUP_DEPLOY_REGISTRY=${CLEANUP_DEPLOY_REGISTRY:-true}
SKIP_SYNC=${SKIP_SYNC:-false}
SKIP_BUILD=${SKIP_BUILD:-false}
SKIP_IMPORT=${SKIP_IMPORT:-false}
SKIP_HELM=${SKIP_HELM:-false}
SKIP_VALIDATE=${SKIP_VALIDATE:-false}
SKIP_PREFLIGHT=${SKIP_PREFLIGHT:-false}
VALIDATE_ONLY=${VALIDATE_ONLY:-false}
KEEP_REMOTE_TAR=${KEEP_REMOTE_TAR:-false}
REMOTE_BUILD_CLEANUP_ALLOWED=false
DEPLOY_REGISTRY_STARTED=false

SERVICE_CATALOG=(
  "browser-automation|browser-automation|Dockerfile"
  "proxy-runtime|proxy-gateway|Dockerfile"
  "openai-sso-lite|openai-sso-lite|Dockerfile"
  "openai-sso-discord-bot|openai-sso-discord-bot|Dockerfile"
  "team-5000|team-5000|Dockerfile"
  "workflow-runtime|.|workflow-runtime/Dockerfile"
  "webui|.|webui/Dockerfile"
  "gpt-service|.|gpt/gpt-service/Dockerfile"
  "gpt-checkout|.|gpt-private/gopay/Dockerfile"
  "gopay-app|.|gopay-app/Dockerfile"
  "mailbox|mailbox|Dockerfile"
  "sms-service|sms|Dockerfile"
  "wa-app-service|.|wa-app/Dockerfile"
)

SOURCE_REPOS=(
  common-lib
  gpt
  gpt-private
  gopay-app
  mailbox
  webui
  sms
  browser-automation
  proxy-gateway
  openai-sso-lite
  openai-sso-discord-bot
  team-5000
  workflow-runtime
  wa-app
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
  --skip-preflight          Do not run local/remote command and source checks.
  --validate-only           Sync sources, render/lint Helm with the overlay, then exit.
  --build-parallelism N     Number of image builds to run concurrently. Default: 2.
  --build-pull              Pass --pull to docker build.
  --build-no-cache          Pass --no-cache to docker build.
  -h, --help                Show this help.

Environment overrides:
  REMOTE_KUBECONFIG, REMOTE_HELM, IMAGE_PREFIX, IMPORT_METHOD, VM_NAME,
  IMPORT_HOST_IP, IMPORT_HTTP_BIND, IMPORT_HTTP_PORT, HELM_TIMEOUT,
  HELM_HISTORY_MAX, ROLLOUT_TIMEOUT, IMAGE_TAGS_RETAIN, KEEP_REMOTE_TAR, SOURCE_ROOT, BROWSER_FETCH_PROXY,
  VALUES_FILE, BROWSER_AUTOMATION_RUNTIME_IMAGE, REBUILD_BROWSER_AUTOMATION_RUNTIME,
  METACUBEXD_GIT_PROXY, DEPLOY_REGISTRY_PUSH_ADDR, DEPLOY_REGISTRY_PULL_ADDR, TRAEFIK_ENABLED,
  TRAEFIK_RELEASE, TRAEFIK_NAMESPACE, TRAEFIK_CHART, TRAEFIK_CHART_VERSION,
  TRAEFIK_VALUES_FILE, BUILD_PARALLELISM, DOCKER_BUILDKIT, BUILDKIT_PROGRESS,
  DOCKER_BUILD_PULL, DOCKER_BUILD_NO_CACHE, BUILD_CACHE_MAX_USED_SPACE,
  SOURCE_REVISION, RELEASE_MANIFEST, ALLOW_DIRTY_SOURCE.
  BROWSER_FETCH_PROXY defaults to
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

source_dirty_allowed() {
  case "$ALLOW_DIRTY_SOURCE" in
    true|1)
      return 0
      ;;
    false|0)
      return 1
      ;;
    *)
      die "ALLOW_DIRTY_SOURCE must be true, false, 1, or 0"
      ;;
  esac
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

dockerfile_source_path() {
  local service context dockerfile
  service=$1
  context=$(docker_context "$service")
  dockerfile=$(dockerfile_path "$service")
  if [[ "$dockerfile" == /* || "$context" == "." ]]; then
    printf '%s' "$dockerfile"
  else
    printf '%s/%s' "$context" "$dockerfile"
  fi
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
      --skip-preflight)
        SKIP_PREFLIGHT=true
        shift
        ;;
      --validate-only)
        VALIDATE_ONLY=true
        shift
        ;;
      --build-parallelism)
        [[ $# -ge 2 ]] || die "--build-parallelism requires a value"
        BUILD_PARALLELISM=$2
        shift 2
        ;;
      --build-pull)
        DOCKER_BUILD_PULL=true
        shift
        ;;
      --build-no-cache)
        DOCKER_BUILD_NO_CACHE=true
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

  case "$BUILD_PARALLELISM" in
    ""|*[!0-9]*)
      die "BUILD_PARALLELISM must be a positive integer"
      ;;
  esac
  if [[ "$BUILD_PARALLELISM" -lt 1 ]]; then
    die "BUILD_PARALLELISM must be a positive integer"
  fi

  case "$DOCKER_BUILDKIT" in
    0|1) ;;
    *) die "DOCKER_BUILDKIT must be 0 or 1" ;;
  esac

  case "$DOCKER_BUILD_PULL" in
    true|false) ;;
    *) die "DOCKER_BUILD_PULL must be true or false" ;;
  esac

  case "$DOCKER_BUILD_NO_CACHE" in
    true|false) ;;
    *) die "DOCKER_BUILD_NO_CACHE must be true or false" ;;
  esac

  if [[ ! "$BUILD_CACHE_MAX_USED_SPACE" =~ ^[0-9]+([kKmMgGtTpP][bB]?)?$ ]]; then
    die "BUILD_CACHE_MAX_USED_SPACE must be a Docker size value such as 20GB or 0"
  fi

  case "$ALLOW_DIRTY_SOURCE" in
    true|false|1|0) ;;
    *) die "ALLOW_DIRTY_SOURCE must be true, false, 1, or 0" ;;
  esac

  case "$IMAGE_TAGS_RETAIN" in
    ""|*[!0-9]*)
      die "IMAGE_TAGS_RETAIN must be a non-negative integer"
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

  if service_selected "gpt-service" && ! service_selected "gpt-checkout"; then
    SERVICES+=("gpt-checkout")
  fi
}

init_deploy_metadata() {
  if [[ -n "$SOURCE_REVISION" ]]; then
    return
  fi

  if [[ -n "$RELEASE_MANIFEST" ]]; then
    local selected_csv manifest_args
    selected_csv=$(selected_source_repos_csv)
    manifest_args=(
      --manifest "$RELEASE_MANIFEST"
      --source-root "$SOURCE_ROOT"
      --selected-repos "$selected_csv"
      --print-source-revision
    )
    if source_dirty_allowed; then
      manifest_args+=(--allow-dirty)
    fi
    SOURCE_REVISION=$(python3 "$DEPLOY_DIR/scripts/validate-release-manifest.py" "${manifest_args[@]}") || die "release manifest validation failed"
    SOURCE_REVISION=${SOURCE_REVISION:-unknown}
    return
  fi

  local repo revision dirty selected
  selected=$(selected_source_repos)
  SOURCE_REVISION=""
  for repo in $selected; do
    [[ -d "$SOURCE_ROOT/$repo/.git" ]] || continue
    revision=$(git -C "$SOURCE_ROOT/$repo" rev-parse --short=12 HEAD 2>/dev/null || true)
    [[ -n "$revision" ]] || continue
    dirty=""
    if [[ -n "$(git -C "$SOURCE_ROOT/$repo" status --porcelain 2>/dev/null)" ]]; then
      dirty="+dirty"
    fi
    if [[ -n "$SOURCE_REVISION" ]]; then
      SOURCE_REVISION="${SOURCE_REVISION},"
    fi
    SOURCE_REVISION="${SOURCE_REVISION}${repo}:${revision}${dirty}"
  done
  SOURCE_REVISION=${SOURCE_REVISION:-unknown}
}

selected_source_repos_csv() {
  local first repo
  first=true
  for repo in $(selected_source_repos); do
    if [[ "$first" == "true" ]]; then
      first=false
    else
      printf ','
    fi
    printf '%s' "$repo"
  done
}

validate_source_release_manifest() {
  if [[ -z "$RELEASE_MANIFEST" ]]; then
    return
  fi

  local selected_csv manifest_args
  selected_csv=$(selected_source_repos_csv)
  manifest_args=(
    --manifest "$RELEASE_MANIFEST"
    --source-root "$SOURCE_ROOT"
    --selected-repos "$selected_csv"
  )
  if source_dirty_allowed; then
    manifest_args+=(--allow-dirty)
  fi
  python3 "$DEPLOY_DIR/scripts/validate-release-manifest.py" "${manifest_args[@]}" >/dev/null
}

ensure_clean_selected_sources() {
  if source_dirty_allowed; then
    log "dirty selected source repos allowed by ALLOW_DIRTY_SOURCE"
    return
  fi

  local repo dirty_repos
  dirty_repos=""
  for repo in $(selected_source_repos); do
    [[ -d "$SOURCE_ROOT/$repo/.git" ]] || continue
    if [[ -n "$(git -C "$SOURCE_ROOT/$repo" status --porcelain 2>/dev/null)" ]]; then
      dirty_repos="$dirty_repos $repo"
    fi
  done
  if [[ -n "$dirty_repos" ]]; then
    die "selected source repos have uncommitted changes:$dirty_repos; commit/stash them or set ALLOW_DIRTY_SOURCE=1"
  fi
}

validate_chart_source_manifest() {
  python3 "$DEPLOY_DIR/scripts/stage-chart-sources.py" \
    --manifest "$DEPLOY_DIR/chart-source-manifest.json" \
    --source-root "$SOURCE_ROOT" \
    --chart-files-dir "$DEPLOY_DIR/iac/helm/byte-v-forge/files" \
    --validate-only >/dev/null
}

preflight() {
  if [[ "$SKIP_PREFLIGHT" == "true" ]]; then
    log "skip preflight"
    return
  fi

  local command_name repo service dockerfile remote_checks
  for command_name in ssh rsync git python3; do
    command -v "$command_name" >/dev/null 2>&1 || die "$command_name is required locally"
  done

  if [[ "$SKIP_SYNC" != "true" ]]; then
    for repo in $(selected_source_repos); do
      [[ -d "$SOURCE_ROOT/$repo" ]] || die "missing source repo: $SOURCE_ROOT/$repo"
    done
    for service in "${SERVICES[@]}"; do
      dockerfile=$(dockerfile_source_path "$service")
      [[ -f "$SOURCE_ROOT/$dockerfile" ]] || die "missing Dockerfile for $service: $SOURCE_ROOT/$dockerfile"
    done
    if [[ -n "$RELEASE_MANIFEST" ]]; then
      validate_source_release_manifest || die "release manifest validation failed"
    else
      ensure_clean_selected_sources
    fi
    validate_chart_source_manifest || die "chart source manifest validation failed"
  fi

  remote_checks="command -v python3 >/dev/null"
  if [[ "$VALIDATE_ONLY" != "true" && "$SKIP_BUILD" != "true" ]]; then
    remote_checks="$remote_checks && command -v docker >/dev/null"
  fi
  if [[ "$SKIP_HELM" != "true" ]]; then
    remote_checks="$remote_checks && command -v kubectl >/dev/null && test -x $(shell_quote "$REMOTE_HELM")"
  fi
  log "preflight remote tooling"
  remote "$remote_checks" || die "remote preflight failed"
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

n8n_workflow_service_selected() {
  local service
  for service in "${SERVICES[@]}"; do
    case "$service" in
      gpt-service|gopay-app|workflow-runtime|n8n-main|n8n-webhook|n8n-worker)
        return 0
        ;;
    esac
  done
  return 1
}

n8n_workflow_checksum() {
  local workflow_dir="$DEPLOY_DIR/iac/helm/byte-v-forge/files/n8n-workflows"
  python3 - "$workflow_dir" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
if root.exists():
    for path in sorted(p for p in root.rglob("*.workflow.json") if p.is_file()):
        rel = path.relative_to(root).as_posix()
        digest.update(rel.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
print(digest.hexdigest())
PY
}

n8n_workflow_manifest() {
  local workflow_dir="$DEPLOY_DIR/iac/helm/byte-v-forge/files/n8n-workflows"
  python3 - "$workflow_dir" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
if not root.exists():
    raise SystemExit(0)

for path in sorted(p for p in root.rglob("*.workflow.json") if p.is_file()):
    rel = path.relative_to(root).as_posix()
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    print(f"{digest}\t{rel}")
PY
}

n8n_workflow_all_manifest_paths() {
  CURRENT_MANIFEST="$N8N_WORKFLOW_MANIFEST" python3 - <<'PY'
import os

for line in os.environ.get("CURRENT_MANIFEST", "").splitlines():
    if not line.strip():
        continue
    _, path = line.split("\t", 1)
    print(path)
PY
}

n8n_workflow_changed_paths() {
  local previous_manifest=$1
  PREVIOUS_MANIFEST="$previous_manifest" CURRENT_MANIFEST="$N8N_WORKFLOW_MANIFEST" python3 - <<'PY'
import os


def parse_manifest(value):
    result = {}
    for line in value.splitlines():
        if not line.strip():
            continue
        digest, path = line.split("\t", 1)
        result[path] = digest
    return result


previous = parse_manifest(os.environ.get("PREVIOUS_MANIFEST", ""))
current = parse_manifest(os.environ.get("CURRENT_MANIFEST", ""))
for path in sorted(current):
    if previous.get(path) != current[path]:
        print(path)
PY
}

n8n_workflow_deleted_count() {
  local previous_manifest=$1
  PREVIOUS_MANIFEST="$previous_manifest" CURRENT_MANIFEST="$N8N_WORKFLOW_MANIFEST" python3 - <<'PY'
import os


def parse_manifest(value):
    result = {}
    for line in value.splitlines():
        if not line.strip():
            continue
        digest, path = line.split("\t", 1)
        result[path] = digest
    return result


previous = parse_manifest(os.environ.get("PREVIOUS_MANIFEST", ""))
current = parse_manifest(os.environ.get("CURRENT_MANIFEST", ""))
print(sum(1 for path in previous if path not in current))
PY
}

non_empty_line_count() {
  awk 'NF { count++ } END { print count + 0 }'
}

n8n_workflow_import_required() {
  case "$N8N_WORKFLOW_IMPORT" in
    skip)
      N8N_WORKFLOW_IMPORT_ENABLED=false
      N8N_WORKFLOW_IMPORT_FULL=false
      N8N_WORKFLOW_IMPORT_FILES=
      N8N_WORKFLOW_STATE_SEED=false
      log "n8n workflow import skipped by N8N_WORKFLOW_IMPORT=skip"
      return 1
      ;;
    auto|force)
      ;;
    *)
      die "N8N_WORKFLOW_IMPORT must be auto, force, or skip"
      ;;
  esac

  if ! n8n_workflow_service_selected; then
    N8N_WORKFLOW_IMPORT_ENABLED=false
    N8N_WORKFLOW_IMPORT_FULL=false
    N8N_WORKFLOW_IMPORT_FILES=
    N8N_WORKFLOW_STATE_SEED=false
    return 1
  fi

  N8N_WORKFLOW_CHECKSUM=$(n8n_workflow_checksum)
  N8N_WORKFLOW_MANIFEST=$(n8n_workflow_manifest)
  if [[ "$N8N_WORKFLOW_IMPORT" == "force" ]]; then
    N8N_WORKFLOW_IMPORT_ENABLED=true
    N8N_WORKFLOW_IMPORT_FULL=true
    N8N_WORKFLOW_IMPORT_FILES=$(n8n_workflow_all_manifest_paths)
    N8N_WORKFLOW_STATE_SEED=false
    log "n8n workflow import forced"
    return 0
  fi

  local previous_manifest changed_count deleted_count
  previous_manifest=$(remote "cat $(shell_quote "$N8N_WORKFLOW_MANIFEST_FILE") 2>/dev/null || true")
  previous_manifest=${previous_manifest//$'\r'/}
  if [[ -n "$previous_manifest" ]]; then
    N8N_WORKFLOW_IMPORT_FILES=$(n8n_workflow_changed_paths "$previous_manifest")
    changed_count=$(printf '%s\n' "$N8N_WORKFLOW_IMPORT_FILES" | non_empty_line_count)
    deleted_count=$(n8n_workflow_deleted_count "$previous_manifest")
    if [[ "$changed_count" == "0" && "$deleted_count" == "0" ]]; then
      N8N_WORKFLOW_IMPORT_ENABLED=false
      N8N_WORKFLOW_IMPORT_FULL=false
      N8N_WORKFLOW_STATE_SEED=false
      log "n8n workflows unchanged; skip import"
      return 1
    fi

    N8N_WORKFLOW_IMPORT_ENABLED=true
    N8N_WORKFLOW_IMPORT_FULL=false
    N8N_WORKFLOW_STATE_SEED=false
    log "n8n workflows changed; import changed=$changed_count deleted=$deleted_count"
    return 0
  fi

  local previous
  previous=$(remote "cat $(shell_quote "$N8N_WORKFLOW_CHECKSUM_FILE") 2>/dev/null || true")
  previous=${previous//$'\r'/}
  previous=${previous//$'\n'/}
  if [[ -n "$previous" && "$previous" == "$N8N_WORKFLOW_CHECKSUM" ]]; then
    N8N_WORKFLOW_IMPORT_ENABLED=false
    N8N_WORKFLOW_IMPORT_FULL=false
    N8N_WORKFLOW_IMPORT_FILES=
    N8N_WORKFLOW_STATE_SEED=true
    log "n8n workflows unchanged; seed workflow manifest"
    return 1
  fi

  N8N_WORKFLOW_IMPORT_ENABLED=true
  N8N_WORKFLOW_IMPORT_FULL=true
  N8N_WORKFLOW_IMPORT_FILES=$(n8n_workflow_all_manifest_paths)
  N8N_WORKFLOW_STATE_SEED=false
  if [[ -z "$previous" ]]; then
    log "n8n workflows not initialized; enable import"
  else
    log "n8n workflows changed without manifest; enable full import"
  fi
  return 0
}

persist_n8n_workflow_state() {
  if [[ "$SKIP_HELM" == "true" || -z "$N8N_WORKFLOW_CHECKSUM" ]]; then
    return
  fi
  if [[ "$N8N_WORKFLOW_IMPORT_ENABLED" != "true" && "$N8N_WORKFLOW_STATE_SEED" != "true" ]]; then
    return
  fi
  log "persist n8n workflow manifest"
  remote "printf '%s\n' $(shell_quote "$N8N_WORKFLOW_CHECKSUM") > $(shell_quote "$N8N_WORKFLOW_CHECKSUM_FILE")"
  printf '%s\n' "$N8N_WORKFLOW_MANIFEST" | ssh -o ConnectTimeout=5 "$REMOTE_HOST" "cat > $(shell_quote "$N8N_WORKFLOW_MANIFEST_FILE")"
}

service_source_repos() {
  case "$1" in
    gpt-service)
      printf '%s\n' common-lib gpt mailbox
      ;;
    gpt-checkout)
      printf '%s\n' common-lib gpt gpt-private
      ;;
    gopay-app)
      printf '%s\n' common-lib gopay-app
      ;;
    webui)
      printf '%s\n' common-lib webui gpt mailbox sms gopay-app workflow-runtime
      ;;
    mailbox)
      printf '%s\n' mailbox
      ;;
    sms-service)
      printf '%s\n' common-lib sms
      ;;
    wa-app-service)
      printf '%s\n' wa-app
      ;;
    browser-automation)
      printf '%s\n' browser-automation
      ;;
    workflow-runtime)
      printf '%s\n' common-lib workflow-runtime
      ;;
    proxy-runtime)
      printf '%s\n' proxy-gateway
      ;;
    openai-sso-lite)
      printf '%s\n' openai-sso-lite
      ;;
    openai-sso-discord-bot)
      printf '%s\n' openai-sso-discord-bot
      ;;
    team-5000)
      printf '%s\n' team-5000
      ;;
    *)
      printf '%s\n' "${SOURCE_REPOS[@]}"
      ;;
  esac
}

stage_chart_sources() {
  python3 "$DEPLOY_DIR/scripts/stage-chart-sources.py" \
    --manifest "$DEPLOY_DIR/chart-source-manifest.json" \
    --source-root "$SOURCE_ROOT" \
    --chart-files-dir "$DEPLOY_DIR/iac/helm/byte-v-forge/files"
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
  remote "cd $(shell_quote "$REMOTE_DIR") && SOURCE_ROOT=$(shell_quote "$REMOTE_DIR") DASHBOARD_CATALOG_CONFIG=$(shell_quote "$REMOTE_DIR/dashboard-catalog.json") ./scripts/sync-dashboard-modules.sh"
}

ensure_browser_automation_runtime_image() {
  if [[ "$REBUILD_BROWSER_AUTOMATION_RUNTIME" != "true" ]] && remote "docker image inspect $(shell_quote "$BROWSER_AUTOMATION_RUNTIME_IMAGE") >/dev/null 2>&1"; then
    log "browser automation runtime image exists: $BROWSER_AUTOMATION_RUNTIME_IMAGE"
    return
  fi

  local build_flags=""
  if [[ -n "$BROWSER_FETCH_PROXY" ]]; then
    build_flags="--add-host=host.docker.internal:host-gateway --build-arg BROWSER_FETCH_PROXY=$(shell_quote "$BROWSER_FETCH_PROXY")"
  fi
  if [[ "$REBUILD_BROWSER_AUTOMATION_RUNTIME" == "true" ]]; then
    build_flags="$build_flags --no-cache"
  fi

  log "build browser automation runtime $BROWSER_AUTOMATION_RUNTIME_IMAGE"
  remote "cd $(shell_quote "$REMOTE_DIR") && docker build $build_flags -t $(shell_quote "$BROWSER_AUTOMATION_RUNTIME_IMAGE") -f browser-automation/Dockerfile.runtime browser-automation"
}

build_image() {
  local service context dockerfile dockerfile_arg image build_flags
  service=$1
  context=$(docker_context "$service")
  dockerfile=$(dockerfile_path "$service")
  dockerfile_arg=$dockerfile
  if [[ "$context" != "." && "$dockerfile" != /* ]]; then
    dockerfile_arg=$context/$dockerfile
  fi
  image=$(image_ref "$service")
  build_flags=""
  if [[ "$DOCKER_BUILD_PULL" == "true" ]]; then
    build_flags="$build_flags --pull"
  fi
  if [[ "$DOCKER_BUILD_NO_CACHE" == "true" ]]; then
    build_flags="$build_flags --no-cache"
  fi
  build_flags="$build_flags --label $(shell_quote "org.opencontainers.image.created=$BUILD_CREATED_AT")"
  build_flags="$build_flags --label $(shell_quote "org.opencontainers.image.version=$TAG")"
  build_flags="$build_flags --label $(shell_quote "org.opencontainers.image.revision=$SOURCE_REVISION")"
  build_flags="$build_flags --label $(shell_quote "org.opencontainers.image.source=byte-v-forge/$service")"
  if [[ "$service" == "browser-automation" ]]; then
    ensure_browser_automation_runtime_image
    build_flags="$build_flags --build-arg BROWSER_AUTOMATION_RUNTIME_IMAGE=$(shell_quote "$BROWSER_AUTOMATION_RUNTIME_IMAGE")"
  elif [[ "$service" == "proxy-runtime" && -n "$METACUBEXD_GIT_PROXY" ]]; then
    build_flags="$build_flags --add-host=host.docker.internal:host-gateway"
    build_flags="$build_flags --build-arg METACUBEXD_GIT_PROXY=$(shell_quote "$METACUBEXD_GIT_PROXY")"
  elif [[ "$service" == "gpt-service" ]]; then
    build_flags="$build_flags --target $(shell_quote "gpt_service_runtime")"
  fi
  log "build $image"
  remote "cd $(shell_quote "$REMOTE_DIR") && DOCKER_BUILDKIT=$(shell_quote "$DOCKER_BUILDKIT") BUILDKIT_PROGRESS=$(shell_quote "$BUILDKIT_PROGRESS") docker build $build_flags -t $(shell_quote "$image") -f $(shell_quote "$dockerfile_arg") $(shell_quote "$context")"
}

wait_build_batch() {
  local pid failed
  failed=0
  for pid in "$@"; do
    if ! wait "$pid"; then
      failed=1
    fi
  done
  [[ "$failed" == "0" ]]
}

build_images() {
  if [[ "$SKIP_BUILD" == "true" ]]; then
    log "skip build"
    return
  fi

  local service pids
  pids=()
  log "build parallelism: $BUILD_PARALLELISM"
  for service in "${SERVICES[@]}"; do
    build_image "$service" &
    pids+=("$!")
    if [[ "${#pids[@]}" -ge "$BUILD_PARALLELISM" ]]; then
      wait_build_batch "${pids[@]}" || die "one or more image builds failed"
      pids=()
    fi
  done
  if [[ "${#pids[@]}" -gt 0 ]]; then
    wait_build_batch "${pids[@]}" || die "one or more image builds failed"
  fi
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
  local push_port pull_host pull_port registry_volume
  push_port=${DEPLOY_REGISTRY_PUSH_ADDR##*:}
  pull_host=${DEPLOY_REGISTRY_PULL_ADDR%:*}
  pull_port=${DEPLOY_REGISTRY_PULL_ADDR##*:}
  registry_volume=${DEPLOY_REGISTRY_CONTAINER}-data

  log "ensure deploy registry push=$DEPLOY_REGISTRY_PUSH_ADDR pull=$DEPLOY_REGISTRY_PULL_ADDR"
  DEPLOY_REGISTRY_STARTED=true
  remote "set -e; \
    if docker inspect $(shell_quote "$DEPLOY_REGISTRY_CONTAINER") >/dev/null 2>&1; then \
      docker start $(shell_quote "$DEPLOY_REGISTRY_CONTAINER") >/dev/null 2>&1 || true; \
    else \
      docker volume create --label byte-v-forge.role=deploy-registry $(shell_quote "$registry_volume") >/dev/null; \
      docker run -d --name $(shell_quote "$DEPLOY_REGISTRY_CONTAINER") \
        --label byte-v-forge.role=deploy-registry \
        -p 127.0.0.1:$(shell_quote "$push_port"):5000 \
        -p $(shell_quote "$pull_host"):$(shell_quote "$pull_port"):5000 \
        -v $(shell_quote "$registry_volume"):/var/lib/registry \
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
  n8n_workflow_import_required || true
  {
    printf 'n8nWorkflows:\n'
    printf '  import:\n'
    if [[ "$N8N_WORKFLOW_IMPORT_ENABLED" == "true" ]]; then
      printf '    enabled: true\n'
    else
      printf '    enabled: false\n'
    fi
    if [[ "$N8N_WORKFLOW_IMPORT_FULL" == "true" ]]; then
      printf '    full: true\n'
    else
      printf '    full: false\n'
    fi
    if [[ -n "$N8N_WORKFLOW_IMPORT_FILES" ]]; then
      printf '    workflowFiles:\n'
      while IFS= read -r workflow_file; do
        [[ -n "$workflow_file" ]] || continue
        printf '      - %s\n' "$workflow_file"
      done <<<"$N8N_WORKFLOW_IMPORT_FILES"
    else
      printf '    workflowFiles: []\n'
    fi
    printf 'workloads:\n'
    local service
    for service in "${SERVICES[@]}"; do
      printf '  %s:\n' "$service"
      printf '    podAnnotations:\n'
      printf '      byte-v-forge/deploy-tag: "%s"\n' "$TAG"
      printf '      byte-v-forge/deploy-created-at: "%s"\n' "$BUILD_CREATED_AT"
      printf '      byte-v-forge/source-revision: "%s"\n' "$SOURCE_REVISION"
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
  remote "KUBECONFIG=$(shell_quote "$REMOTE_KUBECONFIG") $(shell_quote "$REMOTE_HELM") upgrade --install $(shell_quote "$RELEASE") $(shell_quote "$CHART_DIR") --namespace $(shell_quote "$NAMESPACE") --create-namespace --server-side=false --history-max $(shell_quote "$HELM_HISTORY_MAX") --rollback-on-failure --wait=watcher --wait-for-jobs --timeout $(shell_quote "$HELM_TIMEOUT") $flags"
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
  if [[ "$REMOTE_BUILD_CLEANUP_ALLOWED" != "true" || "${REMOTE_TAR:-}" == "" || "$KEEP_REMOTE_TAR" == "true" || "$SKIP_BUILD" == "true" ]]; then
    return
  fi
  log "cleanup remote image tars"
  remote "rm -f $(shell_quote "$REMOTE_TAR"); find /tmp -maxdepth 1 -type f -name 'byte-v-forge-images-*.tar' -delete" || true
}

cleanup_deploy_registry() {
  if [[ "$DEPLOY_REGISTRY_STARTED" != "true" || "$CLEANUP_DEPLOY_REGISTRY" != "true" || "$SKIP_IMPORT" == "true" ]]; then
    return
  fi
  log "cleanup deploy registry container"
  remote "docker rm -fv $(shell_quote "$DEPLOY_REGISTRY_CONTAINER") >/dev/null 2>&1 || true; docker volume rm -f $(shell_quote "${DEPLOY_REGISTRY_CONTAINER}-data") >/dev/null 2>&1 || true"
}

prune_remote_build_cache() {
  if [[ "$REMOTE_BUILD_CLEANUP_ALLOWED" != "true" || "$SKIP_BUILD" == "true" || "$DOCKER_BUILDKIT" != "1" ]]; then
    return
  fi

  log "prune remote BuildKit cache max-used-space=$BUILD_CACHE_MAX_USED_SPACE"
  remote "docker buildx prune --builder default --all --force --max-used-space $(shell_quote "$BUILD_CACHE_MAX_USED_SPACE") >/dev/null 2>&1 || true"
}

prune_remote_dangling_images() {
  if [[ "$REMOTE_BUILD_CLEANUP_ALLOWED" != "true" || "$SKIP_BUILD" == "true" ]]; then
    return
  fi

  log "prune remote dangling images"
  remote "docker image prune --force >/dev/null 2>&1 || true"
}

prune_remote_anonymous_volumes() {
  if [[ "$REMOTE_BUILD_CLEANUP_ALLOWED" != "true" || "$SKIP_BUILD" == "true" ]]; then
    return
  fi

  log "prune remote anonymous volumes"
  remote "docker volume prune --force --filter label=com.docker.volume.anonymous >/dev/null 2>&1 || true"
}

prune_remote_image_tags() {
  if [[ "$REMOTE_BUILD_CLEANUP_ALLOWED" != "true" || "$IMAGE_TAGS_RETAIN" == "0" || "$SKIP_BUILD" == "true" ]]; then
    return
  fi

  local runtime_repo services_csv
  runtime_repo=${BROWSER_AUTOMATION_RUNTIME_IMAGE%:*}
  services_csv=$(catalog_service_names | paste -sd, -)
  log "prune remote image tags keep=$IMAGE_TAGS_RETAIN"
  remote "IMAGE_PREFIX=$(shell_quote "$IMAGE_PREFIX") DEPLOY_REGISTRY_PUSH_ADDR=$(shell_quote "$DEPLOY_REGISTRY_PUSH_ADDR") BROWSER_AUTOMATION_RUNTIME_REPO=$(shell_quote "$runtime_repo") IMAGE_TAGS_RETAIN=$(shell_quote "$IMAGE_TAGS_RETAIN") DEPLOY_SERVICES=$(shell_quote "$services_csv") VM_NAME=$(shell_quote "$VM_NAME") bash -s" <<'REMOTE_SCRIPT'
set -Eeuo pipefail

keep=${IMAGE_TAGS_RETAIN:-1}
IFS=, read -r -a services <<<"${DEPLOY_SERVICES:-}"

prune_host_docker_repo() {
  local repo=$1
  local retain=$2
  mapfile -t tags < <(docker image ls "$repo" --format '{{.Tag}}' | awk 'NF && $1 != "<none>"' | sort -r)
  ((${#tags[@]} > retain)) || return 0

  local keep_set=" "
  local tag
  mapfile -t deploy_tags < <(printf '%s\n' "${tags[@]}" | awk '/^deploy-[0-9]{14}$/ {print}' | sort -r)
  if ((${#deploy_tags[@]} > 0)); then
    for tag in "${deploy_tags[@]:0:retain}"; do
      keep_set+="$tag "
    done
  else
    for tag in "${tags[@]:0:retain}"; do
      keep_set+="$tag "
    done
  fi

  for tag in "${tags[@]}"; do
    case "$keep_set" in
      *" $tag "*) continue ;;
    esac
    docker image rm "$repo:$tag" >/dev/null 2>&1 || true
  done
}

for service in "${services[@]}"; do
  [[ -n "$service" ]] || continue
  prune_host_docker_repo "${IMAGE_PREFIX%/}/$service" "$keep"
  prune_host_docker_repo "${DEPLOY_REGISTRY_PUSH_ADDR%/}/${IMAGE_PREFIX%/}/$service" 0
done

if [[ -n "${BROWSER_AUTOMATION_RUNTIME_REPO:-}" ]]; then
  prune_host_docker_repo "$BROWSER_AUTOMATION_RUNTIME_REPO" "$keep"
fi

REMOTE_SCRIPT
}

prepare_remote_build_space() {
  if [[ "$SKIP_BUILD" == "true" ]]; then
    return
  fi

  REMOTE_BUILD_CLEANUP_ALLOWED=true
  cleanup_remote_tar
  prune_remote_image_tags
  prune_remote_dangling_images
  prune_remote_anonymous_volumes
  prune_remote_build_cache
}

cleanup_on_exit() {
  local status=$?
  cleanup_remote_tar || true
  cleanup_deploy_registry || true
  prune_remote_image_tags || true
  prune_remote_dangling_images || true
  prune_remote_anonymous_volumes || true
  prune_remote_build_cache || true
  return "$status"
}

main() {
  parse_args "$@"
  trap cleanup_on_exit EXIT
  preflight
  init_deploy_metadata

  log "services: ${SERVICES[*]}"
  log "tag: $TAG"
  log "source revision: $SOURCE_REVISION"
  log "build created at: $BUILD_CREATED_AT"
  sync_source
  sync_dashboard_modules
  if [[ "$VALIDATE_ONLY" == "true" ]]; then
    write_overlay
    validate_chart
    log "validate-only done"
    return
  fi
  prepare_remote_build_space
  build_images
  save_images
  import_images
  write_overlay
  validate_chart
  helm_upgrade
  verify_rollout
  persist_n8n_workflow_state
  persist_live_values
  cleanup_remote_tar
  cleanup_deploy_registry
  prune_remote_image_tags
  prune_remote_dangling_images
  prune_remote_anonymous_volumes
  prune_remote_build_cache
  trap - EXIT
  log "done"
}

main "$@"
