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

python3 -m venv "${HARNESS_VENV}"
# shellcheck disable=SC1091
source "${HARNESS_VENV}/bin/activate"
python3 -m pip install --upgrade pip setuptools wheel

if [[ -f "${OPENTITAN_ROOT}/python-requirements.txt" ]]; then
  python3 -m pip install --requirement "${OPENTITAN_ROOT}/python-requirements.txt"
fi

# Current OpenTitan checkouts consume DVSim/FuseSoC from python-requirements.
# Only fall back to unpinned installs for unusual refs without those pins.
if ! command -v fusesoc >/dev/null 2>&1; then
  python3 -m pip install fusesoc
fi
if ! command -v dvsim >/dev/null 2>&1 && ! command -v dvsim.py >/dev/null 2>&1; then
  python3 -m pip install dvsim
fi

mkdir -p "${WORK_ROOT}"
{
  printf 'OPENTITAN_ROOT=%s\n' "${OPENTITAN_ROOT}"
  printf 'OPENTITAN_REF=%s\n' "${OPENTITAN_REF}"
  printf 'OPENTITAN_COMMIT=%s\n' "$(git -C "${OPENTITAN_ROOT}" rev-parse HEAD)"
  printf 'HARNESS_VENV=%s\n' "${HARNESS_VENV}"
} > "${WORK_ROOT}/setup.env"

printf '[ok] OpenTitan checkout ready: %s\n' "${OPENTITAN_ROOT}"
printf '[ok] commit: %s\n' "$(git -C "${OPENTITAN_ROOT}" rev-parse HEAD)"
