#!/usr/bin/env bash
# 在「部署目标机」上执行一次，准备目录 / 用户 / systemd
# 用法：
#   sudo bash prepare-target.sh
#   sudo DEPLOY_USER=ubuntu bash prepare-target.sh
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/web-test}"
# APP_USER = systemd 跑 jar 的用户；DEPLOY_USER = SSH 上传/重启的用户
# 生产建议二者分离，例如：APP_USER=webapp DEPLOY_USER=deploy
# 演示可同名（都设为 deploy）
APP_USER="${APP_USER:-deploy}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
JAVA8_HOME="${JAVA8_HOME:-/usr/lib/jvm/java-8-openjdk-amd64}"
APP_PORT="${APP_PORT:-8088}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 或 sudo 运行" >&2
  exit 1
fi

if [[ "${APP_USER}" == "${DEPLOY_USER}" ]]; then
  echo "WARN: APP_USER 与 DEPLOY_USER 同为 ${APP_USER}（演示可用；生产建议分离）" >&2
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y openjdk-8-jdk curl openssh-server

if [[ ! -x "${JAVA8_HOME}/bin/java" ]]; then
  # Ubuntu 上偶发路径不同，尽量探测
  if [[ -x /usr/lib/jvm/temurin-8-jdk-amd64/bin/java ]]; then
    JAVA8_HOME=/usr/lib/jvm/temurin-8-jdk-amd64
  else
    echo "未找到 JDK 8，请安装 openjdk-8-jdk 或设置 JAVA8_HOME" >&2
    ls /usr/lib/jvm || true
    exit 1
  fi
fi

# 运行应用的系统用户 / 部署 SSH 用户
if [[ "${APP_USER}" == "${DEPLOY_USER}" ]]; then
  # 同名：须为可登录账号（Jenkins SSH）；家目录可与 APP_DIR 分开
  if ! id -u "${DEPLOY_USER}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${DEPLOY_USER}"
    echo "已创建可登录用户 ${DEPLOY_USER}，请放入 SSH 公钥到 ~${DEPLOY_USER}/.ssh/authorized_keys"
  fi
else
  id -u "${APP_USER}" >/dev/null 2>&1 || \
    useradd -r -m -d "${APP_DIR}" -s /usr/sbin/nologin "${APP_USER}"
  if ! id -u "${DEPLOY_USER}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${DEPLOY_USER}"
    echo "已创建用户 ${DEPLOY_USER}，请自行放入 SSH 公钥到 ~${DEPLOY_USER}/.ssh/authorized_keys"
  fi
  usermod -aG "${APP_USER}" "${DEPLOY_USER}"
fi

mkdir -p "${APP_DIR}"
# 组可写：分离模式下 DEPLOY_USER 在 APP_USER 组；同名模式下属主即部署用户
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"
chmod 775 "${APP_DIR}"

install -m 0644 "${SCRIPT_DIR}/web-test.service" /etc/systemd/system/web-test.service
sed -i "s|/usr/lib/jvm/java-8-openjdk-amd64|${JAVA8_HOME}|g" /etc/systemd/system/web-test.service
sed -i "s|^User=.*|User=${APP_USER}|g" /etc/systemd/system/web-test.service
sed -i "s|^Group=.*|Group=${APP_USER}|g" /etc/systemd/system/web-test.service
sed -i "s|Environment=APP_PORT=8080|Environment=APP_PORT=${APP_PORT}|g" /etc/systemd/system/web-test.service
sed -i "s|Environment=APP_PORT=8088|Environment=APP_PORT=${APP_PORT}|g" /etc/systemd/system/web-test.service

systemctl daemon-reload
systemctl enable web-test

# sudo 免密重启（可选模板）
if [[ -f "${SCRIPT_DIR}/sudoers-web-test.example" ]]; then
  tmp_sudo="$(mktemp)"
  # 把模板首列用户名替换为实际 DEPLOY_USER
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
echo "部署用户: ${DEPLOY_USER}（已加入组 ${APP_USER}，可写目录）"
echo "单元: web-test.service（上传 jar 后会由流水线 restart）"
echo "JAVA8: ${JAVA8_HOME}"
echo "端口: ${APP_PORT}"
echo "探活: curl http://127.0.0.1:${APP_PORT}/hello"
echo
echo "请为 ${DEPLOY_USER} 配置 SSH 公钥后，在 Jenkins 使用该密钥部署。"
