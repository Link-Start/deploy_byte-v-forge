#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
CHART_DIR=${CHART_DIR:-$DEPLOY_DIR/iac/helm/byte-v-forge}
TRAEFIK_CHART=${TRAEFIK_CHART:-oci://ghcr.io/traefik/helm/traefik}
TRAEFIK_CHART_VERSION=${TRAEFIK_CHART_VERSION:-40.2.0}
TRAEFIK_VALUES_FILE=${TRAEFIK_VALUES_FILE:-$DEPLOY_DIR/iac/helm/traefik-values.yaml}
RELEASE=${RELEASE:-byte-v-forge}
NAMESPACE=${NAMESPACE:-byte-v-forge}
TRAEFIK_RELEASE=${TRAEFIK_RELEASE:-byte-v-forge-traefik}
TRAEFIK_NAMESPACE=${TRAEFIK_NAMESPACE:-traefik}
OUTPUT_DIR=${OUTPUT_DIR:-/tmp/byte-v-forge-validate}

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

mkdir -p "$OUTPUT_DIR"
cd "$DEPLOY_DIR"

log 'bash syntax'
find scripts -type f -name '*.sh' -print | sort | while IFS= read -r script; do
  bash -n "$script"
done

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
