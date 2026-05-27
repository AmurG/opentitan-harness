#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
cd "${HARNESS_ROOT}"

detached_root="${DETACHED_ROOT:-${HARNESS_ROOT}/detached-runs}"
latest="${detached_root}/latest"
grace="${STOP_GRACE_SECONDS:-10}"

if [[ ! -e "${latest}" ]]; then
  printf '[stop-latest] no latest detached run: %s\n' "${latest}"
  exit 0
fi

run="$(readlink -f "${latest}")"
pid="$(cat "${run}/pid" 2>/dev/null || true)"
printf '[stop-latest] run=%s\n' "${run}"
printf '[stop-latest] pid=%s\n' "${pid:-none}"

live=0
if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
  live=1
  ps -p "${pid}" -o pid,ppid,pgid,sid,etime,stat,cmd || true
else
  printf '[stop-latest] supervisor-not-running\n'
fi

if (( live )); then
  if ! is_truthy "${STOP_CONFIRM:-0}"; then
    printf '[stop-latest] dry-run: set STOP_CONFIRM=1 to terminate this process group\n' >&2
    printf '[stop-latest] example: STOP_CONFIRM=1 %q\n' "$0" >&2
    exit 2
  fi

  pgid="$(ps -o pgid= -p "${pid}" | tr -d ' ')"
  if [[ -z "${pgid}" || "${pgid}" == "0" ]]; then
    printf '[stop-latest] could not determine process group for pid=%s\n' "${pid}" >&2
    exit 2
  fi

  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${run}/stop_requested_utc"
  printf '[stop-latest] TERM process group %s\n' "${pgid}"
  kill -TERM "-${pgid}" 2>/dev/null || true
  sleep "${grace}"
  if kill -0 "${pid}" 2>/dev/null; then
    printf '[stop-latest] KILL process group %s after %ss grace\n' "${pgid}" "${grace}"
    kill -KILL "-${pgid}" 2>/dev/null || true
  fi
else
  if [[ -f "${run}/status" ]]; then
    printf '[stop-latest] status=%s\n' "$(cat "${run}/status")"
  fi
fi

if is_truthy "${COLLECT_AFTER_STOP:-0}"; then
  printf '[stop-latest] collecting partial usable emissions\n'
  ./08_collect_partial_usable_emissions.sh
  if is_truthy "${PACK_AFTER_STOP:-0}"; then
    ./03_pack_usable_emissions.sh
  fi
else
  printf '[stop-latest] collection skipped; set COLLECT_AFTER_STOP=1 to collect after stopping\n'
fi
