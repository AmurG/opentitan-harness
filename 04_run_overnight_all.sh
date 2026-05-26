#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export TARGET_FILE="${TARGET_FILE:-${SCRIPT_DIR}/targets/xrun-overnight-all-dashboard.tsv}"
export BATCH_TARGETS="${BATCH_TARGETS:-1}"
export BATCH_NAME="${BATCH_NAME:-all-dashboard}"
export PURGE_RUN_ROOT="${PURGE_RUN_ROOT:-1}"
export STOP_ON_FAIL="${STOP_ON_FAIL:-0}"

exec "${SCRIPT_DIR}/02_run_xrun_eval.sh"
