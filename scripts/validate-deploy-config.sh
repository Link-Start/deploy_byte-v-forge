#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
SOURCE_ROOT=${SOURCE_ROOT:-$(cd -- "$DEPLOY_DIR/.." && pwd)}
CHART_DIR=${CHART_DIR:-$DEPLOY_DIR/iac/helm/byte-v-forge}
TRAEFIK_CHART=${TRAEFIK_CHART:-oci://ghcr.io/traefik/helm/traefik}
TRAEFIK_CHART_VERSION=${TRAEFIK_CHART_VERSION:-40.2.0}
TRAEFIK_VALUES_FILE=${TRAEFIK_VALUES_FILE:-$DEPLOY_DIR/iac/helm/traefik-values.yaml}
RELEASE=${RELEASE:-byte-v-forge}
NAMESPACE=${NAMESPACE:-byte-v-forge}
TRAEFIK_RELEASE=${TRAEFIK_RELEASE:-byte-v-forge-traefik}
TRAEFIK_NAMESPACE=${TRAEFIK_NAMESPACE:-traefik}
OUTPUT_DIR=${OUTPUT_DIR:-/tmp/byte-v-forge-validate}
RELEASE_MANIFEST=${RELEASE_MANIFEST:-}
ALLOW_DIRTY_SOURCE=${ALLOW_DIRTY_SOURCE:-false}

log() {
  printf '[validate] %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '[validate] error: %s is required\n' "$1" >&2
    exit 1
  }
}

require_command bash
require_command node
require_command helm
require_command python3

mkdir -p "$OUTPUT_DIR"
cd "$DEPLOY_DIR"

log 'bash syntax'
find scripts -type f -name '*.sh' -print | sort | while IFS= read -r script; do
  bash -n "$script"
done

log 'chart source manifest'
python3 scripts/stage-chart-sources.py \
  --manifest chart-source-manifest.json \
  --source-root "$SOURCE_ROOT" \
  --chart-files-dir iac/helm/byte-v-forge/files \
  --validate-only

log 'dashboard catalog'
python3 scripts/validate-dashboard-catalog.py \
  --catalog dashboard-catalog.json \
  --source-root "$SOURCE_ROOT"

log 'event topology'
python3 scripts/validate-event-topology.py \
  --manifest event-topology.json \
  --source-root "$SOURCE_ROOT"

log 'runtime adapter catalog'
python3 scripts/validate-runtime-adapters.py \
  --catalog runtime-adapter-catalog.json \
  --source-root "$SOURCE_ROOT"

if [[ -n "$RELEASE_MANIFEST" ]]; then
  release_manifest_args=(
    --manifest "$RELEASE_MANIFEST"
    --source-root "$SOURCE_ROOT"
  )
  case "$ALLOW_DIRTY_SOURCE" in
    true|1)
      release_manifest_args+=(--allow-dirty)
      ;;
    false|0)
      ;;
    *)
      printf '[validate] error: ALLOW_DIRTY_SOURCE must be true, false, 1, or 0\n' >&2
      exit 1
      ;;
  esac
  log 'release manifest'
  python3 scripts/validate-release-manifest.py "${release_manifest_args[@]}"
fi

log 'node syntax'
node --check iac/helm/byte-v-forge/files/n8n-sync-workflow-folders.js

log 'helm lint byte-v-forge'
helm lint "$CHART_DIR"

log 'helm template byte-v-forge'
helm template "$RELEASE" "$CHART_DIR" --namespace "$NAMESPACE" >"$OUTPUT_DIR/$RELEASE.yaml"

log 'helm template traefik'
helm template "$TRAEFIK_RELEASE" "$TRAEFIK_CHART" \
  --version "$TRAEFIK_CHART_VERSION" \
  --namespace "$TRAEFIK_NAMESPACE" \
  -f "$TRAEFIK_VALUES_FILE" >"$OUTPUT_DIR/$TRAEFIK_RELEASE.yaml"

log "rendered manifests: $OUTPUT_DIR"
