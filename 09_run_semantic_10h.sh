#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export TARGET_FILE="${TARGET_FILE:-${SCRIPT_DIR}/targets/xrun-semantic-10h.tsv}"
export BATCH_TARGETS="${BATCH_TARGETS:-1}"
export BATCH_NAME="${BATCH_NAME:-semantic-10h}"
export PURGE_RUN_ROOT="${PURGE_RUN_ROOT:-1}"
export STOP_ON_FAIL="${STOP_ON_FAIL:-0}"
export BATCH_PRESERVE_TARGET_ORDER="${BATCH_PRESERVE_TARGET_ORDER:-1}"
export BATCH_GROUP_MAX_SEEDS="${BATCH_GROUP_MAX_SEEDS:-1}"

# This is the important difference from the wave-signal run: do not pass
# --waves to DVSim at all. We want DVSim/UVM/checker/log feedback, not a
# private tree dominated by raw VCD I/O.
export DVSIM_WAVES="${DVSIM_WAVES:-off}"
export DVSIM_MAX_WAVES="${DVSIM_MAX_WAVES:-}"
export DVSIM_GROUP_TIMEOUT="${DVSIM_GROUP_TIMEOUT:-18m}"
export DVSIM_GROUP_TIMEOUT_KILL_AFTER="${DVSIM_GROUP_TIMEOUT_KILL_AFTER:-3m}"

export EXPORT_RAW_WAVES="${EXPORT_RAW_WAVES:-0}"
export MAX_RAW_WAVE_BYTES="${MAX_RAW_WAVE_BYTES:-0}"
export VCD_SIGNATURE_MAX_BYTES="${VCD_SIGNATURE_MAX_BYTES:-1}"
export LOG_EXCERPT_LINES="${LOG_EXCERPT_LINES:-360}"

exec "${SCRIPT_DIR}/02_run_xrun_eval.sh"
