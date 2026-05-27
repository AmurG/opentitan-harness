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
if ! is_truthy "${DVSIM_DRY_RUN:-0}" && ! command -v xrun >/dev/null 2>&1; then
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

run_collector() {
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
}

if is_truthy "${BATCH_TARGETS:-0}"; then
  batch_name="${BATCH_NAME:-$(basename "${TARGET_FILE}" .tsv)}"
  slug="$(safe_slug "${batch_name}")"
  run_root="${PRIVATE_OUT}/runs/${slug}"
  if is_truthy "${PURGE_RUN_ROOT:-0}"; then
    rm -rf "${run_root}"
  fi
  mkdir -p "${run_root}"

  tests=()
  seeds=()
  target_rows=0
  while IFS=$'\t' read -r test iteration seed build_mode reason; do
    [[ -z "${test:-}" || "${test:0:1}" == "#" ]] && continue
    tests+=("${test}")
    seeds+=("${seed}")
    target_rows=$((target_rows + 1))
  done < "${TARGET_FILE}"

  if (( target_rows == 0 )); then
    printf '[error] no targets in %s\n' "${TARGET_FILE}" >&2
    exit 2
  fi

  {
    printf 'BATCH_NAME=%s\n' "${batch_name}"
    printf 'TARGET_COUNT=%s\n' "${target_rows}"
    printf 'OPENTITAN_COMMIT=%s\n' "${opentitan_commit}"
    printf 'DVSIM_TOOL=%s\n' "${DVSIM_TOOL}"
    printf 'DVSIM_WAVES=%s\n' "${DVSIM_WAVES}"
    printf 'RUN_ROOT=%s\n' "${run_root}"
    printf 'TARGET_FILE=%s\n' "${TARGET_FILE}"
  } > "${run_root}/run.env"
  cp -f "${TARGET_FILE}" "${run_root}/selected_targets.tsv"

  python3 - "${TARGET_FILE}" "${run_root}" <<'PY'
from __future__ import annotations

from collections import OrderedDict
from pathlib import Path
import re
import sys

target_file = Path(sys.argv[1])
run_root = Path(sys.argv[2])
groups_dir = run_root / "groups"
groups_dir.mkdir(parents=True, exist_ok=True)

def safe_slug(text: str) -> str:
    text = re.sub(r"[^A-Za-z0-9._-]+", "_", text).strip("._-")
    return text or "unnamed"

groups: OrderedDict[str, list[list[str]]] = OrderedDict()
for raw in target_file.read_text(encoding="utf-8", errors="replace").splitlines():
    if not raw.strip() or raw.startswith("#"):
        continue
    parts = raw.split("\t")
    while len(parts) < 5:
        parts.append("")
    groups.setdefault(parts[0], []).append(parts[:5])

with (run_root / "groups.tsv").open("w", encoding="utf-8") as manifest:
    manifest.write("group_idx\ttest\tseed_count\tseeds\tgroup_dir\n")
    for idx, (test, rows) in enumerate(groups.items()):
        group_dir = groups_dir / f"{idx:04d}_{safe_slug(test)}"
        group_dir.mkdir(parents=True, exist_ok=True)
        (group_dir / "selected_targets.tsv").write_text(
            "# test\titeration\tseed\tbuild_mode\treason\n"
            + "\n".join("\t".join(row) for row in rows)
            + "\n",
            encoding="utf-8",
        )
        seeds = ",".join(row[2] for row in rows)
        manifest.write(f"{idx}\t{test}\t{len(rows)}\t{seeds}\t{group_dir}\n")
