#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

run_id="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-signal10h}"
detached_root="${DETACHED_ROOT:-${HARNESS_ROOT}/detached-runs}"
run_dir="${detached_root}/${run_id}"
log_path="${run_dir}/signal.log"
pid_path="${run_dir}/pid"
status_path="${run_dir}/status"

if [[ -e "${run_dir}" ]]; then
  printf '[error] detached run dir already exists: %s\n' "${run_dir}" >&2
  exit 2
fi
if ! command -v timeout >/dev/null 2>&1; then
  printf '[error] timeout(1) is required for bounded signal runs\n' >&2
  exit 2
fi

if [[ -f "${detached_root}/latest/pid" ]] && ! is_truthy "${ALLOW_PARALLEL:-0}"; then
  old_pid="$(cat "${detached_root}/latest/pid" 2>/dev/null || true)"
  if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
    printf '[error] existing detached run appears active: pid=%s\n' "${old_pid}" >&2
    printf '[hint] inspect: %s\n' "${detached_root}/latest" >&2
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
export TARGET_FILE="${TARGET_FILE:-__HARNESS_ROOT__/targets/xrun-10h-signal.tsv}"
export BATCH_NAME="${BATCH_NAME:-signal-10h}"
export USABLE_OUT="${USABLE_OUT:-__HARNESS_ROOT__/usable-emissions-signal-10h}"
export COLLECT_INCLUDE_PRIVATE_PATH_REGEX="${COLLECT_INCLUDE_PRIVATE_PATH_REGEX:-runs/signal-10h/}"
export VCD_SIGNATURE_MAX_BYTES="${VCD_SIGNATURE_MAX_BYTES:-100000000}"
export SIGNAL_RUN_TIMEOUT="${SIGNAL_RUN_TIMEOUT:-10h}"
export SIGNAL_RUN_KILL_AFTER="${SIGNAL_RUN_KILL_AFTER:-10m}"
export MAX_SIGNAL_ARCHIVE_BYTES="${MAX_SIGNAL_ARCHIVE_BYTES:-1000000000}"

printf '[detached-signal] started %s\n' "${RUN_STARTED_UTC}"
printf '[detached-signal] host=%s cwd=%s\n' "$(hostname 2>/dev/null || printf unknown)" "$(pwd)"
printf '[detached-signal] timeout=%s kill_after=%s usable_out=%s max_archive_bytes=%s\n' \
  "${SIGNAL_RUN_TIMEOUT}" "${SIGNAL_RUN_KILL_AFTER}" "${USABLE_OUT}" \
  "${MAX_SIGNAL_ARCHIVE_BYTES}"

if [[ "${RUN_PREREQS:-1}" != "0" ]]; then
  ./00_check_prereqs.sh
else
  printf '[detached-signal] skipping prereq check because RUN_PREREQS=0\n'
fi

if [[ "${RUN_SETUP:-1}" != "0" ]]; then
  ./01_setup_opentitan.sh
else
  printf '[detached-signal] skipping OpenTitan setup because RUN_SETUP=0\n'
fi

rm -rf "${USABLE_OUT}"

set +e
timeout -k "${SIGNAL_RUN_KILL_AFTER}" "${SIGNAL_RUN_TIMEOUT}" ./09_run_10h_signal.sh
run_rc=$?
set -e
printf '[detached-signal] run_rc=%s\n' "${run_rc}"
printf '%s\n' "${run_rc}" > "__RUN_DIR__/run_rc"

if [[ -f "${USABLE_OUT}/manifest.json" ]]; then
  printf '[detached-signal] collect=reusing existing manifest from completed run\n'
  collect_rc=0
else
  set +e
  ./08_collect_partial_usable_emissions.sh
  collect_rc=$?
  set -e
fi
printf '[detached-signal] collect_rc=%s\n' "${collect_rc}"
printf '%s\n' "${collect_rc}" > "__RUN_DIR__/collect_rc"

archive_rc=0
if [[ "${collect_rc}" == "0" ]]; then
  set +e
  ./03_pack_usable_emissions.sh
  archive_rc=$?
  set -e
  archive="$(ls -1t opentitan-usable-emissions-*.tar.gz 2>/dev/null | head -n 1 || true)"
  if [[ -n "${archive}" ]]; then
    archive_full="$(pwd)/${archive}"
    printf '%s\n' "${archive_full}" > "__RUN_DIR__/archive_path"
    printf '[detached-signal] archive=%s\n' "${archive_full}"
    archive_bytes="$(wc -c < "${archive_full}" | tr -d ' ')"
    printf '%s\n' "${archive_bytes}" > "__RUN_DIR__/archive_bytes"
    printf '[detached-signal] archive_bytes=%s\n' "${archive_bytes}"
    if [[ -n "${MAX_SIGNAL_ARCHIVE_BYTES}" ]] && \
       (( archive_bytes > MAX_SIGNAL_ARCHIVE_BYTES )); then
      printf '[detached-signal] warning=archive exceeds MAX_SIGNAL_ARCHIVE_BYTES\n'
    fi
  fi
fi
printf '[detached-signal] archive_rc=%s\n' "${archive_rc}"
printf '%s\n' "${archive_rc}" > "__RUN_DIR__/archive_rc"
du -sh "${USABLE_OUT}" opentitan-usable-emissions-*.tar.gz 2>/dev/null || true
printf '[detached-signal] finished %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ "${collect_rc}" != "0" ]]; then
  exit "${collect_rc}"
fi
if [[ "${archive_rc}" != "0" ]]; then
  exit "${archive_rc}"
fi
exit 0
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

printf '[detached-signal] launched pid=%s\n' "${pid}"
printf '[detached-signal] run_dir=%s\n' "${run_dir}"
printf '[detached-signal] log=%s\n' "${log_path}"
printf '[detached-signal] status=%s\n' "${status_path}"
printf '[detached-signal] follow: tail -f %q\n' "${log_path}"
printf '[detached-signal] check:  test -f %q && cat %q\n' "${status_path}" "${status_path}"
