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
stored_pgid="$(cat "${run}/pgid" 2>/dev/null || true)"
printf '[stop-latest] run=%s\n' "${run}"
printf '[stop-latest] pid=%s\n' "${pid:-none}"
printf '[stop-latest] pgid=%s\n' "${stored_pgid:-unknown}"

live=0
pgid_to_stop=""
if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
  live=1
  ps -p "${pid}" -o pid,ppid,pgid,sid,etime,stat,cmd || true
  pgid_to_stop="$(ps -o pgid= -p "${pid}" | tr -d ' ')"
else
  printf '[stop-latest] supervisor-not-running\n'
  if [[ -n "${stored_pgid}" ]]; then
    related="$(
      ps -u "${USER}" -o pid=,pgid=,cmd= \
        | awk -v pgid="${stored_pgid}" '$2 == pgid {print $1}' \
        | tr '\n' ' '
    )"
    if [[ -n "${related// /}" ]]; then
      live=1
      pgid_to_stop="${stored_pgid}"
      printf '[stop-latest] related-processes-in-pgid=%s\n' "${related}"
      ps -u "${USER}" -o pid,ppid,pgid,sid,etime,stat,cmd \
        | awk -v pgid="${stored_pgid}" '$3 == pgid {print}'
    fi
  fi
fi

if (( live )); then
  if ! is_truthy "${STOP_CONFIRM:-0}"; then
    printf '[stop-latest] dry-run: set STOP_CONFIRM=1 to terminate this process group\n' >&2
    printf '[stop-latest] example: STOP_CONFIRM=1 %q\n' "$0" >&2
    exit 2
  fi

  if [[ -z "${pgid_to_stop}" || "${pgid_to_stop}" == "0" ]]; then
    printf '[stop-latest] could not determine process group for pid=%s\n' "${pid:-none}" >&2
    exit 2
  fi

  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${run}/stop_requested_utc"
  printf '[stop-latest] TERM process group %s\n' "${pgid_to_stop}"
  kill -TERM "-${pgid_to_stop}" 2>/dev/null || true
  sleep "${grace}"
  remaining="$(
    ps -u "${USER}" -o pid=,pgid=,cmd= \
      | awk -v pgid="${pgid_to_stop}" '$2 == pgid {print $1}' \
      | tr '\n' ' '
  )"
  if [[ -n "${remaining// /}" ]]; then
    printf '[stop-latest] KILL process group %s after %ss grace\n' "${pgid_to_stop}" "${grace}"
    kill -KILL "-${pgid_to_stop}" 2>/dev/null || true
  fi
else
  if [[ -f "${run}/status" ]]; then
    printf '[stop-latest] status=%s\n' "$(cat "${run}/status")"
  fi
fi

if is_truthy "${COLLECT_AFTER_STOP:-0}"; then
  if [[ -z "${COLLECT_INCLUDE_PRIVATE_PATH_REGEX:-}" && -f "${run}/semantic.log" ]]; then
    export COLLECT_INCLUDE_PRIVATE_PATH_REGEX="runs/semantic-10h/"
    if [[ "${USABLE_OUT}" == "${HARNESS_ROOT}/usable-emissions" ]]; then
      export USABLE_OUT="${HARNESS_ROOT}/usable-emissions-semantic-10h"
    fi
    export PARTIAL_TARGET_FILE="${PARTIAL_TARGET_FILE:-${HARNESS_ROOT}/targets/xrun-semantic-10h.tsv}"
    export VCD_SIGNATURE_MAX_BYTES="${VCD_SIGNATURE_MAX_BYTES:-1}"
  fi
  if [[ -z "${COLLECT_INCLUDE_PRIVATE_PATH_REGEX:-}" && -f "${run}/signal.log" ]]; then
    export COLLECT_INCLUDE_PRIVATE_PATH_REGEX="runs/signal-10h/"
    if [[ "${USABLE_OUT}" == "${HARNESS_ROOT}/usable-emissions" ]]; then
      export USABLE_OUT="${HARNESS_ROOT}/usable-emissions-signal-10h"
    fi
    export PARTIAL_TARGET_FILE="${PARTIAL_TARGET_FILE:-${HARNESS_ROOT}/targets/xrun-10h-signal.tsv}"
    export VCD_SIGNATURE_MAX_BYTES="${VCD_SIGNATURE_MAX_BYTES:-100000000}"
  fi
  if [[ -z "${COLLECT_INCLUDE_PRIVATE_PATH_REGEX:-}" && -f "${run}/overnight.log" ]]; then
    if ! is_truthy "${ALLOW_UNFILTERED_COLLECT:-0}"; then
      printf '[stop-latest] refusing unfiltered full-run collection; set COLLECT_INCLUDE_PRIVATE_PATH_REGEX or ALLOW_UNFILTERED_COLLECT=1\n' >&2
      exit 2
    fi
  fi
  printf '[stop-latest] collecting partial usable emissions\n'
  ./08_collect_partial_usable_emissions.sh
  if is_truthy "${PACK_AFTER_STOP:-0}"; then
    ./03_pack_usable_emissions.sh
  fi
else
  printf '[stop-latest] collection skipped; set COLLECT_AFTER_STOP=1 to collect after stopping\n'
fi
