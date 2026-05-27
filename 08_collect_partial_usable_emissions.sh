#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

target_for_manifest="${PARTIAL_TARGET_FILE:-}"
if [[ -z "${target_for_manifest}" && -f "${PRIVATE_OUT}/runs/all-dashboard/selected_targets.tsv" ]]; then
  target_for_manifest="${PRIVATE_OUT}/runs/all-dashboard/selected_targets.tsv"
fi
if [[ -z "${target_for_manifest}" ]]; then
  target_for_manifest="$(
    find "${PRIVATE_OUT}/runs" -maxdepth 2 -name selected_targets.tsv -type f 2>/dev/null \
      | sort \
      | head -n 1
  )"
fi
if [[ -z "${target_for_manifest}" ]]; then
  target_for_manifest="${TARGET_FILE}"
fi

if [[ ! -d "${PRIVATE_OUT}/runs" ]]; then
  printf '[error] no private run output found under %s\n' "${PRIVATE_OUT}" >&2
  exit 2
fi
if [[ ! -f "${target_for_manifest}" ]]; then
  printf '[error] missing target file for manifest: %s\n' "${target_for_manifest}" >&2
  exit 2
fi

mkdir -p "${USABLE_OUT}"

collector_args=(
  --private-root "${PRIVATE_OUT}"
  --usable-out "${USABLE_OUT}"
  --target-file "${target_for_manifest}"
  --signal-patterns "${HARNESS_ROOT}/tools/usable_signal_patterns.txt"
  --log-excerpt-lines "${LOG_EXCERPT_LINES}"
  --vcd-max-signals "${VCD_MAX_SIGNALS}"
  --vcd-max-events-per-signal "${VCD_MAX_EVENTS_PER_SIGNAL}"
  --max-raw-wave-bytes "${MAX_RAW_WAVE_BYTES}"
)
if is_truthy "${EXPORT_RAW_WAVES}"; then
  collector_args+=(--export-raw-waves)
fi

printf '[collect-partial] private-root=%s\n' "${PRIVATE_OUT}"
printf '[collect-partial] usable-out=%s\n' "${USABLE_OUT}"
printf '[collect-partial] target-file=%s\n' "${target_for_manifest}"
printf '[collect-partial] note=best run after stopping the active simulator, or while accepting a race with live-written logs/waves\n'

python3 "${HARNESS_ROOT}/tools/collect_usable_emissions.py" "${collector_args[@]}"
printf '[ok] partial usable emissions: %s\n' "${USABLE_OUT}"
