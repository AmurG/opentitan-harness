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
pgid="$(cat "${run}/pgid" 2>/dev/null || true)"
printf 'pgid=%s\n' "${pgid:-unknown}"
pgid_processes=0
if [[ -n "${pgid}" ]]; then
  pgid_processes="$(
    ps -u "${USER}" -o pgid= \
      | awk -v pgid="${pgid}" '$1 == pgid {count++} END {print count + 0}'
  )"
fi
printf 'pgid_processes=%s\n' "${pgid_processes}"
if [[ -n "${pid}" ]]; then
  ps -p "${pid}" -o pid,ppid,pgid,sid,etime,stat,cmd 2>/dev/null || \
    printf 'supervisor-not-running\n'
else
  printf 'supervisor-not-running\n'
fi
if [[ ! -f "${run}/status" && "${pgid_processes}" == "0" ]]; then
  printf 'status_note=latest run has no status file and no live recorded process group\n'
fi

printf '%s\n' '---- progress ----'
log_file=""
for candidate in "${run}/semantic.log" "${run}/signal.log" "${run}/overnight.log"; do
  if [[ -f "${candidate}" ]]; then
    log_file="${candidate}"
    break
  fi
done

if [[ -n "${log_file}" ]]; then
  printf 'log=%s\n' "${log_file}"
  log_bytes="$(stat -c %s "${log_file}" 2>/dev/null || printf unknown)"
  log_mtime_epoch="$(stat -c %Y "${log_file}" 2>/dev/null || printf '')"
  printf 'log_bytes=%s\n' "${log_bytes}"
  if [[ -n "${log_mtime_epoch}" ]]; then
    now_epoch="$(date -u +%s)"
    printf 'log_mtime_utc=%s\n' "$(date -u -d "@${log_mtime_epoch}" +%Y-%m-%dT%H:%M:%SZ)"
    printf 'log_age_seconds=%s\n' "$((now_epoch - log_mtime_epoch))"
  fi
  for rc_file in run_rc collect_rc archive_rc archive_path archive_bytes; do
    if [[ -f "${run}/${rc_file}" ]]; then
      printf '%s=%s\n' "${rc_file}" "$(cat "${run}/${rc_file}")"
    fi
  done
  batch_run_line="$(grep -E '^\[batch-run\]' "${log_file}" | tail -1 || true)"
  last_group_line="$(grep -E '^\[batch-group\]' "${log_file}" | tail -1 || true)"
  last_group_done_line="$(grep -E '^\[batch-group-done\]' "${log_file}" | tail -1 || true)"
  last_scheduler_line="$(grep -E 'ERROR: \[Scheduler\]' "${log_file}" | tail -1 || true)"
  groups_started="$(grep -c -E '^\[batch-group\]' "${log_file}" || true)"
  groups_done="$(grep -c -E '^\[batch-group-done\]' "${log_file}" || true)"
  groups_total="$(printf '%s\n' "${batch_run_line}" | sed -n 's/.* groups=\([0-9][0-9]*\).*/\1/p')"
  if [[ -n "${batch_run_line}" ]]; then
    printf 'batch_run=%s\n' "${batch_run_line}"
  fi
  printf 'groups_started=%s\n' "${groups_started}"
  printf 'groups_done=%s\n' "${groups_done}"
  if [[ -n "${groups_total}" ]]; then
    printf 'groups_total=%s\n' "${groups_total}"
  fi
  if [[ -n "${last_group_line}" ]]; then
    printf 'last_group=%s\n' "${last_group_line}"
  fi
  if [[ -n "${last_group_done_line}" ]]; then
    printf 'last_group_done=%s\n' "${last_group_done_line}"
  fi
  if [[ -n "${last_scheduler_line}" ]]; then
    printf 'last_scheduler_error=%s\n' "${last_scheduler_line}"
  fi
  grep -E '^\[batch-run\]|^\[batch-group\]|^\[batch-group-done\]|\[batch-done\]|ERROR: \[Scheduler\]|FAILED:|Traceback|Exception' \
    "${log_file}" | tail -120 || true
  printf '%s\n' '---- log tail ----'
  tail -n 80 "${log_file}" || true
else
  printf 'detached log not found\n'
fi

printf '%s\n' '---- artifacts ----'
artifact_root="${PRIVATE_OUT}/runs"
if [[ -f "${run}/semantic.log" && -d "${PRIVATE_OUT}/runs/semantic-10h" ]]; then
  artifact_root="${PRIVATE_OUT}/runs/semantic-10h"
fi
if [[ -f "${run}/signal.log" && -d "${PRIVATE_OUT}/runs/signal-10h" ]]; then
  artifact_root="${PRIVATE_OUT}/runs/signal-10h"
fi
printf 'artifact_root=%s\n' "${artifact_root}"
find "${artifact_root}" -path '*/latest/run.log' -type f 2>/dev/null | wc -l | awk '{print "run_logs=" $1}'
find "${artifact_root}" -type f \( -name '*.vcd' -o -name '*.evcd' \) 2>/dev/null | wc -l | awk '{print "waves=" $1}'
printf '%s\n' '---- newest run logs ----'
find "${artifact_root}" -path '*/latest/run.log' -type f -printf '%T@ %p\n' 2>/dev/null \
  | sort -nr \
  | head -10 \
  | awk '{print $2}'
du -sh "${artifact_root}" "${PRIVATE_OUT}" "${HARNESS_ROOT}"/usable-emissions* \
  "${DETACHED_ROOT:-${HARNESS_ROOT}/detached-runs}" 2>/dev/null || true
df -h . || true

printf '%s\n' '---- related processes ----'
ps -u "${USER}" -o pid,ppid,pgid,sid,etime,stat,cmd \
  | grep -E 'screen|run_detached|overnight|semantic|signal|dvsim|xrun|xcelium|bazel|bazelisk' \
  | grep -v grep || true