PY

  group_count="$(($(wc -l < "${run_root}/groups.tsv") - 1))"
  {
    printf 'BATCH_MODE=%s\n' "per-test-groups"
    printf 'GROUP_COUNT=%s\n' "${group_count}"
  } >> "${run_root}/run.env"

  printf '[batch-run] name=%s targets=%s groups=%s mode=per-test-groups\n' \
    "${batch_name}" "${target_rows}" "${group_count}"
  : > "${run_root}/command.sh"

  overall_rc=0
  while IFS=$'\t' read -r group_idx test seed_count seed_csv group_dir; do
    [[ "${group_idx}" == "group_idx" ]] && continue
    IFS=',' read -r -a group_seeds <<< "${seed_csv}"
    group_max_waves="${DVSIM_MAX_WAVES:-${seed_count}}"
    cmd=(
      "${dvsim_cmd[@]}"
      "${OPENTITAN_ROOT}/${DVSIM_CFG}"
      --tool "${DVSIM_TOOL}"
      --waves "${DVSIM_WAVES}"
      --max-waves "${group_max_waves}"
      --reseed "${seed_count}"
      --seeds "${group_seeds[@]}"
      --scratch-root "${group_dir}/scratch"
      --max-parallel "${DVSIM_MAX_PARALLEL}"
    )
    if [[ -n "${DVSIM_EXTRA_ARGS:-}" ]]; then
      read -r -a extra_args <<< "${DVSIM_EXTRA_ARGS}"
      cmd+=("${extra_args[@]}")
    fi
    cmd+=(-i "${test}")

    {
      printf 'TEST=%s\n' "${test}"
      printf 'TARGET_COUNT=%s\n' "${seed_count}"
      printf 'SEEDS=%s\n' "${seed_csv}"
      printf 'DVSIM_MAX_WAVES_EFFECTIVE=%s\n' "${group_max_waves}"
    } > "${group_dir}/group.env"

    printf '[batch-group] %s/%s test=%s seeds=%s max_waves=%s\n' \
      "$((group_idx + 1))" "${group_count}" "${test}" "${seed_count}" "${group_max_waves}"
    {
      printf '# group %s/%s test=%s seeds=%s\n' \
        "$((group_idx + 1))" "${group_count}" "${test}" "${seed_count}"
      printf '%q ' "${cmd[@]}"
      printf '\n'
    } > "${group_dir}/command.sh"
    cat "${group_dir}/command.sh" >> "${run_root}/command.sh"

    if is_truthy "${DVSIM_DRY_RUN:-0}"; then
      printf 'RC=%s\n' 0 >> "${group_dir}/group.env"
      printf '[dry-run] wrote command: %s\n' "${group_dir}/command.sh"
      continue
    fi

    set +e
    (
      cd "${OPENTITAN_ROOT}"
      "${cmd[@]}"
    ) > >(tee "${group_dir}/dvsim.console.log") 2> >(tee "${group_dir}/dvsim.console.err" >&2)
    rc=$?
    set -e
    printf 'RC=%s\n' "${rc}" >> "${group_dir}/group.env"
    printf '[batch-group-done] %s/%s test=%s rc=%s\n' \
      "$((group_idx + 1))" "${group_count}" "${test}" "${rc}"

    if (( rc != 0 )); then
      overall_rc="${rc}"
      if is_truthy "${STOP_ON_FAIL}"; then
        break
      fi
    fi
  done < "${run_root}/groups.tsv"

  printf 'RC=%s\n' "${overall_rc}" >> "${run_root}/run.env"
  printf '[batch-done] name=%s rc=%s groups=%s targets=%s\n' \
    "${batch_name}" "${overall_rc}" "${group_count}" "${target_rows}"

  run_collector
  printf '[ok] usable emissions: %s\n' "${USABLE_OUT}"
  exit "${overall_rc}"
fi

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
    --max-waves "${DVSIM_MAX_WAVES:-1}"
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

  if is_truthy "${DVSIM_DRY_RUN:-0}"; then
    printf 'RC=%s\n' 0 >> "${run_root}/run.env"
    printf '[dry-run] wrote command: %s\n' "${run_root}/command.sh"
    continue
  fi

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

run_collector

printf '[ok] usable emissions: %s\n' "${USABLE_OUT}"
exit "${overall_rc}"
