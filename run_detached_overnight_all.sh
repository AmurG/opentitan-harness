#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

run_id="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
detached_root="${DETACHED_ROOT:-${HARNESS_ROOT}/detached-runs}"
run_dir="${detached_root}/${run_id}"
log_path="${run_dir}/overnight.log"
pid_path="${run_dir}/pid"
status_path="${run_dir}/status"

if [[ -e "${run_dir}" ]]; then
  printf '[error] detached run dir already exists: %s\n' "${run_dir}" >&2
  exit 2
fi

if [[ -f "${detached_root}/latest/pid" ]] && ! is_truthy "${ALLOW_PARALLEL:-0}"; then
  old_pid="$(cat "${detached_root}/latest/pid" 2>/dev/null || true)"
  if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
    printf '[error] existing detached run appears active: pid=%s\n' "${old_pid}" >&2
    printf '[hint] log: %s\n' "${detached_root}/latest/overnight.log" >&2
    printf '[hint] set ALLOW_PARALLEL=1 to launch another run anyway\n' >&2
    exit 2
  fi
fi

mkdir -p "${run_dir}"
rm -f "${detached_root}/latest"
ln -s "${run_dir}" "${detached_root}/latest"

cat > "${run_dir}/run_body.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cd "__HARNESS_ROOT__"
export RUN_STARTED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '[detached] started %s\n' "${RUN_STARTED_UTC}"
printf '[detached] host=%s cwd=%s\n' "$(hostname 2>/dev/null || printf unknown)" "$(pwd)"

if [[ "${RUN_PREREQS:-1}" != "0" ]]; then
  ./00_check_prereqs.sh
else
  printf '[detached] skipping prereq check because RUN_PREREQS=0\n'
fi

if [[ "${RUN_SETUP:-1}" != "0" ]]; then
  ./01_setup_opentitan.sh
else
  printf '[detached] skipping OpenTitan setup because RUN_SETUP=0\n'
fi

./04_run_overnight_all.sh
./03_pack_usable_emissions.sh

archive="$(ls -1t opentitan-usable-emissions-*.tar.gz 2>/dev/null | head -n 1 || true)"
if [[ -n "${archive}" ]]; then
  printf '%s\n' "$(pwd)/${archive}" > "__RUN_DIR__/archive_path"
  printf '[detached] archive=%s\n' "$(pwd)/${archive}"
fi
printf '[detached] finished %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF

python3 - <<'PY' "${run_dir}/run_body.sh" "${HARNESS_ROOT}" "${run_dir}"
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace("__HARNESS_ROOT__", sys.argv[2])
text = text.replace("__RUN_DIR__", sys.argv[3])
path.write_text(text, encoding="utf-8")
PY
chmod +x "${run_dir}/run_body.sh"

cat > "${run_dir}/supervisor.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
status_path="__STATUS_PATH__"
{
  "__RUN_BODY__"
  rc=$?
} || rc=$?
printf '%s\n' "${rc}" > "${status_path}"
exit "${rc}"
EOF

python3 - <<'PY' "${run_dir}/supervisor.sh" "${status_path}" "${run_dir}/run_body.sh"
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace("__STATUS_PATH__", sys.argv[2])
text = text.replace("__RUN_BODY__", sys.argv[3])
path.write_text(text, encoding="utf-8")
PY
chmod +x "${run_dir}/supervisor.sh"

launcher=(nohup "${run_dir}/supervisor.sh")
if command -v setsid >/dev/null 2>&1; then
  launcher=(setsid nohup "${run_dir}/supervisor.sh")
fi

"${launcher[@]}" > "${log_path}" 2>&1 < /dev/null &
pid=$!
printf '%s\n' "${pid}" > "${pid_path}"

printf '[detached] launched pid=%s\n' "${pid}"
printf '[detached] run_dir=%s\n' "${run_dir}"
printf '[detached] log=%s\n' "${log_path}"
printf '[detached] status=%s\n' "${status_path}"
printf '[detached] follow: tail -f %q\n' "${log_path}"
printf '[detached] check:  test -f %q && cat %q\n' "${status_path}" "${status_path}"
