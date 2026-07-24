#!/usr/bin/env bash
# 从 Jenkins 节点把 jar 部署到「Supervisor 应用机」
# 由 Jenkinsfile 在 withCredentials(sshUserPrivateKey) 中调用
#
# 环境变量：
#   DEPLOY_HOST         必填
#   DEPLOY_USER         默认 deploy（SSH）
#   DEPLOY_PATH         默认 /opt/web-test
#   DEPLOY_PORT         默认 22
#   APP_HTTP_PORT       默认 8088
#   APP_RUN_USER        运行用户，默认 deploy（须与 Supervisor user= 一致）
#   PROGRAM_NAME        Supervisor program 名，默认 web-test
#   JAR_FILE            必填 本地 jar
#   SSH_IDENTITY_FILE   可选 私钥路径（Jenkins withCredentials 注入）
set -euo pipefail

DEPLOY_HOST="${DEPLOY_HOST:?请设置 DEPLOY_HOST}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
DEPLOY_PATH="${DEPLOY_PATH:-/opt/web-test}"
DEPLOY_PORT="${DEPLOY_PORT:-22}"
APP_HTTP_PORT="${APP_HTTP_PORT:-8088}"
APP_RUN_USER="${APP_RUN_USER:-deploy}"
PROGRAM_NAME="${PROGRAM_NAME:-web-test}"
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

REMOTE_STAGING="/tmp/web-test-deploy-${DEPLOY_USER}.jar.new"
echo "==== 部署 ${JAR_FILE} -> ${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}/web-test.jar (supervisor: ${PROGRAM_NAME}) ===="

"${SSH[@]}" "${DEPLOY_USER}@${DEPLOY_HOST}" \
  "id; echo HOME=\$HOME; ls -ld \$HOME /tmp 2>/dev/null || true; rm -f '${REMOTE_STAGING}'"
"${SCP[@]}" "${JAR_FILE}" "${DEPLOY_USER}@${DEPLOY_HOST}:${REMOTE_STAGING}"

"${SSH[@]}" "${DEPLOY_USER}@${DEPLOY_HOST}" \
  "APP_DIR='${DEPLOY_PATH}' APP_PORT='${APP_HTTP_PORT}' APP_RUN_USER='${APP_RUN_USER}' PROGRAM_NAME='${PROGRAM_NAME}' STAGING='${REMOTE_STAGING}' bash -s" <<'EOS'
set -euo pipefail

test -f "${STAGING}"

mkdir -p "${APP_DIR}" 2>/dev/null || true

install_jar() {
  if [[ -w "${APP_DIR}" ]]; then
    mv -f "${STAGING}" "${APP_DIR}/web-test.jar"
    chmod 640 "${APP_DIR}/web-test.jar" 2>/dev/null || chmod 644 "${APP_DIR}/web-test.jar"
    if id "${APP_RUN_USER}" >/dev/null 2>&1; then
      chgrp "${APP_RUN_USER}" "${APP_DIR}/web-test.jar" 2>/dev/null || true
      sudo -n chown "${APP_RUN_USER}:${APP_RUN_USER}" "${APP_DIR}/web-test.jar" 2>/dev/null || true
    fi
    return 0
  fi
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
  echo "无法写入 ${APP_DIR}：请 chmod 775 且属主/组为 ${APP_RUN_USER}，或配置 sudoers" >&2
  ls -la "$(dirname "${APP_DIR}")" "${APP_DIR}" 2>/dev/null || true
  id
  exit 1
}

install_jar

CONF="/etc/supervisor/conf.d/${PROGRAM_NAME}.conf"
if [[ ! -f "${CONF}" ]]; then
  echo "未找到 ${CONF}，请先在目标机执行 deploy/02-supervisor/install.sh" >&2
  exit 1
fi

echo "更新 Supervisor 环境中的 APP_PORT=${APP_PORT}"
if sudo -n sed -i -E "s/APP_PORT=\"[0-9]+\"/APP_PORT=\"${APP_PORT}\"/" "${CONF}"; then
  sudo -n supervisorctl reread
  sudo -n supervisorctl update
else
  echo "无法修改 ${CONF} 中的 APP_PORT，请检查 sudoers 或手工修改" >&2
  exit 1
fi

if sudo -n supervisorctl restart "${PROGRAM_NAME}"; then
  :
else
  # 首次可能从未成功 start（无 jar），用 start 兜底
  if ! sudo -n supervisorctl start "${PROGRAM_NAME}"; then
    echo "sudo supervisorctl restart/start 失败：请配置 sudoers（见 sudoers-web-test.example）" >&2
    sudo -n supervisorctl status "${PROGRAM_NAME}" || true
    exit 1
  fi
fi

echo "==== supervisorctl status ${PROGRAM_NAME}（重启后）===="
STATUS_OUT="$(sudo -n supervisorctl status "${PROGRAM_NAME}" 2>&1 || true)"
echo "${STATUS_OUT}"
EOS

echo "等待应用启动并探活 http://${DEPLOY_HOST}:${APP_HTTP_PORT}/hello ..."
for i in $(seq 1 40); do
  if "${SSH[@]}" "${DEPLOY_USER}@${DEPLOY_HOST}" \
      "curl -fsS http://127.0.0.1:${APP_HTTP_PORT}/hello" 2>/dev/null | grep -q hello; then
    echo "远程探活成功"
    echo "==== supervisorctl status ${PROGRAM_NAME}（探活通过后，自动执行）===="
    FINAL_STATUS="$("${SSH[@]}" "${DEPLOY_USER}@${DEPLOY_HOST}" \
      "sudo -n supervisorctl status ${PROGRAM_NAME}" 2>&1 || true)"
    echo "${FINAL_STATUS}"
    if echo "${FINAL_STATUS}" | grep -q RUNNING; then
      echo "Supervisor 状态校验通过：RUNNING"
      exit 0
    fi
    echo "探活成功，但 supervisorctl status 未显示 RUNNING" >&2
    exit 1
  fi
  sleep 2
done

echo "远程探活失败" >&2
"${SSH[@]}" "${DEPLOY_USER}@${DEPLOY_HOST}" \
  "echo '==== supervisorctl status ===='; sudo -n supervisorctl status ${PROGRAM_NAME} || true; echo '==== stderr tail ===='; sudo -n supervisorctl tail ${PROGRAM_NAME} stderr 2>/dev/null | tail -n 80 || true" || true
exit 1
