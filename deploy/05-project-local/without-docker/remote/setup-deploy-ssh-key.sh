#!/usr/bin/env bash
# 在「部署目标机」上执行：为 DEPLOY_USER 生成 SSH 密钥并写入 authorized_keys
# 用法：
#   sudo bash setup-deploy-ssh-key.sh
#   sudo DEPLOY_USER=deploy bash setup-deploy-ssh-key.sh
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 或 sudo 运行" >&2
  exit 1
fi

if ! id -u "${DEPLOY_USER}" >/dev/null 2>&1; then
  echo "用户不存在: ${DEPLOY_USER}（请先运行 prepare-target.sh 或手动创建）" >&2
  exit 1
fi

HOME_DIR="$(getent passwd "${DEPLOY_USER}" | cut -d: -f6)"
if [[ -z "${HOME_DIR}" || ! -d "${HOME_DIR}" ]]; then
  echo "无法解析 ${DEPLOY_USER} 的家目录" >&2
  exit 1
fi

SSH_DIR="${HOME_DIR}/.ssh"
KEY_ED25519="${SSH_DIR}/id_ed25519"
KEY_RSA="${SSH_DIR}/id_rsa"

install -d -m 700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${SSH_DIR}"

if [[ ! -f "${KEY_ED25519}" && ! -f "${KEY_RSA}" ]]; then
  # 无口令，便于 Jenkins 非交互 SSH
  if ssh-keygen -t ed25519 -N '' -f "${KEY_ED25519}" -C "jenkins-web-test-${DEPLOY_USER}" 2>/dev/null; then
    chown "${DEPLOY_USER}:${DEPLOY_USER}" "${KEY_ED25519}" "${KEY_ED25519}.pub"
  else
    # 极老系统无 ed25519 时回退 RSA
    ssh-keygen -t rsa -b 4096 -N '' -f "${KEY_RSA}" -C "jenkins-web-test-${DEPLOY_USER}"
    chown "${DEPLOY_USER}:${DEPLOY_USER}" "${KEY_RSA}" "${KEY_RSA}.pub"
  fi
  echo "已生成新密钥"
else
  echo "已存在密钥，跳过生成"
fi

if [[ -f "${KEY_ED25519}.pub" ]]; then
  PUB="${KEY_ED25519}.pub"
  PRIV="${KEY_ED25519}"
elif [[ -f "${KEY_RSA}.pub" ]]; then
  PUB="${KEY_RSA}.pub"
  PRIV="${KEY_RSA}"
else
  echo "未找到公钥文件" >&2
  exit 1
fi

# 覆盖写入（确保包含本机公钥，可用这对密钥登录）
cat "${PUB}" > "${SSH_DIR}/authorized_keys"
chown "${DEPLOY_USER}:${DEPLOY_USER}" "${SSH_DIR}/authorized_keys"
chmod 600 "${SSH_DIR}/authorized_keys"
chmod 700 "${SSH_DIR}"

echo
echo "==== 完成 ===="
echo "用户: ${DEPLOY_USER}"
echo "公钥已写入: ${SSH_DIR}/authorized_keys"
echo
echo "请将下面「私钥」完整内容导入 Jenkins："
echo "  Manage Jenkins → Credentials → SSH Username with private key"
echo "  ID 示例: web-test-deploy-ssh"
echo "  Username: ${DEPLOY_USER}"
echo "---- BEGIN PRIVATE KEY ----"
cat "${PRIV}"
echo "---- END PRIVATE KEY ----"
echo
echo "本机自测（另开终端，私钥拷到客户端文件后）："
echo "  chmod 600 /tmp/${DEPLOY_USER}_key"
echo "  ssh -i /tmp/${DEPLOY_USER}_key -o BatchMode=yes -o StrictHostKeyChecking=accept-new ${DEPLOY_USER}@<目标机IP> 'echo ssh_ok'"
