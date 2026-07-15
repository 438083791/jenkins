#!/usr/bin/env bash
# 从 Jenkins 节点把 jar 部署到远程机（无 Docker）
# 由 Jenkinsfile 在 withCredentials(sshUserPrivateKey) 中调用（无需 SSH Agent 插件）
#
# 环境变量：
#   DEPLOY_HOST         必填
#   DEPLOY_USER         默认 deploy（SSH）
#   DEPLOY_PATH         默认 /opt/web-test
#   DEPLOY_PORT         默认 22
#   APP_HTTP_PORT       默认 8088
#   APP_RUN_USER        运行用户，默认 deploy（须与 systemd User= 一致）
#   JAR_FILE            必填 本地 jar
#   SSH_IDENTITY_FILE   可选 私钥路径（Jenkins withCredentials 注入）
set -euo pipefail

DEPLOY_HOST="${DEPLOY_HOST:?请设置 DEPLOY_HOST}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
DEPLOY_PATH="${DEPLOY_PATH:-/opt/web-test}"
DEPLOY_PORT="${DEPLOY_PORT:-22}"
APP_HTTP_PORT="${APP_HTTP_PORT:-8088}"
APP_RUN_USER="${APP_RUN_USER:-deploy}"
JAR_FILE="${JAR_FILE:?请设置 JAR_FILE}"

if [[ ! -f "${JAR_FILE}" ]]; then
  echo "JAR 不存在: ${JAR_FILE}" >&2
  exit 1
fi

if ! command -v ssh >/dev/null || ! command -v scp >/dev/null; then
  echo "需要 openssh-client（ssh/scp）" >&2
  exit 1
fi

SSH_BASE=( -p "${DEPLOY_PORT}" -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o IdentitiesOnly=yes )
if [[ -n "${SSH_IDENTITY_FILE:-}" ]]; then
  if [[ ! -f "${SSH_IDENTITY_FILE}" ]]; then
    echo "SSH_IDENTITY_FILE 不存在: ${SSH_IDENTITY_FILE}" >&2
    exit 1
  fi
  SSH_BASE+=( -i "${SSH_IDENTITY_FILE}" )
fi

SSH=(ssh "${SSH_BASE[@]}")
SCP_BASE=( -P "${DEPLOY_PORT}" -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o IdentitiesOnly=yes )
if [[ -n "${SSH_IDENTITY_FILE:-}" ]]; then
  SCP_BASE+=( -i "${SSH_IDENTITY_FILE}" )
fi
SCP=(scp "${SCP_BASE[@]}")

# 先传到部署用户家目录（一定可写），再安装到 /opt/web-test
echo "==== 部署 ${JAR_FILE} -> ${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}/web-test.jar ===="

"${SSH[@]}" "${DEPLOY_USER}@${DEPLOY_HOST}" 'mkdir -p "$HOME/.web-test-deploy"'
"${SCP[@]}" "${JAR_FILE}" "${DEPLOY_USER}@${DEPLOY_HOST}:.web-test-deploy/web-test.jar.new"

"${SSH[@]}" "${DEPLOY_USER}@${DEPLOY_HOST}" \
  "APP_DIR='${DEPLOY_PATH}' APP_PORT='${APP_HTTP_PORT}' APP_RUN_USER='${APP_RUN_USER}' bash -s" <<'EOS'
set -euo pipefail

STAGING="${HOME}/.web-test-deploy/web-test.jar.new"
test -f "${STAGING}"

mkdir -p "${APP_DIR}" 2>/dev/null || true

install_jar() {
  # 目录可写：直接覆盖
  if [[ -w "${APP_DIR}" ]]; then
    mv -f "${STAGING}" "${APP_DIR}/web-test.jar"
    chmod 640 "${APP_DIR}/web-test.jar" 2>/dev/null || chmod 644 "${APP_DIR}/web-test.jar"
    if id "${APP_RUN_USER}" >/dev/null 2>&1; then
      chgrp "${APP_RUN_USER}" "${APP_DIR}/web-test.jar" 2>/dev/null || true
      sudo -n chown "${APP_RUN_USER}:${APP_RUN_USER}" "${APP_DIR}/web-test.jar" 2>/dev/null || true
    fi
    return 0
  fi
  # 不可写：sudo 安装（需 NOPASSWD install/mv/chown）
  if sudo -n install -o "${APP_RUN_USER}" -g "${APP_RUN_USER}" -m 640 \
      "${STAGING}" "${APP_DIR}/web-test.jar" 2>/dev/null; then
    rm -f "${STAGING}"
    return 0
  fi
  if sudo -n mv -f "${STAGING}" "${APP_DIR}/web-test.jar" \
    && sudo -n chown "${APP_RUN_USER}:${APP_RUN_USER}" "${APP_DIR}/web-test.jar"; then
    sudo -n chmod 640 "${APP_DIR}/web-test.jar" || true
    return 0
  fi
  echo "无法写入 ${APP_DIR}：请对目录 chmod 775 且把 ${USER} 加入 ${APP_RUN_USER} 组，或配置 sudoers（install/mv/chown）" >&2
  ls -la "$(dirname "${APP_DIR}")" "${APP_DIR}" 2>/dev/null || true
  id
  exit 1
}

install_jar

if ! systemctl cat web-test >/dev/null 2>&1; then
  echo "未找到 web-test.service，请先在目标机执行 prepare-target.sh" >&2
  exit 1
fi

echo "设置应用端口 APP_PORT=${APP_PORT}"
if sudo -n sed -i "s/^Environment=APP_PORT=.*/Environment=APP_PORT=${APP_PORT}/" /etc/systemd/system/web-test.service; then
  sudo -n systemctl daemon-reload
else
  echo "无法修改 web-test.service 端口，请检查 sudoers 或手工改 Environment=APP_PORT" >&2
  exit 1
fi

if sudo -n systemctl restart web-test; then
  sudo -n systemctl --no-pager --lines=20 status web-test || true
else
  echo "sudo systemctl restart 失败：请配置 sudoers（见 sudoers-web-test.example）" >&2
  exit 1
fi
EOS

echo "等待应用启动并探活 http://${DEPLOY_HOST}:${APP_HTTP_PORT}/hello ..."
for i in $(seq 1 40); do
  if "${SSH[@]}" "${DEPLOY_USER}@${DEPLOY_HOST}" \
      "curl -fsS http://127.0.0.1:${APP_HTTP_PORT}/hello" 2>/dev/null | grep -q hello; then
    echo "远程探活成功"
    exit 0
  fi
  sleep 2
done

echo "远程探活失败" >&2
"${SSH[@]}" "${DEPLOY_USER}@${DEPLOY_HOST}" \
  "sudo -n journalctl -u web-test -n 80 --no-pager || journalctl -u web-test -n 80 --no-pager || true" || true
exit 1
