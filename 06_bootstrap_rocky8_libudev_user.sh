#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

prefix="${LIBUDEV_USER_PREFIX:-${WORK_ROOT}/user-prereqs/libudev}"
download_dir="${prefix}/rpms"
extract_dir="${prefix}/extract"
mkdir -p "${download_dir}" "${extract_dir}" "${prefix}/include" "${prefix}/lib" "${prefix}/lib/pkgconfig" "${prefix}/bin"

if pkg-config --exists libudev; then
  printf '[ok] host already provides libudev.pc: %s\n' "$(pkg-config --modversion libudev)"
  exit 0
fi

for tool in rpm rpm2cpio cpio dnf; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    printf '[error] missing required tool: %s\n' "${tool}" >&2
    exit 2
  fi
done

rpm_path=""
if [[ -n "${SYSTEMD_DEVEL_RPM:-}" ]]; then
  rpm_path="${SYSTEMD_DEVEL_RPM}"
elif [[ -n "${SYSTEMD_DEVEL_RPM_URL:-}" ]]; then
  rpm_url="${SYSTEMD_DEVEL_RPM_URL}"
  rpm_path="${download_dir}/$(basename "${rpm_url%%\?*}")"
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail -o "${rpm_path}" "${rpm_url}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${rpm_path}" "${rpm_url}"
  else
    printf '[error] need curl or wget to download SYSTEMD_DEVEL_RPM_URL\n' >&2
    exit 2
  fi
else
  rpm_url="$(dnf repoquery --location --latest-limit=1 "systemd-devel.$(uname -m)" 2>/dev/null | tail -1 || true)"
  if [[ -z "${rpm_url}" ]]; then
    rpm_url="$(dnf repoquery --location --latest-limit=1 systemd-devel 2>/dev/null | tail -1 || true)"
  fi
  if [[ -n "${rpm_url}" ]]; then
    rpm_path="${download_dir}/$(basename "${rpm_url%%\?*}")"
    if command -v curl >/dev/null 2>&1; then
      curl -L --fail -o "${rpm_path}" "${rpm_url}"
    elif command -v wget >/dev/null 2>&1; then
      wget -O "${rpm_path}" "${rpm_url}"
    else
      printf '[error] need curl or wget to download %s\n' "${rpm_url}" >&2
      exit 2
    fi
  elif dnf download --destdir "${download_dir}" systemd-devel >/dev/null 2>&1; then
    rpm_path="$(find "${download_dir}" -maxdepth 1 -name 'systemd-devel-*.rpm' -type f | sort | tail -1)"
  else
    cat >&2 <<'EOF'
[error] could not locate a downloadable systemd-devel RPM through dnf.
[hint] Ask an admin to install systemd-devel, or set SYSTEMD_DEVEL_RPM=/path/to/systemd-devel.rpm
[hint] or SYSTEMD_DEVEL_RPM_URL=https://.../systemd-devel-....rpm and rerun this script.
EOF
    exit 2
  fi
fi

if [[ ! -f "${rpm_path}" ]]; then
  printf '[error] RPM not found: %s\n' "${rpm_path}" >&2
  exit 2
fi

rm -rf "${extract_dir}"
mkdir -p "${extract_dir}"
(
  cd "${extract_dir}"
  rpm2cpio "${rpm_path}" | cpio -idm --quiet
)

header_path="$(find "${extract_dir}" -path '*/include/libudev.h' -type f | head -1)"
if [[ -z "${header_path}" ]]; then
  printf '[error] extracted RPM did not contain include/libudev.h: %s\n' "${rpm_path}" >&2
  exit 2
fi
cp -f "${header_path}" "${prefix}/include/libudev.h"

syslib="$(ldconfig -p 2>/dev/null | awk '/libudev\.so\.1[[:space:]]/ {print $NF; exit}' || true)"
if [[ -z "${syslib}" || ! -e "${syslib}" ]]; then
  syslib="$(find /usr/lib64 /lib64 /usr/lib /lib -maxdepth 2 -name 'libudev.so.1*' -type f 2>/dev/null | sort | head -1 || true)"
fi
if [[ -z "${syslib}" || ! -e "${syslib}" ]]; then
  printf '[error] could not find runtime libudev.so.1 on this host\n' >&2
  exit 2
fi
runtime_name="$(basename "${syslib}")"
cp -Lf "${syslib}" "${prefix}/lib/${runtime_name}"
ln -sfn "${runtime_name}" "${prefix}/lib/libudev.so"

version="$(rpm -qp --qf '%{VERSION}\n' "${rpm_path}" 2>/dev/null || rpm -q --qf '%{VERSION}\n' systemd-libs 2>/dev/null || printf 'unknown')"
cat > "${prefix}/lib/pkgconfig/libudev.pc" <<EOF
prefix=${prefix}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libudev
Description: User-local libudev metadata for OpenTitan harness builds
Version: ${version}
Libs: -L\${libdir} -ludev
Cflags: -I\${includedir}
EOF

cat > "${prefix}/bin/pkg-config" <<EOF
#!/usr/bin/env bash
export PKG_CONFIG_PATH="${prefix}/lib/pkgconfig\${PKG_CONFIG_PATH:+:\${PKG_CONFIG_PATH}}"
exec /usr/bin/pkg-config "\$@"
EOF
chmod +x "${prefix}/bin/pkg-config"

config_path="${HARNESS_ROOT}/config.env"
if [[ -f "${config_path}" ]]; then
  tmp_config="${config_path}.tmp.$$"
  awk '
    /^# BEGIN opentitan-harness user libudev$/ {skip=1; next}
    /^# END opentitan-harness user libudev$/ {skip=0; next}
    !skip {print}
  ' "${config_path}" > "${tmp_config}"
  cat >> "${tmp_config}" <<EOF

# BEGIN opentitan-harness user libudev
LIBUDEV_USER_PREFIX="${prefix}"
export PATH="\${LIBUDEV_USER_PREFIX}/bin\${PATH:+:\${PATH}}"
export PKG_CONFIG_PATH="\${LIBUDEV_USER_PREFIX}/lib/pkgconfig\${PKG_CONFIG_PATH:+:\${PKG_CONFIG_PATH}}"
export CPATH="\${LIBUDEV_USER_PREFIX}/include\${CPATH:+:\${CPATH}}"
export LIBRARY_PATH="\${LIBUDEV_USER_PREFIX}/lib\${LIBRARY_PATH:+:\${LIBRARY_PATH}}"
export LD_LIBRARY_PATH="\${LIBUDEV_USER_PREFIX}/lib\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
# END opentitan-harness user libudev
EOF
  mv "${tmp_config}" "${config_path}"
  printf '[ok] updated %s with user-local libudev environment\n' "${config_path}"
else
  printf '[warn] config.env not found; create it from config.env.example, then rerun this script\n' >&2
fi

PKG_CONFIG_PATH="${prefix}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}" \
PATH="${prefix}/bin${PATH:+:${PATH}}" \
  pkg-config --modversion libudev

cat <<EOF
[ok] user-local libudev bootstrap complete: ${prefix}
[next] run: ./00_check_prereqs.sh
EOF
