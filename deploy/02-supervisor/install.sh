#!/usr/bin/env bash
# 方案二：在「应用机」安装 Supervisor，准备业务应用目录（不安装 Jenkins）
# 用法：
#   sudo bash install.sh
#   sudo APP_USER=webapp DEPLOY_USER=deploy APP_PORT=8088 bash install.sh
#   sudo SKIP_APT=1 bash install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${APP_DIR:-/opt/web-test}"
LOG_DIR="${LOG_DIR:-/opt/app-logs}"
APP_USER="${APP_USER:-deploy}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
JAVA8_HOME="${JAVA8_HOME:-/usr/lib/jvm/java-8-openjdk-amd64}"
APP_PORT="${APP_PORT:-8088}"
PROGRAM_NAME="${PROGRAM_NAME:-web-test}"
SKIP_APT="${SKIP_APT:-0}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 或 sudo 运行" >&2
  exit 1
fi

if [[ "${APP_USER}" == "${DEPLOY_USER}" ]]; then
  echo "WARN: APP_USER 与 DEPLOY_USER 同为 ${APP_USER}（演示可用；生产建议分离）" >&2
fi

# ---------- 1) 用户与目录 ----------
if [[ "${APP_USER}" == "${DEPLOY_USER}" ]]; then
  if ! id -u "${DEPLOY_USER}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${DEPLOY_USER}"
    echo "已创建可登录用户 ${DEPLOY_USER}"
  fi
else
  id -u "${APP_USER}" >/dev/null 2>&1 || \
    useradd -r -m -d "${APP_DIR}" -s /usr/sbin/nologin "${APP_USER}"
  if ! id -u "${DEPLOY_USER}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${DEPLOY_USER}"
    echo "已创建用户 ${DEPLOY_USER}"
  fi
  usermod -aG "${APP_USER}" "${DEPLOY_USER}"
fi

mkdir -p "${APP_DIR}" "${LOG_DIR}"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"
chown -R "${APP_USER}:${APP_USER}" "${LOG_DIR}"
chmod 775 "${APP_DIR}"
chmod 755 "${LOG_DIR}"

# ---------- 2) 软件包 ----------
disable_cdrom_apt_sources() {
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    if grep -qi 'cdrom' "$f" 2>/dev/null; then
      echo "禁用以 cdrom 为源的配置: $f"
      sed -i -E 's/^(deb\s+cdrom:)/# \1/I' "$f" || true
      if [[ "$f" == *.sources ]] && grep -qi 'cdrom' "$f"; then
        mv -f "$f" "${f}.disabled-cdrom" || true
      fi
    fi
  done
}

ensure_packages() {
  export DEBIAN_FRONTEND=noninteractive
  if [[ "${SKIP_APT}" == "1" ]]; then
    echo "SKIP_APT=1，跳过 apt 安装"
    return 0
  fi
  disable_cdrom_apt_sources
  if ! apt-get update; then
    echo "WARN: apt-get update 失败，再禁 cdrom 后重试..." >&2
    disable_cdrom_apt_sources
    apt-get update || true
  fi
  apt-get install -y openjdk-8-jdk curl openssh-server supervisor
}

ensure_packages

if [[ ! -x "${JAVA8_HOME}/bin/java" ]]; then
  if [[ -x /usr/lib/jvm/temurin-8-jdk-amd64/bin/java ]]; then
    JAVA8_HOME=/usr/lib/jvm/temurin-8-jdk-amd64
  elif command -v java >/dev/null 2>&1; then
    jbin="$(readlink -f "$(command -v java)" || true)"
    if [[ -n "$jbin" ]]; then
      JAVA8_HOME="$(dirname "$(dirname "$jbin")")"
    fi
  fi
fi

if [[ ! -x "${JAVA8_HOME}/bin/java" ]]; then
  echo "未找到 JDK 8，请安装 openjdk-8-jdk 或设置 JAVA8_HOME" >&2
  ls /usr/lib/jvm 2>/dev/null || true
  exit 1
fi

# ---------- 3) 启动脚本 + Supervisor 配置 ----------
tmp_start="$(mktemp)"
tr -d '\r' < "${SCRIPT_DIR}/start-app.sh" > "${tmp_start}"
install -m 0755 "${tmp_start}" "${APP_DIR}/start-app.sh"
rm -f "${tmp_start}"
chown "${APP_USER}:${APP_USER}" "${APP_DIR}/start-app.sh"

tmp_conf="$(mktemp)"
tr -d '\r' < "${SCRIPT_DIR}/web-test.conf" > "${tmp_conf}"
sed -i "s|/opt/web-test|${APP_DIR}|g" "${tmp_conf}"
sed -i "s|/opt/app-logs|${LOG_DIR}|g" "${tmp_conf}"
sed -i "s|^user=.*|user=${APP_USER}|g" "${tmp_conf}"
sed -i "s|JAVA_HOME=\"[^\"]*\"|JAVA_HOME=\"${JAVA8_HOME}\"|g" "${tmp_conf}"
sed -i "s|APP_PORT=\"[0-9]*\"|APP_PORT=\"${APP_PORT}\"|g" "${tmp_conf}"
sed -i "s|^\[program:.*\]|[program:${PROGRAM_NAME}]|g" "${tmp_conf}"
install -m 0644 "${tmp_conf}" "/etc/supervisor/conf.d/${PROGRAM_NAME}.conf"
rm -f "${tmp_conf}"

# ---------- 4) sudoers：部署用户可 supervisorctl / 安装 jar ----------
if [[ -f "${SCRIPT_DIR}/sudoers-web-test.example" ]]; then
  tmp_sudo="$(mktemp)"
  tr -d '\r' < "${SCRIPT_DIR}/sudoers-web-test.example" \
    | sed -E "s/^[^#[:space:]]+ /${DEPLOY_USER} /" \
    | grep -v '^#' | grep -v '^$' > "${tmp_sudo}" || true
  if [[ -s "${tmp_sudo}" ]]; then
    install -m 440 "${tmp_sudo}" /etc/sudoers.d/web-test-supervisor-deploy
    visudo -cf /etc/sudoers.d/web-test-supervisor-deploy
  fi
  rm -f "${tmp_sudo}"
fi

supervisorctl reread
supervisorctl update
supervisorctl status "${PROGRAM_NAME}" || true

echo
echo "==== 应用机 Supervisor 就绪 ===="
echo "应用目录: ${APP_DIR}"
echo "日志目录: ${LOG_DIR}"
echo "运行用户: ${APP_USER}"
echo "部署用户: ${DEPLOY_USER}"
echo "program: ${PROGRAM_NAME}"
echo "JAVA8: ${JAVA8_HOME}"
echo "端口: ${APP_PORT}"
echo "启停: supervisorctl {start|stop|restart} ${PROGRAM_NAME}"
echo "或: bash ${SCRIPT_DIR}/ctl.sh status"
echo
echo "首次尚无 jar 时 status 可能为 FATAL/EXITED，属正常；Jenkins 上传后会变为 RUNNING。"
echo "下一步 SSH 密钥：sudo DEPLOY_USER=${DEPLOY_USER} bash ${SCRIPT_DIR}/setup-deploy-ssh-key.sh"
