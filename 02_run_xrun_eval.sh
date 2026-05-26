#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
activate_harness_venv

if [[ ! -d "${OPENTITAN_ROOT}/.git" ]]; then
  printf '[error] missing OpenTitan checkout: %s\n' "${OPENTITAN_ROOT}" >&2
  printf '[hint] run ./01_setup_opentitan.sh first\n' >&2
  exit 2
fi
if [[ ! -f "${TARGET_FILE}" ]]; then
  printf '[error] missing target file: %s\n' "${TARGET_FILE}" >&2
  exit 2
fi
if ! command -v xrun >/dev/null 2>&1; then
  printf '[error] xrun not found on PATH\n' >&2
  exit 2
fi

dvsim_cmd_text="$(resolve_dvsim_cmd)" || {
  printf '[error] could not find DVSim. Set DVSIM_BIN in config.env.\n' >&2
  exit 2
}
read -r -a dvsim_cmd <<< "${dvsim_cmd_text}"

opentitan_commit="$(git -C "${OPENTITAN_ROOT}" rev-parse HEAD)"
mkdir -p "${PRIVATE_OUT}/runs" "${USABLE_OUT}" "${DVSIM_SCRATCH_ROOT}"

printf '[info] opentitan=%s\n' "${OPENTITAN_ROOT}"
printf '[info] commit=%s\n' "${opentitan_commit}"
printf '[info] dvsim=%s\n' "${dvsim_cmd_text}"
printf '[info] targets=%s\n' "${TARGET_FILE}"
printf '[info] raw-private-out=%s\n' "${PRIVATE_OUT}"
printf '[info] usable-out=%s\n' "${USABLE_OUT}"

overall_rc=0
while IFS=$'\t' read -r test iteration seed build_mode reason; do
  [[ -z "${test:-}" || "${test:0:1}" == "#" ]] && continue
  slug="$(safe_slug "${iteration}_${test}_seed${seed}")"
  run_root="${PRIVATE_OUT}/runs/${slug}"
  mkdir -p "${run_root}"

  {
    printf 'TEST=%s\n' "${test}"
    printf 'ITERATION=%s\n' "${iteration}"
    printf 'SEED=%s\n' "${seed}"
    printf 'BUILD_MODE=%s\n' "${build_mode}"
    printf 'REASON=%s\n' "${reason}"
    printf 'OPENTITAN_COMMIT=%s\n' "${opentitan_commit}"
    printf 'DVSIM_TOOL=%s\n' "${DVSIM_TOOL}"
    printf 'DVSIM_WAVES=%s\n' "${DVSIM_WAVES}"
    printf 'RUN_ROOT=%s\n' "${run_root}"
  } > "${run_root}/run.env"

  cmd=(
    "${dvsim_cmd[@]}"
    "${OPENTITAN_ROOT}/${DVSIM_CFG}"
    --tool "${DVSIM_TOOL}"
    --waves "${DVSIM_WAVES}"
    --reseed 1
    --fixed-seed "${seed}"
    --scratch-root "${run_root}/scratch"
    --max-parallel "${DVSIM_MAX_PARALLEL}"
    -i "${test}"
  )
  if [[ -n "${DVSIM_EXTRA_ARGS:-}" ]]; then
    read -r -a extra_args <<< "${DVSIM_EXTRA_ARGS}"
    cmd+=("${extra_args[@]}")
  fi

  printf '[run] %s seed=%s reason=%s\n' "${test}" "${seed}" "${reason}"
  printf '%q ' "${cmd[@]}" > "${run_root}/command.sh"
  printf '\n' >> "${run_root}/command.sh"

  set +e
  (
    cd "${OPENTITAN_ROOT}"
    "${cmd[@]}"
  ) > >(tee "${run_root}/dvsim.console.log") 2> >(tee "${run_root}/dvsim.console.err" >&2)
  rc=$?
  set -e
  printf 'RC=%s\n' "${rc}" >> "${run_root}/run.env"
  printf '[done] %s rc=%s\n' "${test}" "${rc}"

  if (( rc != 0 )); then
    overall_rc="${rc}"
    if is_truthy "${STOP_ON_FAIL}"; then
      break
    fi
  fi
done < "${TARGET_FILE}"

collector_args=(
  --private-root "${PRIVATE_OUT}"
  --usable-out "${USABLE_OUT}"
  --target-file "${TARGET_FILE}"
  --signal-patterns "${HARNESS_ROOT}/tools/usable_signal_patterns.txt"
  --log-excerpt-lines "${LOG_EXCERPT_LINES}"
  --vcd-max-signals "${VCD_MAX_SIGNALS}"
  --vcd-max-events-per-signal "${VCD_MAX_EVENTS_PER_SIGNAL}"
  --max-raw-wave-bytes "${MAX_RAW_WAVE_BYTES}"
)
if is_truthy "${EXPORT_RAW_WAVES}"; then
  collector_args+=(--export-raw-waves)
fi
python3 "${HARNESS_ROOT}/tools/collect_usable_emissions.py" "${collector_args[@]}"

printf '[ok] usable emissions: %s\n' "${USABLE_OUT}"
exit "${overall_rc}"
