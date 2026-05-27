#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

missing=0
for tool in git xrun; do
  if [[ "${tool}" == "xrun" ]] && is_truthy "${DVSIM_DRY_RUN:-0}"; then
    if command -v "${tool}" >/dev/null 2>&1; then
      printf '[ok] %s: %s\n' "${tool}" "$(command -v "${tool}")"
    else
      printf '[dry-run] xrun not found; continuing because DVSIM_DRY_RUN=1\n'
    fi
    continue
  fi
  if command -v "${tool}" >/dev/null 2>&1; then
    printf '[ok] %s: %s\n' "${tool}" "$(command -v "${tool}")"
  else
    printf '[missing] %s\n' "${tool}" >&2
    missing=1
  fi
done

if host_python="$(select_host_python)"; then
  printf '[ok] python>=3.10: %s (%s)\n' "${host_python}" "$(python_version_text "${host_python}")"
else
  printf '[missing] python>=3.10\n' >&2
  printf '[hint] Install/load Python 3.10+, or set HARNESS_PYTHON=/path/to/python3.10 in config.env.\n' >&2
  missing=1
fi

if command -v pkg-config >/dev/null 2>&1; then
  printf '[ok] pkg-config: %s\n' "$(command -v pkg-config)"
  if pkg-config --exists libudev; then
    printf '[ok] libudev.pc: %s\n' "$(pkg-config --modversion libudev)"
  else
    printf '[missing] pkg-config package libudev\n' >&2
    printf '[hint] OpenTitan Rust SW builds need libudev.pc; install/load the libudev development package or set PKG_CONFIG_PATH to its directory.\n' >&2
    missing=1
  fi
else
  printf '[missing] pkg-config\n' >&2
  printf '[hint] OpenTitan Rust SW builds need pkg-config and the libudev development package.\n' >&2
  missing=1
fi

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
