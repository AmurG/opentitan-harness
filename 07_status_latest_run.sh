#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
cd "${HARNESS_ROOT}"

latest="${DETACHED_ROOT:-${HARNESS_ROOT}/detached-runs}/latest"

printf '%s\n' '---- screen ----'
if command -v screen >/dev/null 2>&1; then
  screen -ls || true
else
  printf 'screen not found\n'
fi

printf '%s\n' '---- latest run ----'
if [[ ! -e "${latest}" ]]; then
  printf 'latest symlink not found: %s\n' "${latest}"
  exit 0
fi
run="$(readlink -f "${latest}")"
printf 'run=%s\n' "${run}"
ls -ld "${run}" || true

printf '%s\n' '---- status ----'
if [[ -f "${run}/status" ]]; then
  printf 'STATUS=%s\n' "$(cat "${run}/status")"
else
  printf 'STATUS=still-running-or-no-status\n'
fi
pid="$(cat "${run}/pid" 2>/dev/null || true)"
printf 'pid=%s\n' "${pid:-none}"
if [[ -n "${pid}" ]]; then
  ps -p "${pid}" -o pid,ppid,pgid,sid,etime,stat,cmd 2>/dev/null || \
    printf 'supervisor-not-running\n'
else
  printf 'supervisor-not-running\n'
fi

printf '%s\n' '---- progress ----'
log_file=""
for candidate in "${run}/signal.log" "${run}/overnight.log"; do
  if [[ -f "${candidate}" ]]; then
    log_file="${candidate}"
    break
  fi
done

if [[ -n "${log_file}" ]]; then
  printf 'log=%s\n' "${log_file}"
  for rc_file in run_rc collect_rc archive_rc archive_path archive_bytes; do
    if [[ -f "${run}/${rc_file}" ]]; then
      printf '%s=%s\n' "${rc_file}" "$(cat "${run}/${rc_file}")"
    fi
  done
  grep -E '^\[batch-run\]|^\[batch-group\]|^\[batch-group-done\]|\[batch-done\]|ERROR: \[Scheduler\]|FAILED:|Traceback|Exception' \
    "${log_file}" | tail -120 || true
  printf '%s\n' '---- log tail ----'
  tail -n 80 "${log_file}" || true
else
  printf 'detached log not found\n'
fi

printf '%s\n' '---- artifacts ----'
artifact_root="${PRIVATE_OUT}/runs"
if [[ -f "${run}/signal.log" && -d "${PRIVATE_OUT}/runs/signal-10h" ]]; then
  artifact_root="${PRIVATE_OUT}/runs/signal-10h"
fi
printf 'artifact_root=%s\n' "${artifact_root}"
find "${artifact_root}" -path '*/latest/run.log' -type f 2>/dev/null | wc -l | awk '{print "run_logs=" $1}'
find "${artifact_root}" -type f \( -name '*.vcd' -o -name '*.evcd' \) 2>/dev/null | wc -l | awk '{print "waves=" $1}'
du -sh "${artifact_root}" "${PRIVATE_OUT}" "${HARNESS_ROOT}"/usable-emissions* \
  "${DETACHED_ROOT:-${HARNESS_ROOT}/detached-runs}" 2>/dev/null || true
df -h . || true

printf '%s\n' '---- related processes ----'
ps -u "${USER}" -o pid,ppid,pgid,sid,etime,stat,cmd \
  | grep -E 'screen|run_detached|overnight|signal|dvsim|xrun|xcelium|bazel|bazelisk' \
  | grep -v grep || true
