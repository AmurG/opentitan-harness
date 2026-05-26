#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

missing=0
for tool in git python3 xrun; do
  if command -v "${tool}" >/dev/null 2>&1; then
    printf '[ok] %s: %s\n' "${tool}" "$(command -v "${tool}")"
  else
    printf '[missing] %s\n' "${tool}" >&2
    missing=1
  fi
done

if command -v bazelisk >/dev/null 2>&1; then
  printf '[ok] bazelisk: %s\n' "$(command -v bazelisk)"
elif command -v bazel >/dev/null 2>&1; then
  printf '[ok] bazel: %s\n' "$(command -v bazel)"
else
  printf '[warn] bazel/bazelisk not found; OpenTitan SW collateral builds may fail.\n' >&2
fi

if command -v xrun >/dev/null 2>&1; then
  printf '[version] xrun:\n'
  xrun -version 2>&1 | sed -n '1,12p'
fi

if (( missing != 0 )); then
  exit 2
fi

printf '[ok] prerequisite scan complete\n'
