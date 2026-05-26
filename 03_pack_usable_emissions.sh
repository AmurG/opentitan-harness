#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

if [[ ! -d "${USABLE_OUT}" ]]; then
  printf '[error] missing usable emissions directory: %s\n' "${USABLE_OUT}" >&2
  printf '[hint] run ./02_run_xrun_eval.sh first\n' >&2
  exit 2
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
archive="${HARNESS_ROOT}/opentitan-usable-emissions-${stamp}.tar.gz"
tar -czf "${archive}" -C "$(dirname "${USABLE_OUT}")" "$(basename "${USABLE_OUT}")"

printf '[ok] archive: %s\n' "${archive}"
du -h "${archive}"
