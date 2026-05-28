#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

target_for_manifest="${PARTIAL_TARGET_FILE:-}"
generated_target_file=""
generated_target_sources=()

if [[ -z "${target_for_manifest}" && -n "${BATCH_NAME:-}" ]]; then
  batch_slug="$(safe_slug "${BATCH_NAME}")"
  if [[ -f "${PRIVATE_OUT}/runs/${batch_slug}/selected_targets.tsv" ]]; then
    target_for_manifest="${PRIVATE_OUT}/runs/${batch_slug}/selected_targets.tsv"
  fi
fi
if [[ -z "${target_for_manifest}" && -n "${COLLECT_INCLUDE_PRIVATE_PATH_REGEX:-}" ]]; then
  matching_targets=()
  while IFS= read -r candidate; do
    relative_candidate="${candidate#${PRIVATE_OUT}/}"
    if [[ "${relative_candidate}" =~ ${COLLECT_INCLUDE_PRIVATE_PATH_REGEX} ]]; then
      matching_targets+=("${candidate}")
    fi
  done < <(
    find "${PRIVATE_OUT}/runs" -name selected_targets.tsv -type f 2>/dev/null \
      | sort
  )
  if (( ${#matching_targets[@]} == 1 )); then
    target_for_manifest="${matching_targets[0]}"
  elif (( ${#matching_targets[@]} > 1 )); then
    generated_target_file="${USABLE_OUT}/_generated_selected_targets.tsv"
    generated_target_sources=("${matching_targets[@]}")
    target_for_manifest="${generated_target_file}"
  fi
fi
if [[ -z "${target_for_manifest}" && \
      "${COLLECT_INCLUDE_PRIVATE_PATH_REGEX:-}" == *signal-10h* && \
      -f "${HARNESS_ROOT}/targets/xrun-10h-signal.tsv" ]]; then
  target_for_manifest="${HARNESS_ROOT}/targets/xrun-10h-signal.tsv"
fi
if [[ -z "${target_for_manifest}" && \
      "${COLLECT_INCLUDE_PRIVATE_PATH_REGEX:-}" == *semantic-10h* && \
      -f "${HARNESS_ROOT}/targets/xrun-semantic-10h.tsv" ]]; then
  target_for_manifest="${HARNESS_ROOT}/targets/xrun-semantic-10h.tsv"
fi
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
if [[ -z "${generated_target_file}" && ! -f "${target_for_manifest}" ]]; then
  printf '[error] missing target file for manifest: %s\n' "${target_for_manifest}" >&2
  exit 2
fi

if is_truthy "${CLEAN_USABLE_OUT:-1}"; then
  if [[ -z "${USABLE_OUT}" || "${USABLE_OUT}" == "/" ]]; then
    printf '[error] refusing to clean unsafe USABLE_OUT=%s\n' "${USABLE_OUT}" >&2
    exit 2
  fi
  rm -rf "${USABLE_OUT}"
fi
mkdir -p "${USABLE_OUT}"

if [[ -n "${generated_target_file}" ]]; then
  {
    printf '# test\titeration\tseed\tbuild_mode\treason\n'
    awk 'NF && $0 !~ /^#/ {print}' "${generated_target_sources[@]}" | awk '!seen[$0]++'
  } > "${generated_target_file}"
fi
if [[ ! -f "${target_for_manifest}" ]]; then
  printf '[error] missing target file for manifest: %s\n' "${target_for_manifest}" >&2
  exit 2
fi

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
if [[ -n "${COLLECT_INCLUDE_PRIVATE_PATH_REGEX:-}" ]]; then
  collector_args+=(--include-private-path-regex "${COLLECT_INCLUDE_PRIVATE_PATH_REGEX}")
fi
if [[ -n "${VCD_SIGNATURE_MAX_BYTES:-}" ]]; then
  collector_args+=(--max-vcd-signature-bytes "${VCD_SIGNATURE_MAX_BYTES}")
fi
if is_truthy "${EXPORT_RAW_WAVES}"; then
  collector_args+=(--export-raw-waves)
fi

printf '[collect-partial] private-root=%s\n' "${PRIVATE_OUT}"
printf '[collect-partial] usable-out=%s\n' "${USABLE_OUT}"
printf '[collect-partial] target-file=%s\n' "${target_for_manifest}"
printf '[collect-partial] include-private-path-regex=%s\n' "${COLLECT_INCLUDE_PRIVATE_PATH_REGEX:-<all>}"
printf '[collect-partial] max-vcd-signature-bytes=%s\n' "${VCD_SIGNATURE_MAX_BYTES:-<unlimited>}"
printf '[collect-partial] clean-usable-out=%s\n' "${CLEAN_USABLE_OUT:-1}"
printf '[collect-partial] note=best run after stopping the active simulator, or while accepting a race with live-written logs/waves\n'

python3 "${HARNESS_ROOT}/tools/collect_usable_emissions.py" "${collector_args[@]}"
printf '[ok] partial usable emissions: %s\n' "${USABLE_OUT}"
