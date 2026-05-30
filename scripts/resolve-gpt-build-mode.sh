#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
SOURCE_ROOT=${SOURCE_ROOT:-$(cd -- "$DEPLOY_DIR/.." && pwd)}

if [[ -d "$SOURCE_ROOT/gpt-private/plugins" && -d "$SOURCE_ROOT/gpt-private/gopay" ]]; then
  printf 'GPT_PRIVATE_AVAILABLE=true\n'
  printf 'GPT_SERVICE_BUILD_TARGET=gpt_service_private_runtime\n'
  printf 'GPT_ORCHESTRATOR_BUILD_TAGS=private_plugins\n'
else
  printf 'GPT_PRIVATE_AVAILABLE=false\n'
  printf 'GPT_SERVICE_BUILD_TARGET=gpt_service_runtime\n'
  printf 'GPT_ORCHESTRATOR_BUILD_TAGS=\n'
fi
