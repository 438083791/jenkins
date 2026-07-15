#!/usr/bin/env bash
# 在「Jenkins 机」上手动验证到目标机的 SSH / 目录权限（模拟流水线）
# 用法：
#   bash test-ssh-from-jenkins.sh /path/to/private_key
#   DEPLOY_HOST=192.168.1.165 DEPLOY_USER=deploy bash test-ssh-from-jenkins.sh ~/.ssh/id_ed25519
set -euo pipefail

KEY="${1:-}"
DEPLOY_HOST="${DEPLOY_HOST:-192.168.1.165}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
DEPLOY_PORT="${DEPLOY_PORT:-22}"
DEPLOY_PATH="${DEPLOY_PATH:-/opt/web-test}"

if [[ -z "${KEY}" || ! -f "${KEY}" ]]; then
  echo "用法: $0 <私钥文件路径>" >&2
  echo "示例: $0 /tmp/deploy_key" >&2
  echo "把目标机 /home/deploy/.ssh/id_ed25519 拷到 Jenkins 机后再测。" >&2
  exit 1
fi

chmod 600 "${KEY}" || true
SSH=(ssh -p "${DEPLOY_PORT}" -i "${KEY}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes)

echo "==== 1) SSH 连通 ===="
"${SSH[@]}" "${DEPLOY_USER}@${DEPLOY_HOST}" 'echo ssh_ok; id; echo HOME=$HOME; ls -ld "$HOME" /tmp /opt/web-test 2>/dev/null || true'

echo "==== 2) /tmp 可写 ===="
"${SSH[@]}" "${DEPLOY_USER}@${DEPLOY_HOST}" 'touch /tmp/web-test-jenkins-probe && rm -f /tmp/web-test-jenkins-probe && echo tmp_ok'

echo "==== 3) 应用目录可写？ ===="
if "${SSH[@]}" "${DEPLOY_USER}@${DEPLOY_HOST}" "test -w '${DEPLOY_PATH}' && touch '${DEPLOY_PATH}/.w' && rm -f '${DEPLOY_PATH}/.w' && echo appdir_ok"; then
  true
else
  echo "WARN: ${DEPLOY_PATH} 不可写，部署将依赖 sudo install/mv（检查 sudoers）"
  "${SSH[@]}" "${DEPLOY_USER}@${DEPLOY_HOST}" "ls -ld '${DEPLOY_PATH}'; id; sudo -n true && echo sudo_n_ok || echo sudo_n_FAIL"
fi

echo "==== 4) sudo systemctl ===="
"${SSH[@]}" "${DEPLOY_USER}@${DEPLOY_HOST}" 'sudo -n systemctl status web-test --no-pager -n 5 || true'

echo
echo "全部探测完成。若 1/2 失败，先修密钥与 known_hosts；若 3/4 失败，在目标机修目录属主或 sudoers。"
