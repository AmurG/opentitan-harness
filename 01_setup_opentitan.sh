#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

mkdir -p "${WORK_ROOT}"

if [[ ! -d "${OPENTITAN_ROOT}/.git" ]]; then
  mkdir -p "$(dirname "${OPENTITAN_ROOT}")"
  git clone "${OPENTITAN_REMOTE}" "${OPENTITAN_ROOT}"
fi

git -C "${OPENTITAN_ROOT}" fetch --tags origin
git -C "${OPENTITAN_ROOT}" checkout "${OPENTITAN_REF}"
git -C "${OPENTITAN_ROOT}" submodule update --init --recursive

host_python="$(select_host_python)" || {
  cat >&2 <<'EOF'
[error] OpenTitan DVSim requires Python >= 3.10, but no usable interpreter was found.
[hint] Install/load Python 3.10+, or set HARNESS_PYTHON=/path/to/python3.10 in config.env.
EOF
  exit 2
}
printf '[setup] host python: %s (%s)\n' "${host_python}" "$(python_version_text "${host_python}")"

if [[ -x "${HARNESS_VENV}/bin/python3" ]] && ! python_version_at_least "${HARNESS_VENV}/bin/python3" 3 10; then
  printf '[setup] removing stale venv with Python %s: %s\n' \
    "$(python_version_text "${HARNESS_VENV}/bin/python3" 2>/dev/null || printf unknown)" \
    "${HARNESS_VENV}"
  rm -rf "${HARNESS_VENV}"
fi

"${host_python}" -m venv "${HARNESS_VENV}"
# shellcheck disable=SC1091
source "${HARNESS_VENV}/bin/activate"
python -m pip install --upgrade pip setuptools wheel

if [[ -f "${OPENTITAN_ROOT}/python-requirements.txt" ]]; then
  python -m pip install --requirement "${OPENTITAN_ROOT}/python-requirements.txt"
fi

# Current OpenTitan checkouts consume DVSim/FuseSoC from python-requirements.
# Only fall back to unpinned installs for unusual refs without those pins.
if ! command -v fusesoc >/dev/null 2>&1; then
  python -m pip install fusesoc
fi
if [[ ! -x "${OPENTITAN_ROOT}/util/dvsim/dvsim.py" ]] \
  && ! command -v dvsim >/dev/null 2>&1 \
  && ! command -v dvsim.py >/dev/null 2>&1; then
  python -m pip install dvsim
fi

mkdir -p "${WORK_ROOT}"
{
  printf 'OPENTITAN_ROOT=%s\n' "${OPENTITAN_ROOT}"
  printf 'OPENTITAN_REF=%s\n' "${OPENTITAN_REF}"
  printf 'OPENTITAN_COMMIT=%s\n' "$(git -C "${OPENTITAN_ROOT}" rev-parse HEAD)"
  printf 'HARNESS_VENV=%s\n' "${HARNESS_VENV}"
  printf 'HARNESS_PYTHON=%s\n' "${host_python}"
} > "${WORK_ROOT}/setup.env"

printf '[ok] OpenTitan checkout ready: %s\n' "${OPENTITAN_ROOT}"
printf '[ok] commit: %s\n' "$(git -C "${OPENTITAN_ROOT}" rev-parse HEAD)"
