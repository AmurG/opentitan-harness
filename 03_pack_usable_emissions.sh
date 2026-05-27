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
usable_base="$(basename "${USABLE_OUT}")"
if [[ "${usable_base}" == "usable-emissions" ]]; then
  archive_stem="opentitan-usable-emissions"
else
  archive_stem="opentitan-${usable_base}"
fi
archive_name="${ARCHIVE_NAME:-${archive_stem}-${stamp}.tar.gz}"
archive="${HARNESS_ROOT}/${archive_name}"
tar -czf "${archive}" -C "$(dirname "${USABLE_OUT}")" "$(basename "${USABLE_OUT}")"

printf '[ok] archive: %s\n' "${archive}"
du -h "${archive}"
