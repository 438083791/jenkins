#!/usr/bin/env bash
# 卸载本机 kubeadm 节点（Master 或 Worker 均可在本机执行）
# 用法：
#   sudo bash uninstall-k8s.sh
#
# 注意：
#   - 在 Master 上执行会重置控制面；请先在业务上 helm uninstall / 备份
#   - Worker 卸载后，建议到 Master 执行: kubectl delete node <name>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 或 sudo 运行" >&2
  exit 1
fi

NODE_NAME="$(hostname)"
echo "将对本机执行 kubeadm reset（hostname=${NODE_NAME}）—— 10 秒后继续，Ctrl+C 取消"
echo "注意: 会清理本机 /etc/kubernetes、容器运行时 Pod 等；PVC 宿主机数据视存储插件而定"
sleep 10

if command -v helm >/dev/null 2>&1 && [[ -f /etc/kubernetes/admin.conf ]]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
  helm uninstall ingress-nginx -n ingress-nginx 2>/dev/null || true
  kubectl delete ns ingress-nginx --wait=false 2>/dev/null || true
fi

if command -v kubeadm >/dev/null 2>&1; then
  kubeadm reset -f
else
  echo "未找到 kubeadm，跳过 reset"
fi

systemctl stop kubelet 2>/dev/null || true
# 清理 CNI / 残留（实验环境）
rm -rf /etc/cni/net.d /var/lib/cni /var/lib/kubelet/* 2>/dev/null || true
rm -f /etc/sysctl.d/99-k8s.conf /etc/modules-load.d/k8s.conf
rm -f "${SCRIPT_DIR}/worker-join.sh"

# 可选：取消 hold（不自动 apt remove，避免误删用户其它用途的 kubectl）
if command -v apt-mark >/dev/null 2>&1; then
  apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
fi

ip link delete cni0 2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true

echo
echo "==== 本机 kubeadm 已 reset ===="
echo "若本机是 Worker，请到 Master 删除节点对象:"
echo "  kubectl delete node ${NODE_NAME}"
echo "彻底卸包（可选）:"
echo "  apt-get purge -y kubeadm kubelet kubectl containerd"
echo "kubeconfig 残留可删: rm -rf ~/.kube /root/.kube"
