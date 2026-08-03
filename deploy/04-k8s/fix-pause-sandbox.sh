#!/usr/bin/env bash
# 修复 pause 沙箱拉取失败（DaoCloud 403 / sandbox 仍指向 registry.k8s.io）
# 适用于：kubeadm init 已写入 manifests，但 etcd/apiserver 起不来、6443 connection refused
#
# 用法（Master，不必先 uninstall）:
#   sudo bash fix-pause-sandbox.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/k8s-common.sh"

k8s_require_root

PAUSE_IMAGE="${PAUSE_IMAGE:-registry.aliyuncs.com/google_containers/pause:3.10}"
CFG="/etc/containerd/config.toml"

echo "==== 1. 去掉会 403 的 registry.k8s.io DaoCloud 代理 ===="
rm -rf /etc/containerd/certs.d/registry.k8s.io

echo "==== 2. sandbox_image -> ${PAUSE_IMAGE} ===="
if [[ -f "${CFG}" ]] && grep -qE 'sandbox_image\s*=' "${CFG}"; then
  sed -i -E "s|sandbox_image\s*=\s*\"[^\"]*\"|sandbox_image = \"${PAUSE_IMAGE}\"|g" "${CFG}"
  sed -i -E "s|sandbox_image\s*=\s*'[^']*'|sandbox_image = \"${PAUSE_IMAGE}\"|g" "${CFG}"
fi
grep -E 'sandbox_image' "${CFG}" || true

echo "==== 3. 拉取 / 打标 pause ===="
crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock pull "${PAUSE_IMAGE}" || true
k8s_ensure_pause_aliases

echo "==== 4. 重启 containerd + kubelet ===="
systemctl restart containerd
sleep 2
systemctl restart kubelet

echo
echo "等待 30s 后检查控制面容器..."
sleep 30
crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock ps -a | grep -E 'etcd|apiserver|scheduler|controller|PAUSE|IMAGE' || true
echo
echo "若仍无 Running，再执行:"
echo "  sudo bash uninstall-k8s.sh"
echo "  sudo APISERVER_ADVERTISE_ADDRESS=\$(hostname -I | awk '{print \$1}') bash install-k8s.sh master"
echo
echo "探测 API:"
echo "  curl -k https://127.0.0.1:6443/healthz || true"
