#!/usr/bin/env bash
# 在「部署目标机」上执行一次，准备目录 / 用户 / systemd
# 用法：
#   sudo bash prepare-target.sh
#   sudo DEPLOY_USER=deploy bash prepare-target.sh
#   sudo SKIP_APT=1 bash prepare-target.sh   # 跳过 apt（本机已有 JDK8 时）
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/web-test}"
# APP_USER = systemd 跑 jar 的用户；DEPLOY_USER = SSH 上传/重启的用户
# 生产建议二者分离，例如：APP_USER=webapp DEPLOY_USER=deploy
# 演示可同名（都设为 deploy）
APP_USER="${APP_USER:-deploy}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
JAVA8_HOME="${JAVA8_HOME:-/usr/lib/jvm/java-8-openjdk-amd64}"
APP_PORT="${APP_PORT:-8088}"
SKIP_APT="${SKIP_APT:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 或 sudo 运行" >&2
  exit 1
fi

if [[ "${APP_USER}" == "${DEPLOY_USER}" ]]; then
  echo "WARN: APP_USER 与 DEPLOY_USER 同为 ${APP_USER}（演示可用；生产建议分离）" >&2
fi

# ---------- 1) 用户与目录（先做，避免 apt 失败导致用户未创建）----------
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

mkdir -p "${APP_DIR}"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"
chmod 775 "${APP_DIR}"

# ---------- 2) 软件包（apt 失败时：禁 cdrom 源重试；仍失败则仅在已有 java 时继续）----------
disable_cdrom_apt_sources() {
  # Ubuntu 安装介质残留的 file:/cdrom 会导致 apt update 失败
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    if grep -qE 'cdrom:|^Types:.*\n.*URIs: *cdrom' "$f" 2>/dev/null || grep -qi 'cdrom' "$f" 2>/dev/null; then
      echo "禁用以 cdrom 为源的配置: $f"
      sed -i -E 's/^(deb\s+cdrom:)/# \1/I' "$f" || true
      # deb822 .sources：整段不好精修，整文件里含 cdrom 则改名禁用
      if [[ "$f" == *.sources ]] && grep -qi 'cdrom' "$f"; then
        mv -f "$f" "${f}.disabled-cdrom" || true
        echo "已禁用: ${f}.disabled-cdrom"
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
    echo "WARN: apt-get update 失败，再禁 cdrom 后重试一次..." >&2
    disable_cdrom_apt_sources
    if ! apt-get update; then
      echo "WARN: apt-get update 仍失败" >&2
      if [[ -x "${JAVA8_HOME}/bin/java" ]] || command -v java >/dev/null 2>&1; then
        echo "已检测到 java，跳过 apt-get install，继续配置 systemd" >&2
        return 0
      fi
      echo "未检测到 JDK，请先修复 apt（常见：注释 /etc/apt 里的 cdrom 源）或：SKIP_APT=1 且自备 JDK8" >&2
      exit 1
    fi
  fi

  apt-get install -y openjdk-8-jdk curl openssh-server
}

ensure_packages

if [[ ! -x "${JAVA8_HOME}/bin/java" ]]; then
  if [[ -x /usr/lib/jvm/temurin-8-jdk-amd64/bin/java ]]; then
    JAVA8_HOME=/usr/lib/jvm/temurin-8-jdk-amd64
  elif command -v java >/dev/null 2>&1; then
    # 尽量从 java 反查 home（演示机兜底）
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

# ---------- 3) systemd + sudoers ----------
install -m 0644 "${SCRIPT_DIR}/web-test.service" /etc/systemd/system/web-test.service
sed -i "s|/usr/lib/jvm/java-8-openjdk-amd64|${JAVA8_HOME}|g" /etc/systemd/system/web-test.service
sed -i "s|^User=.*|User=${APP_USER}|g" /etc/systemd/system/web-test.service
sed -i "s|^Group=.*|Group=${APP_USER}|g" /etc/systemd/system/web-test.service
sed -i "s|Environment=APP_PORT=8080|Environment=APP_PORT=${APP_PORT}|g" /etc/systemd/system/web-test.service
sed -i "s|Environment=APP_PORT=8088|Environment=APP_PORT=${APP_PORT}|g" /etc/systemd/system/web-test.service

systemctl daemon-reload
systemctl enable web-test

if [[ -f "${SCRIPT_DIR}/sudoers-web-test.example" ]]; then
  tmp_sudo="$(mktemp)"
  sed -E "s/^[^#[:space:]]+ /${DEPLOY_USER} /" "${SCRIPT_DIR}/sudoers-web-test.example" \
    | grep -v '^#' | grep -v '^$' > "${tmp_sudo}" || true
  if [[ -s "${tmp_sudo}" ]]; then
    install -m 440 "${tmp_sudo}" /etc/sudoers.d/web-test-deploy
    visudo -cf /etc/sudoers.d/web-test-deploy
  fi
  rm -f "${tmp_sudo}"
fi

echo
echo "==== 目标机准备完成 ===="
echo "应用目录: ${APP_DIR}（权限 775，组 ${APP_USER}）"
echo "运行用户: ${APP_USER}"
echo "部署用户: ${DEPLOY_USER}"
echo "单元: web-test.service"
echo "JAVA8: ${JAVA8_HOME}"
echo "端口: ${APP_PORT}"
echo "探活: curl http://127.0.0.1:${APP_PORT}/hello"
echo
echo "下一步配置 SSH 密钥："
echo "  sudo DEPLOY_USER=${DEPLOY_USER} bash ${SCRIPT_DIR}/setup-deploy-ssh-key.sh"
