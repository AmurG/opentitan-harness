#!/usr/bin/env bash
set -euo pipefail

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HARNESS_ROOT

if [[ -f "${HARNESS_ROOT}/config.env" ]]; then
  # shellcheck disable=SC1091
  source "${HARNESS_ROOT}/config.env"
else
  # shellcheck disable=SC1091
  source "${HARNESS_ROOT}/config.env.example"
fi

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

safe_slug() {
  python3 - "$1" <<'PY'
import re
import sys
text = sys.argv[1]
text = re.sub(r"[^A-Za-z0-9._-]+", "_", text).strip("._-")
print(text or "unnamed")
PY
}

python_version_at_least() {
  local python_bin="$1"
  local major="${2:-3}"
  local minor="${3:-10}"

  [[ -n "${python_bin}" ]] || return 1
  command -v "${python_bin}" >/dev/null 2>&1 || return 1
  "${python_bin}" - "${major}" "${minor}" <<'PY' >/dev/null 2>&1
import sys
need = (int(sys.argv[1]), int(sys.argv[2]))
raise SystemExit(0 if sys.version_info[:2] >= need else 1)
PY
}

python_version_text() {
  local python_bin="$1"
  "${python_bin}" - <<'PY'
import sys
print(".".join(str(part) for part in sys.version_info[:3]))
PY
}

select_host_python() {
  local candidate
  for candidate in \
    "${HARNESS_PYTHON:-}" \
    "${OPENTITAN_PYTHON:-}" \
    python3.12 \
    python3.11 \
    python3.10 \
    python3
  do
    [[ -n "${candidate}" ]] || continue
    if python_version_at_least "${candidate}" 3 10; then
      command -v "${candidate}"
      return 0
    fi
  done
  return 1
}

activate_harness_venv() {
  if [[ -x "${HARNESS_VENV}/bin/python3" ]]; then
    # shellcheck disable=SC1091
    source "${HARNESS_VENV}/bin/activate"
  fi
}

resolve_dvsim_cmd() {
  if [[ -n "${DVSIM_BIN:-}" ]]; then
    printf '%s\n' "${DVSIM_BIN}"
    return
  fi
  if [[ -x "${OPENTITAN_ROOT}/util/dvsim/dvsim.py" ]]; then
    printf '%s\n' "${OPENTITAN_ROOT}/util/dvsim/dvsim.py"
    return
  fi
  if command -v dvsim.py >/dev/null 2>&1; then
    command -v dvsim.py
    return
  fi
  if command -v dvsim >/dev/null 2>&1; then
    command -v dvsim
    return
  fi
  if python3 - <<'PY' >/dev/null 2>&1
import importlib.util
raise SystemExit(0 if importlib.util.find_spec("dvsim") else 1)
PY
  then
    printf '%s\n' "python3 -m dvsim"
    return
  fi
  return 1
}
