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
if [[ -f "${run}/overnight.log" ]]; then
  grep -E '^\[batch-run\]|^\[batch-group\]|^\[batch-group-done\]|\[batch-done\]|ERROR: \[Scheduler\]|FAILED:|Traceback|Exception' \
    "${run}/overnight.log" | tail -120 || true
  printf '%s\n' '---- log tail ----'
  tail -n 80 "${run}/overnight.log" || true
else
  printf 'overnight log not found\n'
fi

printf '%s\n' '---- artifacts ----'
find "${PRIVATE_OUT}/runs/all-dashboard/groups" -path '*/latest/run.log' -type f 2>/dev/null | wc -l | awk '{print "run_logs=" $1}'
find "${PRIVATE_OUT}/runs/all-dashboard/groups" -type f \( -name '*.vcd' -o -name '*.evcd' \) 2>/dev/null | wc -l | awk '{print "waves=" $1}'
du -sh "${PRIVATE_OUT}" "${USABLE_OUT}" "${DETACHED_ROOT:-${HARNESS_ROOT}/detached-runs}" 2>/dev/null || true
df -h . || true

printf '%s\n' '---- related processes ----'
ps -u "${USER}" -o pid,ppid,pgid,sid,etime,stat,cmd \
  | grep -E 'screen|run_detached|overnight|dvsim|xrun|xcelium|bazel|bazelisk' \
  | grep -v grep || true
