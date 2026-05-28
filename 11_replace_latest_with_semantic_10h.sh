#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
cd "${HARNESS_ROOT}"

if ! is_truthy "${STOP_CONFIRM:-0}"; then
  printf '[replace-semantic] dry-run only: set STOP_CONFIRM=1 to stop latest and launch semantic-10h\n' >&2
  ./10_stop_latest_detached.sh || true
  exit 2
fi

printf '[replace-semantic] stopping latest detached run if present\n'
STOP_CONFIRM=1 COLLECT_AFTER_STOP=0 ./10_stop_latest_detached.sh || true

if is_truthy "${PRUNE_ALL_DASHBOARD_PRIVATE:-0}"; then
  target="${PRIVATE_OUT}/runs/all-dashboard"
  if [[ -d "${target}" ]]; then
    printf '[replace-semantic] pruning old full-dashboard private tree: %s\n' "${target}"
    rm -rf "${target}"
  else
    printf '[replace-semantic] no old full-dashboard private tree at %s\n' "${target}"
  fi
fi

printf '[replace-semantic] launching semantic-10h no-wave run\n'
RUN_SETUP="${RUN_SETUP:-0}" ./run_detached_semantic_10h.sh
