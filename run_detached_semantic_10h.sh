#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

run_id="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-semantic10h}"
detached_root="${DETACHED_ROOT:-${HARNESS_ROOT}/detached-runs}"
run_dir="${detached_root}/${run_id}"
log_path="${run_dir}/semantic.log"
pid_path="${run_dir}/pid"
pgid_path="${run_dir}/pgid"
status_path="${run_dir}/status"

if [[ -e "${run_dir}" ]]; then
  printf '[error] detached run dir already exists: %s\n' "${run_dir}" >&2
  exit 2
fi
if ! command -v timeout >/dev/null 2>&1; then
  printf '[error] timeout(1) is required for bounded semantic runs\n' >&2
  exit 2
fi

if [[ -f "${detached_root}/latest/pid" ]] && ! is_truthy "${ALLOW_PARALLEL:-0}"; then
  old_pid="$(cat "${detached_root}/latest/pid" 2>/dev/null || true)"
  if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
    printf '[error] existing detached run appears active: pid=%s\n' "${old_pid}" >&2
    printf '[hint] inspect: %s\n' "${detached_root}/latest" >&2
    printf '[hint] stop it first: STOP_CONFIRM=1 ./10_stop_latest_detached.sh\n' >&2
    exit 2
  fi
  old_pgid="$(cat "${detached_root}/latest/pgid" 2>/dev/null || true)"
  if [[ -n "${old_pgid}" ]] && \
     ps -u "${USER}" -o pid=,pgid=,cmd= | awk -v pgid="${old_pgid}" '$2 == pgid {found=1} END {exit found ? 0 : 1}'; then
    printf '[error] existing detached run process group appears active: pgid=%s\n' "${old_pgid}" >&2
    printf '[hint] inspect: %s\n' "${detached_root}/latest" >&2
    printf '[hint] stop it first: STOP_CONFIRM=1 ./10_stop_latest_detached.sh\n' >&2
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
export TARGET_FILE="${TARGET_FILE:-__HARNESS_ROOT__/targets/xrun-semantic-10h.tsv}"
export BATCH_NAME="${BATCH_NAME:-semantic-10h}"
export PARTIAL_TARGET_FILE="${PARTIAL_TARGET_FILE:-${TARGET_FILE}}"
export USABLE_OUT="${USABLE_OUT:-__HARNESS_ROOT__/usable-emissions-semantic-10h}"
export COLLECT_INCLUDE_PRIVATE_PATH_REGEX="${COLLECT_INCLUDE_PRIVATE_PATH_REGEX:-runs/semantic-10h/}"
export SEMANTIC_RUN_TIMEOUT="${SEMANTIC_RUN_TIMEOUT:-10h}"
export SEMANTIC_RUN_KILL_AFTER="${SEMANTIC_RUN_KILL_AFTER:-10m}"
export MAX_SEMANTIC_ARCHIVE_BYTES="${MAX_SEMANTIC_ARCHIVE_BYTES:-1000000000}"
export ARCHIVE_NAME="${ARCHIVE_NAME:-opentitan-usable-emissions-semantic-10h-$(basename "__RUN_DIR__").tar.gz}"

printf '[detached-semantic] started %s\n' "${RUN_STARTED_UTC}"
printf '[detached-semantic] host=%s cwd=%s\n' "$(hostname 2>/dev/null || printf unknown)" "$(pwd)"
printf '[detached-semantic] timeout=%s kill_after=%s usable_out=%s max_archive_bytes=%s\n' \
  "${SEMANTIC_RUN_TIMEOUT}" "${SEMANTIC_RUN_KILL_AFTER}" "${USABLE_OUT}" \
  "${MAX_SEMANTIC_ARCHIVE_BYTES}"
printf '[detached-semantic] waves=disabled export_raw_waves=0 target_file=%s\n' "${TARGET_FILE}"

if [[ "${RUN_PREREQS:-1}" != "0" ]]; then
  ./00_check_prereqs.sh
else
  printf '[detached-semantic] skipping prereq check because RUN_PREREQS=0\n'
fi

if [[ "${RUN_SETUP:-1}" != "0" ]]; then
  ./01_setup_opentitan.sh
else
  printf '[detached-semantic] skipping OpenTitan setup because RUN_SETUP=0\n'
fi

rm -rf "${USABLE_OUT}"

set +e
timeout -k "${SEMANTIC_RUN_KILL_AFTER}" "${SEMANTIC_RUN_TIMEOUT}" ./09_run_semantic_10h.sh
run_rc=$?
set -e
printf '[detached-semantic] run_rc=%s\n' "${run_rc}"
printf '%s\n' "${run_rc}" > "__RUN_DIR__/run_rc"

if [[ -f "${USABLE_OUT}/manifest.json" ]]; then
  printf '[detached-semantic] collect=reusing existing manifest from completed run\n'
  collect_rc=0
else
  set +e
  ./08_collect_partial_usable_emissions.sh
  collect_rc=$?
  set -e
fi
printf '[detached-semantic] collect_rc=%s\n' "${collect_rc}"
printf '%s\n' "${collect_rc}" > "__RUN_DIR__/collect_rc"

archive_rc=0
if [[ "${collect_rc}" == "0" ]]; then
  set +e
  ./03_pack_usable_emissions.sh
  archive_rc=$?
  set -e
  archive_full="$(pwd)/${ARCHIVE_NAME}"
  if [[ "${archive_rc}" == "0" && -f "${archive_full}" ]]; then
    printf '%s\n' "${archive_full}" > "__RUN_DIR__/archive_path"
    printf '[detached-semantic] archive=%s\n' "${archive_full}"
    archive_bytes="$(wc -c < "${archive_full}" | tr -d ' ')"
    printf '%s\n' "${archive_bytes}" > "__RUN_DIR__/archive_bytes"
    printf '[detached-semantic] archive_bytes=%s\n' "${archive_bytes}"
    if [[ -n "${MAX_SEMANTIC_ARCHIVE_BYTES}" ]] && \
       (( archive_bytes > MAX_SEMANTIC_ARCHIVE_BYTES )); then
      printf '[detached-semantic] warning=archive exceeds MAX_SEMANTIC_ARCHIVE_BYTES\n'
    fi
  fi
fi
printf '[detached-semantic] archive_rc=%s\n' "${archive_rc}"
printf '%s\n' "${archive_rc}" > "__RUN_DIR__/archive_rc"
du -sh "${USABLE_OUT}" "${ARCHIVE_NAME}" 2>/dev/null || true
printf '[detached-semantic] finished %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

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
pgid="$(ps -o pgid= -p "${pid}" 2>/dev/null | tr -d ' ' || true)"
if [[ -n "${pgid}" ]]; then
  printf '%s\n' "${pgid}" > "${pgid_path}"
fi

printf '[detached-semantic] launched pid=%s\n' "${pid}"
printf '[detached-semantic] launched pgid=%s\n' "${pgid:-unknown}"
printf '[detached-semantic] run_dir=%s\n' "${run_dir}"
printf '[detached-semantic] log=%s\n' "${log_path}"
printf '[detached-semantic] status=%s\n' "${status_path}"
printf '[detached-semantic] follow: tail -f %q\n' "${log_path}"
printf '[detached-semantic] check:  test -f %q && cat %q\n' "${status_path}" "${status_path}"
